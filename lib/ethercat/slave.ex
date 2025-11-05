defmodule EtherCAT.Slave do
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
          pdo_registrations: %{name() => domain()}
        }

  @type name :: String.t()
  @type domain :: atom()
  @type offset :: non_neg_integer()
  @type size :: non_neg_integer()

  # Client API

  @doc """
  Creates a new slave process.

  ## Parameters
  - `master`: The master process PID
  - `position`: The slave's position on the bus
  - `driver`: The driver module to use for this slave
  - `slave_config`: The slave configuration reference from the NIF
  - `sync_count`: Number of sync managers
  """
  def create(master, position, driver, slave_config, sync_count) do
    {:ok, pid} = GenServer.start(__MODULE__, {master, position, driver, slave_config, sync_count})
    Process.monitor(pid)
    {:ok, pid}
  end

  def set_driver(slave, driver) do
    GenServer.call(slave, {:set_driver, driver})
  end

  def configure(slave, config) do
    GenServer.call(slave, {:configure, config})
  end

  def list_pdos(slave) do
    GenServer.call(slave, :list_pdos)
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
  """
  def register_pdos(slave, names, domain \\ :default_domain) do
    GenServer.call(slave, {:register_pdos, names, domain})
  end

  @doc """
  Convenience function to register all PDOs from the driver to a domain.
  """
  def register_all_pdos(slave, domain \\ :default_domain) do
    all_pdos = list_pdos(slave)
    register_pdos(slave, all_pdos, domain)
  end

  @doc """
  Registers PDO entries to a domain for cyclic data exchange.
  """
  def register_pdo_entries(slave, domain, entries) do
    GenServer.call(slave, {:register_pdo_entries, domain, entries})
  end

  # Operational API (called after Master activation)

  @doc """
  Sets the value of a PDO output.
  """
  def set_pdo_value(slave, name, value) do
    GenServer.call(slave, {:set_pdo_value, name, value})
  end

  @doc """
  Gets the current value of a PDO input.
  """
  def get_pdo_value(slave, name) do
    GenServer.call(slave, {:get_pdo_value, name})
  end

  @doc """
  Subscribes a process to receive notifications when a PDO value changes.
  """
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
        {"pdo_#{Integer.to_string(entry_index, 16)}:#{Integer.to_string(entry_subindex, 16)}", pdo}
      end)
      |> Map.new()
      |> IO.inspect(label: "Generic Entries")

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
    Master.slave_operation(state.master, state.position, :config_sync_manager,
      [state.slave_config, sync_index, direction, watchdog])
  end

  defp config_pdo_assign_clear_internal(state, sync_index) do
    Master.slave_operation(state.master, state.position, :config_pdo_assign_clear,
      [state.slave_config, sync_index])
  end

  defp config_pdo_assign_add_internal(state, sync_index, pdo_index) do
    Master.slave_operation(state.master, state.position, :config_pdo_assign_add,
      [state.slave_config, sync_index, pdo_index])
  end

  defp config_pdo_mapping_clear_internal(state, pdo_index) do
    Master.slave_operation(state.master, state.position, :config_pdo_mapping_clear,
      [state.slave_config, pdo_index])
  end

  defp config_pdo_mapping_add_internal(state, pdo_index, entry_index, entry_subindex, entry_size) do
    Master.slave_operation(state.master, state.position, :config_pdo_mapping_add,
      [state.slave_config, pdo_index, entry_index, entry_subindex, entry_size])
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
    sync_managers =
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
      |> IO.inspect(label: "SM")

    configured_entries =
      for {sync_index, {direction, watchdog, pdos}} <- sync_managers do
        # Configure sync manager through Master
        config_sync_manager_internal(state, sync_index, direction, watchdog)
        config_pdo_assign_clear_internal(state, sync_index)

        for {pdo_index, entries} <- pdos do
          # Assign PDO to sync manager
          config_pdo_assign_add_internal(state, sync_index, pdo_index)
          config_pdo_mapping_clear_internal(state, pdo_index)

          for {name, {entry_index, entry_subindex, entry_size}} <- entries do
            # Map entries to PDO
            config_pdo_mapping_add_internal(state, pdo_index, entry_index, entry_subindex, entry_size)

            {name, {entry_index, entry_subindex, entry_size}}
          end
        end
      end
      |> List.flatten()
      |> IO.inspect(label: "Entries")

    # Register with domain
    for {name, entry} <- configured_entries do
      Domain.register_pdo_entry(domain, state.slave_config, name, entry)
    end

    # After domain is ready, query back the offset/size and cache it locally
    # Note: This will only work after Master.activate calls Domain.get_ready
    # For now, we'll store the registrations and populate offsets later
    pdo_registrations =
      configured_entries
      |> Enum.map(fn {name, _entry} -> {name, domain} end)
      |> Map.new()
      |> Map.merge(state.pdo_registrations)

    {:reply, :ok, %{state | pdo_registrations: pdo_registrations}}
  end

  # Operational API handlers
  def handle_call({:set_pdo_value, name, value}, _from, state) do
    case state.pdo_registrations[name] do
      domain_name when is_atom(domain_name) ->
        case Domain.get_entry(domain_name, name) do
          {:ok, {offset, size}} ->
            result =
              case size do
                1 -> Domain.set_value_bool(domain_name, offset, value)
                _ -> {:error, :not_implemented}
              end

            {:reply, result, state}

          {:error, :not_found} ->
            {:reply, {:error, {:entry_not_ready, name}}, state}
        end

      nil ->
        {:reply, {:error, {:pdo_not_registered, name}}, state}
    end
  end

  def handle_call({:get_pdo_value, name}, _from, state) do
    case state.pdo_registrations[name] do
      domain_name when is_atom(domain_name) ->
        case Domain.get_entry(domain_name, name) do
          {:ok, {offset, size}} ->
            result =
              case size do
                1 -> Domain.get_value_bool(domain_name, offset)
                _ -> {:error, :not_implemented}
              end

            {:reply, result, state}

          {:error, :not_found} ->
            {:reply, {:error, {:entry_not_ready, name}}, state}
        end

      nil ->
        {:reply, {:error, {:pdo_not_registered, name}}, state}
    end
  end

  def handle_call({:watch_pdo, name, pid}, _from, state) do
    case state.pdo_registrations[name] do
      domain_name when is_atom(domain_name) ->
        # Query domain for entry info
        case Domain.get_entry(domain_name, name) do
          {:ok, {offset, size}} ->
            result = Domain.subscribe(domain_name, pid, name, offset, size)
            {:reply, result, state}

          {:error, :not_found} ->
            {:reply, {:error, {:entry_not_ready, name}}, state}
        end

      nil ->
        {:reply, {:error, {:pdo_not_registered, name}}, state}
    end
  end

  @impl true
  def terminate(_reason, %{driver: mod, driver_state: s}) do
    mod.terminate(s)
  end
end
