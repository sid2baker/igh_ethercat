defmodule EtherCAT.Slave.Driver do
  @moduledoc """
  Behaviour for EtherCAT slave driver processes.

  Drivers are GenServer processes (or any OTP-compliant process) that:
  1. Provide SDO and PDO configuration to the Master
  2. Handle encoding/decoding of PDO values
  3. Manage device-specific state and logic
  4. Expose read/write/subscribe APIs for application use

  ## Architecture

  When a slave is discovered on the EtherCAT network:
  1. Master determines which driver to use (based on vendor/product ID)
  2. Master starts the driver process via `start_link/1`
  3. Master fetches SDO configuration from driver
  4. Master configures SDOs via NIF
  5. Master fetches PDO configuration from driver
  6. Master configures and registers PDOs via NIF
  7. Application code reads/writes through driver process

  ## Example Implementation

      defmodule MyDevice.Driver do
        use EtherCAT.Slave.Driver
        use GenServer  # or gen_statem, or any process

        # Client API (required by behaviour)
        def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
        def get_sdo_config(pid), do: GenServer.call(pid, :get_sdo_config)
        def get_pdo_config(pid), do: GenServer.call(pid, :get_pdo_config)
        def read(pid, pdo, entry), do: GenServer.call(pid, {:read, pdo, entry})
        def write(pid, pdo, entry, val), do: GenServer.call(pid, {:write, pdo, entry, val})
        def subscribe(pid, pdo, entry, sub), do: GenServer.call(pid, {:subscribe, pdo, entry, sub})
        def unsubscribe(pid, pdo, entry, sub), do: GenServer.call(pid, {:unsubscribe, pdo, entry, sub})

        # GenServer callbacks
        def init(opts) do
          state = %{
            master: Keyword.fetch!(opts, :master),
            position: Keyword.fetch!(opts, :position),
            config: Keyword.get(opts, :config, %{})
          }
          {:ok, state}
        end

        def handle_call(:get_sdo_config, _from, state) do
          sdos = [
            # {index, subindex, data}
            {0x8000, 0x01, <<1::8>>}  # example
          ]
          {:reply, sdos, state}
        end

        def handle_call(:get_pdo_config, _from, state) do
          pdos = [
            %{
              name: :inputs,
              sync_manager: {3, :input, :default},
              pdo_index: 0x1A00,
              entries: %{
                value: {:int16, 0x6000, 0x11, 16}
              }
            }
          ]
          {:reply, pdos, state}
        end

        def handle_call({:read, pdo_name, entry_name}, _from, state) do
          # Get raw binary from Master
          case Master.read_slave_pdo(state.master, state.position, pdo_name, entry_name) do
            {:ok, binary} ->
              # Decode using driver-specific logic
              value = decode(pdo_name, entry_name, binary, state)
              {:reply, {:ok, value}, state}
            error ->
              {:reply, error, state}
          end
        end
      end
  """

  @typedoc "Driver-specific state (implementer-defined)"
  @type state :: term()

  @typedoc "PDO name (typically an atom like :ch1 or :inputs)"
  @type pdo_name :: atom() | String.t()

  @typedoc "Entry name within a PDO (typically an atom like :value or :error)"
  @type entry_name :: atom() | String.t()

  @typedoc """
  SDO configuration tuple: {index, subindex, data}

  The driver returns a list of these to configure the device before activation.
  """
  @type sdo_config :: {
          index :: 0x0000..0xFFFF,
          subindex :: 0x00..0xFF,
          data :: binary()
        }

  @typedoc """
  PDO entry configuration: {type, entry_index, entry_subindex, bit_length}

  - type: Data type (:bool, :uint8, :int16, etc.) for default encoding/decoding
  - entry_index: Object dictionary index (e.g., 0x6000)
  - entry_subindex: Object dictionary subindex (e.g., 0x01)
  - bit_length: Size in bits (1, 8, 16, 32, etc.)
  """
  @type pdo_entry_config :: {
          type :: atom(),
          entry_index :: non_neg_integer(),
          entry_subindex :: non_neg_integer(),
          bit_length :: pos_integer()
        }

  @typedoc """
  Sync manager configuration: {sync_index, direction, watchdog_mode}
  """
  @type sync_manager_config :: {
          sync_index :: non_neg_integer(),
          direction :: :invalid | :output | :input | :count,
          watchdog_mode :: :default | :enabled | :disabled
        }

  @typedoc """
  Complete PDO configuration.

  Each PDO groups related entries together (e.g., all channel 1 data).
  """
  @type pdo_config :: %{
          name: pdo_name(),
          sync_manager: sync_manager_config(),
          pdo_index: non_neg_integer(),
          entries: %{entry_name() => pdo_entry_config()},
          # Optional: Domain name for this PDO (default :default_domain)
          domain: atom(),
          # Optional: Whether this device supports dynamic PDO mapping (default true)
          supports_pdo_config?: boolean()
        }

  @doc """
  Start the driver process.

  ## Options
  - `:master` - Master process PID
  - `:position` - Slave position on bus (0-based)
  - `:slave_config` - NIF slave configuration reference
  - `:vendor_id` - Vendor identification
  - `:product_code` - Product code
  - `:revision` - Revision number
  - `:serial` - Serial number
  - `:sync_count` - Number of sync managers
  - `:config` - User configuration map (optional)

  ## Returns
  Standard GenServer.on_start() result
  """
  @callback start_link(opts :: keyword()) :: GenServer.on_start()

  @doc """
  Get SDO configuration list.

  Returns a list of SDO values to write during slave configuration,
  before the master is activated.

  ## Returns
  List of `{index, subindex, data}` tuples
  """
  @callback get_sdo_config(pid()) :: [sdo_config()]

  @doc """
  Get PDO configuration list.

  Returns the complete PDO configuration for this device, including
  sync managers, PDO assignments, and entry mappings.

  ## Returns
  List of PDO configuration maps
  """
  @callback get_pdo_config(pid()) :: [pdo_config()]

  @doc """
  Read a PDO entry value.

  The driver fetches raw binary data from the Master/NIF and decodes it
  using device-specific logic.

  ## Parameters
  - `pid` - Driver process PID
  - `pdo_name` - PDO identifier (e.g., `:ch1`)
  - `entry_name` - Entry identifier (e.g., `:value`)

  ## Returns
  - `{:ok, decoded_value}` on success
  - `{:error, reason}` on failure
  """
  @callback read(pid(), pdo_name(), entry_name()) :: {:ok, term()} | {:error, term()}

  @doc """
  Write a PDO entry value.

  The driver encodes the value to binary using device-specific logic,
  then sends it to the Master/NIF for writing to the hardware.

  ## Parameters
  - `pid` - Driver process PID
  - `pdo_name` - PDO identifier (e.g., `:ch1`)
  - `entry_name` - Entry identifier (e.g., `:value`)
  - `value` - Value to write (will be encoded by driver)

  ## Returns
  - `:ok` on success
  - `{:error, reason}` on failure
  """
  @callback write(pid(), pdo_name(), entry_name(), value :: term()) :: :ok | {:error, term()}

  @doc """
  Subscribe to value change notifications for a PDO entry.

  The subscriber will receive `{:pdo_value_changed, pdo_name, entry_name, value}`
  messages when the entry value changes during cyclic operation.

  ## Parameters
  - `pid` - Driver process PID
  - `pdo_name` - PDO identifier (e.g., `:ch1`)
  - `entry_name` - Entry identifier (e.g., `:value`)
  - `subscriber` - PID to receive notifications

  ## Returns
  - `:ok` on success
  - `{:error, reason}` on failure
  """
  @callback subscribe(pid(), pdo_name(), entry_name(), subscriber :: pid()) ::
              :ok | {:error, term()}

  @doc """
  Unsubscribe from value change notifications.

  ## Parameters
  - `pid` - Driver process PID
  - `pdo_name` - PDO identifier (e.g., `:ch1`)
  - `entry_name` - Entry identifier (e.g., `:value`)
  - `subscriber` - PID to unsubscribe

  ## Returns
  - `:ok` on success
  - `{:error, reason}` on failure
  """
  @callback unsubscribe(pid(), pdo_name(), entry_name(), subscriber :: pid()) ::
              :ok | {:error, term()}

  # ========================================================================
  # Default Encoding/Decoding Helpers
  # ========================================================================

  @doc """
  Default encoding for standard PDO entry types.

  Used by drivers when they don't need custom encoding logic.
  """
  @spec encode_pdo_value(atom(), term()) :: {:ok, binary()} | {:error, term()}
  def encode_pdo_value(:bool, value) when is_boolean(value) do
    {:ok, <<if(value, do: 1, else: 0)>>}
  end

  def encode_pdo_value(:uint8, value) when is_integer(value) and value >= 0 and value <= 255 do
    {:ok, <<value::little-unsigned-8>>}
  end

  def encode_pdo_value(:int8, value) when is_integer(value) and value >= -128 and value <= 127 do
    {:ok, <<value::little-signed-8>>}
  end

  def encode_pdo_value(:uint16, value) when is_integer(value) and value >= 0 and value <= 65535 do
    {:ok, <<value::little-unsigned-16>>}
  end

  def encode_pdo_value(:int16, value)
      when is_integer(value) and value >= -32768 and value <= 32767 do
    {:ok, <<value::little-signed-16>>}
  end

  def encode_pdo_value(:uint32, value) when is_integer(value) and value >= 0 do
    {:ok, <<value::little-unsigned-32>>}
  end

  def encode_pdo_value(:int32, value) when is_integer(value) do
    {:ok, <<value::little-signed-32>>}
  end

  def encode_pdo_value(:uint64, value) when is_integer(value) and value >= 0 do
    {:ok, <<value::little-unsigned-64>>}
  end

  def encode_pdo_value(:int64, value) when is_integer(value) do
    {:ok, <<value::little-signed-64>>}
  end

  def encode_pdo_value(type, value) do
    {:error, {:invalid_value_for_type, value, type}}
  end

  @doc """
  Default decoding for standard PDO entry types.

  Used by drivers when they don't need custom decoding logic.
  """
  @spec decode_pdo_value(atom(), binary()) :: {:ok, term()} | {:error, term()}
  def decode_pdo_value(:bool, <<value>>) do
    {:ok, value != 0}
  end

  def decode_pdo_value(:uint8, <<value::little-unsigned-8>>) do
    {:ok, value}
  end

  def decode_pdo_value(:int8, <<value::little-signed-8>>) do
    {:ok, value}
  end

  def decode_pdo_value(:uint16, <<value::little-unsigned-16>>) do
    {:ok, value}
  end

  def decode_pdo_value(:int16, <<value::little-signed-16>>) do
    {:ok, value}
  end

  def decode_pdo_value(:uint32, <<value::little-unsigned-32>>) do
    {:ok, value}
  end

  def decode_pdo_value(:int32, <<value::little-signed-32>>) do
    {:ok, value}
  end

  def decode_pdo_value(:uint64, <<value::little-unsigned-64>>) do
    {:ok, value}
  end

  def decode_pdo_value(:int64, <<value::little-signed-64>>) do
    {:ok, value}
  end

  def decode_pdo_value(type, data) do
    {:error, {:invalid_data_for_type, byte_size(data), type}}
  end

  @doc """
  Infer type from bit length for entries without explicit type annotation.
  """
  @spec infer_type_from_bit_length(pos_integer()) :: atom()
  def infer_type_from_bit_length(1), do: :bool
  def infer_type_from_bit_length(size) when size >= 2 and size < 8, do: :uint8
  def infer_type_from_bit_length(8), do: :uint8
  def infer_type_from_bit_length(16), do: :uint16
  def infer_type_from_bit_length(32), do: :uint32
  def infer_type_from_bit_length(64), do: :uint64
end
