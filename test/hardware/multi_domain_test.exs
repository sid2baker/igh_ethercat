defmodule Hardware.MultiDomainTest do
  use ExUnit.Case
  require Logger

  @moduledoc """
  Test demonstrating multi-rate control with multiple domains.

  This example shows how to create and use multiple domains with different
  update intervals. This is essential for applications with varying timing
  requirements - fast control loops, moderate sensor sampling, and slow
  configuration updates can coexist efficiently.

  ## Hardware Setup

  Expected configuration:
  - **Slave 0**: Bus coupler
  - **Slave 1**: Digital I/O terminal with multiple channels

  ## Demonstrates

  - Creating custom domains with specific update intervals
  - Registering different PDOs to different domains
  - Multi-rate data exchange (default_domain at 1µs, domain2 at 100µs)

  ## Domain Configuration

  - **:default_domain** - Updates every cycle (interval=1)
  - **:domain2** - Updates every 100 cycles (interval=100)

  ## Use Cases

  - **Fast domain**: Critical control signals (valve positions, motor speeds)
  - **Medium domain**: Sensor readings (temperature, pressure)
  - **Slow domain**: Configuration data, diagnostics, status LEDs

  ## Running

  To run this test with actual hardware:

      mix test test/hardware/multi_domain_test.exs --include hardware

  Or run in IEx for interactive testing:

      iex> master = Hardware.MultiDomainTest.run()
      # Monitor master state transitions
      iex> flush()
      {:master_state_changed, %{...}}
      # You can create additional domains dynamically
      iex> EtherCAT.create_domain(master, :slow_poll, 1000)
  """

  @doc """
  Interactive test function for manual testing in IEx.

  Returns the master PID for continued experimentation and monitoring.
  """
  def run do
    Logger.info("Starting Multi-Domain Test...")

    {:ok, master} = EtherCAT.open()
    :ok = EtherCAT.connect(master)
    {:ok, [_slave1, slave2]} = EtherCAT.list_slaves(master)

    # Create a second domain with a slower update rate
    EtherCAT.create_domain(master, :domain2, 100)

    # Configure the slave
    EtherCAT.configure_slave(slave2, [])
    all_pdos = EtherCAT.list_pdos(slave2)

    # Register first PDO to fast domain
    if length(all_pdos) > 0 do
      fast_pdo = hd(all_pdos)
      EtherCAT.register_pdos(slave2, [fast_pdo], :default_domain)
      Logger.info("Registered #{inspect(fast_pdo)} to fast domain (default_domain)")
    end

    # Register all PDOs to slow domain
    EtherCAT.register_all_pdos(slave2, :domain2)
    Logger.info("Registered all PDOs to slow domain (domain2)")

    # Activate cyclic mode
    EtherCAT.start_cyclic(master)

    Logger.info("Test complete! Returning master PID for interactive use.")
    master
  end

  @tag :hardware
  @tag timeout: 30_000
  test "multi-domain with different update rates" do
    Logger.info("Starting multi-domain test...")

    {:ok, master} = EtherCAT.open()
    :ok = EtherCAT.connect(master)
    {:ok, [_coupler, io_slave]} = EtherCAT.list_slaves(master)

    # Create additional domains with different update intervals
    assert {:ok, _ref} = EtherCAT.create_domain(master, :fast_domain, 1)
    assert {:ok, _ref} = EtherCAT.create_domain(master, :medium_domain, 10)
    assert {:ok, _ref} = EtherCAT.create_domain(master, :slow_domain, 100)

    Logger.info("Created 3 additional domains with different update rates")

    # Configure the slave
    EtherCAT.configure_slave(io_slave, [])
    all_pdos = EtherCAT.list_pdos(io_slave)
    Logger.info("Available PDOs: #{inspect(all_pdos)}")

    # Distribute PDOs across domains based on criticality
    # (In a real application, you'd choose based on actual requirements)
    case length(all_pdos) do
      n when n >= 4 ->
        # Split PDOs across domains
        [p1 | rest] = all_pdos
        [p2 | rest] = rest
        [p3 | rest] = rest

        EtherCAT.register_pdos(io_slave, [p1], :fast_domain)
        EtherCAT.register_pdos(io_slave, [p2], :medium_domain)
        EtherCAT.register_pdos(io_slave, [p3], :slow_domain)
        EtherCAT.register_pdos(io_slave, rest, :default_domain)

        Logger.info("Distributed PDOs across 4 domains")

      n when n > 0 ->
        # Not enough PDOs, just use default domain
        EtherCAT.register_all_pdos(io_slave, :default_domain)
        Logger.info("Using default domain only (not enough PDOs to split)")

      _ ->
        Logger.warning("No PDOs available!")
    end

    # Activate cyclic mode
    EtherCAT.start_cyclic(master)

    # Wait for stabilization
    :timer.sleep(2000)

    # Verify domains are operational by checking intervals
    assert 1 = EtherCAT.get_domain_interval(:default_domain)
    assert 1 = EtherCAT.get_domain_interval(:fast_domain)
    assert 10 = EtherCAT.get_domain_interval(:medium_domain)
    assert 100 = EtherCAT.get_domain_interval(:slow_domain)

    Logger.info("All domains configured correctly with expected intervals")

    # Read some values to verify operation
    if length(all_pdos) > 0 do
      pdo = hd(all_pdos)
      assert {:ok, _value} = EtherCAT.read(io_slave, pdo)
      Logger.info("Successfully read PDO value from multi-domain setup")
    end

    # Cleanup
    GenServer.stop(master, :normal)

    Logger.info("Test passed!")
  end
end
