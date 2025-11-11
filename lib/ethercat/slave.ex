defmodule EtherCAT.Slave do
  @moduledoc """
  Gen_statem managing individual EtherCAT slave device with driver-based PDO configuration.

  ## State Machine

  ```
  :unconfigured (created, driver loaded)
      │ configure/2
      ▼
  :configured (driver configured, ready for registration)
      │ lock/1 (called by Master on activation)
      ▼
  :operational (locked, no changes allowed)
  ```

  ## Entry-Level vs PDO-Level Registration

  This module supports both granular entry-level and convenient PDO-level registration:

  ### Entry-Level (Granular)
  Register only the specific entries you need from a PDO:

      # Register just the temperature value from channel 1
      {:ok, handle} = Slave.register_entry(slave, :ch1, :value)

      # Register multiple specific entries
      {:ok, [val_handle, err_handle]} =
        Slave.register_entries(slave, [
          {:ch1, :value},
          {:ch1, :error}
        ])

  ### PDO-Level (Convenience)
  Register all entries in a PDO at once:

      # Register all 6 entries from channel 1
      {:ok, handles} = Slave.register_pdo(slave, :ch1)

  ## Multi-Domain Registration

  Entries from the same sync manager CAN be registered to different domains.
  Each domain creates its own FMMU (Fieldbus Memory Management Unit) mapping of the
  sync manager's memory.

  This enables multi-rate control systems where different entries update at different rates:

      # Fast control loop (1ms): Register critical entries
      {:ok, position} = Slave.register_entry(slave, :status, :position, :fast_domain)

      # Slow monitoring (10ms): Register diagnostic entries
      {:ok, temp} = Slave.register_entry(slave, :status, :temperature, :slow_domain)

  The only hardware limit is the number of available FMMUs per slave (typically 8-16).

  Reference: IgH EtherCAT Master documentation - "each domain occupies one FMMU in each slave involved"
  """

  @behaviour :gen_statem
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
    :name,
    # Tracks registered entries per PDO: %{pdo_name => %{domain: atom(), entries: MapSet}}
    pdo_registrations: %{},
    # Tracks which sync managers have been configured (one-time setup)
    configured_sync_managers: MapSet.new()
  ]

  @type t :: %__MODULE__{
          driver: atom() | nil,
          driver_state: map(),
          master: pid(),
          alias: non_neg_integer(),
          position: non_neg_integer(),
          vendor_id: non_neg_integer() | nil,
          product_code: non_neg_integer() | nil,
          revision: non_neg_integer(),
          serial: non_neg_integer(),
          slave_config: reference() | nil,
          sync_count: non_neg_integer(),
          name: atom() | String.t() | nil,
          pdo_registrations: %{pdo_name() => %{domain: domain(), entries: MapSet.t(atom())}},
          configured_sync_managers: MapSet.t(non_neg_integer())
        }

  @type pdo_name :: atom() | String.t()
  @type entry_name :: atom() | String.t()
  @type domain :: atom()
  @type offset :: non_neg_integer()
  @type size :: non_neg_integer()

  # Client API

  @doc """
  Starts a slave process linked to the calling process.

  This function is typically called by the Master during slave synchronization.
  It initializes the slave with a driver in the `:unconfigured` state.

  ## Parameters
  - `opts` - Keyword list with:
    - `:master` - The master process PID
    - `:position` - The slave's position on the bus (0-based)
    - `:driver` - The driver module implementing `EtherCAT.Slave.Driver`
    - `:slave_config` - The slave configuration reference from the NIF
    - `:sync_count` - Number of sync managers available on the device
    - `:name` - Optional semantic name for the slave (atom or string)

  ## Returns
  - `{:ok, pid}` - The slave process PID

  ## Example

      # With semantic name
      {:ok, slave} = Slave.start_link(
        master: master_pid,
        position: 1,
        driver: EtherCAT.Drivers.EL3202,
        slave_config: config_ref,
        sync_count: 4,
        name: :temp_sensor_1
      )

      # Without name (uses "s1" as identifier)
      {:ok, slave} = Slave.start_link(
        master: master_pid,
        position: 1,
        driver: EtherCAT.Drivers.Generic,
        slave_config: config_ref,
        sync_count: 4
      )
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) when is_list(opts) do
    master = Keyword.fetch!(opts, :master)
    position = Keyword.fetch!(opts, :position)
    driver = Keyword.fetch!(opts, :driver)
    slave_config = Keyword.fetch!(opts, :slave_config)
    sync_count = Keyword.fetch!(opts, :sync_count)
    name = Keyword.get(opts, :name)

    :gen_statem.start_link(
      __MODULE__,
      {master, position, driver, slave_config, sync_count, name},
      []
    )
  end

  @doc """
  Applies driver-specific configuration to the slave.

  Transitions from `:unconfigured` to `:configured` state.

  The configuration map is passed to the driver's `configure/2` callback,
  allowing device-specific initialization and setup.

  ## Parameters
  - `slave` - The slave process PID
  - `config` - Configuration map (driver-specific)
  - `timeout` - Call timeout in milliseconds (default: 5000)

  ## Example

      Slave.configure(slave, %{sample_rate: 1000, mode: :continuous})
  """
  @spec configure(pid(), map(), timeout()) :: :ok | {:error, term()}
  def configure(slave, config, timeout \\ 5000) do
    :gen_statem.call(slave, {:configure, config}, timeout)
  end

  @doc """
  Sets a semantic name for the slave.

  The name is used to generate more readable unique identifiers for PDO entries.
  For example, a slave named `:temp_sensor_1` will generate entry names like
  `"temp_sensor_1:ch1:value"` instead of `"s0:ch1:value"`.

  ## Parameters
  - `slave` - The slave process PID
  - `name` - Atom or string to identify this slave

  ## Returns
  - `:ok` on success
  - `{:error, reason}` if setting name fails

  ## Example

      Slave.set_name(slave, :temp_sensor_1)
      # Future registrations will use "temp_sensor_1:..." prefix
  """
  @spec set_name(pid(), atom() | String.t()) :: :ok | {:error, term()}
  def set_name(slave, name) when is_atom(name) or is_binary(name) do
    :gen_statem.call(slave, {:set_name, name})
  end

  @doc """
  Gets the semantic name of the slave, if set.

  ## Parameters
  - `slave` - The slave process PID

  ## Returns
  - `{:ok, name}` if name is set
  - `{:ok, nil}` if no name is set (using default "s<position>" format)

  ## Example

      Slave.set_name(slave, :temp_sensor_1)
      {:ok, :temp_sensor_1} = Slave.get_name(slave)
  """
  @spec get_name(pid()) :: {:ok, atom() | String.t() | nil}
  def get_name(slave) do
    :gen_statem.call(slave, :get_name)
  end

  @doc """
  Lists all available PDO names from the slave's driver.

  The returned list depends on the driver implementation:
  - Generic driver: Auto-discovered names like "0x1a00", "0x1a01"
  - Device-specific drivers: Semantic names like `:ch1`, `:ch2`

  ## Parameters
  - `slave` - The slave process PID
  - `timeout` - Call timeout in milliseconds (default: 5000)

  ## Returns
  List of PDO identifiers (atoms or strings)

  ## Example

      pdos = Slave.list_pdos(slave)
      #=> [:ch1, :ch2]
  """
  @spec list_pdos(pid(), timeout()) :: [pdo_name()]
  def list_pdos(slave, timeout \\ 5000) do
    :gen_statem.call(slave, :list_pdos, timeout)
  end

  @doc """
  Registers a single PDO entry for cyclic data exchange.

  This is the granular registration API - register only the specific entries you need.

  ## Parameters
  - `slave` - The slave process PID
  - `pdo_name` - PDO name from `list_pdos/1` (e.g., `:ch1`)
  - `entry_name` - Entry name within the PDO (e.g., `:value`, `:error`)
  - `domain` - Domain identifier (default: `:default_domain`)
  - `timeout` - Call timeout in milliseconds (default: 10_000)

  ## Returns
  - `{:ok, unique_name}` - Unique entry identifier like "slave_0:ch1:value"
  - `{:error, reason}` - Error if registration fails

  ## Multi-Domain Support
  Entries from the same sync manager can be registered to different domains.
  Each domain uses a separate FMMU to access the same sync manager memory.

  ## Example

      # Register only the temperature value, skip error flags
      {:ok, temp_name} = Slave.register_entry(slave, :ch1, :value, :fast_domain)

      # Use with EtherCAT.read/write/watch
      handle = PDO.new(:fast_domain, temp_name, master)
      {:ok, temp} = EtherCAT.read(handle)
  """
  @spec register_entry(pid(), pdo_name(), entry_name(), domain(), timeout()) ::
          {:ok, String.t()} | {:error, term()}
  def register_entry(slave, pdo_name, entry_name, domain \\ :default_domain, timeout \\ 10_000) do
    :gen_statem.call(slave, {:register_entry, pdo_name, entry_name, domain}, timeout)
  end

  @doc """
  Registers multiple PDO entries in a single call.

  Convenience function for registering several entries at once.

  ## Parameters
  - `slave` - The slave process PID
  - `entries` - List of `{pdo_name, entry_name}` or `{pdo_name, entry_name, domain}` tuples
  - `default_domain` - Domain to use when not specified per entry (default: `:default_domain`)
  - `timeout` - Call timeout in milliseconds (default: 10_000)

  ## Returns
  - `{:ok, [unique_name]}` - List of unique entry identifiers
  - `{:error, reason}` - Error if any registration fails

  ## Example

      # All to default domain
      {:ok, names} = Slave.register_entries(slave, [
        {:ch1, :value},
        {:ch1, :error},
        {:ch2, :value}
      ])

      # Different domains per entry
      {:ok, names} = Slave.register_entries(slave, [
        {:ch1, :value, :fast_domain},
        {:ch2, :value, :slow_domain}
      ])
  """
  @spec register_entries(pid(), list(), domain(), timeout()) ::
          {:ok, [String.t()]} | {:error, term()}
  def register_entries(slave, entries, default_domain \\ :default_domain, timeout \\ 10_000)
      when is_list(entries) do
    results =
      Enum.map(entries, fn
        {pdo_name, entry_name} ->
          register_entry(slave, pdo_name, entry_name, default_domain, timeout)

        {pdo_name, entry_name, domain} ->
          register_entry(slave, pdo_name, entry_name, domain, timeout)
      end)

    # Check if any failed
    case Enum.find(results, fn result -> match?({:error, _}, result) end) do
      {:error, _} = error -> error
      nil -> {:ok, Enum.map(results, fn {:ok, name} -> name end)}
    end
  end

  @doc """
  Registers a PDO (with all its entries) to a domain for cyclic data exchange.

  This is the convenient registration API - register all entries in a PDO at once.

  This function incrementally configures the slave's sync managers and PDO mappings
  based on the driver's configuration, then registers all PDO entries with the specified
  domain for real-time I/O.

  **IMPORTANT:**
  - You must call `Slave.configure/2` before calling this function.
  - This registers all entries defined in the PDO by the driver.
  - Entries/PDOs can be registered to different domains regardless of sync manager.
  - Each domain creates its own FMMU mapping.

  ## Parameters
  - `slave` - The slave process PID
  - `pdo_name` - PDO name (from `list_pdos/1`)
  - `domain` - Domain identifier (default: `:default_domain`)
  - `timeout` - Call timeout in milliseconds (default: 10_000 for configuration)

  ## Returns
  - `{:ok, [unique_name]}` - List of unique names for each entry
  - `{:error, reason}` - Error if registration fails

  ## Example

      # Configure the slave first
      :ok = Slave.configure(slave, %{})

      # Register all entries in channel 1 PDO
      {:ok, ch1_entries} = Slave.register_pdo(slave, :ch1, :fast_domain)
      # ch1_entries = ["slave_0:ch1:underrange", "slave_0:ch1:value", ...]
  """
  @spec register_pdo(pid(), pdo_name(), domain(), timeout()) ::
          {:ok, [String.t()]} | {:error, term()}
  def register_pdo(slave, pdo_name, domain \\ :default_domain, timeout \\ 10_000) do
    :gen_statem.call(slave, {:register_pdo, pdo_name, domain}, timeout)
  end

  @doc """
  Convenience function to register all available PDOs to a domain.

  Calls `register_pdo/3` for each PDO returned by `list_pdos/1`.

  ## Returns
  - `{:ok, unique_names}` - Flat list of all entry unique names from all PDOs
  - `{:error, reason}` - Error if any registration fails

  ## Example

      {:ok, unique_names} = Slave.register_all_pdos(slave, :fast_domain)
  """
  @spec register_all_pdos(pid(), domain(), timeout()) :: {:ok, [String.t()]} | {:error, term()}
  def register_all_pdos(slave, domain \\ :default_domain, timeout \\ 10_000) do
    all_pdos = list_pdos(slave, timeout)

    results = Enum.map(all_pdos, fn pdo -> register_pdo(slave, pdo, domain, timeout) end)

    case Enum.find(results, fn result -> match?({:error, _}, result) end) do
      {:error, reason} -> {:error, reason}
      nil -> {:ok, Enum.flat_map(results, fn {:ok, names} -> names end)}
    end
  end

  @doc """
  Returns the current state of the slave.

  ## Returns
  - `:unconfigured` - Driver loaded, waiting for configure/2
  - `:configured` - Ready for PDO/entry registration
  - `:operational` - Locked, master is active
  """
  @spec get_state(pid()) :: :unconfigured | :configured | :operational
  def get_state(slave) do
    :gen_statem.call(slave, :get_state)
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
      def configure(ctx, state, config) do
        limit = Map.get(config, :limit1, 1000)
        data = <<limit::little-signed-16>>
        :ok = Slave.config_sdo(ctx.slave_pid, 0x8000, 0x13, data)
        {:ok, %{configured: true}}
      end
  """
  @spec config_sdo(pid(), 0x0000..0xFFFF, 0x00..0xFF, binary()) :: :ok | {:error, term()}
  def config_sdo(slave, sdo_index, sdo_subindex, data) when is_binary(data) do
    :gen_statem.call(slave, {:config_sdo, sdo_index, sdo_subindex, data})
  end

  # Introspection API

  @doc """
  Gets sync manager information for the specified sync index.
  All NIF communication goes through Master to prevent race conditions.
  """
  @spec get_sync_manager(pid(), non_neg_integer()) :: {:ok, map()} | {:error, term()}
  def get_sync_manager(slave, sync_index) do
    :gen_statem.call(slave, {:get_sync_manager, sync_index})
  end

  @doc """
  Gets PDO information at the specified sync manager and position.
  All NIF communication goes through Master to prevent race conditions.
  """
  @spec get_pdo(pid(), non_neg_integer(), non_neg_integer()) :: {:ok, map()} | {:error, term()}
  def get_pdo(slave, sync_index, pdo_pos) do
    :gen_statem.call(slave, {:get_pdo, sync_index, pdo_pos})
  end

  @doc """
  Gets PDO entry information at the specified position.
  All NIF communication goes through Master to prevent race conditions.
  """
  @spec get_pdo_entry(pid(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  def get_pdo_entry(slave, sync_index, pdo_pos, entry_pos) do
    :gen_statem.call(slave, {:get_pdo_entry, sync_index, pdo_pos, entry_pos})
  end

  @doc false
  @spec lock(pid()) :: :ok
  def lock(slave) do
    :gen_statem.call(slave, :lock)
  end

  @doc """
  Returns the slave configuration NIF reference.

  This is an advanced function used for direct NIF access. Most users
  should not need to call this directly.
  """
  @spec get_slave_config(pid()) :: reference()
  def get_slave_config(slave) do
    :gen_statem.call(slave, :get_slave_config)
  end

  # Callbacks

  @impl true
  def callback_mode(), do: [:state_functions, :state_enter]

  @impl true
  def init({master, position, driver, slave_config, sync_count, name}) do
    # Register this slave in the Registry for process discovery
    Registry.register(EtherCAT.Registry, {:slave, master, position}, %{
      master: master,
      position: position,
      driver: driver,
      name: name
    })

    data = %__MODULE__{
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
      name: name
    }

    Logger.debug("Slave #{position} initialized with name: #{inspect(name)}")
    {:ok, :unconfigured, data}
  end

  @impl true
  def terminate(reason, _state, data) do
    Logger.info("Slave at position #{data.position} terminating: #{inspect(reason)}")

    :telemetry.execute(
      [:ethercat, :slave, :terminate],
      %{position: data.position},
      %{reason: reason, driver: data.driver}
    )

    # Call driver's terminate callback
    if data.driver && data.driver_state do
      data.driver.terminate(data.driver_state)
    end

    :ok
  end

  # State: unconfigured
  # Slave is created but driver has not been configured yet

  def unconfigured(:enter, _old_state, data) do
    Logger.debug("Slave #{data.position} entered :unconfigured state")
    :telemetry.execute([:ethercat, :slave, :state], %{}, %{position: data.position, state: :unconfigured})
    :keep_state_and_data
  end

  def unconfigured({:call, from}, {:configure, config}, data) do
    # Create context struct with slave information
    context = %{
      master: data.master,
      slave_pid: self(),
      position: data.position,
      slave_config: data.slave_config,
      vendor_id: data.vendor_id,
      product_code: data.product_code,
      revision: data.revision,
      serial: data.serial,
      sync_count: data.sync_count
    }

    # Call driver configuration
    case data.driver.configure(context, data.driver_state, config) do
      {:ok, driver_state} ->
        updated_data = %{data | driver_state: driver_state}

        # Clear all PDO assignments and mappings for all sync managers
        # This prepares for incremental entry/PDO registration
        clear_all_pdo_config(updated_data)

        Logger.info("Slave #{data.position} configured, transitioning to :configured")
        {:next_state, :configured, updated_data, [{:reply, from, :ok}]}

      {:error, reason} ->
        Logger.error("Slave #{data.position} configuration failed: #{inspect(reason)}")
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  def unconfigured({:call, from}, :list_pdos, data) do
    # Allow querying PDOs even before configuration
    pdos = data.driver.list_pdos(data.driver_state)
    {:keep_state_and_data, [{:reply, from, pdos}]}
  end

  def unconfigured({:call, from}, {:set_name, name}, data) do
    updated_data = %{data | name: name}
    Logger.debug("Slave #{data.position} name set to: #{inspect(name)}")
    {:keep_state, updated_data, [{:reply, from, :ok}]}
  end

  def unconfigured({:call, from}, :get_name, data) do
    {:keep_state_and_data, [{:reply, from, {:ok, data.name}}]}
  end

  def unconfigured({:call, from}, :get_state, _data) do
    {:keep_state_and_data, [{:reply, from, :unconfigured}]}
  end

  def unconfigured({:call, from}, _request, data) do
    {:keep_state_and_data,
     [{:reply, from, {:error, {:invalid_state, :unconfigured, "Call configure/2 first"}}}]}
  end

  # State: configured
  # Driver is configured, ready for entry/PDO registration

  def configured(:enter, _old_state, data) do
    Logger.debug("Slave #{data.position} entered :configured state")
    :telemetry.execute([:ethercat, :slave, :state], %{}, %{position: data.position, state: :configured})
    :keep_state_and_data
  end

  def configured({:call, from}, {:register_entry, pdo_name, entry_name, domain_name}, data) do
    case do_register_entry(pdo_name, entry_name, domain_name, data) do
      {:ok, unique_name, updated_data} ->
        {:keep_state, updated_data, [{:reply, from, {:ok, unique_name}}]}

      {:error, _reason} = error ->
        {:keep_state_and_data, [{:reply, from, error}]}
    end
  end

  def configured({:call, from}, {:register_pdo, pdo_name, domain_name}, data) do
    case do_register_pdo(pdo_name, domain_name, data) do
      {:ok, unique_names, updated_data} ->
        {:keep_state, updated_data, [{:reply, from, {:ok, unique_names}}]}

      {:error, _reason} = error ->
        {:keep_state_and_data, [{:reply, from, error}]}
    end
  end

  def configured({:call, from}, {:config_sdo, sdo_index, sdo_subindex, sdo_data}, data) do
    result =
      Master.slave_operation(
        data.master,
        data.position,
        :config_sdo,
        [data.slave_config, sdo_index, sdo_subindex, sdo_data]
      )

    {:keep_state_and_data, [{:reply, from, result}]}
  end

  def configured({:call, from}, :list_pdos, data) do
    pdos = data.driver.list_pdos(data.driver_state)
    {:keep_state_and_data, [{:reply, from, pdos}]}
  end

  def configured({:call, from}, {:get_sync_manager, sync_index}, data) do
    result = get_sync_manager_internal(data, sync_index)
    {:keep_state_and_data, [{:reply, from, result}]}
  end

  def configured({:call, from}, {:get_pdo, sync_index, pdo_pos}, data) do
    result = get_pdo_internal(data, sync_index, pdo_pos)
    {:keep_state_and_data, [{:reply, from, result}]}
  end

  def configured({:call, from}, {:get_pdo_entry, sync_index, pdo_pos, entry_pos}, data) do
    result = get_pdo_entry_internal(data, sync_index, pdo_pos, entry_pos)
    {:keep_state_and_data, [{:reply, from, result}]}
  end

  def configured({:call, from}, :get_slave_config, data) do
    {:keep_state_and_data, [{:reply, from, data.slave_config}]}
  end

  def configured({:call, from}, {:set_name, name}, data) do
    updated_data = %{data | name: name}
    Logger.debug("Slave #{data.position} name set to: #{inspect(name)}")
    {:keep_state, updated_data, [{:reply, from, :ok}]}
  end

  def configured({:call, from}, :get_name, data) do
    {:keep_state_and_data, [{:reply, from, {:ok, data.name}}]}
  end

  def configured({:call, from}, :get_state, _data) do
    {:keep_state_and_data, [{:reply, from, :configured}]}
  end

  def configured({:call, from}, :lock, data) do
    Logger.info("Slave #{data.position} locked, transitioning to :operational")
    {:next_state, :operational, data, [{:reply, from, :ok}]}
  end

  # State: operational
  # Master is activated, slave is locked, no changes allowed

  def operational(:enter, _old_state, data) do
    Logger.debug("Slave #{data.position} entered :operational state")
    :telemetry.execute([:ethercat, :slave, :state], %{}, %{position: data.position, state: :operational})
    :keep_state_and_data
  end

  def operational({:call, from}, :list_pdos, data) do
    # Allow querying PDOs in operational state
    pdos = data.driver.list_pdos(data.driver_state)
    {:keep_state_and_data, [{:reply, from, pdos}]}
  end

  def operational({:call, from}, :get_name, data) do
    {:keep_state_and_data, [{:reply, from, {:ok, data.name}}]}
  end

  def operational({:call, from}, :get_state, _data) do
    {:keep_state_and_data, [{:reply, from, :operational}]}
  end

  def operational({:call, from}, :get_slave_config, data) do
    {:keep_state_and_data, [{:reply, from, data.slave_config}]}
  end

  def operational({:call, from}, _request, data) do
    {:keep_state_and_data,
     [
       {:reply, from,
        {:error,
         {:slave_operational,
          "Cannot modify slave #{data.position} after master activation. Restart master to reconfigure."}}}
     ]}
  end

  # Private helpers

  # Registers a single entry from a PDO
  defp do_register_entry(pdo_name, entry_name, domain_name, data) do
    with {:ok, pdo_info} <- data.driver.pdo_info(data.driver_state, pdo_name),
         :ok <- validate_entry_exists(pdo_info, entry_name),
         {:ok, domain_pid} <- Domain.find_domain(data.master, domain_name) do
      {sync_index, direction, watchdog} = pdo_info.sync_manager
      pdo_index = pdo_info.pdo_index

      # Get the specific entry configuration
      {entry_index, entry_subindex, entry_bit_length} = pdo_info.entries[entry_name]

      # Configure sync manager if first time
      updated_data =
        if MapSet.member?(data.configured_sync_managers, sync_index) do
          data
        else
          config_sync_manager_internal(data, sync_index, direction, watchdog)
          %{data | configured_sync_managers: MapSet.put(data.configured_sync_managers, sync_index)}
        end

      # Check if this is the first entry from this PDO
      pdo_registration = Map.get(updated_data.pdo_registrations, pdo_name)
      first_entry_from_pdo? = is_nil(pdo_registration)

      # Add PDO to sync manager assignment if first entry
      if first_entry_from_pdo? do
        config_pdo_assign_add_internal(updated_data, sync_index, pdo_index)
      end

      # Add entry to PDO mapping
      config_pdo_mapping_add_internal(
        updated_data,
        pdo_index,
        entry_index,
        entry_subindex,
        entry_bit_length
      )

      # Register entry with domain
      # Use semantic name if set, otherwise use "s<position>" format
      slave_identifier =
        case updated_data.name do
          nil -> "s#{updated_data.position}"
          name when is_atom(name) -> Atom.to_string(name)
          name when is_binary(name) -> name
        end

      unique_name = "#{slave_identifier}:#{pdo_name}:#{entry_name}"
      pdo_direction = ethercat_direction_to_atom(direction)

      Domain.register_pdo_entry(
        domain_pid,
        updated_data.slave_config,
        unique_name,
        {entry_index, entry_subindex, entry_bit_length},
        pdo_direction
      )

      # Update tracking structures
      updated_registrations =
        Map.update(
          updated_data.pdo_registrations,
          pdo_name,
          %{domain: domain_name, entries: MapSet.new([entry_name])},
          fn reg -> %{reg | entries: MapSet.put(reg.entries, entry_name)} end
        )

      final_data = %{
        updated_data
        | pdo_registrations: updated_registrations
      }

      Logger.debug(
        "Registered entry #{unique_name} to domain #{domain_name} (SM#{sync_index})"
      )

      {:ok, unique_name, final_data}
    end
  end

  # Registers all entries in a PDO (convenience wrapper)
  defp do_register_pdo(pdo_name, domain_name, data) do
    case data.driver.pdo_info(data.driver_state, pdo_name) do
      {:ok, pdo_info} ->
        # Get all entry names
        entry_names = Map.keys(pdo_info.entries)

        # Register each entry
        {final_data, unique_names} =
          Enum.reduce(entry_names, {data, []}, fn entry_name, {acc_data, acc_names} ->
            case do_register_entry(pdo_name, entry_name, domain_name, acc_data) do
              {:ok, unique_name, updated_data} ->
                {updated_data, [unique_name | acc_names]}

              {:error, reason} ->
                throw({:registration_error, reason})
            end
          end)

        {:ok, Enum.reverse(unique_names), final_data}

      {:error, reason} ->
        {:error, reason}
    end
  catch
    {:registration_error, reason} -> {:error, reason}
  end

  # Validates that an entry exists in the PDO
  defp validate_entry_exists(pdo_info, entry_name) do
    if Map.has_key?(pdo_info.entries, entry_name) do
      :ok
    else
      available = Map.keys(pdo_info.entries) |> Enum.join(", ")

      {:error,
       {:entry_not_found, entry_name,
        "Available entries: #{available}"}}
    end
  end

  # Prepares slave for incremental entry/PDO registration by clearing existing configuration
  defp clear_all_pdo_config(data) do
    data.driver.list_pdos(data.driver_state)
    |> Enum.map(fn pdo_name ->
      {:ok, info} = data.driver.pdo_info(data.driver_state, pdo_name)
      info
    end)
    |> Enum.group_by(fn info ->
      {sync_idx, _dir, _wd} = info.sync_manager
      sync_idx
    end)
    |> Enum.each(fn {sync_index, infos} ->
      # Get sync manager config from first PDO in this sync
      {_sync_idx, direction, watchdog} = hd(infos).sync_manager

      # Configure sync manager with direction and watchdog settings
      config_sync_manager_internal(data, sync_index, direction, watchdog)

      # Clear all PDO assignments from this sync manager
      config_pdo_assign_clear_internal(data, sync_index)

      # Clear mappings for all PDOs in this sync manager
      infos
      |> Enum.map(& &1.pdo_index)
      |> Enum.uniq()
      |> Enum.each(&config_pdo_mapping_clear_internal(data, &1))
    end)
  end

  # Internal helpers that call Master (all NIF communication goes through Master)

  defp get_sync_manager_internal(data, sync_index) do
    Master.slave_operation(data.master, data.position, :get_sync_manager, [sync_index])
  end

  defp get_pdo_internal(data, sync_index, pdo_pos) do
    Master.slave_operation(data.master, data.position, :get_pdo, [sync_index, pdo_pos])
  end

  defp get_pdo_entry_internal(data, sync_index, pdo_pos, entry_pos) do
    Master.slave_operation(data.master, data.position, :get_pdo_entry, [
      sync_index,
      pdo_pos,
      entry_pos
    ])
  end

  defp config_sync_manager_internal(data, sync_index, direction, watchdog) do
    Master.slave_operation(data.master, data.position, :config_sync_manager, [
      data.slave_config,
      sync_index,
      direction,
      watchdog
    ])
  end

  defp config_pdo_assign_clear_internal(data, sync_index) do
    Master.slave_operation(data.master, data.position, :config_pdo_assign_clear, [
      data.slave_config,
      sync_index
    ])
  end

  defp config_pdo_assign_add_internal(data, sync_index, pdo_index) do
    Master.slave_operation(data.master, data.position, :config_pdo_assign_add, [
      data.slave_config,
      sync_index,
      pdo_index
    ])
  end

  defp config_pdo_mapping_clear_internal(data, pdo_index) do
    Master.slave_operation(data.master, data.position, :config_pdo_mapping_clear, [
      data.slave_config,
      pdo_index
    ])
  end

  defp config_pdo_mapping_add_internal(data, pdo_index, entry_index, entry_subindex, entry_size) do
    Master.slave_operation(data.master, data.position, :config_pdo_mapping_add, [
      data.slave_config,
      pdo_index,
      entry_index,
      entry_subindex,
      entry_size
    ])
  end

  # Converts EtherCAT direction integer to atom for domain registration
  # 1 = EC_DIR_OUTPUT (master writes, slave reads)
  # 2 = EC_DIR_INPUT (master reads, slave writes)
  defp ethercat_direction_to_atom(2), do: :input
  defp ethercat_direction_to_atom(_), do: :output
end
