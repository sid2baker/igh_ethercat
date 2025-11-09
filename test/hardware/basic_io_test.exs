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
      iex> EtherCAT.watch(input, "pdo_6000:1")
      # Toggle output (if looped back, you'll receive a notification)
      iex> EtherCAT.write(output, "pdo_7000:1", true)
      iex> flush()
      {:data_changed, "pdo_6000:1", true}
  """

  @doc """
  Interactive test function for manual testing in IEx.

  Returns `{master_pid, input_pdo_names, output_pdo_names}` for continued
  experimentation after the function completes.
  """
  def run do
    Logger.info("Starting Basic I/O Test...")

    # Simplified API: open auto-connects and discovers slaves
    {:ok, master, [_coupler, di1, do1]} = EtherCAT.open(update_interval: 1000)

    # Configure slaves and get available PDOs
    {:ok, input_pdos} = EtherCAT.configure_slave(master, di1, %{})
    input_pdos |> IO.inspect(label: "Input PDOs")

    {:ok, output_pdos} = EtherCAT.configure_slave(master, do1, %{})
    output_pdos |> IO.inspect(label: "Output PDOs")

    # Register PDOs and get unique names
    {:ok, input_names} = EtherCAT.register_pdos(master, di1, input_pdos)
    {:ok, output_names} = EtherCAT.register_pdos(master, do1, output_pdos)

    # Start cyclic communication
    EtherCAT.start_cyclic(master)

    # Give the system time to stabilize
    :timer.sleep(1000)

    # Subscribe to input changes using unique name
    # (assumes output 1 is connected to input 1)
    first_input = List.first(input_names)
    EtherCAT.watch(master, first_input)
    :timer.sleep(500)

    # Toggle the output to demonstrate I/O using unique name
    first_output = List.first(output_names)
    EtherCAT.write(master, first_output, true)
    :timer.sleep(500)

    EtherCAT.write(master, first_output, false)
    :timer.sleep(500)

    EtherCAT.write(master, first_output, true)

    Logger.info("Test complete! Returning master and PDO names for interactive use.")
    {master, input_names, output_names}
  end

  @tag :hardware
  @tag timeout: 30_000
  test "basic I/O with loopback" do
    {master, input_names, output_names} = run()

    # Wait for stabilization
    :timer.sleep(2000)

    # Get first input and output unique names
    first_input = List.first(input_names)
    first_output = List.first(output_names)

    # Test write/read cycle
    Logger.info("Setting output HIGH...")
    assert :ok = EtherCAT.write(master, first_output, true)

    :timer.sleep(1000)

    Logger.info("Reading input...")
    assert {:ok, value} = EtherCAT.read(master, first_input)
    Logger.info("Input value: #{inspect(value)}")

    Logger.info("Setting output LOW...")
    assert :ok = EtherCAT.write(master, first_output, false)

    :timer.sleep(1000)

    Logger.info("Reading input again...")
    assert {:ok, value2} = EtherCAT.read(master, first_input)
    Logger.info("Input value: #{inspect(value2)}")

    # Cleanup using new API
    EtherCAT.close(master)

    Logger.info("Test passed!")
  end
end

