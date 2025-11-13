defmodule EtherCAT.Config.Dsl.Slave do
  @moduledoc false
  # Entity target for slave DSL

  defstruct [
    :position,
    :name,
    :driver,
    :expected,
    :config,
    :__spark_metadata__,
    entries: []
  ]
end
