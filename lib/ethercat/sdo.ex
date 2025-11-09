defmodule EtherCAT.SDO do
  @moduledoc """
  Helper utilities for SDO (Service Data Object) configuration.

  Provides type encoding, validation, and common patterns for driver authors.
  Use these helpers if you understand the EtherCAT SDO protocol.

  ## Warning

  Incorrect SDO configuration can:
  - Prevent slave from reaching operational state
  - Cause incorrect sensor readings
  - Damage hardware in extreme cases

  Always consult device documentation before configuring SDOs.

  ## Example

      alias EtherCAT.{NIF, SDO}

      # In driver configure/2 callback
      slave_config = state.slave_config

      # Configure filter (16-bit value)
      :ok = NIF.slave_config_sdo16(slave_config, 0x8000, 0x15, 10)

      # Or with batch configuration
      SDO.configure_batch(slave_config, [
        {0x8000, 0x06, SDO.encode_bool(true)},
        {0x8000, 0x15, SDO.encode_uint16(10)},
        {0x8000, 0x13, SDO.encode_int16(1000)}
      ])
  """

  alias EtherCAT.Nif

  @type sdo_index :: 0x0000..0xFFFF
  @type sdo_subindex :: 0x00..0xFF
  @type slave_config :: reference()

  # ============================================================================
  # Type Encoding Helpers
  # ============================================================================

  @doc """
  Encode a boolean value to SDO binary format.

  ## Examples

      iex> SDO.encode_bool(true)
      <<1>>

      iex> SDO.encode_bool(false)
      <<0>>
  """
  @spec encode_bool(boolean()) :: <<_::8>>
  def encode_bool(true), do: <<1::8>>
  def encode_bool(false), do: <<0::8>>

  @doc """
  Encode an 8-bit unsigned integer.

  ## Examples

      iex> SDO.encode_uint8(255)
      <<255>>
  """
  @spec encode_uint8(0..255) :: <<_::8>>
  def encode_uint8(value) when value in 0..255, do: <<value::8>>

  @doc """
  Encode a 16-bit unsigned integer (little-endian).

  ## Examples

      iex> SDO.encode_uint16(0x0A0B)
      <<11, 10>>
  """
  @spec encode_uint16(0..65535) :: <<_::16>>
  def encode_uint16(value) when value in 0..65535, do: <<value::little-16>>

  @doc """
  Encode a 32-bit unsigned integer (little-endian).

  ## Examples

      iex> SDO.encode_uint32(0x01020304)
      <<4, 3, 2, 1>>
  """
  @spec encode_uint32(0..4_294_967_295) :: <<_::32>>
  def encode_uint32(value) when value in 0..4_294_967_295, do: <<value::little-32>>

  @doc """
  Encode a 16-bit signed integer (little-endian).

  ## Examples

      iex> SDO.encode_int16(-100)
      <<156, 255>>

      iex> SDO.encode_int16(1000)
      <<232, 3>>
  """
  @spec encode_int16(-32768..32767) :: <<_::16>>
  def encode_int16(value) when value in -32768..32767, do: <<value::little-signed-16>>

  @doc """
  Encode a 32-bit signed integer (little-endian).

  ## Examples

      iex> SDO.encode_int32(-1000)
      <<24, 252, 255, 255>>
  """
  @spec encode_int32(integer()) :: <<_::32>>
  def encode_int32(value), do: <<value::little-signed-32>>

  # ============================================================================
  # Configuration Helpers
  # ============================================================================

  @doc """
  Configure multiple SDOs in sequence.

  Stops on first error and returns the failing SDO index/subindex.

  ## Example

      SDO.configure_batch(slave_config, [
        {0x8000, 0x06, <<1>>},              # Enable filter
        {0x8000, 0x15, <<10::little-16>>},  # Filter setting
        {0x8000, 0x13, <<100::little-16>>}  # Limit 1
      ])
  """
  @spec configure_batch(slave_config(), [{sdo_index(), sdo_subindex(), binary()}]) ::
          :ok | {:error, {sdo_index(), sdo_subindex(), term()}}
  def configure_batch(slave_config, sdo_list) when is_list(sdo_list) do
    Enum.reduce_while(sdo_list, :ok, fn {index, subindex, data}, :ok ->
      case Nif.slave_config_sdo(slave_config, index, subindex, data) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {index, subindex, reason}}}
      end
    end)
  end

  @doc """
  Configure an SDO with optional validation.

  ## Options

  - `:validate_range` - `{min, max}` tuple to check value is in range
  - `:allow_pdo_config` - Allow PDO mapping SDOs (default: false)

  ## Example

      # Configure with range validation
      SDO.configure(slave_config, 0x8000, 0x13, <<100::little-16>>,
        validate_range: {0, 1000})

      # Allow PDO configuration (advanced)
      SDO.configure(slave_config, 0x1C12, 0x01, <<0x1604::little-16>>,
        allow_pdo_config: true)
  """
  @spec configure(slave_config(), sdo_index(), sdo_subindex(), binary(), keyword()) ::
          :ok | {:error, term()}
  def configure(slave_config, index, subindex, data, opts \\ []) do
    with :ok <- validate_pdo_restriction(index, opts),
         :ok <- validate_range(data, opts) do
      Nif.slave_config_sdo(slave_config, index, subindex, data)
    end
  end

  @doc """
  Check if an SDO index is in the restricted PDO range.

  Returns `true` for PDO assignment (0x1C10-0x1C2F) or PDO mapping (0x1600-0x1BFF).

  ## Examples

      iex> SDO.pdo_sdo?(0x1C12)
      true

      iex> SDO.pdo_sdo?(0x1A00)
      true

      iex> SDO.pdo_sdo?(0x8000)
      false
  """
  @spec pdo_sdo?(sdo_index()) :: boolean()
  def pdo_sdo?(index) do
    (index >= 0x1C10 and index <= 0x1C2F) or
      (index >= 0x1600 and index <= 0x17FF) or
      (index >= 0x1A00 and index <= 0x1BFF)
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp validate_pdo_restriction(index, opts) do
    if pdo_sdo?(index) and not Keyword.get(opts, :allow_pdo_config, false) do
      {:error,
       {:restricted_sdo, index,
        "PDO configuration SDO. Use allow_pdo_config: true to override (not recommended)."}}
    else
      :ok
    end
  end

  defp validate_range(data, opts) do
    case Keyword.get(opts, :validate_range) do
      {min, max} ->
        # Decode as signed 16-bit for validation
        case data do
          <<value::little-signed-16>> when value >= min and value <= max ->
            :ok

          <<value::little-signed-16>> ->
            {:error, {:out_of_range, value, min, max}}

          _ ->
            # Skip validation for non-16-bit
            :ok
        end

      nil ->
        :ok
    end
  end
end
