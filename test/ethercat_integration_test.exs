defmodule EtherCATIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: :infinity

  # Hardware configuration
  # Position 0: EK1100 Coupler
  # Position 1: EL1809 (16-channel digital input)
  # Position 2: EL2809 (16-channel digital output)
  # Position 3: EL3202 (2-channel analog input)
  # Wiring: All EL2809 outputs connected to corresponding EL1809 inputs

  setup_all do
    # This test requires actual hardware
    # Skip if ETHERCAT_HARDWARE environment variable is not set
    unless System.get_env("ETHERCAT_HARDWARE") == "true" do
      {:ok, skip: true}
    else
      {:ok, skip: false}
    end
  end

  describe "Hardware Configuration" do
    test "validates TestHardwareConfig module exists and compiles" do
      assert Code.ensure_loaded?(TestHardwareConfig)
      config = TestHardwareConfig.hardware_config()
      assert %EtherCAT.Config.HardwareConfig{} = config
      assert length(config.domains) == 2
      assert length(config.slaves) == 3
    end

    test "config has correct domain definitions" do
      config = TestHardwareConfig.hardware_config()

      assert Enum.find(config.domains, &(&1.name == :fast_loop))
      assert Enum.find(config.domains, &(&1.name == :slow_loop))

      fast = Enum.find(config.domains, &(&1.name == :fast_loop))
      assert fast.interval == 1

      slow = Enum.find(config.domains, &(&1.name == :slow_loop))
      assert slow.interval == 10
    end

    test "config has correct slave definitions" do
      config = TestHardwareConfig.hardware_config()

      digital_in = Enum.find(config.slaves, &(&1.name == :digital_inputs))
      assert digital_in.position == 1
      assert digital_in.driver == EtherCAT.Drivers.EL1809
      assert digital_in.expected.vendor == 0x00000002
      assert digital_in.expected.product == 0x07093052
      assert length(digital_in.entries) == 16

      digital_out = Enum.find(config.slaves, &(&1.name == :digital_outputs))
      assert digital_out.position == 2
      assert digital_out.driver == EtherCAT.Drivers.EL2809
      assert digital_out.expected.vendor == 0x00000002
      assert digital_out.expected.product == 0x0AF93052
      assert length(digital_out.entries) == 16

      analog_in = Enum.find(config.slaves, &(&1.name == :analog_inputs))
      assert analog_in.position == 3
      assert analog_in.driver == EtherCAT.Drivers.EL3202
      assert analog_in.expected.vendor == 0x00000002
      assert analog_in.expected.product == 0x0C5A3052
      assert length(analog_in.entries) == 4
    end
  end

  describe "System Initialization (requires hardware)", %{skip: skip} do
    @tag skip: skip
    test "opens EtherCAT system successfully" do
      assert {:ok, system} = EtherCAT.open(TestHardwareConfig)
      assert %EtherCAT.System{} = system
      assert is_pid(system.master)

      # Clean up
      :ok = EtherCAT.close(system)
    end

    @tag skip: skip
    test "system has correct slave configuration" do
      {:ok, system} = EtherCAT.open(TestHardwareConfig)

      # Verify we can find all configured slaves
      assert {:ok, _pid} = EtherCAT.System.find_slave(system, :digital_inputs)
      assert {:ok, _pid} = EtherCAT.System.find_slave(system, :digital_outputs)
      assert {:ok, _pid} = EtherCAT.System.find_slave(system, :analog_inputs)

      # Verify unknown slave returns error
      assert {:error, :slave_not_found} = EtherCAT.System.find_slave(system, :nonexistent)

      EtherCAT.close(system)
    end
  end

  describe "Digital I/O Loopback Testing (requires hardware)", %{skip: skip} do
    setup %{skip: skip} do
      if skip do
        :ok
      else
        {:ok, system} = EtherCAT.open(TestHardwareConfig)
        on_exit(fn -> EtherCAT.close(system) end)
        {:ok, system: system}
      end
    end

    @tag skip: skip
    test "writes and reads single digital channel", %{system: system} do
      # Test channel 1
      # Write HIGH to output
      :ok = EtherCAT.write(system, :digital_outputs, :outputs, :ch1, true)

      # Allow some time for signal propagation
      Process.sleep(50)

      # Read corresponding input
      assert {:ok, true} = EtherCAT.read(system, :digital_inputs, :inputs, :ch1)

      # Write LOW to output
      :ok = EtherCAT.write(system, :digital_outputs, :outputs, :ch1, false)
      Process.sleep(50)

      # Read corresponding input
      assert {:ok, false} = EtherCAT.read(system, :digital_inputs, :inputs, :ch1)
    end

    @tag skip: skip
    test "tests all 16 digital channels in loopback", %{system: system} do
      # Test each channel independently
      for ch <- 1..16 do
        ch_atom = String.to_atom("ch#{ch}")

        # Set this channel HIGH, all others LOW
        for i <- 1..16 do
          ch_i = String.to_atom("ch#{i}")
          :ok = EtherCAT.write(system, :digital_outputs, :outputs, ch_i, i == ch)
        end

        Process.sleep(50)

        # Verify this channel reads HIGH, all others LOW
        for i <- 1..16 do
          ch_i = String.to_atom("ch#{i}")
          expected = i == ch

          assert {:ok, ^expected} = EtherCAT.read(system, :digital_inputs, :inputs, ch_i),
                 "Channel #{i} expected #{expected} when ch#{ch} is active"
        end
      end

      # Clear all outputs
      for ch <- 1..16 do
        ch_atom = String.to_atom("ch#{ch}")
        :ok = EtherCAT.write(system, :digital_outputs, :outputs, ch_atom, false)
      end
    end

    @tag skip: skip
    test "tests pattern writing across multiple channels", %{system: system} do
      # Test binary counter pattern (0-255)
      for pattern <- 0..255 do
        # Write pattern to first 8 channels
        for bit <- 0..7 do
          ch_atom = String.to_atom("ch#{bit + 1}")
          value = (pattern &&& 1 <<< bit) != 0
          :ok = EtherCAT.write(system, :digital_outputs, :outputs, ch_atom, value)
        end

        Process.sleep(50)

        # Read back and verify pattern
        for bit <- 0..7 do
          ch_atom = String.to_atom("ch#{bit + 1}")
          expected = (pattern &&& 1 <<< bit) != 0

          assert {:ok, ^expected} = EtherCAT.read(system, :digital_inputs, :inputs, ch_atom),
                 "Pattern #{pattern}, bit #{bit} mismatch"
        end
      end
    end
  end

  describe "Analog Input Testing (requires hardware)", %{skip: skip} do
    setup %{skip: skip} do
      if skip do
        :ok
      else
        {:ok, system} = EtherCAT.open(TestHardwareConfig)
        on_exit(fn -> EtherCAT.close(system) end)
        {:ok, system: system}
      end
    end

    @tag skip: skip
    test "reads analog values from both channels", %{system: system} do
      # Read channel 1 temperature
      assert {:ok, temp1} = EtherCAT.read(system, :analog_inputs, :ch1, :value)
      assert is_float(temp1) or is_integer(temp1)

      # Sanity check: room temperature should be between -50°C and 150°C
      assert temp1 >= -50.0 and temp1 <= 150.0,
             "Temperature reading out of expected range: #{temp1}°C"

      # Read channel 2 temperature
      assert {:ok, temp2} = EtherCAT.read(system, :analog_inputs, :ch2, :value)
      assert is_float(temp2) or is_integer(temp2)

      assert temp2 >= -50.0 and temp2 <= 150.0,
             "Temperature reading out of expected range: #{temp2}°C"
    end

    @tag skip: skip
    test "reads error flags from both channels", %{system: system} do
      # Read error flags (should be false/0 if sensors are connected properly)
      assert {:ok, error1} = EtherCAT.read(system, :analog_inputs, :ch1, :error)
      assert {:ok, error2} = EtherCAT.read(system, :analog_inputs, :ch2, :error)

      # Error flags are typically boolean or integer
      assert is_boolean(error1) or is_integer(error1)
      assert is_boolean(error2) or is_integer(error2)
    end

    @tag skip: skip
    test "monitors temperature stability over time", %{system: system} do
      # Read temperature 10 times over 1 second
      readings =
        for _ <- 1..10 do
          {:ok, temp} = EtherCAT.read(system, :analog_inputs, :ch1, :value)
          Process.sleep(100)
          temp
        end

      # Calculate variance - temperature should be relatively stable
      mean = Enum.sum(readings) / length(readings)

      variance =
        Enum.map(readings, fn x -> (x - mean) * (x - mean) end)
        |> Enum.sum()
        |> Kernel./(length(readings))

      std_dev = :math.sqrt(variance)

      # Standard deviation should be less than 5°C for stable ambient temperature
      assert std_dev < 5.0,
             "Temperature readings too unstable: std_dev=#{std_dev}°C, readings=#{inspect(readings)}"
    end
  end

  describe "Error Handling", %{skip: skip} do
    setup %{skip: skip} do
      if skip do
        :ok
      else
        {:ok, system} = EtherCAT.open(TestHardwareConfig)
        on_exit(fn -> EtherCAT.close(system) end)
        {:ok, system: system}
      end
    end

    @tag skip: skip
    test "reading from non-existent slave returns error", %{system: system} do
      assert {:error, _reason} = EtherCAT.read(system, :nonexistent_slave, :ch1, :value)
    end

    @tag skip: skip
    test "writing to non-existent slave returns error", %{system: system} do
      assert {:error, _reason} = EtherCAT.write(system, :nonexistent_slave, :ch1, :value, 42)
    end

    @tag skip: skip
    test "reading non-existent entry returns error", %{system: system} do
      assert {:error, _reason} =
               EtherCAT.read(system, :digital_inputs, :inputs, :nonexistent_entry)
    end
  end
end
