defmodule EtherCAT.Config.Dsl.Expect do
  @moduledoc false
  # Entity target for expect DSL block
  # Captures vendor and product ID expectations

  defstruct [:vendor, :product, :__spark_metadata__]
end
