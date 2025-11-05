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
          subscribers: %{offset() => {size(), [pid()]}}
        }

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
  Finalizes PDO entry registration by calling the NIF through Master.
  This must be called before activating the master.
  """
  def get_ready(domain) do
    GenServer.call(domain, :get_ready)
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
      |> IO.inspect(label: "PDO Entries")
      |> Map.new()

    {:reply, :ok, %{state | entries: result, pdo_entries_to_register: %{}}}
  end

  def handle_call({:subscribe, pid, name, offset, size}, _from, state) do
    subscribers =
      Map.update(state.subscribers, offset, {name, size, [pid]}, fn {name, size, pids} ->
        {name, size, [pid | pids]}
      end)

    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  # Receives cyclic data changes from the NIF and notifies subscribers
  def handle_info({:data_changed, data, offsets}, state) do
    IO.inspect(data, label: "Data Changed")
    IO.inspect(offsets, label: "Offsets")

    for offset <- offsets do
      with {name, size, pids} <- state.subscribers[offset] do
        # not working yet
        <<_offset::size(offset), changed_data::size(size), _rest::bitstring>> = data
        Enum.each(pids, fn pid -> send(pid, {:data_changed, name, changed_data}) end)
      end
    end

    {:noreply, state}
  end

  # Receives working counter changes from the NIF during cyclic operation
  def handle_info({:wc_changed, _wc}, state) do
    # Working counter changed - could be used for diagnostics
    {:noreply, state}
  end

  # Catch-all for unexpected messages
  def handle_info(msg, state) do
    require Logger
    Logger.debug("Domain received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end
end
