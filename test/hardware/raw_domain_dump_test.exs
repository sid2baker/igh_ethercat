defmodule Hardware.RawDomainDumpTest do
  use ExUnit.Case, async: false
  require Logger

  @moduledoc """
  Dump raw domain data to see what's actually in memory.
  """

  @cycle_interval 1000
  @stabilization_delay 1000

  @tag :hardware
  @tag timeout: 60_000
  test "dump raw domain data" do
    Logger.info("\n=== Raw Domain Data Dump ===\n")

    {:ok, master, slaves} = EtherCAT.open(update_interval: @cycle_interval)
    [_coupler, input_slave, output_slave | _rest] = slaves

    # Configure slaves
    {:ok, input_pdos} = EtherCAT.configure_slave(input_slave, %{})
    {:ok, output_pdos} = EtherCAT.configure_slave(output_slave, %{})

    # Register all PDOs
    {:ok, input_handles} = EtherCAT.register_pdos(input_slave, input_pdos)
    {:ok, output_handles} = EtherCAT.register_pdos(output_slave, output_pdos)

    # Start cyclic operation
    EtherCAT.start_cyclic(master)
    :timer.sleep(@stabilization_delay)

    # Set all outputs to LOW first
    Logger.info("Setting all outputs to LOW...")

    for handle <- output_handles do
      :ok = EtherCAT.write(handle, false)
    end

    :timer.sleep(1000)

    # Now set outputs 1, 2, 3 to HIGH
    Logger.info("\nSetting outputs 1, 2, 3 to HIGH...")
    :ok = EtherCAT.write(Enum.at(output_handles, 0), true)
    :ok = EtherCAT.write(Enum.at(output_handles, 1), true)
    :ok = EtherCAT.write(Enum.at(output_handles, 2), true)
    :timer.sleep(1000)

    # Now try to read the inputs and log what we get
    Logger.info("\n=== Reading Input PDOs ===")

    for {handle, idx} <- Enum.with_index(input_handles) do
      case EtherCAT.read(handle) do
        {:ok, value} ->
          Logger.info("  Input #{idx + 1} (#{handle.entry_name}): #{inspect(value)}")

        {:error, reason} ->
          Logger.error("  Input #{idx + 1} ERROR: #{inspect(reason)}")
      end
    end

    # Get the domain size - we'll need to access internals for this
    # Let's at least check what the master thinks about domain state
    Logger.info("\n=== Master and Domain Info ===")
    Logger.info("Master: #{inspect(master)}")
    Logger.info("Input slave: #{inspect(input_slave)}")
    Logger.info("Output slave: #{inspect(output_slave)}")

    # Try reading again after another delay
    Logger.info("\n=== Waiting 2 more seconds and reading again ===")
    :timer.sleep(2000)

    for {handle, idx} <- Enum.with_index(Enum.take(input_handles, 5)) do
      {:ok, value} = EtherCAT.read(handle)
      Logger.info("  Input #{idx + 1}: #{inspect(value)}")
    end

    EtherCAT.close(master)
  end
end
