defmodule EtherCAT.Slave.Driver do
  @moduledoc """
  Behaviour and base implementation for EtherCAT slave drivers.

  Use this module in your driver to get GenServer functionality with
  default implementations for read/write/subscribe/unsubscribe operations.

  ## Usage

      defmodule MyDriver do
        use EtherCAT.Slave.Driver

        defstruct [:master, :name, :config]

        @impl GenServer
        def init(opts) do
          state = %__MODULE__{
            master: opts[:master],
            name: opts[:name],
            config: opts[:config]
          }
          {:ok, state}
        end

        @impl EtherCAT.Slave.Driver
        def configurable_pdos?(_state), do: false

        @impl EtherCAT.Slave.Driver
        def get_sdo_config(_state), do: []

        @impl EtherCAT.Slave.Driver
        def get_pdo_config(_state), do: []

        @impl EtherCAT.Slave.Driver
        def encode_pdo_value(_pdo, _entry, _value, _state), do: {:error, :not_implemented}

        @impl EtherCAT.Slave.Driver
        def decode_pdo_value(_pdo, _entry, binary, _state) do
          EtherCAT.Slave.Driver.decode_by_type(:int16, binary)
        end
      end

  ## Callbacks

  Required callbacks (state-based):
  - `init/1` - Initialize driver state (standard GenServer callback)
  - `configurable_pdos?/1` - Whether PDOs can be configured
  - `get_sdo_config/1` - Return SDO configuration list
  - `get_pdo_config/1` - Return sync manager/PDO configuration
  - `encode_pdo_value/4` - Encode value to binary for writing
  - `decode_pdo_value/4` - Decode binary to value for reading

  ## Default Implementations

  The `__using__` macro provides default `handle_call` implementations for:
  - `:configurable_pdos?`, `:get_sdo_config`, `:get_pdo_config` - delegate to callbacks
  - `{:read, pdo, entry}`, `{:write, pdo, entry, value}` - read/write operations
  - `{:subscribe, ...}`, `{:unsubscribe, ...}` - subscription management

  The Master calls these via `GenServer.call(driver_pid, :get_sdo_config)` etc.
  """

  require Logger

  # ========================================================================
  # Types
  # ========================================================================

  @typedoc "PDO name (typically an atom like :ch1 or :inputs)"
  @type pdo_name :: atom() | String.t()

  @typedoc "Entry name within a PDO (typically an atom like :value or :error)"
  @type entry_name :: atom() | String.t()

  # ========================================================================
  # Behaviour Callbacks
  # ========================================================================

  @doc """
  Whether this slave supports PDO configuration.

  Called with the driver state (not pid).

  Returns `true` if the master should write PDO assignments (0x1C12/0x1C13)
  and mappings. Returns `false` for slaves with fixed/predefined PDO layouts.
  """
  @callback configurable_pdos?(state :: term()) :: boolean()

  @doc """
  Get SDO configuration for this slave.

  Called with the driver state (not pid).
  Returns a list of SDO writes to perform before PDO configuration.
  """
  @callback get_sdo_config(state :: term()) :: [EtherCAT.Config.SdoConfig.t()]

  @doc """
  Get PDO configuration for this slave.

  Called with the driver state (not pid).
  Returns the sync manager structure defining PDO layout.
  """
  @callback get_pdo_config(state :: term()) :: [EtherCAT.Config.SyncManagerConfig.t()]

  @doc """
  Encode a PDO value to binary.

  ## Parameters
  - `pdo_name` - PDO identifier (e.g., `:ch1`)
  - `entry_name` - Entry identifier (e.g., `:value`)
  - `value` - Value to encode
  - `state` - Driver state

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
  - `state` - Driver state

  ## Returns
  - `{:ok, value}` on success
  - `{:error, reason}` on failure
  """
  @callback decode_pdo_value(pdo_name(), entry_name(), binary(), state :: term()) ::
              {:ok, term()} | {:error, term()}

  # ========================================================================
  # __using__ Macro
  # ========================================================================

  defmacro __using__(_opts) do
    quote location: :keep do
      use GenServer
      @behaviour EtherCAT.Slave.Driver

      # Default start_link - can be overridden
      def start_link(opts) do
        GenServer.start_link(__MODULE__, opts)
      end

      defoverridable start_link: 1

      # ====================================================================
      # Default handle_call implementations
      # ====================================================================

      @impl GenServer
      def handle_call(:get_sdo_config, _from, state) do
        {:reply, get_sdo_config(state), state}
      end

      @impl GenServer
      def handle_call(:get_pdo_config, _from, state) do
        {:reply, get_pdo_config(state), state}
      end

      @impl GenServer
      def handle_call(:configurable_pdos?, _from, state) do
        {:reply, configurable_pdos?(state), state}
      end

      @impl GenServer
      def handle_call({:read, pdo_name, entry_name}, _from, state) do
        result =
          with unique_name <- "#{state.name}:#{pdo_name}:#{entry_name}",
               {:ok, binary} <- EtherCAT.Master.read_pdo_entry(state.master, unique_name),
               {:ok, value} <- decode_pdo_value(pdo_name, entry_name, binary, state) do
            {:ok, value}
          else
            {:error, {:unknown_pdo_entry, pdo, entry}} ->
              {:error, {:unknown_pdo_entry, state.name, pdo, entry}}

            error ->
              error
          end

        {:reply, result, state}
      end

      @impl GenServer
      def handle_call({:write, pdo_name, entry_name, value}, _from, state) do
        result =
          with {:ok, binary} <- encode_pdo_value(pdo_name, entry_name, value, state),
               unique_name <- "#{state.name}:#{pdo_name}:#{entry_name}",
               :ok <- EtherCAT.Master.write_pdo_entry(state.master, unique_name, binary) do
            :ok
          else
            {:error, {:unknown_pdo_entry, pdo, entry}} ->
              {:error, {:unknown_pdo_entry, state.name, pdo, entry}}

            error ->
              error
          end

        {:reply, result, state}
      end

      @impl GenServer
      def handle_call({:subscribe, pdo_name, entry_name, subscriber}, _from, state) do
        unique_name = "#{state.name}:#{pdo_name}:#{entry_name}"
        result = EtherCAT.Master.subscribe(state.master, unique_name, subscriber)
        {:reply, result, state}
      end

      @impl GenServer
      def handle_call({:unsubscribe, pdo_name, entry_name, subscriber}, _from, state) do
        unique_name = "#{state.name}:#{pdo_name}:#{entry_name}"
        result = EtherCAT.Master.unsubscribe(state.master, unique_name, subscriber)
        {:reply, result, state}
      end

      # Allow drivers to add more handle_call clauses
      defoverridable handle_call: 3
    end
  end

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
