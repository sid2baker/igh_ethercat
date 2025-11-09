defmodule Hardware.BasicIOTest do
  use ExUnit.Case, async: false
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

      iex> {m, input_handles, output_handles} = Hardware.BasicIOTest.run()
      # Subscribe to input changes
      iex> first_input = List.first(input_handles)
      iex> EtherCAT.watch(first_input)
      # Toggle output (if looped back, you'll receive a notification)
      iex> first_output = List.first(output_handles)
      iex> EtherCAT.write(first_output, true)
      iex> flush()
      {:data_changed, "slave_1:pdo_6000:1", true}
  """

  @doc """
  Interactive test function for manual testing in IEx.

  Returns `{master_pid, input_pdo_names, output_pdo_names}` for continued
  experimentation after the function completes.
  """
  def run do
    Logger.info("Starting Basic I/O Test...")

    # Simplified API: open auto-connects and discovers slaves
    {:ok, master, slaves} = EtherCAT.open(update_interval: 1000)

    # Flexible: expect at least 2 slaves (input and output), skip coupler if present
    [di1, do1 | _rest] = if length(slaves) >= 3, do: tl(slaves), else: slaves

    # Configure slaves and get available PDOs
    {:ok, input_pdos} = EtherCAT.configure_slave(di1, %{})
    input_pdos |> IO.inspect(label: "Input PDOs")

    {:ok, output_pdos} = EtherCAT.configure_slave(do1, %{})
    output_pdos |> IO.inspect(label: "Output PDOs")

    # Register PDOs and get PDO handles
    {:ok, input_handles} = EtherCAT.register_pdos(master, di1, input_pdos)
    {:ok, output_handles} = EtherCAT.register_pdos(master, do1, output_pdos)

    # Start cyclic communication
    EtherCAT.start_cyclic(master)

    # Give the system time to stabilize
    :timer.sleep(1000)

    # Subscribe to input changes using PDO handle
    # (assumes output 1 is connected to input 1)
    first_input = List.first(input_handles)
    EtherCAT.watch(first_input)
    :timer.sleep(500)

    # Toggle the output to demonstrate I/O using PDO handle
    first_output = List.first(output_handles)
    EtherCAT.write(first_output, true)
    :timer.sleep(500)

    EtherCAT.write(first_output, false)
    :timer.sleep(500)

    EtherCAT.write(first_output, true)

    Logger.info("Test complete! Returning master and PDO handles for interactive use.")
    {master, input_handles, output_handles}
  end

  @tag :hardware
  @tag timeout: 30_000
  test "basic I/O with loopback" do
    {master, input_handles, output_handles} = run()

    # Wait for stabilization
    :timer.sleep(2000)

    # Get first input and output PDO handles
    first_input = List.first(input_handles)
    first_output = List.first(output_handles)

    # Test write/read cycle
    Logger.info("Setting output HIGH...")
    assert :ok = EtherCAT.write(first_output, true)

    :timer.sleep(1000)

    Logger.info("Reading input...")
    assert {:ok, value} = EtherCAT.read(first_input)
    Logger.info("Input value: #{inspect(value)}")

    Logger.info("Setting output LOW...")
    assert :ok = EtherCAT.write(first_output, false)

    :timer.sleep(1000)

    Logger.info("Reading input again...")
    assert {:ok, value2} = EtherCAT.read(first_input)
    Logger.info("Input value: #{inspect(value2)}")

    # Cleanup using new API (blocks until master is fully released)
    EtherCAT.close(master)

    Logger.info("Test passed!")
  end
end
