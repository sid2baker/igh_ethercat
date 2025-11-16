defmodule Hardware.DigitalIOTest do
  use ExUnit.Case, async: false
  import Bitwise

  @moduletag :hardware
  @moduletag timeout: :infinity

  @moduledoc """
  Tests for digital I/O loopback between EL2809 outputs and EL1809 inputs.

  Hardware Requirements:
  - EL2809 output channels must be connected to corresponding EL1809 input channels
  - Connection: EL2809 Ch1 → EL1809 Ch1, Ch2 → Ch2, etc.

  These tests verify that:
  1. Individual channels can be toggled and read back correctly
  2. All 16 channels work independently
  3. Complex bit patterns can be written and read back
  4. Timing characteristics are acceptable

  Run with: ETHERCAT_HARDWARE=true mix test --only hardware:digital_io

  Note: The EtherCAT Master is auto-started by the Application supervision tree.

  ## PDO Naming (Generic Driver Autodiscovery)

  The Generic driver discovers PDO names from EEPROM as hex strings:
  - EL1809 inputs: PDOs "0x1a00".."0x1a0f", entries "0x6000:1".."0x60f0:1"
  - EL2809 outputs: PDOs "0x1600".."0x160f", entries "0x7000:1".."0x70f0:1"
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

  describe "Single Channel Loopback" do
    setup do
      # Wait for hardware to stabilize after Master connects
      Process.sleep(2100)
      {:ok, slaves} = EtherCAT.configure_hardware(0, TestHardwareConfig.hardware_config())
      {:ok, slaves: slaves}
    end

    @tag :digital_io
    test "writes and reads channel 1", %{slaves: slaves} do
      {out_pdo, out_entry} = output_pdo(1)
      {in_pdo, in_entry} = input_pdo(1)

      # Write HIGH
      :ok = EtherCAT.write(slaves.digital_outputs, out_pdo, out_entry, true)
      Process.sleep(50)

      # Read back
      assert {:ok, true} = EtherCAT.read(slaves.digital_inputs, in_pdo, in_entry)

      # Write LOW
      :ok = EtherCAT.write(slaves.digital_outputs, out_pdo, out_entry, false)
      Process.sleep(50)

      # Read back
      assert {:ok, false} = EtherCAT.read(slaves.digital_inputs, in_pdo, in_entry)
    end

    @tag :digital_io
    test "writes and reads channel 8", %{slaves: slaves} do
      {out_pdo, out_entry} = output_pdo(8)
      {in_pdo, in_entry} = input_pdo(8)

      # Test middle channel
      :ok = EtherCAT.write(slaves.digital_outputs, out_pdo, out_entry, true)
      Process.sleep(50)
      assert {:ok, true} = EtherCAT.read(slaves.digital_inputs, in_pdo, in_entry)

      :ok = EtherCAT.write(slaves.digital_outputs, out_pdo, out_entry, false)
      Process.sleep(50)
      assert {:ok, false} = EtherCAT.read(slaves.digital_inputs, in_pdo, in_entry)
    end

    @tag :digital_io
    test "writes and reads channel 16", %{slaves: slaves} do
      {out_pdo, out_entry} = output_pdo(16)
      {in_pdo, in_entry} = input_pdo(16)

      # Test last channel
      :ok = EtherCAT.write(slaves.digital_outputs, out_pdo, out_entry, true)
      Process.sleep(50)
      assert {:ok, true} = EtherCAT.read(slaves.digital_inputs, in_pdo, in_entry)

      :ok = EtherCAT.write(slaves.digital_outputs, out_pdo, out_entry, false)
      Process.sleep(50)
      assert {:ok, false} = EtherCAT.read(slaves.digital_inputs, in_pdo, in_entry)
    end
  end

  describe "All Channels Loopback" do
    setup do
      {:ok, slaves} = EtherCAT.configure_hardware(0, TestHardwareConfig.hardware_config())

      # Clear all outputs before each test
      for i <- 1..16 do
        {out_pdo, out_entry} = output_pdo(i)
        :ok = EtherCAT.write(slaves.digital_outputs, out_pdo, out_entry, false)
      end

      Process.sleep(100)

      on_exit(fn ->
        # Clear all outputs after test
        for i <- 1..16 do
          {out_pdo, out_entry} = output_pdo(i)
          EtherCAT.write(slaves.digital_outputs, out_pdo, out_entry, false)
        end
      end)

      {:ok, slaves: slaves}
    end

    @tag :digital_io
    test "tests each channel individually", %{slaves: slaves} do
      # Test each channel one at a time
      for active_ch <- 1..16 do
        # Set only this channel HIGH, all others LOW
        for ch <- 1..16 do
          {out_pdo, out_entry} = output_pdo(ch)
          value = ch == active_ch
          :ok = EtherCAT.write(slaves.digital_outputs, out_pdo, out_entry, value)
        end

        Process.sleep(50)

        # Verify only this channel reads HIGH, all others LOW
        for ch <- 1..16 do
          {in_pdo, in_entry} = input_pdo(ch)
          expected = ch == active_ch

          assert {:ok, ^expected} = EtherCAT.read(slaves.digital_inputs, in_pdo, in_entry),
                 "Channel #{ch} expected #{expected} when ch#{active_ch} is active"
        end
      end
    end

    @tag :digital_io
    test "sets all channels HIGH simultaneously", %{slaves: slaves} do
      # Set all channels HIGH
      for i <- 1..16 do
        {out_pdo, out_entry} = output_pdo(i)
        :ok = EtherCAT.write(slaves.digital_outputs, out_pdo, out_entry, true)
      end

      Process.sleep(50)

      # Verify all channels read HIGH
      for i <- 1..16 do
        {in_pdo, in_entry} = input_pdo(i)

        assert {:ok, true} = EtherCAT.read(slaves.digital_inputs, in_pdo, in_entry),
               "Channel #{i} should be HIGH"
      end
    end

    @tag :digital_io
    test "sets all channels LOW simultaneously", %{slaves: slaves} do
      # First set all HIGH
      for i <- 1..16 do
        {out_pdo, out_entry} = output_pdo(i)
        :ok = EtherCAT.write(slaves.digital_outputs, out_pdo, out_entry, true)
      end

      Process.sleep(50)

      # Then set all LOW
      for i <- 1..16 do
        {out_pdo, out_entry} = output_pdo(i)
        :ok = EtherCAT.write(slaves.digital_outputs, out_pdo, out_entry, false)
      end

      Process.sleep(50)

      # Verify all channels read LOW
      for i <- 1..16 do
        {in_pdo, in_entry} = input_pdo(i)

        assert {:ok, false} = EtherCAT.read(slaves.digital_inputs, in_pdo, in_entry),
               "Channel #{i} should be LOW"
      end
    end
  end

  describe "Pattern Testing" do
    setup do
      {:ok, slaves} = EtherCAT.configure_hardware(0, TestHardwareConfig.hardware_config())

      # Clear all outputs
      for i <- 1..16 do
        {out_pdo, out_entry} = output_pdo(i)
        :ok = EtherCAT.write(slaves.digital_outputs, out_pdo, out_entry, false)
      end

      on_exit(fn ->
        for i <- 1..16 do
          {out_pdo, out_entry} = output_pdo(i)
          EtherCAT.write(slaves.digital_outputs, out_pdo, out_entry, false)
        end
      end)

      {:ok, slaves: slaves}
    end

    @tag :digital_io
    test "tests 8-bit binary counter pattern", %{slaves: slaves} do
      # Test patterns 0-255 on first 8 channels
      for pattern <- 0..255 do
        # Write pattern to channels 1-8
        for bit <- 0..7 do
          {out_pdo, out_entry} = output_pdo(bit + 1)
          value = (pattern &&& 1 <<< bit) != 0
          :ok = EtherCAT.write(slaves.digital_outputs, out_pdo, out_entry, value)
        end

        Process.sleep(20)

        # Read back and verify
        for bit <- 0..7 do
          {in_pdo, in_entry} = input_pdo(bit + 1)
          expected = (pattern &&& 1 <<< bit) != 0

          assert {:ok, ^expected} = EtherCAT.read(slaves.digital_inputs, in_pdo, in_entry),
                 "Pattern #{pattern} (0x#{Integer.to_string(pattern, 16)}), bit #{bit} mismatch"
        end
      end
    end

    @tag :digital_io
    test "tests alternating pattern", %{slaves: slaves} do
      # Pattern: 0x5555 (0101010101010101)
      for i <- 1..16 do
        {out_pdo, out_entry} = output_pdo(i)
        value = rem(i, 2) == 1
        :ok = EtherCAT.write(slaves.digital_outputs, out_pdo, out_entry, value)
      end

      Process.sleep(50)

      for i <- 1..16 do
        {in_pdo, in_entry} = input_pdo(i)
        expected = rem(i, 2) == 1
        assert {:ok, ^expected} = EtherCAT.read(slaves.digital_inputs, in_pdo, in_entry)
      end

      # Inverted pattern: 0xAAAA (1010101010101010)
      for i <- 1..16 do
        {out_pdo, out_entry} = output_pdo(i)
        value = rem(i, 2) == 0
        :ok = EtherCAT.write(slaves.digital_outputs, out_pdo, out_entry, value)
      end

      Process.sleep(50)

      for i <- 1..16 do
        {in_pdo, in_entry} = input_pdo(i)
        expected = rem(i, 2) == 0
        assert {:ok, ^expected} = EtherCAT.read(slaves.digital_inputs, in_pdo, in_entry)
      end
    end

    @tag :digital_io
    test "tests walking ones pattern", %{slaves: slaves} do
      # Walk a single HIGH bit across all 16 channels
      for active <- 1..16 do
        # Set only one channel HIGH
        for ch <- 1..16 do
          {out_pdo, out_entry} = output_pdo(ch)
          value = ch == active
          :ok = EtherCAT.write(slaves.digital_outputs, out_pdo, out_entry, value)
        end

        Process.sleep(30)

        # Verify pattern
        for ch <- 1..16 do
          {in_pdo, in_entry} = input_pdo(ch)
          expected = ch == active
          assert {:ok, ^expected} = EtherCAT.read(slaves.digital_inputs, in_pdo, in_entry)
        end
      end
    end
  end

  describe "Timing Tests" do
    setup do
      {:ok, slaves} = EtherCAT.configure_hardware(0, TestHardwareConfig.hardware_config())

      on_exit(fn ->
        for i <- 1..16 do
          {out_pdo, out_entry} = output_pdo(i)
          EtherCAT.write(slaves.digital_outputs, out_pdo, out_entry, false)
        end
      end)

      {:ok, slaves: slaves}
    end

    @tag :digital_io
    test "verifies signal propagation delay is acceptable", %{slaves: slaves} do
      {out_pdo, out_entry} = output_pdo(1)
      {in_pdo, in_entry} = input_pdo(1)

      # Write HIGH and measure time until read
      :ok = EtherCAT.write(slaves.digital_outputs, out_pdo, out_entry, true)

      # Poll until we see HIGH (with timeout)
      start_time = System.monotonic_time(:millisecond)

      result =
        Enum.reduce_while(1..100, :timeout, fn _, _ ->
          case EtherCAT.read(slaves.digital_inputs, in_pdo, in_entry) do
            {:ok, true} ->
              {:halt, :ok}

            {:ok, false} ->
              Process.sleep(1)
              {:cont, :timeout}

            error ->
              {:halt, error}
          end
        end)

      end_time = System.monotonic_time(:millisecond)
      delay = end_time - start_time

      assert result == :ok, "Signal did not propagate within timeout"
      assert delay < 100, "Propagation delay too high: #{delay}ms"
    end

    @tag :digital_io
    test "rapid toggling test", %{slaves: slaves} do
      {out_pdo, out_entry} = output_pdo(1)
      {in_pdo, in_entry} = input_pdo(1)

      # Toggle channel 100 times rapidly
      for _ <- 1..100 do
        :ok = EtherCAT.write(slaves.digital_outputs, out_pdo, out_entry, true)
        :ok = EtherCAT.write(slaves.digital_outputs, out_pdo, out_entry, false)
      end

      # Final state should be LOW
      Process.sleep(50)
      assert {:ok, false} = EtherCAT.read(slaves.digital_inputs, in_pdo, in_entry)
    end
  end
end
