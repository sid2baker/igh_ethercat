defmodule Hardware.SelectivePDOTest do
  use ExUnit.Case, async: false
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

  - Listing all available PDOs from a slave via configure_slave
  - Selective registration of specific PDOs
  - Multiple registration calls to the same domain

  ## Running

  To run this test with actual hardware:

      mix test test/hardware/selective_pdo_test.exs --include hardware

  Or run in IEx for interactive testing:

      iex> {master, pdo_handles} = Hardware.SelectivePDOTest.run()
      # The slave is already configured and operational
      iex> first_handle = List.first(pdo_handles)
      iex> {:ok, value} = EtherCAT.read(first_handle)
  """

  @doc """
  Interactive test function for manual testing in IEx.

  Returns the master PID and PDO handles for continued experimentation.
  """
  def run do
    Logger.info("Starting Selective PDO Test...")

    # Simplified API: open auto-connects and discovers slaves
    {:ok, master, [_coupler, _slave1, slave2]} = EtherCAT.open()

    # Configure slave and get available PDOs
    {:ok, all_pdos} = EtherCAT.configure_slave(master, slave2, %{})
    all_pdos |> IO.inspect(label: "Available PDOs")

    # Select only the first 8 PDOs
    selected_pdos = Enum.take(all_pdos, 8)
    Logger.info("Registering selected PDOs: #{inspect(selected_pdos)}")

    # Register only selected PDOs and get handles
    {:ok, pdo_handles} = EtherCAT.register_pdos(master, slave2, selected_pdos, :default_domain)

    # Start cyclic communication
    EtherCAT.start_cyclic(master)

    Logger.info("Test complete! Returning master and PDO handles for interactive use.")
    {master, pdo_handles}
  end

  @tag :hardware
  @tag timeout: 30_000
  test "selective PDO registration" do
    Logger.info("Starting selective PDO registration test...")

    # Simplified API: open auto-connects and discovers slaves
    {:ok, master, [_coupler, input_slave | _rest]} = EtherCAT.open()

    # Configure the slave and get available PDOs
    {:ok, all_pdos} = EtherCAT.configure_slave(master, input_slave, %{})
    Logger.info("Available PDOs: #{inspect(all_pdos)}")
    assert length(all_pdos) > 0

    # Select only the first few PDOs
    selected_pdos = Enum.take(all_pdos, 4)
    Logger.info("Registering selected PDOs: #{inspect(selected_pdos)}")

    # Register only selected PDOs and get handles
    {:ok, pdo_handles} = EtherCAT.register_pdos(master, input_slave, selected_pdos, :default_domain)

    # Activate cyclic mode
    EtherCAT.start_cyclic(master)

    # Wait for stabilization
    :timer.sleep(2000)

    # Verify we can read from registered PDOs using handles
    for pdo_handle <- pdo_handles do
      Logger.info("Reading PDO: #{inspect(pdo_handle)}")
      assert {:ok, _value} = EtherCAT.read(pdo_handle)
    end

    # Cleanup (blocks until master is fully released)
    EtherCAT.close(master)

    Logger.info("Test passed!")
  end
end
