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
  alias EtherCAT.Nif

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
  Returns a child specification for starting this module under a supervisor.

  This is useful when you want to start a domain under a DynamicSupervisor
  or regular Supervisor with custom parameters.

  ## Parameters
  - Map with keys:
    - `:name` - Registered name for the domain (atom)
    - `:master` - Master process PID
    - `:resource` - Domain reference from the NIF
    - `:interval` - Update interval in microseconds
    - `:id` - Optional child spec identifier (default: name)
    - `:restart` - Restart strategy (default: `:permanent`)
  """
  @spec child_spec(map()) :: Supervisor.child_spec()
  def child_spec(%{name: name, master: master, resource: resource, interval: interval} = opts) do
    id = Map.get(opts, :id, name)
    restart = Map.get(opts, :restart, :permanent)

    %{
      id: id,
      start: {__MODULE__, :start_link, [name, master, resource, interval]},
      restart: restart,
      shutdown: 5000,
      type: :worker
    }
  end

  @doc """
  Starts a domain process.

  ## Parameters
  - `name` - Registered name for the domain (atom)
  - `master` - Master process PID
  - `resource` - Domain reference from the NIF
  - `interval` - Update interval in microseconds

  ## Returns
  - `{:ok, pid}` on success
  - `{:error, reason}` on failure
  """
  @spec start_link(atom(), pid(), reference(), pos_integer()) :: GenServer.on_start()
  def start_link(name, master, resource, interval) do
    GenServer.start_link(__MODULE__, {master, resource, interval}, name: name)
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

  ## Entry Format

  The entry parameter can be:
  - `{entry_type, entry_index, entry_subindex, bit_length}` - explicit type
  - `{entry_index, entry_subindex, bit_length}` - type inferred from bit length

  ## Example

      # Register with explicit type
      Domain.register_pdo_entry(domain, slave_config, "temperature", {:uint16, 0x6000, 1, 16})

      # Register with inferred type (uint16 from 16 bits)
      Domain.register_pdo_entry(domain, slave_config, "pressure", {0x6010, 1, 16})
  """
  @spec register_pdo_entry(GenServer.server(), reference(), name(), tuple()) ::
          :ok | {:error, term()}
  def register_pdo_entry(domain, slave_config, name, entry) do
    GenServer.call(domain, {:register_pdo_entry, slave_config, name, entry})
  end

  # Infer PDO entry type from bit size
  defp infer_entry_type(1), do: :bool
  defp infer_entry_type(8), do: :uint8
  defp infer_entry_type(16), do: :uint16
  defp infer_entry_type(32), do: :uint32
  defp infer_entry_type(64), do: :uint64
  defp infer_entry_type(size), do: {:unknown, size}

  @doc false
  @spec subscribe(GenServer.server(), pid(), name()) :: :ok
  def subscribe(domain, pid, name) do
    GenServer.call(domain, {:subscribe, pid, name})
  end

  # GenServer callbacks

  @impl true
  def init({master, resource, interval}) do
    # Register this domain in the Registry for process discovery
    # Use a unique key combining master PID and resource reference
    domain_name = Process.get(:"$initial_call") |> elem(1) |> List.first()

    Registry.register(EtherCAT.Registry, {:domain, master, domain_name}, %{
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

  def handle_call(:get_ref, _from, state) do
    {:reply, state.resource, state}
  end

  def handle_call(:get_interval, _from, state) do
    {:reply, state.interval, state}
  end

  def handle_call({:register_pdo_entry, slave_config, name, entry}, _from, state) do
    if state.locked? do
      {:reply, {:error, :domain_locked}, state}
    else
      # Normalize entry to include type
      normalized_entry =
        case entry do
          {entry_type, entry_index, entry_subindex, entry_size} when is_atom(entry_type) ->
            # Already has explicit type
            {entry_type, entry_index, entry_subindex, entry_size}

          {entry_index, entry_subindex, entry_size} ->
            # Infer type from size
            entry_type = infer_entry_type(entry_size)
            {entry_type, entry_index, entry_subindex, entry_size}
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

  def handle_call(:get_pdo_entries, _from, state) do
    {:reply, state.entries, state}
  end

  def handle_call({:store_and_lock_entries, entries}, _from, state) do
    {:reply, :ok, %{state | entries: entries, locked?: true}}
  end

  # Receives cyclic data changes from the NIF with entry names and values
  def handle_info({:data_changed, changes}, state) do
    Logger.debug("Domain received data_changed with #{length(changes)} changed entries")

    for {name, value} <- changes do
      Logger.debug("  Entry changed: #{name} = #{inspect(value)}")

      # Find subscribers by entry name
      case state.subscribers[name] do
        pids when is_struct(pids, MapSet) ->
          Logger.debug("  Notifying #{MapSet.size(pids)} subscribers for #{name}")
          Enum.each(pids, fn pid -> send(pid, {:data_changed, name, value}) end)

        nil ->
          # No subscribers for this entry
          :ok
      end
    end

    {:noreply, state}
  end

  # Handles subscriber process termination - remove from all subscriptions
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
  def handle_info({:wc_changed, _wc}, state) do
    # Working counter changed - could be used for diagnostics
    {:noreply, state}
  end

  # Receives working counter state changes from the NIF
  # wc_state values: 0 = EC_WC_ZERO, 1 = EC_WC_INCOMPLETE, 2 = EC_WC_COMPLETE
  def handle_info({:state_changed, _wc_state}, state) do
    # State changed - could be used for diagnostics or error detection
    {:noreply, state}
  end

  # Catch-all for unexpected messages
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
