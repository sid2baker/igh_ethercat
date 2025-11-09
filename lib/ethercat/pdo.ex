defmodule EtherCAT.PDO do
  @moduledoc """
  Handle to a registered PDO entry in a domain.

  A PDO handle encapsulates all information needed to read, write, and subscribe
  to a process data object without requiring string parsing or process lookups.

  ## Structure

  - `domain` - The domain name (atom) where this PDO is registered
  - `unique_name` - Globally unique identifier (e.g., "slave_1:pdo_6000:1")
  - `master` - The master process PID

  ## Usage

      # Get handles from registration
      {:ok, [temp_handle, pressure_handle]} = EtherCAT.register_pdos(master, slave, pdos)

      # Read/write using handles
      {:ok, temp} = EtherCAT.read(temp_handle)
      EtherCAT.write(temp_handle, 25)

      # Subscribe to changes
      EtherCAT.watch(temp_handle)
      receive do
        {:data_changed, "slave_1:pdo_6000:1", value} -> IO.puts("Temp: \#{value}")
      end
  """

  defstruct [:domain, :unique_name, :master]

  @type t :: %__MODULE__{
          domain: atom(),
          unique_name: String.t(),
          master: pid()
        }

  @doc """
  Creates a new PDO handle.

  This is typically called internally by `EtherCAT.register_pdos/4`.
  """
  @spec new(atom(), String.t(), pid()) :: t()
  def new(domain, unique_name, master) do
    %__MODULE__{
      domain: domain,
      unique_name: unique_name,
      master: master
    }
  end
end
