defmodule EtherCAT.Config.SlaveConfig do
  @moduledoc """
  Slave device configuration.

  Defines how a slave at a specific bus position should be configured,
  including driver selection, expected hardware identity, driver config,
  and entry-to-domain routing.
  """

  alias EtherCAT.Config.EntryConfig

  defstruct [
    :position,
    :name,
    :driver,
    :expected,
    :config,
    :entries
  ]

  @type expected :: %{
          vendor: non_neg_integer(),
          product: non_neg_integer()
        }

  @type t :: %__MODULE__{
          position: non_neg_integer(),
          name: atom() | nil,
          driver: module(),
          expected: expected() | nil,
          config: map(),
          entries: [EntryConfig.t()]
        }

  @doc """
  Creates a new slave configuration.

  ## Parameters
  - `position` - Bus position (0-based)
  - `opts` - Configuration options:
    - `:name` - Semantic slave name (optional)
    - `:driver` - Driver module implementing EtherCAT.Slave.Driver
    - `:expected` - Expected vendor/product codes for verification
    - `:config` - Driver-specific configuration map
    - `:entries` - List of EntryConfig structs for domain routing
  """
  @spec new(non_neg_integer(), keyword()) :: t()
  def new(position, opts \\ []) when is_integer(position) and position >= 0 do
    %__MODULE__{
      position: position,
      name: Keyword.get(opts, :name),
      driver: Keyword.get(opts, :driver),
      expected: Keyword.get(opts, :expected),
      config: Keyword.get(opts, :config, %{}),
      entries: Keyword.get(opts, :entries, [])
    }
  end

  @doc """
  Validates slave configuration.

  Checks:
  - Driver module is specified
  - Expected format is valid if provided
  - All entries are valid EntryConfig structs
  """
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = slave) do
    with :ok <- validate_driver(slave),
         :ok <- validate_expected(slave),
         :ok <- validate_entries(slave) do
      :ok
    end
  end

  defp validate_driver(%{driver: nil}), do: {:error, :driver_required}
  defp validate_driver(%{driver: driver}) when is_atom(driver), do: :ok
  defp validate_driver(_), do: {:error, :invalid_driver}

  defp validate_expected(%{expected: nil}), do: :ok

  defp validate_expected(%{expected: %{vendor: v, product: p}})
       when is_integer(v) and is_integer(p),
       do: :ok

  defp validate_expected(_), do: {:error, :invalid_expected_format}

  defp validate_entries(%{entries: entries}) do
    if Enum.all?(entries, &match?(%EntryConfig{}, &1)) do
      :ok
    else
      {:error, :invalid_entry_config}
    end
  end
end
