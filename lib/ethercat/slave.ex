defmodule EtherCAT.Slave do
  @moduledoc """
  Represents an individual EtherCAT slave device on the network.

  Each slave process manages a single physical device, providing:
  - Driver-based configuration and PDO management
  - Sync manager and PDO mapping configuration
  - Registration of PDO entries to domains
  - Value read/write operations for process data
  - Change notification subscriptions

  ## Architecture

  Slaves use a pluggable driver architecture where each driver implements the
  `EtherCAT.Slave.Driver` behavior. Drivers encapsulate device-specific knowledge:
  - Available PDO mappings
  - Sync manager configurations
  - Default settings and initialization

  ## Lifecycle

  1. **Creation** - Slave is created during `Master.sync_slaves/1`
  2. **Configuration** - Driver configures sync managers and PDO mappings
  3. **Registration** - PDO entries are registered to domains
  4. **Activation** - Master activates all slaves for cyclic communication
  5. **Operation** - Slave provides read/write access to process data

  ## PDO Management

  Process Data Objects (PDOs) are the primary mechanism for real-time data exchange:
  - Input PDOs: Data from slave to master (sensor readings, status)
  - Output PDOs: Data from master to slave (control signals, commands)

  Slaves manage PDO registration and track which domain each PDO belongs to,
  enabling targeted subscriptions and efficient data routing.

  ## Thread Safety

  All NIF operations are routed through the Master process, ensuring thread-safe
  access to the underlying C library without race conditions.

  ## Example

      # Configure a slave with specific PDOs
      Slave.configure(slave, [])

      # List available PDOs from the driver
      pdos = Slave.list_pdos(slave)
      #=> ["pdo_6000:1", "pdo_6010:1", "pdo_7000:1"]

      # Register PDOs to a domain for cyclic exchange
      Slave.register_pdos(slave, ["pdo_6000:1", "pdo_6010:1"], :default_domain)

      # Subscribe to value changes
      Slave.watch_pdo(slave, "pdo_6000:1")

      # Set output values
      Slave.set_pdo_value(slave, "pdo_7000:1", true)

      # Read input values
      {:ok, value} = Slave.get_pdo_value(slave, "pdo_6000:1")
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
    :slave_config,
    :pdo_registrations
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
          pdo_registrations: %{(unique_name :: String.t()) => domain()}
        }

  @type name :: String.t()
  @type domain :: atom()
  @type offset :: non_neg_integer()
  @type size :: non_neg_integer()

  # Client API

  @doc """
  Returns a child specification for starting this module under a supervisor.

  ## Parameters
  - Keyword list with keys:
    - `:master` - The master process PID
    - `:position` - The slave's position on the bus (0-based)
    - `:driver` - The driver module implementing `EtherCAT.Slave.Driver`
    - `:slave_config` - The slave configuration reference from the NIF
    - `:sync_count` - Number of sync managers available on the device
    - `:id` - Optional child spec identifier (default: `{__MODULE__, position}`)
    - `:restart` - Restart strategy (default: `:permanent`)
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) when is_list(opts) do
    position = Keyword.fetch!(opts, :position)
    id = Keyword.get(opts, :id, {__MODULE__, position})
    restart = Keyword.get(opts, :restart, :permanent)

    %{
      id: id,
      start: {__MODULE__, :start_link, [opts]},
      restart: restart,
      shutdown: 5000,
      type: :worker
    }
  end

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
  Creates a new slave process for managing an EtherCAT device.

  This is a legacy function maintained for backward compatibility.
  Prefer using `start_link/5` for proper supervision.

  ## Parameters
  - `master` - The master process PID
  - `position` - The slave's position on the bus (0-based)
  - `driver` - The driver module implementing `EtherCAT.Slave.Driver`
  - `slave_config` - The slave configuration reference from the NIF
  - `sync_count` - Number of sync managers available on the device

  ## Returns
  - `{:ok, pid}` - The slave process PID

  ## Example

      {:ok, slave} = Slave.create(master, 1, EtherCAT.Drivers.Generic, config, 4)
  """
  @spec create(pid(), non_neg_integer(), module(), reference(), non_neg_integer()) ::
          {:ok, pid()}
  def create(master, position, driver, slave_config, sync_count) do
    # Use start_link for proper supervision
    case start_link(
           master: master,
           position: position,
           driver: driver,
           slave_config: slave_config,
           sync_count: sync_count
         ) do
      {:ok, pid} ->
        Process.monitor(pid)
        {:ok, pid}

      error ->
        error
    end
  end

  @doc """
  Changes the driver for an existing slave.

  This recreates the slave configuration with the new driver. Should only be
  used before the master enters operational mode.

  ## Parameters
  - `slave` - The slave process PID
  - `driver` - The new driver module
  - `timeout` - Call timeout in milliseconds (default: 5000)
  """
  @spec set_driver(pid(), module(), timeout()) :: :ok
  def set_driver(slave, driver, timeout \\ 5000) do
    GenServer.call(slave, {:set_driver, driver}, timeout)
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

  ## Example

      Slave.register_pdos(slave, [:input1, :input2], :default_domain)
  """
  @spec register_pdos(pid(), [name()], domain(), timeout()) :: :ok
  def register_pdos(slave, names, domain \\ :default_domain, timeout \\ 10_000) do
    GenServer.call(slave, {:register_pdos, names, domain}, timeout)
  end

  @doc """
  Convenience function to register all available PDOs to a domain.

  Equivalent to calling `register_pdos(slave, list_pdos(slave), domain)`.

  ## Example

      # Register all PDOs to the default domain
      Slave.register_all_pdos(slave)

      # Register all PDOs to a custom domain
      Slave.register_all_pdos(slave, :slow_domain)
  """
  @spec register_all_pdos(pid(), domain()) :: :ok
  def register_all_pdos(slave, domain \\ :default_domain) do
    all_pdos = list_pdos(slave)
    register_pdos(slave, all_pdos, domain)
  end

  @doc """
  Registers PDO entries to a domain for cyclic data exchange.

  Low-level function for registering specific PDO entries. Most users should
  use `register_pdos/3` instead, which handles configuration automatically.
  """
  @spec register_pdo_entries(pid(), domain(), map()) :: :ok
  def register_pdo_entries(slave, domain, entries) do
    GenServer.call(slave, {:register_pdo_entries, domain, entries})
  end

  # Operational API (called after Master activation)

  @doc """
  Sets the value of a PDO output.

  Writes a value to an output PDO that will be sent to the slave during the
  next cyclic exchange. The PDO must have been registered before the master
  entered operational mode.

  ## Parameters
  - `slave` - The slave process PID
  - `name` - PDO name (as returned by `list_pdos/1`)
  - `value` - Value to write (type depends on PDO configuration)

  ## Returns
  - `:ok` on success
  - `{:error, reason}` if PDO not found or not registered

  ## Example

      # Set a boolean output
      Slave.set_pdo_value(slave, :output1, true)

      # Set an integer output
      Slave.set_pdo_value(slave, "pdo_7010:1", 42)
  """
  @spec set_pdo_value(pid(), name(), term()) :: :ok | {:error, term()}
  def set_pdo_value(slave, name, value) do
    GenServer.call(slave, {:set_pdo_value, name, value})
  end

  @doc """
  Gets the current value of a PDO input.

  Reads the most recent value received from the slave during cyclic exchange.
  The PDO must have been registered before the master entered operational mode.

  ## Parameters
  - `slave` - The slave process PID
  - `name` - PDO name (as returned by `list_pdos/1`)

  ## Returns
  - `{:ok, value}` on success
  - `{:error, reason}` if PDO not found or not registered

  ## Example

      {:ok, temperature} = Slave.get_pdo_value(slave, :temperature)
      {:ok, input_state} = Slave.get_pdo_value(slave, "pdo_6000:1")
  """
  @spec get_pdo_value(pid(), name()) :: {:ok, term()} | {:error, term()}
  def get_pdo_value(slave, name) do
    GenServer.call(slave, {:get_pdo_value, name})
  end

  @doc """
  Subscribes a process to receive notifications when a PDO value changes.

  The subscriber will receive `{:data_changed, name, value}` messages whenever
  the PDO value changes during cyclic operation.

  ## Parameters
  - `slave` - The slave process PID
  - `name` - PDO name to watch
  - `pid` - Process to receive notifications (default: calling process)

  ## Returns
  - `:ok` on success
  - `{:error, reason}` if PDO not found or not registered

  ## Example

      # Watch from the calling process
      Slave.watch_pdo(slave, :temperature)

      receive do
        {:data_changed, :temperature, value} ->
          IO.puts("Temperature changed to: ")
      end

      # Watch from another process
      Slave.watch_pdo(slave, :pressure, monitor_pid)
  """
  @spec watch_pdo(pid(), name(), pid()) :: :ok | {:error, term()}
  def watch_pdo(slave, name, pid \\ self()) do
    GenServer.call(slave, {:watch_pdo, name, pid})
  end

  # Internal/Legacy API

  def get_slave_config(slave) do
    GenServer.call(slave, {:get_slave_config})
  end

  def subscribe_all(slave, domain \\ :default_domain) do
    GenServer.call(slave, {:subscribe_all, domain})
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
      slave_config: slave_config,
      pdo_registrations: %{}
    }

    if driver == EtherCAT.Drivers.Generic do
      {:ok, state, {:continue, {:load_driver, sync_count}}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_continue({:load_driver, sync_count}, state) do
    pdos =
      for sync_index <- create_range(sync_count) do
        sync_manager = get_sync_manager_internal(state, sync_index)

        for pos <- create_range(sync_manager.n_pdos) do
          pdo = get_pdo_internal(state, sync_index, pos)

          for entry_pos <- create_range(pdo.n_entries) do
            entry = get_pdo_entry_internal(state, sync_index, pos, entry_pos)

            %{
              sync_manager: {sync_manager.index, sync_manager.dir, sync_manager.watchdog_mode},
              pdo_index: pdo.index,
              entry: {entry.index, entry.subindex, entry.bit_length}
            }
          end
        end
      end
      |> List.flatten()
      |> Enum.map(fn pdo ->
        entry_index = elem(pdo.entry, 0)
        entry_subindex = elem(pdo.entry, 1)

        {"pdo_#{Integer.to_string(entry_index, 16)}:#{Integer.to_string(entry_subindex, 16)}",
         pdo}
      end)
      |> Map.new()

    require Logger
    Logger.debug("Generic driver discovered PDOs: #{inspect(pdos)}")

    {:noreply, %{state | driver_state: %{pdos: pdos}}}
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
  def handle_call({:set_driver, driver}, _from, state) do
    sc =
      Master.slave_operation(
        state.master,
        state.position,
        :slave_config,
        [state.alias, state.vendor_id, state.product_code]
      )

    {:reply, :ok, %{state | driver: driver, slave_config: sc}}
  end

  def handle_call({:get_slave_config}, _from, state) do
    {:reply, state.slave_config, state}
  end

  def handle_call({:configure, config}, _from, state) do
    {:ok, driver_state} = state.driver.configure(state.driver_state, config)
    {:reply, :ok, %{state | driver_state: driver_state}}
  end

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

  # New API handlers - configuration
  def handle_call({:configure_sync_manager, sync_index, direction, watchdog}, _from, state) do
    config_sync_manager_internal(state, sync_index, direction, watchdog)
    {:reply, :ok, state}
  end

  def handle_call({:configure_pdo_assignment, sync_index, pdo_indices}, _from, state) do
    config_pdo_assign_clear_internal(state, sync_index)

    for pdo_index <- pdo_indices do
      config_pdo_assign_add_internal(state, sync_index, pdo_index)
    end

    {:reply, :ok, state}
  end

  def handle_call({:configure_pdo_mapping, pdo_index, entries}, _from, state) do
    config_pdo_mapping_clear_internal(state, pdo_index)

    for {entry_index, entry_subindex, entry_size} <- entries do
      config_pdo_mapping_add_internal(state, pdo_index, entry_index, entry_subindex, entry_size)
    end

    {:reply, :ok, state}
  end

  def handle_call({:register_pdos, names, domain}, _from, state) do
    sync_managers = build_sync_manager_config(names, state)
    Logger.debug("Sync managers to configure: #{inspect(sync_managers)}")

    configured_entries = configure_and_register_pdos(sync_managers, state, domain)
    Logger.debug("Configured PDO entries: #{inspect(configured_entries)}")

    # Map unique names to domain for tracking registrations
    pdo_registrations =
      configured_entries
      |> Enum.map(fn {name, _entry, _direction} ->
        unique_name = "slave_#{state.position}:#{name}"
        {unique_name, domain}
      end)
      |> Map.new()
      |> Map.merge(state.pdo_registrations)

    {:reply, :ok, %{state | pdo_registrations: pdo_registrations}}
  end

  # Operational API handlers
  def handle_call({:set_pdo_value, name, value}, _from, state) do
    unique_name = "slave_#{state.position}:#{name}"

    case state.pdo_registrations[unique_name] do
      domain_name when is_atom(domain_name) ->
        # Get domain reference
        domain_ref = Domain.get_ref(domain_name)
        # Call Master as the single NIF gateway
        result = Master.domain_set_value(state.master, domain_ref, unique_name, value)
        {:reply, result, state}

      nil ->
        {:reply, {:error, {:pdo_not_registered, name}}, state}
    end
  end

  def handle_call({:get_pdo_value, name}, _from, state) do
    unique_name = "slave_#{state.position}:#{name}"

    case state.pdo_registrations[unique_name] do
      domain_name when is_atom(domain_name) ->
        # Get domain reference
        domain_ref = Domain.get_ref(domain_name)
        # Call Master as the single NIF gateway
        result = Master.domain_get_value(state.master, domain_ref, unique_name)
        {:reply, result, state}

      nil ->
        {:reply, {:error, {:pdo_not_registered, name}}, state}
    end
  end

  def handle_call({:watch_pdo, name, pid}, _from, state) do
    unique_name = "slave_#{state.position}:#{name}"

    case state.pdo_registrations[unique_name] do
      domain_name when is_atom(domain_name) ->
        # Call Master to subscribe (Master routes to Domain)
        result = Master.domain_subscribe(state.master, domain_name, pid, unique_name)
        {:reply, result, state}

      nil ->
        {:reply, {:error, {:pdo_not_registered, name}}, state}
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
  defp configure_and_register_pdos(sync_managers, state, domain) do
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

    # Register all entries with domain, using globally unique names
    for {name, entry, direction} <- configured_entries do
      # Prefix with slave position to ensure uniqueness across slaves
      unique_name = "slave_#{state.position}:#{name}"
      Domain.register_pdo_entry(domain, state.slave_config, unique_name, entry, direction)
    end

    configured_entries
  end
end
