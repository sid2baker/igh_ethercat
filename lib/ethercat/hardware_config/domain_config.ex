defmodule EtherCAT.HardwareConfig.DomainConfig do
  @moduledoc """
  EtherCAT domain configuration.
  """

  defstruct [
    :name,
    :update_rate_us
  ]

  @type t :: %__MODULE__{
          name: atom(),
          update_rate_us: pos_integer()
        }
end
