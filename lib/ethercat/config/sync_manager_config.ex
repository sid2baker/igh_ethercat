defmodule EtherCAT.Config.SyncManagerConfig do
  @moduledoc """
  EtherCAT Sync Manager configuration.

  Represents a single sync manager with its direction, watchdog mode,
  and PDO assignments. Maps directly to `ec_sync_info_t` in the C library.

  ## Fields

  - `index` - Sync manager index (0-15, typically 2=outputs, 3=inputs)
  - `direction` - `:input` or `:output`
  - `watchdog` - `:default`, `:enabled`, or `:disabled`
  - `pdos` - List of PDO configurations for this sync manager
  """

  alias EtherCAT.Config.PdoConfig

  defstruct [:index, :direction, :watchdog, :pdos]

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          direction: :input | :output,
          watchdog: :default | :enabled | :disabled,
          pdos: [PdoConfig.t()]
        }

  @doc """
  Creates a new sync manager configuration.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      index: Keyword.fetch!(opts, :index),
      direction: Keyword.fetch!(opts, :direction),
      watchdog: Keyword.get(opts, :watchdog, :disabled),
      pdos: Keyword.get(opts, :pdos, [])
    }
  end

  @doc """
  Validates sync manager configuration.
  """
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = sm) do
    with :ok <- validate_index(sm.index),
         :ok <- validate_direction(sm.direction),
         :ok <- validate_watchdog(sm.watchdog),
         :ok <- validate_pdos(sm.pdos) do
      :ok
    end
  end

  defp validate_index(index) when is_integer(index) and index >= 0 and index < 16, do: :ok
  defp validate_index(_), do: {:error, :invalid_sync_manager_index}

  defp validate_direction(dir) when dir in [:input, :output], do: :ok
  defp validate_direction(_), do: {:error, :invalid_direction}

  defp validate_watchdog(wd) when wd in [:default, :enabled, :disabled], do: :ok
  defp validate_watchdog(_), do: {:error, :invalid_watchdog_mode}

  defp validate_pdos(pdos) when is_list(pdos) do
    if Enum.all?(pdos, &match?(%PdoConfig{}, &1)) do
      :ok
    else
      {:error, :invalid_pdo_config}
    end
  end

  defp validate_pdos(_), do: {:error, :pdos_must_be_list}
end
