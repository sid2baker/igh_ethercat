defmodule IghEthercat.Master do
  @behaviour :gen_statem
  require Logger

  alias IghEthercat.{Nif, Slave, Domain}

  defstruct [:master_ref, :slaves, :domains, :update_interval]

  @type t :: %__MODULE__{
          master_ref: reference(),
          slaves: [Slave.t()],
          domains: [Domain.t()],
          update_interval: integer()
        }

  # Client API
  def start_link(opts \\ []) do
    master_index = Keyword.get(opts, :master_index, 0)
    update_interval = Keyword.get(opts, :update_interval, 1_000)
    :gen_statem.start_link(__MODULE__, {master_index, update_interval}, name: __MODULE__)
  end

  def request_nif(master, {request_fn, request_args}) do
    :gen_statem.call(master, {:request_nif, request_fn, request_args})
  end

  def sync_slaves(master) do
    :gen_statem.call(master, :sync_slaves)
  end

  def lock_hardware(master) do
    :gen_statem.call(master, :lock_hardware)
  end

  def create_domain(master, name) do
    :gen_statem.call(master, {:create_domain, name})
  end

  def get_ref(master) do
    :gen_statem.call(master, :get_ref)
  end

  # Callbacks
  @impl true
  def callback_mode(), do: [:state_functions, :state_enter]

  @impl true
  def init({master_index, update_interval}) do
    data = %__MODULE__{
      master_ref: nil,
      domains: [],
      slaves: [],
      update_interval: update_interval
    }

    actions = [{:next_event, :internal, {:connect, master_index}}]
    {:ok, :disconnected, data, actions}
  end

  # State: disconnected
  def disconnected(:enter, _old_state, data) do
    {:next_state, :disconnected, data}
  end

  def disconnected(:internal, {:connect, master_index}, data) do
    case Nif.request_master(master_index) do
      {:ok, ref} ->
        {:next_state, :stale, %{data | master_ref: ref}}

      :error ->
        {:keep_state_and_data, []}
    end
  end

  def disconnected({:call, from}, _event_content, data) do
    actions = [{:reply, from, {:error, :disconnected}}]
    {:keep_state_and_data, actions}
  end

  def disconnected(event_type, event_content, data) do
    handle_unexpected(event_type, event_content, :disconnected, data)
  end

  # State: stale
  def stale(:enter, _old_state, data) do
    actions = [{:state_timeout, data.update_interval, :update_master_state}]
    {:next_state, :stale, data, actions}
  end

  def stale({:call, from}, :get_slaves, data) do
    master_state = Nif.get_master_state(data.master_ref)

    slaves =
      for slave_position <- create_range(master_state.slaves_responding) do
        {:ok, slave} = Nif.master_get_slave(data.master_ref, slave_position)

        for sync_index <- create_range(slave.sync_count) do
          sync_manager = Nif.master_get_sync_manager(data.master_ref, slave_position, sync_index)

          for pos <- create_range(sync_manager.n_pdos) do
            pdo = Nif.master_get_pdo(data.master_ref, slave_position, sync_index, pos)

            for entry_pos <- create_range(pdo.n_entries) do
              Nif.master_get_pdo_entry(
                data.master_ref,
                slave_position,
                sync_index,
                pos,
                entry_pos
              )
            end
          end
        end
      end

    actions = [{:reply, from, slaves}]
    {:next_state, :ready, %{data | slaves: slaves}, actions}
  end

  def stale({:call, from}, :sync_slaves, data) do
    master_state = Nif.get_master_state(data.master_ref)

    slaves =
      Enum.map(create_range(master_state.slaves_responding), fn slave_position ->
        {:ok, slave} = Slave.create(self(), slave_position)
        slave
      end)

    actions = [{:reply, from, {:ok, slaves}}]
    {:next_state, :ready, %{data | slaves: slaves}, actions}
  end

  def stale(:state_timeout, :update_master_state, data) do
    master_state =
      Nif.get_master_state(data.master_ref)
      |> IO.inspect(label: "Stale")

    if master_state.slaves_responding == length(data.slaves) and
         master_state.slaves_responding > 0 do
      {:next_state, :ready, data}
    else
      actions = [{:state_timeout, data.update_interval, :update_master_state}]
      {:keep_state_and_data, actions}
    end
  end

  def stale(event_type, event_content, data) do
    handle_unexpected(event_type, event_content, :stale, data)
  end

  # State: ready
  def ready(:enter, _old_state, data) do
    actions = [{:state_timeout, data.update_interval, :update_master_state}]
    {:next_state, :ready, data, actions}
  end

  def ready({:call, from}, {:request_nif, request_fn, request_args}, data) do
    result = apply(Nif, request_fn, [data.master_ref | request_args])
    actions = [{:reply, from, result}]
    {:keep_state_and_data, actions}
  end

  def ready({:call, from}, :lock_hardware, _data) do
    actions = [{:reply, from, :already_locked}]
    {:keep_state_and_data, actions}
  end

  def ready({:call, from}, {:create_domain, name}, data) do
    domain_ref = Nif.master_create_domain(data.master_ref)
    Domain.start_link(domain_ref, name)
    # Note: Consider adding {:reply, from, domain_ref}
    {:keep_state_and_data, []}
  end

  def ready({:call, from}, :get_ref, data) do
    actions = [{:reply, from, data.master_ref}]
    {:keep_state_and_data, actions}
  end

  def ready(:state_timeout, :update_master_state, data) do
    master_state =
      Nif.get_master_state(data.master_ref)
      |> IO.inspect(label: "Ready")

    if master_state.slaves_responding == length(data.slaves) do
      actions = [{:state_timeout, data.update_interval, :update_master_state}]
      {:keep_state_and_data, actions}
    else
      # TODO kill current slaves
      {:next_state, :stale, %{data | slaves: []}}
    end
  end

  def ready(event_type, event_content, data) do
    handle_unexpected(event_type, event_content, :ready, data)
  end

  # State: operational
  def operational(:enter, _old_state, data) do
    {:next_state, :operational, data}
  end

  def operational(:state_timeout, :update_master_state, data) do
    master_state = Nif.get_master_state(data.master_ref)

    if master_state.slaves_responding == length(data.slaves) do
      actions = [{:state_timeout, data.update_interval, :update_master_state}]
      {:keep_state_and_data, actions}
    else
      # TODO kill current slaves
      # TODO deactivate master
      actions = [{:state_timeout, data.update_interval, :update_master_state}]
      {:next_state, :stale, %{data | slaves: []}, actions}
    end
  end

  def operational(:info, {:master_state_changed, master_state}, data) do
    IO.inspect(master_state, label: "Master State Changed")
    {:keep_state_and_data, []}
  end

  def operational({:call, from}, :get_ref, data) do
    actions = [{:reply, from, data.master_ref}]
    {:keep_state_and_data, actions}
  end

  def operational(event_type, event_content, data) do
    handle_unexpected(event_type, event_content, :operational, data)
  end

  # Common catch-all handler
  defp handle_unexpected(event_type, event_content, state, data) do
    Logger.warning("Unexpected event in state #{state}: #{inspect({event_type, event_content})}")
    {:keep_state_and_data, []}
  end

  defp create_range(0), do: []
  defp create_range(n), do: 0..(n - 1)
end
