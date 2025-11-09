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

      # Open a connection to the EtherCAT master
      {:ok, master} = EtherCAT.open(update_interval: 1000)
      :ok = EtherCAT.connect(master)

      # Discover slaves on the bus
      {:ok, slaves} = EtherCAT.list_slaves(master)

      # Configure and register PDOs
      [_coupler, input, output] = slaves
      EtherCAT.configure_slave(input, [])
      EtherCAT.register_all_pdos(input, :default_domain)
      EtherCAT.configure_slave(output, [])
      EtherCAT.register_all_pdos(output, :default_domain)

      # Activate cyclic communication
      EtherCAT.start_cyclic(master)

      # Read/write process data
      EtherCAT.write(output, :output1, true)
      {:ok, value} = EtherCAT.read(input, :input1)

      # Watch for changes
      EtherCAT.watch(input, :input1)
      receive do
        {:data_changed, :input1, new_value} ->
          IO.inspect(new_value, label: "Input changed")
      end

  ## Requirements

  - Linux kernel with IgH EtherCAT Master driver loaded
  - libethercat development libraries installed
  - Real-time kernel recommended for deterministic performance
  - Appropriate permissions for /dev/EtherCAT* devices

  ## Testing

  For hardware testing examples, see the `test/hardware/` directory.
  These tests demonstrate complete workflows with real EtherCAT devices.
  """

  alias EtherCAT.{Master, Slave, Domain}

  # Master Operations

  @doc """
  Opens a connection to the EtherCAT master.

  Initializes a master instance and creates the default domain. The master
  begins in the `:offline` state and must be connected to the network via
  `connect/1` before use.

  ## Options
  - `:master_index` - The EtherCAT master index (default: 0) - maps to /dev/EtherCATX
  - `:update_interval` - Cyclic task interval in microseconds (default: 10_000 = 10ms)
  - `:name` - Registration name (default: `EtherCAT.Master`)

  ## Returns
  - `{:ok, pid}` on success
  - `{:error, reason}` on failure (e.g., master device not found)

  ## Example

      # Open with default settings (10ms cycle)
      {:ok, master} = EtherCAT.open()

      # Open with 1ms cycle for faster control loops
      {:ok, master} = EtherCAT.open(update_interval: 1_000)
  """
  @spec open(keyword()) :: {:ok, pid()} | {:error, term()}
  def open(opts \\ []), do: Master.start_link(opts)

  @doc """
  Connects to the EtherCAT network and verifies link status.

  Transitions the master from `:offline` to `:stale` state if the network
  link is up. The master will then wait for slaves to respond.

  ## Returns
  - `:ok` if connection successful and link is up
  - `{:error, :link_down}` if physical link is not established
  - `{:error, :offline}` if called from the wrong state

  ## Example

      :ok = EtherCAT.connect(master)
  """
  @spec connect(GenServer.server()) :: :ok | {:error, term()}
  defdelegate connect(master), to: Master

  @doc """
  Discovers and synchronizes all slaves on the bus.

  Queries the master for all responding slaves, creates a process for each,
  and assigns appropriate drivers. The master transitions to `:synced` state.

  Alias for `EtherCAT.Master.sync_slaves/1` with a more intuitive name.

  ## Returns
  - `{:ok, [slave_pids]}` - List of slave process PIDs in bus order
  - `{:error, reason}` - If called from wrong state or slaves not responding

  ## Example

      {:ok, slaves} = EtherCAT.list_slaves(master)
      [coupler, input_terminal, output_terminal] = slaves
  """
  @spec list_slaves(GenServer.server()) :: {:ok, [pid()]} | {:error, term()}
  def list_slaves(master), do: Master.sync_slaves(master)

  @doc """
  Creates a new process data domain with independent update interval.

  Domains allow grouping of PDO entries with different timing requirements,
  enabling efficient multi-rate control loops on a single master.

  ## Parameters
  - `master` - The master process (PID or registered name)
  - `name` - Unique identifier for the domain (atom)
  - `interval` - Update interval multiplier (in cycles)

  ## Returns
  - `{:ok, domain_ref}` - Reference to the created domain
  - `{:error, reason}` - If domain creation fails

  ## Example

      # Fast domain for critical control (every cycle)
      {:ok, fast} = EtherCAT.create_domain(master, :fast_io, 1)

      # Slow domain for monitoring (every 100 cycles)
      {:ok, slow} = EtherCAT.create_domain(master, :monitoring, 100)
  """
  @spec create_domain(GenServer.server(), atom(), pos_integer()) ::
          {:ok, reference()} | {:error, term()}
  defdelegate create_domain(master, name, interval), to: Master

  @doc """
  Activates cyclic mode operation on the master.

  Registers all pending PDO entries, activates the master, and starts the
  real-time cyclic task. After activation, no further configuration changes
  are allowed - slaves and domains become locked.

  Alias for `EtherCAT.Master.start_cyclic_mode/1`.

  ## Example

      EtherCAT.start_cyclic(master)
      # Master now running cyclic communication
  """
  @spec start_cyclic(GenServer.server()) :: :ok
  def start_cyclic(master), do: Master.start_cyclic_mode(master)

  @doc """
  Alias for `start_cyclic/1`.

  Activates the master and begins real-time cyclic operation.
  """
  @spec activate(GenServer.server()) :: :ok
  def activate(master), do: start_cyclic(master)

  # Slave Operations

  @doc """
  Applies driver-specific configuration to a slave.

  The configuration map is passed to the driver's `configure/2` callback,
  allowing device-specific initialization and setup.

  ## Parameters
  - `slave` - The slave process PID
  - `config` - Configuration map (driver-specific)

  ## Example

      EtherCAT.configure_slave(slave, %{sample_rate: 1000, mode: :continuous})
  """
  @spec configure_slave(pid(), map()) :: :ok
  def configure_slave(slave, config), do: Slave.configure(slave, config)

  @doc """
  Lists all available PDO names from the slave's driver.

  The returned list depends on the driver implementation:
  - Generic driver: Auto-discovered names like "pdo_6000:1"
  - Device-specific drivers: Semantic names like :temperature, :pressure

  ## Returns
  List of PDO identifiers (atoms or strings)

  ## Example

      pdos = EtherCAT.list_pdos(slave)
      #=> [:input1, :input2, :output1]
  """
  @spec list_pdos(pid()) :: [atom() | String.t()]
  defdelegate list_pdos(slave), to: Slave

  @doc """
  Registers named PDOs to a domain for cyclic data exchange.

  This configures the slave's sync managers and PDO mappings based on the
  driver's configuration, then registers the PDO entries with the specified
  domain for real-time I/O.

  ## Parameters
  - `slave` - The slave process PID
  - `names` - List of PDO names (from `list_pdos/1`)
  - `domain` - Domain identifier (default: `:default_domain`)

  ## Example

      EtherCAT.register_pdos(slave, [:input1, :input2], :default_domain)
  """
  @spec register_pdos(pid(), [Slave.name()], Slave.domain()) :: :ok
  def register_pdos(slave, names, domain \\ :default_domain),
    do: Slave.register_pdos(slave, names, domain)

  @doc """
  Convenience function to register all available PDOs to a domain.

  Equivalent to calling `register_pdos(slave, list_pdos(slave), domain)`.

  ## Example

      # Register all PDOs to the default domain
      EtherCAT.register_all_pdos(slave)

      # Register all PDOs to a custom domain
      EtherCAT.register_all_pdos(slave, :slow_domain)
  """
  @spec register_all_pdos(pid(), Slave.domain()) :: :ok
  def register_all_pdos(slave, domain \\ :default_domain),
    do: Slave.register_all_pdos(slave, domain)

  @doc """
  Writes a value to a PDO output.

  Writes a value to an output PDO that will be sent to the slave during the
  next cyclic exchange. The PDO must have been registered before the master
  entered operational mode.

  ## Parameters
  - `slave` - The slave process PID
  - `pdo` - PDO name (as returned by `list_pdos/1`)
  - `value` - Value to write (type depends on PDO configuration)

  ## Returns
  - `:ok` on success
  - `{:error, reason}` if PDO not found or not registered

  ## Example

      # Write a boolean output
      EtherCAT.write(slave, :output1, true)

      # Write an integer output
      EtherCAT.write(slave, "pdo_7010:1", 42)
  """
  @spec write(pid(), Slave.name(), term()) :: :ok | {:error, term()}
  def write(slave, pdo, value), do: Slave.set_pdo_value(slave, pdo, value)

  @doc """
  Reads the current value of a PDO input.

  Reads the most recent value received from the slave during cyclic exchange.
  The PDO must have been registered before the master entered operational mode.

  ## Parameters
  - `slave` - The slave process PID
  - `pdo` - PDO name (as returned by `list_pdos/1`)

  ## Returns
  - `{:ok, value}` on success
  - `{:error, reason}` if PDO not found or not registered

  ## Example

      {:ok, temperature} = EtherCAT.read(slave, :temperature)
      {:ok, input_state} = EtherCAT.read(slave, "pdo_6000:1")
  """
  @spec read(pid(), Slave.name()) :: {:ok, term()} | {:error, term()}
  def read(slave, pdo), do: Slave.get_pdo_value(slave, pdo)

  @doc """
  Watches a PDO for changes.

  Subscribes a process to receive notifications when a PDO value changes.
  The subscriber will receive `{:data_changed, pdo, value}` messages whenever
  the PDO value changes during cyclic operation.

  ## Parameters
  - `slave` - The slave process PID
  - `pdo` - PDO name to watch
  - `pid` - Process to receive notifications (default: calling process)

  ## Returns
  - `:ok` on success
  - `{:error, reason}` if PDO not found or not registered

  ## Example

      # Watch from the calling process
      EtherCAT.watch(slave, :temperature)

      receive do
        {:data_changed, :temperature, value} ->
          IO.puts("Temperature changed to: \#{value}")
      end

      # Watch from another process
      EtherCAT.watch(slave, :pressure, monitor_pid)
  """
  @spec watch(pid(), Slave.name(), pid()) :: :ok | {:error, term()}
  def watch(slave, pdo, pid \\ self()), do: Slave.watch_pdo(slave, pdo, pid)

  # Domain Operations

  @doc """
  Returns the domain's NIF reference.

  This reference is used internally for domain operations. Most users won't
  need to call this directly.
  """
  @spec get_domain_ref(GenServer.server()) :: reference()
  def get_domain_ref(domain), do: Domain.get_ref(domain)

  @doc """
  Returns the domain's update interval in microseconds.

  The interval determines how often the domain's data is exchanged during
  cyclic operation.

  ## Example

      interval = EtherCAT.get_domain_interval(:default_domain)
      #=> 1
  """
  @spec get_domain_interval(GenServer.server()) :: pos_integer()
  def get_domain_interval(domain), do: Domain.get_interval(domain)

  # Advanced Operations
  # For users who need direct access to the underlying modules:
  # - EtherCAT.Master.*
  # - EtherCAT.Slave.*
  # - EtherCAT.Domain.*
end
