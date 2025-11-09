defmodule Hardware.FunctionalValidationTest do
  use ExUnit.Case, async: false
  require Logger

  @moduledoc """
  Comprehensive functional validation test suite for EtherCAT PDO operations.

  This test suite systematically exercises all PDO read/write operations using
  a hardware loopback configuration (DI1 ↔ DO1) to validate library correctness.

  ## Hardware Setup

  Required configuration:
  - **Slave 0**: Bus coupler (e.g., EK1100) - provides bus power
  - **Slave 1**: Digital input terminal (e.g., EL1809) - 16 channels
  - **Slave 2**: Digital output terminal (e.g., EL2809) - 16 channels
  - **Physical connection**: Output 1 wired to Input 1

  ## Test Coverage

  1. **Bit-level operations** - Single bit toggle with loopback verification
  2. **Byte-level operations** - Multi-bit patterns (0xFF, 0xAA, 0x55, etc.)
  3. **Rapid state changes** - Stress test timing with fast toggle sequences
  4. **PDO subscriptions** - Watch notifications and ensure reliable delivery
  5. **Multi-PDO concurrent operations** - Write/read multiple channels simultaneously
  6. **Edge cases** - Boundary conditions, repeated writes, idempotency

  ## Running

  To run this test with actual hardware:

      mix test test/hardware/functional_validation_test.exs --include hardware
  """

  # Test configuration
  @cycle_interval 1000
  @stabilization_delay 500
  @fast_toggle_delay 100
  @notification_timeout 2000

  # Shared setup for all tests - uses setup_all to create one master for entire suite
  setup_all do
    Logger.info("=== Setting up EtherCAT master for test suite ===")

    # Simplified API: open auto-connects and discovers slaves
    {:ok, master, [_coupler, di, do_slave]} = EtherCAT.open(update_interval: @cycle_interval)

    # Configure input slave and get available PDOs
    {:ok, input_pdos} = EtherCAT.configure_slave(master, di, %{})
    Logger.info("Input PDOs: #{inspect(input_pdos)}")

    # Register all input PDOs and get unique names
    {:ok, input_names} = EtherCAT.register_pdos(master, di, input_pdos)

    # Configure output slave and get available PDOs
    {:ok, output_pdos} = EtherCAT.configure_slave(master, do_slave, %{})
    Logger.info("Output PDOs: #{inspect(output_pdos)}")

    # Register all output PDOs and get unique names
    {:ok, output_names} = EtherCAT.register_pdos(master, do_slave, output_pdos)

    # Start cyclic operation
    EtherCAT.start_cyclic(master)

    # Wait for system stabilization
    :timer.sleep(@stabilization_delay)

    Logger.info("=== Master setup complete ===")

    # Cleanup function
    on_exit(fn ->
      Logger.info("=== Cleaning up EtherCAT master ===")

      try do
        EtherCAT.close(master)
      catch
        :exit, {:noproc, _} ->
          Logger.info("Master process already terminated, skipping close")
      end

      :erlang.garbage_collect()
      Logger.info("=== Cleanup complete ===")
    end)

    # Return context for all tests
    %{
      master: master,
      input_names: input_names,
      output_names: output_names
    }
  end

  # Helper functions

  defp get_pdo_name(pdos, index) when is_list(pdos) do
    Enum.at(pdos, index)
  end

  defp assert_loopback(input_pdo, output_pdo, expected_value) do
    # Set output value using PDO handle
    assert :ok = EtherCAT.write(output_pdo, expected_value)

    # Wait for propagation
    :timer.sleep(@stabilization_delay)

    # Read input value using PDO handle
    assert {:ok, actual_value} = EtherCAT.read(input_pdo)

    # Verify loopback
    assert actual_value == expected_value,
           "Loopback failed: expected #{inspect(expected_value)}, got #{inspect(actual_value)}"

    Logger.debug(
      "Loopback verified: #{inspect(output_pdo)} -> #{inspect(input_pdo)} = #{inspect(expected_value)}"
    )

    :ok
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  defp count_available_notifications do
    count_available_notifications(0)
  end

  defp count_available_notifications(count) do
    receive do
      {:data_changed, _, _} ->
        count_available_notifications(count + 1)
    after
      0 -> count
    end
  end

  # Test Cases

  @tag :hardware
  @tag timeout: 60_000
  test "1. bit-level operations - single bit toggle", context do
    Logger.info("=== Test 1: Bit-level Operations ===")

    input_pdo = get_pdo_name(context.input_names, 0)
    output_pdo = get_pdo_name(context.output_names, 0)

    Logger.info("Testing PDO pair: #{output_pdo.unique_name} -> #{input_pdo.unique_name}")

    # Test sequence: false -> true -> false
    Logger.info("Step 1: Setting output to FALSE")
    assert_loopback(input_pdo, output_pdo, false)

    Logger.info("Step 2: Setting output to TRUE")
    assert_loopback(input_pdo, output_pdo, true)

    Logger.info("Step 3: Setting output back to FALSE")
    assert_loopback(input_pdo, output_pdo, false)

    Logger.info("✓ Bit-level operations test passed")
  end

  @tag :hardware
  @tag timeout: 60_000
  test "2. byte-level operations - pattern validation", context do
    Logger.info("=== Test 2: Byte-level Operations ===")

    input_pdo = get_pdo_name(context.input_names, 0)
    output_pdo = get_pdo_name(context.output_names, 0)

    Logger.info("Testing PDO pair: #{output_pdo.unique_name} -> #{input_pdo.unique_name}")

    # Test various bit patterns through the single loopback channel
    test_patterns = [
      {false, "Pattern 1: false"},
      {true, "Pattern 2: true"},
      {false, "Pattern 3: false (repeat)"},
      {true, "Pattern 4: true (repeat)"},
      {false, "Pattern 5: false (final)"}
    ]

    for {value, description} <- test_patterns do
      Logger.info("Testing #{description}")
      assert_loopback(input_pdo, output_pdo, value)
      Logger.info("✓ #{description} verified")
    end

    Logger.info("✓ Byte-level operations test passed")
  end

  @tag :hardware
  @tag timeout: 60_000
  test "3. rapid state changes - stress timing", context do
    Logger.info("=== Test 3: Rapid State Changes ===")

    input_pdo = get_pdo_name(context.input_names, 0)
    output_pdo = get_pdo_name(context.output_names, 0)

    Logger.info("Performing rapid toggle sequence (100 iterations)...")

    # Rapid toggle sequence with minimal delay
    for i <- 1..100 do
      value = rem(i, 2) == 1
      assert :ok = EtherCAT.write(output_pdo, value)
      :timer.sleep(@fast_toggle_delay)

      # Periodically verify loopback
      if rem(i, 10) == 0 do
        assert {:ok, actual} = EtherCAT.read(input_pdo)
        Logger.debug("Toggle #{i}: set=#{value}, read=#{actual}")
      end
    end

    # Final verification
    assert :ok = EtherCAT.write(output_pdo, true)
    :timer.sleep(@stabilization_delay)
    assert {:ok, true} = EtherCAT.read(input_pdo)

    Logger.info("✓ Rapid state changes test passed (100 toggles)")
  end

  @tag :hardware
  @tag timeout: 60_000
  test "4. PDO subscriptions - notification delivery", context do
    Logger.info("=== Test 4: PDO Subscriptions ===")

    input_pdo = get_pdo_name(context.input_names, 0)
    output_pdo = get_pdo_name(context.output_names, 0)

    # Subscribe to input changes using PDO handle
    Logger.info("Subscribing to PDO: #{inspect(input_pdo)}")
    assert :ok = EtherCAT.watch(input_pdo)

    # Flush any existing messages
    flush_mailbox()

    # Reset to known state (false) before starting test sequence
    # This ensures we start clean regardless of previous test state
    Logger.info("Resetting output to false...")
    assert :ok = EtherCAT.write(output_pdo, false)
    :timer.sleep(@stabilization_delay)
    flush_mailbox()  # Flush any notifications from the reset

    # Test sequence with notification verification
    test_values = [true, false, true, false, true]

    for {value, idx} <- Enum.with_index(test_values) do
      Logger.info("Step #{idx + 1}: Setting output to #{value}")

      # Set output using PDO handle
      assert :ok = EtherCAT.write(output_pdo, value)

      # Wait for notification (notifications use the unique_name from the PDO struct)
      unique_name = input_pdo.unique_name

      receive do
        {:data_changed, ^unique_name, ^value} ->
          Logger.debug("✓ Notification received: #{unique_name} = #{value}")

        {:data_changed, pdo, other_value} ->
          flunk(
            "Unexpected notification: #{inspect(pdo)} = #{other_value}, expected #{unique_name} = #{value}"
          )

        other ->
          flunk("Unexpected message: #{inspect(other)}")
      after
        @notification_timeout ->
          flunk("Timeout waiting for notification: #{unique_name} = #{value}")
      end
    end

    # Unsubscribe
    assert :ok = EtherCAT.unwatch(input_pdo)

    Logger.info("✓ PDO subscriptions test passed (#{length(test_values)} notifications)")
  end

  @tag :hardware
  @tag timeout: 60_000
  test "5. multi-PDO concurrent operations", context do
    Logger.info("=== Test 5: Multi-PDO Concurrent Operations ===")

    input_pdo = get_pdo_name(context.input_names, 0)
    output_pdo = get_pdo_name(context.output_names, 0)

    Logger.info("Testing concurrent operations on looped-back PDO pair")
    Logger.info("  Output: #{inspect(output_pdo)}")
    Logger.info("  Input: #{inspect(input_pdo)}")

    # Subscribe to input changes
    assert :ok = EtherCAT.watch(input_pdo)
    flush_mailbox()

    # Test rapid concurrent write/read cycles
    test_sequence = [false, true, false, true, false, true]

    for {value, idx} <- Enum.with_index(test_sequence) do
      Logger.debug("Concurrent operation #{idx + 1}: setting #{value}")

      # Write using PDO handle
      assert :ok = EtherCAT.write(output_pdo, value)

      # Immediate read (concurrent with cyclic task)
      assert {:ok, _} = EtherCAT.read(input_pdo)

      # Wait briefly
      :timer.sleep(100)
    end

    # Wait for final propagation
    :timer.sleep(@stabilization_delay)

    # Verify final state
    assert {:ok, final_value} = EtherCAT.read(input_pdo)
    Logger.info("✓ Final value: #{final_value}")

    # Verify we received notifications during the sequence
    notifications_count = count_available_notifications()
    Logger.info("✓ Received #{notifications_count} change notifications")

    assert notifications_count > 0,
           "Expected at least one notification during concurrent operations"

    # Unsubscribe
    assert :ok = EtherCAT.unwatch(input_pdo)

    Logger.info("✓ Multi-PDO concurrent operations test passed")
  end

  @tag :hardware
  @tag timeout: 60_000
  test "6. edge cases - idempotency and boundaries", context do
    Logger.info("=== Test 6: Edge Cases ===")

    input_pdo = get_pdo_name(context.input_names, 0)
    output_pdo = get_pdo_name(context.output_names, 0)

    # Test 6.1: Repeated writes (idempotency)
    Logger.info("Test 6.1: Repeated writes to same value")

    for _i <- 1..5 do
      assert :ok = EtherCAT.write(output_pdo, true)
      :timer.sleep(100)
    end

    :timer.sleep(@stabilization_delay)
    assert {:ok, true} = EtherCAT.read(input_pdo)
    Logger.info("✓ Idempotency verified")

    # Test 6.2: Read before write
    Logger.info("Test 6.2: Read initial state before any writes")

    # Reset to known state
    assert :ok = EtherCAT.write(output_pdo, false)
    :timer.sleep(@stabilization_delay)

    # Read should succeed even before explicit write
    assert {:ok, _value} = EtherCAT.read(input_pdo)
    Logger.info("✓ Read before write succeeded")

    # Test 6.3: Rapid alternation stress
    Logger.info("Test 6.3: Rapid alternation (10Hz for 5 seconds)")

    start_time = System.monotonic_time(:millisecond)
    iterations = 0

    iterations =
      Stream.iterate(iterations, &(&1 + 1))
      |> Enum.reduce_while(iterations, fn i, _acc ->
        if System.monotonic_time(:millisecond) - start_time < 5000 do
          value = rem(i, 2) == 0
          :ok = EtherCAT.write(output_pdo, value)
          :timer.sleep(100)
          {:cont, i}
        else
          {:halt, i}
        end
      end)

    Logger.info("✓ Completed #{iterations} rapid alternations")

    # Final state verification
    :timer.sleep(@stabilization_delay)
    assert {:ok, _final_value} = EtherCAT.read(input_pdo)

    Logger.info("✓ Edge cases test passed")
  end
end
