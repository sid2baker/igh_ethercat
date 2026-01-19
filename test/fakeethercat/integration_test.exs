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

    await_master_state(:operational)

    # Step 2: Start simulator (subscribes to real master's TX signals)
    {:ok, _sup} = Support.FakeMaster.start_master(peer, Support.HardwareConfig.create(true))
    await_master_state(:operational, peer)

    # Connect simulator's digital_outputs to digital_inputs for loopback
    Support.FakeMaster.connect(peer, :digital_outputs, :digital_inputs)

    # Step 3: Restart real master (subscribes to simulator's TX signals)
    stop_supervised(:real_master)

    {:ok, _} =
      start_supervised(
        {EtherCAT, [master_index: 0, hardware_config: Support.HardwareConfig.create(false)]},
        id: :real_master
      )

    await_master_state(:operational)

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

  # Waits for the local master to reach the expected state
  defp await_master_state(expected_state, timeout \\ 5000)

  defp await_master_state(expected_state, timeout) when is_integer(timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    poll_until(deadline, fn ->
      {state, _data} = :sys.get_state(Master)
      state == expected_state
    end)
  end

  # Waits for the remote master (on peer node) to reach the expected state
  defp await_master_state(expected_state, %{node: node} = peer) do
    await_master_state(expected_state, peer, 5000)
  end

  defp await_master_state(expected_state, %{node: node}, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    poll_until(deadline, fn ->
      {state, _data} = :erpc.call(node, :sys, :get_state, [Master])
      state == expected_state
    end)
  end

  # Waits for a PDO entry to reach the expected value
  defp await_pdo_value(pdo_entry, expected_value, timeout \\ 1000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    poll_until(deadline, fn ->
      EtherCAT.read_pdo_entry(pdo_entry) == expected_value
    end)
  end

  # Polls a condition until it returns true or timeout is reached
  defp poll_until(deadline, condition) do
    if condition.() do
      :ok
    else
      now = System.monotonic_time(:millisecond)

      if now >= deadline do
        raise "Timeout waiting for condition"
      else
        Process.sleep(10)
        poll_until(deadline, condition)
      end
    end
  end
end
