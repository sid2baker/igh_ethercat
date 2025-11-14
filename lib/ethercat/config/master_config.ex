defmodule EtherCAT.Config.MasterConfig do
  @moduledoc """
  EtherCAT master configuration.

  Defines the master index and timing parameters for the EtherCAT master.
  """

  defstruct [
    index: 0,
    update_interval: 10_000,
    nif_yield_interval: 100_000
  ]

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          update_interval: pos_integer(),
          nif_yield_interval: pos_integer()
        }

  @doc """
  Creates a new master configuration with default values.

  ## Parameters
  - `opts` - Configuration options:
    - `:index` - EtherCAT master index (default: 0)
    - `:update_interval` - Master update interval in microseconds (default: 10_000)
    - `:nif_yield_interval` - NIF yielding interval in microseconds (default: 100_000)
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      index: Keyword.get(opts, :index, 0),
      update_interval: Keyword.get(opts, :update_interval, 10_000),
      nif_yield_interval: Keyword.get(opts, :nif_yield_interval, 100_000)
    }
  end

  @doc """
  Validates master configuration.

  Checks:
  - Index is a non-negative integer
  - Update interval is positive
  - NIF yield interval is positive
  """
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = master) do
    with :ok <- validate_index(master.index),
         :ok <- validate_update_interval(master.update_interval),
         :ok <- validate_nif_yield_interval(master.nif_yield_interval) do
      :ok
    end
  end

  defp validate_index(index) when is_integer(index) and index >= 0, do: :ok
  defp validate_index(_), do: {:error, :invalid_master_index}

  defp validate_update_interval(interval) when is_integer(interval) and interval > 0, do: :ok
  defp validate_update_interval(_), do: {:error, :invalid_update_interval}

  defp validate_nif_yield_interval(interval) when is_integer(interval) and interval > 0, do: :ok
  defp validate_nif_yield_interval(_), do: {:error, :invalid_nif_yield_interval}
end
