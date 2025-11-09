defmodule EtherCAT.Drivers.EL3202 do
  @moduledoc """
  Driver for Beckhoff EL3202 2-channel RTD (PT100/PT1000) temperature input terminal.

  ## Hardware Overview

  The EL3202 is a 2-channel resistance thermometer (RTD) input terminal supporting:
  - PT100 and PT1000 temperature sensors
  - 2-wire, 3-wire, and 4-wire connection
  - Configurable measurement ranges and limits
  - Built-in filtering and calibration

  ## Configuration Options

  The driver accepts the following configuration options:

  ### Channel 1 Configuration
  - `:ch1_limit1` - Lower temperature limit for channel 1 (int16, in 0.1°C)
  - `:ch1_limit2` - Upper temperature limit for channel 1 (int16, in 0.1°C)
  - `:ch1_enable_limit1` - Enable limit 1 monitoring (boolean, default: false)
  - `:ch1_enable_limit2` - Enable limit 2 monitoring (boolean, default: false)
  - `:ch1_enable_filter` - Enable input filter (boolean, default: true)
  - `:ch1_filter_settings` - Filter configuration (uint16, default: 10)

  ### Channel 2 Configuration
  - `:ch2_limit1` - Lower temperature limit for channel 2 (int16, in 0.1°C)
  - `:ch2_limit2` - Upper temperature limit for channel 2 (int16, in 0.1°C)
  - `:ch2_enable_limit1` - Enable limit 1 monitoring (boolean, default: false)
  - `:ch2_enable_limit2` - Enable limit 2 monitoring (boolean, default: false)
  - `:ch2_enable_filter` - Enable input filter (boolean, default: true)
  - `:ch2_filter_settings` - Filter configuration (uint16, default: 10)

  ## Available PDOs

  The driver exposes the following PDO entries per channel:

  ### Channel 1
  - `:ch1_underrange` - Underrange flag
  - `:ch1_overrange` - Overrange flag
  - `:ch1_limit1` - Limit 1 status
  - `:ch1_limit2` - Limit 2 status
  - `:ch1_error` - Error flag
  - `:ch1_value` - Temperature value (int16, 0.1°C resolution)

  ### Channel 2
  - `:ch2_underrange` - Underrange flag
  - `:ch2_overrange` - Overrange flag
  - `:ch2_limit1` - Limit 1 status
  - `:ch2_limit2` - Limit 2 status
  - `:ch2_error` - Error flag
  - `:ch2_value` - Temperature value (int16, 0.1°C resolution)

  ## Example

      config = %{
        ch1_limit1: -500,  # -50.0°C
        ch1_limit2: 1000,  # 100.0°C
        ch1_enable_limit1: true,
        ch1_enable_limit2: true,
        ch1_enable_filter: true,
        ch2_limit1: 0,
        ch2_limit2: 500,   # 50.0°C
        ch2_enable_filter: true
      }

      {:ok, driver} = EL3202.configure(initial_state, config)
  """

  use EtherCAT.Slave.Driver
  require Logger

  @impl true
  def configure(config_sdo, state, config) do
    Logger.info("Configuring EL3202 RTD input terminal")

    with :ok <- configure_channel_1(config_sdo, config),
         :ok <- configure_channel_2(config_sdo, config) do
      {:ok, Map.put(state, :configured, true)}
    end
  end

  @impl true
  def list_pdos(_state) do
    [
      # Channel 1 PDO entries
      :ch1_underrange,
      :ch1_overrange,
      :ch1_limit1,
      :ch1_limit2,
      :ch1_error,
      :ch1_value,
      # Channel 2 PDO entries
      :ch2_underrange,
      :ch2_overrange,
      :ch2_limit1,
      :ch2_limit2,
      :ch2_error,
      :ch2_value
    ]
  end

  @impl true
  def pdo_info(_state, pdo_name) do
    case pdo_name do
      # Channel 1 entries (all in TxPDO 0x1A00, SM3)
      :ch1_underrange ->
        {:ok,
         %{
           sync_manager: {3, 2, 0},
           pdo_index: 0x1A00,
           entry: {0x6000, 0x01, 1}
         }}

      :ch1_overrange ->
        {:ok,
         %{
           sync_manager: {3, 2, 0},
           pdo_index: 0x1A00,
           entry: {0x6000, 0x02, 1}
         }}

      :ch1_limit1 ->
        {:ok,
         %{
           sync_manager: {3, 2, 0},
           pdo_index: 0x1A00,
           entry: {0x6000, 0x03, 2}
         }}

      :ch1_limit2 ->
        {:ok,
         %{
           sync_manager: {3, 2, 0},
           pdo_index: 0x1A00,
           entry: {0x6000, 0x05, 2}
         }}

      :ch1_error ->
        {:ok,
         %{
           sync_manager: {3, 2, 0},
           pdo_index: 0x1A00,
           entry: {0x6000, 0x07, 1}
         }}

      :ch1_value ->
        {:ok,
         %{
           sync_manager: {3, 2, 0},
           pdo_index: 0x1A00,
           entry: {0x6000, 0x11, 16}
         }}

      # Channel 2 entries (all in TxPDO 0x1A01, SM3)
      :ch2_underrange ->
        {:ok,
         %{
           sync_manager: {3, 2, 0},
           pdo_index: 0x1A01,
           entry: {0x6010, 0x01, 1}
         }}

      :ch2_overrange ->
        {:ok,
         %{
           sync_manager: {3, 2, 0},
           pdo_index: 0x1A01,
           entry: {0x6010, 0x02, 1}
         }}

      :ch2_limit1 ->
        {:ok,
         %{
           sync_manager: {3, 2, 0},
           pdo_index: 0x1A01,
           entry: {0x6010, 0x03, 2}
         }}

      :ch2_limit2 ->
        {:ok,
         %{
           sync_manager: {3, 2, 0},
           pdo_index: 0x1A01,
           entry: {0x6010, 0x05, 2}
         }}

      :ch2_error ->
        {:ok,
         %{
           sync_manager: {3, 2, 0},
           pdo_index: 0x1A01,
           entry: {0x6010, 0x07, 1}
         }}

      :ch2_value ->
        {:ok,
         %{
           sync_manager: {3, 2, 0},
           pdo_index: 0x1A01,
           entry: {0x6010, 0x11, 16}
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

  defp configure_channel_1(config_sdo, config) do
    with :ok <- maybe_configure_limit1_ch1(config_sdo, config),
         :ok <- maybe_configure_limit2_ch1(config_sdo, config),
         :ok <- maybe_configure_filter_ch1(config_sdo, config) do
      Logger.debug("Channel 1 configured successfully")
      :ok
    else
      {:error, reason} ->
        Logger.error("Failed to configure channel 1: #{inspect(reason)}")
        {:error, {:config_failed, :channel_1, reason}}
    end
  end

  defp configure_channel_2(config_sdo, config) do
    with :ok <- maybe_configure_limit1_ch2(config_sdo, config),
         :ok <- maybe_configure_limit2_ch2(config_sdo, config),
         :ok <- maybe_configure_filter_ch2(config_sdo, config) do
      Logger.debug("Channel 2 configured successfully")
      :ok
    else
      {:error, reason} ->
        Logger.error("Failed to configure channel 2: #{inspect(reason)}")
        {:error, {:config_failed, :channel_2, reason}}
    end
  end

  # Channel 1 limit 1 configuration (SDO 0x8000:0x13)
  defp maybe_configure_limit1_ch1(config_sdo, config) do
    case {Map.get(config, :ch1_limit1), Map.get(config, :ch1_enable_limit1, false)} do
      {nil, _} ->
        :ok

      {limit1, enable?} when is_integer(limit1) ->
        with :ok <- config_sdo.(0x8000, 0x13, <<limit1::little-signed-16>>),
             :ok <- config_sdo.(0x8000, 0x07, if(enable?, do: <<1::8>>, else: <<0::8>>)) do
          Logger.debug("Ch1 Limit1 configured: #{limit1} (enabled: #{enable?})")
          :ok
        end

      _ ->
        {:error, :invalid_ch1_limit1}
    end
  end

  # Channel 1 limit 2 configuration (SDO 0x8000:0x14)
  defp maybe_configure_limit2_ch1(config_sdo, config) do
    case {Map.get(config, :ch1_limit2), Map.get(config, :ch1_enable_limit2, false)} do
      {nil, _} ->
        :ok

      {limit2, enable?} when is_integer(limit2) ->
        with :ok <- config_sdo.(0x8000, 0x14, <<limit2::little-signed-16>>),
             :ok <- config_sdo.(0x8000, 0x08, if(enable?, do: <<1::8>>, else: <<0::8>>)) do
          Logger.debug("Ch1 Limit2 configured: #{limit2} (enabled: #{enable?})")
          :ok
        end

      _ ->
        {:error, :invalid_ch1_limit2}
    end
  end

  # Channel 1 filter configuration (SDO 0x8000:0x15)
  defp maybe_configure_filter_ch1(config_sdo, config) do
    enable_filter = Map.get(config, :ch1_enable_filter, true)
    filter_settings = Map.get(config, :ch1_filter_settings, 10)

    with :ok <- config_sdo.(0x8000, 0x06, if(enable_filter, do: <<1::8>>, else: <<0::8>>)),
         :ok <- config_sdo.(0x8000, 0x15, <<filter_settings::little-16>>) do
      Logger.debug("Ch1 Filter configured: #{filter_settings} (enabled: #{enable_filter})")
      :ok
    end
  end

  # Channel 2 limit 1 configuration (SDO 0x8010:0x13)
  defp maybe_configure_limit1_ch2(config_sdo, config) do
    case {Map.get(config, :ch2_limit1), Map.get(config, :ch2_enable_limit1, false)} do
      {nil, _} ->
        :ok

      {limit1, enable?} when is_integer(limit1) ->
        with :ok <- config_sdo.(0x8010, 0x13, <<limit1::little-signed-16>>),
             :ok <- config_sdo.(0x8010, 0x07, if(enable?, do: <<1::8>>, else: <<0::8>>)) do
          Logger.debug("Ch2 Limit1 configured: #{limit1} (enabled: #{enable?})")
          :ok
        end

      _ ->
        {:error, :invalid_ch2_limit1}
    end
  end

  # Channel 2 limit 2 configuration (SDO 0x8010:0x14)
  defp maybe_configure_limit2_ch2(config_sdo, config) do
    case {Map.get(config, :ch2_limit2), Map.get(config, :ch2_enable_limit2, false)} do
      {nil, _} ->
        :ok

      {limit2, enable?} when is_integer(limit2) ->
        with :ok <- config_sdo.(0x8010, 0x14, <<limit2::little-signed-16>>),
             :ok <- config_sdo.(0x8010, 0x08, if(enable?, do: <<1::8>>, else: <<0::8>>)) do
          Logger.debug("Ch2 Limit2 configured: #{limit2} (enabled: #{enable?})")
          :ok
        end

      _ ->
        {:error, :invalid_ch2_limit2}
    end
  end

  # Channel 2 filter configuration (SDO 0x8010:0x15)
  defp maybe_configure_filter_ch2(config_sdo, config) do
    enable_filter = Map.get(config, :ch2_enable_filter, true)
    filter_settings = Map.get(config, :ch2_filter_settings, 10)

    with :ok <- config_sdo.(0x8010, 0x06, if(enable_filter, do: <<1::8>>, else: <<0::8>>)),
         :ok <- config_sdo.(0x8010, 0x15, <<filter_settings::little-16>>) do
      Logger.debug("Ch2 Filter configured: #{filter_settings} (enabled: #{enable_filter})")
      :ok
    end
  end
end
