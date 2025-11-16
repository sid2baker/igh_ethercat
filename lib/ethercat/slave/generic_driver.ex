defmodule EtherCAT.Slave.GenericDriver do
  @moduledoc """
  Generic EtherCAT slave driver with auto-discovery and optional callback module strategy.

  This is the default driver used when `driver: nil` in SlaveConfig.

  ## Features

  - Auto-discovers PDO mappings from slave EEPROM
  - Infers types from bit lengths (1=bool, 8=uint8, 16=uint16, etc.)
  - Provides type-based encoding/decoding
  - Handles read/write/subscribe operations
  - Supports callback module strategy for custom encoding

  ## Usage

  ### Default (Auto-discovery)

  Used automatically when no driver is specified:

      %SlaveConfig{
        position: 1,
        name: :my_device,
        driver: nil,  # GenericDriver used automatically
        expected: %{vendor: 0x00000002, product: 0x12345678}
      }

  ### With Custom Encoding (Strategy Pattern)

  Use GenericDriver with a callback module for simple encoding customization:

      defmodule MyTempEncoder do
        @behaviour EtherCAT.Slave.Driver

        def encode_pdo_value(:temp, :value, celsius, _state) do
          {:ok, <<round(celsius * 10)::little-signed-16>>}
        end

        def encode_pdo_value(pdo, entry, value, state) do
          EtherCAT.Slave.Driver.default_encode(pdo, entry, value, state)
        end

        def decode_pdo_value(:temp, :value, <<raw::little-signed-16>>, _state) do
          {:ok, raw / 10.0}
        end

        def decode_pdo_value(pdo, entry, binary, state) do
          EtherCAT.Slave.Driver.default_decode(pdo, entry, binary, state)
        end
      end

      # In SlaveConfig:
      %SlaveConfig{
        position: 1,
        driver: {EtherCAT.Slave.GenericDriver, callback_module: MyTempEncoder},
        ...
      }

  For complex drivers with custom state machines, see `EtherCAT.Slave.Driver` behaviour
  and implement a full GenServer yourself.
  """

  use GenServer
  @behaviour EtherCAT.Slave.Driver
  require Logger

  alias EtherCAT.Slave.Driver

  # Default state structure
  defstruct [
    :master,           # Master process PID (for callbacks)
    :position,         # Slave position on bus
    :name,             # Slave name (for unique PDO entry naming)
    :pdo_map,          # Auto-discovered PDO mappings
    :callback_module   # Optional callback module for strategy pattern
  ]

  # ========================================================================
  # Client API
  # ========================================================================

  @doc """
  Start the generic driver process.

  ## Options
  - Standard driver options (position, name, master, etc.)
  - `:callback_module` - Optional module implementing Driver behaviour for custom encoding
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Read a PDO entry value.
  """
  def read(pid, pdo_name, entry_name) when is_pid(pid) do
    GenServer.call(pid, {:read, pdo_name, entry_name})
  end

  @doc """
  Write a PDO entry value.
  """
  def write(pid, pdo_name, entry_name, value) when is_pid(pid) do
    GenServer.call(pid, {:write, pdo_name, entry_name, value})
  end

  @doc """
  Subscribe to value change notifications.
  """
  def subscribe(pid, pdo_name, entry_name, subscriber) when is_pid(pid) do
    GenServer.call(pid, {:subscribe, pdo_name, entry_name, subscriber})
  end

  @doc """
  Unsubscribe from value change notifications.
  """
  def unsubscribe(pid, pdo_name, entry_name, subscriber) when is_pid(pid) do
    GenServer.call(pid, {:unsubscribe, pdo_name, entry_name, subscriber})
  end

  @doc """
  Get SDO configuration list (default: empty).
  """
  def get_sdo_config(_pid), do: []

  @doc """
  Get PDO configuration (auto-discovered from EEPROM).
  """
  def get_pdo_config(pid) do
    GenServer.call(pid, :get_pdo_config)
  end

  # ========================================================================
  # GenServer Callbacks
  # ========================================================================

  @impl true
  def init(opts) do
    Driver.build_default_state(__MODULE__, opts)
  end

  @impl true
  def handle_call(:get_pdo_config, _from, state) do
    config = Driver.convert_pdo_config(state.pdo_map)
    {:reply, config, state}
  end

  def handle_call({:read, pdo_name, entry_name}, _from, state) do
    unique_name = "#{state.name}:#{pdo_name}:#{entry_name}"

    result =
      with {:ok, binary} <-
             EtherCAT.Master.read_pdo_entry(state.master, :default_domain, unique_name),
           {:ok, value} <- decode(pdo_name, entry_name, binary, state) do
        {:ok, value}
      end

    {:reply, result, state}
  end

  def handle_call({:write, pdo_name, entry_name, value}, _from, state) do
    unique_name = "#{state.name}:#{pdo_name}:#{entry_name}"

    result =
      with {:ok, binary} <- encode(pdo_name, entry_name, value, state),
           :ok <-
             EtherCAT.Master.write_pdo_entry(
               state.master,
               :default_domain,
               unique_name,
               binary
             ) do
        :ok
      end

    {:reply, result, state}
  end

  def handle_call({:subscribe, pdo_name, entry_name, subscriber}, _from, state) do
    unique_name = "#{state.name}:#{pdo_name}:#{entry_name}"

    result =
      EtherCAT.Master.subscribe(state.master, :default_domain, unique_name, subscriber)

    {:reply, result, state}
  end

  def handle_call({:unsubscribe, pdo_name, entry_name, subscriber}, _from, state) do
    unique_name = "#{state.name}:#{pdo_name}:#{entry_name}"

    result =
      EtherCAT.Master.unsubscribe(state.master, :default_domain, unique_name, subscriber)

    {:reply, result, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("GenericDriver terminating for slave #{state.position}: #{inspect(reason)}")
    :ok
  end

  # ========================================================================
  # Behaviour Implementation (Strategy Pattern)
  # ========================================================================

  @impl true
  def encode_pdo_value(pdo_name, entry_name, value, state) do
    encode(pdo_name, entry_name, value, state)
  end

  @impl true
  def decode_pdo_value(pdo_name, entry_name, binary, state) do
    decode(pdo_name, entry_name, binary, state)
  end

  # ========================================================================
  # Private Helpers (Strategy Pattern Dispatch)
  # ========================================================================

  # No callback module - use default encoding
  defp encode(pdo_name, entry_name, value, %{callback_module: nil} = state) do
    Driver.default_encode(pdo_name, entry_name, value, state)
  end

  # Callback module provided - delegate to it
  defp encode(pdo_name, entry_name, value, %{callback_module: module} = state) do
    module.encode_pdo_value(pdo_name, entry_name, value, state)
  end

  # No callback module - use default decoding
  defp decode(pdo_name, entry_name, binary, %{callback_module: nil} = state) do
    Driver.default_decode(pdo_name, entry_name, binary, state)
  end

  # Callback module provided - delegate to it
  defp decode(pdo_name, entry_name, binary, %{callback_module: module} = state) do
    module.decode_pdo_value(pdo_name, entry_name, binary, state)
  end
end
