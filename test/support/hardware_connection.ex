defmodule Support.HardwareConnection do
  use GenServer

  @doc """
  connection - %{{slave_name, pdo_name, entry_name} => {slave_name, pdo_name, entry_name}}
  """
  def start_link(connections) do
    GenServer.start_link(__MODULE__, connections, name: __MODULE__)
  end

  def init(connections) do
    connections
    |> Enum.each(fn {{slave_name, pdo_name, entry_name}, _to} ->
      EtherCAT.subscribe_pdo_entry({slave_name, pdo_name, entry_name})
    end)

    {:ok, %{connections: connections}}
  end

  def handle_info({:ec_update, entry, value}, state) do
    {slave_name, pdo_name, entry_name} = state.connections[entry]
    # value comes as binary, convert to integer for write
    <<int_value::size(8)>> = value
    EtherCAT.write_pdo_entry({slave_name, pdo_name, entry_name}, int_value)
    {:noreply, state}
  end
end
