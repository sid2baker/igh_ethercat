defmodule EtherCAT.Domain do
  @moduledoc """
  Manages EtherCAT process data domains.

  Domains allow grouping of process data transfers with different update periods.
  They handle PDO entry registration and cyclic data exchange between the master
  and slaves.

  All NIF communication is routed through the Master process to prevent race conditions.
  """
  use GenServer

  defstruct [:master, :resource, :interval, :pdo_entries_to_register, :entries, :subscribers]

  alias EtherCAT.Master

  @type t :: %__MODULE__{
          master: pid(),
          resource: reference(),
          interval: integer(),
          pdo_entries_to_register: map(),
          entries: map(),
          subscribers: %{offset() => {name(), size(), MapSet.t(pid())}}
        }

  @type name :: String.t()
  @type offset :: non_neg_integer()
  @type size :: non_neg_integer()

  # Client API

  @doc """
  Starts a domain process.

  ## Parameters
  - `name` - Registered name for the domain
  - `master` - Master process PID
  - `resource` - Domain reference from the NIF
  - `interval` - Update interval in microseconds
  """
  def start_link(name, master, resource, interval) do
    GenServer.start_link(__MODULE__, {master, resource, interval}, name: name)
  end

  @doc false
  def get_ready(domain) do
    GenServer.call(domain, :get_ready)
  end

  @doc false
  def get_pending_registrations(domain) do
    GenServer.call(domain, :get_pending_registrations)
  end

  @doc false
  def store_entries(domain, entries) do
    GenServer.call(domain, {:store_entries, entries})
  end

  @doc """
  Returns the domain's NIF reference.
  """
  def get_ref(domain) do
    GenServer.call(domain, :get_ref)
  end

  @doc """
  Returns the domain's update interval.
  """
  def get_interval(domain) do
    GenServer.call(domain, :get_interval)
  end

  @doc """
  Registers a PDO entry to this domain.
  Entries are queued and registered when get_ready/1 is called.
  """
  def register_pdo_entry(domain, slave_config, name, entry) do
    GenServer.call(domain, {:register_pdo_entry, slave_config, name, entry})
  end

  @doc """
  Subscribes a process to receive data change notifications for a PDO entry.
  """
  def subscribe(domain, pid, name, offset, size) do
    GenServer.call(domain, {:subscribe, pid, name, offset, size})
  end

  @doc """
  Gets the registered entry information (offset and size) for a PDO by name.
  Returns `{:ok, {offset, size}}` or `{:error, :not_found}`.
  Must be called after `get_ready/1`.
  """
  def get_entry(domain, name) do
    GenServer.call(domain, {:get_entry, name})
  end

  @doc """
  Sets a boolean value in the domain at the specified offset.
  All NIF communication is routed through Master.
  """
  def set_value_bool(domain, offset, value) do
    GenServer.call(domain, {:set_value_bool, offset, value})
  end

  @doc """
  Gets a boolean value from the domain at the specified offset.
  All NIF communication is routed through Master.
  """
  def get_value_bool(domain, offset) do
    GenServer.call(domain, {:get_value_bool, offset})
  end

  # GenServer callbacks

  def init({master, resource, interval}) do
    {:ok,
     %__MODULE__{
       master: master,
       resource: resource,
       interval: interval,
       pdo_entries_to_register: %{},
       entries: %{},
       subscribers: %{}
     }}
  end

  def handle_call(:get_ref, _from, state) do
    {:reply, state.resource, state}
  end

  def handle_call(:get_interval, _from, state) do
    {:reply, state.interval, state}
  end

  def handle_call({:register_pdo_entry, slave_config, name, entry}, _from, state) do
    result =
      Map.update(
        state.pdo_entries_to_register,
        slave_config,
        [{name, entry}],
        &[{name, entry} | &1]
      )

    {:reply, :ok, %{state | pdo_entries_to_register: result}}
  end

  # Registers all queued PDO entries with the master via domain_operation
  # This routes the NIF call through Master to prevent race conditions
  def handle_call(:get_ready, _from, state) do
    result =
      for {slave_config, entries} <- state.pdo_entries_to_register do
        for {name, {entry_index, entry_subindex, entry_size}} <- entries do
          # Call Master.domain_operation which will invoke the NIF
          offset =
            Master.domain_operation(
              state.master,
              :register_pdo_entry,
              [slave_config, entry_index, entry_subindex, state.resource]
            )

          {name, {offset, entry_size}}
        end
      end
      |> List.flatten()

    result_map = Map.new(result)
    require Logger
    Logger.debug("PDO Entries registered: #{inspect(result_map)}")

    {:reply, :ok, %{state | entries: result_map, pdo_entries_to_register: %{}}}
  end

  def handle_call({:subscribe, pid, name, offset, size}, _from, state) do
    # Monitor the subscribing process so we clean up when it dies
    Process.monitor(pid)

    # Add to subscribers using MapSet
    subscribers =
      Map.update(
        state.subscribers,
        offset,
        {name, size, MapSet.new([pid])},
        fn {name, size, pids} ->
          {name, size, MapSet.put(pids, pid)}
        end
      )

    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  def handle_call({:get_entry, name}, _from, state) do
    case state.entries[name] do
      {offset, size} -> {:reply, {:ok, {offset, size}}, state}
      nil -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:set_value_bool, offset, value}, _from, state) do
    result = Master.domain_operation(state.master, :set_value_bool, [state.resource, offset, value])
    {:reply, result, state}
  end

  def handle_call({:get_value_bool, offset}, _from, state) do
    result = Master.domain_operation(state.master, :get_value_bool, [state.resource, offset])
    {:reply, result, state}
  end

  def handle_call(:get_pending_registrations, _from, state) do
    {:reply, state.pdo_entries_to_register, state}
  end

  def handle_call({:store_entries, entries}, _from, state) do
    {:reply, :ok, %{state | entries: entries, pdo_entries_to_register: %{}}}
  end

  # Receives cyclic data changes from the NIF and notifies subscribers
  def handle_info({:data_changed, data, offsets}, state) do
    for offset <- offsets do
      case state.subscribers[offset] do
        {name, size, pids} ->
          # Extract the value at the bit offset
          value = extract_bits(data, offset, size)
          Enum.each(pids, fn pid -> send(pid, {:data_changed, name, value}) end)

        nil ->
          # No subscribers for this offset
          :ok
      end
    end

    {:noreply, state}
  end

  # Handles subscriber process termination - remove from all subscriptions
  def handle_info({:DOWN, _monitor_ref, :process, pid, _reason}, state) do
    subscribers =
      state.subscribers
      |> Enum.map(fn {offset, {name, size, pids}} ->
        updated_pids = MapSet.delete(pids, pid)

        # Keep entry only if there are still subscribers
        if MapSet.size(updated_pids) > 0 do
          {offset, {name, size, updated_pids}}
        else
          nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Map.new()

    {:noreply, %{state | subscribers: subscribers}}
  end

  # Receives working counter changes from the NIF during cyclic operation
  def handle_info({:wc_changed, _wc}, state) do
    # Working counter changed - could be used for diagnostics
    {:noreply, state}
  end

  # Receives working counter state changes from the NIF
  # wc_state values: 0 = EC_WC_ZERO, 1 = EC_WC_INCOMPLETE, 2 = EC_WC_COMPLETE
  def handle_info({:state_changed, _wc_state}, state) do
    # State changed - could be used for diagnostics or error detection
    {:noreply, state}
  end

  # Catch-all for unexpected messages
  def handle_info(msg, state) do
    require Logger
    Logger.debug("Domain received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private helpers

  # Extracts bits from binary data at a specific bit offset using bit operations
  #
  # EtherCAT uses LSB-first bit numbering where bit 0 is the least significant bit.
  # For example, with data <<2, 0>>:
  # - Byte 0: 0b00000010 (decimal 2) - bit 1 is set
  # - Byte 1: 0b00000000 (decimal 0)
  #
  # Bit layout (shown LSB to MSB, left to right):
  #   Bit offset:  0  1  2  3  4  5  6  7 | 8  9 10 11 12 13 14 15
  #   Value:       0  1  0  0  0  0  0  0 | 0  0  0  0  0  0  0  0
  #
  # To extract bit N, we:
  # 1. Find the byte: byte_index = N / 8
  # 2. Find the bit within that byte: bit_index = N % 8
  # 3. Extract using bit shift: (byte >> bit_index) & 1
  defp extract_bits(data, offset, size) when is_binary(data) do
    use Bitwise

    byte_index = div(offset, 8)
    bit_index = rem(offset, 8)

    # Check if we have enough data
    if byte_index >= byte_size(data) do
      0
    else
      byte = :binary.at(data, byte_index)

      # For single bit (boolean values)
      if size == 1 do
        (byte >>> bit_index) &&& 1
      else
        # For multi-bit values spanning multiple bytes
        # Extract bits using LSB-first ordering
        extract_multibyte_value(data, byte_index, bit_index, size)
      end
    end
  end

  # Extracts a multi-bit value that may span multiple bytes
  defp extract_multibyte_value(data, byte_index, bit_index, size) do
    use Bitwise

    bits_remaining = size
    current_byte = byte_index
    current_bit = bit_index
    result = 0
    shift = 0

    extract_multibyte_loop(data, current_byte, current_bit, bits_remaining, result, shift)
  end

  defp extract_multibyte_loop(_data, _byte_index, _bit_index, 0, result, _shift) do
    result
  end

  defp extract_multibyte_loop(data, byte_index, bit_index, bits_remaining, result, shift) do
    use Bitwise

    if byte_index >= byte_size(data) do
      result
    else
      byte = :binary.at(data, byte_index)
      bits_in_this_byte = min(8 - bit_index, bits_remaining)
      mask = (1 <<< bits_in_this_byte) - 1
      value = (byte >>> bit_index) &&& mask

      new_result = result ||| (value <<< shift)
      new_shift = shift + bits_in_this_byte
      new_bits_remaining = bits_remaining - bits_in_this_byte

      extract_multibyte_loop(data, byte_index + 1, 0, new_bits_remaining, new_result, new_shift)
    end
  end
end
