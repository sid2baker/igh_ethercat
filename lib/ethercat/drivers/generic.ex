defmodule EtherCAT.Drivers.Generic do
  @moduledoc """
  Auto-discovers PDOs from slave EEPROM for devices without specific drivers.
  """
  use EtherCAT.Slave.Driver

  @impl true
  def configure(ctx, _state, _config) do
    # For Generic driver, configuration = discovering PDOs from EEPROM
    pdos = discover_pdos_from_eeprom(ctx, ctx.sync_count)
    Logger.debug("Generic driver discovered PDOs: #{inspect(pdos)}")
    {:ok, %{pdos: pdos}}
  end

  @impl true
  def list_pdos(%{pdos: pdos}) when is_map(pdos) do
    Map.keys(pdos)
  end

  def list_pdos(_state), do: []

  @impl true
  def pdo_info(%{pdos: pdos}, pdo_name) when is_map(pdos) do
    case Map.fetch(pdos, pdo_name) do
      {:ok, pdo_config} -> {:ok, pdo_config}
      :error -> {:error, {:pdo_not_found, pdo_name}}
    end
  end

  def pdo_info(_state, pdo_name) do
    {:error, {:pdo_not_found, pdo_name}}
  end

  @impl true
  def terminate(_state), do: :ok
end
