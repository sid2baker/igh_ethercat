defmodule EtherCAT.Domain do
  @moduledoc """
  GenServer grouping PDO transfers with independent update intervals.
  """
  use GenServer
  require Logger

  defstruct [:master, :interval, :entries, :subscribers, locked?: false]

  @type t :: %__MODULE__{
          master: pid(),
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
    - `:interval` - Update interval in microseconds

  ## Returns
  - `{:ok, pid}` on success
  - `{:error, reason}` on failure

  ## Examples

      Domain.start_link(
        name: :default_domain,
        master: master_pid,
        interval: 1
      )
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    name = Keyword.fetch!(opts, :name)
    master = Keyword.fetch!(opts, :master)
    interval = Keyword.fetch!(opts, :interval)

    GenServer.start_link(__MODULE__, {name, master, interval})
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
  Returns the domain's update interval in microseconds.

  The interval determines how often the domain's data is exchanged during
  cyclic operation.
  """
  @spec get_interval(GenServer.server()) :: pos_integer()
  def get_interval(domain) do
    GenServer.call(domain, :get_interval)
  end

  @doc """
  Returns true if domain is locked (operational mode active).

  Locked domains cannot accept new PDO registrations.
  """
  @spec locked?(GenServer.server()) :: boolean()
  def locked?(domain) do
    GenServer.call(domain, :locked?)
  end

  @doc """
  Registers a PDO entry to this domain for cyclic data exchange.

  Entries are queued during configuration and actually registered when the
  master enters operational mode.

  ## Parameters
  - `domain` - Domain process
  - `slave_config` - Slave configuration reference
  - `name` - PDO entry name
  - `entry` - Entry tuple: `{entry_index, entry_subindex, bit_length}`
  - `direction` - `:input` or `:output` (for change detection and verification)

  ## Note

  The domain does not need type information - it only stores and exchanges
  raw binary data. Type encoding/decoding is handled by the Slave driver.

  ## Example

        # Register temperature input
      Domain.register_pdo_entry(domain, slave_config, "temperature",
        {0x6000, 1, 16}, :input)

        # Register motor command output
      Domain.register_pdo_entry(domain, slave_config, "motor_command",
        {0x7010, 1, 16}, :output)
  """
  @spec register_pdo_entry(GenServer.server(), reference(), name(), tuple(), atom()) ::
          :ok | {:error, term()}
  def register_pdo_entry(domain, slave_config, name, entry, direction) do
    GenServer.call(domain, {:register_pdo_entry, slave_config, name, entry, direction})
  end

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
  def init({name, master, interval}) do
    # Register this domain in the Registry for process discovery
    # Use a unique key combining master PID and domain name
    Registry.register(EtherCAT.Registry, {:domain, master, name}, %{
      master: master,
      interval: interval
    })

    {:ok,
     %__MODULE__{
       master: master,
       interval: interval,
       entries: %{},
       subscribers: %{},
       locked?: false
     }}
  end

  @impl true
  def handle_call(:get_interval, _from, state) do
    {:reply, state.interval, state}
  end

  @impl true
  def handle_call(:locked?, _from, state) do
    {:reply, state.locked?, state}
  end

  @impl true
  def handle_call({:set_pdo_value, unique_name, value}, _from, state) do
    # Domain identifies itself by PID; Master will look up the NIF reference
    result = EtherCAT.Master.domain_set_value(state.master, self(), unique_name, value)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_pdo_value, unique_name}, _from, state) do
    # Domain identifies itself by PID; Master will look up the NIF reference
    result = EtherCAT.Master.domain_get_value(state.master, self(), unique_name)
    {:reply, result, state}
  end

  # Reject PDO registration when domain is locked (operational mode active)
  @impl true
  def handle_call(
        {:register_pdo_entry, _slave_config, _name, _entry, _direction},
        _from,
        %{locked?: true} = state
      ) do
    {:reply,
     {:error,
      {:domain_locked,
       "Cannot register PDOs after master activation. " <>
         "Reconfiguration requires restarting the master."}}, state}
  end

  # Accept PDO registration when domain is unlocked (configuration phase)
  @impl true
  def handle_call({:register_pdo_entry, slave_config, name, entry, direction}, _from, state) do
    # Entry is always {index, subindex, size} - add direction to make 4-tuple
    {entry_index, entry_subindex, entry_size} = entry
    normalized_entry = {entry_index, entry_subindex, entry_size, direction}

    result =
      Map.update(
        state.entries,
        slave_config,
        [{name, normalized_entry}],
        &[{name, normalized_entry} | &1]
      )

    {:reply, :ok, %{state | entries: result}}
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
    Logger.info("Domain locked - #{map_size(entries)} slave configs registered")
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
