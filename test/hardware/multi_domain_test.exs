defmodule Hardware.MultiDomainTest do
  use ExUnit.Case, async: false
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

      iex> {master, handles} = Hardware.MultiDomainTest.run()
      # Monitor master state transitions
      iex> flush()
      {:master_state_changed, %{...}}
      # You can create additional domains dynamically
      iex> EtherCAT.create_domain(master, :slow_poll, 1000)
  """

  @doc """
  Interactive test function for manual testing in IEx.

  Returns the master PID and PDO handles for continued experimentation.
  """
  def run do
    Logger.info("Starting Multi-Domain Test...")

    # Simplified API: open auto-connects and discovers slaves
    {:ok, master, [_coupler, _slave1, slave2 | _rest]} = EtherCAT.open()

    # Create a second domain with a slower update rate
    EtherCAT.create_domain(master, :domain2, 100)

    # Configure the slave and get available PDOs
    {:ok, all_pdos} = EtherCAT.configure_slave(master, slave2, %{})

    # Register first PDO to fast domain
    {fast_handles, remaining_pdos} =
      if length(all_pdos) > 0 do
        [fast_pdo | rest] = all_pdos
        {:ok, handles} = EtherCAT.register_pdos(master, slave2, [fast_pdo], :default_domain)
        Logger.info("Registered #{inspect(fast_pdo)} to fast domain (default_domain)")
        {handles, rest}
      else
        {[], []}
      end

    # Register remaining PDOs to slow domain
    slow_handles =
      if length(remaining_pdos) > 0 do
        {:ok, handles} = EtherCAT.register_pdos(master, slave2, remaining_pdos, :domain2)
        Logger.info("Registered #{length(remaining_pdos)} PDOs to slow domain (domain2)")
        handles
      else
        []
      end

    # Activate cyclic mode
    EtherCAT.start_cyclic(master)

    Logger.info("Test complete! Returning master and PDO handles for interactive use.")
    {master, fast_handles ++ slow_handles}
  end

  @tag :hardware
  @tag timeout: 30_000
  test "multi-domain with different update rates" do
    Logger.info("Starting multi-domain test...")

    # Simplified API: open auto-connects and discovers slaves
    {:ok, master, [_coupler, io_slave | _rest]} = EtherCAT.open()

    # Create additional domains with different update intervals
    assert {:ok, _ref} = EtherCAT.create_domain(master, :fast_domain, 1)
    assert {:ok, _ref} = EtherCAT.create_domain(master, :medium_domain, 10)
    assert {:ok, _ref} = EtherCAT.create_domain(master, :slow_domain, 100)

    Logger.info("Created 3 additional domains with different update rates")

    # Configure the slave and get available PDOs
    {:ok, all_pdos} = EtherCAT.configure_slave(master, io_slave, %{})
    Logger.info("Available PDOs: #{inspect(all_pdos)}")

    # Distribute PDOs across domains based on criticality
    # (In a real application, you'd choose based on actual requirements)
    pdo_handles =
      case length(all_pdos) do
        n when n >= 4 ->
          # Split PDOs across domains
          [p1 | rest] = all_pdos
          [p2 | rest] = rest
          [p3 | rest] = rest

          {:ok, h1} = EtherCAT.register_pdos(master, io_slave, [p1], :fast_domain)
          {:ok, h2} = EtherCAT.register_pdos(master, io_slave, [p2], :medium_domain)
          {:ok, h3} = EtherCAT.register_pdos(master, io_slave, [p3], :slow_domain)
          {:ok, h4} = EtherCAT.register_pdos(master, io_slave, rest, :default_domain)

          Logger.info("Distributed PDOs across 4 domains")
          h1 ++ h2 ++ h3 ++ h4

        n when n > 0 ->
          # Not enough PDOs, just use default domain
          {:ok, handles} = EtherCAT.register_pdos(master, io_slave, all_pdos, :default_domain)
          Logger.info("Using default domain only (not enough PDOs to split)")
          handles

        _ ->
          Logger.warning("No PDOs available!")
          []
      end

    # Activate cyclic mode
    EtherCAT.start_cyclic(master)

    # Wait for stabilization
    :timer.sleep(2000)

    # Verify domains are operational by checking intervals
    assert {:ok, 1} = EtherCAT.get_domain_interval(master, :default_domain)
    assert {:ok, 1} = EtherCAT.get_domain_interval(master, :fast_domain)
    assert {:ok, 10} = EtherCAT.get_domain_interval(master, :medium_domain)
    assert {:ok, 100} = EtherCAT.get_domain_interval(master, :slow_domain)

    Logger.info("All domains configured correctly with expected intervals")

    # Read some values to verify operation using PDO handles
    if length(pdo_handles) > 0 do
      first_handle = hd(pdo_handles)
      assert {:ok, _value} = EtherCAT.read(first_handle)
      Logger.info("Successfully read PDO value from multi-domain setup")
    end

    # Cleanup (blocks until master is fully released)
    EtherCAT.close(master)

    Logger.info("Test passed!")
  end
end
