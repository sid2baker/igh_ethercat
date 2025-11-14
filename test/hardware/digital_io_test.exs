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
  """

  setup_all do
    unless System.get_env("ETHERCAT_HARDWARE") == "true" do
      ExUnit.configure(exclude: [:hardware])
      :ok
    else
      :ok
    end
  end

  describe "Single Channel Loopback" do
    setup do
      {:ok, system} = EtherCAT.configure_hardware(HardwareConfig)
      on_exit(fn -> EtherCAT.stop_system(system) end)
      {:ok, system: system}
    end

    @tag :digital_io
    test "writes and reads channel 1", %{system: system} do
      # Write HIGH
      :ok = EtherCAT.write(system, :digital_outputs, :ch1, :output, true)
      Process.sleep(50)

      # Read back
      assert {:ok, true} = EtherCAT.read(system, :digital_inputs, :ch1, :input)

      # Write LOW
      :ok = EtherCAT.write(system, :digital_outputs, :ch1, :output, false)
      Process.sleep(50)

      # Read back
      assert {:ok, false} = EtherCAT.read(system, :digital_inputs, :ch1, :input)
    end

    @tag :digital_io
    test "writes and reads channel 8", %{system: system} do
      # Test middle channel
      :ok = EtherCAT.write(system, :digital_outputs, :ch8, :output, true)
      Process.sleep(50)
      assert {:ok, true} = EtherCAT.read(system, :digital_inputs, :ch8, :input)

      :ok = EtherCAT.write(system, :digital_outputs, :ch8, :output, false)
      Process.sleep(50)
      assert {:ok, false} = EtherCAT.read(system, :digital_inputs, :ch8, :input)
    end

    @tag :digital_io
    test "writes and reads channel 16", %{system: system} do
      # Test last channel
      :ok = EtherCAT.write(system, :digital_outputs, :ch16, :output, true)
      Process.sleep(50)
      assert {:ok, true} = EtherCAT.read(system, :digital_inputs, :ch16, :input)

      :ok = EtherCAT.write(system, :digital_outputs, :ch16, :output, false)
      Process.sleep(50)
      assert {:ok, false} = EtherCAT.read(system, :digital_inputs, :ch16, :input)
    end
  end

  describe "All Channels Loopback" do
    setup do
      {:ok, system} = EtherCAT.configure_hardware(HardwareConfig)

      # Clear all outputs before each test
      for i <- 1..16 do
        ch = String.to_atom("ch#{i}")
        :ok = EtherCAT.write(system, :digital_outputs, ch, :output, false)
      end

      Process.sleep(100)

      on_exit(fn ->
        # Clear all outputs after test
        for i <- 1..16 do
          ch = String.to_atom("ch#{i}")
          EtherCAT.write(system, :digital_outputs, ch, :output, false)
        end

        EtherCAT.stop_system(system)
      end)

      {:ok, system: system}
    end

    @tag :digital_io
    test "tests each channel individually", %{system: system} do
      # Test each channel one at a time
      for active_ch <- 1..16 do
        # Set only this channel HIGH, all others LOW
        for ch <- 1..16 do
          ch_atom = String.to_atom("ch#{ch}")
          value = ch == active_ch
          :ok = EtherCAT.write(system, :digital_outputs, ch_atom, :output, value)
        end

        Process.sleep(50)

        # Verify only this channel reads HIGH, all others LOW
        for ch <- 1..16 do
          ch_atom = String.to_atom("ch#{ch}")
          expected = ch == active_ch

          assert {:ok, ^expected} = EtherCAT.read(system, :digital_inputs, ch_atom, :input),
                 "Channel #{ch} expected #{expected} when ch#{active_ch} is active"
        end
      end
    end

    @tag :digital_io
    test "sets all channels HIGH simultaneously", %{system: system} do
      # Set all channels HIGH
      for i <- 1..16 do
        ch = String.to_atom("ch#{i}")
        :ok = EtherCAT.write(system, :digital_outputs, ch, :output, true)
      end

      Process.sleep(50)

      # Verify all channels read HIGH
      for i <- 1..16 do
        ch = String.to_atom("ch#{i}")

        assert {:ok, true} = EtherCAT.read(system, :digital_inputs, ch, :input),
               "Channel #{i} should be HIGH"
      end
    end

    @tag :digital_io
    test "sets all channels LOW simultaneously", %{system: system} do
      # First set all HIGH
      for i <- 1..16 do
        ch = String.to_atom("ch#{i}")
        :ok = EtherCAT.write(system, :digital_outputs, ch, :output, true)
      end

      Process.sleep(50)

      # Then set all LOW
      for i <- 1..16 do
        ch = String.to_atom("ch#{i}")
        :ok = EtherCAT.write(system, :digital_outputs, ch, :output, false)
      end

      Process.sleep(50)

      # Verify all channels read LOW
      for i <- 1..16 do
        ch = String.to_atom("ch#{i}")

        assert {:ok, false} = EtherCAT.read(system, :digital_inputs, ch, :input),
               "Channel #{i} should be LOW"
      end
    end
  end

  describe "Pattern Testing" do
    setup do
      {:ok, system} = EtherCAT.configure_hardware(HardwareConfig)

      # Clear all outputs
      for i <- 1..16 do
        ch = String.to_atom("ch#{i}")
        :ok = EtherCAT.write(system, :digital_outputs, ch, :output, false)
      end

      on_exit(fn ->
        for i <- 1..16 do
          ch = String.to_atom("ch#{i}")
          EtherCAT.write(system, :digital_outputs, ch, :output, false)
        end

        EtherCAT.stop_system(system)
      end)

      {:ok, system: system}
    end

    @tag :digital_io
    test "tests 8-bit binary counter pattern", %{system: system} do
      # Test patterns 0-255 on first 8 channels
      for pattern <- 0..255 do
        # Write pattern to channels 1-8
        for bit <- 0..7 do
          ch = String.to_atom("ch#{bit + 1}")
          value = (pattern &&& 1 <<< bit) != 0
          :ok = EtherCAT.write(system, :digital_outputs, ch, :output, value)
        end

        Process.sleep(20)

        # Read back and verify
        for bit <- 0..7 do
          ch = String.to_atom("ch#{bit + 1}")
          expected = (pattern &&& 1 <<< bit) != 0

          assert {:ok, ^expected} = EtherCAT.read(system, :digital_inputs, ch, :input),
                 "Pattern #{pattern} (0x#{Integer.to_string(pattern, 16)}), bit #{bit} mismatch"
        end
      end
    end

    @tag :digital_io
    test "tests alternating pattern", %{system: system} do
      # Pattern: 0x5555 (0101010101010101)
      for i <- 1..16 do
        ch = String.to_atom("ch#{i}")
        value = rem(i, 2) == 1
        :ok = EtherCAT.write(system, :digital_outputs, ch, :output, value)
      end

      Process.sleep(50)

      for i <- 1..16 do
        ch = String.to_atom("ch#{i}")
        expected = rem(i, 2) == 1
        assert {:ok, ^expected} = EtherCAT.read(system, :digital_inputs, ch, :input)
      end

      # Inverted pattern: 0xAAAA (1010101010101010)
      for i <- 1..16 do
        ch = String.to_atom("ch#{i}")
        value = rem(i, 2) == 0
        :ok = EtherCAT.write(system, :digital_outputs, ch, :output, value)
      end

      Process.sleep(50)

      for i <- 1..16 do
        ch = String.to_atom("ch#{i}")
        expected = rem(i, 2) == 0
        assert {:ok, ^expected} = EtherCAT.read(system, :digital_inputs, ch, :input)
      end
    end

    @tag :digital_io
    test "tests walking ones pattern", %{system: system} do
      # Walk a single HIGH bit across all 16 channels
      for active <- 1..16 do
        # Set only one channel HIGH
        for ch <- 1..16 do
          ch_atom = String.to_atom("ch#{ch}")
          value = ch == active
          :ok = EtherCAT.write(system, :digital_outputs, ch_atom, :output, value)
        end

        Process.sleep(30)

        # Verify pattern
        for ch <- 1..16 do
          ch_atom = String.to_atom("ch#{ch}")
          expected = ch == active
          assert {:ok, ^expected} = EtherCAT.read(system, :digital_inputs, ch_atom, :input)
        end
      end
    end
  end

  describe "Timing Tests" do
    setup do
      {:ok, system} = EtherCAT.configure_hardware(HardwareConfig)

      on_exit(fn ->
        for i <- 1..16 do
          ch = String.to_atom("ch#{i}")
          EtherCAT.write(system, :digital_outputs, ch, :output, false)
        end

        EtherCAT.stop_system(system)
      end)

      {:ok, system: system}
    end

    @tag :digital_io
    test "verifies signal propagation delay is acceptable", %{system: system} do
      ch = :ch1

      # Write HIGH and measure time until read
      :ok = EtherCAT.write(system, :digital_outputs, ch, :output, true)

      # Poll until we see HIGH (with timeout)
      start_time = System.monotonic_time(:millisecond)

      result =
        Enum.reduce_while(1..100, :timeout, fn _, _ ->
          case EtherCAT.read(system, :digital_inputs, ch, :input) do
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
    test "rapid toggling test", %{system: system} do
      ch = :ch1

      # Toggle channel 100 times rapidly
      for _ <- 1..100 do
        :ok = EtherCAT.write(system, :digital_outputs, ch, :output, true)
        :ok = EtherCAT.write(system, :digital_outputs, ch, :output, false)
      end

      # Final state should be LOW
      Process.sleep(50)
      assert {:ok, false} = EtherCAT.read(system, :digital_inputs, ch, :input)
    end
  end
end
