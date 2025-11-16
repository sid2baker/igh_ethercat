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

  alias EtherCAT.Config.{HardwareConfig, MasterConfig, DomainConfig, SlaveConfig}

  def hardware_config do
    %HardwareConfig{
      master: %MasterConfig{
        index: 0,
        cycle_interval: 10_000,
        nif_yield_interval: 100_000
      },
      domains: [
        %DomainConfig{name: :io_domain, interval: 1}
      ],
      slaves: [
        # EK1100 - EtherCAT Coupler at position 0
        %SlaveConfig{
          position: 0,
          name: :coupler,
          driver: nil,
          expected: %{vendor: 0x00000002, product: 0x044C2C52},
          config: %{},
          entries: []
        },
        # EL1809 - 16-channel digital input at position 1
        # TODO: Add proper entry configuration when specific driver is implemented
        %SlaveConfig{
          position: 1,
          name: :digital_inputs,
          driver: nil,
          expected: %{vendor: 0x00000002, product: 0x07113052},
          config: %{},
          entries: []
        },
        # EL2809 - 16-channel digital output at position 2
        # TODO: Add proper entry configuration when specific driver is implemented
        %SlaveConfig{
          position: 2,
          name: :digital_outputs,
          driver: nil,
          expected: %{vendor: 0x00000002, product: 0x0AF93052},
          config: %{},
          entries: []
        },
        # EL3202 - 2-channel RTD input at position 3
        # TODO: Add proper entry configuration and SDO config when specific driver is implemented
        %SlaveConfig{
          position: 3,
          name: :rtd_inputs,
          driver: nil,
          expected: %{vendor: 0x00000002, product: 0x0C823052},
          config: %{},
          entries: []
        }
      ]
    }
  end
end
