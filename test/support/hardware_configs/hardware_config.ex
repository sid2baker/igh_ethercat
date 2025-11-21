defmodule TestHardwareConfig do
  @moduledoc """
  Hardware configuration for the test setup.

  Physical Hardware Setup:
  - Position 0: EK1100 EtherCAT Coupler (Vendor: 0x00000002, Product: 0x044c2c52)
  - Position 1: EL1809 16-channel digital input (24V DC)
  - Position 2: EL2809 16-channel digital output (24V DC, 0.5A)
  - Position 3: EL3202 2-channel RTD input (PT100/PT1000)

  Wiring:
  - Each EL2809 output channel is connected to the corresponding EL1809 input channel
    (Output Ch1 → Input Ch1, Output Ch2 → Input Ch2, etc.)
  - EL3202 Channel 1: 120Ω resistor connected
  - EL3202 Channel 2: 100Ω resistor connected
  """

  alias EtherCAT.Config.{
    HardwareConfig,
    MasterConfig,
    DomainConfig,
    SlaveConfig,
    SyncManagerConfig,
    PdoConfig
  }

  def hardware_config do
    HardwareConfig.new(
      master:
        MasterConfig.new(
          index: 0,
          cycle_interval: 10_000,
          nif_yield_interval: 100_000
        ),
      domains: [
        DomainConfig.new(:io_domain, 1)
      ],
      slaves: [
        coupler_config(),
        digital_inputs_config(),
        digital_outputs_config(),
        rtd_inputs_config()
      ]
    )
  end

  # EK1100 - EtherCAT Coupler at position 0
  defp coupler_config do
    SlaveConfig.new(0,
      name: :coupler,
      device_identity: %{vendor_id: 0x00000002, product_code: 0x044C2C52},
      driver: nil,
      config: %{},
      registered_entries: %{}
    )
  end

  # EL1809 - 16-channel digital input at position 1
  defp digital_inputs_config do
    SlaveConfig.new(1,
      name: :digital_inputs,
      device_identity: %{vendor_id: 0x00000002, product_code: 0x07113052},
      driver: nil,
      config: %{
        sync_managers: [
          SyncManagerConfig.new(
            index: 0,
            direction: :input,
            watchdog: :disabled,
            pdos: el1809_pdos()
          )
        ]
      },
      registered_entries: %{
        io_domain: el1809_registered_entries()
      }
    )
  end

  # EL2809 - 16-channel digital output at position 2
  defp digital_outputs_config do
    SlaveConfig.new(2,
      name: :digital_outputs,
      device_identity: %{vendor_id: 0x00000002, product_code: 0x0AF93052},
      driver: nil,
      config: %{
        sync_managers: [
          # SM0: Channels 1-8
          SyncManagerConfig.new(
            index: 0,
            direction: :output,
            watchdog: :enabled,
            pdos: el2809_pdos_sm0()
          ),
          # SM1: Channels 9-16
          SyncManagerConfig.new(
            index: 1,
            direction: :output,
            watchdog: :enabled,
            pdos: el2809_pdos_sm1()
          )
        ]
      },
      registered_entries: %{
        io_domain: el2809_registered_entries()
      }
    )
  end

  # EL3202 - 2-channel RTD input at position 3
  # Configured in resistance mode (rtd_element: :resistance_100) for testing with fixed resistors
  defp rtd_inputs_config do
    SlaveConfig.new(3,
      name: :rtd_inputs,
      device_identity: %{vendor_id: 0x00000002, product_code: 0x0C823052},
      driver: Drivers.EL3202,
      config: %{
        channel_1: %{rtd_element: :ohm_1_64, connection: :two_wire},
        channel_2: %{rtd_element: :ohm_1_16, connection: :two_wire}
      },
      registered_entries: %{
        io_domain: el3202_registered_entries()
      }
    )
  end

  # EL1809 PDO configurations (16 TxPDOs, one per channel)
  defp el1809_pdos do
    [
      PdoConfig.new(index: 0x1A00, name: :channel_1, entries: %{input: {0x6000, 0x01, 1}}),
      PdoConfig.new(index: 0x1A01, name: :channel_2, entries: %{input: {0x6010, 0x01, 1}}),
      PdoConfig.new(index: 0x1A02, name: :channel_3, entries: %{input: {0x6020, 0x01, 1}}),
      PdoConfig.new(index: 0x1A03, name: :channel_4, entries: %{input: {0x6030, 0x01, 1}}),
      PdoConfig.new(index: 0x1A04, name: :channel_5, entries: %{input: {0x6040, 0x01, 1}}),
      PdoConfig.new(index: 0x1A05, name: :channel_6, entries: %{input: {0x6050, 0x01, 1}}),
      PdoConfig.new(index: 0x1A06, name: :channel_7, entries: %{input: {0x6060, 0x01, 1}}),
      PdoConfig.new(index: 0x1A07, name: :channel_8, entries: %{input: {0x6070, 0x01, 1}}),
      PdoConfig.new(index: 0x1A08, name: :channel_9, entries: %{input: {0x6080, 0x01, 1}}),
      PdoConfig.new(index: 0x1A09, name: :channel_10, entries: %{input: {0x6090, 0x01, 1}}),
      PdoConfig.new(index: 0x1A0A, name: :channel_11, entries: %{input: {0x60A0, 0x01, 1}}),
      PdoConfig.new(index: 0x1A0B, name: :channel_12, entries: %{input: {0x60B0, 0x01, 1}}),
      PdoConfig.new(index: 0x1A0C, name: :channel_13, entries: %{input: {0x60C0, 0x01, 1}}),
      PdoConfig.new(index: 0x1A0D, name: :channel_14, entries: %{input: {0x60D0, 0x01, 1}}),
      PdoConfig.new(index: 0x1A0E, name: :channel_15, entries: %{input: {0x60E0, 0x01, 1}}),
      PdoConfig.new(index: 0x1A0F, name: :channel_16, entries: %{input: {0x60F0, 0x01, 1}})
    ]
  end

  defp el1809_registered_entries do
    for i <- 1..16 do
      {String.to_atom("channel_#{i}"), :input}
    end
  end

  # EL2809 PDO configurations - SM0 (Channels 1-8)
  defp el2809_pdos_sm0 do
    [
      PdoConfig.new(index: 0x1600, name: :channel_1, entries: %{output: {0x7000, 0x01, 1}}),
      PdoConfig.new(index: 0x1601, name: :channel_2, entries: %{output: {0x7010, 0x01, 1}}),
      PdoConfig.new(index: 0x1602, name: :channel_3, entries: %{output: {0x7020, 0x01, 1}}),
      PdoConfig.new(index: 0x1603, name: :channel_4, entries: %{output: {0x7030, 0x01, 1}}),
      PdoConfig.new(index: 0x1604, name: :channel_5, entries: %{output: {0x7040, 0x01, 1}}),
      PdoConfig.new(index: 0x1605, name: :channel_6, entries: %{output: {0x7050, 0x01, 1}}),
      PdoConfig.new(index: 0x1606, name: :channel_7, entries: %{output: {0x7060, 0x01, 1}}),
      PdoConfig.new(index: 0x1607, name: :channel_8, entries: %{output: {0x7070, 0x01, 1}})
    ]
  end

  # EL2809 PDO configurations - SM1 (Channels 9-16)
  defp el2809_pdos_sm1 do
    [
      PdoConfig.new(index: 0x1608, name: :channel_9, entries: %{output: {0x7080, 0x01, 1}}),
      PdoConfig.new(index: 0x1609, name: :channel_10, entries: %{output: {0x7090, 0x01, 1}}),
      PdoConfig.new(index: 0x160A, name: :channel_11, entries: %{output: {0x70A0, 0x01, 1}}),
      PdoConfig.new(index: 0x160B, name: :channel_12, entries: %{output: {0x70B0, 0x01, 1}}),
      PdoConfig.new(index: 0x160C, name: :channel_13, entries: %{output: {0x70C0, 0x01, 1}}),
      PdoConfig.new(index: 0x160D, name: :channel_14, entries: %{output: {0x70D0, 0x01, 1}}),
      PdoConfig.new(index: 0x160E, name: :channel_15, entries: %{output: {0x70E0, 0x01, 1}}),
      PdoConfig.new(index: 0x160F, name: :channel_16, entries: %{output: {0x70F0, 0x01, 1}})
    ]
  end

  defp el2809_registered_entries do
    for i <- 1..16 do
      {String.to_atom("channel_#{i}"), :output}
    end
  end

  # EL3202 registered entries (PDO config comes from Drivers.EL3202)
  defp el3202_registered_entries do
    [
      {:rtd_channel_1, :value},
      {:rtd_channel_1, :underrange},
      {:rtd_channel_1, :overrange},
      {:rtd_channel_1, :error},
      {:rtd_channel_2, :value},
      {:rtd_channel_2, :underrange},
      {:rtd_channel_2, :overrange},
      {:rtd_channel_2, :error}
    ]
  end
end
