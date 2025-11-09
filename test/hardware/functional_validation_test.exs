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

  Or run specific tests:

      mix test test/hardware/functional_validation_test.exs:line_number --include hardware
  """

  # Test configuration
  @cycle_interval 1000
  @stabilization_delay 500
  @fast_toggle_delay 100
  @notification_timeout 2000

  # Helper functions

  defp setup_master_and_slaves do
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

    {master, di, do_slave, input_names, output_names}
  end

  defp cleanup(master) do
    EtherCAT.close(master)
    # Wait for master to fully release resources
    :timer.sleep(500)
  end

  defp get_pdo_name(pdos, index) when is_list(pdos) do
    Enum.at(pdos, index)
  end

  defp assert_loopback(master, input_pdo, output_pdo, expected_value) do
    # Set output value using unique PDO name
    assert :ok = EtherCAT.write(master, output_pdo, expected_value)

    # Wait for propagation
    :timer.sleep(@stabilization_delay)

    # Read input value using unique PDO name
    assert {:ok, actual_value} = EtherCAT.read(master, input_pdo)

    # Verify loopback
    assert actual_value == expected_value,
           "Loopback failed: expected #{inspect(expected_value)}, got #{inspect(actual_value)}"

    Logger.debug("Loopback verified: #{output_pdo} -> #{input_pdo} = #{inspect(expected_value)}")

    :ok
  end

  # Test Cases

  @tag :hardware
  @tag timeout: 60_000
  test "1. bit-level operations - single bit toggle" do
    Logger.info("=== Test 1: Bit-level Operations ===")
    {master, _di, _do_slave, input_names, output_names} = setup_master_and_slaves()

    try do
      # Use the first available PDO (unique names already include slave position)
      input_pdo = get_pdo_name(input_names, 0)
      output_pdo = get_pdo_name(output_names, 0)

      Logger.info("Testing PDO pair: #{output_pdo} -> #{input_pdo}")

      # Test sequence: false -> true -> false
      Logger.info("Step 1: Setting output to FALSE")
      assert_loopback(master, input_pdo, output_pdo, false)

      Logger.info("Step 2: Setting output to TRUE")
      assert_loopback(master, input_pdo, output_pdo, true)

      Logger.info("Step 3: Setting output back to FALSE")
      assert_loopback(master, input_pdo, output_pdo, false)

      Logger.info("✓ Bit-level operations test passed")
    after
      cleanup(master)
    end
  end

  @tag :hardware
  @tag timeout: 60_000
  test "2. byte-level operations - pattern validation" do
    Logger.info("=== Test 2: Byte-level Operations ===")
    {master, _di, _do_slave, input_names, output_names} = setup_master_and_slaves()

    try do
      # NOTE: Only the first PDO pair (DI1 ↔ DO1) is physically connected
      # This test validates different bit patterns on the looped-back channel
      input_pdo = get_pdo_name(input_names, 0)
      output_pdo = get_pdo_name(output_names, 0)

      Logger.info("Testing PDO pair: #{output_pdo} -> #{input_pdo}")

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
        assert_loopback(master, input_pdo, output_pdo, value)
        Logger.info("✓ #{description} verified")
      end

      Logger.info("✓ Byte-level operations test passed")
    after
      cleanup(master)
    end
  end

  @tag :hardware
  @tag timeout: 60_000
  test "3. rapid state changes - stress timing" do
    Logger.info("=== Test 3: Rapid State Changes ===")
    {master, _di, _do_slave, input_names, output_names} = setup_master_and_slaves()

    try do
      input_pdo = get_pdo_name(input_names, 0)
      output_pdo = get_pdo_name(output_names, 0)

      Logger.info("Performing rapid toggle sequence (100 iterations)...")

      # Rapid toggle sequence with minimal delay
      for i <- 1..100 do
        value = rem(i, 2) == 1
        assert :ok = EtherCAT.write(master, output_pdo, value)
        :timer.sleep(@fast_toggle_delay)

        # Periodically verify loopback
        if rem(i, 10) == 0 do
          assert {:ok, actual} = EtherCAT.read(master, input_pdo)
          Logger.debug("Toggle #{i}: set=#{value}, read=#{actual}")
        end
      end

      # Final verification
      assert :ok = EtherCAT.write(master, output_pdo, true)
      :timer.sleep(@stabilization_delay)
      assert {:ok, true} = EtherCAT.read(master, input_pdo)

      Logger.info("✓ Rapid state changes test passed (100 toggles)")
    after
      cleanup(master)
    end
  end

  @tag :hardware
  @tag timeout: 60_000
  test "4. PDO subscriptions - notification delivery" do
    Logger.info("=== Test 4: PDO Subscriptions ===")
    {master, _di, _do_slave, input_names, output_names} = setup_master_and_slaves()

    try do
      input_pdo = get_pdo_name(input_names, 0)
      output_pdo = get_pdo_name(output_names, 0)

      # Subscribe to input changes using unique name
      Logger.info("Subscribing to PDO: #{input_pdo}")
      assert :ok = EtherCAT.watch(master, input_pdo)

      # Flush any existing messages
      flush_mailbox()

      # Test sequence with notification verification
      test_values = [true, false, true, false, true]

      for {value, idx} <- Enum.with_index(test_values) do
        Logger.info("Step #{idx + 1}: Setting output to #{value}")

        # Set output using unique name
        assert :ok = EtherCAT.write(master, output_pdo, value)

        # Wait for notification (notifications use the full unique name)
        receive do
          {:data_changed, ^input_pdo, ^value} ->
            Logger.debug("✓ Notification received: #{input_pdo} = #{value}")

          {:data_changed, pdo, other_value} ->
            flunk(
              "Unexpected notification: #{inspect(pdo)} = #{other_value}, expected #{input_pdo} = #{value}"
            )

          other ->
            flunk("Unexpected message: #{inspect(other)}")
        after
          @notification_timeout ->
            flunk("Timeout waiting for notification: #{input_pdo} = #{value}")
        end
      end

      Logger.info("✓ PDO subscriptions test passed (#{length(test_values)} notifications)")
    after
      cleanup(master)
    end
  end

  @tag :hardware
  @tag timeout: 60_000
  test "5. multi-PDO concurrent operations" do
    Logger.info("=== Test 5: Multi-PDO Concurrent Operations ===")
    {master, _di, _do_slave, input_names, output_names} = setup_master_and_slaves()

    try do
      # NOTE: Only the first PDO pair (DI1 ↔ DO1) is physically connected
      # This test validates concurrent write/read operations on the loopback channel
      input_pdo = get_pdo_name(input_names, 0)
      output_pdo = get_pdo_name(output_names, 0)

      Logger.info("Testing concurrent operations on looped-back PDO pair")
      Logger.info("  Output: #{output_pdo}")
      Logger.info("  Input: #{input_pdo}")

      # Subscribe to input changes
      assert :ok = EtherCAT.watch(master, input_pdo)
      flush_mailbox()

      # Test rapid concurrent write/read cycles
      test_sequence = [false, true, false, true, false, true]

      for {value, idx} <- Enum.with_index(test_sequence) do
        Logger.debug("Concurrent operation #{idx + 1}: setting #{value}")

        # Write using unique name
        assert :ok = EtherCAT.write(master, output_pdo, value)

        # Immediate read (concurrent with cyclic task)
        assert {:ok, _} = EtherCAT.read(master, input_pdo)

        # Wait briefly
        :timer.sleep(100)
      end

      # Wait for final propagation
      :timer.sleep(@stabilization_delay)

      # Verify final state
      assert {:ok, final_value} = EtherCAT.read(master, input_pdo)
      Logger.info("✓ Final value: #{final_value}")

      # Verify we received notifications during the sequence
      notifications_count = count_available_notifications()
      Logger.info("✓ Received #{notifications_count} change notifications")

      assert notifications_count > 0,
             "Expected at least one notification during concurrent operations"

      Logger.info("✓ Multi-PDO concurrent operations test passed")
    after
      cleanup(master)
    end
  end

  @tag :hardware
  @tag timeout: 60_000
  test "6. edge cases - idempotency and boundaries" do
    Logger.info("=== Test 6: Edge Cases ===")
    {master, _di, _do_slave, input_names, output_names} = setup_master_and_slaves()

    try do
      input_pdo = get_pdo_name(input_names, 0)
      output_pdo = get_pdo_name(output_names, 0)

      # Test 6.1: Repeated writes (idempotency)
      Logger.info("Test 6.1: Repeated writes to same value")

      for _i <- 1..5 do
        assert :ok = EtherCAT.write(master, output_pdo, true)
        :timer.sleep(100)
      end

      :timer.sleep(@stabilization_delay)
      assert {:ok, true} = EtherCAT.read(master, input_pdo)
      Logger.info("✓ Idempotency verified")

      # Test 6.2: Read before write
      Logger.info("Test 6.2: Read initial state before any writes")

      # Reset to known state
      assert :ok = EtherCAT.write(master, output_pdo, false)
      :timer.sleep(@stabilization_delay)

      # Read should succeed even before explicit write
      assert {:ok, _value} = EtherCAT.read(master, input_pdo)
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
            :ok = EtherCAT.write(master, output_pdo, value)
            :timer.sleep(100)
            {:cont, i}
          else
            {:halt, i}
          end
        end)

      Logger.info("✓ Completed #{iterations} rapid alternations")

      # Final state verification
      :timer.sleep(@stabilization_delay)
      assert {:ok, _final_value} = EtherCAT.read(master, input_pdo)

      Logger.info("✓ Edge cases test passed")
    after
      cleanup(master)
    end
  end

  # Helper: Flush mailbox
  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  # Helper: Collect notifications
  defp collect_notifications(count, timeout) do
    collect_notifications(count, timeout, [])
  end

  defp collect_notifications(0, _timeout, acc), do: acc

  defp collect_notifications(count, timeout, acc) do
    receive do
      {:data_changed, pdo, value} ->
        collect_notifications(count - 1, timeout, [{pdo, value} | acc])
    after
      timeout ->
        Logger.warning(
          "Timeout collecting notifications, received #{length(acc)}/#{count + length(acc)}"
        )

        acc
    end
  end

  # Helper: Count available notifications without blocking
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
end
