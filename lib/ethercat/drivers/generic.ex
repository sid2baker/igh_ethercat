defmodule EtherCAT.Drivers.Generic do
  @moduledoc """
  Generic EtherCAT slave driver that auto-discovers PDOs from slave EEPROM.

  This driver automatically inspects the slave's sync managers and PDO
  configuration during initialization, making it suitable for devices without
  a specialized driver implementation.

  ## Auto-Discovery Process

  During slave initialization, the Generic driver:
  1. Reads all sync managers from the slave
  2. Enumerates PDOs within each sync manager
  3. Extracts PDO entries with their indices, subindices, and bit lengths
  4. Generates unique names for each PDO entry (e.g., "pdo_6000:1")

  ## PDO Naming Convention

  PDO entries are named using the format `"pdo_<index>:<subindex>"` where both
  index and subindex are in hexadecimal notation. For example, entry 0x6000:01
  becomes "pdo_6000:1".

  ## When to Use

  Use the Generic driver when:
  - No device-specific driver exists for your slave
  - You want to quickly experiment with a new device
  - The default EEPROM-based PDO configuration is sufficient

  For production use with well-known devices, consider creating a specialized
  driver that provides:
  - Meaningful PDO names (e.g., :temperature, :pressure)
  - Custom configuration options
  - Device-specific validation

  ## Example

      # The Generic driver is automatically used when no specific driver is found
      {:ok, slave_pid} = EtherCAT.Slave.create(master, position, EtherCAT.Drivers.Generic, config, sync_count)
  """
  use EtherCAT.Slave.Driver

  @impl true
  def configure(_slave, state, _config) when is_map(state) do
    {:ok, state}
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
