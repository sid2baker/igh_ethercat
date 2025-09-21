defmodule IghEthercat.Slave do
  @behaviour :gen_statem
  require Logger

  alias IghEthercat.Master

  defstruct [:alias, :position, :vendor_id, :product_code, :sync_managers]

  @type t :: %__MODULE__{
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

  @impl true
  def callback_mode(), do: [:handle_event_function]

  # Client API
  def start_link(position) do
    :gen_statem.start_link(__MODULE__, {position}, [])
  end

  def test do
    IO.inspect("test")
  end

  @impl true
  def init({position}) do
    data = %__MODULE__{
      alias: 0,
      position: position,
      vendor_id: nil,
      product_code: nil,
      sync_managers: %{}
    }

    Process.send_after(self(), :update_slave_state, 1_000)
    {:ok, :stale, data, []}
  end

  @impl true
  def handle_event(:info, :update_slave_state, :stale, data) do
    Process.send_after(self(), :update_slave_state, 1_000)
    # Master.get_slave_state(data.position)

    {:keep_state_and_data, []}
  end
end
