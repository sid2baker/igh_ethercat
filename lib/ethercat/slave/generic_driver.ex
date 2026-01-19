defmodule EtherCAT.Slave.GenericDriver do
  use GenServer
  use EtherCAT.Slave.Driver
  require Logger

  @impl EtherCAT.Slave.Driver
  def start_driver(name, config) do
    config = Map.put(config, :name, name)
    GenServer.start_link(__MODULE__, config, name: name)
  end

  @impl EtherCAT.Slave.Driver
  def configure(driver_pid) do
    GenServer.cast(driver_pid, :configure)
  end

  @impl GenServer
  def init(config) do
    {:ok,
     %{
       name: config[:name],
       sdo_config: config[:sdos],
       pdo_config: config[:sync_managers],
       configured_pdos: %{},
       subscribers: %{}
     }}
  end

  @impl GenServer
  def handle_call(:get_pdos, _from, state) do
    {:reply, state.configured_pdos, state}
  end

  @impl GenServer
  def handle_call({:read_pdo_entry, pdo_name, entry_name}, _from, state) do
    case state.configured_pdos[{pdo_name, entry_name}] do
      {:output, {_entry}} ->
        {:reply, {:error, :is_output}, state}

      {:input, {_index, _subindex, bit_length}} ->
        bytes = div(bit_length + 7, 8)

        {:ok, <<result::size(bytes * 8)>>} =
          EtherCAT.Master.read_pdo_entry({state.name, pdo_name, entry_name})

        {:reply, result, state}
    end
  end

  @impl GenServer
  def handle_call({:write_pdo_entry, pdo_name, entry_name, value}, _from, state) do
    case state.configured_pdos[{pdo_name, entry_name}] do
      {:input, {_entry}} ->
        {:reply, {:error, :is_input}, state}

      {:output, {_index, _subindex, bit_length}} ->
        bytes = div(bit_length + 7, 8)

        result =
          EtherCAT.Master.write_pdo_entry(
            {state.name, pdo_name, entry_name},
            <<value::size(bytes * 8)>>
          )

        {:reply, result, state}
    end
  end

  def handle_call({:subscribe, pdo_name, entry_name}, {pid, _tag}, state) do
    key = {pdo_name, entry_name}
    ref = Process.monitor(pid)
    current = Map.get(state.subscribers, key, [])
    new_subscribers = Map.put(state.subscribers, key, [{pid, ref} | current])
    {:reply, :ok, %{state | subscribers: new_subscribers}}
  end

  def handle_call({:unsubscribe, pdo_name, entry_name}, {pid, _tag}, state) do
    key = {pdo_name, entry_name}
    current = Map.get(state.subscribers, key, [])

    case List.keyfind(current, pid, 0) do
      {^pid, ref} ->
        Process.demonitor(ref, [:flush])
        new_list = List.keydelete(current, pid, 0)
        new_subscribers = Map.put(state.subscribers, key, new_list)
        {:reply, :ok, %{state | subscribers: new_subscribers}}

      nil ->
        {:reply, {:error, :not_subscribed}, state}
    end
  end

  @impl GenServer
  def handle_cast(:configure, state) do
    # configure sdos
    configure_sdos(state.sdo_config)

    # configure pdos
    configured_pdos = configure_pdos(state.pdo_config)

    :ok = slave_configured(configured_pdos)

    {:noreply, %{state | configured_pdos: configured_pdos}}
  end

  defp configure_sdos(nil), do: :ok

  defp configure_sdos(sdos) do
    for {index, subindex, data} <- sdos do
      :ok = sdo_config(index, subindex, data)
    end

    :ok
  end

  defp configure_pdos(nil), do: %{}

  defp configure_pdos(pdos) do
    Enum.flat_map(pdos, fn sm ->
      :ok = sync_manager(sm.index, sm.direction, sm.watchdog)
      :ok = pdo_assign_clear(sm.index)

      Enum.flat_map(sm.pdos, fn {pdo_name, pdo} ->
        :ok = pdo_assign_add(sm.index, pdo.index)
        :ok = pdo_mapping_clear(pdo.index)

        Enum.map(pdo.entries, fn {entry_name, entry_tuple} ->
          {entry_index, entry_subindex, bit_length} = entry_tuple

          :ok =
            pdo_mapping_add(
              pdo.index,
              entry_index,
              entry_subindex,
              bit_length
            )

          {{pdo_name, entry_name}, {sm.direction, entry_tuple}}
        end)
      end)
    end)
    |> Map.new()
  end

  @impl GenServer
  def handle_info({:ec_update, {slave, pdo, entry}, value} = msg, state) do
    subscribers = Map.get(state.subscribers, {pdo, entry}, [])
    {:input, {_index, _subindex, bit_length}} = state.configured_pdos[{pdo, entry}]
    bytes = div(bit_length + 7, 8)
    <<result::size(bytes * 8)>> = value

    for {pid, _ref} <- subscribers do
      send(pid, {:ec_update, {slave, pdo, entry}, result})
    end

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    new_subscribers =
      state.subscribers
      |> Enum.map(fn {key, subs} ->
        {key, List.keydelete(subs, pid, 0)}
      end)
      |> Enum.reject(fn {_key, subs} -> subs == [] end)
      |> Map.new()

    {:noreply, %{state | subscribers: new_subscribers}}
  end

  def handle_info(msg, state) do
    Logger.info(inspect(msg))
    {:noreply, state}
  end
end
