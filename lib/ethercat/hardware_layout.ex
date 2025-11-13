defmodule EtherCAT.HardwareLayout do
  @moduledoc """
  Defines the expected layout of EtherCAT slaves on the bus.

  This module provides a data structure and utilities for defining the expected
  hardware configuration of an EtherCAT network. It enables:

  - **Hardware verification**: Ensure physical hardware matches expectations
  - **Self-documentation**: Explicit declaration of required slaves
  - **Safety**: Fail fast if wrong hardware is connected
  - **Testing**: Generate fake slaves matching the expected layout

  ## Usage

  ### Manual Definition

      layout = %EtherCAT.HardwareLayout{
        slaves: [
          %EtherCAT.SlaveConfig{
            position: 0,
            vendor_id: 0xDEAD,
            product_code: 0x0001,
            name: :simple_io
          },
          %EtherCAT.SlaveConfig{
            position: 1,
            vendor_id: 0x00000002,
            product_code: 0x0C1E3052,
            name: :temp_sensor
          }
        ]
      }

      # Use with verification
      {:ok, master, slaves} = EtherCAT.open(expected: layout, match: :exact)

  ### Discovery and Generation

      # Discover hardware without expectations
      {:ok, master, slaves} = EtherCAT.open()

      # Generate layout from discovered slaves
      layout = EtherCAT.HardwareLayout.from_slaves(slaves)

      # Inspect and save for future use
      IO.inspect(layout)

  ## Future Enhancements

  In future versions, a DSL macro will be provided for more convenient syntax:

      defmodule MyApp.ProductionLayout do
        use EtherCAT.HardwareConfig

        slave 0, vendor: 0xDEAD, product: 0x0001, name: :simple_io
        slave 1, vendor: 0x00000002, product: 0x0C1E3052, name: :temp_sensor
      end
  """

  alias EtherCAT.SlaveConfig

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
      #     %EtherCAT.SlaveConfig{position: 0, vendor_id: 0x00000002, ...},
      #     %EtherCAT.SlaveConfig{position: 1, vendor_id: 0xDEAD, ...}
      #   ]
      # }

  ## Future Options

  - `:include_pdos` - Query and include PDO layout (requires NIF calls)
  - `:include_sdos` - Read current SDO values (slow, requires uploads)
  - `:minimal` - Only include essential fields
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
            vendor_id: info.vendor_id,
            product_code: info.product_code,
            name: info.name,
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

  @doc """
  Generates Elixir module source code from a hardware layout.

  Creates a string containing module source code that defines the given layout.
  This can be saved to a file and committed to version control.

  ## Parameters

  - `layout` - A `%EtherCAT.HardwareLayout{}` struct
  - `opts` - Options:
    - `:module_name` - Full module name (e.g., "MyApp.HardwareLayout")
    - `:indent` - Indentation string (default: "  ")

  ## Returns

  A string containing the Elixir source code.

  ## Example

      layout = EtherCAT.HardwareLayout.from_slaves(slaves)
      source = EtherCAT.HardwareLayout.generate_module(layout,
        module_name: "MyApp.DiscoveredLayout"
      )

      File.write!("lib/my_app/discovered_layout.ex", source)

  ## Future Enhancement

  When the DSL macro is implemented, this will generate code using the DSL
  syntax instead of raw struct literals.
  """
  @spec generate_module(t(), keyword()) :: String.t()
  def generate_module(%__MODULE__{slaves: slaves}, opts \\ []) do
    module_name = Keyword.get(opts, :module_name, "GeneratedHardwareLayout")
    indent = Keyword.get(opts, :indent, "  ")

    slaves_code =
      slaves
      |> Enum.map(fn slave ->
        """
        #{indent}#{indent}%EtherCAT.SlaveConfig{
        #{indent}#{indent}  position: #{slave.position},
        #{indent}#{indent}  vendor_id: 0x#{Integer.to_string(slave.vendor_id, 16)},
        #{indent}#{indent}  product_code: 0x#{Integer.to_string(slave.product_code, 16)},
        #{indent}#{indent}  name: #{inspect(slave.name)},
        #{indent}#{indent}  alias: #{slave.alias}
        #{indent}#{indent}}"""
      end)
      |> Enum.join(",\n")

    """
    defmodule #{module_name} do
      @moduledoc \"\"\"
      Auto-generated hardware layout.

      Generated at: #{DateTime.utc_now() |> DateTime.to_string()}
      \"\"\"

      def layout do
        %EtherCAT.HardwareLayout{
          slaves: [
    #{slaves_code}
          ]
        }
      end
    end
    """
  end
end
