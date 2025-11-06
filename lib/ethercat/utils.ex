defmodule EtherCAT.Utils do
  @moduledoc false

  @doc """
   Creates a range from 0 to n-1, or returns empty list if n is 0.
  Helper for iterating over EtherCAT slaves, sync managers, and PDOs.
  """
  @spec create_range(non_neg_integer()) :: [] | Range.t()
  def create_range(0), do: []
  def create_range(n) when n > 0, do: 0..(n - 1)
end
