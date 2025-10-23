defmodule IghEthercat.Utils do
  def create_range(0), do: []
  def create_range(n), do: 0..(n - 1)
end
