defmodule IghEthercat.Master do
  @behaviour :gen_statem
  require Logger

  alias IghEthercat.{Nif, Slave, Domain}

  defstruct [:master_ref, :slaves, :domains, :task_pid, :update_interval]

  @type t :: %__MODULE__{
          master_ref: reference(),
          slaves: [Slave.t()],
          domains: [Domain.t()],
          task_pid: pid(),
          # in us
          update_interval: integer()
        }

  # Client API
  def start_link(opts \\ []) do
    master_index = Keyword.get(opts, :master_index, 0)
    update_interval = Keyword.get(opts, :update_interval, 100_000)
    :gen_statem.start_link(__MODULE__, {master_index, update_interval}, name: __MODULE__)
  end

  def connect(master) do
    :gen_statem.call(master, :connect)
  end

  def request_nif(master, {request_fn, request_args}) do
    :gen_statem.call(master, {:request_nif, request_fn, request_args})
  end

  def sync_slaves(master) do
    :gen_statem.call(master, :sync_slaves)
  end

  def create_domain(master, name, interval) do
    :gen_statem.call(master, {:create_domain, name, interval})
  end

  def activate(master) do
    :gen_statem.cast(master, :activate)
  end

  def get_ref(master) do
    :gen_statem.call(master, :get_ref)
  end

  # Callbacks
  @impl true
  def callback_mode(), do: [:state_functions, :state_enter]

  @impl true
  def init({master_index, update_interval}) do
    case Nif.request_master(master_index) do
      {:ok, ref} ->
        domain_ref = Nif.master_create_domain(ref)
        {:ok, domain} = Domain.start_link(:default_domain, domain_ref, 1)

        data = %__MODULE__{
          master_ref: ref,
          domains: [domain],
          slaves: [],
          task_pid: nil,
          update_interval: update_interval
        }

        {:ok, :offline, data}

      :error ->
        {:error, :failed_to_create_master}
    end
  end

  # State: offline
  def offline(:enter, _old_state, data) do
    :keep_state_and_data
  end

  def offline({:call, from}, :connect, data) do
    master_state = Nif.get_master_state(data.master_ref)

    if master_state.link_up == 1 do
      {:next_state, :stale, data, [{:reply, from, :ok}]}
    else
      {:keep_state_and_data, [{:reply, from, {:error, :link_down}}]}
    end
  end

  def offline({:call, from}, _event_content, data) do
    actions = [{:reply, from, {:error, :offline}}]
    {:keep_state_and_data, actions}
  end

  def offline(event_type, event_content, data) do
    handle_unexpected(event_type, event_content, :offline, data)
  end

  # State: stale
  def stale(:enter, _old_state, data) do
    actions = [{:state_timeout, data.update_interval, :update_master_state}]
    {:keep_state_and_data, actions}
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
    {:next_state, :synced, %{data | slaves: slaves}, actions}
  end

  def stale({:call, from}, :sync_slaves, data) do
    master_state = Nif.get_master_state(data.master_ref)

    slaves =
      Enum.map(create_range(master_state.slaves_responding), fn slave_position ->
        {:ok, slave_info} = Nif.master_get_slave(data.master_ref, slave_position)

        {:ok, slave} =
          Slave.create(self(), slave_position, slave_info.vendor_id, slave_info.product_code)

        slave
      end)

    actions = [{:reply, from, {:ok, slaves}}]
    {:next_state, :synced, %{data | slaves: slaves}, actions}
  end

  def stale(:state_timeout, :update_master_state, data) do
    master_state =
      Nif.get_master_state(data.master_ref)
      |> IO.inspect(label: "Stale")

    if master_state.slaves_responding == length(data.slaves) and
         master_state.slaves_responding > 0 do
      {:next_state, :synced, data}
    else
      actions = [{:state_timeout, data.update_interval, :update_master_state}]
      {:keep_state_and_data, actions}
    end
  end

  def stale(event_type, event_content, data) do
    handle_unexpected(event_type, event_content, :stale, data)
  end

  # State: :synced
  def synced(:enter, _old_state, data) do
    actions = [{:state_timeout, data.update_interval, :update_master_state}]
    {:keep_state_and_data, actions}
  end

  def synced(:cast, :activate, data) do
    # TODO check if all slaves are configured
    {:next_state, :operational, data}
  end

  def synced({:call, from}, {:request_nif, request_fn, request_args}, data) do
    result = apply(Nif, request_fn, [data.master_ref | request_args])
    actions = [{:reply, from, result}]
    {:keep_state_and_data, actions}
  end

  def synced({:call, from}, {:create_domain, name, interval}, data) do
    domain_ref = Nif.master_create_domain(data.master_ref)

    case Domain.start_link(name, domain_ref, interval) do
      {:ok, domain} ->
        actions = [{:reply, from, domain_ref}]
        {:keep_state, %{data | domains: [domain | data.domains]}, actions}

      {:error, reason} ->
        actions = [{:reply, from, {:error, reason}}]
        {:keep_state_and_data, actions}
    end
  end

  def synced({:call, from}, :get_ref, data) do
    actions = [{:reply, from, data.master_ref}]
    {:keep_state_and_data, actions}
  end

  def synced(:state_timeout, :update_master_state, data) do
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

  def synced(event_type, event_content, data) do
    handle_unexpected(event_type, event_content, :synced, data)
  end

  # State: operational
  def operational(:enter, _old_state, data) do
    Nif.master_activate(data.master_ref)
    parent_pid = self()

    domain_configs =
      Enum.map(data.domains, fn domain ->
        resource = Domain.get_ref(domain)
        interval = Domain.get_interval(domain)
        %{pid: domain, resource: resource, interval: interval}
      end)

    task_pid =
      spawn_link(fn ->
        Nif.cyclic_task(parent_pid, data.master_ref, domain_configs, data.update_interval)
      end)

    {:keep_state, %{data | task_pid: task_pid}, []}
  end

  def operational(:info, {:master_state_changed, master_state}, data) do
    IO.inspect(master_state, label: "Master State Changed")
    {:keep_state_and_data, []}
  end

  def operational(:info, {domain, :data_changed, domain_data, data_changes}, data) do
    IO.inspect(data_changes, label: "Data Changed")
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
