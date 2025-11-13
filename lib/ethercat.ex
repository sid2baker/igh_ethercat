defmodule EtherCAT do
  @moduledoc """
  Declarative EtherCAT industrial I/O interface for the IgH EtherCAT Master.

  ## Quick Start

  Define your hardware configuration using the Spark DSL:

      defmodule MyMachine do
        use EtherCAT.Config

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

  Then open and use the system:

      {:ok, system} = EtherCAT.open(MyMachine)
      {:ok, temp} = EtherCAT.read(system, :temp_sensor, :ch1, :value)
      :ok = EtherCAT.write(system, :output_slave, :ch1, :value, true)
      EtherCAT.close(system)

  ## Discovery Mode

  If you don't have a configuration yet, use discovery mode:

      {:ok, system} = EtherCAT.open()
      config = EtherCAT.generate_config(system)

      # Inspect the config to create your Spark module
      IO.inspect(config, pretty: true)

  ## Architecture

  - **Declarative**: Define hardware config once, reuse everywhere
  - **Type-safe**: Spark DSL validates at compile time
  - **Semantic names**: Use `:temp_sensor` instead of position 0
  - **Multi-domain**: Different update rates for critical vs diagnostic data
  """

  alias EtherCAT.{System, Master, Slave}
  alias EtherCAT.Config.HardwareConfig

  @doc """
  Opens an EtherCAT system with a hardware configuration.

  ## Parameters
  - `config_module` - Module using `EtherCAT.Config` DSL
  - `opts` - Options:
    - `:index` - EtherCAT master index (default: 0)
    - Other options passed to the NIF layer

  ## Returns
  - `{:ok, system}` - System handle for I/O operations
  - `{:error, reason}` - Configuration or hardware error

  ## Examples

      # Using a Spark DSL module
      {:ok, system} = EtherCAT.open(MyMachine)

      # Specifying master index
      {:ok, system} = EtherCAT.open(MyMachine, index: 1)
  """
  @spec open(module(), keyword()) :: {:ok, System.t()} | {:error, term()}
  def open(config_module, opts) when is_atom(config_module) and is_list(opts) do
    config = config_module.hardware_config()
    System.open(config, opts)
  end

  @doc """
  Opens an EtherCAT system in discovery mode (no configuration).

  Use this to discover connected hardware and generate a configuration.
  After discovery, call `generate_config/1` to create a config struct.

  ## Parameters
  - `opts` - Options:
    - `:index` - EtherCAT master index (default: 0)

  ## Returns
  - `{:ok, system}` - System handle with discovered slaves
  - `{:error, reason}` - Connection error

  ## Example

      {:ok, system} = EtherCAT.open()
      config = EtherCAT.generate_config(system)
      # Use config to create your Spark DSL module
  """
  @spec open(keyword()) :: {:ok, System.t()} | {:error, term()}
  def open(opts) when is_list(opts) do
    # Discovery mode - open with empty config
    config = %HardwareConfig{domains: [], slaves: []}
    System.open(config, opts)
  end

  def open(config_module) when is_atom(config_module) do
    open(config_module, [])
  end

  @doc """
  Closes the EtherCAT system and releases all resources.

  ## Parameters
  - `system` - System handle from `open/1` or `open/2`

  ## Example

      {:ok, system} = EtherCAT.open(MyMachine)
      # ... do work ...
      EtherCAT.close(system)
  """
  @spec close(System.t()) :: :ok
  def close(system), do: System.close(system)

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
    with {:ok, entry} <- System.find_entry(system, slave_name, pdo_name, entry_name) do
      Slave.read_entry(entry.slave_pid, entry.pdo_name, entry.entry_name)
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
    with {:ok, entry} <- System.find_entry(system, slave_name, pdo_name, entry_name) do
      Slave.write_entry(entry.slave_pid, entry.pdo_name, entry.entry_name, value)
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
          IO.puts("Temperature changed: \#{temp}")
      end
  """
  @spec watch(System.t(), atom(), atom(), atom()) :: :ok | {:error, term()}
  def watch(%System{} = system, slave_name, pdo_name, entry_name) do
    with {:ok, entry} <- System.find_entry(system, slave_name, pdo_name, entry_name) do
      Slave.watch_entry(entry.slave_pid, entry.pdo_name, entry.entry_name, self())
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
    with {:ok, entry} <- System.find_entry(system, slave_name, pdo_name, entry_name) do
      Slave.unwatch_entry(entry.slave_pid, entry.pdo_name, entry.entry_name, self())
    end
  end

  @doc """
  Generates a HardwareConfig from a running system.

  Use this after opening in discovery mode to create a configuration
  that can be saved and used to build a Spark DSL module.

  ## Parameters
  - `system` - System handle from discovery mode

  ## Returns
  - `HardwareConfig` struct representing the discovered hardware

  ## Example

      {:ok, system} = EtherCAT.open()
      config = EtherCAT.generate_config(system)

      IO.puts(\"\"\"
      defmodule MyMachine do
        use EtherCAT.Config

        # TODO: Add domains
        domain :default_domain, interval: 1

        # Discovered slaves:
        \"\"\")

      Enum.each(config.slaves, fn slave ->
        IO.puts("  slave position: \#{slave.position}, name: :\#{slave.name || "s\#{slave.position}"}")
      end)
  """
  @spec generate_config(System.t()) :: HardwareConfig.t()
  def generate_config(%System{master: master}) do
    # Get all slaves
    {:ok, slaves} = Master.get_slaves(master)

    slave_configs =
      Enum.map(slaves, fn slave_pid ->
        info = Slave.get_info(slave_pid)
        _pdos = Slave.list_pdos(slave_pid)

        # Generate basic slave config (user will need to add entries)
        %EtherCAT.Config.SlaveConfig{
          position: info.position,
          name: info.name,
          driver: nil,
          # TODO: Driver detection
          expected: %{
            vendor: info.vendor_id,
            product: info.product_code
          },
          config: %{},
          entries: []
          # User needs to fill this in
        }
      end)

    %HardwareConfig{
      domains: [
        # Default domain - user should customize
        %EtherCAT.Config.DomainConfig{name: :default_domain, interval: 1}
      ],
      slaves: slave_configs
    }
  end
end
