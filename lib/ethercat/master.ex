defmodule EtherCAT.Master do
  @moduledoc """
  EtherCAT master state machine managing network lifecycle and slave coordination.

  The Master is the central coordination point for EtherCAT communication, managing:
  - Network connection and link status
  - Slave discovery and configuration
  - Domain creation and management
  - Operational mode activation
  - Cyclic task execution

  ## State Machine

  The Master implements a state machine with four states:

  - **`:offline`** - Initial state, master created but not connected
  - **`:stale`** - Network link is up, waiting for slaves to respond
  - **`:synced`** - Slaves discovered and synchronized, ready for configuration
  - **`:operational`** - Cyclic communication active, real-time I/O in progress

  State transitions occur automatically based on network conditions and explicit
  commands like `connect/1`, `sync_slaves/1`, and `start_cyclic_mode/1`.

  ## Thread Safety

  The Master serves as the single gateway for all NIF operations, ensuring
  thread-safe access to the underlying IgH EtherCAT library. Slave and Domain
  modules route all NIF calls through the Master process, preventing race
  conditions and resource conflicts.

  ## Architecture

  ```
  EtherCAT.Master (GenStatem)
    ├─ manages → Master NIF Resource
    ├─ supervises → [EtherCAT.Slave]
    ├─ supervises → [EtherCAT.Domain]
    └─ spawns → Cyclic Task (threaded NIF)
  ```

  ## Example Workflow

      # Start the master
      {:ok, master} = Master.start_link(update_interval: 10_000)

      # Connect to network
      :ok = Master.connect(master)

      # Discover and synchronize slaves
      {:ok, [slave1, slave2]} = Master.sync_slaves(master)

      # Configure slaves and register PDOs
      Slave.configure(slave1, [])
      Slave.register_all_pdos(slave1, :default_domain)

      # Activate cyclic communication
      Master.start_cyclic_mode(master)

      # Master now exchanges data with slaves in real-time
  """
  @behaviour :gen_statem
  require Logger
  import EtherCAT.Utils

  alias EtherCAT.{Nif, Slave, Domain}

  defstruct [:master_ref, :slaves, :domains, :task_pid, :update_interval]

  @type t :: %__MODULE__{
          master_ref: reference(),
          slaves: [Slave.t()],
          domains: [Domain.t()],
          task_pid: pid(),
          # in us
          update_interval: integer()
        }

  # Client API

  @doc """
  Returns a child specification for starting this module under a supervisor.

  ## Options
  - `:master_index` - The EtherCAT master index (default: 0) - maps to /dev/EtherCATX
  - `:update_interval` - Cyclic task interval in microseconds (default: 10_000 = 10ms)
  - `:name` - Registration name (default: `EtherCAT.Master`)
  - `:id` - Child spec identifier (default: `__MODULE__`)
  - `:restart` - Restart strategy (default: `:permanent`)
  - `:shutdown` - Shutdown timeout in ms (default: 5000)
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    id = Keyword.get(opts, :id, __MODULE__)
    restart = Keyword.get(opts, :restart, :permanent)
    shutdown = Keyword.get(opts, :shutdown, 5000)

    %{
      id: id,
      start: {__MODULE__, :start_link, [opts]},
      restart: restart,
      shutdown: shutdown,
      type: :worker
    }
  end

  @doc """
  Starts the EtherCAT master process.

  Initializes a master instance and creates the default domain. The master
  begins in the `:offline` state and must be connected via `connect/1` before
  use.

  ## Options
  - `:master_index` - The EtherCAT master index (default: 0) - maps to /dev/EtherCATX
  - `:update_interval` - Cyclic task interval in microseconds (default: 10_000 = 10ms)
  - `:name` - Registration name (default: `EtherCAT.Master`)

  ## Returns
  - `{:ok, pid}` on success
  - `{:error, reason}` on failure (e.g., master device not found)

  ## Example

      # Start with default settings (10ms cycle)
      {:ok, master} = Master.start_link()

      # Start with 1ms cycle for faster control loops
      {:ok, master} = Master.start_link(update_interval: 1_000)

      # Access a different master device
      {:ok, master} = Master.start_link(master_index: 1)
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) do
    master_index = Keyword.get(opts, :master_index, 0)
    update_interval = Keyword.get(opts, :update_interval, 10_000)
    name = Keyword.get(opts, :name, __MODULE__)
    :gen_statem.start_link({:local, name}, __MODULE__, {master_index, update_interval}, [])
  end

  @doc """
  Connects to the EtherCAT network and verifies link status.

  Transitions the master from `:offline` to `:stale` state if the network
  link is up. The master will then wait for slaves to respond.

  ## Parameters
  - `master` - The master process (PID or registered name)
  - `timeout` - Call timeout in milliseconds (default: 5000)

  ## Returns
  - `:ok` if connection successful and link is up
  - `{:error, :link_down}` if physical link is not established
  - `{:error, :offline}` if called from the wrong state

  ## Example

      :ok = Master.connect(master)
      :ok = Master.connect(master, 10_000)
  """
  @spec connect(GenServer.server(), timeout()) :: :ok | {:error, term()}
  def connect(master, timeout \\ 5000) do
    :gen_statem.call(master, :connect, timeout)
  end

  @doc """
  Synchronizes slaves - discovers and initializes all slaves on the bus.

  Queries the master for all responding slaves, creates a process for each,
  and assigns appropriate drivers. The master transitions to `:synced` state.

  ## Parameters
  - `master` - The master process (PID or registered name)
  - `timeout` - Call timeout in milliseconds (default: 10_000 for slave enumeration)

  ## Returns
  - `{:ok, [slave_pids]}` - List of slave process PIDs in bus order
  - `{:error, reason}` - If called from wrong state or slaves not responding

  ## Example

      {:ok, slaves} = Master.sync_slaves(master)
      [coupler, input_terminal, output_terminal] = slaves
  """
  @spec sync_slaves(GenServer.server(), timeout()) :: {:ok, [pid()]} | {:error, term()}
  def sync_slaves(master, timeout \\ 10_000) do
    :gen_statem.call(master, :sync_slaves, timeout)
  end

  @doc """
  Creates a new process data domain with independent update interval.

  Domains allow grouping of PDO entries with different timing requirements,
  enabling efficient multi-rate control loops on a single master.

  ## Parameters
  - `master` - The master process (PID or registered name)
  - `name` - Unique identifier for the domain (atom)
  - `interval` - Update interval multiplier (in cycles)
  - `timeout` - Call timeout in milliseconds (default: 5000)

  ## Returns
  - `{:ok, domain_ref}` - Reference to the created domain
  - `{:error, reason}` - If domain creation fails

  ## Example

      # Fast domain for critical control (every cycle)
      {:ok, fast} = Master.create_domain(master, :fast_io, 1)

      # Slow domain for monitoring (every 100 cycles)
      {:ok, slow} = Master.create_domain(master, :monitoring, 100)
  """
  @spec create_domain(GenServer.server(), atom(), pos_integer(), timeout()) ::
          {:ok, reference()} | {:error, term()}
  def create_domain(master, name, interval, timeout \\ 5000) do
    :gen_statem.call(master, {:create_domain, name, interval}, timeout)
  end

  @doc """
  Activates cyclic mode operation on the master.

  Registers all pending PDO entries, activates the master, and starts the
  real-time cyclic task. After activation, no further configuration changes
  are allowed - slaves and domains become locked.

  The master transitions to `:operational` state and begins exchanging process
  data with slaves at the configured interval.

  ## Parameters
  - `master` - The master process (PID or registered name)

  ## Returns
  - `:ok` (async operation, use message handlers to monitor state)

  ## Example

      Master.start_cyclic_mode(master)
      # Master now running cyclic communication
  """
  @spec start_cyclic_mode(GenServer.server()) :: :ok
  def start_cyclic_mode(master) do
    :gen_statem.cast(master, :start_cyclic_mode)
  end

  @doc """
  Gets the master's NIF reference for low-level operations.

  This is primarily used internally by Slave and Domain modules. Most
  applications should not need to call this directly.

  ## Parameters
  - `master` - The master process (PID or registered name)
  - `timeout` - Call timeout in milliseconds (default: 5000)

  ## Returns
  - Master resource reference
  """
  @spec get_ref(GenServer.server(), timeout()) :: reference()
  def get_ref(master, timeout \\ 5000) do
    :gen_statem.call(master, :get_ref, timeout)
  end

  # Internal API - called by Slave and Domain modules
  # These functions serve as the single gateway for all NIF operations,
  # preventing race conditions by ensuring only Master talks to the NIF.

  @doc false
  def slave_operation(master, position, operation, args, timeout \\ 5000) do
    :gen_statem.call(master, {:slave_operation, position, operation, args}, timeout)
  end

  @doc false
  def domain_set_value(master, domain_ref, name, value, timeout \\ 5000) do
    :gen_statem.call(master, {:domain_set_value, domain_ref, name, value}, timeout)
  end

  @doc false
  def domain_get_value(master, domain_ref, name, timeout \\ 5000) do
    :gen_statem.call(master, {:domain_get_value, domain_ref, name}, timeout)
  end

  @doc false
  def domain_subscribe(master, domain, pid, name, timeout \\ 5000) do
    :gen_statem.call(master, {:domain_subscribe, domain, pid, name}, timeout)
  end

  # Callbacks
  @impl true
  def callback_mode(), do: [:state_functions, :state_enter]

  @impl true
  def init({master_index, update_interval}) do
    # Trap exits to ensure graceful cleanup
    Process.flag(:trap_exit, true)

    case Nif.request_master(master_index) do
      {:ok, ref} ->
        # Register this master in the Registry for process discovery
        case Registry.register(EtherCAT.Registry, {:master, master_index}, %{
               master_index: master_index,
               update_interval: update_interval
             }) do
          {:ok, _} ->
            :ok

          {:error, {:already_registered, _pid}} ->
            Logger.warning(
              "Master #{master_index} already registered, this instance will not be discoverable via Registry"
            )
        end

        domain_ref = Nif.master_create_domain(ref, self(), 1)

        # Start default domain under DynamicSupervisor for proper supervision
        domain_child_spec = %{
          id: :default_domain,
          start: {Domain, :start_link, [:default_domain, self(), domain_ref, 1]},
          restart: :permanent,
          shutdown: 5000,
          type: :worker
        }

        case DynamicSupervisor.start_child(EtherCAT.DomainSupervisor, domain_child_spec) do
          {:ok, domain_pid} ->
            # Update the domain accessor with the Domain process PID
            Nif.domain_set_pid(domain_ref, domain_pid)

            data = %__MODULE__{
              master_ref: ref,
              domains: [domain_pid],
              slaves: [],
              task_pid: nil,
              update_interval: update_interval
            }

            Logger.info("EtherCAT Master #{master_index} initialized successfully")
            {:ok, :offline, data}

          {:error, reason} ->
            Logger.error("Failed to start default domain: #{inspect(reason)}")
            {:stop, {:failed_to_start_domain, reason}}
        end

      :error ->
        Logger.error("Failed to create EtherCAT master #{master_index}")
        {:stop, :failed_to_create_master}
    end
  end

  @impl true
  def terminate(reason, _state, data) do
    Logger.info("EtherCAT Master terminating: #{inspect(reason)}")

    # Stop cyclic task if running
    if data.task_pid && Process.alive?(data.task_pid) do
      Process.exit(data.task_pid, :shutdown)
    end

    # Gracefully terminate all slaves
    Enum.each(data.slaves, fn slave_pid ->
      if Process.alive?(slave_pid) do
        DynamicSupervisor.terminate_child(EtherCAT.SlaveSupervisor, slave_pid)
      end
    end)

    # Gracefully terminate all domains
    Enum.each(data.domains, fn domain_pid ->
      if Process.alive?(domain_pid) do
        DynamicSupervisor.terminate_child(EtherCAT.DomainSupervisor, domain_pid)
      end
    end)

    Logger.info("EtherCAT Master cleanup completed")
    :ok
  end

  # State: offline
  # Master is created but not yet connected to the network

  def offline(:enter, _old_state, _data) do
    Logger.debug("Master entered :offline state")
    :telemetry.execute([:ethercat, :master, :state], %{}, %{state: :offline})
    :keep_state_and_data
  end

  def offline({:call, from}, :connect, data) do
    start_time = System.monotonic_time()

    try do
      master_state = Nif.get_master_state(data.master_ref)

      if master_state.link_up == 1 do
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:ethercat, :master, :connect],
          %{duration: duration},
          %{result: :success}
        )

        Logger.info("Master connected successfully, transitioning to :stale")
        {:next_state, :stale, data, [{:reply, from, :ok}]}
      else
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:ethercat, :master, :connect],
          %{duration: duration},
          %{result: :link_down}
        )

        Logger.warning("Master connect failed: link is down")
        {:keep_state_and_data, [{:reply, from, {:error, :link_down}}]}
      end
    rescue
      error ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:ethercat, :master, :connect],
          %{duration: duration},
          %{result: :error, error: inspect(error)}
        )

        Logger.error("Error connecting master: #{inspect(error)}")
        {:keep_state_and_data, [{:reply, from, {:error, :nif_error}}]}
    end
  end

  def offline({:call, from}, _event_content, _data) do
    actions = [{:reply, from, {:error, :offline}}]
    {:keep_state_and_data, actions}
  end

  # Handle EXIT messages from linked processes
  def offline(:info, {:EXIT, pid, reason}, data) do
    handle_exit(pid, reason, :offline, data)
  end

  def offline(event_type, event_content, data) do
    handle_unexpected(event_type, event_content, :offline, data)
  end

  # State: stale
  # Network is up but slaves are not yet discovered/synchronized

  def stale(:enter, _old_state, data) do
    :telemetry.execute([:ethercat, :master, :state], %{}, %{state: :stale})
    actions = [{:state_timeout, data.update_interval, :update_master_state}]
    {:keep_state_and_data, actions}
  end

  def stale({:call, from}, :sync_slaves, data) do
    start_time = System.monotonic_time()

    try do
      master_state = Nif.get_master_state(data.master_ref)

      slaves =
        for slave_position <- create_range(master_state.slaves_responding) do
          {:ok, slave_info} = Nif.master_get_slave(data.master_ref, slave_position)
          driver = driver_for_slave(slave_info.vendor_id, slave_info.product_code)

          slave_config =
            Nif.master_slave_config(
              data.master_ref,
              0,
              slave_position,
              slave_info.vendor_id,
              slave_info.product_code
            )

          # Start slave under DynamicSupervisor for proper supervision
          slave_child_spec = %{
            id: {Slave, slave_position},
            start:
              {Slave, :start_link,
               [self(), slave_position, driver, slave_config, slave_info.sync_count]},
            restart: :permanent,
            shutdown: 5000,
            type: :worker
          }

          {:ok, slave} = DynamicSupervisor.start_child(EtherCAT.SlaveSupervisor, slave_child_spec)

          slave
        end

      duration = System.monotonic_time() - start_time

      :telemetry.execute(
        [:ethercat, :master, :sync_slaves],
        %{duration: duration, count: length(slaves)},
        %{result: :success}
      )

      {:next_state, :synced, %{data | slaves: slaves}, [{:reply, from, {:ok, slaves}}]}
    rescue
      error ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:ethercat, :master, :sync_slaves],
          %{duration: duration},
          %{result: :error, error: inspect(error)}
        )

        Logger.error("Error syncing slaves: #{inspect(error)}")
        {:keep_state_and_data, [{:reply, from, {:error, :sync_failed}}]}
    end
  end

  def stale(:state_timeout, :update_master_state, data) do
    master_state = Nif.get_master_state(data.master_ref)
    require Logger
    Logger.debug("Master state (stale): #{inspect(master_state)}")

    if master_state.slaves_responding == length(data.slaves) and
         master_state.slaves_responding > 0 do
      {:next_state, :synced, data}
    else
      actions = [{:state_timeout, data.update_interval, :update_master_state}]
      {:keep_state_and_data, actions}
    end
  end

  def stale(event_type, event_content, data) do
    handle_unexpected(event_type, event_content, :stale, data)
  end

  # State: synced
  # Slaves are discovered and synchronized, ready for configuration

  def synced(:enter, _old_state, data) do
    :telemetry.execute([:ethercat, :master, :state], %{}, %{state: :synced})
    actions = [{:state_timeout, data.update_interval, :update_master_state}]
    {:keep_state_and_data, actions}
  end

  def synced(:cast, :start_cyclic_mode, data) do
    # Retrieve pending PDO entries from all domains, register them, and lock the domains
    Enum.each(data.domains, fn domain ->
      pending_entries = Domain.get_pdo_entries(domain)
      domain_ref = Domain.get_ref(domain)

      Logger.debug(
        "Registering PDO entries for domain: #{map_size(pending_entries)} slave configs"
      )

      # Register all pending PDO entries via NIF and build the registered entries map
      registered_entries =
        for {slave_config, pdo_entries} <- pending_entries,
            {name, {entry_type, entry_index, entry_subindex, entry_size}} <- pdo_entries do
          offset =
            Nif.slave_config_reg_pdo_entry(
              slave_config,
              name,
              entry_type,
              entry_index,
              entry_subindex,
              entry_size,
              domain_ref
            )

          Logger.debug(
            "  Registered #{name}: entry=0x#{Integer.to_string(entry_index, 16)}:#{entry_subindex}, offset=#{offset}, size=#{entry_size}, type=#{entry_type}"
          )

          {name, {offset, entry_size}}
        end
        |> Map.new()

      Logger.debug("Total entries registered: #{map_size(registered_entries)}")

      # Store the registered entries back in the domain and lock it
      Domain.store_and_lock_entries(domain, registered_entries)
    end)

    {:next_state, :operational, data}
  end

  # Gateway for Slave module operations - ensures only Master talks to NIF
  def synced({:call, from}, {:slave_operation, position, operation, args}, data) do
    result = execute_slave_operation(data.master_ref, position, operation, args)
    {:keep_state_and_data, [{:reply, from, result}]}
  end

  def synced({:call, from}, {:create_domain, name, interval}, data) do
    domain_ref = Nif.master_create_domain(data.master_ref, self(), interval)

    # Start domain under DynamicSupervisor for proper supervision
    domain_child_spec = %{
      id: name,
      start: {Domain, :start_link, [name, self(), domain_ref, interval]},
      restart: :permanent,
      shutdown: 5000,
      type: :worker
    }

    case DynamicSupervisor.start_child(EtherCAT.DomainSupervisor, domain_child_spec) do
      {:ok, domain_pid} ->
        # Update the domain accessor with the Domain process PID
        Nif.domain_set_pid(domain_ref, domain_pid)

        {:keep_state, %{data | domains: [domain_pid | data.domains]},
         [{:reply, from, domain_ref}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  def synced({:call, from}, :get_ref, data) do
    {:keep_state_and_data, [{:reply, from, data.master_ref}]}
  end

  def synced(:state_timeout, :update_master_state, data) do
    master_state = Nif.get_master_state(data.master_ref)
    Logger.debug("Master state (synced/ready): #{inspect(master_state)}")

    if master_state.slaves_responding == length(data.slaves) do
      actions = [{:state_timeout, data.update_interval, :update_master_state}]
      {:keep_state_and_data, actions}
    else
      # Slave count mismatch - network topology changed
      # Terminate existing slave processes before transitioning to stale
      Logger.warning(
        "Slave count mismatch: expected #{length(data.slaves)}, got #{master_state.slaves_responding}. Re-scanning bus."
      )

      # Gracefully terminate all slave processes
      Enum.each(data.slaves, fn slave_pid ->
        if Process.alive?(slave_pid) do
          GenServer.stop(slave_pid, :normal)
        end
      end)

      {:next_state, :stale, %{data | slaves: []}}
    end
  end

  def synced(event_type, event_content, data) do
    handle_unexpected(event_type, event_content, :synced, data)
  end

  # State: operational
  # Master is activated and running cyclic communication

  def operational(:enter, _old_state, data) do
    start_time = System.monotonic_time()

    :telemetry.execute([:ethercat, :master, :state], %{}, %{state: :operational})

    try do
      Nif.master_activate(data.master_ref)
      parent_pid = self()

      domain_resources =
        Enum.map(data.domains, fn domain ->
          Domain.get_ref(domain)
        end)

      task_pid =
        spawn_link(fn ->
          Nif.cyclic_task(parent_pid, data.master_ref, domain_resources, data.update_interval)
        end)

      duration = System.monotonic_time() - start_time

      :telemetry.execute(
        [:ethercat, :master, :activate],
        %{duration: duration},
        %{domains: length(data.domains), slaves: length(data.slaves)}
      )

      {:keep_state, %{data | task_pid: task_pid}, []}
    rescue
      error ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:ethercat, :master, :activate],
          %{duration: duration},
          %{result: :error, error: inspect(error)}
        )

        Logger.error("Error activating master: #{inspect(error)}")
        {:keep_state_and_data, []}
    end
  end

  def operational(:info, {:master_state_changed, master_state}, _data) do
    require Logger
    Logger.info("Master State Changed: #{inspect(master_state)}")
    {:keep_state_and_data, []}
  end

  def operational(:info, {_domain, :data_changed, _domain_data, data_changes}, _data) do
    require Logger
    Logger.debug("Data Changed: #{inspect(data_changes)}")
    {:keep_state_and_data, []}
  end

  def operational({:call, from}, :get_ref, data) do
    actions = [{:reply, from, data.master_ref}]
    {:keep_state_and_data, actions}
  end

  # Gateway for domain operations in operational state
  def operational({:call, from}, {:domain_set_value, domain_ref, name, value}, _data) do
    result = Nif.set_value(domain_ref, name, value)
    {:keep_state_and_data, [{:reply, from, result}]}
  end

  def operational({:call, from}, {:domain_get_value, domain_ref, name}, _data) do
    result =
      case Nif.get_value(domain_ref, name) do
        {:error, _} = error -> error
        value -> {:ok, value}
      end

    {:keep_state_and_data, [{:reply, from, result}]}
  end

  def operational({:call, from}, {:domain_subscribe, domain, pid, name}, _data) do
    result = Domain.subscribe(domain, pid, name)
    {:keep_state_and_data, [{:reply, from, result}]}
  end

  def operational(event_type, event_content, data) do
    handle_unexpected(event_type, event_content, :operational, data)
  end

  # Common catch-all handler for unexpected events
  defp handle_unexpected(event_type, event_content, state, _data) do
    Logger.warning("Unexpected event in state #{state}: #{inspect({event_type, event_content})}")
    {:keep_state_and_data, []}
  end

  # Handle EXIT messages from linked processes (slaves, domains, cyclic task)
  defp handle_exit(pid, reason, state, data) do
    cond do
      # Cyclic task exited
      pid == data.task_pid ->
        Logger.error("Cyclic task exited with reason: #{inspect(reason)} in state #{state}")

        if reason != :normal and reason != :shutdown do
          # Unexpected crash - transition to offline for safety
          Logger.warning("Cyclic task crashed unexpectedly, transitioning to offline")
          {:next_state, :offline, %{data | task_pid: nil}}
        else
          {:keep_state, %{data | task_pid: nil}}
        end

      # Domain exited
      pid in data.domains ->
        Logger.warning("Domain #{inspect(pid)} exited with reason: #{inspect(reason)} in state #{state}")
        # Remove from domains list - supervisor will restart it if needed
        {:keep_state, %{data | domains: List.delete(data.domains, pid)}}

      # Slave exited
      pid in data.slaves ->
        Logger.warning("Slave #{inspect(pid)} exited with reason: #{inspect(reason)} in state #{state}")
        # Remove from slaves list - may need to resync
        {:keep_state, %{data | slaves: List.delete(data.slaves, pid)}}

      true ->
        Logger.debug("Unknown process #{inspect(pid)} exited with reason: #{inspect(reason)}")
        :keep_state_and_data
    end
  end

  # Executes slave operations by routing them to appropriate NIF functions
  defp execute_slave_operation(master_ref, position, operation, args) do
    case operation do
      # Introspection operations
      :get_sync_manager ->
        [sync_index] = args
        Nif.master_get_sync_manager(master_ref, position, sync_index)

      :get_pdo ->
        [sync_index, pdo_pos] = args
        Nif.master_get_pdo(master_ref, position, sync_index, pdo_pos)

      :get_pdo_entry ->
        [sync_index, pdo_pos, entry_pos] = args
        Nif.master_get_pdo_entry(master_ref, position, sync_index, pdo_pos, entry_pos)

      :slave_config ->
        [alias_val, vendor_id, product_code] = args
        Nif.master_slave_config(master_ref, alias_val, position, vendor_id, product_code)

      # Configuration operations (must be called before activation)
      :config_sync_manager ->
        [slave_config, sync_index, direction, watchdog] = args
        Nif.slave_config_sync_manager(slave_config, sync_index, direction, watchdog)

      :config_pdo_assign_clear ->
        [slave_config, sync_index] = args
        Nif.slave_config_pdo_assign_clear(slave_config, sync_index)

      :config_pdo_assign_add ->
        [slave_config, sync_index, pdo_index] = args
        Nif.slave_config_pdo_assign_add(slave_config, sync_index, pdo_index)

      :config_pdo_mapping_clear ->
        [slave_config, pdo_index] = args
        Nif.slave_config_pdo_mapping_clear(slave_config, pdo_index)

      :config_pdo_mapping_add ->
        [slave_config, pdo_index, entry_index, entry_subindex, entry_size] = args

        Nif.slave_config_pdo_mapping_add(
          slave_config,
          pdo_index,
          entry_index,
          entry_subindex,
          entry_size
        )

      _ ->
        {:error, {:unknown_operation, operation}}
    end
  end

  # Determines which driver to use for a slave based on vendor ID and product code.
  # Currently returns Generic driver for all devices. In the future, this can be
  # extended to support device-specific drivers.
  defp driver_for_slave(_vendor_id, _product_code) do
    EtherCAT.Drivers.Generic
  end
end
