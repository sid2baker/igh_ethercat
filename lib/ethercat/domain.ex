defmodule EtherCAT.Domain do
  @moduledoc """
  Manages EtherCAT process data domains.

  Domains allow grouping of process data transfers with independent update periods,
  enabling efficient cyclic communication with different timing requirements. They
  handle PDO entry registration and manage data exchange between the master and slaves.

  ## Domain Lifecycle

  1. **Creation** - Domain is created via `Master.create_domain/3` with a name and interval
  2. **Configuration** - PDO entries are registered via `register_pdo_entry/4`
  3. **Activation** - Master activates all domains when entering operational mode
  4. **Operation** - Cyclic task processes and queues domain data at configured intervals
  5. **Notifications** - Subscribers receive messages when PDO values change

  ## Update Intervals

  Each domain has an interval multiplier (in microseconds) that determines how often
  its data is exchanged. For example:
  - Default domain: 1µs (every cycle)
  - Slow sensors: 100µs (every 100 cycles)
  - Configuration data: 1000µs (every 1000 cycles)

  ## Change Notifications

  The domain tracks data changes at the bit level and notifies subscribers only when
  values actually change. This minimizes message traffic while maintaining real-time
  responsiveness.

  ## Thread Safety

  All NIF communication is routed through the Master process to prevent race conditions.
  The domain never calls NIFs directly, ensuring thread-safe operation.

  ## Multi-Master Support

  Domains are registered in the `EtherCAT.Registry` with a composite key `{:domain, master, name}`,
  allowing multiple masters to each have domains with the same name without conflicts.

      # Two masters can each have their own :default_domain
      {:ok, master1, _} = EtherCAT.open(index: 0)
      {:ok, master2, _} = EtherCAT.open(index: 1)

      # Both create :default_domain - no conflict
      Master.create_domain(master1, :default_domain, 1)
      Master.create_domain(master2, :default_domain, 1)

      # Lookup uses both master and name
      {:ok, domain1} = Domain.find_domain(master1, :default_domain)
      {:ok, domain2} = Domain.find_domain(master2, :default_domain)
      # domain1 and domain2 are different processes

  ## Example

      # Create a domain with 100µs update interval
      domain_ref = Master.create_domain(master, :slow_domain, 100)

      # Register PDO entries to this domain
      Domain.register_pdo_entry(domain_ref, slave_config, "temperature", {0x6000, 1, 16})

      # Subscribe to value changes
      Domain.subscribe(domain_ref, self(), "temperature")

      # Receive notifications
      receive do
        {:data_changed, "temperature", value} -> IO.puts("Temp: ")
      end
  """
  use GenServer
  require Logger

  defstruct [:master, :resource, :interval, :entries, :subscribers, locked?: false]

  @type t :: %__MODULE__{
          master: pid(),
          resource: reference(),
          interval: integer(),
          entries: map(),
          subscribers: %{name() => MapSet.t(pid())},
          locked?: boolean()
        }

  @type name :: String.t()
  @type offset :: non_neg_integer()
  @type size :: non_neg_integer()

  # Client API

  @doc """
  Finds a domain process by master and domain name.

  ## Parameters
  - `master` - Master process PID
  - `name` - Domain name (atom)

  ## Returns
  - `{:ok, pid}` if found
  - `{:error, :not_found}` if domain doesn't exist
  """
  @spec find_domain(pid(), atom()) :: {:ok, pid()} | {:error, :not_found}
  def find_domain(master, name) do
    case Registry.lookup(EtherCAT.Registry, {:domain, master, name}) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Starts a domain process.

  ## Parameters
  - `opts` - Keyword list with:
    - `:name` - Registered name for the domain (atom)
    - `:master` - Master process PID
    - `:resource` - Domain reference from the NIF
    - `:interval` - Update interval in microseconds

  ## Returns
  - `{:ok, pid}` on success
  - `{:error, reason}` on failure

  ## Examples

      Domain.start_link(
        name: :default_domain,
        master: master_pid,
        resource: domain_ref,
        interval: 1
      )
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    name = Keyword.fetch!(opts, :name)
    master = Keyword.fetch!(opts, :master)
    resource = Keyword.fetch!(opts, :resource)
    interval = Keyword.fetch!(opts, :interval)

    GenServer.start_link(__MODULE__, {name, master, resource, interval})
  end

  @doc """
  Returns the pending PDO entries from the domain.

  This is called by the Master before activation to retrieve all registered
  PDO entries that need to be configured in the NIF layer.

  ## Returns
  Map of slave configs to their PDO entry lists.
  """
  @spec get_pdo_entries(GenServer.server()) :: map()
  def get_pdo_entries(domain) do
    GenServer.call(domain, :get_pdo_entries)
  end

  @doc false
  @spec store_and_lock_entries(GenServer.server(), map()) :: :ok
  def store_and_lock_entries(domain, entries) do
    GenServer.call(domain, {:store_and_lock_entries, entries})
  end

  @doc """
  Returns the domain's NIF reference.

  This reference is used by the Master to access domain operations in the NIF layer.
  """
  @spec get_ref(GenServer.server()) :: reference()
  def get_ref(domain) do
    GenServer.call(domain, :get_ref)
  end

  @doc """
  Returns the domain's update interval in microseconds.

  The interval determines how often the domain's data is exchanged during
  cyclic operation.
  """
  @spec get_interval(GenServer.server()) :: pos_integer()
  def get_interval(domain) do
    GenServer.call(domain, :get_interval)
  end

  @doc """
  Registers a PDO entry to this domain for cyclic data exchange.

  Entries are queued during configuration and actually registered when the
  master enters operational mode.

  ## Parameters
  - `domain` - Domain process
  - `slave_config` - Slave configuration reference
  - `name` - PDO entry name
  - `entry` - Entry tuple (see Entry Format below)
  - `direction` - `:input` or `:output` (for change detection and verification)

  ## Entry Format

  The entry parameter can be:
  - `{entry_type, entry_index, entry_subindex, bit_length}` - explicit type
  - `{entry_index, entry_subindex, bit_length}` - type inferred from bit length

  ## Example

      # Register input with explicit type
      Domain.register_pdo_entry(domain, slave_config, "temperature",
        {:uint16, 0x6000, 1, 16}, :input)

      # Register output with inferred type
      Domain.register_pdo_entry(domain, slave_config, "motor_command",
        {0x7010, 1, 16}, :output)
  """
  @spec register_pdo_entry(GenServer.server(), reference(), name(), tuple(), atom()) ::
          :ok | {:error, term()}
  def register_pdo_entry(domain, slave_config, name, entry, direction) do
    GenServer.call(domain, {:register_pdo_entry, slave_config, name, entry, direction})
  end

  # Infer PDO entry type from bit size
  defp infer_entry_type(1), do: :bool
  defp infer_entry_type(8), do: :uint8
  defp infer_entry_type(16), do: :uint16
  defp infer_entry_type(32), do: :uint32
  defp infer_entry_type(64), do: :uint64
  defp infer_entry_type(size), do: {:unknown, size}

  @doc """
  Sets a PDO value in this domain.

  Writes a value to an output PDO. The write is deferred until the next cyclic
  task iteration, where it will be detected and written to the domain buffer.

  ## Parameters
  - `domain` - Domain process (name or PID)
  - `unique_name` - Unique PDO identifier (e.g., "slave_1:pdo_7010:1")
  - `value` - Value to write (type depends on PDO configuration)

  ## Returns
  - `:ok` on success
  - `{:error, reason}` if PDO not found or domain not operational

  ## Example

      Domain.set_pdo_value(:default_domain, "slave_1:output1", true)
  """
  @spec set_pdo_value(GenServer.server(), name(), term()) :: :ok | {:error, term()}
  def set_pdo_value(domain, unique_name, value) do
    GenServer.call(domain, {:set_pdo_value, unique_name, value})
  end

  @doc """
  Gets a PDO value from this domain.

  Reads the most recent value received during cyclic exchange.

  ## Parameters
  - `domain` - Domain process (name or PID)
  - `unique_name` - Unique PDO identifier (e.g., "slave_1:pdo_6000:1")

  ## Returns
  - `{:ok, value}` on success
  - `{:error, reason}` if PDO not found or domain not operational

  ## Example

      {:ok, temperature} = Domain.get_pdo_value(:default_domain, "slave_1:temp")
  """
  @spec get_pdo_value(GenServer.server(), name()) :: {:ok, term()} | {:error, term()}
  def get_pdo_value(domain, unique_name) do
    GenServer.call(domain, {:get_pdo_value, unique_name})
  end

  @doc """
  Subscribes a process to receive notifications when a PDO value changes.

  The subscriber will receive `{:data_changed, unique_name, value}` messages
  whenever the PDO value changes during cyclic operation.

  ## Parameters
  - `domain` - Domain process (name or PID)
  - `pid` - Process to receive notifications
  - `unique_name` - Unique PDO identifier to watch

  ## Returns
  - `:ok` on success

  ## Example

      Domain.subscribe(:default_domain, self(), "slave_1:temperature")

      receive do
        {:data_changed, "slave_1:temperature", value} ->
          IO.puts("Temperature changed to: \#{value}")
      end
  """
  @spec subscribe(GenServer.server(), pid(), name()) :: :ok
  def subscribe(domain, pid, name) do
    GenServer.call(domain, {:subscribe, pid, name})
  end

  @doc """
  Unsubscribes a process from receiving PDO change notifications.

  Removes the subscription previously created with `subscribe/3`.

  ## Parameters
  - `domain` - Domain process (name or PID)
  - `pid` - Process to remove from notifications
  - `unique_name` - Unique PDO identifier to stop watching

  ## Returns
  - `:ok` on success

  ## Example

      Domain.subscribe(:default_domain, self(), "slave_1:temperature")
      # ... receive some notifications ...
      Domain.unsubscribe(:default_domain, self(), "slave_1:temperature")
  """
  @spec unsubscribe(GenServer.server(), pid(), name()) :: :ok
  def unsubscribe(domain, pid, name) do
    GenServer.call(domain, {:unsubscribe, pid, name})
  end

  # GenServer callbacks

  @impl true
  def init({name, master, resource, interval}) do
    # Register this domain in the Registry for process discovery
    # Use a unique key combining master PID and domain name
    Registry.register(EtherCAT.Registry, {:domain, master, name}, %{
      master: master,
      interval: interval
    })

    {:ok,
     %__MODULE__{
       master: master,
       resource: resource,
       interval: interval,
       entries: %{},
       subscribers: %{},
       locked?: false
     }}
  end

  @impl true
  def handle_call(:get_ref, _from, state) do
    {:reply, state.resource, state}
  end

  @impl true
  def handle_call(:get_interval, _from, state) do
    {:reply, state.interval, state}
  end

  @impl true
  def handle_call({:set_pdo_value, unique_name, value}, _from, state) do
    result = EtherCAT.Master.domain_set_value(state.master, state.resource, unique_name, value)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_pdo_value, unique_name}, _from, state) do
    result = EtherCAT.Master.domain_get_value(state.master, state.resource, unique_name)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:register_pdo_entry, slave_config, name, entry, direction}, _from, state) do
    if state.locked? do
      {:reply, {:error, :domain_locked}, state}
    else
      # Normalize entry to include type and direction
      normalized_entry =
        case entry do
          {entry_type, entry_index, entry_subindex, entry_size} when is_atom(entry_type) ->
            # Already has explicit type
            {entry_type, entry_index, entry_subindex, entry_size, direction}

          {entry_index, entry_subindex, entry_size} ->
            # Infer type from size
            entry_type = infer_entry_type(entry_size)
            {entry_type, entry_index, entry_subindex, entry_size, direction}
        end

      result =
        Map.update(
          state.entries,
          slave_config,
          [{name, normalized_entry}],
          &[{name, normalized_entry} | &1]
        )

      {:reply, :ok, %{state | entries: result}}
    end
  end

  @impl true
  def handle_call({:subscribe, pid, name}, _from, state) do
    # Monitor the subscribing process so we clean up when it dies
    Process.monitor(pid)

    # Add to subscribers using MapSet
    subscribers =
      Map.update(
        state.subscribers,
        name,
        MapSet.new([pid]),
        &MapSet.put(&1, pid)
      )

    Logger.debug("Subscribed #{inspect(pid)} to #{name}")
    Logger.debug("Total subscribers: #{map_size(subscribers)}")

    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  @impl true
  def handle_call({:unsubscribe, pid, name}, _from, state) do
    # Remove from subscribers
    subscribers =
      case state.subscribers[name] do
        nil ->
          state.subscribers

        pids ->
          updated_pids = MapSet.delete(pids, pid)

          # Remove entry entirely if no subscribers left
          if MapSet.size(updated_pids) == 0 do
            Map.delete(state.subscribers, name)
          else
            Map.put(state.subscribers, name, updated_pids)
          end
      end

    Logger.debug("Unsubscribed #{inspect(pid)} from #{name}")

    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  @impl true
  def handle_call(:get_pdo_entries, _from, state) do
    {:reply, state.entries, state}
  end

  @impl true
  def handle_call({:store_and_lock_entries, entries}, _from, state) do
    {:reply, :ok, %{state | entries: entries, locked?: true}}
  end

  # Receives cyclic data changes from the NIF with entry names and values
  # Each notification is sent individually per entry change
  @impl true
  def handle_info({:data_changed, name, value}, state) do
    Logger.debug("Entry changed: #{name} = #{inspect(value)}")

    # Find subscribers by entry name
    case state.subscribers[name] do
      pids when is_struct(pids, MapSet) ->
        Logger.debug("  Notifying #{MapSet.size(pids)} subscribers for #{name}")
        Enum.each(pids, fn pid -> send(pid, {:data_changed, name, value}) end)

      nil ->
        # No subscribers for this entry
        :ok
    end

    {:noreply, state}
  end

  # Receives output change confirmations from the NIF
  # This is sent when an output PDO value has been successfully written to the domain
  @impl true
  def handle_info({:output_changed, name, value}, state) do
    Logger.debug("Output confirmed: #{name} = #{inspect(value)}")

    # Notify subscribers about output confirmation
    case state.subscribers[name] do
      pids when is_struct(pids, MapSet) ->
        Logger.debug("  Notifying #{MapSet.size(pids)} subscribers for output #{name}")
        Enum.each(pids, fn pid -> send(pid, {:output_changed, name, value}) end)

      nil ->
        # No subscribers for this entry
        :ok
    end

    {:noreply, state}
  end

  # Handles subscriber process termination - remove from all subscriptions
  @impl true
  def handle_info({:DOWN, _monitor_ref, :process, pid, _reason}, state) do
    subscribers =
      state.subscribers
      |> Enum.map(fn {name, pids} ->
        updated_pids = MapSet.delete(pids, pid)

        # Keep entry only if there are still subscribers
        if MapSet.size(updated_pids) > 0 do
          {name, updated_pids}
        else
          nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Map.new()

    {:noreply, %{state | subscribers: subscribers}}
  end

  # Receives working counter changes from the NIF during cyclic operation
  @impl true
  def handle_info({:wc_changed, _wc}, state) do
    # Working counter changed - could be used for diagnostics
    {:noreply, state}
  end

  # Receives working counter state changes from the NIF
  # wc_state values: 0 = EC_WC_ZERO, 1 = EC_WC_INCOMPLETE, 2 = EC_WC_COMPLETE
  @impl true
  def handle_info({:state_changed, _wc_state}, state) do
    # State changed - could be used for diagnostics or error detection
    {:noreply, state}
  end

  # Catch-all for unexpected messages
  @impl true
  def handle_info(msg, state) do
    Logger.debug("Domain received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Domain terminating: #{inspect(reason)}")

    # Notify all subscribers that domain is shutting down
    Enum.each(state.subscribers, fn {_name, pids} ->
      Enum.each(pids, fn pid ->
        if Process.alive?(pid) do
          send(pid, {:domain_shutdown, self()})
        end
      end)
    end)

    :telemetry.execute(
      [:ethercat, :domain, :terminate],
      %{subscriber_count: map_size(state.subscribers)},
      %{reason: reason}
    )

    :ok
  end
end
