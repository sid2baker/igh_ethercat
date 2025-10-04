defmodule IghEthercat.Domain do
  use GenServer

  defstruct [:resource, :interval, :subscribers]

  @type t :: %__MODULE__{
    resource: String.t(),
    interval: integer(),
    subscribers: %{offset() => {size(), [pid()]}}
  }

  @type offset :: non_neg_integer() # in bits
  @type size :: non_neg_integer() # in bits

  def start_link(name, resource, interval) do
    GenServer.start_link(__MODULE__, {resource, interval}, name: name)
  end

  def get_ref(domain) do
    GenServer.call(domain, :get_ref)
  end

  def get_interval(domain) do
    GenServer.call(domain, :get_interval)
  end

  def subscribe(domain, pid, offset, size) do
    GenServer.call(domain, {:subscribe, pid, offset, size})
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

  def handle_call({:subscribe, pid, offset, size}, _from, state) do
    subscribers = Map.update(state.subscribers, offset, {size, [pid]}, &{size, [pid | &1]})
    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  def handle_info({:data_changed, data, offsets}, state)  do
    IO.inspect(data, label: "Data Changed")
    IO.inspect(offsets, label: "Offsets")
    for offset <- offsets do
      with {size, pids} <- state.subscribers[offset] do
        # not working yet
        # <<_offset::size(offset), changed_data::size(size), _rest>> = data
        Enum.each(pids, fn pid -> send(pid, {:data_changed, data}) end)
      end
    end
    {:noreply, state}
  end

  def handle_info(msg, state) do
    IO.inspect(msg, label: "Unhandled Message")
    {:noreply, state}
  end
end
