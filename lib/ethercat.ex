defmodule EtherCAT do
  @moduledoc """
  EtherCAT supervision tree and public API.

  Supervises:
  - `EtherCAT.Master` - The EtherCAT master state machine
  - `EtherCAT.SlaveSupervisor` - DynamicSupervisor for slave drivers

  Uses `:rest_for_one` strategy: if Master crashes, SlaveSupervisor (and all slaves) restart.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @impl Supervisor
  def init(opts) do
    children = [
      {DynamicSupervisor, strategy: :one_for_one, name: EtherCAT.SlaveSupervisor},
      {EtherCAT.Master, opts}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  def read_pdo_entry({slave_name, pdo_name, entry_name}) do
    GenServer.call(slave_name, {:read_pdo_entry, pdo_name, entry_name})
  end

  def write_pdo_entry({slave_name, pdo_name, entry_name}, value) do
    GenServer.call(slave_name, {:write_pdo_entry, pdo_name, entry_name, value})
  end

  def subscribe_pdo_entry({slave_name, pdo_name, entry_name}) do
    GenServer.call(slave_name, {:subscribe, pdo_name, entry_name})
  end

  def unsubscribe_pdo_entry({slave_name, pdo_name, entry_name}) do
    GenServer.call(slave_name, {:unsubscribe, pdo_name, entry_name})
  end

  def get_pdos(slave_name) do
    GenServer.call(slave_name, :get_pdos)
  end
end
