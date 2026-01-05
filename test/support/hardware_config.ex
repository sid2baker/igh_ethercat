defmodule Support.HardwareConfig do
  alias EtherCAT.HardwareConfig
  alias EtherCAT.HardwareConfig.{MasterConfig, DomainConfig, SlaveConfig}

  def create(fake? \\ false) do
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
        el1809(:digital_inputs, 1, fake?),
        el2809(:digital_outputs, 2, fake?)
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
      config: %{},
      registered_entries: %{}
    }
  end

  def el1809(name, position, fake? \\ false) do
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
            direction:
              if(fake?) do
                :output
              else
                :input
              end,
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

  def el2809(name, position, fake? \\ false) do
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
            direction:
              if fake? do
                :input
              else
                :output
              end,
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
            direction:
              if fake? do
                :input
              else
                :output
              end,
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
end
