defmodule EtherCAT.Drivers.Generic do
  @moduledoc """
  Generic EtherCAT slave driver that auto-discovers PDOs from slave configuration.
  """
  use EtherCAT.Slave.Driver

  @impl true
  def configure(state, _config), do: {:ok, state}

  @impl true
  def list_pdos(state), do: Map.keys(state.pdos)

  @impl true
  def pdo_info(state, pdo), do: {:ok, Map.get(state.pdos, pdo)}

  @impl true
  def terminate(_state), do: :ok
end
