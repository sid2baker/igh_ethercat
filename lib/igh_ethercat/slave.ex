defmodule IghEthercat.Slave do
  use GenServer
  require Logger

  alias IghEthercat.Master

  defstruct [:driver, :master, :alias, :position, :vendor_id, :product_code, :slave_config]

  @type t :: %__MODULE__{
          driver: atom() | nil,
          master: Master.t(),
          alias: non_neg_integer(),
          position: non_neg_integer(),
          vendor_id: non_neg_integer(),
          product_code: non_neg_integer(),
          slave_config: reference() | nil
        }

  @type sync_manager :: %{
          direction: direction(),
          watchdog_mode: watchdog_mode(),
          pdos: %{non_neg_integer() => [pdo_entry()]}
        }

  @type direction :: :invalid | :input | :output | :count
  @type watchdog_mode :: :default | :enable | :disable

  @type pdo_entry :: {entry_index(), entry_subindex(), entry_size()}

  @type entry_index :: non_neg_integer()
  @type entry_subindex :: non_neg_integer()
  @type entry_size :: non_neg_integer()

  # Client API
  def create(master, position, vendor_id, product_code) do
    {:ok, pid} = GenServer.start(__MODULE__, {master, position, vendor_id, product_code})
    Process.monitor(pid)
    {:ok, pid}
  end

  def set_driver(slave, driver) do
    GenServer.call(slave, {:set_driver, driver})
  end

  def subscribe_all(slave, domain) do
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
      slave_config: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:set_driver, driver}, _from, state) do
    sc = Master.request_nif(state.master, {:master_slave_config, [state.alias, state.position, state.vendor_id, state.product_code]})
    {:reply, :ok, %{state | driver: driver, slave_config: sc}}
  end

  def handle_call({:register_all, domain}, _from, state) do
    state.driver.register_all(state.master, domain, state.slave_config)
    {:reply, :ok, state}
  end

  def handle_call({:subscribe_all, domain}, from, state) do
    state.driver.subscribe_all(state.master, domain, state.slave_config)
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
