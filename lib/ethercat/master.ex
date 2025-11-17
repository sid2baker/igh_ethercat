defmodule EtherCAT.Master do
  @moduledoc """
  Simplified EtherCAT Master using gen_statem.

  ## State Machine

  ```
  :offline ──connect──> :stale ──stable──> :synced ──activate──> :operational
                           ↑                  ↓                        │
                           └──hardware_change─┘                        │
                           ↑                                            │
                           └────────────stop_cyclic────────────────────┘
  ```

  States:
  - `:offline` - No EtherCAT link, waiting for connection
  - `:stale` - Link up, monitoring hardware topology for stability
  - `:synced` - Hardware stable and verified, slave drivers running
  - `:operational` - Cyclic task active, real-time operation

  ## Simplified Architecture

  1. **Domains** - Just ref + interval (no entries/subscribers in domain)
  2. **Subscribers** - Stored in Master as `%{{slave_name, pdo, entry} => [pids]}`
  3. **Hardware tracking** - Expected config + actual + diff tree
  4. **Slaves** - Driver processes managed by Master

  ## Domain Structure

  ```elixir
  domains: %{
    domain_name => %{
      ref: reference(),
      interval: pos_integer()
    }
  }
  ```

  ## Subscriber Structure

  ```elixir
  subscribers: %{
    {domain_name, unique_name} => [pid, ...]
  }
  ```

  Where:
  - `domain_name` - Domain identifier (e.g., `:default_domain`)
  - `unique_name` - Full entry identifier (e.g., `"slave_0:pdo:entry"`)

  ## Hardware Diff Structure

  ```elixir
  %{
    type: :match | :mismatch | :partial_match,
    path: [atom()],
    changes: %{field => {expected, actual}},
    children: [diff_tree]
  }
  ```
  """

  @behaviour :gen_statem
  require Logger

  alias EtherCAT.Nif

  defstruct [
    :master_ref,
    :master_index,
    :slaves,
    :domains,
    :subscribers,
    :task_pid,
    :scan_interval,
    :stability_timeout,
    :hardware_config,
    :hardware_diff,
    :last_slave_count,
    :stability_timer_ref
  ]

  @type t :: %__MODULE__{
          master_ref: reference() | nil,
          master_index: non_neg_integer(),
          # Map of position => %{pid, name, vendor, product, driver, slave_config}
          # slave_config: NIF SlaveConfigResource owned by Master
          slaves: %{non_neg_integer() => map()},
          # Map of domain_name => %{ref, interval}
          domains: %{atom() => %{ref: reference(), interval: pos_integer()}},
          # Map of {domain_name, unique_name} => [subscriber_pids]
          subscribers: %{{atom(), String.t()} => [pid()]},
          task_pid: pid() | nil,
          # Hardware check interval in milliseconds (for state_timeout)
          scan_interval: pos_integer(),
          # How long hardware must be stable before :stale -> :synced (milliseconds)
          stability_timeout: pos_integer(),
          # Expected hardware configuration (required for :stale -> :synced)
          hardware_config: map() | nil,
          # Diff between expected and actual
          hardware_diff: map() | nil,
          # Last observed slave count (for change detection)
          last_slave_count: non_neg_integer() | nil,
          # Timer reference for stability monitoring
          stability_timer_ref: reference() | nil
        }

  # ============================================================================
  # Child Spec for Supervision
  # ============================================================================

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5000
    }
  end

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    :gen_statem.start_link({:local, __MODULE__}, __MODULE__, opts, [])
  end

  def get_slaves(master \\ __MODULE__) do
    :gen_statem.call(master, :get_slaves)
  end

  @doc """
  Create a new domain with the specified update interval.

  ## Parameters
  - `name` - Unique domain identifier (atom)
  - `interval_us` - Update interval in **microseconds**

  Note: If using DomainConfig, intervals are in milliseconds and automatically converted.
  """
  def create_domain(master \\ __MODULE__, name, interval_us) do
    :gen_statem.call(master, {:create_domain, name, interval_us})
  end

  def start_cyclic(master \\ __MODULE__, cycle_interval, nif_yield_interval) do
    :gen_statem.call(master, {:start_cyclic, cycle_interval, nif_yield_interval}, 30_000)
  end

  def stop_cyclic(master \\ __MODULE__) do
    :gen_statem.call(master, :stop_cyclic)
  end

  def read_pdo_entry(master \\ __MODULE__, domain_name, unique_name) do
    :gen_statem.call(master, {:read_pdo_entry, domain_name, unique_name})
  end

  def write_pdo_entry(master \\ __MODULE__, domain_name, unique_name, binary_data) do
    :gen_statem.call(master, {:write_pdo_entry, domain_name, unique_name, binary_data})
  end

  def subscribe(master \\ __MODULE__, domain_name, unique_name, subscriber_pid) do
    :gen_statem.call(master, {:subscribe, domain_name, unique_name, subscriber_pid})
  end

  def unsubscribe(master \\ __MODULE__, domain_name, unique_name, subscriber_pid) do
    :gen_statem.call(master, {:unsubscribe, domain_name, unique_name, subscriber_pid})
  end

  def get_sync_manager(master \\ __MODULE__, position, sync_index) do
    :gen_statem.call(master, {:get_sync_manager, position, sync_index})
  end

  def get_pdo(master \\ __MODULE__, position, sync_index, pdo_pos) do
    :gen_statem.call(master, {:get_pdo, position, sync_index, pdo_pos})
  end

  def get_pdo_entry(master \\ __MODULE__, position, sync_index, pdo_pos, entry_pos) do
    :gen_statem.call(master, {:get_pdo_entry, position, sync_index, pdo_pos, entry_pos})
  end

  def get_hardware_diff(master \\ __MODULE__) do
    :gen_statem.call(master, :get_hardware_diff)
  end

  @doc """
  Generate a hardware configuration from currently detected slaves.

  This is useful for discovering and documenting your hardware setup.

  ## Parameters
  - `master` - Master process (PID or module name)

  ## Returns
  - `{:ok, config}` - Generated HardwareConfig struct
  - `{:error, reason}` - Not yet synced or generation error
  """
  @spec generate_config(pid() | atom()) ::
          {:ok, EtherCAT.Config.HardwareConfig.t()} | {:error, term()}
  def generate_config(master \\ __MODULE__) do
    :gen_statem.call(master, :generate_config)
  end

  @doc """
  Set the hardware configuration and transition to :stale for verification.

  This function stores the hardware config and triggers the state machine to:
  1. Transition to :stale state
  2. Monitor hardware topology for stability
  3. Verify hardware matches the config
  4. Transition to :synced and start slave drivers
  5. Domains and PDOs will be configured when transitioning to :operational

  ## Parameters
  - `master` - Master process (PID or module name)
  - `config` - HardwareConfig struct with master, domains, and slaves

  ## Returns
  - `:ok` - Config stored, state machine will verify hardware
  - `{:error, reason}` - Configuration error
  """
  @spec set_hardware_config(pid() | atom(), EtherCAT.Config.HardwareConfig.t()) ::
          :ok | {:error, term()}
  def set_hardware_config(master \\ __MODULE__, config) do
    :gen_statem.call(master, {:set_hardware_config, config}, 30_000)
  end

  @doc """
  Get the current state of the master state machine.

  ## Returns
  - `:offline` | `:stale` | `:synced` | `:operational`
  """
  def get_state(master \\ __MODULE__) do
    :sys.get_state(master) |> elem(0)
  end

  @doc """
  Configure hardware and start cyclic communication (high-level API).

  This is a convenience function that:
  1. Sets the hardware config
  2. Waits for hardware to stabilize and sync (up to 10 seconds)
  3. Configures slaves and starts cyclic mode
  4. Returns slave PIDs

  ## Timeout Expectations

  - **Hardware stability**: Configurable via `stability_timeout` option (default: 1000ms = 1 second)
  - **State transition**: Max 10 seconds to reach :synced state
  - **Total timeout**: ~10 seconds + stability_timeout + activation time
  - For large systems (>10 slaves), consider using the low-level API for custom timeouts

  ## Configuration Options

  Master accepts these init options (in microseconds, converted internally):
  - `scan_interval`: Hardware polling interval (default: 100_000µs = 100ms)
  - `stability_timeout`: Required stable duration (default: 1_000_000µs = 1000ms)

  ## Parameters
  - `master` - Master process (PID or module name)
  - `config` - HardwareConfig struct

  ## Returns
  - `{:ok, %{slave_name => pid}}` - Map of slave names to driver PIDs
  - `{:error, {:timeout_waiting_for_state, :synced}}` - Hardware didn't stabilize in time
  - `{:error, reason}` - Configuration or verification error

  ## Examples

      # Quick setup (may timeout on slow hardware)
      {:ok, slaves} = Master.configure_and_activate(master, config)

      # Manual control for better timeout handling
      :ok = Master.set_hardware_config(master, config)
      # Monitor state with custom timeout...
      :ok = Master.start_cyclic(master, 10_000, 100_000)
      {:ok, slaves} = Master.get_slave_name_map(master)

  For more control, use `set_hardware_config/2`, monitor state transitions,
  and call `start_cyclic/3` manually.
  """
  @spec configure_and_activate(pid() | atom(), EtherCAT.Config.HardwareConfig.t()) ::
          {:ok, %{atom() => pid()}} | {:error, term()}
  def configure_and_activate(master \\ __MODULE__, config) do
    alias EtherCAT.Config.HardwareConfig

    with :ok <- HardwareConfig.validate(config),
         :ok <- set_hardware_config(master, config),
         :ok <- wait_for_state(master, :synced, 10_000),
         {:ok, _} <- configure_all_and_activate(master, config),
         {:ok, slave_map} <- get_slave_name_map(master) do
      {:ok, slave_map}
    end
  end

  @doc """
  Get a map of slave names to PIDs from the master's internal state.

  ## Returns
  - `{:ok, %{slave_name => pid}}` - Map of slave names to driver PIDs
  - `{:error, reason}` - Error retrieving slave map
  """
  def get_slave_name_map(master \\ __MODULE__) do
    :gen_statem.call(master, :get_slave_name_map)
  end

  defp wait_for_state(master, target_state, timeout) do
    end_time = System.monotonic_time(:millisecond) + timeout

    wait_loop = fn wait_fn ->
      case get_state(master) do
        ^target_state ->
          :ok

        _other_state ->
          remaining = end_time - System.monotonic_time(:millisecond)

          if remaining > 0 do
            Process.sleep(min(100, remaining))
            wait_fn.(wait_fn)
          else
            {:error, {:timeout_waiting_for_state, target_state}}
          end
      end
    end

    wait_loop.(wait_loop)
  end

  defp configure_all_and_activate(master, config) do
    # This transitions from :synced to :operational
    cycle_interval = config.master.cycle_interval || 10_000
    nif_yield_interval = config.master.nif_yield_interval || 100_000

    # First configure slaves
    case :gen_statem.call(master, :configure_all_slaves, 30_000) do
      :ok ->
        start_cyclic(master, cycle_interval, nif_yield_interval)

      error ->
        error
    end
  end

  # ============================================================================
  # gen_statem Callbacks
  # ============================================================================

  @impl true
  def callback_mode(), do: [:state_functions, :state_enter]

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    master_index = Keyword.get(opts, :master_index, 0)
    # Convert microseconds to milliseconds for timer functions
    scan_interval_us = Keyword.get(opts, :scan_interval, 100_000)
    stability_timeout_us = Keyword.get(opts, :stability_timeout, 1_000_000)
    scan_interval = div(scan_interval_us, 1000)
    stability_timeout = div(stability_timeout_us, 1000)

    case Nif.request_master(master_index) do
      {:ok, ref} ->
        data = %__MODULE__{
          master_ref: ref,
          master_index: master_index,
          slaves: %{},
          domains: %{},
          subscribers: %{},
          task_pid: nil,
          scan_interval: scan_interval,
          stability_timeout: stability_timeout,
          hardware_config: nil,
          hardware_diff: nil,
          last_slave_count: nil,
          stability_timer_ref: nil
        }

        Logger.info("Master #{master_index} initialized")
        {:ok, :offline, data, [{:next_event, :internal, :connect}]}

      :error ->
        Logger.error("Failed to create master #{master_index}")
        {:stop, :failed_to_create_master}
    end
  end

  @impl true
  def terminate(reason, _state, data) do
    Logger.info("Master terminating: #{inspect(reason)}")

    # Safely cleanup cyclic task
    if is_map(data) and Map.has_key?(data, :task_pid) and data.task_pid do
      if Process.alive?(data.task_pid) do
        Process.exit(data.task_pid, :kill)
      end
    end

    # Safely cleanup slave drivers
    if is_map(data) and Map.has_key?(data, :slaves) and is_map(data.slaves) do
      Enum.each(data.slaves, fn {_position, slave_info} ->
        if is_map(slave_info) and Map.has_key?(slave_info, :pid) do
          if Process.alive?(slave_info.pid) do
            try do
              GenServer.stop(slave_info.pid, :normal, 5000)
            catch
              :exit, _ -> :ok
            end
          end
        end
      end)
    end

    :ok
  end

  # ============================================================================
  # State: :offline
  # ============================================================================

  def offline(:enter, _old_state, _data) do
    Logger.debug("Entered :offline state")
    :keep_state_and_data
  end

  def offline(:internal, :connect, data) do
    case Nif.get_master_state(data.master_ref) do
      {:ok, master_state} when master_state.link_up == 1 ->
        Logger.info("Master connected, transitioning to :stale")
        {:next_state, :stale, data}

      {:ok, _} ->
        Logger.warning("Master link down, retrying...")
        {:keep_state_and_data, [{:state_timeout, data.scan_interval, :retry_connect}]}

      {:error, reason} ->
        Logger.error("Connection failed: #{inspect(reason)}")
        {:keep_state_and_data, [{:state_timeout, data.scan_interval, :retry_connect}]}
    end
  end

  def offline(:state_timeout, :retry_connect, _data) do
    {:keep_state_and_data, [{:next_event, :internal, :connect}]}
  end

  def offline({:call, from}, _event, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :offline}}]}
  end

  def offline(_event_type, _event, _data) do
    :keep_state_and_data
  end

  # ============================================================================
  # State: :stale
  # ============================================================================

  def stale(:enter, _old_state, _data) do
    Logger.info("Entered :stale state - monitoring hardware topology")
    {:keep_state_and_data, [{:state_timeout, 0, :check_hardware}]}
  end

  def stale(:state_timeout, :check_hardware, data) do
    case Nif.get_master_state(data.master_ref) do
      {:ok, master_state} ->
        current_slave_count = master_state.slaves_responding

        cond do
          # Hardware changed - reset stability timer
          data.last_slave_count != nil and data.last_slave_count != current_slave_count ->
            Logger.info(
              "Hardware changed: #{data.last_slave_count} -> #{current_slave_count} slaves"
            )

            # Cancel existing timer if any and flush message
            if data.stability_timer_ref do
              cancel_stability_timer(data.stability_timer_ref)
            end

            new_data = %{data | last_slave_count: current_slave_count, stability_timer_ref: nil}

            {:keep_state, new_data, [{:state_timeout, data.scan_interval, :check_hardware}]}

          # First check - start stability monitoring
          data.last_slave_count == nil ->
            Logger.info("Initial hardware scan: #{current_slave_count} slaves detected")

            new_data = %{data | last_slave_count: current_slave_count}
            {:keep_state, new_data, [{:state_timeout, data.scan_interval, :check_hardware}]}

          # Hardware stable but no timer yet - start stability countdown
          data.stability_timer_ref == nil ->
            Logger.debug("Hardware stable, starting stability timer")
            timer_ref = Process.send_after(self(), :stability_timeout, data.stability_timeout)
            new_data = %{data | stability_timer_ref: timer_ref}

            {:keep_state, new_data, [{:state_timeout, data.scan_interval, :check_hardware}]}

          # Hardware still stable, timer running - keep monitoring
          true ->
            {:keep_state_and_data, [{:state_timeout, data.scan_interval, :check_hardware}]}
        end

      {:error, reason} ->
        Logger.error("Failed to check hardware: #{inspect(reason)}")
        {:next_state, :offline, data}
    end
  end

  def stale(:info, :stability_timeout, data) do
    Logger.info("Hardware stable for #{data.stability_timeout}ms, attempting sync")

    # Check if we have hardware_config
    if data.hardware_config == nil do
      Logger.warning("Cannot transition to :synced - no hardware_config set")
      # Stay in :stale and keep monitoring
      {:keep_state_and_data, [{:state_timeout, data.scan_interval, :check_hardware}]}
    else
      # Re-check hardware hasn't changed since timer started
      case Nif.get_master_state(data.master_ref) do
        {:ok, master_state} ->
          current_slave_count = master_state.slaves_responding

          if current_slave_count == data.last_slave_count do
            # Hardware still stable, proceed with sync
            case verify_and_sync_hardware(data) do
              {:ok, new_data} ->
                {:next_state, :synced, new_data}

              {:error, reason} ->
                Logger.error("Hardware verification failed: #{inspect(reason)}")
                # Reset and keep monitoring
                new_data = %{data | last_slave_count: nil, stability_timer_ref: nil}
                {:keep_state, new_data, [{:state_timeout, data.scan_interval, :check_hardware}]}
            end
          else
            # Hardware changed during timer - reset monitoring
            Logger.warning(
              "Hardware changed during stability wait: #{data.last_slave_count} -> #{current_slave_count}, restarting monitoring"
            )

            new_data = %{data | last_slave_count: current_slave_count, stability_timer_ref: nil}
            {:keep_state, new_data, [{:state_timeout, data.scan_interval, :check_hardware}]}
          end

        {:error, reason} ->
          Logger.error("Failed to re-check hardware: #{inspect(reason)}")
          {:next_state, :offline, data}
      end
    end
  end

  def stale({:call, from}, {:set_hardware_config, config}, data) do
    Logger.info("Hardware config set, resetting stability monitoring")

    # Cancel existing timer and flush message
    if data.stability_timer_ref do
      cancel_stability_timer(data.stability_timer_ref)
    end

    # Reset monitoring state with new config
    new_data = %{
      data
      | hardware_config: config,
        last_slave_count: nil,
        stability_timer_ref: nil
    }

    {:keep_state, new_data,
     [{:reply, from, :ok}, {:state_timeout, 0, :check_hardware}]}
  end

  def stale({:call, from}, _event, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :stale}}]}
  end

  def stale(_event_type, _event, _data) do
    :keep_state_and_data
  end

  # ============================================================================
  # State: :synced
  # ============================================================================

  def synced(:enter, _old_state, data) do
    Logger.info("Entered :synced state - hardware verified, slave drivers running")
    # Start monitoring for hardware changes
    {:keep_state_and_data, [{:state_timeout, data.scan_interval, :monitor_hardware}]}
  end

  def synced(:state_timeout, :monitor_hardware, data) do
    case Nif.get_master_state(data.master_ref) do
      {:ok, master_state} ->
        current_slave_count = master_state.slaves_responding

        if current_slave_count != data.last_slave_count do
          Logger.warning(
            "Hardware change detected in :synced state: #{data.last_slave_count} -> #{current_slave_count} slaves, transitioning to :stale"
          )

          # Stop all slave drivers before transitioning
          stop_all_slave_drivers(data)

          # Clear subscribers as PDO entries will be re-registered
          Logger.debug("Clearing #{map_size(data.subscribers)} subscriber(s) due to hardware change")

          # Reset state and transition to :stale
          new_data = %{
            data
            | slaves: %{},
              domains: %{},
              subscribers: %{},
              last_slave_count: nil,
              stability_timer_ref: nil
          }

          {:next_state, :stale, new_data}
        else
          # Hardware still stable
          {:keep_state_and_data, [{:state_timeout, data.scan_interval, :monitor_hardware}]}
        end

      {:error, reason} ->
        Logger.error("Failed to monitor hardware: #{inspect(reason)}")
        {:next_state, :offline, data}
    end
  end

  def synced({:call, from}, :get_slaves, data) do
    slave_pids = data.slaves |> Map.values() |> Enum.map(& &1.pid)
    {:keep_state_and_data, [{:reply, from, {:ok, slave_pids}}]}
  end

  def synced({:call, from}, :get_slave_name_map, data) do
    slave_map =
      data.slaves
      |> Map.values()
      |> Enum.map(fn slave_info -> {slave_info.name, slave_info.pid} end)
      |> Map.new()

    {:keep_state_and_data, [{:reply, from, {:ok, slave_map}}]}
  end

  def synced({:call, from}, {:create_domain, name, interval}, data) do
    case Map.has_key?(data.domains, name) do
      true ->
        {:keep_state_and_data, [{:reply, from, {:error, :domain_already_exists}}]}

      false ->
        case Nif.master_create_domain(data.master_ref, name, interval) do
          {:ok, domain_ref} ->
            domain_info = %{ref: domain_ref, interval: interval}
            new_domains = Map.put(data.domains, name, domain_info)

            {:keep_state, %{data | domains: new_domains}, [{:reply, from, {:ok, domain_ref}}]}

          {:error, _} = error ->
            {:keep_state_and_data, [{:reply, from, error}]}
        end
    end
  end

  def synced({:call, from}, {:set_hardware_config, config}, data) do
    Logger.info("New hardware config received, stopping drivers and transitioning to :stale")

    # Stop all slave drivers
    stop_all_slave_drivers(data)

    # Cancel monitoring timer if any and flush message
    if data.stability_timer_ref do
      cancel_stability_timer(data.stability_timer_ref)
    end

    # Clear subscribers as PDO entries will be re-registered with new config
    Logger.debug("Clearing #{map_size(data.subscribers)} subscriber(s) due to config change")

    # Reset state with new config and transition to :stale
    new_data = %{
      data
      | hardware_config: config,
        slaves: %{},
        domains: %{},
        subscribers: %{},
        last_slave_count: nil,
        stability_timer_ref: nil
    }

    {:next_state, :stale, new_data, [{:reply, from, :ok}]}
  end

  def synced({:call, from}, :configure_all_slaves, data) do
    Logger.debug("Configuring all slaves (SDOs and PDOs)")

    case configure_all_slaves(data) do
      :ok ->
        {:keep_state_and_data, [{:reply, from, :ok}]}

      {:error, _} = error ->
        {:keep_state_and_data, [{:reply, from, error}]}
    end
  end

  def synced({:call, from}, {:start_cyclic, cycle_interval, nif_yield_interval}, data) do
    Logger.info("Starting cyclic mode")

    # Configure and register all PDOs
    case configure_all_slaves(data) do
      :ok ->
        case Nif.master_activate(data.master_ref) do
          :ok ->
            domain_refs = data.domains |> Map.values() |> Enum.map(& &1.ref)

            task_pid =
              spawn_link(fn ->
                Nif.cyclic_task(
                  self(),
                  data.master_ref,
                  domain_refs,
                  cycle_interval,
                  nif_yield_interval
                )
              end)

            new_data = %{data | task_pid: task_pid}
            {:next_state, :operational, new_data, [{:reply, from, :ok}]}

          {:error, _} = error ->
            {:keep_state_and_data, [{:reply, from, error}]}
        end

      {:error, _} = error ->
        {:keep_state_and_data, [{:reply, from, error}]}
    end
  end

  def synced({:call, from}, {:get_sync_manager, position, sync_index}, data) do
    result = Nif.master_get_sync_manager(data.master_ref, position, sync_index)
    {:keep_state_and_data, [{:reply, from, result}]}
  end

  def synced({:call, from}, {:get_pdo, position, sync_index, pdo_pos}, data) do
    result = Nif.master_get_pdo(data.master_ref, position, sync_index, pdo_pos)
    {:keep_state_and_data, [{:reply, from, result}]}
  end

  def synced({:call, from}, {:get_pdo_entry, position, sync_index, pdo_pos, entry_pos}, data) do
    result = Nif.master_get_pdo_entry(data.master_ref, position, sync_index, pdo_pos, entry_pos)
    {:keep_state_and_data, [{:reply, from, result}]}
  end

  def synced({:call, from}, :get_hardware_diff, data) do
    {:keep_state_and_data, [{:reply, from, {:ok, data.hardware_diff}}]}
  end

  def synced({:call, from}, :generate_config, _data) do
    # TODO: Implement hardware config generation from discovered slaves
    # For now, return a placeholder error
    {:keep_state_and_data, [{:reply, from, {:error, :not_implemented}}]}
  end

  def synced({:call, from}, {:subscribe, domain_name, unique_name, subscriber_pid}, data) do
    Process.monitor(subscriber_pid)

    key = {domain_name, unique_name}
    new_subscribers = Map.update(data.subscribers, key, [subscriber_pid], &[subscriber_pid | &1])

    {:keep_state, %{data | subscribers: new_subscribers}, [{:reply, from, :ok}]}
  end

  def synced({:call, from}, {:unsubscribe, domain_name, unique_name, subscriber_pid}, data) do
    key = {domain_name, unique_name}

    new_subscribers =
      case data.subscribers[key] do
        nil ->
          data.subscribers

        pids ->
          updated = List.delete(pids, subscriber_pid)

          if updated == [],
            do: Map.delete(data.subscribers, key),
            else: Map.put(data.subscribers, key, updated)
      end

    {:keep_state, %{data | subscribers: new_subscribers}, [{:reply, from, :ok}]}
  end

  def synced(:info, {:DOWN, _ref, :process, pid, _reason}, data) do
    # Remove dead subscriber from all subscriptions
    new_subscribers =
      Map.new(data.subscribers, fn {key, pids} ->
        updated = List.delete(pids, pid)
        if updated == [], do: nil, else: {key, updated}
      end)
      |> Enum.reject(&is_nil/1)
      |> Map.new()

    {:keep_state, %{data | subscribers: new_subscribers}}
  end

  def synced(:info, {:EXIT, pid, reason}, data) do
    handle_exit(pid, reason, data)
  end

  def synced(_event_type, _event, _data) do
    :keep_state_and_data
  end

  # ============================================================================
  # State: :operational
  # ============================================================================

  def operational(:enter, _old_state, data) do
    Logger.info("Entered :operational state - cyclic mode active")
    # Start monitoring for hardware changes
    {:keep_state_and_data, [{:state_timeout, data.scan_interval, :monitor_hardware}]}
  end

  def operational(:state_timeout, :monitor_hardware, data) do
    case Nif.get_master_state(data.master_ref) do
      {:ok, master_state} ->
        current_slave_count = master_state.slaves_responding

        if current_slave_count != data.last_slave_count do
          Logger.error(
            "Hardware change detected in :operational state: #{data.last_slave_count} -> #{current_slave_count} slaves, stopping cyclic and transitioning to :stale"
          )

          # Kill cyclic task
          if data.task_pid do
            Process.exit(data.task_pid, :kill)
          end

          # Stop all slave drivers
          stop_all_slave_drivers(data)

          # Clear subscribers as PDO entries will be re-registered
          Logger.debug("Clearing #{map_size(data.subscribers)} subscriber(s) due to hardware change")

          # Reset state and transition to :stale
          new_data = %{
            data
            | task_pid: nil,
              slaves: %{},
              domains: %{},
              subscribers: %{},
              last_slave_count: nil,
              stability_timer_ref: nil
          }

          {:next_state, :stale, new_data}
        else
          # Hardware still stable
          {:keep_state_and_data, [{:state_timeout, data.scan_interval, :monitor_hardware}]}
        end

      {:error, reason} ->
        Logger.error("Failed to monitor hardware in :operational: #{inspect(reason)}")
        {:next_state, :offline, data}
    end
  end

  def operational({:call, from}, :stop_cyclic, data) do
    Logger.info("Stopping cyclic mode, transitioning to :stale")

    if data.task_pid do
      Process.exit(data.task_pid, :kill)

      # Wait for termination messages
      receive do
        {:EXIT, _pid, _} -> :ok
      after
        3000 -> Logger.warning("Timeout waiting for task exit")
      end

      receive do
        :cyclic_task_died -> :ok
      after
        3000 -> Logger.warning("Timeout waiting for task died message")
      end
    end

    # Stop all slave drivers
    stop_all_slave_drivers(data)

    # Clear subscribers as PDO entries will be re-registered
    Logger.debug("Clearing #{map_size(data.subscribers)} subscriber(s) due to stop_cyclic")

    # Reset state and transition to :stale
    new_data = %{
      data
      | task_pid: nil,
        slaves: %{},
        domains: %{},
        subscribers: %{},
        last_slave_count: nil,
        stability_timer_ref: nil
    }

    {:next_state, :stale, new_data, [{:reply, from, :ok}]}
  end

  def operational({:call, from}, {:read_pdo_entry, domain_name, unique_name}, data) do
    case get_in(data.domains, [domain_name, :ref]) do
      nil ->
        {:keep_state_and_data, [{:reply, from, {:error, :domain_not_found}}]}

      domain_ref ->
        result =
          case Nif.get_value(domain_ref, unique_name) do
            {:error, _} = error -> error
            value -> {:ok, value}
          end

        {:keep_state_and_data, [{:reply, from, result}]}
    end
  end

  def operational({:call, from}, {:write_pdo_entry, domain_name, unique_name, binary_data}, data) do
    case get_in(data.domains, [domain_name, :ref]) do
      nil ->
        {:keep_state_and_data, [{:reply, from, {:error, :domain_not_found}}]}

      domain_ref ->
        result = Nif.set_value(domain_ref, unique_name, binary_data)
        {:keep_state_and_data, [{:reply, from, result}]}
    end
  end

  def operational({:call, from}, :get_slaves, data) do
    slave_pids = data.slaves |> Map.values() |> Enum.map(& &1.pid)
    {:keep_state_and_data, [{:reply, from, {:ok, slave_pids}}]}
  end

  def operational({:call, from}, :get_slave_name_map, data) do
    slave_map =
      data.slaves
      |> Map.values()
      |> Enum.map(fn slave_info -> {slave_info.name, slave_info.pid} end)
      |> Map.new()

    {:keep_state_and_data, [{:reply, from, {:ok, slave_map}}]}
  end

  def operational({:call, from}, :get_hardware_diff, data) do
    {:keep_state_and_data, [{:reply, from, {:ok, data.hardware_diff}}]}
  end

  # Handle data change notifications from NIF
  # NIF sends: {:data_changed, domain_name, unique_name, value}
  # Where unique_name = "slave_name:pdo_name:entry_name"
  def operational(:info, {:data_changed, domain_name, unique_name, value}, data) do
    key = {domain_name, unique_name}

    case data.subscribers[key] do
      nil ->
        :keep_state_and_data

      pids ->
        Enum.each(pids, fn pid ->
          send(pid, {:pdo_value_changed, domain_name, unique_name, value})
        end)

        :keep_state_and_data
    end
  end

  # Handle output change notifications from NIF (for telemetry/debugging)
  # NIF sends: {:output_changed, domain_name, unique_name, value}
  def operational(:info, {:output_changed, _domain_name, _unique_name, _value}, _data) do
    # Currently unused - could be used for output monitoring/telemetry
    :keep_state_and_data
  end

  # Handle domain working counter changes
  # NIF sends: {:wc_changed, domain_name, working_counter}
  def operational(:info, {:wc_changed, _domain_name, _working_counter}, _data) do
    # Could be used for domain health monitoring
    :keep_state_and_data
  end

  # Handle domain state changes
  # NIF sends: {:state_changed, domain_name, wc_state}
  def operational(:info, {:state_changed, _domain_name, _wc_state}, _data) do
    # Could be used for domain state monitoring
    :keep_state_and_data
  end

  def operational(:info, {:DOWN, _ref, :process, pid, _reason}, data) do
    # Remove dead subscriber
    new_subscribers =
      Map.new(data.subscribers, fn {key, pids} ->
        updated = List.delete(pids, pid)
        if updated == [], do: nil, else: {key, updated}
      end)
      |> Enum.reject(&is_nil/1)
      |> Map.new()

    {:keep_state, %{data | subscribers: new_subscribers}}
  end

  def operational(:info, {:EXIT, pid, reason}, data) do
    handle_exit(pid, reason, data)
  end

  def operational(_event_type, _event, _data) do
    :keep_state_and_data
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp verify_and_sync_hardware(data) do
    alias EtherCAT.Config.HardwareConfig

    config = data.hardware_config

    # Validate config
    with :ok <- HardwareConfig.validate(config),
         {:ok, data_with_domains} <- create_domains_from_config(data, config),
         {:ok, data_with_slaves} <- start_slaves_from_config(data_with_domains, config),
         :ok <- validate_hardware_count(config, data_with_slaves) do
      # Generate hardware diff
      hardware_diff = generate_hardware_diff(config, data_with_slaves.slaves)

      Logger.info(
        "Hardware verification successful: #{map_size(data_with_slaves.slaves)} slaves synced"
      )

      {:ok, %{data_with_slaves | hardware_diff: hardware_diff}}
    end
  end

  defp validate_hardware_count(config, data) do
    expected_count = length(config.slaves)
    actual_count = map_size(data.slaves)

    if expected_count == actual_count do
      :ok
    else
      {:error,
       {:slave_count_mismatch, "Expected #{expected_count} slaves, found #{actual_count}"}}
    end
  end

  defp cancel_stability_timer(timer_ref) do
    # Cancel the timer and flush any pending :stability_timeout messages
    Process.cancel_timer(timer_ref)

    receive do
      :stability_timeout -> :ok
    after
      0 -> :ok
    end
  end

  defp stop_all_slave_drivers(data) do
    Enum.each(data.slaves, fn {_position, slave_info} ->
      if Process.alive?(slave_info.pid) do
        try do
          GenServer.stop(slave_info.pid, :normal, 5000)
        catch
          :exit, _ -> :ok
        end
      end
    end)
  end

  defp start_slave_driver(data, position) do
    slave_name = :"slave_#{position}"

    with {:ok, slave_info} <- Nif.master_get_slave(data.master_ref, position),
         {:ok, slave_config} <-
           Nif.master_slave_config(
             data.master_ref,
             0,
             position,
             slave_info.vendor_id,
             slave_info.product_code
           ),
         {:ok, eeprom_data} <-
           read_slave_eeprom_data(data.master_ref, position, slave_info.sync_count),
         driver_module = driver_for_slave(slave_info.vendor_id, slave_info.product_code),
         {:ok, pid} <-
           driver_module.start_link(
             master: self(),
             position: position,
             name: slave_name,
             eeprom_data: eeprom_data
           ) do
      {:ok,
       %{
         pid: pid,
         name: slave_name,
         vendor: slave_info.vendor_id,
         product: slave_info.product_code,
         driver: driver_module,
         slave_config: slave_config
       }}
    end
  end

  defp driver_for_slave(0x02, 0x0C823052), do: EtherCAT.Slave.GenericDriver
  defp driver_for_slave(_vendor_id, _product_code), do: EtherCAT.Slave.GenericDriver

  # Parse driver configuration
  # Returns {driver_module, driver_opts}
  # Supports:
  #   - nil -> {GenericDriver, []}
  #   - Module -> {Module, []}
  #   - {Module, opts} -> {Module, opts}
  defp parse_driver_config(nil), do: {EtherCAT.Slave.GenericDriver, []}
  defp parse_driver_config({module, opts}) when is_atom(module) and is_list(opts), do: {module, opts}
  defp parse_driver_config(module) when is_atom(module), do: {module, []}

  # Read all EEPROM data for a slave (sync managers, PDOs, entries)
  # This is done by Master to avoid circular dependency with drivers
  defp read_slave_eeprom_data(master_ref, position, sync_count) do
    try do
      sync_results =
        if sync_count > 0 do
          for sync_index <- 0..(sync_count - 1) do
            case Nif.master_get_sync_manager(master_ref, position, sync_index) do
              sync_manager when is_map(sync_manager) ->
                pdos =
                  read_sync_manager_pdos(master_ref, position, sync_index, sync_manager.n_pdos)

                {sync_index, %{sync_manager: sync_manager, pdos: pdos}}

              error ->
                Logger.warning(
                  "Failed to get sync manager #{sync_index} for slave #{position}: #{inspect(error)}"
                )

                nil
            end
          end
          |> Enum.reject(&is_nil/1)
          |> Map.new()
        else
          %{}
        end

      {:ok, sync_results}
    rescue
      error ->
        Logger.error("Failed to read EEPROM data for slave #{position}: #{inspect(error)}")
        {:error, error}
    end
  end

  defp read_sync_manager_pdos(master_ref, position, sync_index, n_pdos) do
    if n_pdos > 0 do
      for pdo_pos <- 0..(n_pdos - 1) do
        case Nif.master_get_pdo(master_ref, position, sync_index, pdo_pos) do
          pdo when is_map(pdo) ->
            entries = read_pdo_entries(master_ref, position, sync_index, pdo_pos, pdo.n_entries)
            {pdo_pos, %{pdo: pdo, entries: entries}}

          error ->
            Logger.warning(
              "Failed to get PDO #{pdo_pos} for sync #{sync_index} on slave #{position}: #{inspect(error)}"
            )

            nil
        end
      end
      |> Enum.reject(&is_nil/1)
      |> Map.new()
    else
      %{}
    end
  end

  defp read_pdo_entries(master_ref, position, sync_index, pdo_pos, n_entries) do
    if n_entries > 0 do
      for entry_pos <- 0..(n_entries - 1) do
        case Nif.master_get_pdo_entry(master_ref, position, sync_index, pdo_pos, entry_pos) do
          entry when is_map(entry) ->
            {entry_pos, entry}

          error ->
            Logger.warning(
              "Failed to get PDO entry #{entry_pos} for slave #{position}: #{inspect(error)}"
            )

            nil
        end
      end
      |> Enum.reject(&is_nil/1)
      |> Map.new()
    else
      %{}
    end
  end

  defp configure_all_slaves(data) do
    Enum.reduce_while(data.slaves, :ok, fn {position, slave_info}, :ok ->
      case configure_single_slave(data, position, slave_info) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp configure_single_slave(data, position, slave_info) do
    driver_module = slave_info.driver
    slave_pid = slave_info.pid

    Logger.debug("Configuring slave #{position} (#{inspect(driver_module)})")

    with {:ok, slave_config} <- get_slave_config_for_position(data, position),
         :ok <- configure_slave_sdos(slave_config, position, driver_module, slave_pid),
         pdo_configs = driver_module.get_pdo_config(slave_pid),
         :ok <- configure_slave_pdos(data, position, pdo_configs),
         :ok <- register_pdo_entries(data, position, slave_info, pdo_configs) do
      :ok
    end
  end

  defp configure_slave_sdos(slave_config, position, driver_module, slave_pid) do
    sdo_configs = driver_module.get_sdo_config(slave_pid)

    Enum.each(sdo_configs, fn {index, subindex, sdo_data} ->
      case Nif.slave_config_sdo(slave_config, index, subindex, sdo_data) do
        :ok ->
          Logger.debug(
            "Slave #{position}: Configured SDO 0x#{Integer.to_string(index, 16)}:#{subindex}"
          )

        {:error, reason} ->
          Logger.warning(
            "Slave #{position}: Failed to configure SDO 0x#{Integer.to_string(index, 16)}:#{subindex} - #{inspect(reason)}"
          )
      end
    end)

    :ok
  end

  defp configure_slave_pdos(data, position, pdo_configs) do
    # Group PDOs by sync manager
    pdos_by_sm =
      Enum.group_by(pdo_configs, fn pdo_config ->
        {sm_index, _direction, _watchdog} = pdo_config.sync_manager
        sm_index
      end)

    # Configure each sync manager
    Enum.reduce_while(pdos_by_sm, :ok, fn {sm_index, sm_pdos}, :ok ->
      case configure_sync_manager(data, position, sm_index, sm_pdos) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp configure_sync_manager(_data, _position, _sm_index, []) do
    # Empty PDO list - nothing to configure
    :ok
  end

  defp configure_sync_manager(data, position, sm_index, sm_pdos) when is_list(sm_pdos) do
    with {:ok, slave_config} <- get_slave_config_for_position(data, position),
         [first_pdo | _] = sm_pdos,
         {_sm_index, direction, watchdog} = first_pdo.sync_manager,
         :ok <- do_configure_sync_manager(slave_config, position, sm_index, direction, watchdog),
         :ok <- do_clear_and_assign_pdos(slave_config, position, sm_index, sm_pdos),
         :ok <- do_configure_pdo_mappings(slave_config, position, sm_pdos, first_pdo) do
      :ok
    end
  end

  defp do_configure_sync_manager(slave_config, position, sm_index, direction, watchdog) do
    Logger.debug("Slave #{position}: Configuring SM#{sm_index} (#{direction})")
    Nif.slave_config_sync_manager(slave_config, sm_index, direction, watchdog)
    :ok
  end

  defp do_clear_and_assign_pdos(slave_config, position, sm_index, sm_pdos) do
    # Clear PDO assignments
    Nif.slave_config_pdo_assign_clear(slave_config, sm_index)

    # Add all PDO assignments for this SM
    pdo_indices = Enum.map(sm_pdos, & &1.pdo_index) |> Enum.uniq()

    Enum.each(pdo_indices, fn pdo_index ->
      Nif.slave_config_pdo_assign_add(slave_config, sm_index, pdo_index)

      Logger.debug(
        "Slave #{position}: Assigned PDO 0x#{Integer.to_string(pdo_index, 16)} to SM#{sm_index}"
      )
    end)

    :ok
  end

  defp do_configure_pdo_mappings(slave_config, position, sm_pdos, first_pdo) do
    supports_pdo_config = Map.get(first_pdo, :supports_pdo_config?, true)

    if supports_pdo_config do
      Enum.each(sm_pdos, fn pdo_config ->
        configure_pdo_mappings(slave_config, position, pdo_config)
      end)
    end

    :ok
  end

  defp configure_pdo_mappings(slave_config, position, pdo_config) do
    pdo_index = pdo_config.pdo_index

    # Clear existing mappings
    Nif.slave_config_pdo_mapping_clear(slave_config, pdo_index)

    # Add all entry mappings
    Enum.each(pdo_config.entries, fn {entry_name,
                                      {_type, entry_index, entry_subindex, bit_length}} ->
      Nif.slave_config_pdo_mapping_add(
        slave_config,
        pdo_index,
        entry_index,
        entry_subindex,
        bit_length
      )

      Logger.debug(
        "Slave #{position}: Mapped entry #{entry_name} (0x#{Integer.to_string(entry_index, 16)}:#{entry_subindex}) to PDO 0x#{Integer.to_string(pdo_index, 16)}"
      )
    end)
  end

  defp register_pdo_entries(data, position, slave_info, pdo_configs) do
    with {:ok, slave_config} <- get_slave_config_for_position(data, position) do
      Enum.reduce_while(pdo_configs, :ok, fn pdo_config, :ok ->
        # Determine which domain this PDO belongs to
        domain_name = Map.get(pdo_config, :domain, :default_domain)

        case data.domains[domain_name] do
          nil ->
            Logger.error(
              "Slave #{position}: Domain #{domain_name} not found for PDO #{pdo_config.name}"
            )

            {:halt, {:error, {:domain_not_found, domain_name}}}

          domain_info ->
            case register_pdo_to_domain(
                   slave_config,
                   domain_info.ref,
                   position,
                   slave_info.name,
                   pdo_config
                 ) do
              :ok -> {:cont, :ok}
              {:error, _} = error -> {:halt, error}
            end
        end
      end)
    end
  end

  defp register_pdo_to_domain(slave_config, domain_ref, position, slave_name, pdo_config) do
    {_sm_index, direction, _watchdog} = pdo_config.sync_manager

    try do
      Enum.each(pdo_config.entries, fn {entry_name,
                                        {_type, entry_index, entry_subindex, bit_length}} ->
        # Skip gap entries (0x0000:0x00) - these are padding and should not be registered
        if entry_index != 0 or entry_subindex != 0 do
          # Build unique name for this entry
          unique_name = "#{slave_name}:#{pdo_config.name}:#{entry_name}"

          # Register with NIF (can raise on error)
          _offset =
            Nif.slave_config_reg_pdo_entry(
              slave_config,
              unique_name,
              entry_index,
              entry_subindex,
              bit_length,
              domain_ref,
              direction
            )

          Logger.debug(
            "Slave #{position}: Registered #{unique_name} to domain (direction: #{direction})"
          )
        end
      end)

      :ok
    rescue
      error ->
        Logger.error("Failed to register PDO entries for slave #{position}: #{inspect(error)}")
        {:error, {:pdo_registration_failed, error}}
    end
  end

  defp get_slave_config_for_position(data, position) do
    case data.slaves[position] do
      nil ->
        {:error, :slave_not_found}

      slave_info ->
        # Master owns slave_config - direct map access (no Registry indirection)
        {:ok, slave_info.slave_config}
    end
  end

  defp handle_exit(pid, reason, data) do
    cond do
      pid == data.task_pid ->
        Logger.error("Cyclic task crashed: #{inspect(reason)}, transitioning to :stale for recovery")

        # Stop all slave drivers
        stop_all_slave_drivers(data)

        # Clear subscribers as system needs recovery
        Logger.debug("Clearing #{map_size(data.subscribers)} subscriber(s) due to task crash")

        # Reset state and transition to :stale
        new_data = %{
          data
          | task_pid: nil,
            slaves: %{},
            domains: %{},
            subscribers: %{},
            last_slave_count: nil,
            stability_timer_ref: nil
        }

        {:next_state, :stale, new_data}

      true ->
        # Check if it's a slave
        case Enum.find(data.slaves, fn {_pos, info} -> info.pid == pid end) do
          {position, _info} ->
            Logger.warning("Slave #{position} exited: #{inspect(reason)}, transitioning to :stale")

            # Stop remaining slave drivers
            stop_all_slave_drivers(data)

            # If cyclic task is running, kill it
            if data.task_pid do
              Process.exit(data.task_pid, :kill)
            end

            # Clear subscribers as slave drivers are being restarted
            Logger.debug("Clearing #{map_size(data.subscribers)} subscriber(s) due to slave crash")

            # Reset state and transition to :stale
            new_data = %{
              data
              | task_pid: nil,
                slaves: %{},
                domains: %{},
                subscribers: %{},
                last_slave_count: nil,
                stability_timer_ref: nil
            }

            {:next_state, :stale, new_data}

          nil ->
            :keep_state_and_data
        end
    end
  end

  # ============================================================================
  # Hardware Configuration Helpers
  # ============================================================================

  defp create_domains_from_config(data, config) do
    result =
      Enum.reduce_while(config.domains, {:ok, data}, fn domain_config, {:ok, acc_data} ->
        # Convert milliseconds to microseconds (DomainConfig uses ms, NIF expects µs)
        interval_us = domain_config.interval * 1000

        case Nif.master_create_domain(acc_data.master_ref, domain_config.name, interval_us) do
          {:ok, domain_ref} ->
            domain_info = %{ref: domain_ref, interval: interval_us}
            new_domains = Map.put(acc_data.domains, domain_config.name, domain_info)
            {:cont, {:ok, %{acc_data | domains: new_domains}}}

          {:error, reason} ->
            {:halt, {:error, {:failed_to_create_domain, domain_config.name, reason}}}
        end
      end)

    case result do
      {:ok, _} = success -> success
      error -> error
    end
  end

  defp start_slaves_from_config(data, config) do
    # Build map of position => SlaveConfig
    slaves_by_position =
      Map.new(config.slaves, fn slave_config -> {slave_config.position, slave_config} end)

    # Check if all expected slaves exist
    detected_positions = Map.keys(data.slaves)
    configured_positions = Map.keys(slaves_by_position)

    case configured_positions -- detected_positions do
      [] ->
        # Reuse or replace slave drivers
        result =
          Enum.reduce_while(slaves_by_position, {:ok, %{}}, fn {position, slave_config},
                                                               {:ok, acc_slaves} ->
            existing_slave = data.slaves[position]
            {requested_driver, _driver_opts} = parse_driver_config(slave_config.driver)

            # Reuse default driver only if name hasn't changed (to avoid PDO re-discovery deadlock)
            if existing_slave.driver == EtherCAT.Slave.GenericDriver and
                 requested_driver == EtherCAT.Slave.GenericDriver and
                 existing_slave.name == slave_config.name do
              # Reuse existing driver - same driver type and name
              {:cont, {:ok, Map.put(acc_slaves, position, existing_slave)}}
            else
              # Need to replace driver - either different driver type or name changed
              if Process.alive?(existing_slave.pid) do
                GenServer.stop(existing_slave.pid, :normal)
              end

              case start_configured_slave_driver(data, position, slave_config) do
                {:ok, slave_info} ->
                  {:cont, {:ok, Map.put(acc_slaves, position, slave_info)}}

                {:error, reason} ->
                  {:halt, {:error, {:failed_to_start_slave, position, reason}}}
              end
            end
          end)

        case result do
          {:ok, new_slaves} -> {:ok, %{data | slaves: new_slaves}}
          error -> error
        end

      missing ->
        {:error, {:missing_slaves, missing}}
    end
  end

  defp start_configured_slave_driver(data, position, slave_config) do
    # Get hardware info for this slave
    with {:ok, slave_info} <- Nif.master_get_slave(data.master_ref, position),
         {:ok, slave_config_ref} <-
           Nif.master_slave_config(
             data.master_ref,
             0,
             position,
             slave_info.vendor_id,
             slave_info.product_code
           ),
         {:ok, eeprom_data} <-
           read_slave_eeprom_data(data.master_ref, position, slave_info.sync_count),
         {driver_module, driver_opts} = parse_driver_config(slave_config.driver),
         {:ok, pid} <-
           driver_module.start_link(
             Keyword.merge(
               [
                 master: self(),
                 position: position,
                 name: slave_config.name,
                 eeprom_data: eeprom_data
               ],
               driver_opts
             )
           ) do
      {:ok,
       %{
         pid: pid,
         name: slave_config.name,
         vendor: slave_info.vendor_id,
         product: slave_info.product_code,
         driver: driver_module,
         slave_config: slave_config_ref
       }}
    end
  end

  defp activate_and_start_cyclic(data, config) do
    cycle_interval = config.master.cycle_interval || 10_000
    nif_yield_interval = config.master.nif_yield_interval || 100_000

    case Nif.master_activate(data.master_ref) do
      :ok ->
        domain_refs = data.domains |> Map.values() |> Enum.map(& &1.ref)

        task_pid =
          spawn_link(fn ->
            Nif.cyclic_task(
              self(),
              data.master_ref,
              domain_refs,
              cycle_interval,
              nif_yield_interval
            )
          end)

        {:ok, %{data | task_pid: task_pid, hardware_config: config}}

      {:error, _} = error ->
        error
    end
  end

  # ============================================================================
  # Hardware Diff Algorithm
  # ============================================================================

  defp generate_hardware_diff(_expected_config, _actual_slaves) do
    # TODO: Implement tree diff algorithm
    # For now, return placeholder
    %{type: :unknown, path: [], changes: %{}, children: []}
  end

  @doc """
  Compute diff tree between expected and actual hardware nodes.

  ## Algorithm

  1. Match nodes by label (position, vendor, product)
  2. Compare attributes (vendor_id, product_code, etc.)
  3. Recursively diff children
  4. Return diff tree with type: :match | :mismatch | :partial_match
  """
  def diff_tree(expected, actual, path \\ []) do
    cond do
      expected.label != actual.label ->
        %{
          type: :mismatch,
          path: path,
          changes: attr_diff(expected.attrs, actual.attrs),
          children: []
        }

      true ->
        child_diffs =
          zip_match(expected.children, actual.children)
          |> Enum.map(fn {e_child, a_child} ->
            diff_tree(e_child, a_child, path ++ [expected.label])
          end)
          |> Enum.filter(&(&1.type != :match))

        %{
          type: if(Enum.empty?(child_diffs), do: :match, else: :partial_match),
          path: path,
          changes: attr_diff(expected.attrs, actual.attrs),
          children: child_diffs
        }
    end
  end

  defp attr_diff(exp_attrs, act_attrs) do
    exp_attrs
    |> Enum.map(fn {key, exp_val} ->
      case Map.get(act_attrs, key) do
        ^exp_val -> nil
        act_val -> {key, {exp_val, act_val}}
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Map.new()
  end

  defp zip_match(exp_kids, act_kids) do
    # Simple: sort by label and zip
    # Advanced: max common subtree via LCS
    Enum.sort_by(exp_kids, & &1.label)
    |> Enum.zip(Enum.sort_by(act_kids, & &1.label))
  end
end
