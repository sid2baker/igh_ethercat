defmodule EtherCAT.Slave.Driver do
  @moduledoc """
  Behaviour for EtherCAT slave drivers.

  This module defines the contract that all EtherCAT slave drivers must implement
  and provides shared helper functions for type-based encoding/decoding.

  ## Driver Responsibilities

  1. **SDO Configuration** - Return list of SDOs to configure before PDO activation
  2. **PDO Configuration** - Return sync manager/PDO structure for hardware setup
  3. **Value Encoding** - Convert Elixir values to binary for writing to hardware
  4. **Value Decoding** - Convert binary from hardware to Elixir values

  ## GenericDriver (Default)

  When `driver: nil` is specified in SlaveConfig, `EtherCAT.Slave.GenericDriver` is used
  with type-based encoding inferred from bit lengths.

  ## Custom Drivers

  For devices requiring custom logic (e.g., CIA 402 motor controllers):

      defmodule MyCIA402Driver do
        use GenServer
        @behaviour EtherCAT.Slave.Driver

        defstruct [:master, :name, :sync_managers, :sdos, :state_machine]

        def start_link(opts) do
          GenServer.start_link(__MODULE__, opts)
        end

        def init(opts) do
          config = opts[:config]

          state = %__MODULE__{
            master: opts[:master],
            name: opts[:name],
            sync_managers: config[:sync_managers] || [],
            sdos: config[:sdos] || [],
            state_machine: :not_ready_to_switch_on
          }

          {:ok, state}
        end

        def get_sdo_config(pid) do
          GenServer.call(pid, :get_sdo_config)
        end

        def get_pdo_config(pid) do
          GenServer.call(pid, :get_pdo_config)
        end

        def handle_call(:get_sdo_config, _from, state) do
          {:reply, state.sdos, state}
        end

        def handle_call(:get_pdo_config, _from, state) do
          {:reply, state.sync_managers, state}
        end

        # Custom encode/decode with state machine logic
        def encode_pdo_value(:control_word, :value, command, state) do
          # CIA 402 specific control word calculation
          control_word = calculate_control_word(state.state_machine, command)
          {:ok, <<control_word::little-unsigned-16>>}
        end

        def encode_pdo_value(pdo, entry, value, state) do
          # Fallback to type-based encoding
          type = find_type(state.sync_managers, pdo, entry)
          EtherCAT.Slave.Driver.encode_by_type(type, value)
        end

        def decode_pdo_value(pdo, entry, binary, state) do
          type = find_type(state.sync_managers, pdo, entry)
          EtherCAT.Slave.Driver.decode_by_type(type, binary)
        end
      end
  """

  require Logger

  alias EtherCAT.Config.{SyncManagerConfig, SdoConfig}

  # ========================================================================
  # Behaviour Definition
  # ========================================================================

  @typedoc "PDO name (typically an atom like :ch1 or :inputs)"
  @type pdo_name :: atom() | String.t()

  @typedoc "Entry name within a PDO (typically an atom like :value or :error)"
  @type entry_name :: atom() | String.t()

  @doc """
  Get SDO configuration for this slave.

  Returns a list of SDO writes to perform before PDO configuration.
  SDOs are applied in order during slave setup.

  ## Returns
  - `[SdoConfig.t()]` - List of SDO configurations

  ## Example

      def get_sdo_config(_pid) do
        [
          %SdoConfig{index: 0x8000, subindex: 0x01, data: <<0xFF>>},
          %SdoConfig{index: 0x8001, subindex: 0x02, data: <<100::little-unsigned-16>>}
        ]
      end
  """
  @callback get_sdo_config(pid()) :: [SdoConfig.t()]

  @doc """
  Get PDO configuration for this slave.

  Returns the sync manager structure defining PDO layout.
  This is used by Master to configure the slave's PDO assignments and mappings.

  ## Returns
  - `[SyncManagerConfig.t()]` - List of sync manager configurations

  ## Example

      def get_pdo_config(pid) do
        GenServer.call(pid, :get_pdo_config)
      end

      # In handle_call
      def handle_call(:get_pdo_config, _from, state) do
        {:reply, state.sync_managers, state}
      end
  """
  @callback get_pdo_config(pid()) :: [SyncManagerConfig.t()]

  @doc """
  Encode a PDO value to binary.

  ## Parameters
  - `pdo_name` - PDO identifier (e.g., `:ch1`)
  - `entry_name` - Entry identifier (e.g., `:value`)
  - `value` - Value to encode
  - `state` - Driver state (for type lookup or custom logic)

  ## Returns
  - `{:ok, binary}` on success
  - `{:error, reason}` on failure
  """
  @callback encode_pdo_value(pdo_name(), entry_name(), value :: term(), state :: term()) ::
              {:ok, binary()} | {:error, term()}

  @doc """
  Decode a PDO value from binary.

  ## Parameters
  - `pdo_name` - PDO identifier (e.g., `:ch1`)
  - `entry_name` - Entry identifier (e.g., `:value`)
  - `binary` - Raw binary data from hardware
  - `state` - Driver state (for type lookup or custom logic)

  ## Returns
  - `{:ok, value}` on success
  - `{:error, reason}` on failure
  """
  @callback decode_pdo_value(pdo_name(), entry_name(), binary(), state :: term()) ::
              {:ok, term()} | {:error, term()}

  # ========================================================================
  # Public Helper Functions
  # ========================================================================

  @doc """
  Infer type from bit length for entries without explicit type annotation.

  Used by drivers to determine encoding/decoding type from PDO entry bit lengths.
  """
  @spec infer_type_from_bit_length(pos_integer()) :: atom()
  def infer_type_from_bit_length(1), do: :bool
  def infer_type_from_bit_length(size) when size >= 2 and size < 8, do: :uint8
  def infer_type_from_bit_length(8), do: :uint8
  def infer_type_from_bit_length(16), do: :uint16
  def infer_type_from_bit_length(32), do: :uint32
  def infer_type_from_bit_length(64), do: :uint64
  def infer_type_from_bit_length(_), do: :uint16

  # ========================================================================
  # Type-Based Encoding/Decoding
  # ========================================================================

  @doc """
  Encode value by type using standard EtherCAT binary formats.
  """
  @spec encode_by_type(atom(), term()) :: {:ok, binary()} | {:error, term()}
  def encode_by_type(:bool, value) when is_boolean(value) do
    {:ok, <<if(value, do: 1, else: 0)>>}
  end

  def encode_by_type(:uint8, value) when is_integer(value) and value >= 0 and value <= 255 do
    {:ok, <<value::little-unsigned-8>>}
  end

  def encode_by_type(:int8, value) when is_integer(value) and value >= -128 and value <= 127 do
    {:ok, <<value::little-signed-8>>}
  end

  def encode_by_type(:uint16, value) when is_integer(value) and value >= 0 and value <= 65535 do
    {:ok, <<value::little-unsigned-16>>}
  end

  def encode_by_type(:int16, value)
      when is_integer(value) and value >= -32768 and value <= 32767 do
    {:ok, <<value::little-signed-16>>}
  end

  def encode_by_type(:uint32, value) when is_integer(value) and value >= 0 do
    {:ok, <<value::little-unsigned-32>>}
  end

  def encode_by_type(:int32, value) when is_integer(value) do
    {:ok, <<value::little-signed-32>>}
  end

  def encode_by_type(:uint64, value) when is_integer(value) and value >= 0 do
    {:ok, <<value::little-unsigned-64>>}
  end

  def encode_by_type(:int64, value) when is_integer(value) do
    {:ok, <<value::little-signed-64>>}
  end

  def encode_by_type(type, value) do
    {:error, {:invalid_value_for_type, value, type}}
  end

  @doc """
  Decode binary by type using standard EtherCAT binary formats.
  """
  @spec decode_by_type(atom(), binary()) :: {:ok, term()} | {:error, term()}
  def decode_by_type(:bool, <<value>>) do
    {:ok, value != 0}
  end

  def decode_by_type(:uint8, <<value::little-unsigned-8>>) do
    {:ok, value}
  end

  def decode_by_type(:int8, <<value::little-signed-8>>) do
    {:ok, value}
  end

  def decode_by_type(:uint16, <<value::little-unsigned-16>>) do
    {:ok, value}
  end

  def decode_by_type(:int16, <<value::little-signed-16>>) do
    {:ok, value}
  end

  def decode_by_type(:uint32, <<value::little-unsigned-32>>) do
    {:ok, value}
  end

  def decode_by_type(:int32, <<value::little-signed-32>>) do
    {:ok, value}
  end

  def decode_by_type(:uint64, <<value::little-unsigned-64>>) do
    {:ok, value}
  end

  def decode_by_type(:int64, <<value::little-signed-64>>) do
    {:ok, value}
  end

  def decode_by_type(type, data) do
    {:error, {:invalid_data_for_type, byte_size(data), type}}
  end
end
