defmodule FakeEtherCAT.IntegrationTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Master

  @moduledoc """
  Integration test for EtherCAT Master using libfakeethercat with RtIPC loopback.

  ## Test Architecture

  Two EtherCAT masters connected via RtIPC shared memory:

  ```
  Real Master (this process)         Simulator (peer node)
  FAKE_EC_NAME=FakeEtherCAT          FAKE_EC_NAME=Simulator
  ┌─────────────────────┐            ┌─────────────────────┐
  │ EL2809 (DO)         │            │ EL2809 (DO inverted)│
  │   SM0/SM1: OUTPUT ──┼── RtIPC ──►│   SM0/SM1: INPUT    │
  │                     │            │                     │
  │ EL1809 (DI)         │            │ EL1809 (DI inverted)│
  │   SM3: INPUT    ◄───┼── RtIPC ──┤   SM3: OUTPUT       │
  └─────────────────────┘            └─────────────────────┘
  ```

  The simulator inverts sync manager directions and uses HardwareConnection
  to forward values between digital_outputs → digital_inputs, creating a
  complete loopback path.

  ## RtIPC Startup Order

  RtIPC requires a specific startup sequence for bidirectional communication:
  1. Real master starts first (publishes TX signals to conf file)
  2. Simulator starts (publishes TX signals AND subscribes to real master's)
  3. Real master restarts (subscribes to simulator's TX signals)
  """

  @fake_ec_homedir "/tmp/FakeEtherCAT"

  setup_all do
    File.rm_rf!(@fake_ec_homedir)
    File.mkdir_p!(@fake_ec_homedir)

    peer = Application.get_env(:ethercat, :fake_master)

    # Step 1: Start real master first (publishes TX signals)
    {:ok, _} =
      start_supervised(
        {EtherCAT, [master_index: 0, hardware_config: Support.HardwareConfig.create(false)]},
        id: :real_master
      )

    Process.sleep(500)

    # Step 2: Start simulator (subscribes to real master's TX signals)
    {:ok, _sup} = Support.FakeMaster.start_master(peer, Support.HardwareConfig.create(true))
    Process.sleep(500)

    # Connect simulator's digital_outputs to digital_inputs for loopback
    Support.FakeMaster.connect(peer, :digital_outputs, :digital_inputs)

    # Step 3: Restart real master (subscribes to simulator's TX signals)
    stop_supervised(:real_master)
    Process.sleep(200)

    {:ok, _} =
      start_supervised(
        {EtherCAT, [master_index: 0, hardware_config: Support.HardwareConfig.create(false)]},
        id: :real_master
      )

    Process.sleep(2000)

    {:ok, peer: peer}
  end

  test "real master reaches operational state" do
    {state, _data} = :sys.get_state(EtherCAT.Master)
    assert state == :operational
  end

  test "RtIPC loopback: write to digital_outputs, read from digital_inputs", %{peer: _peer} do
    # Reset to known state
    EtherCAT.write_pdo_entry({:digital_outputs, :channel_1, :output}, 0)
    Process.sleep(200)

    value_before = EtherCAT.read_pdo_entry({:digital_inputs, :channel_1, :input})
    IO.puts("=== Writing to local digital_outputs ===")
    EtherCAT.write_pdo_entry({:digital_outputs, :channel_1, :output}, 1)
    Process.sleep(200)

    value_after = EtherCAT.read_pdo_entry({:digital_inputs, :channel_1, :input})
    IO.puts("=== Local digital_inputs before: #{value_before}, after: #{value_after} ===")
    assert value_before == 0
    assert value_after == 1
  end

  test "read/write pdo via RtIPC loopback" do
    # Write to real master's digital outputs
    :ok = Master.write_pdo_entry({:digital_outputs, :channel_1, :output}, <<1>>)

    # Give RtIPC time to propagate through cyclic thread
    Process.sleep(100)

    # Read back what we wrote
    {:ok, value} = Master.read_pdo_entry({:digital_outputs, :channel_1, :output})

    assert value == <<1>>
  end

  test "stop thread" do
    :ok = Master.stop_thread()
  end
end
