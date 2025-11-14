defmodule EtherCAT.Config.Dsl.Master do
  @moduledoc false
  # Entity target for master DSL
  # Captures the EtherCAT master configuration

  defstruct [
    :index,
    :update_interval,
    :nif_yield_interval,
    :__spark_metadata__
  ]
end
