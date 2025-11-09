defmodule EtherCAT do
  @moduledoc """
  Simplified EtherCAT master implementation using the IgH EtherCAT Master for Linux.

  EtherCAT (Ethernet for Control Automation Technology) is a high-performance,
  deterministic industrial Ethernet protocol designed for real-time automation
  and motion control applications.

  This library provides a simplified, shallow Elixir interface to the IgH EtherCAT Master,
  enabling real-time industrial I/O from the BEAM VM.

  ## Simplified API

  The API is designed to be straightforward with minimal concepts:

  1. **Connection** - Open connection to master, auto-connect, and discover slaves
  2. **Configuration** - Configure slaves and register PDOs to domains
  3. **Operation** - Start cyclic communication and perform I/O
  4. **Cleanup** - Close and cleanup resources

  ## Quick Start

      # Open connection - auto-connects and returns slaves
      {:ok, master, slaves} = EtherCAT.open(update_interval: 1000)

      # Configure slaves and register PDOs
      [_coupler, input, output] = slaves
      {:ok, input_pdos} = EtherCAT.configure_slave(master, input, %{})
      {:ok, output_pdos} = EtherCAT.configure_slave(master, output, %{})

      {:ok, input_names} = EtherCAT.register_pdos(master, input, input_pdos)
      {:ok, output_names} = EtherCAT.register_pdos(master, output, output_pdos)

      # Start cyclic communication
      :ok = EtherCAT.start_cyclic(master)

      # Perform I/O using unique PDO names
      [first_output | _] = output_names
      :ok = EtherCAT.write(master, first_output, true)

      [first_input | _] = input_names
      {:ok, value} = EtherCAT.read(master, first_input)

      # Watch for changes
      :ok = EtherCAT.watch(master, first_input)
      receive do
        {:data_changed, ^first_input, new_value} ->
          IO.inspect(new_value, label: "Input changed")
      end

      # Cleanup
      EtherCAT.close(master)

  ## Multi-Domain Support

  For advanced use cases with different timing requirements:

      {:ok, master, slaves} = EtherCAT.open()

      # Create fast domain for critical control
      {:ok, _fast_domain} = EtherCAT.create_domain(master, :fast_io, 1)

      # Create slow domain for monitoring
      {:ok, _slow_domain} = EtherCAT.create_domain(master, :monitoring, 100)

      # Register PDOs to specific domains
      {:ok, _} = EtherCAT.register_pdos(master, slave, [:input1], :fast_io)
      {:ok, _} = EtherCAT.register_pdos(master, slave, [:input2], :monitoring)

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
  require Logger

  # Connection Lifecycle

  @doc """
  Opens a connection to the EtherCAT master, connects to the network, and discovers slaves.

  This is a convenience function that combines master initialization, network connection,
  and slave discovery into a single call.

  ## Options
  - `:master_index` - The EtherCAT master index (default: 0) - maps to /dev/EtherCATX
  - `:update_interval` - Cyclic task interval in microseconds (default: 10_000 = 10ms)
  - `:name` - Registration name (default: `EtherCAT.Master`)

  ## Returns
  - `{:ok, master, [slave_pids]}` - Master PID and list of discovered slave PIDs
  - `{:error, reason}` on failure

  ## Example

      # Open with default settings (10ms cycle)
      {:ok, master, slaves} = EtherCAT.open()

      # Open with 1ms cycle for faster control loops
      {:ok, master, slaves} = EtherCAT.open(update_interval: 1_000)
  """
  @spec open(keyword()) :: {:ok, pid(), [pid()]} | {:error, term()}
  def open(opts \\ []) do
    with {:ok, master} <- Master.start_link(opts),
         :ok <- Master.connect(master),
         {:ok, slaves} <- Master.sync_slaves(master) do
      {:ok, master, slaves}
    end
  end

  @doc """
  Closes the master connection and cleans up all resources.

  This stops the cyclic task, terminates all slave and domain processes,
  and releases the master resource.

  ## Parameters
  - `master` - The master process PID

  ## Returns
  - `:ok`

  ## Example

      EtherCAT.close(master)
  """
  @spec close(pid()) :: :ok
  def close(master) do
    GenServer.stop(master, :normal)
    :ok
  end

  # Domain Management

  @doc """
  Creates a new process data domain with independent update interval.

  Domains allow grouping of PDO entries with different timing requirements,
  enabling efficient multi-rate control loops on a single master.

  ## Parameters
  - `master` - The master process PID
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
  @spec create_domain(pid(), atom(), pos_integer()) :: {:ok, reference()} | {:error, term()}
  def create_domain(master, name, interval) do
    Master.create_domain(master, name, interval)
  end

  # Slave Configuration

  @doc """
  Applies driver-specific configuration to a slave and returns available PDOs.

  The configuration map is passed to the driver's `configure/2` callback,
  allowing device-specific initialization and setup.

  ## Parameters
  - `master` - The master process PID
  - `slave` - The slave process PID
  - `config` - Configuration map (driver-specific)

  ## Returns
  - `{:ok, [pdo_names]}` - List of available PDO names from the driver

  ## Example

      {:ok, pdos} = EtherCAT.configure_slave(master, slave, %{sample_rate: 1000})
      # pdos => ["pdo_6000:1", "pdo_6010:1", "pdo_7000:1"]
  """
  @spec configure_slave(pid(), pid(), map()) :: {:ok, list()}
  def configure_slave(_master, slave, config) do
    :ok = Slave.configure(slave, config)
    {:ok, Slave.list_pdos(slave)}
  end

  @doc """
  Registers named PDOs to a domain for cyclic data exchange.

  This configures the slave's sync managers and PDO mappings based on the
  driver's configuration, then registers the PDO entries with the specified
  domain for real-time I/O.

  **Important**: A PDO can only be registered to one domain. Attempting to
  register a PDO to multiple domains will return an error.

  ## Parameters
  - `master` - The master process PID
  - `slave` - The slave process PID
  - `pdo_names` - List of PDO names (from `configure_slave/3`)
  - `domain` - Domain identifier (default: `:default_domain`)

  ## Returns
  - `{:ok, [unique_pdo_names]}` - List of globally unique PDO identifiers
  - `{:error, {:pdo_already_registered, conflicts}}` - If PDOs are already registered

  ## Example

      {:ok, unique_names} = EtherCAT.register_pdos(master, slave, ["pdo_6000:1", "pdo_6010:1"])
      # unique_names => ["slave_1:pdo_6000:1", "slave_1:pdo_6010:1"]

      # Register to custom domain
      {:ok, names} = EtherCAT.register_pdos(master, slave, ["pdo_7000:1"], :fast_io)

      # Error if trying to register same PDO to different domain
      {:error, {:pdo_already_registered, _}} =
        EtherCAT.register_pdos(master, slave, ["pdo_6000:1"], :other_domain)
  """
  @spec register_pdos(pid(), pid(), [Slave.name()], Slave.domain()) ::
          {:ok, [String.t()]} | {:error, term()}
  def register_pdos(_master, slave, pdo_names, domain \\ :default_domain) do
    case Slave.register_pdos(slave, pdo_names, domain) do
      :ok ->
        # Get the slave position to construct unique names
        position = get_slave_position(slave)

        unique_names =
          Enum.map(pdo_names, fn name ->
            "slave_#{position}:#{name}"
          end)

        {:ok, unique_names}

      error ->
        error
    end
  end

  # Runtime I/O Operations

  @doc """
  Reads the current value of a PDO input.

  Reads the most recent value received from the slave during cyclic exchange.
  The PDO must have been registered before the master entered operational mode.

  ## Parameters
  - `master` - The master process PID
  - `unique_pdo` - Globally unique PDO name (from `register_pdos/4`)

  ## Returns
  - `{:ok, value}` on success
  - `{:error, reason}` if PDO not found or not registered

  ## Example

      {:ok, value} = EtherCAT.read(master, "slave_1:pdo_6000:1")
  """
  @spec read(pid(), String.t()) :: {:ok, term()} | {:error, term()}
  def read(master, unique_pdo) do
    case parse_unique_pdo(master, unique_pdo) do
      {:ok, slave, pdo_name} ->
        Slave.get_pdo_value(slave, pdo_name)

      error ->
        error
    end
  end

  @doc """
  Writes a value to a PDO output.

  Writes a value to an output PDO that will be sent to the slave during the
  next cyclic exchange. The PDO must have been registered before the master
  entered operational mode.

  ## Parameters
  - `master` - The master process PID
  - `unique_pdo` - Globally unique PDO name (from `register_pdos/4`)
  - `value` - Value to write (type depends on PDO configuration)

  ## Returns
  - `:ok` on success
  - `{:error, reason}` if PDO not found or not registered

  ## Example

      :ok = EtherCAT.write(master, "slave_2:pdo_7000:1", true)
      :ok = EtherCAT.write(master, "slave_2:pdo_7010:1", 42)
  """
  @spec write(pid(), String.t(), term()) :: :ok | {:error, term()}
  def write(master, unique_pdo, value) do
    case parse_unique_pdo(master, unique_pdo) do
      {:ok, slave, pdo_name} ->
        Slave.set_pdo_value(slave, pdo_name, value)

      error ->
        error
    end
  end

  @doc """
  Watches a PDO for changes.

  Subscribes the calling process to receive notifications when a PDO value changes.
  The subscriber will receive `{:data_changed, unique_pdo, value}` messages whenever
  the PDO value changes during cyclic operation.

  ## Parameters
  - `master` - The master process PID
  - `unique_pdo` - Globally unique PDO name (from `register_pdos/4`)

  ## Returns
  - `:ok` on success
  - `{:error, reason}` if PDO not found or not registered

  ## Example

      :ok = EtherCAT.watch(master, "slave_1:pdo_6000:1")

      receive do
        {:data_changed, "slave_1:pdo_6000:1", value} ->
          IO.puts("PDO changed to: \#{value}")
      end
  """
  @spec watch(pid(), String.t()) :: :ok | {:error, term()}
  def watch(master, unique_pdo) do
    case parse_unique_pdo(master, unique_pdo) do
      {:ok, slave, pdo_name} ->
        Slave.watch_pdo(slave, pdo_name, self())

      error ->
        error
    end
  end

  @doc """
  Unwatches a PDO to stop receiving change notifications.

  Unsubscribes the calling process from notifications for the specified PDO.

  ## Parameters
  - `master` - The master process PID
  - `unique_pdo` - Globally unique PDO name (from `register_pdos/4`)

  ## Returns
  - `:ok` on success
  - `{:error, reason}` if PDO not found or not registered

  ## Example

      :ok = EtherCAT.watch(master, "slave_1:pdo_6000:1")
      # ... receive some notifications ...
      :ok = EtherCAT.unwatch(master, "slave_1:pdo_6000:1")
  """
  @spec unwatch(pid(), String.t()) :: :ok | {:error, term()}
  def unwatch(master, unique_pdo) do
    case parse_unique_pdo(master, unique_pdo) do
      {:ok, slave, pdo_name} ->
        Slave.unwatch_pdo(slave, pdo_name, self())

      error ->
        error
    end
  end

  # Operational Mode

  @doc """
  Activates cyclic mode operation on the master.

  Registers all pending PDO entries, activates the master, and starts the
  real-time cyclic task. After activation, no further configuration changes
  are allowed - slaves and domains become locked.

  ## Parameters
  - `master` - The master process PID

  ## Returns
  - `:ok` (async operation)

  ## Example

      EtherCAT.start_cyclic(master)
      # Master now running cyclic communication
  """
  @spec start_cyclic(pid()) :: :ok
  def start_cyclic(master) do
    Master.start_cyclic_mode(master)
  end

  # Private Helpers

  # Parses a unique PDO name into slave PID and PDO name
  # Format: "slave_<position>:<pdo_name>"
  defp parse_unique_pdo(master, unique_pdo) do
    case String.split(unique_pdo, ":", parts: 2) do
      ["slave_" <> position_str, pdo_name] ->
        case Integer.parse(position_str) do
          {position, ""} ->
            case find_slave_by_position(master, position) do
              {:ok, slave} -> {:ok, slave, pdo_name}
              error -> error
            end

          _ ->
            {:error, {:invalid_unique_pdo, unique_pdo}}
        end

      _ ->
        {:error, {:invalid_unique_pdo, unique_pdo}}
    end
  end

  # Finds a slave process by its position using the Registry
  defp find_slave_by_position(master, position) do
    case Registry.lookup(EtherCAT.Registry, {:slave, master, position}) do
      [{slave_pid, _}] -> {:ok, slave_pid}
      [] -> {:error, {:slave_not_found, position}}
    end
  end

  # Gets the position of a slave process using Registry
  defp get_slave_position(slave_pid) do
    case Registry.keys(EtherCAT.Registry, slave_pid) do
      [{:slave, _master, position}] -> position
      _ -> nil
    end
  end
end
