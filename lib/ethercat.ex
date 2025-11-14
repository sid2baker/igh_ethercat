defmodule EtherCAT do
  @moduledoc """
  EtherCAT application and main API.

  ## Two-Phase Initialization

  ### Phase 1: Start Infrastructure

  The EtherCAT application automatically starts the Master in your supervision tree.
  Alternatively, start manually:

      {:ok, _pid} = EtherCAT.start_link(master_index: 0, scan_interval: 100_000)

  ### Phase 2: Configure Hardware

      # Option A: Use predefined configuration
      {:ok, system} = EtherCAT.configure_hardware(MyMachine)

      # Option B: Discover and generate config
      {:ok, config} = EtherCAT.generate_config()
      {:ok, system} = EtherCAT.configure_hardware(config)

  ## Usage

      {:ok, value} = EtherCAT.read(system, :temp_sensor, :ch1, :value)
      :ok = EtherCAT.write(system, :valve1, :control, :command, true)

  ## Reconfiguration

      :ok = EtherCAT.stop_system(system)
      {:ok, new_system} = EtherCAT.configure_hardware(NewConfig)

  ## Quick Start

  Define your hardware configuration using the Spark DSL:

      defmodule MyMachine do
        use EtherCAT.Config

        master do
          index 0
          cycle_interval 10_000
          nif_yield_interval 100_000
        end

        domain :fast_loop, interval: 1
        domain :slow_loop, interval: 10

        slave position: 0, name: :temp_sensor do
          driver EtherCAT.Drivers.EL3202
          expect vendor: 0x00000002, product: 0x0C5A3052

          config do
            limit1 1000
            limit2 2000
          end

          entry :ch1, :value, domain: :fast_loop
          entry :ch1, :error, domain: :slow_loop
        end
      end

  Then configure and use the system:

      {:ok, system} = EtherCAT.configure_hardware(MyMachine)
      {:ok, temp} = EtherCAT.read(system, :temp_sensor, :ch1, :value)
      :ok = EtherCAT.write(system, :output_slave, :ch1, :value, true)
      EtherCAT.stop_system(system)

  ## Architecture

  - **Declarative**: Define hardware config once, reuse everywhere
  - **Type-safe**: Spark DSL validates at compile time
  - **Semantic names**: Use `:temp_sensor` instead of position 0
  - **Multi-domain**: Different update rates for critical vs diagnostic data
  - **Two-phase init**: Infrastructure managed separately from configuration
  """

  use Supervisor

  alias EtherCAT.{Master, System, Slave}
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
  Configure hardware and create an operational System.

  This is the main entry point for configuring the EtherCAT network.

  ## Examples

      # With module-based config
      {:ok, system} = EtherCAT.configure_hardware(MyMachine)

      # With HardwareConfig struct
      {:ok, config} = EtherCAT.generate_config()
      {:ok, system} = EtherCAT.configure_hardware(config)

  ## Options
  - `:master_index` - Which master to use (default: 0)
  """
  @spec configure_hardware(module() | HardwareConfig.t(), keyword()) ::
          {:ok, System.t()} | {:error, term()}
  def configure_hardware(config_or_module, opts \\ []) do
    master_index = Keyword.get(opts, :master_index, 0)

    with {:ok, master} <- find_master(master_index),
         {:ok, config} <- get_config(config_or_module),
         :ok <- verify_hardware(master, config),
         {:ok, system} <- System.configure(master, config) do
      {:ok, system}
    end
  end

  @doc """
  Stop a System and release its resources.

  The Master remains running and can be reconfigured with a new System.
  """
  @spec stop_system(System.t()) :: :ok
  def stop_system(%System{} = system) do
    System.close(system)
  end

  @doc """
  Verify that current hardware matches the configuration without applying it.

  Useful for checking compatibility before reconfiguring.
  """
  @spec verify_hardware(module() | HardwareConfig.t(), keyword()) ::
          :ok | {:error, term()}
  def verify_hardware(config_or_module, opts \\ []) do
    master_index = Keyword.get(opts, :master_index, 0)

    with {:ok, master} <- find_master(master_index),
         {:ok, config} <- get_config(config_or_module) do
      verify_hardware(master, config)
    end
  end

  @doc """
  Generate a HardwareConfig by scanning current hardware.

  Auto-detects drivers based on vendor/product IDs.

  ## Options
  - `:master_index` - Which master to scan (default: 0)
  """
  @spec generate_config(keyword()) :: {:ok, HardwareConfig.t()} | {:error, term()}
  def generate_config(opts \\ []) do
    master_index = Keyword.get(opts, :master_index, 0)

    with {:ok, master} <- find_master(master_index),
         {:ok, slaves} <- Master.get_slaves(master) do
      System.generate_hardware_config(slaves)
    end
  end

  ## I/O API (delegate to System)

  @doc """
  Reads a PDO entry value from the system.

  ## Parameters
  - `system` - System handle
  - `slave_name` - Slave name from configuration (atom)
  - `pdo_name` - PDO identifier (atom)
  - `entry_name` - Entry identifier (atom)

  ## Returns
  - `{:ok, value}` - Decoded entry value
  - `{:error, reason}` - Read error or entry not found

  ## Example

      {:ok, temp} = EtherCAT.read(system, :temp_sensor, :ch1, :value)
      {:ok, error_flag} = EtherCAT.read(system, :temp_sensor, :ch1, :error)
  """
  @spec read(System.t(), atom(), atom(), atom()) :: {:ok, term()} | {:error, term()}
  def read(%System{} = system, slave_name, pdo_name, entry_name) do
    with {:ok, slave_pid} <- System.find_entry(system, slave_name, pdo_name, entry_name) do
      Slave.read_entry(slave_pid, pdo_name, entry_name)
    end
  end

  @doc """
  Writes a value to a PDO entry in the system.

  ## Parameters
  - `system` - System handle
  - `slave_name` - Slave name from configuration (atom)
  - `pdo_name` - PDO identifier (atom)
  - `entry_name` - Entry identifier (atom)
  - `value` - Value to write (will be encoded by driver)

  ## Returns
  - `:ok` - Write successful
  - `{:error, reason}` - Write error or entry not found

  ## Example

      :ok = EtherCAT.write(system, :valve_outputs, :ch1, :value, true)
      :ok = EtherCAT.write(system, :motor_drive, :setpoint, :velocity, 1500)
  """
  @spec write(System.t(), atom(), atom(), atom(), term()) :: :ok | {:error, term()}
  def write(%System{} = system, slave_name, pdo_name, entry_name, value) do
    with {:ok, slave_pid} <- System.find_entry(system, slave_name, pdo_name, entry_name) do
      Slave.write_entry(slave_pid, pdo_name, entry_name, value)
    end
  end

  @doc """
  Subscribes to value change notifications for a PDO entry.

  The calling process will receive `{:pdo_value_changed, unique_name, value}`
  messages when the entry value changes.

  ## Parameters
  - `system` - System handle
  - `slave_name` - Slave name from configuration (atom)
  - `pdo_name` - PDO identifier (atom)
  - `entry_name` - Entry identifier (atom)

  ## Returns
  - `:ok` - Subscription successful
  - `{:error, reason}` - Subscription error or entry not found

  ## Example

      :ok = EtherCAT.watch(system, :temp_sensor, :ch1, :value)

      receive do
        {:pdo_value_changed, _name, temp} ->
          IO.puts("Temperature changed: #{temp}")
      end
  """
  @spec watch(System.t(), atom(), atom(), atom()) :: :ok | {:error, term()}
  def watch(%System{} = system, slave_name, pdo_name, entry_name) do
    with {:ok, slave_pid} <- System.find_entry(system, slave_name, pdo_name, entry_name) do
      Slave.watch_entry(slave_pid, pdo_name, entry_name, self())
    end
  end

  @doc """
  Unsubscribes from value change notifications for a PDO entry.

  ## Parameters
  - `system` - System handle
  - `slave_name` - Slave name from configuration (atom)
  - `pdo_name` - PDO identifier (atom)
  - `entry_name` - Entry identifier (atom)

  ## Returns
  - `:ok` - Unsubscription successful
  - `{:error, reason}` - Unsubscription error or entry not found

  ## Example

      :ok = EtherCAT.unwatch(system, :temp_sensor, :ch1, :value)
  """
  @spec unwatch(System.t(), atom(), atom(), atom()) :: :ok | {:error, term()}
  def unwatch(%System{} = system, slave_name, pdo_name, entry_name) do
    with {:ok, slave_pid} <- System.find_entry(system, slave_name, pdo_name, entry_name) do
      Slave.unwatch_entry(slave_pid, pdo_name, entry_name, self())
    end
  end

  ## Private Helpers

  defp find_master(master_index) do
    case Registry.lookup(EtherCAT.Registry, {:master, master_index}) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, {:master_not_found, master_index}}
    end
  end

  defp get_config(module) when is_atom(module) do
    if function_exported?(module, :hardware_config, 0) do
      {:ok, module.hardware_config()}
    else
      {:error, {:invalid_config_module, module}}
    end
  end

  defp get_config(%HardwareConfig{} = config), do: {:ok, config}

  defp get_config(other), do: {:error, {:invalid_config, other}}

  defp verify_hardware(master, %HardwareConfig{} = config) do
    with {:ok, slaves} <- Master.get_slaves(master) do
      # Get hardware info from each slave
      slave_infos = Enum.map(slaves, &get_slave_info/1)

      # Verify each configured slave matches hardware
      Enum.reduce_while(config.slaves, :ok, fn slave_config, :ok ->
        case find_matching_hardware(slave_config, slave_infos) do
          {:ok, _hw_info} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:verification_failed, slave_config, reason}}}
        end
      end)
    end
  end

  defp get_slave_info(slave_pid) do
    Slave.get_info(slave_pid)
  end

  defp find_matching_hardware(slave_config, slave_infos) do
    # Match by position and verify vendor/product if specified
    case Enum.find(slave_infos, fn info -> info.position == slave_config.position end) do
      nil ->
        {:error, :not_found}

      hw_info ->
        if slave_config.expected do
          cond do
            slave_config.expected.vendor && hw_info.vendor_id != slave_config.expected.vendor ->
              {:error,
               {:vendor_mismatch,
                expected: slave_config.expected.vendor, actual: hw_info.vendor_id}}

            slave_config.expected.product &&
                hw_info.product_code != slave_config.expected.product ->
              {:error,
               {:product_mismatch,
                expected: slave_config.expected.product, actual: hw_info.product_code}}

            true ->
              {:ok, hw_info}
          end
        else
          {:ok, hw_info}
        end
    end
  end
end
