defmodule Hardware.DiagnosticMappingTest do
  use ExUnit.Case, async: false
  require Logger

  @moduledoc """
  Diagnostic test to understand PDO mapping between inputs and outputs.

  This test helps identify bit/byte ordering issues by:
  1. Setting each output one at a time
  2. Reading all inputs to see which input actually turns on
  3. Building a mapping table
  """

  @cycle_interval 1000
  @stabilization_delay 1000

  @tag :hardware
  @tag timeout: 300_000
  test "diagnostic - map output channels to input channels" do
    Logger.info("\n=== Diagnostic: Output to Input Mapping ===\n")

    {:ok, master, slaves} = EtherCAT.open(update_interval: @cycle_interval)
    Logger.info("Discovered #{length(slaves)} slaves")

    [_coupler, input_slave, output_slave | _rest] = slaves

    # Configure slaves
    {:ok, input_pdos} = EtherCAT.configure_slave(input_slave, %{})
    {:ok, output_pdos} = EtherCAT.configure_slave(output_slave, %{})

    Logger.info("Input PDOs: #{inspect(input_pdos)}")
    Logger.info("Output PDOs: #{inspect(output_pdos)}")

    # Register all PDOs
    {:ok, input_handles} = EtherCAT.register_pdos(input_slave, input_pdos)
    {:ok, output_handles} = EtherCAT.register_pdos(output_slave, output_pdos)

    Logger.info("Input handles: #{inspect(input_handles)}")
    Logger.info("Output handles: #{inspect(output_handles)}")

    # Start cyclic operation
    EtherCAT.start_cyclic(master)
    :timer.sleep(@stabilization_delay)

    # First, set all outputs to LOW
    Logger.info("\nStep 1: Setting all outputs to LOW...")

    for handle <- output_handles do
      :ok = EtherCAT.write(handle, false)
    end

    :timer.sleep(@stabilization_delay)

    # Verify all inputs are LOW
    Logger.info("\nReading all inputs (should all be LOW)...")

    for {handle, idx} <- Enum.with_index(input_handles) do
      {:ok, value} = EtherCAT.read(handle)
      Logger.info("  Input #{idx + 1}: #{value}")
    end

    # Now test each output individually
    Logger.info("\n=== Testing Each Output Individually ===\n")

    mapping =
      for {out_handle, out_idx} <- Enum.with_index(output_handles) do
        output_num = out_idx + 1
        Logger.info("Setting Output #{output_num} to HIGH...")

        # Set this output HIGH
        :ok = EtherCAT.write(out_handle, true)
        :timer.sleep(@stabilization_delay)

        # Read all inputs and find which one(s) turned on
        active_inputs =
          for {in_handle, in_idx} <- Enum.with_index(input_handles) do
            {:ok, value} = EtherCAT.read(in_handle)

            if value do
              input_num = in_idx + 1
              Logger.info("  → Input #{input_num} is HIGH")
              input_num
            else
              nil
            end
          end
          |> Enum.filter(&(&1 != nil))

        # Set this output back to LOW
        :ok = EtherCAT.write(out_handle, false)
        :timer.sleep(@stabilization_delay)

        {output_num, active_inputs}
      end

    # Print mapping table
    Logger.info("\n=== Mapping Table ===")
    Logger.info("Output → Input(s)")

    for {output_num, input_nums} <- mapping do
      inputs_str =
        if Enum.empty?(input_nums) do
          "NONE"
        else
          Enum.join(input_nums, ", ")
        end

      Logger.info("  #{output_num} → #{inputs_str}")
    end

    # Analyze the pattern
    Logger.info("\n=== Pattern Analysis ===")

    # Check if it's a simple 1-to-1 mapping
    one_to_one = Enum.all?(mapping, fn {out, ins} -> length(ins) == 1 end)
    Logger.info("One-to-one mapping: #{one_to_one}")

    if one_to_one do
      # Check if outputs are in order
      in_order =
        mapping
        |> Enum.map(fn {out, [inp]} -> {out, inp} end)
        |> Enum.all?(fn {out, inp} -> out == inp end)

      Logger.info("In sequential order: #{in_order}")

      if !in_order do
        Logger.info("\nActual mapping:")

        for {out, [inp]} <- mapping do
          if out != inp do
            Logger.info("  Output #{out} maps to Input #{inp}")
          end
        end
      end
    end

    # Check for bit swapping patterns
    Logger.info("\n=== Checking for Common Patterns ===")

    # Check if odd/even are swapped
    even_outputs_map_to_odd =
      mapping
      |> Enum.filter(fn {out, _} -> rem(out, 2) == 0 end)
      |> Enum.all?(fn {_, [inp | _]} -> rem(inp, 2) == 1 end)

    if even_outputs_map_to_odd do
      Logger.info("Pattern detected: Even outputs map to odd inputs (bit swap)")
    end

    EtherCAT.close(master)
  end
end
