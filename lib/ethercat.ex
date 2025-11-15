defmodule EtherCAT do
  @moduledoc """
  EtherCAT application and main API.

  ## Two-Phase Initialization

  ### Phase 1: Start Infrastructure

  The EtherCAT application automatically starts the Master in your supervision tree.
  Alternatively, start manually:

      {:ok, _pid} = EtherCAT.start_link(master_index: 0)

  ### Phase 2: Configure Hardware

      # Configure and get slave PIDs
      {:ok, slaves} = EtherCAT.configure_hardware(0, MyMachine)
      # slaves = %{temp_sensor: #PID<0.123.0>, valve1: #PID<0.124.0>, ...}

  ## Usage

  Work directly with slave PIDs:

      {:ok, value} = EtherCAT.read(slaves.temp_sensor, :ch1, :value)
      :ok = EtherCAT.write(slaves.valve1, :control, :command, true)
      :ok = EtherCAT.watch(slaves.temp_sensor, :ch1, :value)

      receive do
        {:pdo_value_changed, unique_name, value} ->
          IO.puts("Value changed: \#{value}")
      end

  ## Quick Start

  Define your hardware configuration:

      defmodule MyMachine do
        use EtherCAT.Config

        master do
          index 0
          cycle_interval 10_000
        end

        domain :fast_loop, interval: 1

        slave position: 0, name: :temp_sensor do
          driver EtherCAT.Drivers.EL3202
          expect vendor: 0x00000002, product: 0x0C5A3052

          config do
            limit1 1000
            limit2 2000
          end

          entry :ch1, :value, domain: :fast_loop
          entry :ch1, :error, domain: :fast_loop
        end
      end

  Then configure and use the system:

      {:ok, slaves} = EtherCAT.configure_hardware(0, MyMachine)
      {:ok, temp} = EtherCAT.read(slaves.temp_sensor, :ch1, :value)
      :ok = EtherCAT.write(slaves.valve1, :ch1, :value, true)

  ## Architecture

  - **Declarative**: Define hardware config once, reuse everywhere
  - **Direct access**: Work with slave PIDs directly, no wrapper structs
  - **Type-safe**: Drivers handle encoding/decoding
  - **Semantic names**: Use `:temp_sensor` instead of position 0
  - **Two-phase init**: Infrastructure managed separately from configuration
  """

  use Supervisor

  alias EtherCAT.Master
  alias EtherCAT.Config.HardwareConfig

  ## Supervision API

  @doc """
  Starts the EtherCAT application supervisor.

  This is typically called automatically by the application supervision tree,
  but can be started manually for testing or embedded use.

  ## Options
  - `:master_index` - EtherCAT master index (default: 0)
  - `:scan_interval` - Hardware change detection interval in µs (default: 100_000)
  """
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    children = [
      {Registry, keys: :unique, name: EtherCAT.Registry},
      {Master, opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  ## Configuration API

  @doc """
  Configure hardware and start slave drivers.

  Automatically stops any existing slaves and starts cyclic communication.

  ## Parameters
  - `master_index` - Master index (integer)
  - `config_or_module` - Configuration module or HardwareConfig struct

  ## Returns
  - `{:ok, slaves}` - Map of slave names to PIDs: `%{temp_sensor: pid, valve1: pid}`
  - `{:error, reason}` - Configuration error

  ## Examples

      {:ok, slaves} = EtherCAT.configure_hardware(0, MyMachine)
      {:ok, temp} = EtherCAT.read(slaves.temp_sensor, :ch1, :value)
  """
  @spec configure_hardware(non_neg_integer(), module() | HardwareConfig.t()) ::
          {:ok, %{atom() => pid()}} | {:error, term()}
  def configure_hardware(master_index, config_or_module) when is_integer(master_index) do
    with {:ok, master} <- find_master(master_index),
         {:ok, config} <- get_config(config_or_module),
         {:ok, slave_pids} <- Master.configure_and_start_slaves(master, config) do
      {:ok, slave_pids}
    end
  end

  @doc """
  Find a Master process by index.

  ## Parameters
  - `master_index` - Master index (default: 0)

  ## Returns
  - `{:ok, pid}` - Master process PID
  - `{:error, reason}` - Master not found

  ## Example

      {:ok, master} = EtherCAT.find_master(0)
  """
  @spec find_master(non_neg_integer()) :: {:ok, pid()} | {:error, term()}
  def find_master(master_index \\ 0) do
    case Registry.lookup(EtherCAT.Registry, {:master, master_index}) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, {:master_not_found, master_index}}
    end
  end

  ## I/O API - Direct slave PID access

  @doc """
  Reads a PDO entry value from a slave.

  ## Parameters
  - `slave_pid` - Slave driver process PID
  - `pdo_name` - PDO identifier (atom)
  - `entry_name` - Entry identifier (atom)

  ## Returns
  - `{:ok, value}` - Decoded entry value
  - `{:error, reason}` - Read error

  ## Example

      {:ok, slaves} = EtherCAT.configure_hardware(0, MyConfig)
      {:ok, temp} = EtherCAT.read(slaves.temp_sensor, :ch1, :value)
  """
  @spec read(pid(), atom(), atom()) :: {:ok, term()} | {:error, term()}
  def read(slave_pid, pdo_name, entry_name) when is_pid(slave_pid) do
    # Delegate to driver's read/3 callback
    apply_driver_callback(slave_pid, :read, [slave_pid, pdo_name, entry_name])
  end

  @doc """
  Writes a value to a PDO entry in a slave.

  ## Parameters
  - `slave_pid` - Slave driver process PID
  - `pdo_name` - PDO identifier (atom)
  - `entry_name` - Entry identifier (atom)
  - `value` - Value to write (will be encoded by driver)

  ## Returns
  - `:ok` - Write successful
  - `{:error, reason}` - Write error

  ## Example

      {:ok, slaves} = EtherCAT.configure_hardware(0, MyConfig)
      :ok = EtherCAT.write(slaves.valve1, :ch1, :value, true)
  """
  @spec write(pid(), atom(), atom(), term()) :: :ok | {:error, term()}
  def write(slave_pid, pdo_name, entry_name, value) when is_pid(slave_pid) do
    # Delegate to driver's write/4 callback
    apply_driver_callback(slave_pid, :write, [slave_pid, pdo_name, entry_name, value])
  end

  @doc """
  Subscribes to value change notifications for a PDO entry.

  The calling process will receive `{:pdo_value_changed, unique_name, value}`
  messages when the entry value changes.

  ## Parameters
  - `slave_pid` - Slave driver process PID
  - `pdo_name` - PDO identifier (atom)
  - `entry_name` - Entry identifier (atom)

  ## Returns
  - `:ok` - Subscription successful
  - `{:error, reason}` - Subscription error

  ## Example

      {:ok, slaves} = EtherCAT.configure_hardware(0, MyConfig)
      :ok = EtherCAT.watch(slaves.temp_sensor, :ch1, :value)

      receive do
        {:pdo_value_changed, _name, temp} ->
          IO.puts("Temperature changed: \#{temp}")
      end
  """
  @spec watch(pid(), atom(), atom()) :: :ok | {:error, term()}
  def watch(slave_pid, pdo_name, entry_name) when is_pid(slave_pid) do
    # Delegate to driver's subscribe/4 callback
    apply_driver_callback(slave_pid, :subscribe, [slave_pid, pdo_name, entry_name, self()])
  end

  @doc """
  Unsubscribes from value change notifications for a PDO entry.

  ## Parameters
  - `slave_pid` - Slave driver process PID
  - `pdo_name` - PDO identifier (atom)
  - `entry_name` - Entry identifier (atom)

  ## Returns
  - `:ok` - Unsubscription successful
  - `{:error, reason}` - Unsubscription error

  ## Example

      :ok = EtherCAT.unwatch(slaves.temp_sensor, :ch1, :value)
  """
  @spec unwatch(pid(), atom(), atom()) :: :ok | {:error, term()}
  def unwatch(slave_pid, pdo_name, entry_name) when is_pid(slave_pid) do
    # Delegate to driver's unsubscribe/4 callback
    apply_driver_callback(slave_pid, :unsubscribe, [slave_pid, pdo_name, entry_name, self()])
  end

  @doc """
  Generate hardware configuration by discovering connected slaves.

  Use this for hardware discovery mode when you don't know the slave configuration.

  ## Parameters
  - `master_index` - Master index (integer)

  ## Returns
  - `{:ok, config}` - Generated HardwareConfig
  - `{:error, reason}` - Master not synced or error

  ## Example

      {:ok, config} = EtherCAT.generate_config(0)
      IO.inspect(config, pretty: true)
  """
  @spec generate_config(non_neg_integer()) :: {:ok, HardwareConfig.t()} | {:error, term()}
  def generate_config(master_index) when is_integer(master_index) do
    with {:ok, master} <- find_master(master_index) do
      Master.generate_config(master)
    end
  end

  @doc """
  Get list of detected slave PIDs from Master.

  ## Parameters
  - `master_index` - Master index (integer)

  ## Returns
  - `{:ok, [pid]}` - List of slave PIDs
  - `{:error, reason}` - Master not synced yet

  ## Example

      {:ok, slaves} = EtherCAT.get_slaves(0)
  """
  @spec get_slaves(non_neg_integer()) :: {:ok, [pid()]} | {:error, term()}
  def get_slaves(master_index) when is_integer(master_index) do
    with {:ok, master} <- find_master(master_index) do
      Master.get_slaves(master)
    end
  end

  @doc """
  Stop all slave drivers and cyclic mode for a master.

  This function:
  1. Stops cyclic mode
  2. Stops all slave driver processes
  3. Clears the slave map

  ## Parameters
  - `master_index` - Master index (integer)

  ## Returns
  - `:ok` - Cleanup successful
  - `{:error, reason}` - Cleanup error

  ## Example

      :ok = EtherCAT.stop_slaves(0)
  """
  @spec stop_slaves(non_neg_integer()) :: :ok | {:error, term()}
  def stop_slaves(master_index) when is_integer(master_index) do
    with {:ok, master} <- find_master(master_index),
         :ok <- Master.stop_cyclic(master),
         {:ok, slave_pids} <- Master.get_slaves(master) do
      # Stop all slave drivers
      Enum.each(slave_pids, fn pid ->
        if Process.alive?(pid) do
          GenServer.stop(pid, :normal)
        end
      end)

      :ok
    end
  end

  ## Private Helpers

  defp get_config(module) when is_atom(module) do
    if function_exported?(module, :hardware_config, 0) do
      {:ok, module.hardware_config()}
    else
      {:error, {:invalid_config_module, module}}
    end
  end

  defp get_config(%HardwareConfig{} = config), do: {:ok, config}
  defp get_config(other), do: {:error, {:invalid_config, other}}

  # Look up the driver module and call its function
  defp apply_driver_callback(slave_pid, function, args) do
    case Registry.lookup(EtherCAT.Registry, {:slave, slave_pid}) do
      [{^slave_pid, %{driver: driver_module}}] ->
        # Check if function is exported
        if function_exported?(driver_module, function, length(args)) do
          apply(driver_module, function, args)
        else
          {:error, {:callback_not_implemented, driver_module, function, length(args)}}
        end

      [] ->
        {:error, {:slave_not_found, slave_pid}}
    end
  end
end
