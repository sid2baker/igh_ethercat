defmodule EtherCAT.Master2 do
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
    {slave_name, pdo_name, entry_name} => [pid, ...]
  }
  ```

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
          # Map of position => %{pid, name, vendor, product}
          slaves: %{non_neg_integer() => map()},
          # Map of domain_name => %{ref, interval}
          domains: %{atom() => %{ref: reference(), interval: pos_integer()}},
          # Map of {slave_name, pdo, entry} => [subscriber_pids]
          subscribers: %{{atom(), atom(), atom()} => [pid()]},
          task_pid: pid() | nil,
          scan_interval: pos_integer(),
          # Expected hardware configuration
          hardware_config: map() | nil,
          # Diff between expected and actual
          hardware_diff: map() | nil
        }

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    :gen_statem.start_link({:local, __MODULE__}, __MODULE__, opts, [])
  end

  def get_slaves(master \\ __MODULE__) do
    :gen_statem.call(master, :get_slaves)
  end

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

  def subscribe(master \\ __MODULE__, slave_name, pdo_name, entry_name, subscriber_pid) do
    :gen_statem.call(master, {:subscribe, slave_name, pdo_name, entry_name, subscriber_pid})
  end

  def unsubscribe(master \\ __MODULE__, slave_name, pdo_name, entry_name, subscriber_pid) do
    :gen_statem.call(master, {:unsubscribe, slave_name, pdo_name, entry_name, subscriber_pid})
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
        Registry.register(EtherCAT.Registry, {:master, master_index}, %{})

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

    if data.task_pid do
      Process.exit(data.task_pid, :kill)
    end

    Enum.each(data.slaves, fn {_position, slave_info} ->
      if Process.alive?(slave_info.pid), do: GenServer.stop(slave_info.pid)
    end)

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

  def scanning(:enter, _old_state, data) do
    Logger.info("Entered :scanning state - discovering slaves")
    {:keep_state_and_data, [{:next_event, :internal, :discover_slaves}]}
  end

  def scanning(:internal, :discover_slaves, data) do
    case Nif.get_master_state(data.master_ref) do
      {:ok, master_state} ->
        slave_count = master_state.slaves_responding
        Logger.info("Discovered #{slave_count} slaves")

        # Start driver processes for each slave
        slaves =
          for position <- 0..(slave_count - 1), into: %{} do
            {:ok, slave_info} = start_slave_driver(data, position)
            {position, slave_info}
          end

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

  def ready(:enter, _old_state, _data) do
    Logger.info("Entered :ready state - ready for configuration and activation")
    :keep_state_and_data
  end

  def ready({:call, from}, :get_slaves, data) do
    slave_pids = data.slaves |> Map.values() |> Enum.map(& &1.pid)
    {:keep_state_and_data, [{:reply, from, {:ok, slave_pids}}]}
  end

  def ready({:call, from}, {:create_domain, name, interval}, data) do
    case Map.has_key?(data.domains, name) do
      true ->
        {:keep_state_and_data, [{:reply, from, {:error, :domain_already_exists}}]}

      false ->
        case Nif.master_create_domain(data.master_ref, self(), interval) do
          {:ok, domain_ref} ->
            :ok = Nif.domain_set_pid(domain_ref, self())

            domain_info = %{ref: domain_ref, interval: interval}
            new_domains = Map.put(data.domains, name, domain_info)

            {:keep_state, %{data | domains: new_domains}, [{:reply, from, {:ok, domain_ref}}]}

          {:error, _} = error ->
            {:keep_state_and_data, [{:reply, from, error}]}
        end
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

  def ready({:call, from}, {:subscribe, slave_name, pdo_name, entry_name, subscriber_pid}, data) do
    Process.monitor(subscriber_pid)

    key = {slave_name, pdo_name, entry_name}
    new_subscribers = Map.update(data.subscribers, key, [subscriber_pid], &[subscriber_pid | &1])

    {:keep_state, %{data | subscribers: new_subscribers}, [{:reply, from, :ok}]}
  end

  def ready({:call, from}, {:unsubscribe, slave_name, pdo_name, entry_name, subscriber_pid}, data) do
    key = {slave_name, pdo_name, entry_name}

    new_subscribers =
      case data.subscribers[key] do
        nil ->
          data.subscribers

        pids ->
          updated = List.delete(pids, subscriber_pid)
          if updated == [], do: Map.delete(data.subscribers, key), else: Map.put(data.subscribers, key, updated)
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

  def operational({:call, from}, :get_hardware_diff, data) do
    {:keep_state_and_data, [{:reply, from, {:ok, data.hardware_diff}}]}
  end

  # Handle data change notifications from NIF
  def operational(:info, {:data_changed, unique_name, value}, data) do
    # Parse unique_name to extract slave/pdo/entry
    # Format: "slave_0:pdo_name:entry_name" or "slave_name:pdo_name:entry_name"
    case parse_unique_name(unique_name) do
      {:ok, slave_name, pdo_name, entry_name} ->
        key = {slave_name, pdo_name, entry_name}

        case data.subscribers[key] do
          nil ->
            :keep_state_and_data

          pids ->
            Enum.each(pids, fn pid ->
              send(pid, {:pdo_value_changed, slave_name, pdo_name, entry_name, value})
            end)

            :keep_state_and_data
        end

      :error ->
        :keep_state_and_data
    end
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
    {:ok, slave_info} = Nif.master_get_slave(data.master_ref, position)

    {:ok, slave_config} =
      Nif.master_slave_config(
        data.master_ref,
        0,
        position,
        slave_info.vendor_id,
        slave_info.product_code
      )

    driver_module = driver_for_slave(slave_info.vendor_id, slave_info.product_code)

    {:ok, pid} =
      driver_module.start_link(
        master: self(),
        position: position,
        slave_config: slave_config,
        vendor_id: slave_info.vendor_id,
        product_code: slave_info.product_code,
        revision: slave_info.revision_number,
        serial: slave_info.serial_number,
        sync_count: slave_info.sync_count,
        config: %{}
      )

    {:ok,
     %{
       pid: pid,
       name: :"slave_#{position}",
       vendor: slave_info.vendor_id,
       product: slave_info.product_code,
       driver: driver_module
     }}
  end

  defp driver_for_slave(0x02, 0x0C823052), do: EtherCAT.Drivers.Generic2
  defp driver_for_slave(_vendor_id, _product_code), do: EtherCAT.Drivers.Generic2

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

    # Step 1: Get and write SDO configuration
    sdo_configs = driver_module.get_sdo_config(slave_pid)

    Enum.each(sdo_configs, fn {index, subindex, sdo_data} ->
      # Get slave_config from driver
      {:ok, slave_config} = get_slave_config_for_position(data, position)

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

    # Step 2: Get PDO configuration from driver
    pdo_configs = driver_module.get_pdo_config(slave_pid)

    # Step 3: Group PDOs by sync manager
    pdos_by_sm =
      Enum.group_by(pdo_configs, fn pdo_config ->
        {sm_index, _direction, _watchdog} = pdo_config.sync_manager
        sm_index
      end)

    # Step 4: Configure each sync manager
    Enum.each(pdos_by_sm, fn {sm_index, sm_pdos} ->
      configure_sync_manager(data, position, sm_index, sm_pdos)
    end)

    # Step 5: Register PDO entries to domains
    register_pdo_entries(data, position, slave_info, pdo_configs)
  end

  defp configure_sync_manager(data, position, sm_index, sm_pdos) do
    {:ok, slave_config} = get_slave_config_for_position(data, position)

    # Get SM config from first PDO
    {_sm_index, direction, watchdog} = hd(sm_pdos).sync_manager

    # Step 1: Configure sync manager
    Logger.debug("Slave #{position}: Configuring SM#{sm_index} (#{direction})")
    Nif.slave_config_sync_manager(slave_config, sm_index, direction, watchdog)

    # Step 2: Clear PDO assignments
    Nif.slave_config_pdo_assign_clear(slave_config, sm_index)

    # Step 3: Add all PDO assignments for this SM
    pdo_indices = Enum.map(sm_pdos, & &1.pdo_index) |> Enum.uniq()

    Enum.each(pdo_indices, fn pdo_index ->
      Nif.slave_config_pdo_assign_add(slave_config, sm_index, pdo_index)
      Logger.debug("Slave #{position}: Assigned PDO 0x#{Integer.to_string(pdo_index, 16)} to SM#{sm_index}")
    end)

    # Step 4: Configure PDO mappings (if device supports it)
    supports_pdo_config = Map.get(hd(sm_pdos), :supports_pdo_config?, true)

    if supports_pdo_config do
      Enum.each(sm_pdos, fn pdo_config ->
        configure_pdo_mappings(slave_config, position, pdo_config)
      end)
    end
  end

  defp configure_pdo_mappings(slave_config, position, pdo_config) do
    pdo_index = pdo_config.pdo_index

    # Clear existing mappings
    Nif.slave_config_pdo_mapping_clear(slave_config, pdo_index)

    # Add all entry mappings
    Enum.each(pdo_config.entries, fn {entry_name, {_type, entry_index, entry_subindex, bit_length}} ->
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
    {:ok, slave_config} = get_slave_config_for_position(data, position)

    Enum.each(pdo_configs, fn pdo_config ->
      # Determine which domain this PDO belongs to
      domain_name = Map.get(pdo_config, :domain, :default_domain)

      case data.domains[domain_name] do
        nil ->
          Logger.warning(
            "Slave #{position}: Domain #{domain_name} not found, skipping PDO #{pdo_config.name}"
          )

        domain_info ->
          register_pdo_to_domain(
            slave_config,
            domain_info.ref,
            position,
            slave_info.name,
            pdo_config
          )
      end
    end)

    :ok
  end

  defp register_pdo_to_domain(slave_config, domain_ref, position, slave_name, pdo_config) do
    {_sm_index, direction, _watchdog} = pdo_config.sync_manager

    Enum.each(pdo_config.entries, fn {entry_name, {_type, entry_index, entry_subindex, bit_length}} ->
      # Build unique name for this entry
      unique_name = "#{slave_name}:#{pdo_config.name}:#{entry_name}"

      # Register with NIF
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
    end)
  end

  defp get_slave_config_for_position(data, position) do
    case data.slaves[position] do
      nil ->
        {:error, :slave_not_found}

      slave_info ->
        # Get slave_config from Registry
        case Registry.lookup(EtherCAT.Registry, {:slave, slave_info.pid}) do
          [{_pid, %{slave_config: slave_config}}] ->
            {:ok, slave_config}

          [] ->
            {:error, :slave_config_not_found}
        end
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

  defp parse_unique_name(unique_name) do
    case String.split(unique_name, ":") do
      [slave_part, pdo, entry] ->
        slave_name = String.to_atom(slave_part)
        {:ok, slave_name, String.to_atom(pdo), String.to_atom(entry)}

      _ ->
        :error
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
