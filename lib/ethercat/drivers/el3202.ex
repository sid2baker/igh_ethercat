defmodule EtherCAT.Drivers.EL3202 do
  @moduledoc """
  Beckhoff EL3202 2-channel RTD (PT100/PT1000) temperature input driver with SDO configuration.
  """

  use EtherCAT.Slave.Driver
  require Logger

  @impl true
  def configure(ctx, state, config) do
    Logger.info("Configuring EL3202 RTD input terminal")

    with :ok <- configure_channel_1(ctx, config),
         :ok <- configure_channel_2(ctx, config) do
      {:ok, Map.put(state, :configured, true)}
    end
  end

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
      # Channel 1 - TxPDO 0x1A00 (SM3, all 6 entries)
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
             value: {0x6000, 0x11, 16}
           }
         }}

      # Channel 2 - TxPDO 0x1A01 (SM3, all 6 entries)
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
             value: {0x6010, 0x11, 16}
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
  # Private Configuration Helpers
  # ============================================================================

  defp configure_channel_1(ctx, config) do
    with :ok <- maybe_configure_limit1_ch1(ctx, config),
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
    with :ok <- maybe_configure_limit1_ch2(ctx, config),
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
end
