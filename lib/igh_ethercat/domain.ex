defmodule IghEthercat.Domain do
  use GenServer

  defstruct [:resource, :interval, :pdo_entries_to_register, :entries, :subscribers]

  alias IghEthercat.Nif

  @type t :: %__MODULE__{
          resource: String.t(),
          interval: integer(),
          pdo_entries_to_register: map(),
          entries: map(),
          subscribers: %{offset() => {size(), [pid()]}}
        }

  # in bits
  @type offset :: non_neg_integer()
  # in bits
  @type size :: non_neg_integer()

  def start_link(name, resource, interval) do
    GenServer.start_link(__MODULE__, {resource, interval}, name: name)
  end

  def get_ready(domain) do
    GenServer.call(domain, :get_ready)
  end

  def get_ref(domain) do
    GenServer.call(domain, :get_ref)
  end

  def get_interval(domain) do
    GenServer.call(domain, :get_interval)
  end

  def register_pdo_entry(domain, slave_config, name, entry) do
    GenServer.call(domain, {:register_pdo_entry, slave_config, name, entry})
  end

  def subscribe(domain, pid, name, offset, size) do
    GenServer.call(domain, {:subscribe, pid, name, offset, size})
  end

  def init({resource, interval}) do
    {:ok,
     %__MODULE__{
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

  def handle_call(:get_ready, _from, state) do
    result =
      for {slave_config, entries} <- state.pdo_entries_to_register do
        for {name, {entry_index, entry_subindex, entry_size}} <- entries do
          offset =
            Nif.slave_config_reg_pdo_entry(
              slave_config,
              entry_index,
              entry_subindex,
              state.resource
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
      Map.update(state.subscribers, offset, {name, size, [pid]}, &{name, size, [pid | &1]})

    {:reply, :ok, %{state | subscribers: subscribers}}
  end

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

  def handle_call(msg, _from, state) do
    IO.inspect(msg, label: "Unhandled Message")
    {:reply, :ok, state}
  end

  def handle_info(msg, state) do
    IO.inspect(msg, label: "Unhandled Message")
    {:noreply, state}
  end
end
