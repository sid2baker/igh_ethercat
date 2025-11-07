defmodule Hardware.BasicIOTest do
  use ExUnit.Case
  require Logger

  @moduledoc """
  Basic EtherCAT I/O test with loopback demonstration.

  This test demonstrates a complete EtherCAT workflow:
  - Master initialization and connection
  - Slave discovery and configuration
  - PDO registration to the default domain
  - Cyclic mode activation
  - Real-time I/O operations with change notifications

  ## Hardware Setup

  Expected configuration (typical Beckhoff setup):
  - **Slave 0**: Bus coupler/terminal (e.g., EK1100) - provides bus power
  - **Slave 1**: Digital input terminal (e.g., EL1809) - 16 channels
  - **Slave 2**: Digital output terminal (e.g., EL2809) - 16 channels

  For testing, physically connect output 1 to input 1 to see the loopback.

  ## Running

  To run this test with actual hardware:

      mix test test/hardware/basic_io_test.exs --include hardware

  Or run in IEx for interactive testing:

      iex> {m, input, output} = Hardware.BasicIOTest.run()
      # Subscribe to input changes
      iex> EtherCAT.watch_pdo(input, "pdo_6000:1")
      # Toggle output (if looped back, you'll receive a notification)
      iex> EtherCAT.set_pdo(output, "pdo_7000:1", true)
      iex> flush()
      {:data_changed, "pdo_6000:1", true}
  """

  @doc """
  Interactive test function for manual testing in IEx.

  Returns `{master_pid, input_slave_pid, output_slave_pid}` for continued
  experimentation after the function completes.
  """
  def run do
    Logger.info("Starting Basic I/O Test...")

    {:ok, master} = EtherCAT.start_link(update_interval: 1000)
    :ok = EtherCAT.connect(master)
    {:ok, [_coupler, di1, do1]} = EtherCAT.list_slaves(master)

    EtherCAT.configure_slave(di1, [])
    EtherCAT.list_pdos(di1) |> IO.inspect(label: "Input PDOs")

    EtherCAT.configure_slave(do1, [])
    EtherCAT.list_pdos(do1) |> IO.inspect(label: "Output PDOs")

    EtherCAT.register_all_pdos(di1, :default_domain)
    EtherCAT.register_all_pdos(do1, :default_domain)

    EtherCAT.start_cyclic(master)

    # Give the system time to stabilize
    :timer.sleep(1000)

    # Subscribe to input changes (assumes output 1 is connected to input 1)
    EtherCAT.watch_pdo(di1, "pdo_6000:1")
    :timer.sleep(500)

    # Toggle the output to demonstrate I/O
    EtherCAT.set_pdo(do1, "pdo_7000:1", true)
    :timer.sleep(500)

    EtherCAT.set_pdo(do1, "pdo_7000:1", false)
    :timer.sleep(500)

    EtherCAT.set_pdo(do1, "pdo_7000:1", true)

    Logger.info("Test complete! Returning PIDs for interactive use.")
    {master, di1, do1}
  end

  @tag :hardware
  @tag timeout: 30_000
  test "basic I/O with loopback" do
    {master, input, output} = run()

    # Wait for stabilization
    :timer.sleep(2000)

    # Test write/read cycle
    Logger.info("Setting output HIGH...")
    assert :ok = EtherCAT.set_pdo(output, "pdo_7000:1", true)

    :timer.sleep(1000)

    Logger.info("Reading input...")
    assert {:ok, value} = EtherCAT.get_pdo(input, "pdo_6000:1")
    Logger.info("Input value: #{inspect(value)}")

    Logger.info("Setting output LOW...")
    assert :ok = EtherCAT.set_pdo(output, "pdo_7000:1", false)

    :timer.sleep(1000)

    Logger.info("Reading input again...")
    assert {:ok, value2} = EtherCAT.get_pdo(input, "pdo_6000:1")
    Logger.info("Input value: #{inspect(value2)}")

    # Cleanup
    GenServer.stop(master, :normal)

    Logger.info("Test passed!")
  end
end
