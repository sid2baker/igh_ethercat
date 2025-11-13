defmodule EtherCAT.Config.Dsl.Slave do
  @moduledoc false
  # Entity target for slave DSL

  defstruct [
    :position,
    :name,
    :driver,
    :expected,
    :config,
    entries: []
  ]
end
