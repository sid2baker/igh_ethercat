defmodule EtherCAT.Slave.Driver do
  @moduledoc """
  Behaviour for device-specific slave drivers defining PDO mappings and configuration.
  """

  @typedoc "Driver-specific state maintained across callbacks"
  @type state :: term()

  @typedoc "PDO identifier (typically an atom like :input1 or :output1)"
  @type pdo_name :: atom() | String.t()

  @typedoc """
  Sync manager configuration tuple: {sync_index, direction, watchdog_mode}
  """
  @type sync_manager_config :: {
          sync_index :: non_neg_integer(),
          direction :: :invalid | :output | :input | :count,
          watchdog_mode :: :default | :enabled | :disabled
        }

  @typedoc """
  PDO entry configuration tuple: {entry_index, entry_subindex, bit_length}

  - entry_index: Object dictionary index (e.g., 0x6000)
  - entry_subindex: Object dictionary subindex (e.g., 0x01)
  - bit_length: Size in bits (1, 8, 16, 32, etc.)
  """
  @type pdo_entry_config :: {
          entry_index :: non_neg_integer(),
          entry_subindex :: non_neg_integer(),
          bit_length :: pos_integer()
        }

  @typedoc """
  Complete PDO information including sync manager, PDO index, and all entries.

  This represents a single PDO (Process Data Object) containing all its mapped entries.
  While individual entries can be selectively registered to domains, grouping them
  provides a cleaner API and matches the typical usage pattern.

  The entries map provides semantic names for each entry in the PDO.
  """
  @type pdo_info :: %{
          sync_manager: sync_manager_config(),
          pdo_index: non_neg_integer(),
          entries: %{(entry_name :: atom()) => pdo_entry_config()}
        }

  @typedoc """
  Configuration context passed to drivers during configuration phase.

  Contains all information about the slave being configured and provides
  access to SDO read/write operations.
  """
  @type context :: %{
          master: pid(),
          slave_pid: pid(),
          position: non_neg_integer(),
          slave_config: reference(),
          vendor_id: non_neg_integer(),
          product_code: non_neg_integer(),
          revision: non_neg_integer(),
          serial: non_neg_integer(),
          sync_count: non_neg_integer()
        }

  @doc """
  Configure the driver with device-specific settings.

  Called when a slave is being configured. The driver receives a context
  struct containing slave information and helpers for SDO operations.

  ## Parameters
  - `ctx` - Configuration context with slave info and SDO helpers
  - `state` - Current driver state
  - `config` - Configuration map passed from user code

  ## Returns
  - `{:ok, new_state}` on success
  - `{:error, reason}` on failure

  ## Example

      def configure(ctx, state, config) do
        # Configure SDO parameters using helper functions
        limit = Map.get(config, :temperature_limit, 1000)
        :ok = write_sdo_value(ctx, 0x8000, 0x13, limit, :int16)

        {:ok, Map.put(state, :configured, true)}
      end
  """
  @callback configure(
              ctx :: context(),
              state :: state(),
              config :: map()
            ) ::
              {:ok, state()} | {:error, term()}

  @doc """
  List all available PDO names for this driver.

  Returns a list of PDO identifiers that can be registered for cyclic data exchange.
  """
  @callback list_pdos(state :: state()) :: [pdo_name()]

  @doc """
  Get detailed information about a specific PDO.

  Returns complete PDO configuration including sync manager settings, PDO index,
  and all entries mapped within this PDO. The driver groups related entries
  together for convenience (e.g., all channel 1 data in `:ch1`).

  ## Example

      pdo_info(state, :ch1)
      #=> {:ok, %{
      #     sync_manager: {3, 2, 0},
      #     pdo_index: 0x1A00,
      #     entries: %{
      #       underrange: {0x6000, 0x01, 1},
      #       value: {0x6000, 0x11, 16}
      #     }
      #   }}
  """
  @callback pdo_info(state :: state(), pdo :: pdo_name()) ::
              {:ok, pdo_info()} | {:error, term()}

  @doc """
  Encode a user value into binary format for writing to the device.

  Called when writing a PDO entry value. The driver can perform custom transformations
  like scaling, unit conversion, or calibration. Return `:default` to use standard
  type-based encoding.

  ## Parameters
  - `state` - Current driver state (may contain calibration data, etc.)
  - `pdo_name` - The PDO containing this entry
  - `entry_name` - The specific entry being written
  - `value` - User-provided value (integer, float, boolean, etc.)

  ## Returns
  - `{:ok, binary}` - Encoded binary data
  - `:default` - Use default encoding based on entry type
  - `{:error, reason}` - Encoding failed

  ## Example

      # Custom scaling for temperature sensor
      def encode_value(_state, :ch1, :value, celsius) do
        raw = trunc(celsius * 100)
        {:ok, <<raw::little-signed-16>>}
      end

      # Use default encoding for other entries
      def encode_value(_state, _pdo, _entry, _value), do: :default
  """
  @callback encode_value(
              state :: state(),
              pdo_name :: pdo_name(),
              entry_name :: atom(),
              value :: term()
            ) :: {:ok, binary()} | :default | {:error, term()}

  @doc """
  Decode binary data from the device into a user value.

  Called when reading a PDO entry value. The driver can perform custom transformations
  like scaling, unit conversion, or calibration. Return `:default` to use standard
  type-based decoding.

  ## Parameters
  - `state` - Current driver state (may contain calibration data, etc.)
  - `pdo_name` - The PDO containing this entry
  - `entry_name` - The specific entry being read
  - `data` - Raw binary data from the device

  ## Returns
  - `{:ok, value}` - Decoded user value
  - `:default` - Use default decoding based on entry type
  - `{:error, reason}` - Decoding failed

  ## Example

      # Custom scaling for temperature sensor
      def decode_value(_state, :ch1, :value, <<raw::little-signed-16>>) do
        {:ok, raw / 100.0}
      end

      # Use default decoding for other entries
      def decode_value(_state, _pdo, _entry, _data), do: :default
  """
  @callback decode_value(
              state :: state(),
              pdo_name :: pdo_name(),
              entry_name :: atom(),
              data :: binary()
            ) :: {:ok, term()} | :default | {:error, term()}

  @doc """
  Indicates whether this device supports dynamic PDO configuration.

  Returns true if the device supports changing PDO mappings (Enable PDO Configuration),
  or false if it has fixed PDO mappings. Devices with fixed mappings (like EL3202) cannot
  have their PDO assignments or mappings modified.

  Default: true (supports dynamic PDO configuration)
  """
  @callback supports_pdo_config?(state :: state()) :: boolean()

  @optional_callbacks supports_pdo_config?: 1

  # ========================================================================
  # Public Helper Functions for Default Encoding/Decoding
  # ========================================================================

  @doc """
  Default encoding for standard PDO entry types.

  Used when driver returns `:default` from encode_value callback.
  Handles common types based on bit length and signedness.
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

  Used when driver returns `:default` from decode_value callback.
  Handles common types based on bit length and signedness.
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

  @doc """
  Clean up driver resources when the slave process terminates.

  This callback is called during slave process termination and should
  release any resources held by the driver.
  """
  @callback terminate(state :: state()) :: :ok

  defmacro __using__(_opts) do
    quote do
      @behaviour EtherCAT.Slave.Driver

      require Logger

      # ========================================================================
      # Default Implementations
      # ========================================================================

      # Default: Most devices support dynamic PDO configuration
      # Override this in your driver if the device has fixed PDO mappings
      def supports_pdo_config?(_state), do: true

      # Default: Use standard type-based encoding/decoding
      # Override these in your driver for custom transformations
      def encode_value(_state, _pdo_name, _entry_name, _value), do: :default
      def decode_value(_state, _pdo_name, _entry_name, _data), do: :default

      defoverridable supports_pdo_config?: 1, encode_value: 4, decode_value: 4

      # ========================================================================
      # SDO Configuration Helpers
      # ========================================================================

      # Write an SDO to the slave during configuration.
      #
      # Parameters:
      # - ctx: Configuration context
      # - index: SDO index (0x0000-0xFFFF)
      # - subindex: SDO subindex (0x00-0xFF)
      # - data: Binary data to write
      #
      # Returns :ok on success, {:error, reason} on failure
      #
      # Example: write_sdo(ctx, 0x8000, 0x13, <<180::little-signed-16>>)
      @spec write_sdo(
              EtherCAT.Slave.Driver.context(),
              0x0000..0xFFFF,
              0x00..0xFF,
              binary()
            ) :: :ok | {:error, term()}
      defp write_sdo(ctx, index, subindex, data) do
        Logger.debug(
          "Slave #{ctx.position}: Writing SDO 0x#{Integer.to_string(index, 16)}:#{subindex} " <>
            "(#{byte_size(data)} bytes)"
        )

        result =
          EtherCAT.Master.slave_operation(
            ctx.master,
            ctx.position,
            :config_sdo,
            [ctx.slave_config, index, subindex, data]
          )

        case result do
          :ok ->
            Logger.debug("Slave #{ctx.position}: SDO write successful")
            :ok

          {:error, reason} = error ->
            Logger.error("Slave #{ctx.position}: SDO write failed - #{inspect(reason)}")
            error
        end
      end

      # Write an SDO with automatic encoding based on value type.
      #
      # Supported types: :bool, :uint8, :int8, :uint16, :int16, :uint32, :int32
      #
      # Examples:
      #   write_sdo_value(ctx, 0x8000, 0x13, 180, :int16)
      #   write_sdo_value(ctx, 0x8000, 0x07, true, :bool)
      @spec write_sdo_value(
              EtherCAT.Slave.Driver.context(),
              0x0000..0xFFFF,
              0x00..0xFF,
              term(),
              atom()
            ) :: :ok | {:error, term()}
      defp write_sdo_value(ctx, index, subindex, value, type) do
        case encode_sdo_value(value, type) do
          {:ok, data} -> write_sdo(ctx, index, subindex, data)
          {:error, _} = error -> error
        end
      end

      # Write multiple SDOs atomically.
      #
      # Stops at the first error and returns which SDO failed.
      #
      # Example:
      #   write_sdo_batch(ctx, [
      #     {0x8000, 0x13, <<180::little-signed-16>>},
      #     {0x8000, 0x07, <<1::8>>}
      #   ])
      @spec write_sdo_batch(
              EtherCAT.Slave.Driver.context(),
              [{non_neg_integer(), non_neg_integer(), binary()}]
            ) :: :ok | {:error, term()}
      defp write_sdo_batch(ctx, sdo_list) do
        Enum.reduce_while(sdo_list, :ok, fn {index, subindex, data}, _acc ->
          case write_sdo(ctx, index, subindex, data) do
            :ok ->
              {:cont, :ok}

            {:error, reason} ->
              {:halt, {:error, {:sdo_failed, index, subindex, reason}}}
          end
        end)
      end

      # ========================================================================
      # Private Encoding Helpers
      # ========================================================================

      defp encode_sdo_value(value, :bool) when is_boolean(value) do
        {:ok, <<if(value, do: 1, else: 0)::8>>}
      end

      defp encode_sdo_value(value, :uint8)
           when is_integer(value) and value >= 0 and value <= 255 do
        {:ok, <<value::8>>}
      end

      defp encode_sdo_value(value, :int8)
           when is_integer(value) and value >= -128 and value <= 127 do
        {:ok, <<value::signed-8>>}
      end

      defp encode_sdo_value(value, :uint16)
           when is_integer(value) and value >= 0 and value <= 65535 do
        {:ok, <<value::little-unsigned-16>>}
      end

      defp encode_sdo_value(value, :int16)
           when is_integer(value) and value >= -32768 and value <= 32767 do
        {:ok, <<value::little-signed-16>>}
      end

      defp encode_sdo_value(value, :uint32) when is_integer(value) and value >= 0 do
        {:ok, <<value::little-unsigned-32>>}
      end

      defp encode_sdo_value(value, :int32) when is_integer(value) do
        {:ok, <<value::little-signed-32>>}
      end

      defp encode_sdo_value(value, type) do
        {:error, {:invalid_value_for_type, value, type}}
      end

      # ========================================================================
      # PDO Discovery Helpers
      # ========================================================================

      # Discover all PDOs from slave's EEPROM configuration.
      #
      # Reads sync managers, PDOs, and PDO entries to build a complete
      # map of available PDOs. Each PDO contains all its entries.
      # Useful for generic drivers or drivers that need to validate expected PDO configuration.
      #
      # Returns map of PDO identifiers (using pdo_index as hex string) to configurations:
      #   %{"0x1a00" => %{
      #     sync_manager: {3, 2, 0},
      #     pdo_index: 0x1A00,
      #     entries: %{
      #       "0x6000:1" => {0x6000, 0x01, 1},
      #       "0x6000:11" => {0x6000, 0x11, 16}
      #     }
      #   }}
      @spec discover_pdos_from_eeprom(EtherCAT.Slave.Driver.context(), non_neg_integer()) ::
              map()
      defp discover_pdos_from_eeprom(ctx, sync_count) do
        for sync_index <- 0..(sync_count - 1) do
          sync_manager = get_sync_manager(ctx, sync_index)

          for pdo_pos <- 0..(sync_manager.n_pdos - 1) do
            pdo = get_pdo(ctx, sync_index, pdo_pos)

            # Collect all entries for this PDO
            entries =
              for entry_pos <- 0..(pdo.n_entries - 1) do
                entry = get_pdo_entry(ctx, sync_index, pdo_pos, entry_pos)

                entry_name =
                  "0x#{Integer.to_string(entry.index, 16)}:#{Integer.to_string(entry.subindex, 16)}"

                {entry_name, {entry.index, entry.subindex, entry.bit_length}}
              end
              |> Map.new()

            # Use PDO index as the identifier
            pdo_name = "0x#{Integer.to_string(pdo.index, 16)}"

            direction = normalize_direction(sync_manager.dir)
            watchdog_mode = normalize_watchdog_mode(sync_manager.watchdog_mode)

            {pdo_name,
             %{
               sync_manager: {sync_manager.index, direction, watchdog_mode},
               pdo_index: pdo.index,
               entries: entries
             }}
          end
        end
        |> List.flatten()
        |> Map.new()
      end

      defp normalize_direction(0), do: :invalid
      defp normalize_direction(1), do: :output
      defp normalize_direction(2), do: :input
      defp normalize_direction(3), do: :count

      defp normalize_watchdog_mode(0), do: :default
      defp normalize_watchdog_mode(1), do: :enabled
      defp normalize_watchdog_mode(2), do: :disabled

      # Get sync manager information from slave.
      defp get_sync_manager(ctx, sync_index) do
        EtherCAT.Master.slave_operation(
          ctx.master,
          ctx.position,
          :get_sync_manager,
          [sync_index]
        )
      end

      # Get PDO information from slave.
      defp get_pdo(ctx, sync_index, pdo_pos) do
        EtherCAT.Master.slave_operation(
          ctx.master,
          ctx.position,
          :get_pdo,
          [sync_index, pdo_pos]
        )
      end

      # Get PDO entry information from slave.
      defp get_pdo_entry(ctx, sync_index, pdo_pos, entry_pos) do
        EtherCAT.Master.slave_operation(
          ctx.master,
          ctx.position,
          :get_pdo_entry,
          [sync_index, pdo_pos, entry_pos]
        )
      end
    end
  end
end
