defmodule EtherCAT.HardwareConfig.MasterConfig do
  @moduledoc """
  EtherCAT master configuration.
  """

  defstruct [
    :cyclic_interval
  ]

  @type t :: %__MODULE__{
          cyclic_interval: pos_integer()
        }
end
