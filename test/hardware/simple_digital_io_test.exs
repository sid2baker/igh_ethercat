defmodule Hardware.SimpleDigitalIOTest do
  use ExUnit.Case, async: false
  import Bitwise

  @moduletag :hardware
  @moduletag timeout: :infinity

  @moduledoc """
  Simplified tests for digital I/O loopback between EL2809 outputs and EL1809 inputs.

  Hardware Requirements:
  - EL2809 output channels must be connected to corresponding EL1809 input channels
  - Connection: EL2809 Ch1 → EL1809 Ch1, Ch2 → Ch2, etc.

  This simplified test setup excludes the EL3202 RTD module to focus on digital I/O only.

  Run with: mix test test/hardware/simple_digital_io_test.exs
  """

  # Helper to get PDO/entry names for a channel (1-based)
  defp input_pdo(ch) when ch >= 1 and ch <= 16 do
    pdo_hex = Integer.to_string(0x1A00 + (ch - 1), 16) |> String.downcase()
    entry_hex = Integer.to_string(0x6000 + (ch - 1) * 0x10, 16) |> String.downcase()
    {"0x#{pdo_hex}", "0x#{entry_hex}:1"}
  end

  defp output_pdo(ch) when ch >= 1 and ch <= 16 do
    pdo_hex = Integer.to_string(0x1600 + (ch - 1), 16) |> String.downcase()
    entry_hex = Integer.to_string(0x7000 + (ch - 1) * 0x10, 16) |> String.downcase()
    {"0x#{pdo_hex}", "0x#{entry_hex}:1"}
  end

  describe "Simple Digital I/O Loopback" do
    setup do
      # Wait for hardware to stabilize after Master connects
      Process.sleep(2100)
      master = Process.whereis(EtherCAT.Master)
      {:ok, slaves} = EtherCAT.configure_hardware(master, SimpleHardwareConfig.hardware_config())
      {:ok, slaves: slaves}
    end

    @tag :digital_io
    test "writes and reads channel 1 with debug output", %{slaves: slaves} do
      {out_pdo, out_entry} = output_pdo(1)
      {in_pdo, in_entry} = input_pdo(1)

      IO.puts("\n=== Testing Channel 1 Loopback ===")
      IO.puts("Output: #{out_pdo}/#{out_entry}")
      IO.puts("Input:  #{in_pdo}/#{in_entry}")

      # Read initial state
      {:ok, initial} = EtherCAT.read(slaves.digital_inputs, in_pdo, in_entry)
      IO.puts("Initial input state: #{inspect(initial)}")

      # Write HIGH
      IO.puts("Writing HIGH to output...")
      :ok = EtherCAT.write(slaves.digital_outputs, out_pdo, out_entry, true)
      Process.sleep(100)

      # Read back
      {:ok, after_high} = EtherCAT.read(slaves.digital_inputs, in_pdo, in_entry)
      IO.puts("After writing HIGH: #{inspect(after_high)}")

      # Write LOW
      IO.puts("Writing LOW to output...")
      :ok = EtherCAT.write(slaves.digital_outputs, out_pdo, out_entry, false)
      Process.sleep(100)

      # Read back
      {:ok, after_low} = EtherCAT.read(slaves.digital_inputs, in_pdo, in_entry)
      IO.puts("After writing LOW: #{inspect(after_low)}")

      IO.puts("\n=== Results ===")
      IO.puts("Initial: #{initial}, After HIGH: #{after_high}, After LOW: #{after_low}")

      # Assert results
      assert after_high == true, "Expected input to be HIGH after writing HIGH"
      assert after_low == false, "Expected input to be LOW after writing LOW"
    end

    @tag :digital_io
    test "verifies all channels work independently", %{slaves: slaves} do
      IO.puts("\n=== Testing All 16 Channels ===")

      # Set all channels to LOW first
      for ch <- 1..16 do
        {out_pdo, out_entry} = output_pdo(ch)
        :ok = EtherCAT.write(slaves.digital_outputs, out_pdo, out_entry, false)
      end

      Process.sleep(100)

      # Test each channel individually
      failed_channels = []

      for ch <- 1..16 do
        {out_pdo, out_entry} = output_pdo(ch)
        {in_pdo, in_entry} = input_pdo(ch)

        # Write HIGH to this channel
        :ok = EtherCAT.write(slaves.digital_outputs, out_pdo, out_entry, true)
        Process.sleep(50)

        # Read back
        {:ok, value} = EtherCAT.read(slaves.digital_inputs, in_pdo, in_entry)

        if value != true do
          IO.puts("Channel #{ch}: FAILED (expected true, got #{inspect(value)})")
          failed_channels = [ch | failed_channels]
        else
          IO.puts("Channel #{ch}: OK")
        end

        # Write LOW again
        :ok = EtherCAT.write(slaves.digital_outputs, out_pdo, out_entry, false)
        Process.sleep(50)
      end

      assert failed_channels == [],
             "Channels #{inspect(Enum.reverse(failed_channels))} failed loopback test"
    end

    @tag :digital_io
    test "verifies bit pattern", %{slaves: slaves} do
      IO.puts("\n=== Testing Bit Pattern (First 8 Channels) ===")

      # Test pattern: alternating bits (0xAA = 10101010)
      pattern = 0xAA

      # Write pattern
      for ch <- 1..8 do
        {out_pdo, out_entry} = output_pdo(ch)
        bit_value = (pattern &&& 1 <<< (ch - 1)) != 0
        :ok = EtherCAT.write(slaves.digital_outputs, out_pdo, out_entry, bit_value)
      end

      Process.sleep(100)

      # Read back and verify
      read_pattern = 0

      for ch <- 1..8 do
        {in_pdo, in_entry} = input_pdo(ch)
        {:ok, value} = EtherCAT.read(slaves.digital_inputs, in_pdo, in_entry)

        if value do
          read_pattern = read_pattern ||| 1 <<< (ch - 1)
        end
      end

      IO.puts("Expected pattern: 0x#{Integer.to_string(pattern, 16)}")
      IO.puts("Read pattern:     0x#{Integer.to_string(read_pattern, 16)}")

      assert read_pattern == pattern,
             "Pattern mismatch: expected 0x#{Integer.to_string(pattern, 16)}, got 0x#{Integer.to_string(read_pattern, 16)}"
    end
  end
end
