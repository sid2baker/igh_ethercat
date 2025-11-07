defmodule EtherCAT do
  @moduledoc """
  EtherCAT master implementation using the IgH EtherCAT Master for Linux.

  EtherCAT (Ethernet for Control Automation Technology) is a high-performance,
  deterministic industrial Ethernet protocol designed for real-time automation
  and motion control applications.

  This library provides an idiomatic Elixir interface to the IgH EtherCAT Master,
  enabling real-time industrial I/O from the BEAM VM.

  ## Core Modules

  - `EtherCAT.Master` - State machine managing network lifecycle and coordination
  - `EtherCAT.Slave` - Individual slave device processes with driver-based configuration
  - `EtherCAT.Domain` - Process data domains for multi-rate cyclic communication
  - `EtherCAT.Slave.Driver` - Pluggable behavior for device-specific drivers

  ## Architecture

  All NIF communication is routed through the Master process to ensure thread-safe
  access to the underlying C library. This design prevents race conditions while
  maintaining OTP supervision and fault tolerance principles.

  ```
  EtherCAT.Master (GenStatem)
    ├─ EtherCAT.Slave (GenServer) - per device
    │   └─ Driver (behaviour implementation)
    └─ EtherCAT.Domain (GenServer) - per data group
        └─ Subscribers (GenServer) - change notifications
  ```

  ## Quick Start

      # Start a master
      {:ok, master} = EtherCAT.Master.start_link(update_interval: 1000)

      # Connect to the network
      :ok = EtherCAT.Master.connect(master)

      # Discover slaves
      {:ok, slaves} = EtherCAT.Master.sync_slaves(master)

      # Configure and register PDOs
      [_coupler, input, output] = slaves
      EtherCAT.Slave.configure(input, [])
      EtherCAT.Slave.register_all_pdos(input, :default_domain)
      EtherCAT.Slave.configure(output, [])
      EtherCAT.Slave.register_all_pdos(output, :default_domain)

      # Activate cyclic communication
      EtherCAT.Master.start_cyclic_mode(master)

      # Read/write process data
      EtherCAT.Slave.set_pdo_value(output, :output1, true)
      {:ok, value} = EtherCAT.Slave.get_pdo_value(input, :input1)

  ## Requirements

  - Linux kernel with IgH EtherCAT Master driver loaded
  - libethercat development libraries installed
  - Real-time kernel recommended for deterministic performance
  - Appropriate permissions for /dev/EtherCAT* devices

  ## Example Functions

  This module includes `test/0`, `test2/0`, and `test3/0` functions that
  demonstrate complete workflows. These are intended as interactive examples
  and integration tests - see their documentation for details.
  """
  alias EtherCAT.{Master, Slave}

  @doc """
  Interactive test demonstrating basic EtherCAT workflow with I/O loopback.

  This function demonstrates a complete EtherCAT session including:
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

  ## Returns

  `{master_pid, input_slave_pid, output_slave_pid}` for interactive testing
  in IEx. Keep these references to continue experimenting after the function
  returns.

  ## Example Session

      iex> {m, input, output} = EtherCAT.test()
      # Subscribe to input changes
      iex> EtherCAT.Slave.watch_pdo(input, "pdo_6000:1")
      # Toggle output (if looped back, you'll receive a notification)
      iex> EtherCAT.Slave.set_pdo_value(output, "pdo_7000:1", true)
      iex> flush()
      {:data_changed, "pdo_6000:1", true}
      iex> EtherCAT.Slave.set_pdo_value(output, "pdo_7000:1", false)

  ## Notes

  - Uses Generic driver for auto-discovery
  - PDO names follow the format "pdo_XXXX:Y" where XXXX is hex index
  - The function includes demonstration I/O operations before returning
  """
  @spec test() :: {pid(), pid(), pid()}
  def test do
    {:ok, master} = Master.start_link(update_interval: 1000)
    :ok = Master.connect(master)
    {:ok, [_koppler, di1, do1]} = Master.sync_slaves(master)
    Slave.configure(di1, [])
    Slave.list_pdos(di1) |> IO.inspect(label: "Input PDOs")
    Slave.configure(do1, [])
    Slave.list_pdos(do1) |> IO.inspect(label: "Output PDOs")
    Slave.register_all_pdos(di1, :default_domain)
    Slave.register_all_pdos(do1, :default_domain)
    Master.start_cyclic_mode(master)
    # I connected output 1 with input 1, so i should receive changes
    :timer.sleep(1000)
    Slave.watch_pdo(di1, "pdo_6000:1")
    :timer.sleep(500)
    Slave.set_pdo_value(do1, "pdo_7000:1", true)
    :timer.sleep(500)
    Slave.set_pdo_value(do1, "pdo_7000:1", false)
    :timer.sleep(500)
    Slave.set_pdo_value(do1, "pdo_7000:1", true)
    {master, di1, do1}
  end

  @doc """
  Interactive test demonstrating selective PDO registration.

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

  ## Returns

  The input slave PID for continued experimentation.

  ## Example Session

      iex> slave = EtherCAT.test2()
      # The slave is already configured and operational
      iex> EtherCAT.Slave.list_pdos(slave)
      ["pdo_6000:1", "pdo_6010:1", ...]
      iex> {:ok, value} = EtherCAT.Slave.get_pdo_value(slave, "pdo_6000:1")
  """
  @spec test2() :: pid()
  def test2 do
    {:ok, master} = Master.start_link()
    :ok = Master.connect(master)
    {:ok, [_slave1, slave2]} = Master.sync_slaves(master)

    Slave.configure(slave2, [])
    Slave.list_pdos(slave2) |> IO.inspect(label: "Options")
    Slave.register_all_pdos(slave2, :default_domain)

    Slave.register_pdos(
      slave2,
      [:input1, :input2, :input3, :input4, :input5, :input6, :input7, :input9],
      :default_domain
    )

    Master.start_cyclic_mode(master)
    slave2
  end

  @doc """
  Interactive test demonstrating multi-rate control with multiple domains.

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

  ## Returns

  The master PID for continued experimentation and monitoring.

  ## Example Session

      iex> master = EtherCAT.test3()
      # Monitor master state transitions
      iex> flush()
      {:master_state_changed, %{...}}
      # You can create additional domains dynamically
      iex> EtherCAT.Master.create_domain(master, :slow_poll, 1000)

  ## Use Cases

  - **Fast domain**: Critical control signals (valve positions, motor speeds)
  - **Medium domain**: Sensor readings (temperature, pressure)
  - **Slow domain**: Configuration data, diagnostics, status LEDs
  """
  @spec test3() :: pid()
  def test3 do
    {:ok, master} = Master.start_link()
    :ok = Master.connect(master)
    {:ok, [_slave1, slave2]} = Master.sync_slaves(master)
    Master.create_domain(master, :domain2, 100)

    Slave.configure(slave2, [])
    Slave.register_pdos(slave2, [:input1], :default_domain)
    Slave.register_all_pdos(slave2, :domain2)
    Master.start_cyclic_mode(master)
    master
  end
end
