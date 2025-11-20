defmodule EtherCAT.Config.PdoConfig do
  @moduledoc """
  EtherCAT PDO configuration.

  Represents a single PDO (Process Data Object) with its index, name,
  and entry mappings. Maps directly to `ec_pdo_info_t` in the C library.

  ## Fields

  - `index` - PDO index (e.g., 0x1600 for RxPDO, 0x1A00 for TxPDO)
  - `name` - Semantic name for application access (e.g., `:channel_1`)
  - `entries` - Map of entry_name => {index, subindex, bit_length}

  ## Example

      %PdoConfig{
        index: 0x1A00,
        name: :channel_1,
        entries: %{
          input: {0x6000, 0x01, 1},
          status: {0x6010, 0x01, 8}
        }
      }
  """

  defstruct [:index, :name, :entries]

  @type entry_tuple :: {
          index :: non_neg_integer(),
          subindex :: non_neg_integer(),
          bit_length :: pos_integer()
        }

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          name: atom(),
          entries: %{atom() => entry_tuple()}
        }

  @doc """
  Creates a new PDO configuration.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      index: Keyword.fetch!(opts, :index),
      name: Keyword.fetch!(opts, :name),
      entries: Keyword.get(opts, :entries, %{})
    }
  end

  @doc """
  Validates PDO configuration.
  """
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = pdo) do
    with :ok <- validate_index(pdo.index),
         :ok <- validate_name(pdo.name),
         :ok <- validate_entries(pdo.entries) do
      :ok
    end
  end

  defp validate_index(index) when is_integer(index) and index > 0, do: :ok
  defp validate_index(_), do: {:error, :invalid_pdo_index}

  defp validate_name(name) when is_atom(name), do: :ok
  defp validate_name(_), do: {:error, :invalid_pdo_name}

  defp validate_entries(entries) when is_map(entries) do
    entries
    |> Enum.reduce_while(:ok, fn {name, tuple}, :ok ->
      if is_atom(name) and valid_entry_tuple?(tuple) do
        {:cont, :ok}
      else
        {:halt, {:error, :invalid_entry_format}}
      end
    end)
  end

  defp validate_entries(_), do: {:error, :entries_must_be_map}

  defp valid_entry_tuple?({index, subindex, bit_length})
       when is_integer(index) and index >= 0 and
              is_integer(subindex) and subindex >= 0 and
              is_integer(bit_length) and bit_length > 0,
       do: true

  defp valid_entry_tuple?(_), do: false
end
