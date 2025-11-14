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
  """

  setup_all do
    # Skip tests if ETHERCAT_HARDWARE environment variable is not set
    unless System.get_env("ETHERCAT_HARDWARE") == "true" do
      ExUnit.configure(exclude: [:hardware])
      :ok
    else
      :ok
    end
  end

  describe "System Initialization" do
    test "successfully configures EtherCAT system" do
      assert {:ok, system} = EtherCAT.configure_hardware(HardwareConfig)
      assert %EtherCAT.System{} = system
      assert is_pid(system.master)

      # Clean up
      :ok = EtherCAT.stop_system(system)
    end

    test "system transitions to operational state" do
      {:ok, system} = EtherCAT.configure_hardware(HardwareConfig)

      # Give the system time to reach operational state
      Process.sleep(1000)

      # System should be running
      assert Process.alive?(system.master)

      EtherCAT.stop_system(system)
    end
  end

  describe "Slave Detection" do
    setup do
      {:ok, system} = EtherCAT.configure_hardware(HardwareConfig)
      on_exit(fn -> EtherCAT.stop_system(system) end)
      {:ok, system: system}
    end

    test "detects EL1809 digital input slave", %{system: system} do
      assert {:ok, _pid} = EtherCAT.System.find_slave(system, :digital_inputs)
    end

    test "detects EL2809 digital output slave", %{system: system} do
      assert {:ok, _pid} = EtherCAT.System.find_slave(system, :digital_outputs)
    end

    test "detects EL3202 RTD input slave", %{system: system} do
      assert {:ok, _pid} = EtherCAT.System.find_slave(system, :rtd_inputs)
    end

    test "returns error for non-existent slave", %{system: system} do
      assert {:error, :slave_not_found} = EtherCAT.System.find_slave(system, :nonexistent)
    end

    test "all configured slaves are present", %{system: system} do
      # Verify we can find all three slaves
      assert {:ok, _} = EtherCAT.System.find_slave(system, :digital_inputs)
      assert {:ok, _} = EtherCAT.System.find_slave(system, :digital_outputs)
      assert {:ok, _} = EtherCAT.System.find_slave(system, :rtd_inputs)
    end
  end

  describe "Slave Communication" do
    setup do
      {:ok, system} = EtherCAT.configure_hardware(HardwareConfig)
      on_exit(fn -> EtherCAT.stop_system(system) end)
      {:ok, system: system}
    end

    test "can read from digital input slave", %{system: system} do
      # Should be able to read from any channel
      assert {:ok, value} = EtherCAT.read(system, :digital_inputs, :ch1, :input)
      assert is_boolean(value)
    end

    test "can write to digital output slave", %{system: system} do
      # Should be able to write to any channel
      assert :ok = EtherCAT.write(system, :digital_outputs, :ch1, :output, false)
      assert :ok = EtherCAT.write(system, :digital_outputs, :ch1, :output, true)
    end

    test "can read from RTD input slave", %{system: system} do
      # Should be able to read resistance value
      assert {:ok, value} = EtherCAT.read(system, :rtd_inputs, :ch1, :value)
      assert is_number(value)
    end
  end
end
