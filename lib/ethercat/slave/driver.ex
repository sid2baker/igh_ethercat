defmodule EtherCAT.Slave.Driver do
  @moduledoc """
  Smart EtherCAT slave driver with auto-discovery.

  By default, this driver:
  - Auto-discovers PDO mappings from slave EEPROM
  - Infers types from bit lengths (1=bool, 8=uint8, 16=uint16, etc.)
  - Provides type-based encoding/decoding
  - Handles read/write/subscribe operations

  ## Usage

  ### Simple driver (auto-discovery, no custom code):

      defmodule MyDevice do
        use EtherCAT.Slave.Driver
      end

  ### Custom encoding/decoding:

      defmodule MyTempSensor do
        use EtherCAT.Slave.Driver

        # Override for custom encoding
        def encode_pdo_value(:temp, :value, celsius, _state) do
          {:ok, <<round(celsius * 10)::little-signed-16>>}
        end

        # Fallback to default for other PDOs
        def encode_pdo_value(pdo, entry, value, state) do
          super(pdo, entry, value, state)
        end

        # Override for custom decoding
        def decode_pdo_value(:temp, :value, <<raw::little-signed-16>>, _state) do
          {:ok, raw / 10.0}
        end

        def decode_pdo_value(pdo, entry, binary, state) do
          super(pdo, entry, binary, state)
        end
      end

  ### Fixed PDO config (no auto-discovery):

      defmodule MyFixedDevice do
        use EtherCAT.Slave.Driver

        # Provide fixed PDO configuration
        def handle_call(:get_pdo_config, _from, state) do
          config = [
            %{
              name: :inputs,
              sync_manager: {3, :input, :default},
              pdo_index: 0x1A00,
              entries: %{value: {:int16, 0x6000, 0x01, 16}},
              domain: :default_domain
            }
          ]
          {:reply, config, state}
        end
      end

  ## Overridable Functions

  - `init/1` - Initialize driver state
  - `get_sdo_config/1` - Return SDO configuration list
  - `encode_pdo_value/4` - Custom encoding logic
  - `decode_pdo_value/4` - Custom decoding logic
  - `handle_call/3` - Full GenServer control
  """

  use GenServer
  require Logger

  # Default state structure for Driver when used directly
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

  @typedoc "PDO name (typically an atom like :ch1 or :inputs)"
  @type pdo_name :: atom() | String.t()

  @typedoc "Entry name within a PDO (typically an atom like :value or :error)"
  @type entry_name :: atom() | String.t()

  @doc """
  Encode a PDO value to binary.

  ## Parameters
  - `pdo_name` - PDO identifier (e.g., `:ch1`)
  - `entry_name` - Entry identifier (e.g., `:value`)
  - `value` - Value to encode
  - `state` - Driver state (for type lookup)

  ## Returns
  - `{:ok, binary}` on success
  - `{:error, reason}` on failure
  """
  @callback encode_pdo_value(pdo_name(), entry_name(), value :: term(), state :: term()) ::
              {:ok, binary()} | {:error, term()}

  @doc """
  Decode a PDO value from binary.

  ## Parameters
  - `pdo_name` - PDO identifier (e.g., `:ch1`)
  - `entry_name` - Entry identifier (e.g., `:value`)
  - `binary` - Raw binary data from hardware
  - `state` - Driver state (for type lookup)

  ## Returns
  - `{:ok, value}` on success
  - `{:error, reason}` on failure
  """
  @callback decode_pdo_value(pdo_name(), entry_name(), binary(), state :: term()) ::
              {:ok, term()} | {:error, term()}

  # ========================================================================
  # GenServer Implementation - Driver module can be used directly
  # ========================================================================

  @doc """
  Start the driver process.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Get SDO configuration list (default: empty).
  """
  def get_sdo_config(_pid), do: []

  @doc """
  Get PDO configuration (auto-discovered from EEPROM by default).
  """
  def get_pdo_config(pid) do
    GenServer.call(pid, :get_pdo_config)
  end

  @impl true
  def init(opts) do
    position = Keyword.fetch!(opts, :position)
    name = Keyword.fetch!(opts, :name)
    eeprom_data = Keyword.fetch!(opts, :eeprom_data)

    # Auto-discover PDO mappings from EEPROM
    pdo_map = process_eeprom_data(eeprom_data, position)

    state = %__MODULE__{
      master: Keyword.fetch!(opts, :master),
      position: position,
      name: name,
      slave_config: Keyword.fetch!(opts, :slave_config),
      vendor_id: Keyword.fetch!(opts, :vendor_id),
      product_code: Keyword.fetch!(opts, :product_code),
      revision: Keyword.fetch!(opts, :revision),
      serial: Keyword.fetch!(opts, :serial),
      sync_count: Keyword.fetch!(opts, :sync_count),
      config: Keyword.get(opts, :config, %{}),
      pdo_map: pdo_map
    }

    Logger.info(
      "Driver started for slave #{state.position} " <>
        "(vendor: 0x#{Integer.to_string(state.vendor_id, 16)}, " <>
        "product: 0x#{Integer.to_string(state.product_code, 16)}) " <>
        "with #{map_size(pdo_map)} PDOs"
    )

    {:ok, state}
  end

  @impl true
  def handle_call(:get_pdo_config, _from, state) do
    config = convert_pdo_config(state.pdo_map)
    {:reply, config, state}
  end

  def handle_call({:read, pdo_name, entry_name}, _from, state) do
    unique_name = "#{state.name}:#{pdo_name}:#{entry_name}"

    result =
      with {:ok, binary} <-
             EtherCAT.Master.read_pdo_entry(state.master, :default_domain, unique_name),
           {:ok, value} <- driver_decode(pdo_name, entry_name, binary, state) do
        {:ok, value}
      end

    {:reply, result, state}
  end

  def handle_call({:write, pdo_name, entry_name, value}, _from, state) do
    unique_name = "#{state.name}:#{pdo_name}:#{entry_name}"

    result =
      with {:ok, binary} <- driver_encode(pdo_name, entry_name, value, state),
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
    Logger.info("Driver terminating for slave #{state.position}: #{inspect(reason)}")
    :ok
  end

  # Type-based encoding/decoding for direct Driver use
  defp driver_encode(pdo_name, entry_name, value, state) do
    type = get_entry_type(state.pdo_map, pdo_name, entry_name)
    encode_by_type(type, value)
  end

  defp driver_decode(pdo_name, entry_name, binary, state) do
    type = get_entry_type(state.pdo_map, pdo_name, entry_name)
    decode_by_type(type, binary)
  end

  # ========================================================================
  # __using__ macro - Complete driver implementation
  # ========================================================================

  @doc false
  defmacro __using__(_opts) do
    quote do
      use GenServer
      @behaviour EtherCAT.Slave.Driver
      require Logger

      # Default state structure (can be extended by drivers)
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

      # ======================================================================
      # Client API - Provided to all drivers
      # ======================================================================

      @doc """
      Start the driver process.
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
      Get PDO configuration (auto-discovered from EEPROM by default).
      """
      def get_pdo_config(pid) do
        GenServer.call(pid, :get_pdo_config)
      end

      # ======================================================================
      # GenServer Callbacks - Default implementation
      # ======================================================================

      @impl true
      def init(opts) do
        position = Keyword.fetch!(opts, :position)
        name = Keyword.fetch!(opts, :name)
        eeprom_data = Keyword.fetch!(opts, :eeprom_data)

        # Auto-discover PDO mappings from EEPROM
        pdo_map = EtherCAT.Slave.Driver.process_eeprom_data(eeprom_data, position)

        state = %__MODULE__{
          master: Keyword.fetch!(opts, :master),
          position: position,
          name: name,
          slave_config: Keyword.fetch!(opts, :slave_config),
          vendor_id: Keyword.fetch!(opts, :vendor_id),
          product_code: Keyword.fetch!(opts, :product_code),
          revision: Keyword.fetch!(opts, :revision),
          serial: Keyword.fetch!(opts, :serial),
          sync_count: Keyword.fetch!(opts, :sync_count),
          config: Keyword.get(opts, :config, %{}),
          pdo_map: pdo_map
        }

        Logger.info(
          "Driver started for slave #{state.position} " <>
            "(vendor: 0x#{Integer.to_string(state.vendor_id, 16)}, " <>
            "product: 0x#{Integer.to_string(state.product_code, 16)}) " <>
            "with #{map_size(pdo_map)} PDOs"
        )

        {:ok, state}
      end

      @impl true
      def handle_call(:get_pdo_config, _from, state) do
        config = EtherCAT.Slave.Driver.convert_pdo_config(state.pdo_map)
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
        Logger.info("Driver terminating for slave #{state.position}: #{inspect(reason)}")
        :ok
      end

      # ======================================================================
      # Type-Based Encoding/Decoding (Default Implementation)
      # ======================================================================

      @doc """
      Default encode implementation with type lookup from pdo_map.
      """
      def encode_pdo_value(pdo_name, entry_name, value, state) do
        type = EtherCAT.Slave.Driver.get_entry_type(state.pdo_map, pdo_name, entry_name)
        EtherCAT.Slave.Driver.encode_by_type(type, value)
      end

      @doc """
      Default decode implementation with type lookup from pdo_map.
      """
      def decode_pdo_value(pdo_name, entry_name, binary, state) do
        type = EtherCAT.Slave.Driver.get_entry_type(state.pdo_map, pdo_name, entry_name)
        EtherCAT.Slave.Driver.decode_by_type(type, binary)
      end

      # Make functions overridable for custom drivers
      defoverridable init: 1,
                     get_sdo_config: 1,
                     get_pdo_config: 1,
                     encode_pdo_value: 4,
                     decode_pdo_value: 4,
                     handle_call: 3,
                     terminate: 2
    end
  end

  # ========================================================================
  # Public Helper Functions (called from injected code)
  # ========================================================================

  @doc false
  def process_eeprom_data(eeprom_data, position) do
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

  @doc false
  def convert_pdo_config(pdo_map) do
    Enum.map(pdo_map, fn {pdo_name, pdo_info} ->
      %{
        name: safe_to_atom(pdo_name),
        sync_manager: pdo_info.sync_manager,
        pdo_index: pdo_info.pdo_index,
        entries:
          Map.new(pdo_info.entries, fn {entry_name, {index, subindex, bit_length}} ->
            type = infer_type_from_bit_length(bit_length)
            {safe_to_atom(entry_name), {type, index, subindex, bit_length}}
          end),
        domain: :default_domain,
        # Fixed EEPROM PDO mappings - do not allow dynamic reconfiguration
        supports_pdo_config?: false
      }
    end)
  end

  @doc false
  def get_entry_type(pdo_map, pdo_name, entry_name) do
    pdo_name_str = to_string(pdo_name)
    entry_name_str = to_string(entry_name)

    with {:ok, pdo_info} <- Map.fetch(pdo_map, pdo_name_str),
         {:ok, {_index, _subindex, bit_length}} <- Map.fetch(pdo_info.entries, entry_name_str) do
      infer_type_from_bit_length(bit_length)
    else
      _ -> :uint16
    end
  end

  @doc """
  Infer type from bit length for entries without explicit type annotation.
  """
  def infer_type_from_bit_length(1), do: :bool
  def infer_type_from_bit_length(size) when size >= 2 and size < 8, do: :uint8
  def infer_type_from_bit_length(8), do: :uint8
  def infer_type_from_bit_length(16), do: :uint16
  def infer_type_from_bit_length(32), do: :uint32
  def infer_type_from_bit_length(64), do: :uint64
  def infer_type_from_bit_length(_), do: :uint16

  # ========================================================================
  # Type-Based Encoding/Decoding
  # ========================================================================

  @doc false
  def encode_by_type(:bool, value) when is_boolean(value) do
    {:ok, <<if(value, do: 1, else: 0)>>}
  end

  def encode_by_type(:uint8, value) when is_integer(value) and value >= 0 and value <= 255 do
    {:ok, <<value::little-unsigned-8>>}
  end

  def encode_by_type(:int8, value) when is_integer(value) and value >= -128 and value <= 127 do
    {:ok, <<value::little-signed-8>>}
  end

  def encode_by_type(:uint16, value) when is_integer(value) and value >= 0 and value <= 65535 do
    {:ok, <<value::little-unsigned-16>>}
  end

  def encode_by_type(:int16, value)
      when is_integer(value) and value >= -32768 and value <= 32767 do
    {:ok, <<value::little-signed-16>>}
  end

  def encode_by_type(:uint32, value) when is_integer(value) and value >= 0 do
    {:ok, <<value::little-unsigned-32>>}
  end

  def encode_by_type(:int32, value) when is_integer(value) do
    {:ok, <<value::little-signed-32>>}
  end

  def encode_by_type(:uint64, value) when is_integer(value) and value >= 0 do
    {:ok, <<value::little-unsigned-64>>}
  end

  def encode_by_type(:int64, value) when is_integer(value) do
    {:ok, <<value::little-signed-64>>}
  end

  def encode_by_type(type, value) do
    {:error, {:invalid_value_for_type, value, type}}
  end

  @doc false
  def decode_by_type(:bool, <<value>>) do
    {:ok, value != 0}
  end

  def decode_by_type(:uint8, <<value::little-unsigned-8>>) do
    {:ok, value}
  end

  def decode_by_type(:int8, <<value::little-signed-8>>) do
    {:ok, value}
  end

  def decode_by_type(:uint16, <<value::little-unsigned-16>>) do
    {:ok, value}
  end

  def decode_by_type(:int16, <<value::little-signed-16>>) do
    {:ok, value}
  end

  def decode_by_type(:uint32, <<value::little-unsigned-32>>) do
    {:ok, value}
  end

  def decode_by_type(:int32, <<value::little-signed-32>>) do
    {:ok, value}
  end

  def decode_by_type(:uint64, <<value::little-unsigned-64>>) do
    {:ok, value}
  end

  def decode_by_type(:int64, <<value::little-signed-64>>) do
    {:ok, value}
  end

  def decode_by_type(type, data) do
    {:error, {:invalid_data_for_type, byte_size(data), type}}
  end

  # ========================================================================
  # Private Helpers
  # ========================================================================

  # SECURITY: Safely convert string to atom, only if it already exists
  defp safe_to_atom(string) when is_binary(string) do
    try do
      String.to_existing_atom(string)
    rescue
      ArgumentError ->
        # Atom doesn't exist - use string instead to prevent atom creation
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
end
