defmodule EtherCAT.Config.Dsl.Driver do
  @moduledoc false
  # Entity target for driver DSL
  # Captures the driver module for a slave

  defstruct [:module, :__spark_metadata__]
end
