defmodule Hardware.HardwareConfigTest do
  use ExUnit.Case, async: false

  @moduletag :hardware
  @moduletag timeout: :infinity

  @moduledoc """
  Hardware tests for TestHardwareConfig with EL1809, EL2809, and EL3202.

  Hardware Setup:
  - Position 0: EK1100 EtherCAT Coupler
  - Position 1: EL1809 16-channel digital input
  - Position 2: EL2809 16-channel digital output (looped back to EL1809)
  - Position 3: EL3202 2-channel RTD input (Ch1: 120Ω, Ch2: 100Ω resistors)
  """

  describe "Digital I/O Loopback" do
    setup do
      master = Process.whereis(EtherCAT.Master)
      {:ok, slaves} = EtherCAT.configure_hardware(master, TestHardwareConfig.hardware_config())

      # Clear all outputs
      for ch <- 1..16 do
        pdo = String.to_atom("channel_#{ch}")
        EtherCAT.write(slaves.digital_outputs, pdo, :output, false)
      end

      Process.sleep(100)

      on_exit(fn ->
        for ch <- 1..16 do
          pdo = String.to_atom("channel_#{ch}")
          EtherCAT.write(slaves.digital_outputs, pdo, :output, false)
        end
      end)

      {:ok, slaves: slaves}
    end

    @tag :digital_io
    test "single channel toggle", %{slaves: slaves} do
      # Test channel 1
      :ok = EtherCAT.write(slaves.digital_outputs, :channel_1, :output, true)
      Process.sleep(50)
      assert {:ok, true} = EtherCAT.read(slaves.digital_inputs, :channel_1, :input)

      :ok = EtherCAT.write(slaves.digital_outputs, :channel_1, :output, false)
      Process.sleep(50)
      assert {:ok, false} = EtherCAT.read(slaves.digital_inputs, :channel_1, :input)
    end

    @tag :digital_io
    test "all channels individually", %{slaves: slaves} do
      for active_ch <- 1..16 do
        _active_pdo = String.to_atom("channel_#{active_ch}")

        # Set only this channel HIGH
        for ch <- 1..16 do
          pdo = String.to_atom("channel_#{ch}")
          :ok = EtherCAT.write(slaves.digital_outputs, pdo, :output, ch == active_ch)
        end

        Process.sleep(50)

        # Verify
        for ch <- 1..16 do
          pdo = String.to_atom("channel_#{ch}")
          expected = ch == active_ch

          assert {:ok, ^expected} = EtherCAT.read(slaves.digital_inputs, pdo, :input),
                 "Channel #{ch} expected #{expected} when ch#{active_ch} is active"
        end
      end
    end

    @tag :digital_io
    test "all channels HIGH", %{slaves: slaves} do
      for ch <- 1..16 do
        pdo = String.to_atom("channel_#{ch}")
        :ok = EtherCAT.write(slaves.digital_outputs, pdo, :output, true)
      end

      Process.sleep(200)

      for ch <- 1..16 do
        pdo = String.to_atom("channel_#{ch}")

        assert {:ok, true} = EtherCAT.read(slaves.digital_inputs, pdo, :input),
               "Channel #{ch} should be HIGH"
      end
    end

    @tag :digital_io
    test "alternating pattern", %{slaves: slaves} do
      # Set odd channels HIGH, even LOW
      for ch <- 1..16 do
        pdo = String.to_atom("channel_#{ch}")
        :ok = EtherCAT.write(slaves.digital_outputs, pdo, :output, rem(ch, 2) == 1)
      end

      Process.sleep(50)

      for ch <- 1..16 do
        pdo = String.to_atom("channel_#{ch}")
        expected = rem(ch, 2) == 1
        assert {:ok, ^expected} = EtherCAT.read(slaves.digital_inputs, pdo, :input)
      end
    end
  end

  describe "RTD Resistance Reading" do
    # Expected values and tolerance
    @ch1_expected 120.0
    @ch2_expected 100.0
    @tolerance 10.0

    setup do
      master = Process.whereis(EtherCAT.Master)
      {:ok, slaves} = EtherCAT.configure_hardware(master, TestHardwareConfig.hardware_config())
      # Allow RTD to stabilize
      Process.sleep(500)
      {:ok, slaves: slaves}
    end

    @tag :rtd
    test "reads channel 1 resistance (120Ω)", %{slaves: slaves} do
      {:ok, value} = EtherCAT.read(slaves.rtd_inputs, :rtd_channel_1, :value)

      # Value is in 0.1Ω units for resistance mode
      resistance = value / 10.0

      assert_in_delta resistance,
                      @ch1_expected,
                      @tolerance,
                      "Channel 1: expected #{@ch1_expected}Ω ±#{@tolerance}Ω, got #{resistance}Ω"
    end

    @tag :rtd
    test "reads channel 2 resistance (100Ω)", %{slaves: slaves} do
      {:ok, value} = EtherCAT.read(slaves.rtd_inputs, :rtd_channel_2, :value)

      resistance = value / 10.0

      assert_in_delta resistance,
                      @ch2_expected,
                      @tolerance,
                      "Channel 2: expected #{@ch2_expected}Ω ±#{@tolerance}Ω, got #{resistance}Ω"
    end

    @tag :rtd
    test "no error flags on either channel", %{slaves: slaves} do
      {:ok, ch1_error} = EtherCAT.read(slaves.rtd_inputs, :rtd_channel_1, :error)
      {:ok, ch2_error} = EtherCAT.read(slaves.rtd_inputs, :rtd_channel_2, :error)

      refute ch1_error, "Channel 1 should not have error flag"
      refute ch2_error, "Channel 2 should not have error flag"
    end

    @tag :rtd
    test "readings are stable", %{slaves: slaves} do
      readings =
        for _ <- 1..20 do
          {:ok, value} = EtherCAT.read(slaves.rtd_inputs, :rtd_channel_1, :value)
          Process.sleep(100)
          value / 10.0
        end

      mean = Enum.sum(readings) / length(readings)

      variance =
        Enum.map(readings, fn x -> (x - mean) ** 2 end)
        |> Enum.sum()
        |> Kernel./(length(readings))

      std_dev = :math.sqrt(variance)

      assert std_dev < 2.0,
             "Channel 1 too unstable: std_dev=#{std_dev}Ω, mean=#{mean}Ω"
    end

    @tag :rtd
    test "channels read different values", %{slaves: slaves} do
      {:ok, ch1_value} = EtherCAT.read(slaves.rtd_inputs, :rtd_channel_1, :value)
      {:ok, ch2_value} = EtherCAT.read(slaves.rtd_inputs, :rtd_channel_2, :value)

      ch1_resistance = ch1_value / 10.0
      ch2_resistance = ch2_value / 10.0
      difference = abs(ch1_resistance - ch2_resistance)

      # Expected ~20Ω difference
      assert difference > 10.0 and difference < 30.0,
             "Expected ~20Ω difference, got #{difference}Ω (ch1=#{ch1_resistance}Ω, ch2=#{ch2_resistance}Ω)"
    end
  end
end
