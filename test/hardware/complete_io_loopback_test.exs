defmodule Hardware.CompleteIOLoopbackTest do
  use ExUnit.Case, async: false
  require Logger

  @moduledoc """
  Comprehensive loopback test for all 16 I/O channels.

  ## Hardware Configuration

  - **Slave 0**: Bus coupler (e.g., EK1100)
  - **Slave 1**: Digital input terminal (e.g., EL1809) - 16 channels
  - **Slave 2**: Digital output terminal (e.g., EL2809) - 16 channels
  - **Slave 3**: Analog input terminal (e.g., EL3202/EL3204)

  ## Wiring

  All outputs connected to corresponding inputs:
  - Output 1 → Input 1
  - Output 2 → Input 2
  - ...
  - Output 16 → Input 16

  ## Test Coverage

  1. Individual channel verification (all 16 channels)
  2. Simultaneous multi-channel operations
  3. Pattern-based testing (walking ones, walking zeros, checkerboard)
  4. Rapid sequential channel switching
  5. Byte-level operations (channels 1-8 and 9-16)
  6. Edge cases and stress testing
  """

  @cycle_interval 1000
  @stabilization_delay 500
  @fast_toggle_delay 100

  setup_all do
    Logger.info("=== Setting up EtherCAT master for complete I/O loopback tests ===")

    {:ok, master, slaves} = EtherCAT.open(update_interval: @cycle_interval)
    Logger.info("Discovered #{length(slaves)} slaves")

    # Expected: [coupler, input_module, output_module, analog_input, ...]
    [_coupler, input_slave, output_slave | _rest] = slaves

    # Configure input slave
    {:ok, input_pdos} = EtherCAT.configure_slave(input_slave, %{})
    Logger.info("Input slave has #{length(input_pdos)} PDOs")

    # Configure output slave
    {:ok, output_pdos} = EtherCAT.configure_slave(output_slave, %{})
    Logger.info("Output slave has #{length(output_pdos)} PDOs")

    # Register all PDOs
    {:ok, input_handles} = EtherCAT.register_pdos(input_slave, input_pdos)
    {:ok, output_handles} = EtherCAT.register_pdos(output_slave, output_pdos)

    Logger.info("Registered #{length(input_handles)} input PDO handles")
    Logger.info("Registered #{length(output_handles)} output PDO handles")

    # Start cyclic operation
    EtherCAT.start_cyclic(master)
    :timer.sleep(@stabilization_delay)

    Logger.info("=== Master setup complete ===")

    on_exit(fn ->
      Logger.info("=== Cleaning up EtherCAT master ===")

      try do
        if Process.alive?(master) do
          EtherCAT.close(master)
        end
      catch
        :exit, reason ->
          Logger.info("Master already stopped: #{inspect(reason)}")
      end
    end)

    %{
      master: master,
      input_handles: input_handles,
      output_handles: output_handles,
      num_channels: min(length(input_handles), length(output_handles))
    }
  end

  # Helper functions

  defp set_output_and_verify(output_handle, input_handle, value, channel_num) do
    assert :ok = EtherCAT.write(output_handle, value)
    :timer.sleep(@stabilization_delay)

    assert {:ok, actual} = EtherCAT.read(input_handle)

    assert actual == value,
           "Channel #{channel_num} loopback failed: expected #{value}, got #{actual}"

    Logger.debug("Channel #{channel_num}: #{value} ✓")
    :ok
  end

  defp set_all_outputs(output_handles, values) when is_list(values) do
    output_handles
    |> Enum.zip(values)
    |> Enum.each(fn {handle, value} ->
      :ok = EtherCAT.write(handle, value)
    end)
  end

  defp read_all_inputs(input_handles) do
    Enum.map(input_handles, fn handle ->
      {:ok, value} = EtherCAT.read(handle)
      value
    end)
  end

  # Test Cases

  @tag :hardware
  @tag timeout: 120_000
  test "1. individual channel verification - all 16 channels", context do
    Logger.info("=== Test 1: Individual Channel Verification ===")

    input_handles = context.input_handles
    output_handles = context.output_handles
    num_channels = context.num_channels

    Logger.info("Testing #{num_channels} channels individually")

    # Test each channel: false -> true -> false
    for i <- 0..(num_channels - 1) do
      channel_num = i + 1
      input_handle = Enum.at(input_handles, i)
      output_handle = Enum.at(output_handles, i)

      Logger.info("Testing channel #{channel_num}")

      # Set to false
      set_output_and_verify(output_handle, input_handle, false, channel_num)

      # Set to true
      set_output_and_verify(output_handle, input_handle, true, channel_num)

      # Set back to false
      set_output_and_verify(output_handle, input_handle, false, channel_num)
    end

    Logger.info("✓ All #{num_channels} channels verified individually")
  end

  @tag :hardware
  @tag timeout: 120_000
  test "2. simultaneous multi-channel - all HIGH", context do
    Logger.info("=== Test 2: All Channels HIGH Simultaneously ===")

    input_handles = context.input_handles
    output_handles = context.output_handles
    num_channels = context.num_channels

    # Set all outputs to true
    all_high = List.duplicate(true, num_channels)
    set_all_outputs(output_handles, all_high)
    :timer.sleep(@stabilization_delay)

    # Verify all inputs are true
    actual = read_all_inputs(input_handles)

    for {value, idx} <- Enum.with_index(actual) do
      assert value == true,
             "Channel #{idx + 1} failed: expected true, got #{value}"
    end

    Logger.info("✓ All #{num_channels} channels HIGH simultaneously")
  end

  @tag :hardware
  @tag timeout: 120_000
  test "3. simultaneous multi-channel - all LOW", context do
    Logger.info("=== Test 3: All Channels LOW Simultaneously ===")

    input_handles = context.input_handles
    output_handles = context.output_handles
    num_channels = context.num_channels

    # Set all outputs to false
    all_low = List.duplicate(false, num_channels)
    set_all_outputs(output_handles, all_low)
    :timer.sleep(@stabilization_delay)

    # Verify all inputs are false
    actual = read_all_inputs(input_handles)

    for {value, idx} <- Enum.with_index(actual) do
      assert value == false,
             "Channel #{idx + 1} failed: expected false, got #{value}"
    end

    Logger.info("✓ All #{num_channels} channels LOW simultaneously")
  end

  @tag :hardware
  @tag timeout: 120_000
  test "4. pattern testing - walking ones", context do
    Logger.info("=== Test 4: Walking Ones Pattern ===")

    input_handles = context.input_handles
    output_handles = context.output_handles
    num_channels = context.num_channels

    # Test walking ones: only one bit set at a time
    for i <- 0..(num_channels - 1) do
      Logger.info("Walking ones: position #{i + 1}")

      # Create pattern: all false except position i
      pattern =
        for j <- 0..(num_channels - 1) do
          j == i
        end

      set_all_outputs(output_handles, pattern)
      :timer.sleep(@stabilization_delay)

      # Verify pattern
      actual = read_all_inputs(input_handles)

      for {expected, actual_val, idx} <- Enum.zip([pattern, actual, 0..(num_channels - 1)]) do
        assert expected == actual_val,
               "Walking ones at position #{i + 1}, channel #{idx + 1}: expected #{expected}, got #{actual_val}"
      end
    end

    Logger.info("✓ Walking ones pattern verified for all #{num_channels} positions")
  end

  @tag :hardware
  @tag timeout: 120_000
  test "5. pattern testing - walking zeros", context do
    Logger.info("=== Test 5: Walking Zeros Pattern ===")

    input_handles = context.input_handles
    output_handles = context.output_handles
    num_channels = context.num_channels

    # Test walking zeros: only one bit clear at a time
    for i <- 0..(num_channels - 1) do
      Logger.info("Walking zeros: position #{i + 1}")

      # Create pattern: all true except position i
      pattern =
        for j <- 0..(num_channels - 1) do
          j != i
        end

      set_all_outputs(output_handles, pattern)
      :timer.sleep(@stabilization_delay)

      # Verify pattern
      actual = read_all_inputs(input_handles)

      for {expected, actual_val, idx} <- Enum.zip([pattern, actual, 0..(num_channels - 1)]) do
        assert expected == actual_val,
               "Walking zeros at position #{i + 1}, channel #{idx + 1}: expected #{expected}, got #{actual_val}"
      end
    end

    Logger.info("✓ Walking zeros pattern verified for all #{num_channels} positions")
  end

  @tag :hardware
  @tag timeout: 120_000
  test "6. pattern testing - checkerboard", context do
    Logger.info("=== Test 6: Checkerboard Pattern ===")

    input_handles = context.input_handles
    output_handles = context.output_handles
    num_channels = context.num_channels

    # Test checkerboard: alternating true/false
    Logger.info("Testing checkerboard pattern (odd HIGH, even LOW)")

    pattern1 =
      for i <- 0..(num_channels - 1) do
        rem(i, 2) == 0
      end

    set_all_outputs(output_handles, pattern1)
    :timer.sleep(@stabilization_delay)

    actual1 = read_all_inputs(input_handles)

    for {expected, actual_val, idx} <- Enum.zip([pattern1, actual1, 0..(num_channels - 1)]) do
      assert expected == actual_val,
             "Checkerboard pattern 1, channel #{idx + 1}: expected #{expected}, got #{actual_val}"
    end

    Logger.info("✓ Checkerboard pattern 1 verified")

    # Test inverted checkerboard
    Logger.info("Testing inverted checkerboard pattern (odd LOW, even HIGH)")

    pattern2 = Enum.map(pattern1, &(!&1))

    set_all_outputs(output_handles, pattern2)
    :timer.sleep(@stabilization_delay)

    actual2 = read_all_inputs(input_handles)

    for {expected, actual_val, idx} <- Enum.zip([pattern2, actual2, 0..(num_channels - 1)]) do
      assert expected == actual_val,
             "Checkerboard pattern 2, channel #{idx + 1}: expected #{expected}, got #{actual_val}"
    end

    Logger.info("✓ Inverted checkerboard pattern verified")
  end

  @tag :hardware
  @tag timeout: 120_000
  test "7. rapid sequential switching - all channels", context do
    Logger.info("=== Test 7: Rapid Sequential Switching ===")

    input_handles = context.input_handles
    output_handles = context.output_handles
    num_channels = context.num_channels

    # Rapidly toggle each channel in sequence
    iterations = 10

    for iteration <- 1..iterations do
      Logger.info("Rapid switching iteration #{iteration}/#{iterations}")

      for i <- 0..(num_channels - 1) do
        output_handle = Enum.at(output_handles, i)
        input_handle = Enum.at(input_handles, i)

        # Toggle: false -> true
        :ok = EtherCAT.write(output_handle, true)
        :timer.sleep(@fast_toggle_delay)

        # Verify
        {:ok, value} = EtherCAT.read(input_handle)
        assert value == true, "Channel #{i + 1} rapid switch failed"

        # Toggle back: true -> false
        :ok = EtherCAT.write(output_handle, false)
        :timer.sleep(@fast_toggle_delay)
      end
    end

    Logger.info(
      "✓ Rapid sequential switching completed (#{iterations} iterations × #{num_channels} channels)"
    )
  end

  @tag :hardware
  @tag timeout: 120_000
  test "8. byte-level operations - first byte (channels 1-8)", context do
    Logger.info("=== Test 8: Byte-Level Operations (Channels 1-8) ===")

    input_handles = Enum.take(context.input_handles, 8)
    output_handles = Enum.take(context.output_handles, 8)

    # Test various byte patterns
    test_patterns = [
      {0b00000000, "All zeros"},
      {0b11111111, "All ones"},
      {0b10101010, "Alternating (0xAA)"},
      {0b01010101, "Alternating (0x55)"},
      {0b11110000, "High nibble"},
      {0b00001111, "Low nibble"},
      {0b10000001, "Corners"},
      {0b01111110, "Middle bits"}
    ]

    for {byte_value, description} <- test_patterns do
      Logger.info(
        "Testing byte pattern: #{description} (0b#{Integer.to_string(byte_value, 2) |> String.pad_leading(8, "0")})"
      )

      # Convert byte to list of booleans
      pattern =
        for i <- 0..7 do
          Bitwise.band(byte_value, Bitwise.bsl(1, i)) != 0
        end

      set_all_outputs(output_handles, pattern)
      :timer.sleep(@stabilization_delay)

      # Verify
      actual = read_all_inputs(input_handles)

      for {expected, actual_val, idx} <- Enum.zip([pattern, actual, 0..7]) do
        assert expected == actual_val,
               "Byte pattern #{description}, bit #{idx}: expected #{expected}, got #{actual_val}"
      end

      Logger.info("✓ #{description} verified")
    end

    Logger.info("✓ Byte-level operations (channels 1-8) complete")
  end

  @tag :hardware
  @tag timeout: 120_000
  test "9. byte-level operations - second byte (channels 9-16)", context do
    Logger.info("=== Test 9: Byte-Level Operations (Channels 9-16) ===")

    # Skip first 8 channels, take next 8
    input_handles = context.input_handles |> Enum.drop(8) |> Enum.take(8)
    output_handles = context.output_handles |> Enum.drop(8) |> Enum.take(8)

    # Test various byte patterns
    test_patterns = [
      {0b00000000, "All zeros"},
      {0b11111111, "All ones"},
      {0b10101010, "Alternating (0xAA)"},
      {0b01010101, "Alternating (0x55)"},
      {0b11110000, "High nibble"},
      {0b00001111, "Low nibble"}
    ]

    for {byte_value, description} <- test_patterns do
      Logger.info(
        "Testing byte pattern: #{description} (0b#{Integer.to_string(byte_value, 2) |> String.pad_leading(8, "0")})"
      )

      # Convert byte to list of booleans
      pattern =
        for i <- 0..7 do
          Bitwise.band(byte_value, Bitwise.bsl(1, i)) != 0
        end

      set_all_outputs(output_handles, pattern)
      :timer.sleep(@stabilization_delay)

      # Verify
      actual = read_all_inputs(input_handles)

      for {expected, actual_val, idx} <- Enum.zip([pattern, actual, 8..15]) do
        assert expected == actual_val,
               "Byte pattern #{description}, bit #{idx}: expected #{expected}, got #{actual_val}"
      end

      Logger.info("✓ #{description} verified")
    end

    Logger.info("✓ Byte-level operations (channels 9-16) complete")
  end

  @tag :hardware
  @tag timeout: 120_000
  test "10. stress test - random patterns", context do
    Logger.info("=== Test 10: Stress Test - Random Patterns ===")

    input_handles = context.input_handles
    output_handles = context.output_handles
    num_channels = context.num_channels

    iterations = 50

    for iteration <- 1..iterations do
      # Generate random pattern
      pattern =
        for _ <- 0..(num_channels - 1) do
          :rand.uniform() > 0.5
        end

      set_all_outputs(output_handles, pattern)
      :timer.sleep(@fast_toggle_delay * 2)

      # Verify
      actual = read_all_inputs(input_handles)

      for {expected, actual_val, idx} <- Enum.zip([pattern, actual, 0..(num_channels - 1)]) do
        assert expected == actual_val,
               "Random pattern #{iteration}, channel #{idx + 1}: expected #{expected}, got #{actual_val}"
      end

      if rem(iteration, 10) == 0 do
        Logger.info("Completed #{iteration}/#{iterations} random patterns")
      end
    end

    Logger.info("✓ Stress test complete (#{iterations} random patterns)")
  end

  @tag :hardware
  @tag timeout: 120_000
  test "11. edge case - rapid full transitions", context do
    Logger.info("=== Test 11: Edge Case - Rapid Full Transitions ===")

    input_handles = context.input_handles
    output_handles = context.output_handles
    num_channels = context.num_channels

    # Rapidly alternate between all HIGH and all LOW
    iterations = 20

    for iteration <- 1..iterations do
      # All HIGH
      all_high = List.duplicate(true, num_channels)
      set_all_outputs(output_handles, all_high)
      :timer.sleep(@fast_toggle_delay)

      # All LOW
      all_low = List.duplicate(false, num_channels)
      set_all_outputs(output_handles, all_low)
      :timer.sleep(@fast_toggle_delay)

      if rem(iteration, 5) == 0 do
        Logger.info("Completed #{iteration}/#{iterations} full transitions")
      end
    end

    # Final verification
    :timer.sleep(@stabilization_delay)
    actual = read_all_inputs(input_handles)
    assert length(actual) == num_channels

    Logger.info("✓ Edge case test complete (#{iterations} full transitions)")
  end

  @tag :hardware
  @tag timeout: 120_000
  test "12. consistency check - repeated same pattern", context do
    Logger.info("=== Test 12: Consistency Check - Repeated Same Pattern ===")

    input_handles = context.input_handles
    output_handles = context.output_handles
    num_channels = context.num_channels

    # Create a specific pattern
    test_pattern =
      for i <- 0..(num_channels - 1) do
        rem(i, 3) == 0
      end

    # Write the same pattern multiple times
    repetitions = 10

    for rep <- 1..repetitions do
      set_all_outputs(output_handles, test_pattern)
      :timer.sleep(100)

      # Verify consistency
      actual = read_all_inputs(input_handles)

      for {expected, actual_val, idx} <- Enum.zip([test_pattern, actual, 0..(num_channels - 1)]) do
        assert expected == actual_val,
               "Repetition #{rep}, channel #{idx + 1}: expected #{expected}, got #{actual_val}"
      end
    end

    Logger.info("✓ Consistency verified over #{repetitions} repetitions")
  end
end
