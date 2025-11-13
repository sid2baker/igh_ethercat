defmodule Hardware.InputReadTest do
  use ExUnit.Case, async: false
  require Logger

  @moduledoc """
  Simple test to verify input reading functionality.

  Manually set some outputs HIGH using the terminal switches,
  then this test will read and report the input states.
  """

  @cycle_interval 1000
  @stabilization_delay 2000

  @tag :hardware
  @tag timeout: 60_000
  test "read all inputs continuously" do
    Logger.info("\n=== Input Reading Test ===\n")

    {:ok, master, slaves} = EtherCAT.open(update_interval: @cycle_interval)
    [_coupler, input_slave, output_slave | _rest] = slaves

    # Configure slaves
    {:ok, input_pdos} = EtherCAT.configure_slave(input_slave, %{})
    {:ok, output_pdos} = EtherCAT.configure_slave(output_slave, %{})

    # Register all PDOs
    {:ok, input_handles} = EtherCAT.register_pdos(input_slave, input_pdos)
    {:ok, output_handles} = EtherCAT.register_pdos(output_slave, output_pdos)

    Logger.info("Registered #{length(input_handles)} input handles")
    Logger.info("Registered #{length(output_handles)} output handles")

    # Start cyclic operation
    EtherCAT.start_cyclic(master)
    :timer.sleep(@stabilization_delay)

    # First, set output 1 to HIGH using our code
    Logger.info("\n=== Setting Output 1 to HIGH via software ===")
    output1 = Enum.at(output_handles, 0)
    :ok = EtherCAT.write(output1, true)
    :timer.sleep(1000)

    Logger.info("\n=== Reading inputs (Output 1 should be HIGH) ===")

    for {handle, idx} <- Enum.with_index(input_handles) do
      {:ok, value} = EtherCAT.read(handle)
      Logger.info("  Input #{idx + 1}: #{value}")
    end

    # Now set output 2 to HIGH as well
    Logger.info("\n=== Setting Output 2 to HIGH via software ===")
    output2 = Enum.at(output_handles, 1)
    :ok = EtherCAT.write(output2, true)
    :timer.sleep(1000)

    Logger.info("\n=== Reading inputs (Outputs 1 and 2 should be HIGH) ===")

    for {handle, idx} <- Enum.with_index(input_handles) do
      {:ok, value} = EtherCAT.read(handle)
      Logger.info("  Input #{idx + 1}: #{value}")
    end

    # Set all outputs HIGH
    Logger.info("\n=== Setting ALL outputs to HIGH via software ===")

    for handle <- output_handles do
      :ok = EtherCAT.write(handle, true)
    end

    :timer.sleep(1000)

    Logger.info("\n=== Reading inputs (ALL should be HIGH except maybe 15) ===")

    for {handle, idx} <- Enum.with_index(input_handles) do
      {:ok, value} = EtherCAT.read(handle)
      status = if value, do: "✓ HIGH", else: "✗ LOW"
      Logger.info("  Input #{idx + 1}: #{status}")
    end

    # Continuous reading for 10 seconds
    Logger.info("\n=== Continuous Reading (10 seconds) ===")
    Logger.info("Watching for any changes...")

    end_time = System.monotonic_time(:second) + 10
    read_inputs_continuously(input_handles, end_time, 0)

    EtherCAT.close(master)
  end

  defp read_inputs_continuously(input_handles, end_time, iteration) do
    if System.monotonic_time(:second) < end_time do
      values =
        for {handle, idx} <- Enum.with_index(input_handles) do
          {:ok, value} = EtherCAT.read(handle)
          {idx + 1, value}
        end

      # Only log if something changed or every 10th iteration
      high_inputs = values |> Enum.filter(fn {_, v} -> v end) |> Enum.map(fn {i, _} -> i end)

      if !Enum.empty?(high_inputs) or rem(iteration, 10) == 0 do
        Logger.info("  Iteration #{iteration}: HIGH inputs = #{inspect(high_inputs)}")
      end

      :timer.sleep(100)
      read_inputs_continuously(input_handles, end_time, iteration + 1)
    end
  end
end
