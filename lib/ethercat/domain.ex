defmodule EtherCAT.Domain do
  @moduledoc """
  Manages EtherCAT process data domains.

  Domains allow grouping of process data transfers with different update periods.
  They handle PDO entry registration and cyclic data exchange between the master
  and slaves.

  All NIF communication is routed through the Master process to prevent race conditions.
  """
  use GenServer
  require Logger
  alias EtherCAT.Nif

  defstruct [:master, :resource, :interval, :entries, :subscribers, locked?: false]

  @type t :: %__MODULE__{
          master: pid(),
          resource: reference(),
          interval: integer(),
          entries: map(),
          subscribers: %{name() => MapSet.t(pid())},
          locked?: boolean()
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

  @doc """
  Returns the pending PDO entries from the domain.
  """
  def get_pdo_entries(domain) do
    GenServer.call(domain, :get_pdo_entries)
  end

  @doc false
  def store_and_lock_entries(domain, entries) do
    GenServer.call(domain, {:store_and_lock_entries, entries})
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
  Entries are queued and registered.
  Entry should be {entry_type, entry_index, entry_subindex, entry_size} or
  {entry_index, entry_subindex, entry_size} (type will be inferred from size).
  """
  def register_pdo_entry(domain, slave_config, name, entry) do
    GenServer.call(domain, {:register_pdo_entry, slave_config, name, entry})
  end

  # Infer PDO entry type from bit size
  defp infer_entry_type(1), do: :bool
  defp infer_entry_type(8), do: :uint8
  defp infer_entry_type(16), do: :uint16
  defp infer_entry_type(32), do: :uint32
  defp infer_entry_type(64), do: :uint64
  defp infer_entry_type(size), do: {:unknown, size}

  @doc """
  Subscribes a process to receive data change notifications for a PDO entry.
  """
  def subscribe(domain, pid, name) do
    GenServer.call(domain, {:subscribe, pid, name})
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
       entries: %{},
       subscribers: %{},
       locked?: false
     }}
  end

  def handle_call(:get_ref, _from, state) do
    {:reply, state.resource, state}
  end

  def handle_call(:get_interval, _from, state) do
    {:reply, state.interval, state}
  end

  def handle_call({:register_pdo_entry, slave_config, name, entry}, _from, state) do
    if state.locked? do
      {:reply, {:error, :domain_locked}, state}
    else
      # Normalize entry to include type
      normalized_entry =
        case entry do
          {entry_type, entry_index, entry_subindex, entry_size} when is_atom(entry_type) ->
            # Already has explicit type
            {entry_type, entry_index, entry_subindex, entry_size}

          {entry_index, entry_subindex, entry_size} ->
            # Infer type from size
            entry_type = infer_entry_type(entry_size)
            {entry_type, entry_index, entry_subindex, entry_size}
        end

      result =
        Map.update(
          state.entries,
          slave_config,
          [{name, normalized_entry}],
          &[{name, normalized_entry} | &1]
        )

      {:reply, :ok, %{state | entries: result}}
    end
  end

  def handle_call({:subscribe, pid, name}, _from, state) do
    # Monitor the subscribing process so we clean up when it dies
    Process.monitor(pid)

    # Add to subscribers using MapSet
    subscribers =
      Map.update(
        state.subscribers,
        name,
        MapSet.new([pid]),
        &MapSet.put(&1, pid)
      )

    Logger.debug("Subscribed #{inspect(pid)} to #{name}")
    Logger.debug("Total subscribers: #{map_size(subscribers)}")

    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  def handle_call({:get_entry, name}, _from, state) do
    case state.entries[name] do
      {offset, size} -> {:reply, {:ok, {offset, size}}, state}
      nil -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:set_value_bool, offset, value}, _from, state) do
    result = Nif.set_domain_value_bool(state.resource, offset, value)
    {:reply, result, state}
  end

  def handle_call({:get_value_bool, offset}, _from, state) do
    result = Nif.get_domain_value_bool(state.resource, offset)
    {:reply, result, state}
  end

  def handle_call(:get_pdo_entries, _from, state) do
    {:reply, state.entries, state}
  end

  def handle_call({:store_and_lock_entries, entries}, _from, state) do
    {:reply, :ok, %{state | entries: entries, locked?: true}}
  end

  # Receives cyclic data changes from the NIF with entry names and values
  def handle_info({:data_changed, changes}, state) do
    Logger.debug("Domain received data_changed with #{length(changes)} changed entries")

    for {name, value} <- changes do
      Logger.debug("  Entry changed: #{name} = #{inspect(value)}")

      # Find subscribers by entry name
      case state.subscribers[name] do
        pids when is_struct(pids, MapSet) ->
          Logger.debug("  Notifying #{MapSet.size(pids)} subscribers for #{name}")
          Enum.each(pids, fn pid -> send(pid, {:data_changed, name, value}) end)

        nil ->
          # No subscribers for this entry
          :ok
      end
    end

    {:noreply, state}
  end

  # Handles subscriber process termination - remove from all subscriptions
  def handle_info({:DOWN, _monitor_ref, :process, pid, _reason}, state) do
    subscribers =
      state.subscribers
      |> Enum.map(fn {name, pids} ->
        updated_pids = MapSet.delete(pids, pid)

        # Keep entry only if there are still subscribers
        if MapSet.size(updated_pids) > 0 do
          {name, updated_pids}
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
    Logger.debug("Domain received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end
end
