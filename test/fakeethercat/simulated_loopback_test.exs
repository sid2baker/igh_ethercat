defmodule FakeEtherCAT.SimulatedLoopbackTest do
  use ExUnit.Case, async: false

  @moduletag :fakeethercat
  @moduletag timeout: :infinity

  @moduledoc """
  Simulated hardware tests using libfakeethercat.

  This recreates the hardware tests from the original hardware_config_test.exs
  but uses libfakeethercat instead of physical hardware. Since we don't have
  actual loopback wiring, these tests verify that operations complete without
  errors rather than checking actual data flow.

  Future enhancement: Implement dual-master loopback via RtIPC for true
  data exchange testing.
  """

  setup do
    FakeEtherCAT.setup()
  end

  describe "Digital I/O Operations" do
    setup do
      config = SimpleHardwareConfig.hardware_config()
      {:ok, master} = start_supervised({EtherCAT.Master, [name: EtherCAT.Master]})
      {:ok, slaves} = EtherCAT.configure_hardware(master, config)

      # Clear all outputs
      for ch <- 1..16 do
        pdo = String.to_atom("channel_#{ch}")
        EtherCAT.write(slaves.digital_outputs, pdo, :output, false)
      end

      Process.sleep(100)

      {:ok, slaves: slaves}
    end

    test "single channel write and read", %{slaves: slaves} do
      # Write to output
      assert :ok = EtherCAT.write(slaves.digital_outputs, :channel_1, :output, true)
      Process.sleep(50)

      # Read from input (with fakeethercat, returns default values)
      assert {:ok, value} = EtherCAT.read(slaves.digital_inputs, :channel_1, :input)
      assert is_boolean(value)

      assert :ok = EtherCAT.write(slaves.digital_outputs, :channel_1, :output, false)
      Process.sleep(50)
      assert {:ok, value} = EtherCAT.read(slaves.digital_inputs, :channel_1, :input)
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
      # Set odd channels HIGH, even LOW
      for ch <- 1..16 do
        pdo = String.to_atom("channel_#{ch}")
        assert :ok = EtherCAT.write(slaves.digital_outputs, pdo, :output, rem(ch, 2) == 1)
      end

      Process.sleep(100)

      # Read all input channels
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
        # Set only this channel HIGH
        for ch <- 1..16 do
          pdo = String.to_atom("channel_#{ch}")
          assert :ok = EtherCAT.write(slaves.digital_outputs, pdo, :output, ch == active_ch)
        end

        Process.sleep(50)

        # Verify reads don't crash
        for ch <- 1..16 do
          pdo = String.to_atom("channel_#{ch}")
          assert {:ok, value} = EtherCAT.read(slaves.digital_inputs, pdo, :input)
          assert is_boolean(value)
        end
      end
    end
  end

  describe "Configuration and Setup" do
    test "master starts and configures successfully" do
      config = SimpleHardwareConfig.hardware_config()
      {:ok, master} = start_supervised({EtherCAT.Master, [name: EtherCAT.Master]})
      {:ok, slaves} = EtherCAT.configure_hardware(master, config)

      # Should have expected slaves
      assert Map.has_key?(slaves, :digital_outputs)
      assert Map.has_key?(slaves, :digital_inputs)
      assert Map.has_key?(slaves, :coupler)

      # Slaves should be PIDs
      assert is_pid(slaves.digital_outputs)
      assert is_pid(slaves.digital_inputs)
      assert is_pid(slaves.coupler)
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
    setup do
      config = SimpleHardwareConfig.hardware_config()
      {:ok, master} = start_supervised({EtherCAT.Master, [name: EtherCAT.Master]})
      {:ok, slaves} = EtherCAT.configure_hardware(master, config)

      {:ok, slaves: slaves}
    end

    test "slaves are alive", %{slaves: slaves} do
      assert Process.alive?(slaves.digital_outputs)
      assert Process.alive?(slaves.digital_inputs)
      assert Process.alive?(slaves.coupler)
    end

    test "can query slave state", %{slaves: slaves} do
      # Should be able to get state without crashing
      state = :sys.get_state(slaves.digital_outputs)
      assert state != nil
    end
  end
end
