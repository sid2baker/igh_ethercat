defmodule EtherCAT.Master do
  @moduledoc """
  GenStatem managing EtherCAT network lifecycle: offline → stale → synced → operational.
  """
  @behaviour :gen_statem
  require Logger
  import EtherCAT.Utils

  alias EtherCAT.{Nif, Slave, Domain}

  defstruct [
    :master_ref,
    :master_index,
    :slaves,
    :domains,
    :task_pid,
    :scan_interval,
    :scan_timer,
    :cycle_interval,
    :nif_yield_interval,
    :current_system,
    :slave_fingerprint,
    :fingerprint_stable_since,
    :fingerprint_change_threshold,
    :pending_caller,
    slaves_operational?: false
  ]

  @type domain_info :: %{name: atom(), ref: reference()}

  @type t :: %__MODULE__{
          master_ref: reference(),
          master_index: non_neg_integer(),
          slaves: [Slave.t()],
          # Map of pid => %{name: atom, ref: reference}
          domains: %{pid() => domain_info()},
          task_pid: pid() | nil,
          # Hardware change detection interval in microseconds
          scan_interval: integer(),
          # Timer reference for hardware scanning
          scan_timer: reference() | nil,
          # PDO cyclic update interval (set when going operational)
          cycle_interval: integer() | nil,
          # NIF yielding interval (set when going operational)
          nif_yield_interval: integer() | nil,
          # Currently loaded System PID (only one at a time)
          current_system: pid() | nil,
          # Hardware fingerprint (slave count for now)
          slave_fingerprint: non_neg_integer() | nil,
          # Timestamp when current fingerprint became stable (monotonic milliseconds)
          fingerprint_stable_since: integer() | nil,
          # How long fingerprint must be stable before generating config (milliseconds)
          fingerprint_change_threshold: pos_integer(),
          # Caller waiting for start_cyclic_mode to complete (slaves reach OP)
          pending_caller: :gen_statem.from() | nil,
          # True when at least one slave has reached OP state (PDO communication ready)
          slaves_operational?: boolean()
        }

  # Client API

  @doc "Child spec for supervision."
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
  Starts master process in `:offline` state.

  ## Options
  - `:master_index` - EtherCAT master index (default: 0)
  - `:scan_interval` - Hardware change detection interval in microseconds (default: 100_000 = 100ms)
  - `:fingerprint_change_threshold` - How long hardware must be stable before regenerating config in ms (default: 2_000)
  - `:name` - Registered process name (default: `EtherCAT.Master`)
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) do
    master_index = Keyword.get(opts, :master_index, 0)
    scan_interval = Keyword.get(opts, :scan_interval, 100_000)
    fingerprint_change_threshold = Keyword.get(opts, :fingerprint_change_threshold, 2_000)
    name = Keyword.get(opts, :name, __MODULE__)

    :gen_statem.start_link(
      {:local, name},
      __MODULE__,
      {master_index, scan_interval, fingerprint_change_threshold},
      []
    )
  end

  @doc """
  Safely stops the master and cleans up all resources.

  This will:
  - Stop the cyclic task (if running)
  - Terminate all linked domains and slaves
  - Release the EtherCAT master resource

  The process terminates normally via OTP's supervision tree.

  Returns `:ok` even if the process is already dead (idempotent).
  """
  @spec stop(GenServer.server(), timeout()) :: :ok
  def stop(master, timeout \\ 5000) do
    :gen_statem.stop(master, :normal, timeout)
  catch
    # Handle all variations of "process doesn't exist or is already stopping" exits:
    # Common exit patterns from :proc_lib.stop/3:
    :exit, :noproc ->
      :ok

    :exit, {:noproc, _} ->
      :ok

    :exit, {reason, _details} when reason == :noproc ->
      :ok

    :exit, :shutdown ->
      :ok

    :exit, {:shutdown, _} ->
      :ok

    :exit, :normal ->
      :ok

    :exit, reason ->
      # Catch-all for any other exit that indicates process is gone/stopping
      # This handles variations in :proc_lib.stop/3 error formats across OTP versions
      reason_str = inspect(reason)

      if String.contains?(reason_str, "noproc") or
           String.contains?(reason_str, "no process") or
           String.contains?(reason_str, "not alive") do
        :ok
      else
        # Unexpected exit - re-raise it
        exit(reason)
      end
  end

  @doc "Connects to EtherCAT network, transitions to `:stale`."
  @spec connect(GenServer.server(), timeout()) :: :ok | {:error, term()}
  def connect(master, timeout \\ 5000) do
    :gen_statem.call(master, :connect, timeout)
  end

  @doc """
  Syncs slaves with the given configuration.

  This validates the config against detected hardware, syncs slaves if valid,
  and transitions from :stale to :synced. This is the primary way to configure
  a Master.

  ## Parameters
  - `master` - Master PID or name
  - `config` - HardwareConfig struct to validate and sync with
  - `timeout` - Call timeout in milliseconds

  ## Returns
  - `{:ok, slaves}` - List of synced slave PIDs
  - `{:error, :hardware_not_stable}` - Hardware fingerprint not stable yet
  - `{:error, {:slave_count_mismatch, ...}}` - Wrong number of slaves
  - `{:error, {:hardware_mismatch, ...}}` - Vendor/product mismatch
  - `{:error, reason}` - Other sync error

  ## Example

      config = MyMachine.hardware_config()
      {:ok, slaves} = Master.sync_with_config(master, config)
  """
  @spec sync_with_config(GenServer.server(), EtherCAT.Config.HardwareConfig.t(), timeout()) ::
          {:ok, [pid()]} | {:error, term()}
  def sync_with_config(master, config, timeout \\ 10_000) do
    :gen_statem.call(master, {:sync_with_config, config}, timeout)
  end

  @doc """
  Gets list of all slave PIDs.

  Only works in :synced or :operational states. Returns error in :stale.
  """
  @spec get_slaves(GenServer.server(), timeout()) :: {:ok, [pid()]} | {:error, term()}
  def get_slaves(master, timeout \\ 10_000) do
    :gen_statem.call(master, :get_slaves, timeout)
  end

  @doc """
  Generates HardwareConfig by introspecting connected slaves.

  Used for hardware discovery mode. Master must be in synced or operational state.

  ## Returns
  - `{:ok, config}` - Generated HardwareConfig with detected slaves
  - `{:error, reason}` - Master not synced or error reading slave info
  """
  @spec generate_config(GenServer.server(), timeout()) ::
          {:ok, EtherCAT.Config.HardwareConfig.t()} | {:error, term()}
  def generate_config(master, timeout \\ 10_000) do
    alias EtherCAT.Config.{HardwareConfig, MasterConfig, DomainConfig, SlaveConfig}

    with {:ok, slaves} <- get_slaves(master, timeout) do
      slave_configs =
        Enum.map(slaves, fn slave_pid ->
          info = Slave.get_info(slave_pid)

          %SlaveConfig{
            position: info.position,
            name: :"slave_#{info.position}",
            driver: nil,
            # TODO: Auto-detect driver from vendor/product
            expected: %{
              vendor: info.vendor_id,
              product: info.product_code
            },
            config: %{},
            entries: []
          }
        end)

      config = %HardwareConfig{
        master: %MasterConfig{
          index: 0,
          cycle_interval: 10_000,
          nif_yield_interval: 100_000
        },
        domains: [%DomainConfig{name: :default_domain, interval: 1}],
        slaves: slave_configs
      }

      {:ok, config}
    end
  end

  @doc "Creates domain with independent update interval."
  @spec create_domain(GenServer.server(), atom(), pos_integer(), timeout()) ::
          {:ok, reference()} | {:error, term()}
  def create_domain(master, name, interval, timeout \\ 5000) do
    :gen_statem.call(master, {:create_domain, name, interval}, timeout)
  end

  @doc """
  Activates cyclic mode, transitions to `:operational`. Configuration locked.

  This is a synchronous operation that blocks until the master has:
  - Registered all PDO entries with the NIF
  - Locked all domains
  - Locked all slaves
  - Transitioned to operational state

  The system is ready for I/O operations when this function returns.

  ## Parameters
  - `master` - Master process
  - `cycle_interval` - PDO cyclic update interval in microseconds (from configuration)
  - `nif_yield_interval` - NIF scheduler yielding interval in microseconds (from configuration)
  - `timeout` - Call timeout (default: 30_000ms)
  """
  @spec start_cyclic_mode(GenServer.server(), pos_integer(), pos_integer(), timeout()) ::
          :ok | {:error, term()}
  def start_cyclic_mode(master, cycle_interval, nif_yield_interval, timeout \\ 30_000) do
    :gen_statem.call(master, {:start_cyclic_mode, cycle_interval, nif_yield_interval}, timeout)
  end

  @doc """
  Stop cyclic mode and return to synced state.

  Stops the cyclic task, deactivates the master, and transitions back to synced state.
  The master can then be reconfigured with a new system.

  ## Parameters
  - `master` - Master process
  - `timeout` - Call timeout (default: 10_000ms)
  """
  @spec stop_cyclic_mode(GenServer.server(), timeout()) :: :ok | {:error, term()}
  def stop_cyclic_mode(master, timeout \\ 10_000) do
    :gen_statem.call(master, :stop_cyclic_mode, timeout)
  end

  @doc "Gets master NIF reference for internal use."
  @spec get_ref(GenServer.server(), timeout()) :: reference()
  def get_ref(master, timeout \\ 5000) do
    :gen_statem.call(master, :get_ref, timeout)
  end

  @doc """
  Register a System with the Master.

  Stores the System struct for later retrieval.
  Called by System when created via configure_hardware.
  """
  @spec register_system(GenServer.server(), EtherCAT.System.t(), timeout()) :: :ok
  def register_system(master, system, timeout \\ 5000) do
    :gen_statem.call(master, {:register_system, system}, timeout)
  end

  @doc """
  Unregister the current System from the Master.

  Clears the current_system reference.
  Called by System when stopped via stop_system.
  """
  @spec unregister_system(GenServer.server(), timeout()) :: :ok
  def unregister_system(master, timeout \\ 5000) do
    :gen_statem.call(master, :unregister_system, timeout)
  end

  @doc """
  Get the currently loaded System struct (if any).

  Returns `{:ok, nil}` if no system is loaded, `{:ok, system}` if a system is loaded.
  """
  @spec get_current_system(GenServer.server(), timeout()) ::
          {:ok, EtherCAT.System.t() | nil} | {:error, term()}
  def get_current_system(master, timeout \\ 5000) do
    :gen_statem.call(master, :get_current_system, timeout)
  end

  # Internal API - called by Slave and Domain modules
  # These functions serve as the single gateway for all NIF operations,
  # preventing race conditions by ensuring only Master talks to the NIF.

  @doc false
  def slave_operation(master, position, operation, args, timeout \\ 5000) do
    :gen_statem.call(master, {:slave_operation, position, operation, args}, timeout)
  end

  @doc false
  def domain_set_value(master, domain_pid, name, value, timeout \\ 5000) do
    :gen_statem.call(master, {:domain_set_value, domain_pid, name, value}, timeout)
  end

  @doc false
  def domain_get_value(master, domain_pid, name, timeout \\ 5000) do
    :gen_statem.call(master, {:domain_get_value, domain_pid, name}, timeout)
  end

  @doc false
  def domain_subscribe(master, domain, pid, name, timeout \\ 5000) do
    :gen_statem.call(master, {:domain_subscribe, domain, pid, name}, timeout)
  end

  @doc false
  def domain_unsubscribe(master, domain, pid, name, timeout \\ 5000) do
    :gen_statem.call(master, {:domain_unsubscribe, domain, pid, name}, timeout)
  end

  # Callbacks
  @impl true
  def callback_mode(), do: [:state_functions, :state_enter]

  @impl true
  def init({master_index, scan_interval, fingerprint_change_threshold}) do
    # Trap exits to ensure graceful cleanup
    Process.flag(:trap_exit, true)

    case Nif.request_master(master_index) do
      {:ok, ref} ->
        # Register this master in the Registry for process discovery
        case Registry.register(EtherCAT.Registry, {:master, master_index}, %{
               master_index: master_index,
               scan_interval: scan_interval,
               fingerprint_change_threshold: fingerprint_change_threshold
             }) do
          {:ok, _} ->
            :ok

          {:error, {:already_registered, _pid}} ->
            Logger.warning(
              "Master #{master_index} already registered, this instance will not be discoverable via Registry"
            )
        end

        # DO NOT create default domain - domains created during configure_hardware
        data = %__MODULE__{
          master_ref: ref,
          master_index: master_index,
          domains: %{},
          slaves: [],
          task_pid: nil,
          scan_interval: scan_interval,
          scan_timer: nil,
          cycle_interval: nil,
          nif_yield_interval: nil,
          current_system: nil,
          slave_fingerprint: nil,
          fingerprint_stable_since: nil,
          fingerprint_change_threshold: fingerprint_change_threshold,
          pending_caller: nil,
          slaves_operational?: false
        }

        Logger.info("EtherCAT Master #{master_index} initialized (infrastructure only)")

        # Auto-connect on startup
        {:ok, :offline, data, [{:next_event, :internal, :auto_connect}]}

      :error ->
        Logger.error("Failed to create EtherCAT master #{master_index}")
        {:stop, :failed_to_create_master}
    end
  end

  @impl true
  def terminate(reason, _state, %{task_pid: task_pid} = _data) do
    Logger.info("EtherCAT Master terminating: #{inspect(reason)}")
    # All linked processes (slaves, domains, cyclic task) will automatically
    # receive exit signals and terminate when this process terminates
    if task_pid do
      # task_pid needs to be terminated with :kill, otherwise beam.yield doesn't work
      # look at https://github.com/E-xyza/zigler/issues/571 for more information
      Process.exit(task_pid, :kill)

      # FIX H5: Add timeout handling to prevent deadlocks
      # Wait for BOTH messages (order is non-deterministic)
      # NIF sends :cyclic_task_died before task exits, but EXIT signal timing varies
      results =
        for _ <- 1..2 do
          receive do
            {:EXIT, ^task_pid, _exit_reason} -> :exit_received
            :cyclic_task_died -> :died_received
          after
            3000 ->
              Logger.error("Timeout waiting for cyclic task termination message")
              :timeout
          end
        end

      # Verify we got both required messages
      unless :exit_received in results and :died_received in results do
        Logger.error("Incomplete cyclic task shutdown - received: #{inspect(results)}")
      end
    end

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

  def offline(:internal, :auto_connect, data) do
    Logger.info("Auto-connecting to EtherCAT master #{data.master_index}")

    case Nif.get_master_state(data.master_ref) do
      {:ok, master_state} when master_state.link_up == 1 ->
        Logger.info("Master connected, transitioning to :stale")
        {:next_state, :stale, data}

      {:ok, _master_state} ->
        # Link down, retry after scan_interval
        Logger.warning("Master link down, will retry")
        {:keep_state_and_data, [{:state_timeout, data.scan_interval, :auto_connect}]}

      {:error, reason} ->
        Logger.error("Failed to connect: #{inspect(reason)}")
        {:keep_state_and_data, [{:state_timeout, data.scan_interval, :auto_connect}]}
    end
  end

  def offline(:state_timeout, :auto_connect, data) do
    # Retry connection
    offline(:internal, :auto_connect, data)
  end

  def offline({:call, from}, :connect, data) do
    start_time = System.monotonic_time()

    case Nif.get_master_state(data.master_ref) do
      {:ok, master_state} ->
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

      {:error, reason} ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:ethercat, :master, :connect],
          %{duration: duration},
          %{result: :error, error: inspect(reason)}
        )

        Logger.error("Error connecting master: #{inspect(reason)}")
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
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
  # Network is up, monitoring hardware fingerprint for stability

  def stale(:enter, _old_state, data) do
    :telemetry.execute([:ethercat, :master, :state], %{}, %{state: :stale})

    # Initialize fingerprint immediately when entering :stale
    # This allows sync_with_config to be called without waiting for first scan
    case Nif.get_master_state(data.master_ref) do
      {:ok, master_state} ->
        current_fingerprint = master_state.slaves_responding
        now = System.monotonic_time(:millisecond)

        new_data = %{
          data
          | slave_fingerprint: current_fingerprint,
            fingerprint_stable_since: now
        }

        actions = [{:state_timeout, data.scan_interval, :update_master_state}]
        {:keep_state, new_data, actions}

      {:error, reason} ->
        Logger.warning("Failed to initialize fingerprint in :stale: #{inspect(reason)}")
        actions = [{:state_timeout, data.scan_interval, :update_master_state}]
        {:keep_state_and_data, actions}
    end
  end

  def stale({:call, from}, :get_slaves, _data) do
    # Master is not yet synced, return error
    {:keep_state_and_data, [{:reply, from, {:error, :not_synced_yet}}]}
  end

  def stale({:call, from}, :get_current_system, _data) do
    # No system can exist in :stale state (not yet configured)
    {:keep_state_and_data, [{:reply, from, {:ok, nil}}]}
  end

  def stale({:call, from}, {:sync_with_config, config}, data) do
    start_time = System.monotonic_time()

    with {:ok, master_state} <- Nif.get_master_state(data.master_ref),
         {:ok, updated_data} <- ensure_hardware_stable(data, master_state),
         :ok <- validate_config_matches_hardware(config, master_state),
         {:ok, slaves} <- sync_all_slaves(data.master_ref, master_state.slaves_responding) do
      duration = System.monotonic_time() - start_time

      :telemetry.execute(
        [:ethercat, :master, :slaves_synced],
        %{duration: duration, count: length(slaves)},
        %{result: :success}
      )

      Logger.info(
        "Synced #{length(slaves)} slaves with config in #{duration}µs, transitioning to :synced"
      )

      {:next_state, :synced, %{updated_data | slaves: slaves}, [{:reply, from, {:ok, slaves}}]}
    else
      {:error, reason} = error ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:ethercat, :master, :slaves_synced],
          %{duration: duration},
          %{result: :error, error: inspect(reason)}
        )

        Logger.warning("Failed to sync slaves with config: #{inspect(reason)}")
        {:keep_state_and_data, [{:reply, from, error}]}
    end
  end

  def stale(:state_timeout, :update_master_state, data) do
    case Nif.get_master_state(data.master_ref) do
      {:ok, master_state} ->
        Logger.debug("Master state (stale): #{inspect(master_state)}")

        # Create fingerprint from slave count
        current_fingerprint = master_state.slaves_responding
        now = System.monotonic_time(:millisecond)

        # Track fingerprint changes, but don't auto-transition to :synced
        # User must call sync_with_config to validate and sync
        if data.slave_fingerprint != current_fingerprint do
          Logger.debug(
            "Hardware fingerprint changed: #{data.slave_fingerprint} -> #{current_fingerprint}"
          )

          new_data = %{
            data
            | slave_fingerprint: current_fingerprint,
              fingerprint_stable_since: now
          }

          actions = [{:state_timeout, data.scan_interval, :update_master_state}]
          {:keep_state, new_data, actions}
        else
          # Fingerprint unchanged, continue monitoring
          actions = [{:state_timeout, data.scan_interval, :update_master_state}]
          {:keep_state_and_data, actions}
        end

      {:error, reason} ->
        Logger.warning("Failed to get master state in stale: #{inspect(reason)}")
        actions = [{:state_timeout, data.scan_interval, :update_master_state}]
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

    # Slaves are already synced via sync_with_config call or already exist from :operational
    # Just set up monitoring
    Logger.debug("Entering synced state with #{length(data.slaves)} slaves")
    actions = [{:state_timeout, data.scan_interval, :update_master_state}]
    {:keep_state_and_data, actions}
  end

  def synced({:call, from}, {:sync_with_config, config}, data) do
    # Reconfiguration: terminate old slaves and sync with new config
    start_time = System.monotonic_time()

    Logger.info("Reconfiguring: terminating #{length(data.slaves)} existing slaves")

    # Terminate existing slaves
    Enum.each(data.slaves, fn slave_pid ->
      if Process.alive?(slave_pid) do
        GenServer.stop(slave_pid, :normal)
      end
    end)

    # Now validate and sync with new config
    with {:ok, master_state} <- Nif.get_master_state(data.master_ref),
         {:ok, updated_data} <- ensure_hardware_stable(data, master_state),
         :ok <- validate_config_matches_hardware(config, master_state),
         {:ok, slaves} <- sync_all_slaves(data.master_ref, master_state.slaves_responding) do
      duration = System.monotonic_time() - start_time

      :telemetry.execute(
        [:ethercat, :master, :slaves_synced],
        %{duration: duration, count: length(slaves)},
        %{result: :success, reconfiguration: true}
      )

      Logger.info(
        "Reconfigured with #{length(slaves)} slaves in #{duration}µs"
      )

      {:keep_state, %{updated_data | slaves: slaves}, [{:reply, from, {:ok, slaves}}]}
    else
      {:error, reason} = error ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:ethercat, :master, :slaves_synced],
          %{duration: duration},
          %{result: :error, error: inspect(reason), reconfiguration: true}
        )

        Logger.warning("Failed to reconfigure with new config: #{inspect(reason)}")
        # Leave data.slaves empty after terminating old ones - user must fix config and retry
        {:keep_state, %{data | slaves: []}, [{:reply, from, error}]}
    end
  end

  def synced({:call, from}, {:start_cyclic_mode, cycle_interval, nif_yield_interval}, data) do
    Logger.info(
      "Starting cyclic mode - cycle: #{cycle_interval}µs, yield: #{nif_yield_interval}µs - locking #{map_size(data.domains)} domains and #{length(data.slaves)} slaves"
    )

    # Retrieve pending PDO entries from all domains, register them, and lock the domains
    # We iterate over the domains map which already contains the refs
    result =
      Enum.reduce_while(data.domains, :ok, fn {domain_pid, domain_info}, :ok ->
        pending_entries = Domain.get_pdo_entries(domain_pid)
        domain_ref = domain_info.ref

        Logger.debug(
          "Registering PDO entries for domain: #{map_size(pending_entries)} slave configs"
        )

        # Register all pending PDO entries via NIF and build the registered entries map
        # Entries are 4-tuples: {index, subindex, size, direction}
        # Domain doesn't need type info - that's handled by Slave for encoding/decoding
        registered_entries =
          for {slave_config, pdo_entries} <- pending_entries,
              {name, {entry_index, entry_subindex, entry_size, direction}} <- pdo_entries do
            # Infer type for NIF registration

            offset =
              Nif.slave_config_reg_pdo_entry(
                slave_config,
                name,
                entry_index,
                entry_subindex,
                entry_size,
                domain_ref,
                direction
              )

            Logger.debug(
              "  Registered #{name}: entry=0x#{Integer.to_string(entry_index, 16)}:#{entry_subindex}, offset=#{offset}, size=#{entry_size}, direction=#{direction}"
            )

            {name, {offset, entry_size}}
          end
          |> Map.new()

        Logger.debug("Total entries registered: #{map_size(registered_entries)}")

        # Store the registered entries back in the domain and lock it
        Logger.debug("Locking domain with #{map_size(registered_entries)} entries")

        case Domain.store_and_lock_entries(domain_pid, registered_entries) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:domain_lock_failed, reason}}}
        end
      end)

    case result do
      :ok ->
        Logger.info("All domains locked, now locking #{length(data.slaves)} slaves")

        # Lock all slaves to prevent further configuration changes
        Enum.each(data.slaves, fn slave ->
          Slave.lock(slave)
        end)

        Logger.info("Cyclic mode activation complete, transitioning to :operational")
        # DON'T reply yet - store caller and reply when slaves reach OP state
        # Store operational parameters in state
        updated_data = %{
          data
          | pending_caller: from,
            cycle_interval: cycle_interval,
            nif_yield_interval: nif_yield_interval
        }

        {:next_state, :operational, updated_data, []}

      {:error, _reason} = error ->
        Logger.error("Failed to start cyclic mode: #{inspect(error)}")
        {:keep_state_and_data, [{:reply, from, error}]}
    end
  end

  def synced({:call, from}, :stop_cyclic_mode, _data) do
    # Already in synced state (not operational), nothing to stop
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  # Gateway for Slave module operations - ensures only Master talks to NIF
  def synced({:call, from}, {:slave_operation, position, operation, args}, data) do
    result = execute_slave_operation(data.master_ref, position, operation, args)
    {:keep_state_and_data, [{:reply, from, result}]}
  end

  def synced({:call, from}, {:create_domain, name, interval}, data) do
    case do_create_domain(data.master_ref, name, interval) do
      {:ok, domain_ref, domain_pid} ->
        updated_domains = Map.put(data.domains, domain_pid, %{name: name, ref: domain_ref})
        {:keep_state, %{data | domains: updated_domains}, [{:reply, from, {:ok, domain_ref}}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  def synced({:call, from}, :get_ref, data) do
    {:keep_state_and_data, [{:reply, from, data.master_ref}]}
  end

  def synced({:call, from}, :get_slaves, data) do
    {:keep_state_and_data, [{:reply, from, {:ok, data.slaves}}]}
  end

  def synced({:call, from}, {:register_system, system}, data) do
    new_data = %{data | current_system: system}
    {:keep_state, new_data, [{:reply, from, :ok}]}
  end

  def synced({:call, from}, :unregister_system, data) do
    new_data = %{data | current_system: nil}
    {:keep_state, new_data, [{:reply, from, :ok}]}
  end

  def synced({:call, from}, :get_current_system, data) do
    {:keep_state_and_data, [{:reply, from, {:ok, data.current_system}}]}
  end

  def synced(:state_timeout, :update_master_state, data) do
    case Nif.get_master_state(data.master_ref) do
      {:ok, master_state} ->
        Logger.debug("Master state (synced/ready): #{inspect(master_state)}")

        current_fingerprint = master_state.slaves_responding
        now = System.monotonic_time(:millisecond)

        cond do
          # Fingerprint changed - reset stability timer
          data.slave_fingerprint != current_fingerprint ->
            Logger.warning(
              "Hardware fingerprint changed: #{data.slave_fingerprint} -> #{current_fingerprint}"
            )

            new_data = %{
              data
              | slave_fingerprint: current_fingerprint,
                fingerprint_stable_since: now
            }

            actions = [{:state_timeout, data.scan_interval, :update_master_state}]
            {:keep_state, new_data, actions}

          # Fingerprint same and matches current slaves - hardware stable
          current_fingerprint == length(data.slaves) ->
            actions = [{:state_timeout, data.scan_interval, :update_master_state}]
            {:keep_state_and_data, actions}

          # Fingerprint stable but different - check threshold then notify
          true ->
            stable_duration = now - (data.fingerprint_stable_since || now)

            if stable_duration >= data.fingerprint_change_threshold do
              # Hardware has been stable with different count for threshold duration
              Logger.warning(
                "Hardware change stable for #{stable_duration}ms: #{length(data.slaves)} -> #{current_fingerprint} slaves"
              )

              # Clear current system on hardware change
              if data.current_system do
                Logger.info("Hardware changed, clearing current system")
              end

              # Terminate existing slaves and transition to stale for re-scan
              Enum.each(data.slaves, fn slave_pid ->
                if Process.alive?(slave_pid) do
                  GenServer.stop(slave_pid, :normal)
                end
              end)

              {:next_state, :stale, %{data | slaves: [], current_system: nil}}
            else
              # Not stable long enough yet - keep waiting
              actions = [{:state_timeout, data.scan_interval, :update_master_state}]
              {:keep_state_and_data, actions}
            end
        end

      {:error, reason} ->
        Logger.warning("Failed to get master state in synced: #{inspect(reason)}")
        actions = [{:state_timeout, data.scan_interval, :update_master_state}]
        {:keep_state_and_data, actions}
    end
  end

  def synced(event_type, event_content, data) do
    handle_unexpected(event_type, event_content, :synced, data)
  end

  # State: operational
  # Master is activated and running cyclic communication

  def operational(:enter, _old_state, data) do
    Logger.info("Master entered :operational state - system ready for I/O")
    start_time = System.monotonic_time()

    :telemetry.execute([:ethercat, :master, :state], %{}, %{state: :operational})

    case Nif.master_activate(data.master_ref) do
      :ok ->
        parent_pid = self()

        # Extract domain refs from the domains map
        # This avoids making synchronous calls during state transition
        domain_resources =
          data.domains
          |> Map.values()
          |> Enum.map(& &1.ref)

        task_pid =
          spawn_link(fn ->
            Nif.cyclic_task(
              parent_pid,
              data.master_ref,
              domain_resources,
              data.cycle_interval,
              data.nif_yield_interval
            )
          end)

        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:ethercat, :master, :activate],
          %{duration: duration},
          %{domains: map_size(data.domains), slaves: length(data.slaves)}
        )

        # Check if slaves are already in OP state (fast transition case)
        case Nif.get_master_state(data.master_ref) do
          {:ok, state} when state.al_state_op > 0 ->
            Logger.info("Slaves already in operational state - PDO communication ready")

            # Reply immediately to pending caller
            actions =
              if data.pending_caller do
                [{:reply, data.pending_caller, :ok}]
              else
                []
              end

            {:keep_state,
             %{data | task_pid: task_pid, slaves_operational?: true, pending_caller: nil},
             actions}

          _ ->
            Logger.debug("Waiting for slaves to reach operational state...")

            # Set timeout - slaves should reach OP within 10 seconds
            {:keep_state, %{data | task_pid: task_pid, slaves_operational?: false},
             [{:state_timeout, 10_000, :slave_op_timeout}]}
        end

      {:error, reason} ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:ethercat, :master, :activate],
          %{duration: duration},
          %{result: :error, error: inspect(reason)}
        )

        Logger.error("Error activating master: #{inspect(reason)}")
        {:keep_state_and_data, []}
    end
  end

  def operational(:info, {:master_state_changed, master_state}, data) do
    require Logger
    Logger.info("Master State Changed: #{inspect(master_state)}")

    # Check if at least one slave has reached OP state (al_state_op > 0)
    # This indicates PDO communication is ready
    if master_state.al_state_op > 0 and not data.slaves_operational? do
      Logger.info("Slaves reached operational state - PDO communication ready")

      # Reply to pending caller if waiting
      actions =
        if data.pending_caller do
          Logger.info("Replying to start_cyclic_mode caller - system ready")
          [{:reply, data.pending_caller, :ok}, {:state_timeout, :cancel}]
        else
          [{:state_timeout, :cancel}]
        end

      {:keep_state, %{data | slaves_operational?: true, pending_caller: nil}, actions}
    else
      {:keep_state_and_data, []}
    end
  end

  def operational(:state_timeout, :slave_op_timeout, data) do
    Logger.error(
      "Timeout waiting for slaves to reach OP state - slaves may be misconfigured or hardware issue"
    )

    # Reply with error to pending caller
    actions =
      if data.pending_caller do
        [
          {:reply, data.pending_caller,
           {:error,
            {:slave_op_timeout,
             "Slaves did not reach operational state within 10 seconds. Check slave configuration and hardware connections."}}}
        ]
      else
        []
      end

    {:keep_state, %{data | pending_caller: nil}, actions}
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

  def operational({:call, from}, :get_slaves, data) do
    {:keep_state_and_data, [{:reply, from, {:ok, data.slaves}}]}
  end

  def operational({:call, from}, {:register_system, system}, data) do
    new_data = %{data | current_system: system}
    {:keep_state, new_data, [{:reply, from, :ok}]}
  end

  def operational({:call, from}, :unregister_system, data) do
    new_data = %{data | current_system: nil}
    {:keep_state, new_data, [{:reply, from, :ok}]}
  end

  def operational({:call, from}, :get_current_system, data) do
    {:keep_state_and_data, [{:reply, from, {:ok, data.current_system}}]}
  end

  def operational({:call, from}, :start_cyclic_mode, _data) do
    {:keep_state_and_data,
     [{:reply, from, {:error, {:already_operational, "Cyclic mode is already running"}}}]}
  end

  def operational({:call, from}, :stop_cyclic_mode, data) do
    Logger.info("Stopping cyclic mode - transitioning from operational to synced")

    case stop_cyclic_task(data.task_pid) do
      :ok ->
        Logger.info("Master deactivated successfully")

        # Transition back to synced state
        new_data = %{
          data
          | task_pid: nil,
            cycle_interval: nil,
            nif_yield_interval: nil,
            slaves_operational?: false,
            pending_caller: nil
        }

        {:next_state, :synced, new_data, [{:reply, from, :ok}]}

      {:error, reason} ->
        Logger.error("Failed to deactivate master: #{inspect(reason)}")
        {:keep_state_and_data, [{:reply, from, {:error, {:deactivate_failed, reason}}}]}
    end
  end

  # Gateway for domain operations in operational state
  # Domain identifies itself by PID; we look up its NIF reference
  def operational({:call, from}, {:domain_set_value, domain_pid, name, value}, data)
      when is_binary(value) do
    # Check if slaves have reached OP state before allowing PDO writes
    unless data.slaves_operational? do
      {:keep_state_and_data,
       [
         {:reply, from,
          {:error,
           {:slaves_not_operational,
            "Slaves are still transitioning to OP state. PDO communication not yet available."}}}
       ]}
    else
      case Map.get(data.domains, domain_pid) do
        nil ->
          {:keep_state_and_data, [{:reply, from, {:error, :domain_not_found}}]}

        domain_info ->
          result = Nif.set_value(domain_info.ref, name, value)
          {:keep_state_and_data, [{:reply, from, result}]}
      end
    end
  end

  def operational({:call, from}, {:domain_set_value, _domain_pid, name, value}, _data) do
    {:keep_state_and_data,
     [
       {:reply, from,
        {:error, {:invalid_value_type, name, "Expected binary, got: #{inspect(value)}"}}}
     ]}
  end

  def operational({:call, from}, {:domain_get_value, domain_pid, name}, data) do
    # Check if slaves have reached OP state before allowing PDO reads
    unless data.slaves_operational? do
      {:keep_state_and_data,
       [
         {:reply, from,
          {:error,
           {:slaves_not_operational,
            "Slaves are still transitioning to OP state. PDO communication not yet available."}}}
       ]}
    else
      case Map.get(data.domains, domain_pid) do
        nil ->
          {:keep_state_and_data, [{:reply, from, {:error, :domain_not_found}}]}

        domain_info ->
          result =
            case Nif.get_value(domain_info.ref, name) do
              {:error, _} = error -> error
              value -> {:ok, value}
            end

          {:keep_state_and_data, [{:reply, from, result}]}
      end
    end
  end

  def operational({:call, from}, {:domain_subscribe, domain, pid, name}, _data) do
    result = Domain.subscribe(domain, pid, name)
    {:keep_state_and_data, [{:reply, from, result}]}
  end

  def operational({:call, from}, {:domain_unsubscribe, domain, pid, name}, _data) do
    result = Domain.unsubscribe(domain, pid, name)
    {:keep_state_and_data, [{:reply, from, result}]}
  end

  def operational(event_type, event_content, data) do
    handle_unexpected(event_type, event_content, :operational, data)
  end

  # Helper to properly stop cyclic task
  #
  # The task must be killed with :kill (not :normal) due to beam.yield issue
  # See: https://github.com/E-xyza/zigler/issues/571
  #
  # We need to wait for BOTH messages (order is non-deterministic):
  # - NIF sends :cyclic_task_died before task exits
  # - Erlang sends {:EXIT, task_pid, _} when process dies
  defp stop_cyclic_task(nil), do: :ok

  defp stop_cyclic_task(task_pid) do
    # Kill the task (must use :kill due to beam.yield)
    Process.exit(task_pid, :kill)

    # Wait for BOTH termination messages (order is non-deterministic)
    results =
      for _ <- 1..2 do
        receive do
          {:EXIT, ^task_pid, _exit_reason} -> :exit_received
          :cyclic_task_died -> :died_received
        after
          3000 ->
            Logger.error("Timeout waiting for cyclic task termination message")
            :timeout
        end
      end

    if Enum.member?(results, :timeout) do
      Logger.warning("Cyclic task termination messages incomplete: #{inspect(results)}")
      {:error, :timeout}
    else
      :ok
    end
  end

  # Common catch-all handler for unexpected events
  defp handle_unexpected(event_type, event_content, state, _data) do
    Logger.warning("Unexpected event in state #{state}: #{inspect({event_type, event_content})}")
    {:keep_state_and_data, []}
  end

  # Helper to create domain with proper two-step initialization (avoids race condition)
  #
  # 1. Create domain resource via NIF (allocates native EtherCAT domain + accessor)
  # 2. Start Domain process (creates Elixir GenServer)
  # 3. Set PID in resource (NIF now knows where to send messages)
  #
  # Order is critical: if we set PID before the process starts, the NIF's cyclic
  # task might try to send messages to a non-existent process during race window.
  # The `with` statement ensures atomicity and proper cleanup on any error.
  #
  # Note: Domain no longer stores the NIF reference - Master maintains the mapping
  # of domain PID to reference in its domains map for single source of truth.
  defp do_create_domain(master_ref, name, interval) do
    with {:ok, domain_ref} <- Nif.master_create_domain(master_ref, self(), interval),
         {:ok, domain_pid} <-
           Domain.start_link(
             name: name,
             master: self(),
             interval: interval
           ),
         :ok <- Nif.domain_set_pid(domain_ref, domain_pid) do
      {:ok, domain_ref, domain_pid}
    end
  end

  # Validate hardware fingerprint is stable
  # Ensures hardware is stable, updating fingerprint tracking if it has changed
  defp ensure_hardware_stable(data, master_state) do
    current_fingerprint = master_state.slaves_responding
    now = System.monotonic_time(:millisecond)

    # Update tracking if fingerprint changed
    updated_data =
      if data.slave_fingerprint != current_fingerprint do
        Logger.debug(
          "Hardware fingerprint changed during sync: #{data.slave_fingerprint} -> #{current_fingerprint}, resetting stability timer"
        )

        %{data | slave_fingerprint: current_fingerprint, fingerprint_stable_since: now}
      else
        data
      end

    # Check if stable for required duration
    stable_duration = now - (updated_data.fingerprint_stable_since || now)

    if stable_duration >= data.fingerprint_change_threshold do
      {:ok, updated_data}
    else
      {:error,
       {:hardware_not_stable,
        "Hardware must be stable for #{data.fingerprint_change_threshold}ms, " <>
          "currently stable for #{stable_duration}ms"}}
    end
  end

  defp validate_hardware_stable(data, master_state) do
    current_fingerprint = master_state.slaves_responding
    now = System.monotonic_time(:millisecond)

    # Check if fingerprint matches what we've been tracking
    if data.slave_fingerprint != current_fingerprint do
      {:error, {:fingerprint_mismatch, "Hardware changed during sync attempt"}}
    else
      # Check if stable for required duration
      stable_duration = now - (data.fingerprint_stable_since || now)

      if stable_duration >= data.fingerprint_change_threshold do
        :ok
      else
        {:error,
         {:hardware_not_stable,
          "Hardware must be stable for #{data.fingerprint_change_threshold}ms, " <>
            "currently stable for #{stable_duration}ms"}}
      end
    end
  end

  # Validate config matches detected hardware
  defp validate_config_matches_hardware(config, %{master_ref: master_ref} = master_state) do
    detected_count = master_state.slaves_responding
    config_count = length(config.slaves)

    if detected_count != config_count do
      {:error,
       {:slave_count_mismatch,
        "Config expects #{config_count} slaves, but detected #{detected_count}"}}
    else
      # Validate each slave's vendor/product if specified
      config.slaves
      |> Enum.filter(& &1.expected)
      |> Enum.reduce_while(:ok, fn slave_config, :ok ->
        with {:ok, slave_info} <- Nif.master_get_slave(master_ref, slave_config.position) do
          cond do
            slave_config.expected.vendor &&
                slave_info.vendor_id != slave_config.expected.vendor ->
              {:halt,
               {:error,
                {:hardware_mismatch, slave_config.position,
                 "Expected vendor 0x#{Integer.to_string(slave_config.expected.vendor, 16)}, " <>
                   "but found 0x#{Integer.to_string(slave_info.vendor_id, 16)}"}}}

            slave_config.expected.product &&
                slave_info.product_code != slave_config.expected.product ->
              {:halt,
               {:error,
                {:hardware_mismatch, slave_config.position,
                 "Expected product 0x#{Integer.to_string(slave_config.expected.product, 16)}, " <>
                   "but found 0x#{Integer.to_string(slave_info.product_code, 16)}"}}}

            true ->
              {:cont, :ok}
          end
        else
          {:error, reason} ->
            {:halt, {:error, {:slave_info_read_failed, slave_config.position, reason}}}
        end
      end)
    end
  end

  # Helper to synchronize all slaves on the bus
  defp sync_all_slaves(master_ref, slave_count) do
    create_range(slave_count)
    |> Enum.reduce_while({:ok, []}, fn slave_position, {:ok, acc} ->
      case sync_single_slave(master_ref, slave_position) do
        {:ok, slave_pid} -> {:cont, {:ok, [slave_pid | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, slaves} -> {:ok, Enum.reverse(slaves)}
      error -> error
    end
  end

  # Helper to synchronize a single slave
  defp sync_single_slave(master_ref, slave_position) do
    with {:ok, slave_info} <- Nif.master_get_slave(master_ref, slave_position),
         {:ok, slave_config} <-
           Nif.master_slave_config(
             master_ref,
             0,
             slave_position,
             slave_info.vendor_id,
             slave_info.product_code
           ) do
      driver = driver_for_slave(slave_info.vendor_id, slave_info.product_code)

      Slave.start_link(
        master: self(),
        position: slave_position,
        driver: driver,
        slave_config: slave_config,
        sync_count: slave_info.sync_count,
        vendor_id: slave_info.vendor_id,
        product_code: slave_info.product_code,
        alias: slave_info.alias,
        revision: slave_info.revision_number,
        serial: slave_info.serial_number
      )
    end
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
      Map.has_key?(data.domains, pid) ->
        domain_info = data.domains[pid]

        Logger.warning(
          "Domain #{domain_info.name} (#{inspect(pid)}) exited with reason: #{inspect(reason)} in state #{state}"
        )

        # Remove from domains map - supervisor will restart it if needed
        {:keep_state, %{data | domains: Map.delete(data.domains, pid)}}

      # Slave exited
      pid in data.slaves ->
        Logger.warning(
          "Slave #{inspect(pid)} exited with reason: #{inspect(reason)} in state #{state}"
        )

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

      # SDO configuration operation (must be called before activation)
      :config_sdo ->
        [slave_config, sdo_index, sdo_subindex, data] = args
        Nif.slave_config_sdo(slave_config, sdo_index, sdo_subindex, data)

      _ ->
        {:error, {:unknown_operation, operation}}
    end
  end

  # Determines which driver to use for a slave based on vendor ID and product code.
  # Maps known Beckhoff devices to their specific drivers, falls back to Generic.
  defp driver_for_slave(0x02, 0x07113052), do: EtherCAT.Drivers.EL1809
  defp driver_for_slave(0x02, 0x0AF93052), do: EtherCAT.Drivers.EL2809
  defp driver_for_slave(0x02, 0x0C823052), do: EtherCAT.Drivers.EL3202
  defp driver_for_slave(_vendor_id, _product_code), do: EtherCAT.Drivers.Generic
end
