defmodule EtherCAT.SlaveConfig do
  @moduledoc """
  Configuration and expected specification for an EtherCAT slave device.

  This struct defines the expected properties of a slave at a specific position
  on the EtherCAT bus. It is used for hardware verification to ensure that the
  physical hardware matches the expected configuration.

  ## Fields

  - `:position` - Bus position (0-based index)
  - `:vendor_id` - Vendor identification (32-bit)
  - `:product_code` - Product code (32-bit)
  - `:name` - Optional semantic name for the slave (atom)
  - `:alias` - Optional alias address (defaults to 0)
  - `:pdos` - List of expected PDO configurations (future use)
  - `:sdos` - List of SDO configurations to apply (future use)

  ## Example

      %EtherCAT.SlaveConfig{
        position: 0,
        vendor_id: 0x00000002,
        product_code: 0x0C1E3052,
        name: :temp_sensor,
        alias: 0
      }
  """

  @type t :: %__MODULE__{
          position: non_neg_integer(),
          vendor_id: non_neg_integer(),
          product_code: non_neg_integer(),
          name: atom() | nil,
          alias: non_neg_integer(),
          pdos: list(),
          sdos: list()
        }

  defstruct [
    :position,
    :vendor_id,
    :product_code,
    :name,
    alias: 0,
    pdos: [],
    sdos: []
  ]
end
