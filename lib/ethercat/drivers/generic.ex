defmodule EtherCAT.Drivers.Generic do
  @moduledoc """
  Generic EtherCAT slave driver.

  This driver auto-discovers PDO configuration from the slave's EEPROM
  and provides basic read/write functionality without device-specific logic.

  ## Architecture

  1. Driver is a GenServer process (not a module)
  2. Master starts driver via start_link/1
  3. Driver provides SDO/PDO config via callbacks
  4. Driver handles read/write/subscribe by calling Master functions
  5. Driver manages its own state
  """

  use GenServer
  require Logger

  alias EtherCAT.{Master, Nif, Slave.Driver}

  defstruct [
    :master,
    :position,
    :slave_config,
    :vendor_id,
    :product_code,
    :revision,
    :serial,
    :sync_count,
    :config,
    :pdo_map,
    :entry_map
  ]

  # ============================================================================
  # Client API (Driver Behaviour)
  # ============================================================================

  @doc """
  Start the Generic driver process.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Get SDO configuration list.

  Generic driver doesn't write any SDOs by default.
  """
  def get_sdo_config(_pid) do
    []
  end

  @doc """
  Get PDO configuration by auto-discovering from EEPROM.
  """
  def get_pdo_config(pid) do
    GenServer.call(pid, :get_pdo_config)
  end

  @doc """
  Read a PDO entry value.
  """
  def read(pid, pdo_name, entry_name) do
    GenServer.call(pid, {:read, pdo_name, entry_name})
  end

  @doc """
  Write a PDO entry value.
  """
  def write(pid, pdo_name, entry_name, value) do
    GenServer.call(pid, {:write, pdo_name, entry_name, value})
  end

  @doc """
  Subscribe to value changes.
  """
  def subscribe(pid, pdo_name, entry_name, subscriber) do
    GenServer.call(pid, {:subscribe, pdo_name, entry_name, subscriber})
  end

  @doc """
  Unsubscribe from value changes.
  """
  def unsubscribe(pid, pdo_name, entry_name, subscriber) do
    GenServer.call(pid, {:unsubscribe, pdo_name, entry_name, subscriber})
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    position = Keyword.fetch!(opts, :position)
    slave_config = Keyword.fetch!(opts, :slave_config)

    # Register in Registry for discovery (include slave_config for Master lookup)
    Registry.register(EtherCAT.Registry, {:slave, self()}, %{
      driver: __MODULE__,
      position: position,
      slave_config: slave_config
    })

    state = %__MODULE__{
      master: Keyword.fetch!(opts, :master),
      position: position,
      slave_config: slave_config,
      vendor_id: Keyword.fetch!(opts, :vendor_id),
      product_code: Keyword.fetch!(opts, :product_code),
      revision: Keyword.fetch!(opts, :revision),
      serial: Keyword.fetch!(opts, :serial),
      sync_count: Keyword.fetch!(opts, :sync_count),
      config: Keyword.get(opts, :config, %{}),
      pdo_map: %{},
      entry_map: %{}
    }

    Logger.info(
      "Generic driver started for slave #{state.position} " <>
        "(vendor: 0x#{Integer.to_string(state.vendor_id, 16)}, " <>
        "product: 0x#{Integer.to_string(state.product_code, 16)})"
    )

    # Auto-discover PDO configuration
    {:ok, state, {:continue, :discover_pdos}}
  end

  @impl true
  def handle_continue(:discover_pdos, state) do
    pdo_map = discover_pdos_from_eeprom(state)

    Logger.debug(
      "Slave #{state.position}: Discovered #{map_size(pdo_map)} PDOs"
    )

    {:noreply, %{state | pdo_map: pdo_map}}
  end

  @impl true
  def handle_call(:get_pdo_config, _from, state) do
    # Convert internal pdo_map to Driver.pdo_config format
    pdo_configs =
      Enum.map(state.pdo_map, fn {pdo_name, pdo_info} ->
        %{
          name: String.to_atom(pdo_name),
          sync_manager: pdo_info.sync_manager,
          pdo_index: pdo_info.pdo_index,
          entries:
            Map.new(pdo_info.entries, fn {entry_name, {index, subindex, bit_length}} ->
              type = Driver.infer_type_from_bit_length(bit_length)
              {String.to_atom(entry_name), {type, index, subindex, bit_length}}
            end),
          domain: :default_domain,
          supports_pdo_config?: true
        }
      end)

    {:reply, pdo_configs, state}
  end

  def handle_call({:read, pdo_name, entry_name}, _from, state) do
    unique_name = build_unique_name(state.position, pdo_name, entry_name)
    domain = :default_domain

    case Master.read_pdo_entry(state.master, domain, unique_name) do
      {:ok, binary} ->
        # Decode using default logic
        type = get_entry_type(state, pdo_name, entry_name)

        case Driver.decode_pdo_value(type, binary) do
          {:ok, value} -> {:reply, {:ok, value}, state}
          {:error, _} = error -> {:reply, error, state}
        end

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:write, pdo_name, entry_name, value}, _from, state) do
    unique_name = build_unique_name(state.position, pdo_name, entry_name)
    domain = :default_domain
    type = get_entry_type(state, pdo_name, entry_name)

    case Driver.encode_pdo_value(type, value) do
      {:ok, binary} ->
        result = Master.write_pdo_entry(state.master, domain, unique_name, binary)
        {:reply, result, state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:subscribe, pdo_name, entry_name, subscriber}, _from, state) do
    # Use the new Master subscribe API with slave_name, pdo_name, entry_name
    slave_name = :"slave_#{state.position}"

    result = Master.subscribe(state.master, slave_name, pdo_name, entry_name, subscriber)
    {:reply, result, state}
  end

  def handle_call({:unsubscribe, pdo_name, entry_name, subscriber}, _from, state) do
    # Use the new Master unsubscribe API with slave_name, pdo_name, entry_name
    slave_name = :"slave_#{state.position}"

    result = Master.unsubscribe(state.master, slave_name, pdo_name, entry_name, subscriber)
    {:reply, result, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Generic driver terminating for slave #{state.position}: #{inspect(reason)}")
    :ok
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Discover all PDOs from slave's EEPROM
  defp discover_pdos_from_eeprom(state) do
    for sync_index <- 0..(state.sync_count - 1) do
      sync_manager = get_sync_manager(state, sync_index)

      for pdo_pos <- 0..(sync_manager.n_pdos - 1) do
        pdo = get_pdo(state, sync_index, pdo_pos)

        entries =
          for entry_pos <- 0..(pdo.n_entries - 1) do
            entry = get_pdo_entry(state, sync_index, pdo_pos, entry_pos)

            entry_name =
              "0x#{Integer.to_string(entry.index, 16)}:#{Integer.to_string(entry.subindex, 16)}"

            {entry_name, {entry.index, entry.subindex, entry.bit_length}}
          end
          |> Map.new()

        pdo_name = "0x#{Integer.to_string(pdo.index, 16)}"

        direction = normalize_direction(sync_manager.dir)
        watchdog_mode = normalize_watchdog_mode(sync_manager.watchdog_mode)

        {pdo_name,
         %{
           sync_manager: {sync_manager.index, direction, watchdog_mode},
           pdo_index: pdo.index,
           entries: entries
         }}
      end
    end
    |> List.flatten()
    |> Map.new()
  end

  defp normalize_direction(0), do: :invalid
  defp normalize_direction(1), do: :output
  defp normalize_direction(2), do: :input
  defp normalize_direction(3), do: :count

  defp normalize_watchdog_mode(0), do: :default
  defp normalize_watchdog_mode(1), do: :enabled
  defp normalize_watchdog_mode(2), do: :disabled

  defp get_sync_manager(state, sync_index) do
    Master.get_sync_manager(state.master, state.position, sync_index)
  end

  defp get_pdo(state, sync_index, pdo_pos) do
    Master.get_pdo(state.master, state.position, sync_index, pdo_pos)
  end

  defp get_pdo_entry(state, sync_index, pdo_pos, entry_pos) do
    Master.get_pdo_entry(state.master, state.position, sync_index, pdo_pos, entry_pos)
  end

  defp build_unique_name(position, pdo_name, entry_name) do
    "slave_#{position}:#{pdo_name}:#{entry_name}"
  end

  defp get_entry_type(state, pdo_name, entry_name) do
    pdo_name_str = to_string(pdo_name)
    entry_name_str = to_string(entry_name)

    with {:ok, pdo_info} <- Map.fetch(state.pdo_map, pdo_name_str),
         {:ok, {_index, _subindex, bit_length}} <- Map.fetch(pdo_info.entries, entry_name_str) do
      Driver.infer_type_from_bit_length(bit_length)
    else
      _ -> :uint16
    end
  end
end
