defmodule Hardware.SelectivePDOTest do
  use ExUnit.Case
  require Logger

  @moduledoc """
  Test demonstrating selective PDO registration.

  This example shows how to register only specific PDOs from a slave rather
  than all available PDOs. This is useful when you only need a subset of
  the device's capabilities, reducing process data size and improving
  efficiency.

  ## Hardware Setup

  Expected configuration:
  - **Slave 0**: Bus coupler (ignored in this test)
  - **Slave 1**: Multi-channel digital input terminal (e.g., EL1809 with 16 channels)

  ## Demonstrates

  - Listing all available PDOs from a slave
  - Selective registration of specific PDOs
  - Multiple registration calls to the same domain

  ## Running

  To run this test with actual hardware:

      mix test test/hardware/selective_pdo_test.exs --include hardware

  Or run in IEx for interactive testing:

      iex> slave = Hardware.SelectivePDOTest.run()
      # The slave is already configured and operational
      iex> EtherCAT.list_pdos(slave)
      ["pdo_6000:1", "pdo_6010:1", ...]
      iex> {:ok, value} = EtherCAT.read(slave, "pdo_6000:1")
  """

  @doc """
  Interactive test function for manual testing in IEx.

  Returns the input slave PID for continued experimentation.
  """
  def run do
    Logger.info("Starting Selective PDO Test...")

    {:ok, master} = EtherCAT.open()
    :ok = EtherCAT.connect(master)
    {:ok, [_slave1, slave2]} = EtherCAT.list_slaves(master)

    EtherCAT.configure_slave(slave2, [])
    EtherCAT.list_pdos(slave2) |> IO.inspect(label: "Available PDOs")

    # Register all PDOs first
    EtherCAT.register_all_pdos(slave2, :default_domain)

    # Selective registration example (would typically be done instead of register_all_pdos)
    # This demonstrates that you can register specific PDOs by name
    EtherCAT.register_pdos(
      slave2,
      [:input1, :input2, :input3, :input4, :input5, :input6, :input7, :input9],
      :default_domain
    )

    EtherCAT.start_cyclic(master)

    Logger.info("Test complete! Returning slave PID for interactive use.")
    slave2
  end

  @tag :hardware
  @tag timeout: 30_000
  test "selective PDO registration" do
    Logger.info("Starting selective PDO registration test...")

    {:ok, master} = EtherCAT.open()
    :ok = EtherCAT.connect(master)
    {:ok, [_coupler, input_slave]} = EtherCAT.list_slaves(master)

    # Configure the slave
    EtherCAT.configure_slave(input_slave, [])

    # List all available PDOs
    all_pdos = EtherCAT.list_pdos(input_slave)
    Logger.info("Available PDOs: #{inspect(all_pdos)}")
    assert length(all_pdos) > 0

    # Select only the first few PDOs
    selected_pdos = Enum.take(all_pdos, 4)
    Logger.info("Registering selected PDOs: #{inspect(selected_pdos)}")

    # Register only selected PDOs
    assert :ok = EtherCAT.register_pdos(input_slave, selected_pdos, :default_domain)

    # Activate cyclic mode
    EtherCAT.start_cyclic(master)

    # Wait for stabilization
    :timer.sleep(2000)

    # Verify we can read from registered PDOs
    for pdo <- selected_pdos do
      Logger.info("Reading PDO: #{inspect(pdo)}")
      assert {:ok, _value} = EtherCAT.read(input_slave, pdo)
    end

    # Cleanup
    GenServer.stop(master, :normal)

    Logger.info("Test passed!")
  end
end
