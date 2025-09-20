defmodule IghEthercat.Master do
  @behaviour :gen_statem
  require Logger

  alias IghEthercat.{Nif, Slave, Domain}

  defstruct [:master_ref, :slaves, :domains]

  @type t :: %__MODULE__{
          master_ref: reference(),
          slaves: [Slave.t()],
          domains: [Domain.t()]
        }

  @impl true
  def callback_mode(), do: [:handle_event_function]

  # Client API
  def start_link(opts \\ []) do
    master_index = Keyword.get(opts, :master_index, 0)
    :gen_statem.start_link(__MODULE__, {master_index}, name: __MODULE__)
  end

  def scan(master) do
    :gen_statem.call(master, :scan)
  end

  def get_ref(master) do
    :gen_statem.call(master, :get_ref)
  end

  def test do
    {:ok, master} = start_link()
    scan(master)
  end

  @impl true
  def init({master_index}) do
    data = %__MODULE__{
      master_ref: nil,
      domains: [],
      slaves: []
    }

    actions = [{:next_event, :internal, {:connect, master_index}}]
    {:ok, :stale, data, actions}
  end

  @impl true
  def handle_event(:internal, {:connect, master_index}, :stale, data) do
    case Nif.request_master(master_index) do
      ref ->
        Process.send_after(self(), :update_master_state, 1_000)
        {:keep_state, %{data | master_ref: ref}}
    end
  end

  def handle_event({:call, from}, :scan, :stale, data) do
    master_state = Nif.get_master_state(data.master_ref)

    slaves =
      for slave_position <- create_range(master_state.slaves_responding) do
        {:ok, slave} = Nif.master_get_slave(data.master_ref, slave_position)

        for sync_index <- create_range(slave.sync_count) do
          sync_manager = Nif.master_get_sync_manager(data.master_ref, slave_position, sync_index)

          for pos <- create_range(sync_manager.n_pdos) do
            pdo = Nif.master_get_pdo(data.master_ref, slave_position, sync_index, pos)

            for entry_pos <- create_range(pdo.n_entries) do
              pdo_entry =
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

    {:keep_state_and_data, actions}
  end

  def handle_event({:call, from}, :get_ref, _state, data) do
    actions = [{:reply, from, data.master_ref}]
    {:keep_state_and_data, actions}
  end

  def handle_event(:info, :update_master_state, :stale, data) do
    Process.send_after(self(), :update_master_state, 1_000)
    master_state = Nif.get_master_state(data.master_ref)

    if master_state.slaves_responding == length(data.slaves) do
      {:next_state, :synced, data}
    else
      {:keep_state_and_data, []}
    end
  end

  def handle_event(:info, :update_master_state, :synced, data) do
    Process.send_after(self(), :update_master_state, 1_000)
    master_state = Nif.get_master_state(data.master_ref)

    if master_state.slaves_responding == length(data.slaves) do
      {:keep_state_and_data, []}
    else
      # TODO kill current slaves
      {:next_state, :stale, %{data | slaves: []}}
    end
  end

  def handle_event(:info, :update_master_state, :operational, data) do
    Process.send_after(self(), :update_master_state, 1_000)
    master_state = Nif.get_master_state(data.master_ref)

    if master_state.slaves_responding == length(data.slaves) do
      {:keep_state_and_data, []}
    else
      # TODO kill current slaves
      # TODO deactivate master
      {:next_state, :stale, %{data | slaves: []}}
    end
  end

  defp create_range(0), do: []
  defp create_range(n), do: 0..(n - 1)
end
