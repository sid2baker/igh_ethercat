defmodule EtherCAT.Utils do
  @moduledoc """
  Internal utility functions for EtherCAT operations.

  Provides common helpers used across the EtherCAT modules.
  """

  @doc """
  Creates a range from 0 to n-1, or returns empty list if n is 0.

  This helper is used for iterating over EtherCAT slaves, sync managers,
  PDOs, and other zero-indexed collections from the IgH EtherCAT library.

  ## Examples

      iex> EtherCAT.Utils.create_range(0)
      []

      iex> EtherCAT.Utils.create_range(3)
      0..2

      iex> Enum.to_list(EtherCAT.Utils.create_range(5))
      [0, 1, 2, 3, 4]
  """
  @spec create_range(non_neg_integer()) :: [] | Range.t()
  def create_range(0), do: []
  def create_range(n) when n > 0, do: 0..(n - 1)//1
end
