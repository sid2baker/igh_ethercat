defmodule EtherCAT.ExampleLayouts do
  @moduledoc """
  Example hardware layouts for testing.

  Provides pre-defined layouts that can be used as test fixtures or
  reference examples for common EtherCAT configurations.

  ## Usage

      # In your tests
      import EtherCAT.ExampleLayouts

      test "works with simple I/O slave" do
        layout = simple_io_layout()
        # Use layout for testing...
      end
  """

  alias EtherCAT.{HardwareLayout, SlaveConfig}

  @doc """
  Single simple I/O slave layout.

  Matches the example from TESTING_STRATEGY.md:
  - Vendor ID: 0xDEADBEEF
  - Product Code: 0x00000001
  - 1 byte input, 1 byte output

  This is useful for basic testing scenarios where you just need
  a minimal functional slave.
  """
  @spec simple_io_layout() :: HardwareLayout.t()
  def simple_io_layout do
    %HardwareLayout{
      slaves: [
        %SlaveConfig{
          position: 0,
          vendor_id: 0xDEADBEEF,
          product_code: 0x00000001,
          name: :simple_io,
          alias: 0
        }
      ]
    }
  end

  @doc """
  Beckhoff EL3202 2-channel RTD temperature sensor.

  Real-world example of a common industrial device:
  - Vendor ID: 0x00000002 (Beckhoff Automation GmbH)
  - Product Code: 0x0C823052 (EL3202-0010)
  - 2 temperature input channels
  - Supports PT100/PT1000 sensors

  Useful for testing with a realistic slave configuration.
  """
  @spec beckhoff_temperature_layout() :: HardwareLayout.t()
  def beckhoff_temperature_layout do
    %HardwareLayout{
      slaves: [
        %SlaveConfig{
          position: 0,
          vendor_id: 0x00000002,
          product_code: 0x0C823052,
          name: :temp_sensor,
          alias: 0
        }
      ]
    }
  end

  @doc """
  Multi-slave bus with mixed vendors.

  Simulates a more complex real-world scenario:
  - Position 0: Beckhoff EK1100 coupler
  - Position 1: Beckhoff EL3202 temperature sensor
  - Position 2: Custom I/O device
  - Position 3: Another Beckhoff terminal

  Useful for testing:
  - Multi-slave enumeration
  - Finding slaves by vendor
  - Hardware verification with multiple devices
  """
  @spec multi_slave_layout() :: HardwareLayout.t()
  def multi_slave_layout do
    %HardwareLayout{
      slaves: [
        %SlaveConfig{
          position: 0,
          vendor_id: 0x00000002,
          product_code: 0x044C2C52,
          name: :coupler_ek1100,
          alias: 0
        },
        %SlaveConfig{
          position: 1,
          vendor_id: 0x00000002,
          product_code: 0x0C823052,
          name: :temp_sensor_el3202,
          alias: 0
        },
        %SlaveConfig{
          position: 2,
          vendor_id: 0xDEADBEEF,
          product_code: 0x00000001,
          name: :custom_io,
          alias: 0
        },
        %SlaveConfig{
          position: 3,
          vendor_id: 0x00000002,
          product_code: 0x13ed3052,
          name: :digital_output_el2008,
          alias: 0
        }
      ]
    }
  end

  @doc """
  Aliased slave configuration.

  Demonstrates using alias addresses for position-independent addressing:
  - Position 0: Slave with alias 1000
  - Position 1: Slave with alias 2000

  Useful for testing alias-based slave lookup and configuration.
  """
  @spec aliased_layout() :: HardwareLayout.t()
  def aliased_layout do
    %HardwareLayout{
      slaves: [
        %SlaveConfig{
          position: 0,
          vendor_id: 0xDEADBEEF,
          product_code: 0x00000001,
          name: :device_a,
          alias: 1000
        },
        %SlaveConfig{
          position: 1,
          vendor_id: 0xDEADBEEF,
          product_code: 0x00000002,
          name: :device_b,
          alias: 2000
        }
      ]
    }
  end

  @doc """
  Empty bus layout.

  Useful for testing edge cases:
  - No slaves discovered
  - Hardware verification with empty expected configuration
  """
  @spec empty_layout() :: HardwareLayout.t()
  def empty_layout do
    %HardwareLayout{slaves: []}
  end

  @doc """
  Large bus configuration.

  Simulates a complex system with many slaves (16 devices).
  Useful for performance testing and scalability validation.
  """
  @spec large_bus_layout() :: HardwareLayout.t()
  def large_bus_layout do
    slaves =
      0..15
      |> Enum.map(fn position ->
        # Alternate between two vendor IDs
        vendor_id = if rem(position, 2) == 0, do: 0x00000002, else: 0xDEADBEEF

        %SlaveConfig{
          position: position,
          vendor_id: vendor_id,
          product_code: 0x00000001 + position,
          name: :"slave_#{position}",
          alias: 0
        }
      end)

    %HardwareLayout{slaves: slaves}
  end
end
