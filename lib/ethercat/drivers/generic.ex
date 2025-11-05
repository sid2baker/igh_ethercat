defmodule EtherCAT.Drivers.Generic do
  use EtherCAT.Slave.Driver

  def configure(state, _config) do
    {:ok, state}
  end

  def list_pdos(state) do
    Map.keys(state.pdos)
  end

  def pdo_info(state, pdo) do
    {:ok, Map.get(state.pdos, pdo)}
  end

  def terminate(state) do
    :ok
  end
end
