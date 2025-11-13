defmodule EtherCAT.Config.Dsl.Config do
  @moduledoc false
  # Entity target for config DSL block
  # Captures driver-specific configuration as a map

  defstruct [:__fields__, :__spark_metadata__]

  def new(fields) when is_list(fields) do
    %__MODULE__{__fields__: Map.new(fields)}
  end
end
