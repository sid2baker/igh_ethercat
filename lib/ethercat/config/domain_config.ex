defmodule EtherCAT.Config.DomainConfig do
  @moduledoc """
  Domain configuration for cyclic data exchange.

  A domain represents a group of PDO entries that are updated together
  at a specific interval.
  """

  defstruct [
    :name,
    :interval
  ]

  @type t :: %__MODULE__{
          name: atom(),
          interval: pos_integer()
        }

  @doc """
  Creates a new domain configuration.

  ## Parameters
  - `name` - Unique domain identifier (atom)
  - `interval` - Update interval in milliseconds
  """
  @spec new(atom(), pos_integer()) :: t()
  def new(name, interval) when is_atom(name) and is_integer(interval) and interval > 0 do
    %__MODULE__{
      name: name,
      interval: interval
    }
  end
end
