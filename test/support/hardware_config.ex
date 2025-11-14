defmodule HardwareConfig do
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

  alias EtherCAT.Config.{HardwareConfig, MasterConfig, DomainConfig, SlaveConfig, EntryConfig}

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
        # EL1809 - 16-channel digital input at position 1
        %SlaveConfig{
          position: 1,
          name: :digital_inputs,
          driver: EtherCAT.Drivers.EL1809,
          expected: %{vendor: 0x00000002, product: 0x07113052},
          config: %{},
          entries:
            Enum.map(1..16, fn i ->
              %EntryConfig{
                pdo_name: String.to_atom("ch#{i}"),
                entry_name: :input,
                domain: :io_domain
              }
            end)
        },
        # EL2809 - 16-channel digital output at position 2
        %SlaveConfig{
          position: 2,
          name: :digital_outputs,
          driver: EtherCAT.Drivers.EL2809,
          expected: %{vendor: 0x00000002, product: 0x0AF93052},
          config: %{},
          entries:
            Enum.map(1..16, fn i ->
              %EntryConfig{
                pdo_name: String.to_atom("ch#{i}"),
                entry_name: :output,
                domain: :io_domain
              }
            end)
        },
        # EL3202 - 2-channel RTD input at position 3
        # Configured in OHMS mode to read resistor values directly
        %SlaveConfig{
          position: 3,
          name: :rtd_inputs,
          driver: EtherCAT.Drivers.EL3202,
          expected: %{vendor: 0x00000002, product: 0x0C823052},
          config: %{
            # OHMS mode
            ch1_rtd_element: 8,
            # 2-wire
            ch1_connection: 0,
            ch1_enable_user_scale: true,
            # No offset
            ch1_user_scale_offset: 0,
            # 32768 * 1.257 (120/95.5)
            ch1_user_scale_gain: 41190,
            # OHMS mode
            ch2_rtd_element: 8,
            # 2-wire
            ch2_connection: 0,
            ch2_enable_user_scale: true,
            # No offset
            ch2_user_scale_offset: 0,
            # 32768 * 1.259 (100/79.4)
            ch2_user_scale_gain: 41264
          },
          entries: [
            %EntryConfig{pdo_name: :ch1, entry_name: :value, domain: :io_domain},
            %EntryConfig{pdo_name: :ch1, entry_name: :error, domain: :io_domain},
            %EntryConfig{pdo_name: :ch2, entry_name: :value, domain: :io_domain},
            %EntryConfig{pdo_name: :ch2, entry_name: :error, domain: :io_domain}
          ]
        }
      ]
    }
  end
end
