defmodule HardwareConfigs do
  @moduledoc """
  Simplified hardware configuration for basic digital I/O testing with multi-domain support.

  Physical Hardware Setup:
  - Position 0: EK1100 EtherCAT Coupler (Vendor: 0x00000002, Product: 0x044c2c52)
  - Position 1: EL1809 16-channel digital input (24V DC)
  - Position 2: EL2809 16-channel digital output (24V DC, 0.5A)

  Wiring:
  - Each EL2809 output channel is connected to the corresponding EL1809 input channel
    (Output Ch1 → Input Ch1, Output Ch2 → Input Ch2, etc.)

  Domain Configuration:
  - :fast domain (cyclic_multiplier=1, every cycle = 10ms)
    - Input channels 1-16
    - Output channels 1-16

  Note: In IgH EtherCAT, once a slave's sync managers are configured, ALL of them
  must be registered to the SAME domain. You cannot split a slave's SMs across domains.
  Both EL1809 and EL2809 must have all their channels in one domain.
  """

  alias EtherCAT.HardwareConfig
  alias EtherCAT.HardwareConfig.{MasterConfig, DomainConfig, SlaveConfig}

  def simple_hardware_config do
    %HardwareConfig{
      master: %MasterConfig{
        cyclic_interval: 10_000
      },
      domains: [
        %DomainConfig{
          name: :fast,
          cyclic_multiplier: 1
        }
      ],
      slaves: [
        ek1100(:coupler, 0),
        el1809(:digital_inputs, 1),
        el2809(:digital_outputs, 2)
      ]
    }
  end

  def rtd_hardware_config do
    %HardwareConfig{
      master: %MasterConfig{
        cyclic_interval: 10_000
      },
      domains: [
        %DomainConfig{
          name: :fast,
          cyclic_multiplier: 1
        }
      ],
      slaves: [
        ek1100(:coupler, 0),
        el1809(:digital_inputs, 1),
        el2809(:digital_outputs, 2),
        el3202(:rtd, 3)
      ]
    }
  end

  def ek1100(name, position) do
    %SlaveConfig{
      name: name,
      position: position,
      device_identity: %{
        vendor_id: 0x00000002,
        product_code: 0x044C2C52,
        revision_no: nil,
        serial_no: nil
      },
      driver: nil,
      config: %{
        sync_managers: [],
        sdos: []
      },
      registered_entries: %{}
    }
  end

  def el1809(name, position) do
    %SlaveConfig{
      name: name,
      position: position,
      device_identity: %{
        vendor_id: 0x00000002,
        product_code: 0x07113052,
        revision_no: nil,
        serial_no: nil
      },
      driver: EtherCAT.Slave.GenericDriver,
      config: %{
        sdos: [],
        sync_managers: [
          %{
            index: 3,
            direction: :input,
            watchdog: :disabled,
            pdos:
              Map.new(
                for ch <- 1..16 do
                  {:"channel_#{ch}",
                   %{
                     index: 0x1A00 + (ch - 1),
                     entries: %{
                       input: {0x6000 + (ch - 1) * 0x10, 0x01, 1}
                     }
                   }}
                end
              )
          }
        ]
      },
      registered_entries: %{
        # EL1809 has single SM with all 16 channels - cannot be split across domains
        # All channels must go to ONE domain to avoid double allocation
        fast:
          for ch <- 1..16 do
            {:"channel_#{ch}", :input}
          end
      }
    }
  end

  def el2809(name, position) do
    %SlaveConfig{
      name: name,
      position: position,
      device_identity: %{
        vendor_id: 0x00000002,
        product_code: 0x0AF93052,
        revision_no: nil,
        serial_no: nil
      },
      driver: EtherCAT.Slave.GenericDriver,
      config: %{
        sdos: [],
        sync_managers: [
          # First 8 channels in SM0
          %{
            index: 0,
            direction: :output,
            watchdog: :enabled,
            pdos:
              Map.new(
                for ch <- 1..8 do
                  {:"channel_#{ch}",
                   %{
                     index: 0x1600 + (ch - 1),
                     entries: %{
                       output: {0x7000 + (ch - 1) * 0x10, 0x01, 1}
                     }
                   }}
                end
              )
          },
          # Second 8 channels in SM1
          %{
            index: 1,
            direction: :output,
            watchdog: :enabled,
            pdos:
              Map.new(
                for ch <- 9..16 do
                  {:"channel_#{ch}",
                   %{
                     index: 0x1600 + (ch - 1),
                     entries: %{
                       output: {0x7000 + (ch - 1) * 0x10, 0x01, 1}
                     }
                   }}
                end
              )
          }
        ]
      },
      registered_entries: %{
        # EL1809 has single SM with all 16 channels - cannot be split across domains
        # All channels must go to ONE domain to avoid double allocation
        fast:
          for ch <- 1..16 do
            {:"channel_#{ch}", :output}
          end
      }
    }
  end

  def el3202(name, position) do
    %SlaveConfig{
      name: name,
      position: position,
      device_identity: %{
        vendor_id: 0x00000002,
        product_code: 0x0C823052,
        revision_no: nil,
        serial_no: nil
      },
      driver: Drivers.EL3202,
      config: %{
        channel_1: %{rtd_element: :ohm_1_64, connection: :two_wire},
        channel_2: %{rtd_element: :ohm_1_16, connection: :two_wire}
      },
      registered_entries: %{
        fast: [
          {:rtd_channel_1, :value},
          {:rtd_channel_1, :underrange},
          {:rtd_channel_1, :overrange},
          {:rtd_channel_1, :error},
          {:rtd_channel_2, :value},
          {:rtd_channel_2, :underrange},
          {:rtd_channel_2, :overrange},
          {:rtd_channel_2, :error}
        ]
      }
    }
  end
end
