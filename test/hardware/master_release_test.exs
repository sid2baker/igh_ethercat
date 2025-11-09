defmodule Hardware.MasterReleaseTest do
  use ExUnit.Case, async: false
  require Logger

  @moduledoc """
  Test to verify that the EtherCAT master is properly released after process termination.

  This test:
  1. Starts a master process
  2. Kills the master process abruptly
  3. Waits for kernel module cleanup
  4. Attempts to start a new master to verify release

  This helps determine the minimum safe delay needed between master operations.
  """

  @tag :hardware
  @tag timeout: 30_000
  test "master is released after process kill" do
    Logger.info("=== Master Release Test ===")

    # Step 1: Start first master
    Logger.info("Step 1: Starting first master...")
    {:ok, master1} = EtherCAT.Master.start_link(index: 0)
    Logger.info("First master started: #{inspect(master1)}")

    # Give it a moment to fully initialize
    :timer.sleep(500)

    # Step 2: Kill the master process abruptly (simulate crash)
    Logger.info("Step 2: Killing master process...")
    ref = Process.monitor(master1)
    Process.exit(master1, :kill)

    # Wait for the process to die
    receive do
      {:DOWN, ^ref, :process, ^master1, :killed} ->
        Logger.info("Master process confirmed dead")
    after
      5000 ->
        Logger.error("Master process did not die within 5 seconds!")
        flunk("Master process did not terminate")
    end

    # Step 3: Try different delays to find minimum safe time
    delays = [500, 1000, 1500, 2000, 2500, 3000]

    result =
      Enum.find_value(delays, fn delay ->
        Logger.info("Step 3: Waiting #{delay}ms for kernel cleanup...")
        :timer.sleep(delay)

        Logger.info("Step 4: Attempting to start new master...")

        case EtherCAT.Master.start_link(index: 0) do
          {:ok, master2} ->
            Logger.info("✓ SUCCESS! Master acquired after #{delay}ms delay")
            Logger.info("New master: #{inspect(master2)}")

            # Clean up properly
            GenServer.stop(master2, :normal)
            :timer.sleep(3000)

            {:ok, delay}

          {:error, :failed_to_create_master} ->
            Logger.warning("✗ FAILED: Master still busy after #{delay}ms")
            nil

          {:error, other} ->
            Logger.error("✗ ERROR: Unexpected error: #{inspect(other)}")
            nil
        end
      end)

    case result do
      {:ok, delay} ->
        Logger.info("=== Test Result: Minimum safe delay is #{delay}ms ===")
        assert true

      nil ->
        Logger.error("=== Test Result: Master not released even after 3000ms ===")
        flunk("Master device not released after maximum delay")
    end
  end

  @tag :hardware
  @tag timeout: 30_000
  test "master is released after clean shutdown" do
    Logger.info("=== Master Clean Shutdown Test ===")

    # Step 1: Start first master
    Logger.info("Step 1: Starting first master...")
    {:ok, master1} = EtherCAT.Master.start_link(index: 0)
    Logger.info("First master started: #{inspect(master1)}")

    # Give it a moment to fully initialize
    :timer.sleep(500)

    # Step 2: Clean shutdown using GenServer.stop
    Logger.info("Step 2: Stopping master cleanly...")
    ref = Process.monitor(master1)
    GenServer.stop(master1, :normal)

    # Wait for the process to die
    receive do
      {:DOWN, ^ref, :process, ^master1, :normal} ->
        Logger.info("Master process terminated normally")
    after
      5000 ->
        Logger.error("Master process did not terminate within 5 seconds!")
        flunk("Master process did not terminate")
    end

    # Step 3: Try different delays to find minimum safe time
    delays = [500, 1000, 1500, 2000, 2500, 3000]

    result =
      Enum.find_value(delays, fn delay ->
        Logger.info("Step 3: Waiting #{delay}ms for kernel cleanup...")
        :timer.sleep(delay)

        Logger.info("Step 4: Attempting to start new master...")

        case EtherCAT.Master.start_link(index: 0) do
          {:ok, master2} ->
            Logger.info("✓ SUCCESS! Master acquired after #{delay}ms delay")
            Logger.info("New master: #{inspect(master2)}")

            # Clean up properly
            GenServer.stop(master2, :normal)
            :timer.sleep(3000)

            {:ok, delay}

          {:error, :failed_to_create_master} ->
            Logger.warning("✗ FAILED: Master still busy after #{delay}ms")
            nil

          {:error, other} ->
            Logger.error("✗ ERROR: Unexpected error: #{inspect(other)}")
            nil
        end
      end)

    case result do
      {:ok, delay} ->
        Logger.info("=== Test Result: Minimum safe delay is #{delay}ms ===")
        assert true

      nil ->
        Logger.error("=== Test Result: Master not released even after 3000ms ===")
        flunk("Master device not released after maximum delay")
    end
  end
end
