defmodule EtherCAT.Config.DomainConfig do
  @moduledoc """
  Domain configuration for cyclic data exchange.

  A domain represents a group of PDO entries that are updated together
  at a specific cycle rate.
  """

  defstruct [
    :name,
    :cycle_multiplier
  ]

  @type t :: %__MODULE__{
          name: atom(),
          cycle_multiplier: pos_integer()
        }

  @doc """
  Creates a new domain configuration.

  ## Parameters
  - `name` - Unique domain identifier (atom)
  - `cycle_multiplier` - Process this domain every N master cycles (1 = every cycle, 200 = every 200th cycle)
  """
  @spec new(atom(), pos_integer()) :: t()
  def new(name, cycle_multiplier) when is_atom(name) and is_integer(cycle_multiplier) and cycle_multiplier > 0 do
    %__MODULE__{
      name: name,
      cycle_multiplier: cycle_multiplier
    }
  end
end
