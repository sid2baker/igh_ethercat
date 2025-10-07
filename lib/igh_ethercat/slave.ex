defmodule IghEthercat.Slave do
  use GenServer
  require Logger

  alias IghEthercat.{Master, Domain, Nif}

  defstruct [
    :driver,
    :driver_state,
    :master,
    :alias,
    :position,
    :vendor_id,
    :product_code,
    :slave_config,
    :configured_inputs,
    :configured_outputs
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
          configured_inputs: %{name() => {domain(), type(), offset()}},
          configured_outputs: %{name() => {domain(), type(), offset()}}
        }

  @type name :: atom()
  @type domain :: atom()
  @type type :: atom()
  @type offset :: non_neg_integer()

  # Client API
  def create(master, position, driver, slave_config) do
    {:ok, pid} = GenServer.start(__MODULE__, {master, position, driver, slave_config})
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

  def register_pdos(slave, names, domain \\ :default_domain) do
    GenServer.call(slave, {:register_pdos, names, domain})
  end

  def register_all_pdos(slave, domain \\ :default_domain) do
    all_pdos = list_pdos(slave)
    register_pdos(slave, all_pdos, domain)
  end

  def set_pdo(slave, variable, value) do
    GenServer.call(slave, {:set_pdo, variable, value})
  end

  def get_pdo(slave, variable) do
    GenServer.call(slave, {:get_value, variable})
  end

  def watch_pdo(slave, variable, pid \\ self()) do
    GenServer.call(slave, {:watch_value, variable, pid})
  end

  def get_slave_config(slave) do
    GenServer.call(slave, {:get_slave_config})
  end

  def subscribe_all(slave, domain \\ :default_domain) do
    GenServer.call(slave, {:subscribe_all, domain})
  end

  def test do
    IO.inspect("test")
  end

  def get_pdos(pid, sync_index) do
    GenServer.call(pid, {:get_pdos, sync_index})
  end

  @impl true
  def init({master, position, driver, slave_config}) do
    state = %__MODULE__{
      driver: driver,
      driver_state: %{},
      master: master,
      alias: 0,
      position: position,
      slave_config: slave_config,
      configured_inputs: %{},
      configured_outputs: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:set_driver, driver}, _from, state) do
    sc =
      Master.request_nif(
        state.master,
        {:master_slave_config, [state.alias, state.position, state.vendor_id, state.product_code]}
      )

    {:reply, :ok, %{state | driver: driver, slave_config: sc}}
  end

  def handle_call({:get_slave_config}, _from, state) do
    {:reply, state.slave_config, state}
  end

  def handle_call({:configure, config}, _from, state) do
    {:ok, driver_state} = state.driver.configure(config)
    {:reply, :ok, %{state | driver_state: driver_state}}
  end

  def handle_call(:list_pdos, _from, state) do
    {:reply, state.driver.list_pdos(state.driver_state), state}
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
        Nif.slave_config_sync_manager(state.slave_config, sync_index, direction, watchdog)
        Nif.slave_config_pdo_assign_clear(state.slave_config, sync_index)

        for {pdo_index, entries} <- pdos, {name, {entry_index, entry_subindex, entry_size}} <- entries do
          Nif.slave_config_pdo_assign_add(state.slave_config, sync_index, pdo_index)
          Nif.slave_config_pdo_mapping_clear(state.slave_config, pdo_index)

          Nif.slave_config_pdo_mapping_add(
          state.slave_config,
          pdo_index,
          entry_index,
          entry_subindex,
          entry_size
          )

          {name, {entry_index, entry_subindex, entry_size}}
        end
      end
      |> List.flatten()
      |> IO.inspect(label: "Entries")

    for {name, entry} <- configured_entries do
      Domain.register_pdo_entry(domain, state.slave_config, name, entry)
    end

    {:reply, :ok, state}
  end

  def handle_call({:set_pdo, variable}, _from, state) do
    {domain, type, offset} = state.configured_outputs[variable]
    domain_ref = Domain.get_ref(domain)

    result =
      case type do
        :bool ->
          nil
      end
  end

  def handle_call({:get_pdo, variable}, _from, state) do
    {domain, type, offset} = state.configured_inputs[variable]
    domain_ref = Domain.get_ref(domain)

    result =
      case type do
        :bool -> Nif.get_domain_value_bool(domain_ref, offset)
        _ -> IO.debug("Not implemented yet")
      end

    {:reply, result, state}
  end

  def handle_call({:watch_pdo, pid, variable}, _from, state) do
    {domain, type, offset} = state.configured_inputs[variable]

    case type do
      :bool -> Domain.subscribe(domain, pid, variable, offset, 1)
      _ -> IO.debug("Not implemented yet")
    end

    {:reply, :ok, state}
  end

  def handle_call({:get_pdos, sync_index}, _from, state) do
    sync_manager =
      Master.request_nif(state.master, {:master_get_sync_manager, [state.position, sync_index]})

    entries =
      for pos <- create_range(sync_manager.n_pdos) do
        pdo =
          Master.request_nif(state.master, {:master_get_pdo, [state.position, sync_index, pos]})

        for entry_pos <- create_range(pdo.n_entries) do
          Master.request_nif(
            state.master,
            {:master_get_pdo_entry, [state.position, sync_index, pos, entry_pos]}
          )
        end
      end

    {:reply, {:ok, entries}, state}
  end

  def terminate(_reason, %{driver: mod, driver_state: s}) do
    mod.terminate(s)
  end

  defp create_range(0), do: []
  defp create_range(n), do: 0..(n - 1)
end
