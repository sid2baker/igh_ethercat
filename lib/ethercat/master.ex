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
    unique_name => [pid, ...]
  }
  ```

  Where:
  - `unique_name` - Full entry identifier (e.g., `"slave_0:pdo:entry"`)

  ## Entry Registry

  ```elixir
  entry_registry: %{
    unique_name => domain_name
  }
  ```

  Maps unique entry names to their domains for routing read/write operations

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
    :entry_registry,
    :task_pid,
    :scan_interval,
    :stability_timeout,
    :hardware_config,
    :hardware_diff,
    :last_slave_count,
    :stability_timer_ref,
    :cycle_interval_us,
    :pending_writes
  ]

  @type t :: %__MODULE__{
          master_ref: reference() | nil,
          master_index: non_neg_integer(),
          # Map of position => %{pid, name, vendor, product, driver, slave_config}
          # slave_config: NIF SlaveConfigResource owned by Master
          slaves: %{non_neg_integer() => map()},
          # Map of domain_name => %{ref, cycle_multiplier}
          domains: %{atom() => %{ref: reference(), cycle_multiplier: pos_integer()}},
          # Map of unique_name => [subscriber_pids]
          subscribers: %{String.t() => [pid()]},
          # Map of unique_name => domain_name (for routing)
          entry_registry: %{String.t() => atom()},
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
          stability_timer_ref: reference() | nil,
          # Master cycle interval in microseconds (set when operational)
          cycle_interval_us: pos_integer() | nil,
          # Map of {domain_name, unique_name} => %{from, timer_ref}
          pending_writes: %{
            {atom(), String.t()} => %{from: :gen_statem.from(), timer_ref: reference()}
          }
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

  def start_cyclic(master \\ __MODULE__, cycle_interval, nif_yield_interval) do
    :gen_statem.call(master, {:start_cyclic, cycle_interval, nif_yield_interval}, 30_000)
  end

  def stop_cyclic(master \\ __MODULE__) do
    :gen_statem.call(master, :stop_cyclic)
  end

  def read_pdo_entry(master \\ __MODULE__, unique_name) do
    :gen_statem.call(master, {:read_pdo_entry, unique_name})
  end

  def write_pdo_entry(master \\ __MODULE__, unique_name, binary_data) do
    :gen_statem.call(master, {:write_pdo_entry, unique_name, binary_data})
  end

  def subscribe(master \\ __MODULE__, unique_name, subscriber_pid) do
    :gen_statem.call(master, {:subscribe, unique_name, subscriber_pid})
  end

  def unsubscribe(master \\ __MODULE__, unique_name, subscriber_pid) do
    :gen_statem.call(master, {:unsubscribe, unique_name, subscriber_pid})
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

    # start_cyclic will configure slaves and activate
    case start_cyclic(master, cycle_interval, nif_yield_interval) do
      :ok -> {:ok, :activated}
      error -> error
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
          entry_registry: %{},
          task_pid: nil,
          scan_interval: scan_interval,
          stability_timeout: stability_timeout,
          hardware_config: nil,
          hardware_diff: nil,
          last_slave_count: nil,
          stability_timer_ref: nil,
          cycle_interval_us: nil,
          pending_writes: %{}
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
    {:keep_state_and_data, [{:state_timeout, 0, :retry_check}]}
  end

  def stale(:state_timeout, :retry_check, _data) do
    {:keep_state_and_data, [{:next_event, :internal, :check_hardware}]}
  end

  def stale(:internal, :check_hardware, data) do
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

            {:keep_state, new_data, [{:state_timeout, data.scan_interval, :retry_check}]}

          # First check - start stability monitoring
          data.last_slave_count == nil ->
            Logger.info("Initial hardware scan: #{current_slave_count} slaves detected")

            new_data = %{data | last_slave_count: current_slave_count}
            {:keep_state, new_data, [{:state_timeout, data.scan_interval, :retry_check}]}

          # Hardware stable but no timer yet - start stability countdown
          data.stability_timer_ref == nil ->
            Logger.debug("Hardware stable, starting stability timer")
            timer_ref = Process.send_after(self(), :stability_timeout, data.stability_timeout)
            new_data = %{data | stability_timer_ref: timer_ref}

            {:keep_state, new_data, [{:state_timeout, data.scan_interval, :retry_check}]}

          # Hardware still stable, timer running - keep monitoring
          true ->
            {:keep_state_and_data, [{:state_timeout, data.scan_interval, :retry_check}]}
        end

      {:error, reason} ->
        Logger.error("Failed to check hardware: #{inspect(reason)}")

        # Cancel stability timer if running
        if data.stability_timer_ref do
          cancel_stability_timer(data.stability_timer_ref)
        end

        # Reset monitoring state and transition to :offline
        new_data = %{data | last_slave_count: nil, stability_timer_ref: nil}
        {:next_state, :offline, new_data}
    end
  end

  def stale(:info, :stability_timeout, data) do
    Logger.info("Hardware stable for #{data.stability_timeout}ms, attempting sync")

    # Check if we have hardware_config
    if data.hardware_config == nil do
      Logger.warning("Cannot transition to :synced - no hardware_config set")
      # Stay in :stale and keep monitoring
      {:keep_state_and_data, [{:state_timeout, data.scan_interval, :retry_check}]}
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
                {:keep_state, new_data, [{:state_timeout, data.scan_interval, :retry_check}]}
            end
          else
            # Hardware changed during timer - reset monitoring
            Logger.warning(
              "Hardware changed during stability wait: #{data.last_slave_count} -> #{current_slave_count}, restarting monitoring"
            )

            new_data = %{data | last_slave_count: current_slave_count, stability_timer_ref: nil}
            {:keep_state, new_data, [{:state_timeout, data.scan_interval, :retry_check}]}
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

    {:keep_state, new_data, [{:reply, from, :ok}, {:next_event, :internal, :check_hardware}]}
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
          Logger.debug(
            "Clearing #{map_size(data.subscribers)} subscriber(s) due to hardware change"
          )

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
        Logger.error(
          "Failed to monitor hardware: #{inspect(reason)}, cleaning up and transitioning to :offline"
        )

        # Stop all slave drivers
        stop_all_slave_drivers(data)

        # Clear subscribers
        Logger.debug(
          "Clearing #{map_size(data.subscribers)} subscriber(s) due to monitoring failure"
        )

        # Reset state and transition to :offline
        new_data = %{
          data
          | slaves: %{},
            domains: %{},
            subscribers: %{},
            last_slave_count: nil,
            stability_timer_ref: nil
        }

        {:next_state, :offline, new_data}
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

  def synced({:call, from}, {:start_cyclic, cycle_interval, nif_yield_interval}, data) do
    Logger.info("Starting cyclic mode")

    # Configure and register all PDOs
    case configure_all_slaves(data) do
      {:ok, data_with_registry} ->
        case Nif.master_activate(data_with_registry.master_ref) do
          :ok ->
            domain_refs = data_with_registry.domains |> Map.values() |> Enum.map(& &1.ref)
            master_pid = self()

            task_pid =
              spawn_link(fn ->
                Nif.cyclic_task(
                  master_pid,
                  data_with_registry.master_ref,
                  domain_refs,
                  cycle_interval,
                  nif_yield_interval
                )
              end)

            new_data = %{
              data_with_registry
              | task_pid: task_pid,
                cycle_interval_us: cycle_interval
            }

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

  def operational(:enter, _old_state, _data) do
    Logger.info("Entered :operational state - cyclic mode active")
    :keep_state_and_data
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

    # Reply to all pending writes with error and cancel their timers
    Enum.each(data.pending_writes, fn {_key, %{from: from, timer_ref: timer_ref}} ->
      :gen_statem.reply(from, {:error, :cyclic_stopped})
      Process.cancel_timer(timer_ref)
    end)

    # Reset state and transition to :stale
    new_data = %{
      data
      | task_pid: nil,
        slaves: %{},
        domains: %{},
        subscribers: %{},
        last_slave_count: nil,
        stability_timer_ref: nil,
        cycle_interval_us: nil,
        pending_writes: %{}
    }

    {:next_state, :stale, new_data, [{:reply, from, :ok}]}
  end

  def operational({:call, from}, {:read_pdo_entry, unique_name}, data) do
    case data.entry_registry[unique_name] do
      nil ->
        {:keep_state_and_data, [{:reply, from, {:error, :entry_not_registered}}]}

      domain_name ->
        domain_ref = data.domains[domain_name].ref

        result =
          case Nif.get_value(domain_ref, unique_name) do
            {:error, _} = error -> error
            value -> {:ok, value}
          end

        {:keep_state_and_data, [{:reply, from, result}]}
    end
  end

  def operational({:call, from}, {:write_pdo_entry, unique_name, binary_data}, data) do
    case data.entry_registry[unique_name] do
      nil ->
        {:keep_state_and_data, [{:reply, from, {:error, :entry_not_registered}}]}

      domain_name ->
        # Check if there's already a pending write for this entry
        write_key = {domain_name, unique_name}

        case Map.get(data.pending_writes, write_key) do
          nil ->
            # No pending write, proceed with NIF call
            domain_ref = data.domains[domain_name].ref

            case Nif.set_value(domain_ref, unique_name, binary_data) do
              :ok ->
                # Calculate timeout: max(2 * cycle_multiplier * cycle_interval_us / 1_000_000, 1.0) seconds
                domain_info = data.domains[domain_name]
                cycle_multiplier = domain_info.cycle_multiplier

                timeout_ms =
                  max(trunc(2 * cycle_multiplier * data.cycle_interval_us / 1000), 1000)

                # Start timer
                timer_ref =
                  Process.send_after(self(), {:write_timeout, write_key, from}, timeout_ms)

                # Add to pending_writes
                new_pending_writes =
                  Map.put(data.pending_writes, write_key, %{from: from, timer_ref: timer_ref})

                new_data = %{data | pending_writes: new_pending_writes}
                {:keep_state, new_data}

              {:error, _} = error ->
                # NIF error, reply immediately
                {:keep_state_and_data, [{:reply, from, error}]}
            end

          _pending_write ->
            # There's already a pending write for this entry
            {:keep_state_and_data, [{:reply, from, {:error, :write_pending}}]}
        end
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

  def operational({:call, from}, {:subscribe, unique_name, subscriber_pid}, data) do
    Process.monitor(subscriber_pid)

    new_subscribers =
      Map.update(data.subscribers, unique_name, [subscriber_pid], &[subscriber_pid | &1])

    {:keep_state, %{data | subscribers: new_subscribers}, [{:reply, from, :ok}]}
  end

  def operational({:call, from}, {:unsubscribe, unique_name, subscriber_pid}, data) do
    new_subscribers =
      case data.subscribers[unique_name] do
        nil ->
          data.subscribers

        pids ->
          new_pids = List.delete(pids, subscriber_pid)

          if new_pids == [] do
            Map.delete(data.subscribers, unique_name)
          else
            Map.put(data.subscribers, unique_name, new_pids)
          end
      end

    {:keep_state, %{data | subscribers: new_subscribers}, [{:reply, from, :ok}]}
  end

  # Handle data change notifications from NIF
  # NIF sends: {:data_changed, domain_name, unique_name, value}
  # Where unique_name = "slave_name:pdo_name:entry_name"
  def operational(:info, {:data_changed, _domain_name, unique_name, value}, data) do
    case data.subscribers[unique_name] do
      nil ->
        :keep_state_and_data

      pids ->
        Enum.each(pids, fn pid ->
          send(pid, {:pdo_value_changed, unique_name, value})
        end)

        :keep_state_and_data
    end
  end

  # Handle output change notifications from NIF (for telemetry/debugging)
  # NIF sends: {:output_changed, domain_name, unique_name, value}
  def operational(:info, {:output_changed, domain_name, unique_name, _value}, data) do
    write_key = {domain_name, unique_name}

    Logger.debug(
      "Received :output_changed for #{inspect(write_key)}, pending_writes keys: #{inspect(Map.keys(data.pending_writes))}"
    )

    case Map.get(data.pending_writes, write_key) do
      nil ->
        # No pending write for this entry, just ignore
        Logger.debug("No pending write found for #{inspect(write_key)}")
        :keep_state_and_data

      %{from: from, timer_ref: timer_ref} ->
        # Reply to the waiting caller
        Logger.debug("Found pending write for #{inspect(write_key)}, replying :ok to caller")
        :gen_statem.reply(from, :ok)

        # Cancel the timeout timer
        Process.cancel_timer(timer_ref)

        # Remove from pending_writes
        new_pending_writes = Map.delete(data.pending_writes, write_key)
        new_data = %{data | pending_writes: new_pending_writes}

        {:keep_state, new_data}
    end
  end

  # Handle write timeout
  def operational(:info, {:write_timeout, write_key, from}, data) do
    case Map.get(data.pending_writes, write_key) do
      nil ->
        # Already handled (output_changed arrived first), ignore
        :keep_state_and_data

      %{from: ^from} ->
        # Timeout occurred, reply with error
        :gen_statem.reply(from, {:error, :timeout})

        # Remove from pending_writes
        new_pending_writes = Map.delete(data.pending_writes, write_key)
        new_data = %{data | pending_writes: new_pending_writes}

        {domain_name, unique_name} = write_key
        Logger.warning("Write timeout for #{unique_name} in domain #{domain_name}")

        {:keep_state, new_data}
    end
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

  defp configure_all_slaves(data) do
    Enum.reduce_while(data.slaves, {:ok, data}, fn {position, slave_info}, {:ok, acc_data} ->
      case configure_single_slave(acc_data, position, slave_info) do
        {:ok, new_data} -> {:cont, {:ok, new_data}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp configure_single_slave(data, position, slave_info) do
    driver_module = slave_info.driver
    slave_pid = slave_info.pid
    hw_slave_config = get_hw_slave_config(data, position)

    Logger.debug("Configuring slave #{position} (#{inspect(driver_module)})")

    with {:ok, slave_config_nif} <- get_slave_config_for_position(data, position),
         sdos <- driver_module.get_sdo_config(slave_pid),
         :ok <- apply_sdos(slave_config_nif, position, sdos),
         sync_managers <- driver_module.get_pdo_config(slave_pid),
         :ok <- configure_pdos(slave_config_nif, position, sync_managers),
         {:ok, new_data} <-
           register_entries(data, slave_config_nif, hw_slave_config, sync_managers) do
      {:ok, new_data}
    end
  end

  # Apply SDO configuration
  defp apply_sdos(slave_config_nif, position, sdos) do
    Enum.each(sdos, fn sdo ->
      case Nif.slave_config_sdo(slave_config_nif, sdo.index, sdo.subindex, sdo.data) do
        :ok ->
          Logger.debug(
            "Slave #{position}: Configured SDO 0x#{Integer.to_string(sdo.index, 16)}:#{sdo.subindex}"
          )

        {:error, reason} ->
          Logger.warning(
            "Slave #{position}: Failed to configure SDO 0x#{Integer.to_string(sdo.index, 16)}:#{sdo.subindex} - #{inspect(reason)}"
          )
      end
    end)

    :ok
  end

  # Configure PDOs - direct translation of ecrt_slave_config_pdos
  defp configure_pdos(slave_config_nif, position, sync_managers) do
    Enum.each(sync_managers, fn sm ->
      # Configure sync manager
      Nif.slave_config_sync_manager(slave_config_nif, sm.index, sm.direction, sm.watchdog)

      Logger.debug(
        "Slave #{position}: Configured SM#{sm.index} (#{sm.direction}, watchdog: #{sm.watchdog})"
      )

      # Clear PDO assignments
      Nif.slave_config_pdo_assign_clear(slave_config_nif, sm.index)

      # Configure each PDO
      Enum.each(sm.pdos, fn pdo ->
        # Assign PDO to sync manager
        Nif.slave_config_pdo_assign_add(slave_config_nif, sm.index, pdo.index)

        Logger.debug(
          "Slave #{position}: Assigned PDO 0x#{Integer.to_string(pdo.index, 16)} to SM#{sm.index}"
        )

        # Clear PDO mappings
        Nif.slave_config_pdo_mapping_clear(slave_config_nif, pdo.index)

        # Add entry mappings
        Enum.each(pdo.entries, fn {_entry_name, {index, subindex, bit_length}} ->
          Nif.slave_config_pdo_mapping_add(
            slave_config_nif,
            pdo.index,
            index,
            subindex,
            bit_length
          )
        end)
      end)
    end)

    :ok
  end

  # Register entries with domains based on registered_entries map
  defp register_entries(data, slave_config_nif, hw_slave_config, sync_managers) do
    # Build entry_registry as we register
    entry_registry =
      for {domain_name, entry_list} <- hw_slave_config.registered_entries,
          {pdo_name, entry_name} <- entry_list,
          into: %{} do
        # Find entry in sync_managers
        {index, subindex, bit_length, direction} =
          find_entry_in_sync_managers(sync_managers, pdo_name, entry_name)

        unique_name = "#{hw_slave_config.name}:#{pdo_name}:#{entry_name}"

        # Get domain ref
        domain_ref = data.domains[domain_name].ref

        # Register with NIF (skip gap entries 0x0000:0x00)
        if index != 0 or subindex != 0 do
          _offset =
            Nif.slave_config_reg_pdo_entry(
              slave_config_nif,
              unique_name,
              index,
              subindex,
              bit_length,
              domain_ref,
              direction
            )

          Logger.debug(
            "Registered #{unique_name} to domain #{domain_name} (direction: #{direction})"
          )
        end

        # Track in entry_registry
        {unique_name, domain_name}
      end

    # Merge new entries into Master's entry_registry
    new_data = %{data | entry_registry: Map.merge(data.entry_registry, entry_registry)}
    {:ok, new_data}
  end

  # Find entry details in sync_managers structure
  defp find_entry_in_sync_managers(sync_managers, pdo_name, entry_name) do
    Enum.find_value(sync_managers, fn sm ->
      pdo = Enum.find(sm.pdos, &(&1.name == pdo_name))

      if pdo && Map.has_key?(pdo.entries, entry_name) do
        {index, subindex, bit_length} = pdo.entries[entry_name]
        {index, subindex, bit_length, sm.direction}
      end
    end) || raise "Entry #{pdo_name}:#{entry_name} not found in sync_managers"
  end

  # Get hardware slave config from HardwareConfig
  defp get_hw_slave_config(data, position) do
    Enum.find(data.hardware_config.slaves, &(&1.position == position)) ||
      raise "No hardware config for slave at position #{position}"
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
        Logger.error(
          "Cyclic task crashed: #{inspect(reason)}, transitioning to :stale for recovery"
        )

        # Stop all slave drivers
        stop_all_slave_drivers(data)

        # Clear subscribers as system needs recovery
        Logger.debug("Clearing #{map_size(data.subscribers)} subscriber(s) due to task crash")

        # Reply to all pending writes with error and cancel their timers
        Enum.each(data.pending_writes, fn {_key, %{from: from, timer_ref: timer_ref}} ->
          :gen_statem.reply(from, {:error, :cyclic_task_crashed})
          Process.cancel_timer(timer_ref)
        end)

        # Reset state and transition to :stale
        new_data = %{
          data
          | task_pid: nil,
            slaves: %{},
            domains: %{},
            subscribers: %{},
            last_slave_count: nil,
            stability_timer_ref: nil,
            cycle_interval_us: nil,
            pending_writes: %{}
        }

        {:next_state, :stale, new_data}

      true ->
        # Check if it's a slave
        case Enum.find(data.slaves, fn {_pos, info} -> info.pid == pid end) do
          {position, _info} ->
            Logger.warning(
              "Slave #{position} exited: #{inspect(reason)}, transitioning to :stale"
            )

            # Stop remaining slave drivers
            stop_all_slave_drivers(data)

            # If cyclic task is running, kill it
            if data.task_pid do
              Process.exit(data.task_pid, :kill)
            end

            # Clear subscribers as slave drivers are being restarted
            Logger.debug(
              "Clearing #{map_size(data.subscribers)} subscriber(s) due to slave crash"
            )

            # Reply to all pending writes with error and cancel their timers
            Enum.each(data.pending_writes, fn {_key, %{from: from, timer_ref: timer_ref}} ->
              :gen_statem.reply(from, {:error, :slave_crashed})
              Process.cancel_timer(timer_ref)
            end)

            # Reset state and transition to :stale
            new_data = %{
              data
              | task_pid: nil,
                slaves: %{},
                domains: %{},
                subscribers: %{},
                last_slave_count: nil,
                stability_timer_ref: nil,
                cycle_interval_us: nil,
                pending_writes: %{}
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
        # Pass cycle_multiplier directly to NIF (no conversion needed)
        cycle_multiplier = domain_config.cycle_multiplier

        case Nif.master_create_domain(acc_data.master_ref, domain_config.name, self(), cycle_multiplier) do
          {:ok, domain_ref} ->
            domain_info = %{ref: domain_ref, cycle_multiplier: cycle_multiplier}
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

    # Start or replace slave drivers for each configured position
    result =
      Enum.reduce_while(slaves_by_position, {:ok, %{}}, fn {position, slave_config},
                                                           {:ok, acc_slaves} ->
        existing_slave = data.slaves[position]

        # If no existing slave, start a new one
        if existing_slave == nil do
          case start_configured_slave_driver(data, position, slave_config) do
            {:ok, slave_info} ->
              {:cont, {:ok, Map.put(acc_slaves, position, slave_info)}}

            {:error, reason} ->
              {:halt, {:error, {:failed_to_start_slave, position, reason}}}
          end
        else
          # Existing slave - check if we can reuse it
          requested_driver = slave_config.driver || EtherCAT.Slave.GenericDriver

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
        end
      end)

    case result do
      {:ok, new_slaves} -> {:ok, %{data | slaves: new_slaves}}
      error -> error
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
         driver_module = slave_config.driver || EtherCAT.Slave.GenericDriver,
         {:ok, pid} <-
           driver_module.start_link(
             master: self(),
             position: position,
             name: slave_config.name,
             config: slave_config.config
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
