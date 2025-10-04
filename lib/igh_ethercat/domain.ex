defmodule IghEthercat.Domain do
  use GenServer

  defstruct [:resource, :interval, :subscribers]

  @type t :: %__MODULE__{
          resource: String.t(),
          interval: integer(),
          subscribers: %{offset() => {size(), [pid()]}}
        }

  # in bits
  @type offset :: non_neg_integer()
  # in bits
  @type size :: non_neg_integer()

  def start_link(name, resource, interval) do
    GenServer.start_link(__MODULE__, {resource, interval}, name: name)
  end

  def get_ref(domain) do
    GenServer.call(domain, :get_ref)
  end

  def get_interval(domain) do
    GenServer.call(domain, :get_interval)
  end

  def subscribe(domain, pid, name, offset, size) do
    GenServer.call(domain, {:subscribe, pid, name, offset, size})
  end

  def init({resource, interval}) do
    {:ok, %__MODULE__{resource: resource, interval: interval, subscribers: %{}}}
  end

  def handle_call(:get_ref, _from, state) do
    {:reply, state.resource, state}
  end

  def handle_call(:get_interval, _from, state) do
    {:reply, state.interval, state}
  end

  def handle_call({:subscribe, pid, name, offset, size}, _from, state) do
    subscribers =
      Map.update(state.subscribers, offset, {name, size, [pid]}, &{name, size, [pid | &1]})

    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  def handle_info({:data_changed, data, offsets}, state) do
    for offset <- offsets do
      with {name, size, pids} <- state.subscribers[offset] do
        # not working yet
        <<_offset::size(offset), changed_data::size(size), _rest::bitstring>> = data
        Enum.each(pids, fn pid -> send(pid, {:data_changed, name, changed_data}) end)
      end
    end

    {:noreply, state}
  end

  def handle_info(msg, state) do
    IO.inspect(msg, label: "Unhandled Message")
    {:noreply, state}
  end
end
