defmodule TestHardwareConfig do
  @moduledoc """
  Hardware configuration for integration testing (programmatic version).

  Hardware setup:
  - Position 0: EK1100 Coupler
  - Position 1: EL1809 (16-channel digital input)
  - Position 2: EL2809 (16-channel digital output)
  - Position 3: EL3202 (2-channel analog input, PT100)
  """

  alias EtherCAT.Config.{HardwareConfig, DomainConfig, SlaveConfig, EntryConfig}

  def hardware_config do
    %HardwareConfig{
      domains: [
        %DomainConfig{name: :fast_loop, interval: 1},
        %DomainConfig{name: :slow_loop, interval: 10}
      ],
      slaves: [
        # EL1809 - 16-channel digital input
        %SlaveConfig{
          position: 1,
          name: :digital_inputs,
          driver: EtherCAT.Drivers.EL1809,
          expected: %{:vendor => 0x00000002, :product => 0x07093052},
          config: %{},
          entries: Enum.map(1..16, fn i ->
            %EntryConfig{
              pdo_name: :inputs,
              entry_name: String.to_atom("ch#{i}"),
              domain: :fast_loop
            }
          end)
        },
        # EL2809 - 16-channel digital output
        %SlaveConfig{
          position: 2,
          name: :digital_outputs,
          driver: EtherCAT.Drivers.EL2809,
          expected: %{:vendor => 0x00000002, :product => 0x0AF93052},
          config: %{},
          entries: Enum.map(1..16, fn i ->
            %EntryConfig{
              pdo_name: :outputs,
              entry_name: String.to_atom("ch#{i}"),
              domain: :fast_loop
            }
          end)
        },
        # EL3202 - 2-channel analog input
        %SlaveConfig{
          position: 3,
          name: :analog_inputs,
          driver: EtherCAT.Drivers.EL3202,
          expected: %{:vendor => 0x00000002, :product => 0x0C5A3052},
          config: %{},
          entries: [
            %EntryConfig{pdo_name: :ch1, entry_name: :value, domain: :fast_loop},
            %EntryConfig{pdo_name: :ch2, entry_name: :value, domain: :fast_loop},
            %EntryConfig{pdo_name: :ch1, entry_name: :error, domain: :slow_loop},
            %EntryConfig{pdo_name: :ch2, entry_name: :error, domain: :slow_loop}
          ]
        }
      ]
    }
  end
end
