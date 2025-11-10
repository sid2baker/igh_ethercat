defmodule EtherCAT.Slave do
  @moduledoc """
  GenServer managing individual EtherCAT slave device with driver-based PDO configuration.
  """
  use GenServer
  require Logger

  alias EtherCAT.{Master, Domain}

  defstruct [
    :driver,
    :driver_state,
    :master,
    :alias,
    :position,
    :vendor_id,
    :product_code,
    :revision,
    :serial,
    :slave_config,
    :sync_count,
    :pdo_registrations,
    locked?: false,
    configured?: false
  ]

  @type t :: %__MODULE__{
          driver: atom() | nil,
          driver_state: map(),
          master: Master.t(),
          alias: non_neg_integer(),
          position: non_neg_integer(),
          vendor_id: non_neg_integer(),
          product_code: non_neg_integer(),
          slave_config: reference() | nil,
          pdo_registrations: %{(unique_name :: String.t()) => domain()},
          locked?: boolean(),
          configured?: boolean()
        }

  @type name :: String.t()
  @type domain :: atom()
  @type offset :: non_neg_integer()
  @type size :: non_neg_integer()

  # Client API

  @doc """
  Starts a slave process linked to the calling process.

  This function is typically called by the Master during slave synchronization.
  It initializes the slave with a driver and begins auto-discovery if using
  the Generic driver.

  ## Parameters
  - `opts` - Keyword list with:
    - `:master` - The master process PID
    - `:position` - The slave's position on the bus (0-based)
    - `:driver` - The driver module implementing `EtherCAT.Slave.Driver`
    - `:slave_config` - The slave configuration reference from the NIF
    - `:sync_count` - Number of sync managers available on the device

  ## Returns
  - `{:ok, pid}` - The slave process PID

  ## Example

      {:ok, slave} = Slave.start_link(
        master: master_pid,
        position: 1,
        driver: EtherCAT.Drivers.Generic,
        slave_config: config_ref,
        sync_count: 4
      )
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    master = Keyword.fetch!(opts, :master)
    position = Keyword.fetch!(opts, :position)
    driver = Keyword.fetch!(opts, :driver)
    slave_config = Keyword.fetch!(opts, :slave_config)
    sync_count = Keyword.fetch!(opts, :sync_count)

    GenServer.start_link(__MODULE__, {master, position, driver, slave_config, sync_count})
  end

  @doc """
  Applies driver-specific configuration to the slave.

  The configuration map is passed to the driver's `configure/2` callback,
  allowing device-specific initialization and setup.

  ## Parameters
  - `slave` - The slave process PID
  - `config` - Configuration map (driver-specific)
  - `timeout` - Call timeout in milliseconds (default: 5000)

  ## Example

      Slave.configure(slave, %{sample_rate: 1000, mode: :continuous})
  """
  @spec configure(pid(), map(), timeout()) :: :ok
  def configure(slave, config, timeout \\ 5000) do
    GenServer.call(slave, {:configure, config}, timeout)
  end

  @doc """
  Lists all available PDO names from the slave's driver.

  The returned list depends on the driver implementation:
  - Generic driver: Auto-discovered names like "pdo_6000:1"
  - Device-specific drivers: Semantic names like :temperature, :pressure

  ## Parameters
  - `slave` - The slave process PID
  - `timeout` - Call timeout in milliseconds (default: 5000)

  ## Returns
  List of PDO identifiers (atoms or strings)

  ## Example

      pdos = Slave.list_pdos(slave)
      #=> [:input1, :input2, :output1]
  """
  @spec list_pdos(pid(), timeout()) :: [atom() | String.t()]
  def list_pdos(slave, timeout \\ 5000) do
    GenServer.call(slave, :list_pdos, timeout)
  end

  # Introspection API

  @doc """
  Gets sync manager information for the specified sync index.
  All NIF communication goes through Master to prevent race conditions.
  """
  def get_sync_manager(slave, sync_index) do
    GenServer.call(slave, {:get_sync_manager, sync_index})
  end

  @doc """
  Gets PDO information at the specified sync manager and position.
  All NIF communication goes through Master to prevent race conditions.
  """
  def get_pdo(slave, sync_index, pdo_pos) do
    GenServer.call(slave, {:get_pdo, sync_index, pdo_pos})
  end

  @doc """
  Gets PDO entry information at the specified position.
  All NIF communication goes through Master to prevent race conditions.
  """
  def get_pdo_entry(slave, sync_index, pdo_pos, entry_pos) do
    GenServer.call(slave, {:get_pdo_entry, sync_index, pdo_pos, entry_pos})
  end

  @doc """
  Registers a named PDO to a domain for cyclic data exchange.

  This function incrementally configures the slave's sync managers and PDO mappings
  based on the driver's configuration, then registers the PDO entry with the specified
  domain for real-time I/O.

  **IMPORTANT:** You must call `Slave.configure/2` before calling this function.

  ## Parameters
  - `slave` - The slave process PID
  - `name` - PDO name (from `list_pdos/1`)
  - `domain` - Domain identifier (default: `:default_domain`)
  - `timeout` - Call timeout in milliseconds (default: 10_000 for configuration)

  ## Returns
  - `{:ok, unique_name}` - Unique PDO name (e.g., `"slave_0:pdo_6000:1"`)
  - `{:error, reason}` - Error if registration fails

  ## Example

      # Configure the slave first
      :ok = Slave.configure(slave, %{})

      # Register PDOs incrementally to different domains
      {:ok, "slave_0:input1"} = Slave.register_pdo(slave, :input1, :fast_domain)
      {:ok, "slave_0:input2"} = Slave.register_pdo(slave, :input2, :slow_domain)
  """
  @spec register_pdo(pid(), name(), domain(), timeout()) ::
          {:ok, String.t()} | {:error, term()}
  def register_pdo(slave, name, domain \\ :default_domain, timeout \\ 10_000) do
    GenServer.call(slave, {:register_pdo, name, domain}, timeout)
  end

  @doc """
  Convenience function to register all available PDOs to a domain.

  Calls `register_pdo/3` for each PDO returned by `list_pdos/1`.

  ## Returns
  - `{:ok, unique_names}` - List of unique PDO names
  - `{:error, reason}` - Error if any registration fails

  ## Example

      # Register all PDOs to the default domain
      {:ok, unique_names} = Slave.register_all_pdos(slave)

      # Register all PDOs to a custom domain
      {:ok, unique_names} = Slave.register_all_pdos(slave, :slow_domain)
  """
  @spec register_all_pdos(pid(), domain()) :: {:ok, [String.t()]} | {:error, term()}
  def register_all_pdos(slave, domain \\ :default_domain) do
    all_pdos = list_pdos(slave)

    # Register each PDO individually
    results =
      Enum.map(all_pdos, fn pdo ->
        register_pdo(slave, pdo, domain)
      end)

    # Check if any failed
    case Enum.find(results, fn result -> match?({:error, _}, result) end) do
      {:error, reason} -> {:error, reason}
      nil -> {:ok, Enum.map(results, fn {:ok, name} -> name end)}
    end
  end

  @doc """
  Returns true if slave is locked (operational mode active).

  Locked slaves cannot accept configuration changes.
  """
  @spec locked?(pid()) :: boolean()
  def locked?(slave) do
    GenServer.call(slave, :locked?)
  end

  @doc false
  @spec lock(pid()) :: :ok
  def lock(slave) do
    GenServer.call(slave, :lock)
  end

  @doc """
  Configure an SDO (Service Data Object) value on the slave.

  This function should be called from within a driver's `configure/2` callback
  to set SDO parameters before the master is activated.

  ## Parameters
  - `slave` - The slave process PID (passed to driver configure callback)
  - `sdo_index` - SDO index (0x0000-0xFFFF)
  - `sdo_subindex` - SDO subindex (0x00-0xFF)
  - `data` - Binary data to write

  ## Returns
  - `:ok` on success
  - `{:error, reason}` on failure

  ## Example

      # In driver configure/2 callback
      def configure(slave, config) do
        # Configure temperature limit (int16 value)
        limit = Map.get(config, :limit1, 1000)
        data = <<limit::little-signed-16>>
        :ok = Slave.config_sdo(slave, 0x8000, 0x13, data)

        {:ok, %{configured: true}}
      end
  """
  @spec config_sdo(pid(), 0x0000..0xFFFF, 0x00..0xFF, binary()) :: :ok | {:error, term()}
  def config_sdo(slave, sdo_index, sdo_subindex, data) when is_binary(data) do
    GenServer.call(slave, {:config_sdo, sdo_index, sdo_subindex, data})
  end

  # Internal/Advanced API

  @doc """
  Returns the slave configuration NIF reference.

  This is an advanced function used for direct NIF access. Most users
  should not need to call this directly.
  """
  def get_slave_config(slave) do
    GenServer.call(slave, {:get_slave_config})
  end

  @impl true
  def init({master, position, driver, slave_config, sync_count}) do
    # Register this slave in the Registry for process discovery
    Registry.register(EtherCAT.Registry, {:slave, master, position}, %{
      master: master,
      position: position,
      driver: driver
    })

    state = %__MODULE__{
      driver: driver,
      driver_state: %{},
      master: master,
      alias: 0,
      position: position,
      vendor_id: nil,
      product_code: nil,
      revision: 0,
      serial: 0,
      slave_config: slave_config,
      sync_count: sync_count,
      pdo_registrations: %{}
    }

    {:ok, state}
  end

  # Internal helpers that call Master
  # All NIF communication must go through Master to prevent race conditions

  defp get_sync_manager_internal(state, sync_index) do
    Master.slave_operation(state.master, state.position, :get_sync_manager, [sync_index])
  end

  defp get_pdo_internal(state, sync_index, pdo_pos) do
    Master.slave_operation(state.master, state.position, :get_pdo, [sync_index, pdo_pos])
  end

  defp get_pdo_entry_internal(state, sync_index, pdo_pos, entry_pos) do
    Master.slave_operation(state.master, state.position, :get_pdo_entry, [
      sync_index,
      pdo_pos,
      entry_pos
    ])
  end

  # Configuration helpers - route through Master to avoid direct NIF calls

  defp config_sync_manager_internal(state, sync_index, direction, watchdog) do
    Master.slave_operation(state.master, state.position, :config_sync_manager, [
      state.slave_config,
      sync_index,
      direction,
      watchdog
    ])
  end

  defp config_pdo_assign_clear_internal(state, sync_index) do
    Master.slave_operation(state.master, state.position, :config_pdo_assign_clear, [
      state.slave_config,
      sync_index
    ])
  end

  defp config_pdo_assign_add_internal(state, sync_index, pdo_index) do
    Master.slave_operation(state.master, state.position, :config_pdo_assign_add, [
      state.slave_config,
      sync_index,
      pdo_index
    ])
  end

  defp config_pdo_mapping_clear_internal(state, pdo_index) do
    Master.slave_operation(state.master, state.position, :config_pdo_mapping_clear, [
      state.slave_config,
      pdo_index
    ])
  end

  defp config_pdo_mapping_add_internal(state, pdo_index, entry_index, entry_subindex, entry_size) do
    Master.slave_operation(state.master, state.position, :config_pdo_mapping_add, [
      state.slave_config,
      pdo_index,
      entry_index,
      entry_subindex,
      entry_size
    ])
  end

  @impl true
  def handle_call(:locked?, _from, state) do
    {:reply, state.locked?, state}
  end

  @impl true
  def handle_call(:lock, _from, state) do
    Logger.info("Slave at position #{state.position} locked")
    {:reply, :ok, %{state | locked?: true}}
  end

  @impl true
  def handle_call({:get_slave_config}, _from, state) do
    {:reply, state.slave_config, state}
  end

  # Configuration - reject when locked
  @impl true
  def handle_call({:configure, _config}, _from, %{locked?: true} = state) do
    {:reply,
     {:error,
      {:slave_locked,
       "Cannot reconfigure slave after master activation. " <>
         "Reconfiguration requires restarting the master."}}, state}
  end

  @impl true
  def handle_call({:configure, config}, _from, state) do
    # Create context struct with slave information
    ctx = %{
      master: state.master,
      slave_pid: self(),
      position: state.position,
      slave_config: state.slave_config,
      vendor_id: state.vendor_id,
      product_code: state.product_code,
      revision: state.revision,
      serial: state.serial,
      sync_count: state.sync_count
    }

    # Call driver configuration
    {:ok, driver_state} = state.driver.configure(ctx, state.driver_state, config)

    # Clear all PDO assignments and mappings for all sync managers
    # This is done once after driver configuration to prepare for incremental registration
    clear_all_pdo_config(state)

    {:reply, :ok, %{state | driver_state: driver_state, configured?: true}}
  end

  # Read-only operations - allowed when locked
  def handle_call(:list_pdos, _from, state) do
    {:reply, state.driver.list_pdos(state.driver_state), state}
  end

  # New API handlers - introspection
  def handle_call({:get_sync_manager, sync_index}, _from, state) do
    result = get_sync_manager_internal(state, sync_index)
    {:reply, result, state}
  end

  def handle_call({:get_pdo, sync_index, pdo_pos}, _from, state) do
    result = get_pdo_internal(state, sync_index, pdo_pos)
    {:reply, result, state}
  end

  def handle_call({:get_pdo_entry, sync_index, pdo_pos, entry_pos}, _from, state) do
    result = get_pdo_entry_internal(state, sync_index, pdo_pos, entry_pos)
    {:reply, result, state}
  end

  # SDO configuration - reject when locked
  def handle_call(
        {:config_sdo, _sdo_index, _sdo_subindex, _data},
        _from,
        %{locked?: true} = state
      ) do
    {:reply,
     {:error,
      {:slave_locked,
       "Cannot configure SDOs after master activation. " <>
         "SDO configuration requires restarting the master."}}, state}
  end

  def handle_call({:config_sdo, sdo_index, sdo_subindex, data}, _from, state) do
    result =
      Master.slave_operation(
        state.master,
        state.position,
        :config_sdo,
        [state.slave_config, sdo_index, sdo_subindex, data]
      )

    {:reply, result, state}
  end

  # PDO registration - reject when locked
  def handle_call({:register_pdo, _name, _domain}, _from, %{locked?: true} = state) do
    {:reply,
     {:error,
      {:slave_locked,
       "Cannot register PDOs after master activation. " <>
         "Reconfiguration requires restarting the master."}}, state}
  end

  # PDO registration - reject when not configured
  def handle_call({:register_pdo, _name, _domain}, _from, %{configured?: false} = state) do
    {:reply,
     {:error,
      {:not_configured,
       "Cannot register PDOs before calling configure/2. " <>
         "Call Slave.configure/2 first to initialize PDO configuration."}}, state}
  end

  def handle_call({:register_pdo, name, domain}, _from, state) do
    unique_name = "slave_#{state.position}:#{name}"

    case state.pdo_registrations[unique_name] do
      ^domain ->
        # Already registered to this domain, return success idempotently
        {:reply, {:ok, unique_name}, state}

      nil ->
        # Not registered yet, proceed with registration
        case register_single_pdo(name, domain, state) do
          {:ok, ^unique_name} ->
            new_state = put_in(state.pdo_registrations[unique_name], domain)
            {:reply, {:ok, unique_name}, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      other_domain ->
        # Already registered to a different domain
        {:reply, {:error, {:pdo_already_registered, name, other_domain}}, state}
    end
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Slave at position #{state.position} terminating: #{inspect(reason)}")

    :telemetry.execute(
      [:ethercat, :slave, :terminate],
      %{position: state.position},
      %{reason: reason, driver: state.driver}
    )

    # Call driver's terminate callback
    if state.driver && state.driver_state do
      state.driver.terminate(state.driver_state)
    end

    :ok
  end

  # Private helpers

  # Clears all PDO assignments and mappings for all sync managers
  # Called once during configure to prepare for incremental registration
  # Following EtherLab's ecrt_slave_config_pdos pattern
  defp clear_all_pdo_config(state) do
    state.driver.list_pdos(state.driver_state)
    |> Enum.map(fn pdo_name ->
      {:ok, info} = state.driver.pdo_info(state.driver_state, pdo_name)
      info
    end)
    |> Enum.group_by(fn info ->
      {sync_idx, _dir, _wd} = info.sync_manager
      sync_idx
    end)
    |> Enum.each(fn {sync_index, infos} ->
      # Get sync manager config from first PDO in this sync
      {_sync_idx, direction, watchdog} = hd(infos).sync_manager

      # Configure sync manager, then clear assignments and mappings
      config_sync_manager_internal(state, sync_index, direction, watchdog)
      config_pdo_assign_clear_internal(state, sync_index)

      # Clear PDO mappings for all unique pdo_indices in this sync
      infos
      |> Enum.map(& &1.pdo_index)
      |> Enum.uniq()
      |> Enum.each(&config_pdo_mapping_clear_internal(state, &1))
    end)
  end

  # Registers a single PDO to a domain without clearing existing configuration
  # This function is called after configure/2 has cleared all PDO assignments and mappings
  # Follows EtherLab pattern: incrementally add assignments and mapping entries
  defp register_single_pdo(name, domain_name, state) do
    with {:ok, pdo_info} <- state.driver.pdo_info(state.driver_state, name),
         {:ok, domain_pid} <- Domain.find_domain(state.master, domain_name) do
      %{sync_manager: {sync_index, direction, _watchdog}, pdo_index: pdo_index, entry: entry} =
        pdo_info

      # Add PDO to assignment (EtherLab handles duplicates gracefully)
      config_pdo_assign_add_internal(state, sync_index, pdo_index)

      # Add this entry to the PDO mapping (never clear - already cleared in configure)
      {entry_index, entry_subindex, entry_size} = entry
      config_pdo_mapping_add_internal(state, pdo_index, entry_index, entry_subindex, entry_size)

      # Register with domain using unique name
      unique_name = "slave_#{state.position}:#{name}"
      pdo_direction = ethercat_direction_to_atom(direction)
      Domain.register_pdo_entry(domain_pid, state.slave_config, unique_name, entry, pdo_direction)

      {:ok, unique_name}
    end
  end

  # Converts EtherCAT direction integer to atom for domain registration
  # 1 = EC_DIR_OUTPUT (master writes, slave reads)
  # 2 = EC_DIR_INPUT (master reads, slave writes)
  defp ethercat_direction_to_atom(2), do: :input
  defp ethercat_direction_to_atom(_), do: :output
end
