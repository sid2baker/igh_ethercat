defmodule Hardware.RTDInputTest do
  use ExUnit.Case, async: false

  @moduletag :hardware
  @moduletag timeout: :infinity

  @moduledoc """
  Tests for EL3202 RTD input readings with fixed resistors.

  Hardware Requirements:
  - EL3202 Channel 1: 120Ω resistor connected
  - EL3202 Channel 2: 100Ω resistor connected
  - Module configured in OHMS mode (rtd_element = 8) via SDO

  These tests verify:
  1. Resistance values are read correctly from both channels
  2. Values are within acceptable tolerance of expected resistances
  3. No error flags are present
  4. Readings are stable over time

  Run with: mix test

  Note: The EtherCAT Master is started by test_helper.exs.
  """

  # Expected resistance values
  @ch1_expected_resistance 120.0
  @ch2_expected_resistance 100.0

  # Tolerance for resistance measurements (±5Ω allows for resistor tolerance and wire resistance)
  @resistance_tolerance 5.0

  describe "Basic Resistance Reading" do
    setup do
      master = Process.whereis(EtherCAT.Master)
      {:ok, slaves} = EtherCAT.configure_hardware(master, TestHardwareConfig.hardware_config())
      {:ok, slaves: slaves}
    end

    @tag :rtd
    test "reads resistance from channel 1 (120Ω)", %{slaves: slaves} do
      assert {:ok, resistance} = EtherCAT.read(slaves.rtd_inputs, :ch1, :value)
      assert is_number(resistance), "Expected numeric resistance value"

      assert_in_range(
        resistance,
        @ch1_expected_resistance,
        @resistance_tolerance,
        "Channel 1 resistance"
      )
    end

    @tag :rtd
    test "reads resistance from channel 2 (100Ω)", %{slaves: slaves} do
      assert {:ok, resistance} = EtherCAT.read(slaves.rtd_inputs, :ch2, :value)
      assert is_number(resistance), "Expected numeric resistance value"

      assert_in_range(
        resistance,
        @ch2_expected_resistance,
        @resistance_tolerance,
        "Channel 2 resistance"
      )
    end

    @tag :rtd
    test "channel 1 has no error flags", %{slaves: slaves} do
      assert {:ok, error} = EtherCAT.read(slaves.rtd_inputs, :ch1, :error)

      # Error should be false or 0
      refute error, "Channel 1 should not have error flag set"
    end

    @tag :rtd
    test "channel 2 has no error flags", %{slaves: slaves} do
      assert {:ok, error} = EtherCAT.read(slaves.rtd_inputs, :ch2, :error)

      # Error should be false or 0
      refute error, "Channel 2 should not have error flag set"
    end
  end

  describe "Measurement Stability" do
    setup do
      master = Process.whereis(EtherCAT.Master)
      {:ok, slaves} = EtherCAT.configure_hardware(master, TestHardwareConfig.hardware_config())
      {:ok, slaves: slaves}
    end

    @tag :rtd
    test "channel 1 readings are stable over time", %{slaves: slaves} do
      # Take 20 readings over 2 seconds
      readings =
        for _ <- 1..20 do
          {:ok, resistance} = EtherCAT.read(slaves.rtd_inputs, :ch1, :value)
          Process.sleep(100)
          resistance
        end

      # Calculate statistics
      mean = Enum.sum(readings) / length(readings)
      variance = Enum.map(readings, fn x -> (x - mean) * (x - mean) end) |> Enum.sum()
      variance = variance / length(readings)
      std_dev = :math.sqrt(variance)

      # Standard deviation should be small (< 2Ω) for fixed resistor
      assert std_dev < 2.0,
             "Channel 1 readings too unstable: std_dev=#{std_dev}Ω, mean=#{mean}Ω, readings=#{inspect(readings)}"

      # Mean should still be within tolerance
      assert_in_range(mean, @ch1_expected_resistance, @resistance_tolerance, "Channel 1 mean")
    end

    @tag :rtd
    test "channel 2 readings are stable over time", %{slaves: slaves} do
      # Take 20 readings over 2 seconds
      readings =
        for _ <- 1..20 do
          {:ok, resistance} = EtherCAT.read(slaves.rtd_inputs, :ch2, :value)
          Process.sleep(100)
          resistance
        end

      # Calculate statistics
      mean = Enum.sum(readings) / length(readings)
      variance = Enum.map(readings, fn x -> (x - mean) * (x - mean) end) |> Enum.sum()
      variance = variance / length(readings)
      std_dev = :math.sqrt(variance)

      # Standard deviation should be small (< 2Ω) for fixed resistor
      assert std_dev < 2.0,
             "Channel 2 readings too unstable: std_dev=#{std_dev}Ω, mean=#{mean}Ω, readings=#{inspect(readings)}"

      # Mean should still be within tolerance
      assert_in_range(mean, @ch2_expected_resistance, @resistance_tolerance, "Channel 2 mean")
    end

    @tag :rtd
    test "both channels can be read simultaneously", %{slaves: slaves} do
      # Read both channels multiple times
      for _ <- 1..10 do
        assert {:ok, ch1_resistance} = EtherCAT.read(slaves.rtd_inputs, :ch1, :value)
        assert {:ok, ch2_resistance} = EtherCAT.read(slaves.rtd_inputs, :ch2, :value)

        assert_in_range(ch1_resistance, @ch1_expected_resistance, @resistance_tolerance, "Ch1")
        assert_in_range(ch2_resistance, @ch2_expected_resistance, @resistance_tolerance, "Ch2")

        Process.sleep(100)
      end
    end
  end

  describe "Rapid Reading" do
    setup do
      master = Process.whereis(EtherCAT.Master)
      {:ok, slaves} = EtherCAT.configure_hardware(master, TestHardwareConfig.hardware_config())
      {:ok, slaves: slaves}
    end

    @tag :rtd
    test "can read channel 1 rapidly without errors", %{slaves: slaves} do
      # Read 100 times as fast as possible
      readings =
        for _ <- 1..100 do
          assert {:ok, resistance} = EtherCAT.read(slaves.rtd_inputs, :ch1, :value)
          resistance
        end

      # All readings should be valid
      assert length(readings) == 100
      assert Enum.all?(readings, &is_number/1)

      # Calculate mean
      mean = Enum.sum(readings) / length(readings)

      # Mean should be within tolerance
      assert_in_range(mean, @ch1_expected_resistance, @resistance_tolerance, "Ch1 rapid mean")
    end

    @tag :rtd
    test "can read channel 2 rapidly without errors", %{slaves: slaves} do
      # Read 100 times as fast as possible
      readings =
        for _ <- 1..100 do
          assert {:ok, resistance} = EtherCAT.read(slaves.rtd_inputs, :ch2, :value)
          resistance
        end

      # All readings should be valid
      assert length(readings) == 100
      assert Enum.all?(readings, &is_number/1)

      # Calculate mean
      mean = Enum.sum(readings) / length(readings)

      # Mean should be within tolerance
      assert_in_range(mean, @ch2_expected_resistance, @resistance_tolerance, "Ch2 rapid mean")
    end
  end

  describe "Range Validation" do
    setup do
      master = Process.whereis(EtherCAT.Master)
      {:ok, slaves} = EtherCAT.configure_hardware(master, TestHardwareConfig.hardware_config())
      {:ok, slaves: slaves}
    end

    @tag :rtd
    test "channel 1 reading is within physical limits", %{slaves: slaves} do
      {:ok, resistance} = EtherCAT.read(slaves.rtd_inputs, :ch1, :value)

      # Should be a reasonable resistance value (not negative, not impossibly high)
      assert resistance >= 0.0, "Resistance cannot be negative"
      assert resistance < 1000.0, "Resistance unreasonably high"
    end

    @tag :rtd
    test "channel 2 reading is within physical limits", %{slaves: slaves} do
      {:ok, resistance} = EtherCAT.read(slaves.rtd_inputs, :ch2, :value)

      # Should be a reasonable resistance value
      assert resistance >= 0.0, "Resistance cannot be negative"
      assert resistance < 1000.0, "Resistance unreasonably high"
    end

    @tag :rtd
    test "channels read different values (120Ω vs 100Ω)", %{slaves: slaves} do
      {:ok, ch1_resistance} = EtherCAT.read(slaves.rtd_inputs, :ch1, :value)
      {:ok, ch2_resistance} = EtherCAT.read(slaves.rtd_inputs, :ch2, :value)

      # The difference should be approximately 20Ω
      difference = abs(ch1_resistance - ch2_resistance)

      assert difference > 10.0,
             "Channels should read different values: ch1=#{ch1_resistance}Ω, ch2=#{ch2_resistance}Ω"

      assert difference < 30.0,
             "Difference too large: ch1=#{ch1_resistance}Ω, ch2=#{ch2_resistance}Ω"
    end
  end

  # Helper function to assert a value is within range
  defp assert_in_range(actual, expected, tolerance, label) do
    min = expected - tolerance
    max = expected + tolerance

    assert actual >= min and actual <= max,
           "#{label}: expected #{expected}Ω ±#{tolerance}Ω, got #{actual}Ω (range: #{min}Ω - #{max}Ω)"
  end
end
