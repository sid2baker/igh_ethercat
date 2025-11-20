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

  alias EtherCAT.Config.{
    HardwareConfig,
    MasterConfig,
    DomainConfig,
    SlaveConfig,
    SyncManagerConfig,
    PdoConfig
  }

  def hardware_config do
    %HardwareConfig{
      master: %MasterConfig{
        index: 0,
        cycle_interval: 10_000,
        nif_yield_interval: 100_000
      },
      domains: [
        %DomainConfig{name: :default_domain, interval: 1}
      ],
      slaves: [
        # EK1100 - EtherCAT Coupler at position 0
        %SlaveConfig{
          position: 0,
          name: :coupler,
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
        },
        # EL1809 - 16-channel digital input at position 1
        %SlaveConfig{
          position: 1,
          name: :digital_inputs,
          device_identity: %{
            vendor_id: 0x00000002,
            product_code: 0x07113052,
            revision_no: nil,
            serial_no: nil
          },
          driver: nil,
          config: %{
            sdos: [],
            sync_managers: [
              %SyncManagerConfig{
                index: 3,
                direction: :input,
                watchdog: :disabled,
                pdos:
                  for ch <- 1..16 do
                    %PdoConfig{
                      index: 0x1A00 + (ch - 1),
                      name: :"channel_#{ch}",
                      entries: %{
                        input: {0x6000 + (ch - 1) * 0x10, 0x01, 1}
                      }
                    }
                  end
              }
            ]
          },
          registered_entries: %{
            default_domain:
              for ch <- 1..16 do
                {:"channel_#{ch}", :input}
              end
          }
        },
        # EL2809 - 16-channel digital output at position 2
        %SlaveConfig{
          position: 2,
          name: :digital_outputs,
          device_identity: %{
            vendor_id: 0x00000002,
            product_code: 0x0AF93052,
            revision_no: nil,
            serial_no: nil
          },
          driver: nil,
          config: %{
            sdos: [],
            sync_managers: [
              # First 8 channels in SM0
              %SyncManagerConfig{
                index: 0,
                direction: :output,
                watchdog: :enabled,
                pdos:
                  for ch <- 1..8 do
                    %PdoConfig{
                      index: 0x1600 + (ch - 1),
                      name: :"channel_#{ch}",
                      entries: %{
                        output: {0x7000 + (ch - 1) * 0x10, 0x01, 1}
                      }
                    }
                  end
              },
              # Second 8 channels in SM1
              %SyncManagerConfig{
                index: 1,
                direction: :output,
                watchdog: :enabled,
                pdos:
                  for ch <- 9..16 do
                    %PdoConfig{
                      index: 0x1600 + (ch - 1),
                      name: :"channel_#{ch}",
                      entries: %{
                        output: {0x7000 + (ch - 1) * 0x10, 0x01, 1}
                      }
                    }
                  end
              }
            ]
          },
          registered_entries: %{
            default_domain:
              for ch <- 1..16 do
                {:"channel_#{ch}", :output}
              end
          }
        }
      ]
    }
  end
end
