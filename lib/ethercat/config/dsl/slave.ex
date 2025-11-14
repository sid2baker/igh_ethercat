defmodule EtherCAT.Config.Dsl.Slave do
  @moduledoc false
  # Entity target for slave DSL

  defstruct [
    :position,
    :name,
    # Will be a Driver entity (singleton)
    :driver,
    # Will be an Expect entity (singleton)
    :expect,
    # Will be a Config entity (singleton)
    :config,
    :__spark_metadata__,
    # Will be a list of Entry entities
    entries: []
  ]
end
