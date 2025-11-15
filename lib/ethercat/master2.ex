defmodule EtherCAT.Master2 do
  @moduledoc """
  Simplified EtherCAT Master - manages network lifecycle and slave drivers.

  ## Key Simplifications

  1. **No Domain processes** - Domains are MapSets in Master state tracking intervals and entries
  2. **No Slave wrappers** - Drivers ARE the slave processes
  3. **Master orchestrates everything** - SDO/PDO config, NIF registration, I/O routing

  ## Architecture

  ```
  Master (GenServer)
    ├─ Manages NIF master reference
    ├─ Discovers slaves on bus
    ├─ Starts driver processes for each slave
    ├─ Fetches SDO/PDO configs from drivers
    ├─ Configures hardware via NIF
    ├─ Routes I/O between drivers and NIF
    └─ Manages domains as internal MapSets
  ```

  ## Domain Structure

  Domains are stored in Master state as:

  ```elixir
  %{
    domain_name: %{
      ref: reference(),           # NIF domain reference
      interval: pos_integer(),    # Update interval in µs
      entries: %{                 # Registered PDO entries
        unique_name => %{
          slave_pid: pid(),
          offset: non_neg_integer(),
          size: pos_integer(),
          type: atom(),
          direction: :input | :output
        }
      },
      subscribers: %{             # Value change subscribers
        unique_name => MapSet.t(pid())
      }
    }
  }
  ```

  ## States

  - `:offline` - Master created but not connected
  - `:scanning` - Connected, discovering slaves
  - `:ready` - Slaves configured, ready for activation
  - `:operational` - Cyclic mode active, PDO communication running
  """

  use GenServer
  require Logger

  alias EtherCAT.Nif

  defstruct [
    :master_ref,
    :master_index,
    :slaves,
    :domains,
    :task_pid,
    :scan_interval,
    :slave_fingerprint,
    :fingerprint_stable_since,
    :fingerprint_change_threshold,
    state: :offline
  ]

  @type domain_info :: %{
          ref: reference(),
          interval: pos_integer(),
          entries: %{String.t() => entry_metadata()},
          subscribers: %{String.t() => MapSet.t(pid())}
        }

  @type entry_metadata :: %{
          slave_pid: pid(),
          offset: non_neg_integer(),
          size: pos_integer(),
          type: atom(),
          direction: :input | :output
        }

  @type t :: %__MODULE__{
          master_ref: reference() | nil,
          master_index: non_neg_integer(),
          # Map of position => slave_pid
          slaves: %{non_neg_integer() => pid()},
          # Map of domain_name => domain_info
          domains: %{atom() => domain_info()},
          task_pid: pid() | nil,
          scan_interval: pos_integer(),
          slave_fingerprint: non_neg_integer() | nil,
          fingerprint_stable_since: integer() | nil,
          fingerprint_change_threshold: pos_integer(),
          state: :offline | :scanning | :ready | :operational
        }

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Start the Master process.

  ## Options
  - `:master_index` - EtherCAT master index (default: 0)
  - `:scan_interval` - Hardware scan interval in µs (default: 100_000)
  - `:fingerprint_change_threshold` - Hardware stability threshold in ms (default: 2_000)
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get the list of slave PIDs managed by this master.
  """
  def get_slaves(master \\ __MODULE__) do
    GenServer.call(master, :get_slaves)
  end

  @doc """
  Create a domain with the specified update interval.

  Domains group PDO entries with the same cyclic update rate.
  """
  def create_domain(master \\ __MODULE__, name, interval_us) do
    GenServer.call(master, {:create_domain, name, interval_us})
  end

  @doc """
  Start cyclic mode - activates master and begins PDO communication.
  """
  def start_cyclic(master \\ __MODULE__, cycle_interval, nif_yield_interval) do
    GenServer.call(master, {:start_cyclic, cycle_interval, nif_yield_interval}, 30_000)
  end

  @doc """
  Stop cyclic mode - deactivates master and halts PDO communication.
  """
  def stop_cyclic(master \\ __MODULE__) do
    GenServer.call(master, :stop_cyclic)
  end

  @doc """
  Read raw binary data from a PDO entry.

  Called by driver processes to fetch data from the NIF.
  """
  def read_pdo_entry(master \\ __MODULE__, domain_name, unique_name) do
    GenServer.call(master, {:read_pdo_entry, domain_name, unique_name})
  end

  @doc """
  Write raw binary data to a PDO entry.

  Called by driver processes to send data to the NIF.
  """
  def write_pdo_entry(master \\ __MODULE__, domain_name, unique_name, binary_data) do
    GenServer.call(master, {:write_pdo_entry, domain_name, unique_name, binary_data})
  end

  @doc """
  Subscribe to PDO value changes.

  Called by driver processes to register subscribers for value change notifications.
  """
  def subscribe_pdo_entry(master \\ __MODULE__, domain_name, unique_name, subscriber_pid) do
    GenServer.call(master, {:subscribe, domain_name, unique_name, subscriber_pid})
  end

  @doc """
  Unsubscribe from PDO value changes.
  """
  def unsubscribe_pdo_entry(master \\ __MODULE__, domain_name, unique_name, subscriber_pid) do
    GenServer.call(master, {:unsubscribe, domain_name, unique_name, subscriber_pid})
  end

  @doc """
  Get sync manager information for a slave.

  Called by drivers during PDO discovery.
  """
  def get_sync_manager(master \\ __MODULE__, position, sync_index) do
    GenServer.call(master, {:get_sync_manager, position, sync_index})
  end

  @doc """
  Get PDO information for a slave.

  Called by drivers during PDO discovery.
  """
  def get_pdo(master \\ __MODULE__, position, sync_index, pdo_pos) do
    GenServer.call(master, {:get_pdo, position, sync_index, pdo_pos})
  end

  @doc """
  Get PDO entry information for a slave.

  Called by drivers during PDO discovery.
  """
  def get_pdo_entry(master \\ __MODULE__, position, sync_index, pdo_pos, entry_pos) do
    GenServer.call(master, {:get_pdo_entry, position, sync_index, pdo_pos, entry_pos})
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    master_index = Keyword.get(opts, :master_index, 0)
    scan_interval = Keyword.get(opts, :scan_interval, 100_000)
    fingerprint_change_threshold = Keyword.get(opts, :fingerprint_change_threshold, 2_000)

    case Nif.request_master(master_index) do
      {:ok, ref} ->
        # Register in Registry for discovery
        Registry.register(EtherCAT.Registry, {:master, master_index}, %{})

        state = %__MODULE__{
          master_ref: ref,
          master_index: master_index,
          slaves: %{},
          domains: %{},
          task_pid: nil,
          scan_interval: scan_interval,
          slave_fingerprint: nil,
          fingerprint_stable_since: nil,
          fingerprint_change_threshold: fingerprint_change_threshold,
          state: :offline
        }

        Logger.info("Master #{master_index} initialized")

        # Auto-connect and start scanning
        {:ok, state, {:continue, :connect}}

      :error ->
        Logger.error("Failed to create master #{master_index}")
        {:stop, :failed_to_create_master}
    end
  end

  @impl true
  def handle_continue(:connect, state) do
    case Nif.get_master_state(state.master_ref) do
      {:ok, master_state} when master_state.link_up == 1 ->
        Logger.info("Master connected, starting slave discovery")
        {:noreply, %{state | state: :scanning}, {:continue, :discover_slaves}}

      {:ok, _} ->
        Logger.warning("Master link down, retrying...")
        Process.send_after(self(), :retry_connect, state.scan_interval)
        {:noreply, state}

      {:error, reason} ->
        Logger.error("Connection failed: #{inspect(reason)}")
        Process.send_after(self(), :retry_connect, state.scan_interval)
        {:noreply, state}
    end
  end

  def handle_continue(:discover_slaves, state) do
    case Nif.get_master_state(state.master_ref) do
      {:ok, master_state} ->
        slave_count = master_state.slaves_responding
        Logger.info("Discovered #{slave_count} slaves")

        # Start driver processes for each slave
        slaves =
          for position <- 0..(slave_count - 1), into: %{} do
            {:ok, slave_pid} = start_slave_driver(state, position)
            {position, slave_pid}
          end

        new_state = %{state | slaves: slaves, state: :ready}
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("Failed to discover slaves: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:get_slaves, _from, state) do
    slave_pids = Map.values(state.slaves)
    {:reply, {:ok, slave_pids}, state}
  end

  def handle_call({:create_domain, name, interval}, _from, state) do
    case Map.has_key?(state.domains, name) do
      true ->
        {:reply, {:error, :domain_already_exists}, state}

      false ->
        case Nif.master_create_domain(state.master_ref, self(), interval) do
          {:ok, domain_ref} ->
            # Set PID for cyclic task messaging
            :ok = Nif.domain_set_pid(domain_ref, self())

            domain_info = %{
              ref: domain_ref,
              interval: interval,
              entries: %{},
              subscribers: %{}
            }

            new_domains = Map.put(state.domains, name, domain_info)
            {:reply, {:ok, domain_ref}, %{state | domains: new_domains}}

          {:error, _} = error ->
            {:reply, error, state}
        end
    end
  end

  def handle_call({:start_cyclic, cycle_interval, nif_yield_interval}, _from, state) do
    Logger.info("Starting cyclic mode")

    # Register all PDO entries from all slaves
    result = register_all_pdo_entries(state)

    case result do
      :ok ->
        # Activate master
        case Nif.master_activate(state.master_ref) do
          :ok ->
            # Start cyclic task
            domain_refs = state.domains |> Map.values() |> Enum.map(& &1.ref)

            task_pid =
              spawn_link(fn ->
                Nif.cyclic_task(
                  self(),
                  state.master_ref,
                  domain_refs,
                  cycle_interval,
                  nif_yield_interval
                )
              end)

            new_state = %{state | task_pid: task_pid, state: :operational}
            {:reply, :ok, new_state}

          {:error, _} = error ->
            {:reply, error, state}
        end

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:stop_cyclic, _from, %{task_pid: nil} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:stop_cyclic, _from, state) do
    # Kill cyclic task
    Process.exit(state.task_pid, :kill)

    # Wait for termination messages
    receive do
      {:EXIT, _pid, _} -> :ok
    after
      3000 -> Logger.warning("Timeout waiting for cyclic task exit")
    end

    receive do
      :cyclic_task_died -> :ok
    after
      3000 -> Logger.warning("Timeout waiting for cyclic task died message")
    end

    new_state = %{state | task_pid: nil, state: :ready}
    {:reply, :ok, new_state}
  end

  def handle_call({:read_pdo_entry, domain_name, unique_name}, _from, state) do
    case get_in(state.domains, [domain_name, :ref]) do
      nil ->
        {:reply, {:error, :domain_not_found}, state}

      domain_ref ->
        result =
          case Nif.get_value(domain_ref, unique_name) do
            {:error, _} = error -> error
            value -> {:ok, value}
          end

        {:reply, result, state}
    end
  end

  def handle_call({:write_pdo_entry, domain_name, unique_name, binary_data}, _from, state) do
    case get_in(state.domains, [domain_name, :ref]) do
      nil ->
        {:reply, {:error, :domain_not_found}, state}

      domain_ref ->
        result = Nif.set_value(domain_ref, unique_name, binary_data)
        {:reply, result, state}
    end
  end

  def handle_call({:subscribe, domain_name, unique_name, subscriber_pid}, _from, state) do
    case get_in(state.domains, [domain_name]) do
      nil ->
        {:reply, {:error, :domain_not_found}, state}

      domain_info ->
        # Monitor subscriber
        Process.monitor(subscriber_pid)

        # Add to subscribers
        subscribers =
          Map.update(
            domain_info.subscribers,
            unique_name,
            MapSet.new([subscriber_pid]),
            &MapSet.put(&1, subscriber_pid)
          )

        new_domain_info = %{domain_info | subscribers: subscribers}
        new_domains = Map.put(state.domains, domain_name, new_domain_info)

        {:reply, :ok, %{state | domains: new_domains}}
    end
  end

  def handle_call({:unsubscribe, domain_name, unique_name, subscriber_pid}, _from, state) do
    case get_in(state.domains, [domain_name]) do
      nil ->
        {:reply, {:error, :domain_not_found}, state}

      domain_info ->
        subscribers =
          case domain_info.subscribers[unique_name] do
            nil ->
              domain_info.subscribers

            pids ->
              updated = MapSet.delete(pids, subscriber_pid)

              if MapSet.size(updated) == 0 do
                Map.delete(domain_info.subscribers, unique_name)
              else
                Map.put(domain_info.subscribers, unique_name, updated)
              end
          end

        new_domain_info = %{domain_info | subscribers: subscribers}
        new_domains = Map.put(state.domains, domain_name, new_domain_info)

        {:reply, :ok, %{state | domains: new_domains}}
    end
  end

  def handle_call({:get_sync_manager, position, sync_index}, _from, state) do
    result = Nif.master_get_sync_manager(state.master_ref, position, sync_index)
    {:reply, result, state}
  end

  def handle_call({:get_pdo, position, sync_index, pdo_pos}, _from, state) do
    result = Nif.master_get_pdo(state.master_ref, position, sync_index, pdo_pos)
    {:reply, result, state}
  end

  def handle_call({:get_pdo_entry, position, sync_index, pdo_pos, entry_pos}, _from, state) do
    result = Nif.master_get_pdo_entry(state.master_ref, position, sync_index, pdo_pos, entry_pos)
    {:reply, result, state}
  end

  @impl true
  def handle_info(:retry_connect, state) do
    {:noreply, state, {:continue, :connect}}
  end

  # Handle data change notifications from NIF
  def handle_info({:data_changed, unique_name, value}, state) do
    # Find which domain this belongs to and notify subscribers
    Enum.each(state.domains, fn {_domain_name, domain_info} ->
      case domain_info.subscribers[unique_name] do
        nil ->
          :ok

        subscribers ->
          Enum.each(subscribers, fn pid ->
            send(pid, {:pdo_value_changed, unique_name, value})
          end)
      end
    end)

    {:noreply, state}
  end

  # Handle subscriber process death
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Remove from all subscriber lists
    new_domains =
      Map.new(state.domains, fn {name, domain_info} ->
        new_subscribers =
          Map.new(domain_info.subscribers, fn {unique_name, pids} ->
            updated = MapSet.delete(pids, pid)

            if MapSet.size(updated) == 0 do
              nil
            else
              {unique_name, updated}
            end
          end)
          |> Enum.reject(&is_nil/1)
          |> Map.new()

        {name, %{domain_info | subscribers: new_subscribers}}
      end)

    {:noreply, %{state | domains: new_domains}}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    cond do
      pid == state.task_pid ->
        Logger.warning("Cyclic task exited: #{inspect(reason)}")
        {:noreply, %{state | task_pid: nil, state: :ready}}

      Map.values(state.slaves) |> Enum.member?(pid) ->
        # Find and remove dead slave
        position = Enum.find_value(state.slaves, fn {pos, p} -> if p == pid, do: pos end)
        Logger.warning("Slave at position #{position} exited: #{inspect(reason)}")
        new_slaves = Map.delete(state.slaves, position)
        {:noreply, %{state | slaves: new_slaves}}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Master terminating: #{inspect(reason)}")

    if state.task_pid do
      Process.exit(state.task_pid, :kill)
    end

    # Terminate all slaves
    Enum.each(state.slaves, fn {_position, pid} ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    :ok
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Start a driver process for a discovered slave
  defp start_slave_driver(state, position) do
    {:ok, slave_info} = Nif.master_get_slave(state.master_ref, position)

    {:ok, slave_config} =
      Nif.master_slave_config(
        state.master_ref,
        0,
        position,
        slave_info.vendor_id,
        slave_info.product_code
      )

    # Determine driver module based on vendor/product
    driver_module = driver_for_slave(slave_info.vendor_id, slave_info.product_code)

    # Start driver process
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
  end

  # Map vendor/product to driver module
  defp driver_for_slave(0x02, 0x07113052), do: EtherCAT.Drivers.EL1809
  defp driver_for_slave(0x02, 0x0AF93052), do: EtherCAT.Drivers.EL2809
  defp driver_for_slave(0x02, 0x0C823052), do: EtherCAT.Drivers.EL3202
  defp driver_for_slave(_vendor_id, _product_code), do: EtherCAT.Drivers.Generic

  # Register all PDO entries from all slaves to their respective domains
  defp register_all_pdo_entries(state) do
    Enum.reduce_while(state.slaves, :ok, fn {_position, slave_pid}, :ok ->
      # Get SDO config and write to device
      case apply_sdo_config(slave_pid, state.master_ref) do
        :ok ->
          # Get PDO config and register entries
          case register_slave_pdo_config(slave_pid, state) do
            :ok -> {:cont, :ok}
            {:error, _} = error -> {:halt, error}
          end

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  # Apply SDO configuration from driver
  defp apply_sdo_config(slave_pid, _master_ref) do
    # Get SDO list from driver
    _sdo_list = slave_pid |> driver_module_for_pid() |> apply(:get_sdo_config, [slave_pid])

    # TODO: Write SDOs via NIF
    # For now, drivers will handle this internally during init
    :ok
  end

  # Register slave's PDO configuration
  defp register_slave_pdo_config(slave_pid, state) do
    driver_module = driver_module_for_pid(slave_pid)
    pdo_configs = apply(driver_module, :get_pdo_config, [slave_pid])

    # TODO: Process PDO configs and register to domains
    # This requires:
    # 1. Configure sync managers
    # 2. Clear and add PDO assignments
    # 3. Clear and add PDO mappings
    # 4. Register entries to domains via NIF
    # 5. Store metadata in domain's entries map

    Logger.debug("Slave #{inspect(slave_pid)}: Got #{length(pdo_configs)} PDO configs")
    :ok
  end

  # Get driver module for a slave PID
  defp driver_module_for_pid(pid) do
    # Look up in Registry
    case Registry.lookup(EtherCAT.Registry, {:slave, pid}) do
      [{_pid, %{driver: driver}}] -> driver
      [] -> EtherCAT.Drivers.Generic
    end
  end
end
