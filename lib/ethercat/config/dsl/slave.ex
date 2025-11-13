defmodule EtherCAT.Config.Dsl.Slave do
  @moduledoc false
  # Entity target for slave DSL

  defstruct [
    :position,
    :name,
    :driver,    # Will be a Driver entity (singleton)
    :expect,    # Will be an Expect entity (singleton)
    :config,    # Will be a Config entity (singleton)
    :__spark_metadata__,
    entries: []  # Will be a list of Entry entities
  ]
end
