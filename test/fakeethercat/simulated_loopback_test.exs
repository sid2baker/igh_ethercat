defmodule FakeEtherCAT.SimulatedLoopbackTest do
  use ExUnit.Case, async: false

  @moduletag :fakeethercat
  @moduletag timeout: :infinity

  @moduledoc """
  Dual-master tests using libfakeethercat.

  These tests validate that inverted hardware configs work correctly by running
  two masters simultaneously:
  1. Real master with normal hardware config (master_index: 0)
  2. Emulator master with inverted config (master_index: 1)

  Note: True RtIPC loopback would require both masters using the same master_index
  in separate OS processes, which is not yet implemented. Currently these tests
  verify that:
  - Both masters start and configure successfully
  - Inverted configs are valid
  - Operations complete without errors
  - Basic read/write operations work on both masters
  """

  setup do
    config = SimpleHardwareConfig.hardware_config()
    {:ok, emulator_master, emulator_slaves} = FakeEtherCAT.setup(config)

    # Start real master with normal config
    {:ok, master} = start_supervised({EtherCAT.Master, name: EtherCAT.Master, master_index: 0})
    {:ok, slaves} = EtherCAT.configure_hardware(master, config)

    # Clear all outputs on both masters
    # Real master: clear digital_outputs
    # Emulator master: clear digital_inputs (which are inverted to outputs)
    for ch <- 1..16 do
      pdo = String.to_atom("channel_#{ch}")
      EtherCAT.write(slaves.digital_outputs, pdo, :output, false)
      EtherCAT.write(emulator_slaves.digital_inputs, pdo, :output, false)
    end

    Process.sleep(100)

    {:ok, master: master, slaves: slaves,
          emulator_master: emulator_master, emulator_slaves: emulator_slaves}
  end

  describe "Digital I/O Operations" do

    test "single channel write and read", %{slaves: slaves, emulator_slaves: emulator_slaves} do
      # Write to real master's output
      assert :ok = EtherCAT.write(slaves.digital_outputs, :channel_1, :output, true)
      Process.sleep(50)

      # Read from real master's input (verify operation completes)
      assert {:ok, value} = EtherCAT.read(slaves.digital_inputs, :channel_1, :input)
      assert is_boolean(value)

      # Verify emulator master operations also work (inverted config)
      assert :ok = EtherCAT.write(emulator_slaves.digital_inputs, :channel_1, :output, true)
      Process.sleep(50)
      assert {:ok, value} = EtherCAT.read(emulator_slaves.digital_outputs, :channel_1, :input)
      assert is_boolean(value)
    end

    test "all channels write operations", %{slaves: slaves} do
      # Write to all output channels
      for ch <- 1..16 do
        pdo = String.to_atom("channel_#{ch}")
        assert :ok = EtherCAT.write(slaves.digital_outputs, pdo, :output, true)
      end

      Process.sleep(100)

      # Clear all outputs
      for ch <- 1..16 do
        pdo = String.to_atom("channel_#{ch}")
        assert :ok = EtherCAT.write(slaves.digital_outputs, pdo, :output, false)
      end
    end

    test "all channels read operations", %{slaves: slaves} do
      # Read from all input channels
      for ch <- 1..16 do
        pdo = String.to_atom("channel_#{ch}")
        assert {:ok, value} = EtherCAT.read(slaves.digital_inputs, pdo, :input)
        assert is_boolean(value)
      end
    end

    test "alternating pattern write", %{slaves: slaves} do
      # Set odd channels HIGH, even LOW on real master
      for ch <- 1..16 do
        pdo = String.to_atom("channel_#{ch}")
        assert :ok = EtherCAT.write(slaves.digital_outputs, pdo, :output, rem(ch, 2) == 1)
      end

      Process.sleep(100)

      # Verify reads complete successfully
      for ch <- 1..16 do
        pdo = String.to_atom("channel_#{ch}")
        assert {:ok, value} = EtherCAT.read(slaves.digital_inputs, pdo, :input)
        assert is_boolean(value)
      end
    end

    test "rapid toggling", %{slaves: slaves} do
      # Toggle channel 1 rapidly
      for _iteration <- 1..10 do
        assert :ok = EtherCAT.write(slaves.digital_outputs, :channel_1, :output, true)
        Process.sleep(10)
        assert :ok = EtherCAT.write(slaves.digital_outputs, :channel_1, :output, false)
        Process.sleep(10)
      end

      # Should complete without errors
      assert {:ok, value} = EtherCAT.read(slaves.digital_inputs, :channel_1, :input)
      assert is_boolean(value)
    end

    test "all channels individually", %{slaves: slaves} do
      for active_ch <- 1..16 do
        # Set only this channel HIGH on real master
        for ch <- 1..16 do
          pdo = String.to_atom("channel_#{ch}")
          assert :ok = EtherCAT.write(slaves.digital_outputs, pdo, :output, ch == active_ch)
        end

        Process.sleep(50)

        # Verify reads complete successfully
        for ch <- 1..16 do
          pdo = String.to_atom("channel_#{ch}")
          assert {:ok, value} = EtherCAT.read(slaves.digital_inputs, pdo, :input)
          assert is_boolean(value)
        end
      end
    end
  end

  describe "Configuration and Setup" do
    test "master starts and configures successfully", %{master: master, slaves: slaves} do
      # Reuse master from module setup
      # Should have expected slaves
      assert Map.has_key?(slaves, :digital_outputs)
      assert Map.has_key?(slaves, :digital_inputs)
      assert Map.has_key?(slaves, :coupler)

      # Slaves should be PIDs
      assert is_pid(slaves.digital_outputs)
      assert is_pid(slaves.digital_inputs)
      assert is_pid(slaves.coupler)
    end

    test "emulator master configured successfully", %{emulator_master: emulator_master, emulator_slaves: emulator_slaves} do
      # Verify emulator has expected slaves with inverted config
      assert Map.has_key?(emulator_slaves, :digital_outputs)
      assert Map.has_key?(emulator_slaves, :digital_inputs)
      assert Map.has_key?(emulator_slaves, :coupler)

      # Slaves should be PIDs
      assert is_pid(emulator_slaves.digital_outputs)
      assert is_pid(emulator_slaves.digital_inputs)
      assert is_pid(emulator_slaves.coupler)
    end

    test "inverted config is valid" do
      config = SimpleHardwareConfig.hardware_config()
      inverted = FakeEtherCAT.invert_config(config)

      # Both configs should validate
      assert :ok = EtherCAT.Config.HardwareConfig.validate(config)
      assert :ok = EtherCAT.Config.HardwareConfig.validate(inverted)
    end
  end

  describe "Slave Operations" do
    test "real master slaves are alive", %{slaves: slaves} do
      assert Process.alive?(slaves.digital_outputs)
      assert Process.alive?(slaves.digital_inputs)
      assert Process.alive?(slaves.coupler)
    end

    test "emulator master slaves are alive", %{emulator_slaves: emulator_slaves} do
      assert Process.alive?(emulator_slaves.digital_outputs)
      assert Process.alive?(emulator_slaves.digital_inputs)
      assert Process.alive?(emulator_slaves.coupler)
    end

    test "can query slave state", %{slaves: slaves} do
      # Should be able to get state without crashing
      state = :sys.get_state(slaves.digital_outputs)
      assert state != nil
    end
  end
end
