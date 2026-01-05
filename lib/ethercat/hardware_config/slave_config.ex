defmodule EtherCAT.HardwareConfig.SlaveConfig do
  @moduledoc """
  EtherCAT slave device configuration.

  Defines the complete configuration for a single slave device including
  device identity, driver module, PDO/SDO configuration, and domain registrations.
  """

  defstruct [
    :name,
    :position,
    :device_identity,
    :driver,
    :config,
    :registered_entries
  ]

  @type device_identity :: %{
          vendor_id: non_neg_integer(),
          product_code: non_neg_integer(),
          revision_no: non_neg_integer() | nil,
          serial_no: non_neg_integer() | nil
        }

  @type domain_name :: atom()
  @type pdo_name :: atom()
  @type entry_name :: atom()

  @type t :: %__MODULE__{
          name: atom(),
          position: non_neg_integer(),
          device_identity: device_identity(),
          driver: module() | nil,
          config: map(),
          registered_entries: %{domain_name() => [{pdo_name(), entry_name()}]}
        }
end
