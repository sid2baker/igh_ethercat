defmodule IghEthercat.Slave do
  use GenServer
  require Logger

  alias IghEthercat.{Master, Domain, Nif}

  defstruct [
    :driver,
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
  def create(master, position, vendor_id, product_code) do
    {:ok, pid} = GenServer.start(__MODULE__, {master, position, vendor_id, product_code})
    Process.monitor(pid)
    {:ok, pid}
  end

  def set_driver(slave, driver) do
    GenServer.call(slave, {:set_driver, driver})
  end

  def configure(slave, config) do
    GenServer.call(slave, {:configure, config})
  end

  def get_value(slave, variable) do
    GenServer.call(slave, {:get_value, variable})
  end

  def watch_value(slave, pid, variable) do
    GenServer.call(slave, {:watch_value, pid, variable})
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
  def init({master, position, vendor_id, product_code}) do
    state = %__MODULE__{
      driver: nil,
      master: master,
      alias: 0,
      position: position,
      vendor_id: vendor_id,
      product_code: product_code,
      slave_config: nil,
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
    %{inputs: inputs, outputs: outputs} = state.driver.configure(state.slave_config, config)
    {:reply, :ok, %{state | configured_inputs: inputs, configured_outputs: outputs}}
  end

  def handle_call({:set_value, variable}, _from, state) do
    {domain, type, offset} = state.configured_outputs[variable]
    domain_ref = Domain.get_ref(domain)

    result =
      case type do
        :bool ->
          nil
      end
  end

  def handle_call({:get_value, variable}, _from, state) do
    {domain, type, offset} = state.configured_inputs[variable]
    domain_ref = Domain.get_ref(domain)

    result =
      case type do
        :bool -> Nif.get_domain_value_bool(domain_ref, offset)
        _ -> IO.debug("Not implemented yet")
      end

    {:reply, result, state}
  end

  def handle_call({:watch_value, pid, variable}, _from, state) do
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

  defp create_range(0), do: []
  defp create_range(n), do: 0..(n - 1)
end
