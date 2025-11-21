defmodule Drivers.EL3202 do
  @moduledoc """
  Driver for Beckhoff EL3202 2-channel RTD input terminal.

  ## Configuration

  The driver accepts per-channel configuration via the `:channels` key:

      %{
        channels: [
          %{
            rtd_element: :pt100,
            connection: :two_wire,
            enable_filter: true,
            filter_settings: 50
          },
          %{
            rtd_element: :pt1000,
            connection: :three_wire
          }
        ]
      }

  ## Channel Options

  - `:rtd_element` - RTD sensor type (default: `:pt100`)
    - `:pt100`, `:ni100`, `:pt200`, `:ni120`, `:pt500`, `:pt1000`,
      `:ni1000`, `:ni1000_tk5000`, `:resistance_100`, `:resistance_1000`

  - `:connection` - Wiring configuration (default: `:two_wire`)
    - `:two_wire`, `:three_wire`, `:four_wire`

  - `:enable_filter` - Enable digital filter (default: `false`)
  - `:filter_settings` - Filter frequency in Hz (default: `50`)

  - `:enable_user_scale` - Enable user scaling (default: `false`)
  - `:user_scale_offset` - Scaling offset, int16 (default: `0`)
  - `:user_scale_gain` - Scaling gain, int32 (default: `65536`)

  - `:enable_limit_1` - Enable limit 1 monitoring (default: `false`)
  - `:limit_1` - Limit 1 threshold, int16 (default: `0`)
  - `:enable_limit_2` - Enable limit 2 monitoring (default: `false`)
  - `:limit_2` - Limit 2 threshold, int16 (default: `0`)

  - `:wire_calibration` - Wire resistance calibration in 1/32 Ohm (default: `0`)

  ## PDO Layout (Fixed)

  The EL3202 has a fixed PDO layout and does not support PDO reconfiguration.
  Each channel provides:
  - Status bits: underrange, overrange, limit_1, limit_2, error
  - TxPDO state/toggle bits
  - 16-bit signed temperature value (0.1°C resolution)
  """

  use EtherCAT.Slave.Driver

  alias EtherCAT.Slave.Driver
  alias EtherCAT.Config.{SdoConfig, SyncManagerConfig, PdoConfig}

  # RTD element types (0x8000:19 / 0x8010:19)
  @rtd_elements %{
    pt100: 0,
    ni100: 1,
    pt200: 2,
    ni120: 3,
    pt500: 4,
    pt1000: 5,
    ni1000: 6,
    ni1000_tk5000: 7,
    resistance_100: 8,
    resistance_1000: 9
  }

  # Connection technology (0x8000:1a / 0x8010:1a)
  @connections %{
    two_wire: 0,
    three_wire: 1,
    four_wire: 2
  }

  defstruct [:master, :name, :channels]

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl GenServer
  def init(opts) do
    config = opts[:config] || %{}
    channels = Map.get(config, :channels, [%{}, %{}])

    # Ensure we have exactly 2 channel configs
    channels =
      case channels do
        [c1] -> [c1, %{}]
        [c1, c2 | _] -> [c1, c2]
        _ -> [%{}, %{}]
      end

    state = %__MODULE__{
      master: opts[:master],
      name: opts[:name],
      channels: channels
    }

    {:ok, state}
  end

  # ============================================================================
  # Driver Behaviour Callbacks
  # ============================================================================

  @impl EtherCAT.Slave.Driver
  def configurable_pdos?(_state), do: false

  @impl EtherCAT.Slave.Driver
  def get_sdo_config(state) do
    build_sdo_config(state.channels)
  end

  @impl EtherCAT.Slave.Driver
  def get_pdo_config(_state) do
    pdo_config()
  end

  @impl EtherCAT.Slave.Driver
  def encode_pdo_value(_pdo, _entry, _value, _state) do
    # EL3202 is input-only, no encoding needed
    {:error, :input_only_device}
  end

  @impl EtherCAT.Slave.Driver
  def decode_pdo_value(pdo, entry, binary, _state) do
    type = get_entry_type(pdo, entry)
    Driver.decode_by_type(type, binary)
  end

  # ============================================================================
  # SDO Configuration Builder
  # ============================================================================

  defp build_sdo_config(channels) do
    channels
    |> Enum.with_index()
    |> Enum.flat_map(fn {channel_config, index} ->
      build_channel_sdos(channel_config, index)
    end)
  end

  defp build_channel_sdos(config, channel_index) do
    # Base index: 0x8000 for ch1, 0x8010 for ch2
    base = 0x8000 + channel_index * 0x10

    sdos = []

    # RTD element type
    sdos =
      if rtd = config[:rtd_element] do
        value = Map.get(@rtd_elements, rtd, 0)
        [SdoConfig.new(index: base, subindex: 0x19, data: <<value::little-16>>) | sdos]
      else
        sdos
      end

    # Connection technology
    sdos =
      if conn = config[:connection] do
        value = Map.get(@connections, conn, 0)
        [SdoConfig.new(index: base, subindex: 0x1A, data: <<value::little-16>>) | sdos]
      else
        sdos
      end

    # Filter settings
    sdos =
      if config[:enable_filter] do
        filter_hz = config[:filter_settings] || 50

        [
          SdoConfig.new(index: base, subindex: 0x06, data: <<1>>),
          SdoConfig.new(index: base, subindex: 0x15, data: <<filter_hz::little-16>>)
          | sdos
        ]
      else
        sdos
      end

    # User scaling
    sdos =
      if config[:enable_user_scale] do
        offset = config[:user_scale_offset] || 0
        gain = config[:user_scale_gain] || 65536

        [
          SdoConfig.new(index: base, subindex: 0x01, data: <<1>>),
          SdoConfig.new(index: base, subindex: 0x11, data: <<offset::little-signed-16>>),
          SdoConfig.new(index: base, subindex: 0x12, data: <<gain::little-signed-32>>)
          | sdos
        ]
      else
        sdos
      end

    # Limit 1
    sdos =
      if config[:enable_limit_1] do
        limit = config[:limit_1] || 0

        [
          SdoConfig.new(index: base, subindex: 0x07, data: <<1>>),
          SdoConfig.new(index: base, subindex: 0x13, data: <<limit::little-signed-16>>)
          | sdos
        ]
      else
        sdos
      end

    # Limit 2
    sdos =
      if config[:enable_limit_2] do
        limit = config[:limit_2] || 0

        [
          SdoConfig.new(index: base, subindex: 0x08, data: <<1>>),
          SdoConfig.new(index: base, subindex: 0x14, data: <<limit::little-signed-16>>)
          | sdos
        ]
      else
        sdos
      end

    # Wire calibration
    sdos =
      if wire_cal = config[:wire_calibration] do
        [SdoConfig.new(index: base, subindex: 0x1B, data: <<wire_cal::little-signed-16>>) | sdos]
      else
        sdos
      end

    Enum.reverse(sdos)
  end

  # ============================================================================
  # Fixed PDO Configuration
  # ============================================================================

  defp pdo_config do
    [
      SyncManagerConfig.new(
        index: 3,
        direction: :input,
        watchdog: :disabled,
        pdos: [
          PdoConfig.new(
            index: 0x1A00,
            name: :rtd_channel_1,
            entries: %{
              underrange: {0x6000, 0x01, 1},
              overrange: {0x6000, 0x02, 1},
              limit_1: {0x6000, 0x03, 2},
              limit_2: {0x6000, 0x05, 2},
              error: {0x6000, 0x07, 1},
              gap: {0x0000, 0x00, 7},
              txpdo_state: {0x1800, 0x07, 1},
              txpdo_toggle: {0x1800, 0x09, 1},
              value: {0x6000, 0x11, 16}
            }
          ),
          PdoConfig.new(
            index: 0x1A01,
            name: :rtd_channel_2,
            entries: %{
              underrange: {0x6010, 0x01, 1},
              overrange: {0x6010, 0x02, 1},
              limit_1: {0x6010, 0x03, 2},
              limit_2: {0x6010, 0x05, 2},
              error: {0x6010, 0x07, 1},
              gap: {0x0000, 0x00, 7},
              txpdo_state: {0x1801, 0x07, 1},
              txpdo_toggle: {0x1801, 0x09, 1},
              value: {0x6010, 0x11, 16}
            }
          )
        ]
      )
    ]
  end

  # ============================================================================
  # Entry Type Mapping
  # ============================================================================

  defp get_entry_type(_pdo, :value), do: :int16
  defp get_entry_type(_pdo, :underrange), do: :bool
  defp get_entry_type(_pdo, :overrange), do: :bool
  defp get_entry_type(_pdo, :error), do: :bool
  defp get_entry_type(_pdo, :txpdo_state), do: :bool
  defp get_entry_type(_pdo, :txpdo_toggle), do: :bool
  defp get_entry_type(_pdo, :limit_1), do: :uint8
  defp get_entry_type(_pdo, :limit_2), do: :uint8
  defp get_entry_type(_pdo, _), do: :uint8
end
