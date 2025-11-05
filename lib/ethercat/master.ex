defmodule EtherCAT.Master do
  @behaviour :gen_statem
  require Logger
  import EtherCAT.Utils

  alias EtherCAT.{Nif, Slave, Domain}

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

  @doc """
  Starts the EtherCAT master process.

  ## Options
  - `:master_index` - The EtherCAT master index (default: 0)
  - `:update_interval` - State update interval in microseconds (default: 10_000)
  """
  def start_link(opts \\ []) do
    master_index = Keyword.get(opts, :master_index, 0)
    update_interval = Keyword.get(opts, :update_interval, 10_000)
    :gen_statem.start_link(__MODULE__, {master_index, update_interval}, name: __MODULE__)
  end

  @doc """
  Connects to the EtherCAT network and checks if the link is up.
  """
  def connect(master) do
    :gen_statem.call(master, :connect)
  end

  @doc """
  Synchronizes slaves - discovers and configures all slaves on the bus.
  Returns `{:ok, [slave_pids]}` on success.
  """
  def sync_slaves(master) do
    :gen_statem.call(master, :sync_slaves)
  end

  @doc """
  Creates a new process data domain.
  Domains allow grouping of process data transfers with different periods.
  """
  def create_domain(master, name, interval) do
    :gen_statem.call(master, {:create_domain, name, interval})
  end

  @doc """
  Activates the master for cyclic operation.
  After activation, no further configuration changes are allowed.
  """
  def activate(master) do
    :gen_statem.cast(master, :activate)
  end

  @doc """
  Gets the master's NIF reference.
  """
  def get_ref(master) do
    :gen_statem.call(master, :get_ref)
  end

  # Internal API - called by Slave and Domain modules
  # These functions serve as the single gateway for all NIF operations,
  # preventing race conditions by ensuring only Master talks to the NIF.

  @doc false
  def slave_operation(master, position, operation, args) do
    :gen_statem.call(master, {:slave_operation, position, operation, args})
  end

  @doc false
  def domain_operation(master, operation, args) do
    :gen_statem.call(master, {:domain_operation, operation, args})
  end

  # Callbacks
  @impl true
  def callback_mode(), do: [:state_functions, :state_enter]

  @impl true
  def init({master_index, update_interval}) do
    case Nif.request_master(master_index) do
      {:ok, ref} ->
        domain_ref = Nif.master_create_domain(ref)
        {:ok, domain} = Domain.start_link(:default_domain, self(), domain_ref, 1)

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
  # Master is created but not yet connected to the network

  def offline(:enter, _old_state, _data) do
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

  def offline({:call, from}, _event_content, _data) do
    actions = [{:reply, from, {:error, :offline}}]
    {:keep_state_and_data, actions}
  end

  def offline(event_type, event_content, data) do
    handle_unexpected(event_type, event_content, :offline, data)
  end

  # State: stale
  # Network is up but slaves are not yet discovered/synchronized

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
        driver = driver_for_slave(slave_info.vendor_id, slave_info.product_code)

        slave_config =
          Nif.master_slave_config(
            data.master_ref,
            0,
            slave_position,
            slave_info.vendor_id,
            slave_info.product_code
          )

        {:ok, slave} =
          Slave.create(self(), slave_position, driver, slave_config, slave_info.sync_count)

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

  # State: synced
  # Slaves are discovered and synchronized, ready for configuration

  def synced(:enter, _old_state, data) do
    actions = [{:state_timeout, data.update_interval, :update_master_state}]
    {:keep_state_and_data, actions}
  end

  def synced(:cast, :activate, data) do
    # TODO check if all slaves are configured
    {:next_state, :operational, data}
  end

  # Gateway for Slave module operations - ensures only Master talks to NIF
  def synced({:call, from}, {:slave_operation, position, operation, args}, data) do
    result =
      case operation do
        :get_sync_manager ->
          [sync_index] = args
          Nif.master_get_sync_manager(data.master_ref, position, sync_index)

        :get_pdo ->
          [sync_index, pdo_pos] = args
          Nif.master_get_pdo(data.master_ref, position, sync_index, pdo_pos)

        :get_pdo_entry ->
          [sync_index, pdo_pos, entry_pos] = args
          Nif.master_get_pdo_entry(data.master_ref, position, sync_index, pdo_pos, entry_pos)

        :slave_config ->
          [alias_val, vendor_id, product_code] = args
          Nif.master_slave_config(data.master_ref, alias_val, position, vendor_id, product_code)

        _ ->
          {:error, {:unknown_operation, operation}}
      end

    actions = [{:reply, from, result}]
    {:keep_state_and_data, actions}
  end

  # Gateway for Domain module operations - ensures only Master talks to NIF
  def synced({:call, from}, {:domain_operation, operation, args}, _data) do
    result =
      case operation do
        :register_pdo_entry ->
          [slave_config, entry_index, entry_subindex, domain_ref] = args
          Nif.slave_config_reg_pdo_entry(slave_config, entry_index, entry_subindex, domain_ref)

        _ ->
          {:error, {:unknown_operation, operation}}
      end

    actions = [{:reply, from, result}]
    {:keep_state_and_data, actions}
  end

  def synced({:call, from}, {:create_domain, name, interval}, data) do
    domain_ref = Nif.master_create_domain(data.master_ref)

    case Domain.start_link(name, self(), domain_ref, interval) do
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
  # Master is activated and running cyclic communication

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

  def operational(:info, {:master_state_changed, master_state}, _data) do
    IO.inspect(master_state, label: "Master State Changed")
    {:keep_state_and_data, []}
  end

  def operational(:info, {_domain, :data_changed, _domain_data, data_changes}, _data) do
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

  # Common catch-all handler for unexpected events
  defp handle_unexpected(event_type, event_content, state, _data) do
    Logger.warning("Unexpected event in state #{state}: #{inspect({event_type, event_content})}")
    {:keep_state_and_data, []}
  end

  # Helper function to determine which driver to use for a slave
  # Currently returns Generic driver for all slaves
  # TODO: Implement driver selection based on vendor_id and product_code

  defp driver_for_slave(vendor_id, product_code) do
    case {vendor_id, product_code} do
      {_, _} -> EtherCAT.Drivers.Generic
    end
  end
end
