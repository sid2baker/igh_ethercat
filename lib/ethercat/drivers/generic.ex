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
  use EtherCAT.Slave.Driver
  require Logger

  alias EtherCAT.{Master, Slave.Driver}

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
    name = Keyword.fetch!(opts, :name)
    slave_config = Keyword.fetch!(opts, :slave_config)
    eeprom_data = Keyword.fetch!(opts, :eeprom_data)

    # Register in Registry for discovery (include slave_config for Master lookup)
    Registry.register(EtherCAT.Registry, {:slave, self()}, %{
      driver: __MODULE__,
      position: position,
      slave_config: slave_config
    })

    # Process EEPROM data synchronously (no Master calls needed)
    pdo_map = process_eeprom_data(eeprom_data, position)

    state = %__MODULE__{
      master: Keyword.fetch!(opts, :master),
      position: position,
      name: name,
      slave_config: slave_config,
      vendor_id: Keyword.fetch!(opts, :vendor_id),
      product_code: Keyword.fetch!(opts, :product_code),
      revision: Keyword.fetch!(opts, :revision),
      serial: Keyword.fetch!(opts, :serial),
      sync_count: Keyword.fetch!(opts, :sync_count),
      config: Keyword.get(opts, :config, %{}),
      pdo_map: pdo_map,
      entry_map: %{}
    }

    Logger.info(
      "Generic driver started for slave #{state.position} " <>
        "(vendor: 0x#{Integer.to_string(state.vendor_id, 16)}, " <>
        "product: 0x#{Integer.to_string(state.product_code, 16)}) " <>
        "with #{map_size(pdo_map)} PDOs"
    )

    {:ok, state}
  end

  @impl true
  def handle_call(:get_pdo_config, _from, state) do
    {:reply, convert_pdo_config(state), state}
  end

  def handle_call({:read, pdo_name, entry_name}, _from, state) do
    unique_name = "#{state.name}:#{pdo_name}:#{entry_name}"
    type = get_entry_type(state, pdo_name, entry_name)

    # Use injected helper function
    result = read_from_master(state.master, :default_domain, unique_name, type)
    {:reply, result, state}
  end

  def handle_call({:write, pdo_name, entry_name, value}, _from, state) do
    unique_name = "#{state.name}:#{pdo_name}:#{entry_name}"
    type = get_entry_type(state, pdo_name, entry_name)

    # Use injected helper function
    result = write_to_master(state.master, :default_domain, unique_name, type, value)
    {:reply, result, state}
  end

  def handle_call({:subscribe, pdo_name, entry_name, subscriber}, _from, state) do
    unique_name = "#{state.name}:#{pdo_name}:#{entry_name}"

    # Use injected helper function
    result = subscribe_to_master(state.master, :default_domain, unique_name, subscriber)
    {:reply, result, state}
  end

  def handle_call({:unsubscribe, pdo_name, entry_name, subscriber}, _from, state) do
    unique_name = "#{state.name}:#{pdo_name}:#{entry_name}"

    # Use injected helper function
    result = unsubscribe_from_master(state.master, :default_domain, unique_name, subscriber)
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

  # Process EEPROM data provided by Master into pdo_map format
  defp process_eeprom_data(eeprom_data, position) do
    try do
      eeprom_data
      |> Enum.flat_map(fn {_sync_index, sync_data} ->
        sync_manager = sync_data.sync_manager
        pdos = sync_data.pdos || %{}

        Enum.map(pdos, fn {_pdo_pos, pdo_data} ->
          pdo = pdo_data.pdo
          entries = pdo_data.entries || %{}

          pdo_name = "0x#{Integer.to_string(pdo.index, 16) |> String.downcase()}"
          direction = normalize_direction(sync_manager.dir)
          watchdog_mode = normalize_watchdog_mode(sync_manager.watchdog_mode)

          entry_map =
            Enum.map(entries, fn {_entry_pos, entry} ->
              index_hex = Integer.to_string(entry.index, 16) |> String.downcase()
              entry_name = "0x#{index_hex}:#{entry.subindex}"
              {entry_name, {entry.index, entry.subindex, entry.bit_length}}
            end)
            |> Map.new()

          {pdo_name,
           %{
             sync_manager: {sync_manager.index, direction, watchdog_mode},
             pdo_index: pdo.index,
             entries: entry_map
           }}
        end)
      end)
      |> Map.new()
    rescue
      error ->
        Logger.error("Failed to process EEPROM data for slave #{position}: #{inspect(error)}")
        %{}
    end
  end

  # Convert internal pdo_map to Driver.pdo_config format
  defp convert_pdo_config(state) do
    # SECURITY: Use existing_atom to prevent atom exhaustion from untrusted EEPROM data
    Enum.map(state.pdo_map, fn {pdo_name, pdo_info} ->
      %{
        name: safe_to_atom(pdo_name),
        sync_manager: pdo_info.sync_manager,
        pdo_index: pdo_info.pdo_index,
        entries:
          Map.new(pdo_info.entries, fn {entry_name, {index, subindex, bit_length}} ->
            type = Driver.infer_type_from_bit_length(bit_length)
            {safe_to_atom(entry_name), {type, index, subindex, bit_length}}
          end),
        domain: :default_domain,
        # Generic driver uses fixed EEPROM PDO mappings - do not allow dynamic reconfiguration
        # This prevents Master from calling slave_config_pdo_mapping_clear/add which would
        # corrupt the fixed mappings of Beckhoff terminals (EL1809, EL2809, etc.)
        supports_pdo_config?: false
      }
    end)
  end

  # SECURITY: Safely convert string to atom, only if it already exists
  # This prevents atom exhaustion from untrusted EEPROM data
  defp safe_to_atom(string) when is_binary(string) do
    try do
      String.to_existing_atom(string)
    rescue
      ArgumentError ->
        # Atom doesn't exist - use string instead to prevent atom creation
        # This is safe because the driver can work with string keys
        string
    end
  end

  defp safe_to_atom(value), do: value

  defp normalize_direction(0), do: :invalid
  defp normalize_direction(1), do: :output
  defp normalize_direction(2), do: :input
  defp normalize_direction(3), do: :count

  defp normalize_watchdog_mode(0), do: :default
  defp normalize_watchdog_mode(1), do: :enabled
  defp normalize_watchdog_mode(2), do: :disabled

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
