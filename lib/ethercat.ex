defmodule EtherCAT do
  @moduledoc """
  EtherCAT library and main API.

  ## Installation

  Add EtherCAT to your application's supervision tree:

      children = [
        {EtherCAT, master_index: 0}
      ]

  Or use Master directly:

      children = [
        {EtherCAT.Master, master_index: 0, name: MyMaster}
      ]

  ## Two-Phase Initialization

  ### Phase 1: Start Infrastructure

  Add to your supervision tree as shown above.

  ### Phase 2: Configure Hardware

      # Configure and get slave PIDs
      {:ok, slaves} = EtherCAT.configure_hardware(master_pid, MyMachine)
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
          # driver uses auto-discovery by default (driver: nil)
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

      {:ok, slaves} = EtherCAT.configure_hardware(master_pid, MyMachine)
      {:ok, temp} = EtherCAT.read(slaves.temp_sensor, :ch1, :value)
      :ok = EtherCAT.write(slaves.valve1, :ch1, :value, true)

  ## Architecture

  - **Declarative**: Define hardware config once, reuse everywhere
  - **Direct access**: Work with slave PIDs directly, no wrapper structs
  - **Type-safe**: Drivers handle encoding/decoding
  - **Semantic names**: Use `:temp_sensor` instead of position 0
  - **Two-phase init**: Infrastructure managed separately from configuration
  """

  alias EtherCAT.Master
  alias EtherCAT.Config.HardwareConfig

  ## Supervision API

  @doc """
  Child spec that delegates to EtherCAT.Master.

  This allows you to add `{EtherCAT, opts}` to your supervision tree,
  which will start a Master process.

  ## Options
  - `:master_index` - EtherCAT master index (default: 0)
  - `:scan_interval` - Hardware change detection interval in µs (default: 100_000)

  ## Example

      children = [
        {EtherCAT, master_index: 0}
      ]
  """
  def child_spec(opts) do
    Master.child_spec(opts)
  end

  ## Configuration API

  @doc """
  Configure hardware and start slave drivers.

  Automatically stops any existing slaves and starts cyclic communication.

  ## Parameters
  - `master` - Master process PID or registered name
  - `config_or_module` - Configuration module or HardwareConfig struct

  ## Returns
  - `{:ok, slaves}` - Map of slave names to PIDs: `%{temp_sensor: pid, valve1: pid}`
  - `{:error, reason}` - Configuration error

  ## Examples

      {:ok, slaves} = EtherCAT.configure_hardware(master_pid, MyMachine)
      {:ok, temp} = EtherCAT.read(slaves.temp_sensor, :ch1, :value)
  """
  @spec configure_hardware(GenServer.server(), module() | HardwareConfig.t()) ::
          {:ok, %{atom() => pid()}} | {:error, term()}
  def configure_hardware(master, config_or_module) do
    with {:ok, config} <- get_config(config_or_module),
         :ok <- Master.set_hardware_config(master, config),
         {:ok, slave_pids} <-
           Master.start_cyclic(
             master,
             config.master.cycle_interval || 10_000,
             config.master.nif_yield_interval || 100_000
           ) do
      {:ok, slave_pids}
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
    GenServer.call(slave_pid, {:read, pdo_name, entry_name})
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
    GenServer.call(slave_pid, {:write, pdo_name, entry_name, value})
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
    GenServer.call(slave_pid, {:subscribe, pdo_name, entry_name, self()})
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
    GenServer.call(slave_pid, {:unsubscribe, pdo_name, entry_name, self()})
  end

  @doc """
  Generate hardware configuration by discovering connected slaves.

  Use this for hardware discovery mode when you don't know the slave configuration.

  ## Parameters
  - `master` - Master process PID or registered name

  ## Returns
  - `{:ok, config}` - Generated HardwareConfig
  - `{:error, reason}` - Master not synced or error

  ## Example

      {:ok, config} = EtherCAT.generate_config(master_pid)
      IO.inspect(config, pretty: true)
  """
  @spec generate_config(GenServer.server()) :: {:ok, HardwareConfig.t()} | {:error, term()}
  def generate_config(master) do
    Master.generate_config(master)
  end

  @doc """
  Get list of detected slave PIDs from Master.

  ## Parameters
  - `master` - Master process PID or registered name

  ## Returns
  - `{:ok, [pid]}` - List of slave PIDs
  - `{:error, reason}` - Master not synced yet

  ## Example

      {:ok, slaves} = EtherCAT.get_slaves(master_pid)
  """
  @spec get_slaves(GenServer.server()) :: {:ok, [pid()]} | {:error, term()}
  def get_slaves(master) do
    Master.get_slaves(master)
  end

  @doc """
  Stop all slave drivers and cyclic mode for a master.

  This function:
  1. Stops cyclic mode
  2. Stops all slave driver processes
  3. Clears the slave map

  ## Parameters
  - `master` - Master process PID or registered name

  ## Returns
  - `:ok` - Cleanup successful
  - `{:error, reason}` - Cleanup error

  ## Example

      :ok = EtherCAT.stop_slaves(master_pid)
  """
  @spec stop_slaves(GenServer.server()) :: :ok | {:error, term()}
  def stop_slaves(master) do
    with :ok <- Master.stop_cyclic(master),
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
end
