defmodule EtherCAT do
  @moduledoc """
  Real-time EtherCAT master for industrial automation.

  ## Overview

  This library provides a two-phase system for real-time I/O control:

  1. **Configuration Phase**: Define hardware once, apply atomically
  2. **Operation Phase**: Real-time cyclic I/O in separate thread at fixed intervals

  The Master is a 4-state FSM that transitions from disconnected → stable topology →
  configured → operational. Once operational, a cyclic task reads sensor inputs, detects
  changes, writes output values, and notifies subscribers asynchronously.

  ## Installation

  Add to your supervision tree:

      children = [
        {EtherCAT, master_index: 0}  # Starts EtherCAT.Master process
      ]

       Supervisor.start_link(children, strategy: :one_for_one)

  ## Basic Usage

  Define your hardware configuration:

      defmodule MyMachine do
        alias EtherCAT.Config

        def hardware_config do
          %Config.HardwareConfig{
            master: %Config.MasterConfig{
              index: 0,
              cycle_interval: 10_000,      # 10ms cycle
              nif_yield_interval: 100_000   # Yield to BEAM every 100ms
            },
            domains: [
              %Config.DomainConfig{name: :fast_loop, cycle_multiplier: 1}
            ],
            slaves: [
              %Config.SlaveConfig{
                position: 0,
                name: :temp_sensor,
                device_identity: %{
                  vendor_id: 0x00000002,
                  product_code: 0x0C5A3052
                },
                driver: nil,  # Auto-discovery
                config: %{},
                registered_entries: %{
                  fast_loop: [{:ch1, :value}, {:ch1, :error}]
                }
              }
            ]
          }
        end
      end

  Then configure and use:

      master = Process.whereis(EtherCAT.Master)
      {:ok, slaves} = EtherCAT.configure_hardware(master, MyMachine)
      {:ok, temp} = EtherCAT.read(slaves.temp_sensor, :ch1, :value)
      :ok = EtherCAT.write(slaves.temp_sensor, :ch1, :value, 25.0)

  Subscribe to changes:

      :ok = EtherCAT.watch(slaves.temp_sensor, :ch1, :value)
      receive do
        {:pdo_value_changed, _name, new_temp} ->
          IO.puts("Temperature: \#{new_temp}°C")
      end

  ## How It Works

  ### Configuration Phase

  When you call `configure_hardware/2`:

  1. Wait for EtherCAT link (if not present)
  2. Detect slaves (poll until topology stable, ~1 second)
  3. Stop any existing configuration
  4. For each slave:
     - Apply SDO configuration (device parameters)
     - Configure sync managers and PDO mappings
     - Start driver process
  5. Create domains (FMMU memory mapping)
  6. Start cyclic task (separate OS thread)
  7. Wait for all slaves to reach operational state
  8. Return map of slave names → PIDs

  The entire config is atomic: either all slaves configured, or all rolled back.

  ### Operation Phase

  The cyclic task runs in a separate thread, every cycle_interval (e.g., 10ms):

  1. Sync clock with EtherCAT master
  2. Receive network frames (slave responses)
  3. For each domain:
     - Process domain (update buffer from frame)
     - Detect changes: compare buffer with cached values
     - Send notifications for changed inputs
     - Write outputs to buffer (source of truth)
     - Queue domain for transmission
  4. Check master state
  5. Send frames to network
  6. Sleep to maintain exact cycle rate
  7. Periodically yield to BEAM scheduler

  ### Direct Slave PID Access

  Instead of looking up slaves by name each time, you get PIDs from `configure_hardware/2`:

      {:ok, slaves} = EtherCAT.configure_hardware(master, MyMachine)
      # slaves = %{
      #   temp_sensor: #PID<0.123.0>,
      #   valve1: #PID<0.124.0>
      # }

  Use these PIDs directly for all I/O (no indirection, no hidden state).

  ### Multi-Domain Support

  Domains allow different update rates:

      domains: [
        %DomainConfig{name: :critical, cycle_multiplier: 1},    # Every cycle (10ms)
        %DomainConfig{name: :normal, cycle_multiplier: 5},      # Every 5 cycles (50ms)
        %DomainConfig{name: :monitoring, cycle_multiplier: 100} # Every 100 cycles (1s)
      ]

  Each domain has its own FMMU mapping, enabling:
  - Servo control at 1ms
  - I/O at 10ms
  - Diagnostics at 100ms
  - All with single cycle_interval

  ### Error Recovery

  If a slave crashes, the Master:
  - Stops cyclic task
  - Stops all slaves
  - Transitions back to :stale
  - Clears all subscribers

  Configuration can be reapplied to recover.

  ## Architecture

  ```
  Supervision Tree
  └─ EtherCAT.Master (gen_statem)
     ├─ Slave Drivers (GenServer pool)
     └─ Cyclic Task (Zig NIF, separate thread)
        └─ IgH EtherCAT Library (C + Linux kernel)
  ```

  ## Key Concepts

  - **Declarative**: Define hardware config struct, Master applies atomically
  - **Direct access**: Use slave PIDs directly, not names or indices
  - **Type-safe**: Drivers encode/decode values, config validated upfront
  - **Real-time**: Cyclic task at µs precision in separate thread
  - **Semantic naming**: Refer to `slaves.temp_sensor` not position 0
  - **Fail-safe**: All-or-nothing configuration, supervisor restarts on crash
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
