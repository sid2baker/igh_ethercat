defmodule Hardware.EL3202Test do
  @moduledoc """
  Simple EL3202 RTD temperature input test.

  ## Hardware Setup

  Expected configuration:
  - Slave 0: EK1100 Bus coupler
  - Slave 1: EL1809 Digital input
  - Slave 2: EL2809 Digital output
  - Slave 3: EL3202 RTD temperature input (2 channels)

  Connect resistors to simulate PT100 sensors:
  - CH1 (pins 1+, 2-): 120Ω resistor → ~50°C
  - CH2 (pins 5+, 6-): 100Ω resistor → ~0°C

  ## Running

      mix test test/hardware/el3202_test.exs --include hardware
  """

  use ExUnit.Case, async: false
  require Logger

  @tag :hardware
  @tag timeout: 30_000
  test "EL3202 reads temperature values" do
    Logger.info("\n=== EL3202 Temperature Reading Test ===\n")

    # Open master and discover slaves
    {:ok, master, slaves} = EtherCAT.open(update_interval: 1000)
    Logger.info("Discovered #{length(slaves)} slaves")

    # Get EL3202 (should be at position 3)
    el3202 = Enum.at(slaves, 3)
    assert el3202 != nil, "EL3202 not found at position 3"

    # Configure with empty config to use defaults (no SDO configuration)
    Logger.info("Configuring EL3202 with default settings...")
    {:ok, available_pdos} = EtherCAT.configure_slave(el3202, %{})
    Logger.info("Available PDOs: #{inspect(available_pdos)}")

    # Register both channels
    Logger.info("Registering PDO channels...")
    {:ok, pdo_handles} = EtherCAT.register_pdos(el3202, [:ch1, :ch2])
    Logger.info("Registered #{length(pdo_handles)} PDO entries")

    # Start cyclic communication
    Logger.info("Starting cyclic mode...")
    EtherCAT.start_cyclic(master)

    # Wait for data to stabilize
    :timer.sleep(2000)

    # Read channel 1 temperature
    Logger.info("\n=== Channel 1 (120Ω resistor) ===")
    ch1_value = read_pdo_entry(pdo_handles, "ch1:value")
    ch1_error = read_pdo_entry(pdo_handles, "ch1:error")
    ch1_underrange = read_pdo_entry(pdo_handles, "ch1:underrange")
    ch1_overrange = read_pdo_entry(pdo_handles, "ch1:overrange")

    if ch1_value do
      temp_c = ch1_value / 10.0
      Logger.info("  Value: #{ch1_value} (#{temp_c}°C)")
      Logger.info("  Error: #{ch1_error}")
      Logger.info("  Underrange: #{ch1_underrange}")
      Logger.info("  Overrange: #{ch1_overrange}")

      # For 120Ω PT100, expect around 50°C
      assert temp_c > 45.0 and temp_c < 55.0,
             "CH1 temperature #{temp_c}°C outside expected range (45-55°C for 120Ω)"
    end

    # Read channel 2 temperature
    Logger.info("\n=== Channel 2 (100Ω resistor) ===")
    ch2_value = read_pdo_entry(pdo_handles, "ch2:value")
    ch2_error = read_pdo_entry(pdo_handles, "ch2:error")
    ch2_underrange = read_pdo_entry(pdo_handles, "ch2:underrange")
    ch2_overrange = read_pdo_entry(pdo_handles, "ch2:overrange")

    if ch2_value do
      temp_c = ch2_value / 10.0
      Logger.info("  Value: #{ch2_value} (#{temp_c}°C)")
      Logger.info("  Error: #{ch2_error}")
      Logger.info("  Underrange: #{ch2_underrange}")
      Logger.info("  Overrange: #{ch2_overrange}")

      # For 100Ω PT100, expect around 0°C (allowing for measurement offset)
      assert temp_c > -5.0 and temp_c < 5.0,
             "CH2 temperature #{temp_c}°C outside expected range (-5 to 5°C for 100Ω)"
    end

    # Cleanup
    Logger.info("\n=== Test Complete ===\n")
    EtherCAT.close(master)
  end

  # Helper to read a PDO entry by name pattern
  defp read_pdo_entry(handles, name_pattern) do
    handle = Enum.find(handles, fn h -> String.contains?(h.unique_name, name_pattern) end)

    if handle do
      case EtherCAT.read(handle) do
        {:ok, value} -> value
        {:error, _reason} -> nil
      end
    else
      nil
    end
  end
end
