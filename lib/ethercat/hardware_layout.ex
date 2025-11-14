defmodule EtherCAT.HardwareLayout do
  @moduledoc """
  Utilities for working with EtherCAT hardware layout.

  This module provides utilities for generating hardware layout information
  from discovered slaves.

  ## Usage

  ### Discovery and Generation

      # Discover hardware
      {:ok, master, slaves} = EtherCAT.open()

      # Generate layout from discovered slaves
      layout = EtherCAT.HardwareLayout.from_slaves(slaves)

      # Inspect layout
      IO.inspect(layout)
  """

  alias EtherCAT.Config.SlaveConfig

  @type t :: %__MODULE__{
          slaves: [SlaveConfig.t()]
        }

  defstruct slaves: []

  @doc """
  Generates a hardware layout from currently discovered slaves.

  This function creates a `HardwareLayout` struct by extracting the identity
  information (position, vendor ID, product code) from discovered slave processes.

  ## Parameters

  - `slaves` - List of slave PIDs returned from `EtherCAT.open/1`
  - `opts` - Options (currently unused, reserved for future extensions)

  ## Returns

  A `%EtherCAT.HardwareLayout{}` struct containing the slave configurations.

  ## Example

      {:ok, master, slaves} = EtherCAT.open()
      layout = EtherCAT.HardwareLayout.from_slaves(slaves)

      # Returns something like:
      # %EtherCAT.HardwareLayout{
      #   slaves: [
      #     %EtherCAT.Config.SlaveConfig{position: 0, expected: %{vendor: 0x00000002, ...}, ...},
      #     %EtherCAT.Config.SlaveConfig{position: 1, expected: %{vendor: 0xDEAD, ...}, ...}
      #   ]
      # }
  """
  @spec from_slaves([pid()], keyword()) :: t()
  def from_slaves(slaves, _opts \\ []) do
    slave_configs =
      slaves
      |> Enum.map(fn slave_pid ->
        # Get slave info from the process
        # The Slave GenStatem stores this in its data
        try do
          info = EtherCAT.Slave.get_info(slave_pid)

          %SlaveConfig{
            position: info.position,
            name: info.name,
            driver: nil,
            expected: %{
              vendor: info.vendor_id,
              product: info.product_code
            },
            config: %{},
            entries: [],
            alias: info.alias
          }
        catch
          :exit, reason ->
            # Slave process died or couldn't be reached
            raise "Failed to get info from slave #{inspect(slave_pid)}: #{inspect(reason)}"
        end
      end)

    %__MODULE__{slaves: slave_configs}
  end
end
