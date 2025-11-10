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

  - sync_index: 0-15
  - direction: 1 (output/write) or 2 (input/read)
  - watchdog_mode: 0 (default), 1 (enabled), 2 (disabled)
  """
  @type sync_manager_config :: {
          sync_index :: non_neg_integer(),
          direction :: 1 | 2,
          watchdog_mode :: 0 | 1 | 2
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
  Complete PDO information including sync manager, PDO index, and entry details
  """
  @type pdo_info :: %{
          sync_manager: sync_manager_config(),
          pdo_index: non_neg_integer(),
          entry: pdo_entry_config()
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

  Returns PDO configuration including sync manager settings, PDO index,
  and entry details needed for registration.
  """
  @callback pdo_info(state :: state(), pdo :: pdo_name()) ::
              {:ok, pdo_info()} | {:error, term()}

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
      # map of available PDOs. Useful for generic drivers or drivers that
      # need to validate expected PDO configuration.
      #
      # Returns map of PDO names to configurations:
      #   %{"pdo_6000:1" => %{sync_manager: {...}, pdo_index: ..., entry: {...}}}
      @spec discover_pdos_from_eeprom(EtherCAT.Slave.Driver.context(), non_neg_integer()) ::
              map()
      defp discover_pdos_from_eeprom(ctx, sync_count) do
        for sync_index <- 0..(sync_count - 1) do
          sync_manager = get_sync_manager(ctx, sync_index)

          for pdo_pos <- 0..(sync_manager.n_pdos - 1) do
            pdo = get_pdo(ctx, sync_index, pdo_pos)

            for entry_pos <- 0..(pdo.n_entries - 1) do
              entry = get_pdo_entry(ctx, sync_index, pdo_pos, entry_pos)

              pdo_name =
                "pdo_#{Integer.to_string(entry.index, 16)}:#{Integer.to_string(entry.subindex, 16)}"

              {pdo_name,
               %{
                 sync_manager: {sync_manager.index, sync_manager.dir, sync_manager.watchdog_mode},
                 pdo_index: pdo.index,
                 entry: {entry.index, entry.subindex, entry.bit_length}
               }}
            end
          end
        end
        |> List.flatten()
        |> Map.new()
      end

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
