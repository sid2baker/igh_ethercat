defmodule EtherCAT.Slave.GenericDriver do
  @moduledoc """
  Default EtherCAT slave driver with auto-discovery.

  This is the concrete implementation used when `driver: nil` in SlaveConfig.

  Features:
  - Auto-discovers PDO mappings from slave EEPROM
  - Infers types from bit lengths (1=bool, 8=uint8, 16=uint16, etc.)
  - Provides type-based encoding/decoding
  - Handles read/write/subscribe operations

  ## Usage

  This driver is used automatically when no driver is specified:

      %SlaveConfig{
        position: 1,
        name: :my_device,
        driver: nil,  # GenericDriver used automatically
        expected: %{vendor: 0x00000002, product: 0x12345678}
      }

  For custom drivers, see `EtherCAT.Slave.Driver` behaviour.
  """

  use GenServer
  @behaviour EtherCAT.Slave.Driver
  require Logger

  alias EtherCAT.Slave.Driver

  # Default state structure
  defstruct [
    :master,
    :position,
    :name,
    :slave_config,
    :vendor_id,
    :product_code,
    :revision,
    :serial,
    :sync_count,
    :config,
    :pdo_map
  ]

  # ========================================================================
  # Client API
  # ========================================================================

  @doc """
  Start the generic driver process.
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
           {:ok, value} <- decode_pdo_value(pdo_name, entry_name, binary, state) do
        {:ok, value}
      end

    {:reply, result, state}
  end

  def handle_call({:write, pdo_name, entry_name, value}, _from, state) do
    unique_name = "#{state.name}:#{pdo_name}:#{entry_name}"

    result =
      with {:ok, binary} <- encode_pdo_value(pdo_name, entry_name, value, state),
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
  # Behaviour Implementation
  # ========================================================================

  @impl true
  def encode_pdo_value(pdo_name, entry_name, value, state) do
    Driver.default_encode(pdo_name, entry_name, value, state)
  end

  @impl true
  def decode_pdo_value(pdo_name, entry_name, binary, state) do
    Driver.default_decode(pdo_name, entry_name, binary, state)
  end
end
