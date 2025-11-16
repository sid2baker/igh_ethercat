defmodule EtherCAT.Slave.Driver do
  @moduledoc """
  Behaviour for EtherCAT slave drivers.

  This module defines the contract that all EtherCAT slave drivers must implement
  and provides shared helper functions for common operations.

  ## Default Driver

  When `driver: nil` is specified in SlaveConfig, `EtherCAT.Slave.GenericDriver` is used
  with auto-discovery and type-based encoding.

  ## Custom Encoding (Strategy Pattern)

  For simple customization (custom encoding/decoding only), use GenericDriver with a callback module:

      defmodule MyTempEncoder do
        @behaviour EtherCAT.Slave.Driver

        alias EtherCAT.Slave.Driver

        def encode_pdo_value(:temp, :value, celsius, _state) do
          {:ok, <<round(celsius * 10)::little-signed-16>>}
        end

        def encode_pdo_value(pdo, entry, value, state) do
          Driver.default_encode(pdo, entry, value, state)
        end

        def decode_pdo_value(:temp, :value, <<raw::little-signed-16>>, _state) do
          {:ok, raw / 10.0}
        end

        def decode_pdo_value(pdo, entry, binary, state) do
          Driver.default_decode(pdo, entry, binary, state)
        end
      end

      # In SlaveConfig:
      %SlaveConfig{
        position: 1,
        driver: {EtherCAT.Slave.GenericDriver, callback_module: MyTempEncoder},
        ...
      }

  ## Complex Drivers (Full GenServer Control)

  For complex drivers that need custom state machines (like CIA 402), implement a full GenServer:

      defmodule MyCIA402Driver do
        use GenServer
        @behaviour EtherCAT.Slave.Driver

        alias EtherCAT.Slave.Driver

        defstruct [
          :master, :position, :name, :pdo_map,  # Keep for default encoding
          :state_machine, :target_position      # Custom fields
        ]

        def start_link(opts) do
          GenServer.start_link(__MODULE__, opts)
        end

        def init(opts) do
          # Use helper to build base state
          {:ok, base_state} = Driver.build_default_state(__MODULE__, opts)

          state = %__MODULE__{
            master: base_state.master,
            position: base_state.position,
            name: base_state.name,
            pdo_map: base_state.pdo_map,
            state_machine: :not_ready_to_switch_on,
            target_position: 0
          }

          {:ok, state}
        end

        def handle_call({:move_to, position}, _from, state) do
          # Custom motion control commands
          {:reply, :ok, %{state | target_position: position}}
        end

        def handle_call({:write, pdo, entry, value}, _from, state) do
          # Can use standard write logic with custom encoding
          with {:ok, binary} <- encode_pdo_value(pdo, entry, value, state),
               :ok <- EtherCAT.Master.write_pdo_entry(state.master, :default_domain,
                                                      "\#{state.name}:\#{pdo}:\#{entry}", binary) do
            {:reply, :ok, state}
          else
            error -> {:reply, error, state}
          end
        end

        def encode_pdo_value(:control_word, :value, value, state) do
          # CIA 402 specific control word based on state machine
          control_word = calculate_control_word(state.state_machine, value)
          {:ok, <<control_word::little-unsigned-16>>}
        end

        def encode_pdo_value(pdo, entry, value, state) do
          # Fallback to default for other PDOs
          Driver.default_encode(pdo, entry, value, state)
        end

        def decode_pdo_value(pdo, entry, binary, state) do
          Driver.default_decode(pdo, entry, binary, state)
        end

        defp calculate_control_word(state_machine, value) do
          # CIA 402 state machine logic
          # ...
        end
      end

      # In SlaveConfig:
      %SlaveConfig{
        position: 1,
        driver: MyCIA402Driver,
        ...
      }
  """

  require Logger

  # ========================================================================
  # Behaviour Definition
  # ========================================================================

  @typedoc "PDO name (typically an atom like :ch1 or :inputs)"
  @type pdo_name :: atom() | String.t()

  @typedoc "Entry name within a PDO (typically an atom like :value or :error)"
  @type entry_name :: atom() | String.t()

  @doc """
  Encode a PDO value to binary.

  ## Parameters
  - `pdo_name` - PDO identifier (e.g., `:ch1`)
  - `entry_name` - Entry identifier (e.g., `:value`)
  - `value` - Value to encode
  - `state` - Driver state (for type lookup)

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
  - `state` - Driver state (for type lookup)

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
  Build default state structure for a driver module.

  This helper is used by GenericDriver and can be used by custom drivers
  to build their initial state with auto-discovered PDO mappings.

  Only sets common fields that all drivers need. Custom drivers can extend
  the returned state with their own fields.
  """
  def build_default_state(module, opts) do
    position = Keyword.fetch!(opts, :position)
    name = Keyword.fetch!(opts, :name)
    eeprom_data = Keyword.fetch!(opts, :eeprom_data)

    # Auto-discover PDO mappings from EEPROM
    pdo_map = process_eeprom_data(eeprom_data, position)

    # Build field list - only common fields that all drivers have
    fields = [
      master: Keyword.fetch!(opts, :master),
      position: position,
      name: name,
      pdo_map: pdo_map
    ]

    # Add optional callback_module if the struct has that field (GenericDriver only)
    fields =
      if :callback_module in Map.keys(struct(module)) do
        Keyword.put(fields, :callback_module, Keyword.get(opts, :callback_module))
      else
        fields
      end

    state = struct!(module, fields)

    Logger.info("Driver started for slave #{position} (#{name}) with #{map_size(pdo_map)} PDOs")

    {:ok, state}
  end

  @doc """
  Default encode implementation using type-based encoding.

  This function infers the type from bit length and encodes accordingly.
  Can be called by custom drivers as a fallback for PDOs they don't handle specially.
  """
  def default_encode(pdo_name, entry_name, value, %{pdo_map: pdo_map}) do
    type = get_entry_type(pdo_map, pdo_name, entry_name)
    encode_by_type(type, value)
  end

  @doc """
  Default decode implementation using type-based decoding.

  This function infers the type from bit length and decodes accordingly.
  Can be called by custom drivers as a fallback for PDOs they don't handle specially.
  """
  def default_decode(pdo_name, entry_name, binary, %{pdo_map: pdo_map}) do
    type = get_entry_type(pdo_map, pdo_name, entry_name)
    decode_by_type(type, binary)
  end

  @doc false
  def process_eeprom_data(eeprom_data, _position) do
    eeprom_data
    |> Enum.flat_map(fn {_sync_index, sync_data} ->
      sync_manager = sync_data.sync_manager
      pdos = sync_data.pdos || %{}

      Enum.map(pdos, fn {_pdo_pos, pdo_data} ->
        pdo = pdo_data.pdo
        entries = pdo_data.entries || %{}

        pdo_name = "0x#{Integer.to_string(pdo.index, 16) |> String.downcase()}"
        direction = normalize_direction(sync_manager.dir)
        watchdog_mode = normalize_watchdog_mode(sync_manager.watchdog_mode)

        entry_map =
          Enum.map(entries, fn {_entry_pos, entry} ->
            index_hex = Integer.to_string(entry.index, 16) |> String.downcase()
            entry_name = "0x#{index_hex}:#{entry.subindex}"
            {entry_name, {entry.index, entry.subindex, entry.bit_length}}
          end)
          |> Map.new()

        {pdo_name,
         %{
           sync_manager: {sync_manager.index, direction, watchdog_mode},
           pdo_index: pdo.index,
           entries: entry_map
         }}
      end)
    end)
    |> Map.new()
  end

  @doc false
  def convert_pdo_config(pdo_map) do
    Enum.map(pdo_map, fn {pdo_name, pdo_info} ->
      %{
        name: safe_to_atom(pdo_name),
        sync_manager: pdo_info.sync_manager,
        pdo_index: pdo_info.pdo_index,
        entries:
          Map.new(pdo_info.entries, fn {entry_name, {index, subindex, bit_length}} ->
            type = infer_type_from_bit_length(bit_length)
            {safe_to_atom(entry_name), {type, index, subindex, bit_length}}
          end),
        domain: :default_domain,
        # Fixed EEPROM PDO mappings - do not allow dynamic reconfiguration
        supports_pdo_config?: false
      }
    end)
  end

  @doc false
  def get_entry_type(pdo_map, pdo_name, entry_name) do
    pdo_name_str = to_string(pdo_name)
    entry_name_str = to_string(entry_name)

    with {:ok, pdo_info} <- Map.fetch(pdo_map, pdo_name_str),
         {:ok, {_index, _subindex, bit_length}} <- Map.fetch(pdo_info.entries, entry_name_str) do
      infer_type_from_bit_length(bit_length)
    else
      _ -> :uint16
    end
  end

  @doc """
  Infer type from bit length for entries without explicit type annotation.
  """
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

  @doc false
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

  @doc false
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

  # ========================================================================
  # Private Helpers
  # ========================================================================

  # SECURITY: Safely convert string to atom, only if it already exists
  defp safe_to_atom(string) when is_binary(string) do
    try do
      String.to_existing_atom(string)
    rescue
      ArgumentError ->
        # Atom doesn't exist - use string instead to prevent atom creation
        string
    end
  end

  defp safe_to_atom(value), do: value

  defp normalize_direction(0), do: :invalid
  defp normalize_direction(1), do: :output
  defp normalize_direction(2), do: :input
  defp normalize_direction(3), do: :count

  defp normalize_watchdog_mode(0), do: :default
  defp normalize_watchdog_mode(1), do: :enabled
  defp normalize_watchdog_mode(2), do: :disabled
end
