defmodule EtherCAT.HardwareConfig do
  @moduledoc """
  Complete EtherCAT system hardware configuration.
  """

  alias EtherCAT.HardwareConfig.DomainConfig
  alias EtherCAT.HardwareConfig.SlaveConfig

  defstruct [
    :domains,
    :slaves
  ]

  @type t :: %__MODULE__{
          domains: [DomainConfig.t()],
          slaves: [SlaveConfig.t()]
        }
end
