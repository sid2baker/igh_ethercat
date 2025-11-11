defmodule EtherCAT.Drivers.EL3202 do
  @moduledoc """
  Beckhoff EL3202 2-channel RTD (PT100/PT1000) temperature input driver with SDO configuration.
  """

  use EtherCAT.Slave.Driver
  require Logger

  @impl true
  def configure(ctx, state, config) do
    # Skip all SDO configuration if config is empty
    if map_size(config) == 0 do
      Logger.info("EL3202: Using default configuration (no SDO writes)")
      {:ok, Map.put(state, :configured, true)}
    else
      Logger.info("Configuring EL3202 RTD input terminal")

      with :ok <- configure_channel_1(ctx, config),
           :ok <- configure_channel_2(ctx, config) do
        {:ok, Map.put(state, :configured, true)}
      end
    end
  end

  @impl true
  def supports_pdo_config?(_state), do: false

  @impl true
  def list_pdos(_state) do
    [
      # Channel 1: Groups all 6 entries from TxPDO 0x1A00
      :ch1,
      # Channel 2: Groups all 6 entries from TxPDO 0x1A01
      :ch2
    ]
  end

  @impl true
  def pdo_info(_state, pdo_name) do
    case pdo_name do
      # Channel 1 - TxPDO 0x1A00 (SM3, all entries including padding)
      :ch1 ->
        {:ok,
         %{
           sync_manager: {3, 2, 0},
           pdo_index: 0x1A00,
           entries: %{
             underrange: {0x6000, 0x01, 1},
             overrange: {0x6000, 0x02, 1},
             limit1: {0x6000, 0x03, 2},
             limit2: {0x6000, 0x05, 2},
             error: {0x6000, 0x07, 1},
             txpdo_state: {0x1800, 0x07, 1},
             txpdo_toggle: {0x1800, 0x09, 1},
             value: {:int16, 0x6000, 0x11, 16}
           }
         }}

      # Channel 2 - TxPDO 0x1A01 (SM3, all entries including padding)
      :ch2 ->
        {:ok,
         %{
           sync_manager: {3, 2, 0},
           pdo_index: 0x1A01,
           entries: %{
             underrange: {0x6010, 0x01, 1},
             overrange: {0x6010, 0x02, 1},
             limit1: {0x6010, 0x03, 2},
             limit2: {0x6010, 0x05, 2},
             error: {0x6010, 0x07, 1},
             txpdo_state: {0x1801, 0x07, 1},
             txpdo_toggle: {0x1801, 0x09, 1},
             value: {:int16, 0x6010, 0x11, 16}
           }
         }}

      _ ->
        {:error, {:unknown_pdo, pdo_name}}
    end
  end

  @impl true
  def terminate(_state) do
    Logger.debug("Terminating EL3202 driver")
    :ok
  end

  # ============================================================================
  # Encode/Decode Callbacks
  # ============================================================================

  # Decode temperature value from raw int16 to degrees Celsius
  # The EL3202 provides temperature in units of 0.1°C
  @impl true
  def decode_value(_state, _pdo_name, :value, <<raw::little-signed-16>>) do
    celsius = raw / 10.0
    {:ok, celsius}
  end

  # All other entries use default encoding/decoding
  @impl true
  def decode_value(_state, _pdo_name, _entry_name, _data), do: :default

  # Encode temperature value from degrees Celsius to raw int16
  # The EL3202 expects temperature in units of 0.1°C
  @impl true
  def encode_value(_state, _pdo_name, :value, celsius) when is_number(celsius) do
    raw = trunc(celsius * 10)
    {:ok, <<raw::little-signed-16>>}
  end

  # All other entries use default encoding/decoding
  @impl true
  def encode_value(_state, _pdo_name, _entry_name, _value), do: :default

  # ============================================================================
  # Private Configuration Helpers
  # ============================================================================

  defp configure_channel_1(ctx, config) do
    with :ok <- maybe_configure_rtd_element_ch1(ctx, config),
         :ok <- maybe_configure_connection_ch1(ctx, config),
         :ok <- maybe_configure_wire_calibration_ch1(ctx, config),
         :ok <- maybe_configure_limit1_ch1(ctx, config),
         :ok <- maybe_configure_limit2_ch1(ctx, config),
         :ok <- maybe_configure_filter_ch1(ctx, config) do
      Logger.debug("Channel 1 configured successfully")
      :ok
    else
      {:error, reason} ->
        Logger.error("Failed to configure channel 1: #{inspect(reason)}")
        {:error, {:config_failed, :channel_1, reason}}
    end
  end

  defp configure_channel_2(ctx, config) do
    with :ok <- maybe_configure_rtd_element_ch2(ctx, config),
         :ok <- maybe_configure_connection_ch2(ctx, config),
         :ok <- maybe_configure_wire_calibration_ch2(ctx, config),
         :ok <- maybe_configure_limit1_ch2(ctx, config),
         :ok <- maybe_configure_limit2_ch2(ctx, config),
         :ok <- maybe_configure_filter_ch2(ctx, config) do
      Logger.debug("Channel 2 configured successfully")
      :ok
    else
      {:error, reason} ->
        Logger.error("Failed to configure channel 2: #{inspect(reason)}")
        {:error, {:config_failed, :channel_2, reason}}
    end
  end

  # Channel 1 RTD element configuration (SDO 0x8000:0x19)
  # Values: 0 = PT100, 1 = NI100, 2 = PT1000, 3 = PT500, 4 = PT200, 5 = NI1000, 6 = NI1000 TK1500, 7 = NI120, 8 = OHMS, 9 = KTY
  defp maybe_configure_rtd_element_ch1(ctx, config) do
    # Default to PT100
    rtd_element = Map.get(config, :ch1_rtd_element, 0)

    case write_sdo_value(ctx, 0x8000, 0x19, rtd_element, :uint16) do
      :ok ->
        element_name = rtd_element_name(rtd_element)
        Logger.debug("Ch1 RTD element configured: #{element_name} (#{rtd_element})")
        :ok

      error ->
        error
    end
  end

  # Channel 1 connection technology configuration (SDO 0x8000:0x1a)
  # Values: 0 = 2-wire, 1 = 3-wire, 2 = 4-wire
  defp maybe_configure_connection_ch1(ctx, config) do
    # Default to 2-wire
    connection = Map.get(config, :ch1_connection, 0)

    case write_sdo_value(ctx, 0x8000, 0x1A, connection, :uint16) do
      :ok ->
        connection_name = connection_name(connection)
        Logger.debug("Ch1 Connection configured: #{connection_name} (#{connection})")
        :ok

      error ->
        error
    end
  end

  # Channel 1 wire calibration configuration (SDO 0x8000:0x1b)
  # Value in 1/32 Ohm units (e.g., 32 = 1 Ohm wire resistance)
  defp maybe_configure_wire_calibration_ch1(ctx, config) do
    case Map.get(config, :ch1_wire_calibration) do
      nil ->
        :ok

      calibration when is_integer(calibration) ->
        case write_sdo_value(ctx, 0x8000, 0x1B, calibration, :int16) do
          :ok ->
            ohms = calibration / 32.0
            Logger.debug("Ch1 Wire calibration configured: #{ohms} Ohm (raw: #{calibration})")
            :ok

          error ->
            error
        end

      _ ->
        {:error, :invalid_ch1_wire_calibration}
    end
  end

  # Channel 1 limit 1 configuration (SDO 0x8000:0x13)
  defp maybe_configure_limit1_ch1(ctx, config) do
    case {Map.get(config, :ch1_limit1), Map.get(config, :ch1_enable_limit1, false)} do
      {nil, _} ->
        :ok

      {limit1, enable?} when is_integer(limit1) ->
        with :ok <- write_sdo_value(ctx, 0x8000, 0x13, limit1, :int16),
             :ok <- write_sdo_value(ctx, 0x8000, 0x07, enable?, :bool) do
          Logger.debug("Ch1 Limit1 configured: #{limit1} (enabled: #{enable?})")
          :ok
        end

      _ ->
        {:error, :invalid_ch1_limit1}
    end
  end

  # Channel 1 limit 2 configuration (SDO 0x8000:0x14)
  defp maybe_configure_limit2_ch1(ctx, config) do
    case {Map.get(config, :ch1_limit2), Map.get(config, :ch1_enable_limit2, false)} do
      {nil, _} ->
        :ok

      {limit2, enable?} when is_integer(limit2) ->
        with :ok <- write_sdo_value(ctx, 0x8000, 0x14, limit2, :int16),
             :ok <- write_sdo_value(ctx, 0x8000, 0x08, enable?, :bool) do
          Logger.debug("Ch1 Limit2 configured: #{limit2} (enabled: #{enable?})")
          :ok
        end

      _ ->
        {:error, :invalid_ch1_limit2}
    end
  end

  # Channel 1 filter configuration (SDO 0x8000:0x15)
  defp maybe_configure_filter_ch1(ctx, config) do
    enable_filter = Map.get(config, :ch1_enable_filter, true)
    filter_settings = Map.get(config, :ch1_filter_settings, 10)

    with :ok <- write_sdo_value(ctx, 0x8000, 0x06, enable_filter, :bool),
         :ok <- write_sdo_value(ctx, 0x8000, 0x15, filter_settings, :uint16) do
      Logger.debug("Ch1 Filter configured: #{filter_settings} (enabled: #{enable_filter})")
      :ok
    end
  end

  # Channel 2 RTD element configuration (SDO 0x8010:0x19)
  # Values: 0 = PT100, 1 = NI100, 2 = PT1000, 3 = PT500, 4 = PT200, 5 = NI1000, 6 = NI1000 TK1500, 7 = NI120, 8 = OHMS, 9 = KTY
  defp maybe_configure_rtd_element_ch2(ctx, config) do
    # Default to PT100
    rtd_element = Map.get(config, :ch2_rtd_element, 0)

    case write_sdo_value(ctx, 0x8010, 0x19, rtd_element, :uint16) do
      :ok ->
        element_name = rtd_element_name(rtd_element)
        Logger.debug("Ch2 RTD element configured: #{element_name} (#{rtd_element})")
        :ok

      error ->
        error
    end
  end

  # Channel 2 connection technology configuration (SDO 0x8010:0x1a)
  # Values: 0 = 2-wire, 1 = 3-wire, 2 = 4-wire
  defp maybe_configure_connection_ch2(ctx, config) do
    # Default to 2-wire
    connection = Map.get(config, :ch2_connection, 0)

    case write_sdo_value(ctx, 0x8010, 0x1A, connection, :uint16) do
      :ok ->
        connection_name = connection_name(connection)
        Logger.debug("Ch2 Connection configured: #{connection_name} (#{connection})")
        :ok

      error ->
        error
    end
  end

  # Channel 2 wire calibration configuration (SDO 0x8010:0x1b)
  # Value in 1/32 Ohm units (e.g., 32 = 1 Ohm wire resistance)
  defp maybe_configure_wire_calibration_ch2(ctx, config) do
    case Map.get(config, :ch2_wire_calibration) do
      nil ->
        :ok

      calibration when is_integer(calibration) ->
        case write_sdo_value(ctx, 0x8010, 0x1B, calibration, :int16) do
          :ok ->
            ohms = calibration / 32.0
            Logger.debug("Ch2 Wire calibration configured: #{ohms} Ohm (raw: #{calibration})")
            :ok

          error ->
            error
        end

      _ ->
        {:error, :invalid_ch2_wire_calibration}
    end
  end

  # Channel 2 limit 1 configuration (SDO 0x8010:0x13)
  defp maybe_configure_limit1_ch2(ctx, config) do
    case {Map.get(config, :ch2_limit1), Map.get(config, :ch2_enable_limit1, false)} do
      {nil, _} ->
        :ok

      {limit1, enable?} when is_integer(limit1) ->
        with :ok <- write_sdo_value(ctx, 0x8010, 0x13, limit1, :int16),
             :ok <- write_sdo_value(ctx, 0x8010, 0x07, enable?, :bool) do
          Logger.debug("Ch2 Limit1 configured: #{limit1} (enabled: #{enable?})")
          :ok
        end

      _ ->
        {:error, :invalid_ch2_limit1}
    end
  end

  # Channel 2 limit 2 configuration (SDO 0x8010:0x14)
  defp maybe_configure_limit2_ch2(ctx, config) do
    case {Map.get(config, :ch2_limit2), Map.get(config, :ch2_enable_limit2, false)} do
      {nil, _} ->
        :ok

      {limit2, enable?} when is_integer(limit2) ->
        with :ok <- write_sdo_value(ctx, 0x8010, 0x14, limit2, :int16),
             :ok <- write_sdo_value(ctx, 0x8010, 0x08, enable?, :bool) do
          Logger.debug("Ch2 Limit2 configured: #{limit2} (enabled: #{enable?})")
          :ok
        end

      _ ->
        {:error, :invalid_ch2_limit2}
    end
  end

  # Channel 2 filter configuration (SDO 0x8010:0x15)
  defp maybe_configure_filter_ch2(ctx, config) do
    enable_filter = Map.get(config, :ch2_enable_filter, true)
    filter_settings = Map.get(config, :ch2_filter_settings, 10)

    with :ok <- write_sdo_value(ctx, 0x8010, 0x06, enable_filter, :bool),
         :ok <- write_sdo_value(ctx, 0x8010, 0x15, filter_settings, :uint16) do
      Logger.debug("Ch2 Filter configured: #{filter_settings} (enabled: #{enable_filter})")
      :ok
    end
  end

  # Helper functions for mapping values to names
  defp rtd_element_name(0), do: "PT100"
  defp rtd_element_name(1), do: "NI100"
  defp rtd_element_name(2), do: "PT1000"
  defp rtd_element_name(3), do: "PT500"
  defp rtd_element_name(4), do: "PT200"
  defp rtd_element_name(5), do: "NI1000"
  defp rtd_element_name(6), do: "NI1000 TK1500"
  defp rtd_element_name(7), do: "NI120"
  defp rtd_element_name(8), do: "OHMS"
  defp rtd_element_name(9), do: "KTY"
  defp rtd_element_name(n), do: "Unknown(#{n})"

  defp connection_name(0), do: "2-wire"
  defp connection_name(1), do: "3-wire"
  defp connection_name(2), do: "4-wire"
  defp connection_name(n), do: "Unknown(#{n})"
end
