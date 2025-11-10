defmodule EtherCAT.Slave do
  @moduledoc """
  GenServer managing individual EtherCAT slave device with driver-based PDO configuration.
  """
  use GenServer
  require Logger
  import EtherCAT.Utils

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
    locked?: false
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
          locked?: boolean()
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

  # Configuration API (must be called before Master activation)

  @doc """
  Configures a sync manager with direction and watchdog settings.
  """
  def configure_sync_manager(slave, sync_index, direction, watchdog) do
    GenServer.call(slave, {:configure_sync_manager, sync_index, direction, watchdog})
  end

  @doc """
  Configures PDO assignment for a sync manager.
  Clears existing assignments and adds the specified PDO indices.
  """
  def configure_pdo_assignment(slave, sync_index, pdo_indices) do
    GenServer.call(slave, {:configure_pdo_assignment, sync_index, pdo_indices})
  end

  @doc """
  Configures PDO mapping for a specific PDO index.
  Clears existing mappings and adds the specified entries.
  """
  def configure_pdo_mapping(slave, pdo_index, entries) do
    GenServer.call(slave, {:configure_pdo_mapping, pdo_index, entries})
  end

  @doc """
  Registers named PDOs to a domain for cyclic data exchange.

  This configures the slave's sync managers and PDO mappings based on the
  driver's configuration, then registers the PDO entries with the specified
  domain for real-time I/O.

  ## Parameters
  - `slave` - The slave process PID
  - `names` - List of PDO names (from `list_pdos/1`)
  - `domain` - Domain identifier (default: `:default_domain`)
  - `timeout` - Call timeout in milliseconds (default: 10_000 for configuration)

  ## Returns
  - `{:ok, unique_names}` - List of unique PDO names (e.g., `["slave_0:pdo_6000:1"]`)
  - `{:error, reason}` - Error if registration fails

  ## Example

      {:ok, unique_names} = Slave.register_pdos(slave, [:input1, :input2], :default_domain)
      #=> {:ok, ["slave_0:input1", "slave_0:input2"]}
  """
  @spec register_pdos(pid(), [name()], domain(), timeout()) ::
          {:ok, [String.t()]} | {:error, term()}
  def register_pdos(slave, names, domain \\ :default_domain, timeout \\ 10_000) do
    GenServer.call(slave, {:register_pdos, names, domain}, timeout)
  end

  @doc """
  Convenience function to register all available PDOs to a domain.

  Equivalent to calling `register_pdos(slave, list_pdos(slave), domain)`.

  ## Returns
  - `{:ok, unique_names}` - List of unique PDO names
  - `{:error, reason}` - Error if registration fails

  ## Example

      # Register all PDOs to the default domain
      {:ok, unique_names} = Slave.register_all_pdos(slave)

      # Register all PDOs to a custom domain
      {:ok, unique_names} = Slave.register_all_pdos(slave, :slow_domain)
  """
  @spec register_all_pdos(pid(), domain()) :: {:ok, [String.t()]} | {:error, term()}
  def register_all_pdos(slave, domain \\ :default_domain) do
    all_pdos = list_pdos(slave)
    register_pdos(slave, all_pdos, domain)
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

    {:ok, driver_state} = state.driver.configure(ctx, state.driver_state, config)
    {:reply, :ok, %{state | driver_state: driver_state}}
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

  # Sync manager configuration - reject when locked
  def handle_call(
        {:configure_sync_manager, _sync_index, _direction, _watchdog},
        _from,
        %{locked?: true} = state
      ) do
    {:reply,
     {:error,
      {:slave_locked,
       "Cannot configure sync managers after master activation. " <>
         "Reconfiguration requires restarting the master."}}, state}
  end

  def handle_call({:configure_sync_manager, sync_index, direction, watchdog}, _from, state) do
    config_sync_manager_internal(state, sync_index, direction, watchdog)
    {:reply, :ok, state}
  end

  # PDO assignment configuration - reject when locked
  def handle_call(
        {:configure_pdo_assignment, _sync_index, _pdo_indices},
        _from,
        %{locked?: true} = state
      ) do
    {:reply,
     {:error,
      {:slave_locked,
       "Cannot configure PDO assignments after master activation. " <>
         "Reconfiguration requires restarting the master."}}, state}
  end

  def handle_call({:configure_pdo_assignment, sync_index, pdo_indices}, _from, state) do
    config_pdo_assign_clear_internal(state, sync_index)

    for pdo_index <- pdo_indices do
      config_pdo_assign_add_internal(state, sync_index, pdo_index)
    end

    {:reply, :ok, state}
  end

  # PDO mapping configuration - reject when locked
  def handle_call({:configure_pdo_mapping, _pdo_index, _entries}, _from, %{locked?: true} = state) do
    {:reply,
     {:error,
      {:slave_locked,
       "Cannot configure PDO mappings after master activation. " <>
         "Reconfiguration requires restarting the master."}}, state}
  end

  def handle_call({:configure_pdo_mapping, pdo_index, entries}, _from, state) do
    config_pdo_mapping_clear_internal(state, pdo_index)

    for {entry_index, entry_subindex, entry_size} <- entries do
      config_pdo_mapping_add_internal(state, pdo_index, entry_index, entry_subindex, entry_size)
    end

    {:reply, :ok, state}
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
  def handle_call({:register_pdos, _names, _domain}, _from, %{locked?: true} = state) do
    {:reply,
     {:error,
      {:slave_locked,
       "Cannot register PDOs after master activation. " <>
         "Reconfiguration requires restarting the master."}}, state}
  end

  def handle_call({:register_pdos, names, domain}, _from, state) do
    # Check if any PDO is already registered to a different domain
    conflicts =
      Enum.filter(names, fn name ->
        unique_name = "slave_#{state.position}:#{name}"

        case state.pdo_registrations[unique_name] do
          nil -> false
          ^domain -> false
          other_domain -> {name, other_domain}
        end
      end)

    if conflicts != [] do
      # Return error with details about which PDOs are already registered
      conflict_details =
        Enum.map(conflicts, fn
          {name, other_domain} -> {name, other_domain}
          name -> {name, state.pdo_registrations["slave_#{state.position}:#{name}"]}
        end)

      {:reply, {:error, {:pdo_already_registered, conflict_details}}, state}
    else
      sync_managers = build_sync_manager_config(names, state)
      Logger.debug("Sync managers to configure: #{inspect(sync_managers)}")

      configured_entries = configure_and_register_pdos(sync_managers, state, domain)
      Logger.debug("Configured PDO entries: #{inspect(configured_entries)}")

      # Extract unique names from configured entries
      unique_names =
        Enum.map(configured_entries, fn {name, _entry, _direction} ->
          "slave_#{state.position}:#{name}"
        end)

      # Map unique names to domain for tracking registrations
      pdo_registrations =
        configured_entries
        |> Enum.map(fn {name, _entry, _direction} ->
          unique_name = "slave_#{state.position}:#{name}"
          {unique_name, domain}
        end)
        |> Map.new()
        |> Map.merge(state.pdo_registrations)

      {:reply, {:ok, unique_names}, %{state | pdo_registrations: pdo_registrations}}
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

  # Builds a map of sync manager configurations from PDO names
  defp build_sync_manager_config(names, state) do
    Enum.reduce(names, %{}, fn name, acc ->
      {:ok,
       %{sync_manager: {sync_index, direction, watchdog}, pdo_index: pdo_index, entry: entry}} =
        state.driver.pdo_info(state.driver_state, name)

      Map.update(
        acc,
        sync_index,
        {direction, watchdog, %{pdo_index => [{name, entry}]}},
        fn {^direction, ^watchdog, pdos} ->
          pdos = Map.update(pdos, pdo_index, [{name, entry}], &[{name, entry} | &1])
          {direction, watchdog, pdos}
        end
      )
    end)
  end

  # Configures sync managers and PDOs, then registers them with the domain
  defp configure_and_register_pdos(sync_managers, state, domain_name) do
    configured_entries =
      for {sync_index, {sm_direction, watchdog, pdos}} <- sync_managers do
        config_sync_manager_internal(state, sync_index, sm_direction, watchdog)
        config_pdo_assign_clear_internal(state, sync_index)

        # Convert EtherCAT sync manager direction to atom
        # 1 = EC_DIR_OUTPUT (master writes, slave reads - outputs from master's perspective)
        # 2 = EC_DIR_INPUT (master reads, slave writes - inputs from master's perspective)
        pdo_direction = if sm_direction == 2, do: :input, else: :output

        for {pdo_index, entries} <- pdos do
          config_pdo_assign_add_internal(state, sync_index, pdo_index)
          config_pdo_mapping_clear_internal(state, pdo_index)

          for {name, {entry_index, entry_subindex, entry_size}} <- entries do
            config_pdo_mapping_add_internal(
              state,
              pdo_index,
              entry_index,
              entry_subindex,
              entry_size
            )

            # Include direction as atom in the entry tuple
            {name, {entry_index, entry_subindex, entry_size}, pdo_direction}
          end
        end
      end
      |> List.flatten()

    # Look up domain PID from Registry
    {:ok, domain_pid} = Domain.find_domain(state.master, domain_name)

    # Register all entries with domain, using globally unique names
    for {name, entry, direction} <- configured_entries do
      # Prefix with slave position to ensure uniqueness across slaves
      unique_name = "slave_#{state.position}:#{name}"
      Domain.register_pdo_entry(domain_pid, state.slave_config, unique_name, entry, direction)
    end

    configured_entries
  end
end
