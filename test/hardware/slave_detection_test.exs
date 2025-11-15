defmodule Hardware.SlaveDetectionTest do
  use ExUnit.Case, async: false

  @moduletag :hardware
  @moduletag timeout: :infinity

  @moduledoc """
  Tests for detecting and verifying the presence of all expected EtherCAT slaves.

  Hardware Requirements:
  - Position 1: EL1809 (16-channel digital input)
  - Position 2: EL2809 (16-channel digital output)
  - Position 3: EL3202 (2-channel RTD input)

  Run with: ETHERCAT_HARDWARE=true mix test --only hardware

  Note: The EtherCAT Master is auto-started by the Application supervision tree.
  """

  describe "System Initialization" do
    test "successfully configures EtherCAT hardware" do
      assert {:ok, slaves} = EtherCAT.configure_hardware(0, TestHardwareConfig.hardware_config())
      assert is_map(slaves)
      assert map_size(slaves) > 0
    end

    test "hardware enters operational state" do
      {:ok, slaves} = EtherCAT.configure_hardware(0, TestHardwareConfig.hardware_config())

      # Give the system time to reach operational state
      Process.sleep(1000)

      # All slave processes should be alive
      Enum.each(slaves, fn {_name, pid} ->
        assert Process.alive?(pid), "Slave #{inspect(_name)} process should be alive"
      end)
    end
  end

  describe "Slave Detection" do
    setup do
      {:ok, slaves} = EtherCAT.configure_hardware(0, TestHardwareConfig.hardware_config())
      {:ok, slaves: slaves}
    end

    test "detects EL1809 digital input slave", %{slaves: slaves} do
      assert Map.has_key?(slaves, :digital_inputs)
      assert is_pid(slaves.digital_inputs)
      assert Process.alive?(slaves.digital_inputs)
    end

    test "detects EL2809 digital output slave", %{slaves: slaves} do
      assert Map.has_key?(slaves, :digital_outputs)
      assert is_pid(slaves.digital_outputs)
      assert Process.alive?(slaves.digital_outputs)
    end

    test "detects EL3202 RTD input slave", %{slaves: slaves} do
      assert Map.has_key?(slaves, :rtd_inputs)
      assert is_pid(slaves.rtd_inputs)
      assert Process.alive?(slaves.rtd_inputs)
    end

    test "all configured slaves are present", %{slaves: slaves} do
      # Verify all three slaves are in the map
      assert Map.has_key?(slaves, :digital_inputs)
      assert Map.has_key?(slaves, :digital_outputs)
      assert Map.has_key?(slaves, :rtd_inputs)

      # Verify all slave processes are alive
      assert Process.alive?(slaves.digital_inputs)
      assert Process.alive?(slaves.digital_outputs)
      assert Process.alive?(slaves.rtd_inputs)
    end
  end

  describe "Slave Communication" do
    setup do
      {:ok, slaves} = EtherCAT.configure_hardware(0, TestHardwareConfig.hardware_config())
      {:ok, slaves: slaves}
    end

    test "can read from digital input slave", %{slaves: slaves} do
      # Should be able to read from any channel
      assert {:ok, value} = EtherCAT.read(slaves.digital_inputs, :ch1, :input)
      assert is_boolean(value)
    end

    test "can write to digital output slave", %{slaves: slaves} do
      # Should be able to write to any channel
      assert :ok = EtherCAT.write(slaves.digital_outputs, :ch1, :output, false)
      assert :ok = EtherCAT.write(slaves.digital_outputs, :ch1, :output, true)
    end

    test "can read from RTD input slave", %{slaves: slaves} do
      # Should be able to read resistance value
      assert {:ok, value} = EtherCAT.read(slaves.rtd_inputs, :ch1, :value)
      assert is_number(value)
    end
  end
end
