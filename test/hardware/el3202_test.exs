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

    # Configure for OHMS measurement mode with user scale
    # Formula: Yscaled = (Ycalibrated * AW * 2^-16) + BW
    # Default gain is 32768 (1.0x), so: gain = 32768 * desired_factor
    # Measured: Ch1=95.5Ω, Ch2=79.4Ω. Actual: Ch1=120Ω, Ch2=100Ω
    Logger.info("Configuring EL3202 for OHMS measurement...")

    config = %{
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
    }

    {:ok, available_pdos} = EtherCAT.configure_slave(el3202, config)
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
    ch1_value = read_pdo_entry(pdo_handles, :ch1, :value)
    ch1_error = read_pdo_entry(pdo_handles, :ch1, :error)
    ch1_underrange = read_pdo_entry(pdo_handles, :ch1, :underrange)
    ch1_overrange = read_pdo_entry(pdo_handles, :ch1, :overrange)

    if ch1_value do
      # Driver returns resistance in Ohms when configured for OHMS mode
      Logger.info("  PDO Value: #{ch1_value}Ω")
      Logger.info("  Error: #{ch1_error}")
      Logger.info("  Underrange: #{ch1_underrange}")
      Logger.info("  Overrange: #{ch1_overrange}")

      # Also check the internal resistor value (SDO 0x800e:0x02)
      # This is the actual measured resistance after wire compensation
      case System.cmd("ethercat", ["upload", "-p", "3", "0x800e", "0x02", "--type", "uint16"]) do
        {output, 0} ->
          if String.contains?(output, "0x") do
            [_, hex_val | _] = String.split(output)
            {int_val, _} = Integer.parse(String.trim(hex_val), 16)
            internal_ohms = int_val / 10.0
            Logger.info("  Internal Resistor: #{internal_ohms}Ω (from SDO 0x800e:0x02)")
          end

        _ ->
          :ok
      end
    end

    # Read channel 2 temperature
    Logger.info("\n=== Channel 2 (100Ω resistor) ===")
    ch2_value = read_pdo_entry(pdo_handles, :ch2, :value)
    ch2_error = read_pdo_entry(pdo_handles, :ch2, :error)
    ch2_underrange = read_pdo_entry(pdo_handles, :ch2, :underrange)
    ch2_overrange = read_pdo_entry(pdo_handles, :ch2, :overrange)

    if ch2_value do
      # Driver returns resistance in Ohms when configured for OHMS mode
      Logger.info("  PDO Value: #{ch2_value}Ω")
      Logger.info("  Error: #{ch2_error}")
      Logger.info("  Underrange: #{ch2_underrange}")
      Logger.info("  Overrange: #{ch2_overrange}")

      # Also check the internal resistor value (SDO 0x801e:0x02)
      # This is the actual measured resistance after wire compensation
      case System.cmd("ethercat", ["upload", "-p", "3", "0x801e", "0x02", "--type", "uint16"]) do
        {output, 0} ->
          if String.contains?(output, "0x") do
            [_, hex_val | _] = String.split(output)
            {int_val, _} = Integer.parse(String.trim(hex_val), 16)
            internal_ohms = int_val / 10.0
            Logger.info("  Internal Resistor: #{internal_ohms}Ω (from SDO 0x801e:0x02)")
          end

        _ ->
          :ok
      end
    end

    # Cleanup
    Logger.info("\n=== Test Complete ===\n")
    EtherCAT.close(master)
  end

  # Helper to read a PDO entry by pdo_name and entry_name
  defp read_pdo_entry(handles, pdo_name, entry_name) do
    handle =
      Enum.find(handles, fn h -> h.pdo_name == pdo_name and h.entry_name == entry_name end)

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
