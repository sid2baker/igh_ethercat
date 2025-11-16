defmodule EtherCAT.Master do
  @moduledoc """
  Simplified EtherCAT Master using gen_statem.

  ## State Machine

  ```
  :offline ──connect──> :scanning ──discover──> :ready ──activate──> :operational
                                                    ↑                      │
                                                    └──────stop_cyclic─────┘
  ```

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
    :hardware_config,
    :hardware_diff
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
          scan_interval: pos_integer(),
          # Expected hardware configuration
          hardware_config: map() | nil,
          # Diff between expected and actual
          hardware_diff: map() | nil
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
  Get the driver module for a given slave PID.

  ## Parameters
  - `master` - Master process PID or registered name
  - `slave_pid` - Slave process PID

  ## Returns
  - `{:ok, driver_module}` - The driver module for the slave
  - `{:error, :slave_not_found}` - Slave not found in master's slaves map
  """
  def get_slave_driver(master \\ __MODULE__, slave_pid) do
    :gen_statem.call(master, {:get_slave_driver, slave_pid})
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
  Configure hardware using HardwareConfig and start all slave drivers.

  This function:
  1. Creates domains from the config
  2. Starts slave driver processes with config-specified names and modules
  3. Configures all slaves (SDOs, PDOs, domain registration)
  4. Starts cyclic mode
  5. Returns a map of slave names to PIDs

  ## Parameters
  - `master` - Master process (PID or module name)
  - `config` - HardwareConfig struct with master, domains, and slaves

  ## Returns
  - `{:ok, %{slave_name => pid}}` - Map of slave names to driver PIDs
  - `{:error, reason}` - Configuration error
  """
  @spec configure_and_start_slaves(pid() | atom(), EtherCAT.Config.HardwareConfig.t()) ::
          {:ok, %{atom() => pid()}} | {:error, term()}
  def configure_and_start_slaves(master \\ __MODULE__, config) do
    :gen_statem.call(master, {:configure_and_start_slaves, config}, 30_000)
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
    scan_interval = Keyword.get(opts, :scan_interval, 100_000)

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
          hardware_config: nil,
          hardware_diff: nil
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
        Logger.info("Master connected, transitioning to :scanning")
        {:next_state, :scanning, data}

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
  # State: :scanning
  # ============================================================================

  def scanning(:enter, _old_state, _data) do
    Logger.info("Entered :scanning state - discovering slaves")
    {:keep_state_and_data, [{:state_timeout, 0, :discover_slaves}]}
  end

  def scanning(:state_timeout, :discover_slaves, data) do
    case Nif.get_master_state(data.master_ref) do
      {:ok, master_state} ->
        slave_count = master_state.slaves_responding
        Logger.info("Discovered #{slave_count} slaves")

        # Start driver processes for each slave with error handling
        result =
          Enum.reduce_while(0..(slave_count - 1), {:ok, %{}}, fn position, {:ok, acc_slaves} ->
            case start_slave_driver(data, position) do
              {:ok, slave_info} ->
                {:cont, {:ok, Map.put(acc_slaves, position, slave_info)}}

              {:error, reason} ->
                Logger.error("Failed to start driver for slave #{position}: #{inspect(reason)}")
                {:halt, {:error, {:slave_driver_start_failed, position, reason}}}
            end
          end)

        case result do
          {:ok, slaves} ->
            # Generate hardware diff if we have expected config
            hardware_diff =
              if data.hardware_config do
                generate_hardware_diff(data.hardware_config, slaves)
              else
                nil
              end

            new_data = %{data | slaves: slaves, hardware_diff: hardware_diff}
            {:next_state, :ready, new_data}

          {:error, reason} ->
            Logger.error("Failed to start all slave drivers: #{inspect(reason)}")
            {:next_state, :offline, data}
        end

      {:error, reason} ->
        Logger.error("Failed to discover slaves: #{inspect(reason)}")
        {:next_state, :offline, data}
    end
  end

  def scanning({:call, from}, _event, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :scanning}}]}
  end

  def scanning(_event_type, _event, _data) do
    :keep_state_and_data
  end

  # ============================================================================
  # State: :ready
  # ============================================================================

  def ready(:enter, _old_state, data) do
    Logger.info("Entered :ready state - ready for configuration and activation")

    # Auto-create default_domain if it doesn't exist
    case Map.has_key?(data.domains, :default_domain) do
      true ->
        :keep_state_and_data

      false ->
        Logger.info("Auto-creating :default_domain with 1000µs interval")

        case Nif.master_create_domain(data.master_ref, :default_domain, 1000) do
          {:ok, domain_ref} ->
            domain_info = %{ref: domain_ref, interval: 1000}
            new_domains = Map.put(data.domains, :default_domain, domain_info)
            {:keep_state, %{data | domains: new_domains}}

          {:error, reason} ->
            Logger.warning(
              "Failed to create default_domain: #{inspect(reason)}, continuing anyway"
            )

            :keep_state_and_data
        end
    end
  end

  def ready({:call, from}, :get_slaves, data) do
    slave_pids = data.slaves |> Map.values() |> Enum.map(& &1.pid)
    {:keep_state_and_data, [{:reply, from, {:ok, slave_pids}}]}
  end

  def ready({:call, from}, {:get_slave_driver, slave_pid}, data) do
    result =
      data.slaves
      |> Enum.find_value(fn {_pos, slave_info} ->
        if slave_info.pid == slave_pid, do: {:ok, slave_info.driver}
      end)

    case result do
      {:ok, _} = success -> {:keep_state_and_data, [{:reply, from, success}]}
      nil -> {:keep_state_and_data, [{:reply, from, {:error, :slave_not_found}}]}
    end
  end

  def ready({:call, from}, {:create_domain, name, interval}, data) do
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

  def ready({:call, from}, {:configure_and_start_slaves, config}, data) do
    Logger.info("Configuring hardware from HardwareConfig")

    alias EtherCAT.Config.HardwareConfig

    with :ok <- HardwareConfig.validate(config),
         {:ok, data_with_domains} <- create_domains_from_config(data, config),
         {:ok, data_with_slaves} <- start_slaves_from_config(data_with_domains, config),
         :ok <- configure_all_slaves(data_with_slaves),
         {:ok, operational_data} <- activate_and_start_cyclic(data_with_slaves, config) do
      # Build map of slave names to PIDs
      slave_map =
        operational_data.slaves
        |> Enum.map(fn {_position, slave_info} -> {slave_info.name, slave_info.pid} end)
        |> Map.new()

      {:next_state, :operational, operational_data, [{:reply, from, {:ok, slave_map}}]}
    else
      {:error, _} = error ->
        Logger.error("Failed to configure hardware: #{inspect(error)}")
        {:keep_state_and_data, [{:reply, from, error}]}
    end
  end

  def ready({:call, from}, {:start_cyclic, cycle_interval, nif_yield_interval}, data) do
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

  def ready({:call, from}, {:get_sync_manager, position, sync_index}, data) do
    result = Nif.master_get_sync_manager(data.master_ref, position, sync_index)
    {:keep_state_and_data, [{:reply, from, result}]}
  end

  def ready({:call, from}, {:get_pdo, position, sync_index, pdo_pos}, data) do
    result = Nif.master_get_pdo(data.master_ref, position, sync_index, pdo_pos)
    {:keep_state_and_data, [{:reply, from, result}]}
  end

  def ready({:call, from}, {:get_pdo_entry, position, sync_index, pdo_pos, entry_pos}, data) do
    result = Nif.master_get_pdo_entry(data.master_ref, position, sync_index, pdo_pos, entry_pos)
    {:keep_state_and_data, [{:reply, from, result}]}
  end

  def ready({:call, from}, :get_hardware_diff, data) do
    {:keep_state_and_data, [{:reply, from, {:ok, data.hardware_diff}}]}
  end

  def ready({:call, from}, :generate_config, _data) do
    # TODO: Implement hardware config generation from discovered slaves
    # For now, return a placeholder error
    {:keep_state_and_data, [{:reply, from, {:error, :not_implemented}}]}
  end

  def ready({:call, from}, {:subscribe, domain_name, unique_name, subscriber_pid}, data) do
    Process.monitor(subscriber_pid)

    key = {domain_name, unique_name}
    new_subscribers = Map.update(data.subscribers, key, [subscriber_pid], &[subscriber_pid | &1])

    {:keep_state, %{data | subscribers: new_subscribers}, [{:reply, from, :ok}]}
  end

  def ready({:call, from}, {:unsubscribe, domain_name, unique_name, subscriber_pid}, data) do
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

  def ready(:info, {:DOWN, _ref, :process, pid, _reason}, data) do
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

  def ready(:info, {:EXIT, pid, reason}, data) do
    handle_exit(pid, reason, data)
  end

  def ready(_event_type, _event, _data) do
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
    Logger.info("Stopping cyclic mode")

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

    new_data = %{data | task_pid: nil}
    {:next_state, :ready, new_data, [{:reply, from, :ok}]}
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

  def operational({:call, from}, {:get_slave_driver, slave_pid}, data) do
    result =
      data.slaves
      |> Enum.find_value(fn {_pos, slave_info} ->
        if slave_info.pid == slave_pid, do: {:ok, slave_info.driver}
      end)

    case result do
      {:ok, _} = success -> {:keep_state_and_data, [{:reply, from, success}]}
      nil -> {:keep_state_and_data, [{:reply, from, {:error, :slave_not_found}}]}
    end
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
             slave_config: slave_config,
             vendor_id: slave_info.vendor_id,
             product_code: slave_info.product_code,
             revision: slave_info.revision_number,
             serial: slave_info.serial_number,
             sync_count: slave_info.sync_count,
             eeprom_data: eeprom_data,
             config: %{}
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

  defp driver_for_slave(0x02, 0x0C823052), do: EtherCAT.Drivers.Generic
  defp driver_for_slave(_vendor_id, _product_code), do: EtherCAT.Drivers.Generic

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
        Logger.warning("Cyclic task exited: #{inspect(reason)}")
        {:next_state, :ready, %{data | task_pid: nil}}

      true ->
        # Check if it's a slave
        case Enum.find(data.slaves, fn {_pos, info} -> info.pid == pid end) do
          {position, _info} ->
            Logger.warning("Slave #{position} exited: #{inspect(reason)}")
            new_slaves = Map.delete(data.slaves, position)
            {:keep_state, %{data | slaves: new_slaves}}

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
            requested_driver = slave_config.driver || EtherCAT.Drivers.Generic

            # Reuse Generic driver only if name hasn't changed (to avoid PDO re-discovery deadlock)
            if existing_slave.driver == EtherCAT.Drivers.Generic and
                 requested_driver == EtherCAT.Drivers.Generic and
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
         driver_module = slave_config.driver || EtherCAT.Drivers.Generic,
         {:ok, pid} <-
           driver_module.start_link(
             master: self(),
             position: position,
             name: slave_config.name,
             slave_config: slave_config_ref,
             vendor_id: slave_info.vendor_id,
             product_code: slave_info.product_code,
             revision: slave_info.revision_number,
             serial: slave_info.serial_number,
             sync_count: slave_info.sync_count,
             eeprom_data: eeprom_data,
             config: slave_config.config || %{}
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
