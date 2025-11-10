defmodule EtherCAT.Utils do
  @moduledoc false

  @doc "Creates range 0..n-1 or [] if n is 0."
  @spec create_range(non_neg_integer()) :: [] | Range.t()
  def create_range(0), do: []
  def create_range(n) when n > 0, do: 0..(n - 1)//1
end
