defmodule SimpleHardwareConfig do
  @moduledoc """
  Simplified hardware configuration for basic digital I/O testing.

  Physical Hardware Setup:
  - Position 0: EK1100 EtherCAT Coupler (Vendor: 0x00000002, Product: 0x044c2c52)
  - Position 1: EL1809 16-channel digital input (24V DC)
  - Position 2: EL2809 16-channel digital output (24V DC, 0.5A)

  Wiring:
  - Each EL2809 output channel is connected to the corresponding EL1809 input channel
    (Output Ch1 → Input Ch1, Output Ch2 → Input Ch2, etc.)
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
        %SlaveConfig{
          position: 1,
          name: :digital_inputs,
          driver: nil,
          expected: %{vendor: 0x00000002, product: 0x07113052},
          config: %{},
          entries: []
        },
        # EL2809 - 16-channel digital output at position 2
        %SlaveConfig{
          position: 2,
          name: :digital_outputs,
          driver: nil,
          expected: %{vendor: 0x00000002, product: 0x0AF93052},
          config: %{},
          entries: []
        }
      ]
    }
  end
end
