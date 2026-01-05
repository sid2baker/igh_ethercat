defmodule EtherCAT.HardwareConfig.DomainConfig do
  @moduledoc """
  EtherCAT domain configuration.
  """

  defstruct [
    :name,
    :cyclic_multiplier
  ]

  @type t :: %__MODULE__{
          name: atom(),
          cyclic_multiplier: pos_integer()
        }
end
