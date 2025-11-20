defmodule EtherCAT.Config.SdoConfig do
  @moduledoc """
  EtherCAT SDO (Service Data Object) configuration.

  Represents an SDO write operation to configure a slave before PDO activation.
  SDOs are applied in order during slave configuration.

  ## Fields

  - `index` - SDO index (0x0000-0xFFFF)
  - `subindex` - SDO subindex (0x00-0xFF)
  - `data` - Binary data to write

  ## Example

      # Write 0xFF to SDO 0x8000:0x01
      %SdoConfig{
        index: 0x8000,
        subindex: 0x01,
        data: <<0xFF>>
      }

      # Write uint16 value 1000
      %SdoConfig{
        index: 0x8001,
        subindex: 0x02,
        data: <<1000::little-unsigned-16>>
      }
  """

  defstruct [:index, :subindex, :data]

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          subindex: non_neg_integer(),
          data: binary()
        }

  @doc """
  Creates a new SDO configuration.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      index: Keyword.fetch!(opts, :index),
      subindex: Keyword.fetch!(opts, :subindex),
      data: Keyword.fetch!(opts, :data)
    }
  end

  @doc """
  Validates SDO configuration.
  """
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = sdo) do
    with :ok <- validate_index(sdo.index),
         :ok <- validate_subindex(sdo.subindex),
         :ok <- validate_data(sdo.data) do
      :ok
    end
  end

  defp validate_index(index) when is_integer(index) and index >= 0 and index <= 0xFFFF, do: :ok
  defp validate_index(_), do: {:error, :invalid_sdo_index}

  defp validate_subindex(subindex) when is_integer(subindex) and subindex >= 0 and subindex <= 0xFF,
    do: :ok

  defp validate_subindex(_), do: {:error, :invalid_sdo_subindex}

  defp validate_data(data) when is_binary(data) and byte_size(data) > 0, do: :ok
  defp validate_data(_), do: {:error, :invalid_sdo_data}
end
