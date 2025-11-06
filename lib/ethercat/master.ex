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

  def stale({:call, from}, :sync_slaves, data) do
    master_state = Nif.get_master_state(data.master_ref)

    slaves =
      for slave_position <- create_range(master_state.slaves_responding) do
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
      end

    {:next_state, :synced, %{data | slaves: slaves}, [{:reply, from, {:ok, slaves}}]}
  end

  def stale(:state_timeout, :update_master_state, data) do
    master_state = Nif.get_master_state(data.master_ref)
    require Logger
    Logger.debug("Master state (stale): #{inspect(master_state)}")

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
    # Finalize all domain registrations before activation
    # We handle this directly here to avoid deadlock (Domain can't call back to Master)
    Enum.each(data.domains, fn domain ->
      :ok = finalize_domain_registrations(domain, data.master_ref)
    end)

    # TODO check if all slaves are configured
    {:next_state, :operational, data}
  end

  # Gateway for Slave module operations - ensures only Master talks to NIF
  def synced({:call, from}, {:slave_operation, position, operation, args}, data) do
    result = execute_slave_operation(data.master_ref, position, operation, args)
    {:keep_state_and_data, [{:reply, from, result}]}
  end

  # Gateway for Domain module operations - ensures only Master talks to NIF
  def synced({:call, from}, {:domain_operation, operation, args}, _data) do
    result = execute_domain_operation(operation, args)
    {:keep_state_and_data, [{:reply, from, result}]}
  end

  def synced({:call, from}, {:create_domain, name, interval}, data) do
    domain_ref = Nif.master_create_domain(data.master_ref)

    case Domain.start_link(name, self(), domain_ref, interval) do
      {:ok, domain} ->
        {:keep_state, %{data | domains: [domain | data.domains]}, [{:reply, from, domain_ref}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  def synced({:call, from}, :get_ref, data) do
    {:keep_state_and_data, [{:reply, from, data.master_ref}]}
  end

  def synced(:state_timeout, :update_master_state, data) do
    master_state = Nif.get_master_state(data.master_ref)
    require Logger
    Logger.debug("Master state (synced/ready): #{inspect(master_state)}")

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
    require Logger
    Logger.info("Master State Changed: #{inspect(master_state)}")
    {:keep_state_and_data, []}
  end

  def operational(:info, {_domain, :data_changed, _domain_data, data_changes}, _data) do
    require Logger
    Logger.debug("Data Changed: #{inspect(data_changes)}")
    {:keep_state_and_data, []}
  end

  def operational({:call, from}, :get_ref, data) do
    actions = [{:reply, from, data.master_ref}]
    {:keep_state_and_data, actions}
  end

  # Gateway for Domain module operations in operational state
  def operational({:call, from}, {:domain_operation, operation, args}, _data) do
    result = execute_domain_operation(operation, args)
    {:keep_state_and_data, [{:reply, from, result}]}
  end

  def operational(event_type, event_content, data) do
    handle_unexpected(event_type, event_content, :operational, data)
  end

  # Common catch-all handler for unexpected events
  defp handle_unexpected(event_type, event_content, state, _data) do
    Logger.warning("Unexpected event in state #{state}: #{inspect({event_type, event_content})}")
    {:keep_state_and_data, []}
  end

  # Executes slave operations by routing them to appropriate NIF functions
  defp execute_slave_operation(master_ref, position, operation, args) do
    case operation do
      # Introspection operations
      :get_sync_manager ->
        [sync_index] = args
        Nif.master_get_sync_manager(master_ref, position, sync_index)

      :get_pdo ->
        [sync_index, pdo_pos] = args
        Nif.master_get_pdo(master_ref, position, sync_index, pdo_pos)

      :get_pdo_entry ->
        [sync_index, pdo_pos, entry_pos] = args
        Nif.master_get_pdo_entry(master_ref, position, sync_index, pdo_pos, entry_pos)

      :slave_config ->
        [alias_val, vendor_id, product_code] = args
        Nif.master_slave_config(master_ref, alias_val, position, vendor_id, product_code)

      # Configuration operations (must be called before activation)
      :config_sync_manager ->
        [slave_config, sync_index, direction, watchdog] = args
        Nif.slave_config_sync_manager(slave_config, sync_index, direction, watchdog)

      :config_pdo_assign_clear ->
        [slave_config, sync_index] = args
        Nif.slave_config_pdo_assign_clear(slave_config, sync_index)

      :config_pdo_assign_add ->
        [slave_config, sync_index, pdo_index] = args
        Nif.slave_config_pdo_assign_add(slave_config, sync_index, pdo_index)

      :config_pdo_mapping_clear ->
        [slave_config, pdo_index] = args
        Nif.slave_config_pdo_mapping_clear(slave_config, pdo_index)

      :config_pdo_mapping_add ->
        [slave_config, pdo_index, entry_index, entry_subindex, entry_size] = args

        Nif.slave_config_pdo_mapping_add(
          slave_config,
          pdo_index,
          entry_index,
          entry_subindex,
          entry_size
        )

      _ ->
        {:error, {:unknown_operation, operation}}
    end
  end

  # Executes domain operations by routing them to appropriate NIF functions
  defp execute_domain_operation(operation, args) do
    case operation do
      :register_pdo_entry ->
        [slave_config, entry_index, entry_subindex, domain_ref] = args
        Nif.slave_config_reg_pdo_entry(slave_config, entry_index, entry_subindex, domain_ref)

      :set_value_bool ->
        [domain_ref, offset, value] = args
        Nif.set_domain_value_bool(domain_ref, offset, value)

      :get_value_bool ->
        [domain_ref, offset] = args
        Nif.get_domain_value_bool(domain_ref, offset)

      _ ->
        {:error, {:unknown_operation, operation}}
    end
  end

  # Finalizes domain PDO registrations by calling the NIF directly.
  # This avoids deadlock by not requiring Domain to call back to Master.
  # Called during activation to register all pending PDO entries with their domains.
  defp finalize_domain_registrations(domain, _master_ref) do
    pending = Domain.get_pending_registrations(domain)
    domain_ref = Domain.get_ref(domain)

    entries =
      for {slave_config, pdo_entries} <- pending,
          {name, {entry_index, entry_subindex, entry_size}} <- pdo_entries do
        offset =
          Nif.slave_config_reg_pdo_entry(slave_config, entry_index, entry_subindex, domain_ref)

        {name, {offset, entry_size}}
      end
      |> Map.new()

    Domain.store_entries(domain, entries)
  end

  # Determines which driver to use for a slave based on vendor ID and product code.
  # Currently returns Generic driver for all devices. In the future, this can be
  # extended to support device-specific drivers.
  defp driver_for_slave(_vendor_id, _product_code) do
    EtherCAT.Drivers.Generic
  end
end
