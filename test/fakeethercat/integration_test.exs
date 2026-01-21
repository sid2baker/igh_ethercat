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

    :ok = Master.wait_for(:operational)

    # Step 2: Start simulator (subscribes to real master's TX signals)
    {:ok, _sup} = Support.FakeMaster.start_master(peer, Support.HardwareConfig.create(true))
    :ok = :erpc.call(peer.node, Master, :wait_for, [:operational, 5000])

    # Connect simulator's digital_outputs to digital_inputs for loopback
    Support.FakeMaster.connect(peer, :digital_outputs, :digital_inputs)

    # Step 3: Restart real master (subscribes to simulator's TX signals)
    stop_supervised(:real_master)

    {:ok, _} =
      start_supervised(
        {EtherCAT, [master_index: 0, hardware_config: Support.HardwareConfig.create(false)]},
        id: :real_master
      )

    :ok = Master.wait_for(:operational)

    :ok
  end

  test "RtIPC loopback: write to digital_outputs, wait for digital_inputs" do
    EtherCAT.subscribe_pdo_entry({:digital_inputs, :channel_1, :input})
    EtherCAT.subscribe_pdo_entry({:digital_inputs, :channel_4, :input})
    EtherCAT.subscribe_pdo_entry({:digital_inputs, :channel_9, :input})
    EtherCAT.subscribe_pdo_entry({:digital_inputs, :channel_12, :input})

    EtherCAT.write_pdo_entry({:digital_outputs, :channel_1, :output}, 1)
    assert_receive {:ec_update, {:digital_inputs, :channel_1, :input}, 1}
    EtherCAT.write_pdo_entry({:digital_outputs, :channel_4, :output}, 1)
    assert_receive {:ec_update, {:digital_inputs, :channel_4, :input}, 1}
    EtherCAT.write_pdo_entry({:digital_outputs, :channel_9, :output}, 1)
    assert_receive {:ec_update, {:digital_inputs, :channel_9, :input}, 1}
    EtherCAT.write_pdo_entry({:digital_outputs, :channel_12, :output}, 1)
    assert_receive {:ec_update, {:digital_inputs, :channel_12, :input}, 1}
  end
end
