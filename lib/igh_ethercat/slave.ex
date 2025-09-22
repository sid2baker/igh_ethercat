defmodule IghEthercat.Slave do
  use GenServer
  require Logger

  alias IghEthercat.Master

  defstruct [:master, :alias, :position, :vendor_id, :product_code, :sync_managers]

  @type t :: %__MODULE__{
          master: Master.t(),
          alias: non_neg_integer() | nil,
          position: non_neg_integer(),
          vendor_id: non_neg_integer() | nil,
          product_code: non_neg_integer() | nil,
          sync_managers: %{non_neg_integer() => sync_manager()}
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
  def create(master, position) do
    {:ok, pid} = GenServer.start(__MODULE__, {master, position})
    Process.monitor(pid)
    {:ok, pid}
  end

  def test do
    IO.inspect("test")
  end

  def get_pdos(pid, sync_index) do
    GenServer.call(pid, {:get_pdos, sync_index})
  end

  @impl true
  def init({master, position}) do
    state = %__MODULE__{
      master: master,
      alias: 0,
      position: position,
      vendor_id: nil,
      product_code: nil,
      sync_managers: %{}
    }

    {:ok, state}
  end

  @impl true
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
