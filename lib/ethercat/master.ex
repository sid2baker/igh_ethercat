defmodule EtherCAT.Master do
  @behaviour :gen_statem
  require Logger

  alias EtherCAT.Master.Nif
  alias EtherCAT.Master.Slave

  @version {1, 6}
  @offline_poll_ms 500
  @stale_check_hardware_ms 500

  @type t :: %__MODULE__{
          master_ref: reference(),
          master_index: non_neg_integer(),
          hardware_config: map(),
          slaves: %{slave_position() => Slave.t()},
          entry_to_index: %{
            Slave.pdo_entry() => {domain_name(), slave_position(), Slave.pdo_entry_index()}
          },
          domains: %{domain_name() => %{ref: reference(), update_rate_us: non_neg_integer()}},
          thread_pid: pid(),
          pending_requests: %{any() => pid()}
        }

  @type domain_name() :: atom()
  @type slave_position() :: non_neg_integer()

  defstruct [
    :master_ref,
    :master_index,
    :hardware_config,
    :slaves,
    :entry_to_index,
    :last_slaves_count,
    :domains,
    :thread_pid,
    :pending_requests
  ]

  def start_link(opts \\ []) do
    @version = Nif.version()
    :gen_statem.start_link({:local, __MODULE__}, __MODULE__, opts, [])
  end

  def child_spec(opts) do
    default = %{
      id: __MODULE__,
      start: {EtherCAT.Master, :start_link, [opts]},
      restart: :permanent,
      shutdown: 5000,
      type: :worker
    }

    Supervisor.child_spec(default, [])
  end

  def get_master_ref() do
    {_, %{master_ref: master_ref}} = :sys.get_state(__MODULE__)
    master_ref
  end

  @spec set_hardware_config(config :: map) :: :ok | {:error, any()}
  def set_hardware_config(config) do
    :gen_statem.call(__MODULE__, {:set_hardware_config, config})
  end

  @spec read_pdo_entry(Slave.pdo_entry()) :: :ok | {:error, any()}
  def read_pdo_entry(pdo_entry) do
    :gen_statem.call(__MODULE__, {:read_pdo_entry, pdo_entry})
  end

  @spec write_pdo_entry(Slave.pdo_entry(), binary()) :: :ok | {:error, any()}
  def write_pdo_entry(pdo_entry, binary_data) do
    :gen_statem.call(__MODULE__, {:write_pdo_entry, pdo_entry, binary_data})
  end

  def stop_thread() do
    :gen_statem.call(__MODULE__, :stop_thread)
  end

  @spec wait_for(atom(), timeout()) :: :ok | {:error, :timeout}
  def wait_for(state, timeout \\ 5_000) do
    :gen_statem.call(__MODULE__, {:wait_for, state}, timeout)
  end

  @impl true
  def callback_mode(), do: [:state_functions, :state_enter]

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    master_index = Keyword.get(opts, :master_index, 0)
    hardware_config = Keyword.get(opts, :hardware_config, nil)

    case Nif.create_master(master_index) do
      {:ok, master_ref} ->
        data = %__MODULE__{
          master_ref: master_ref,
          master_index: master_index,
          hardware_config: hardware_config,
          slaves: %{},
          entry_to_index: %{},
          last_slaves_count: 0,
          domains: %{},
          thread_pid: nil,
          pending_requests: %{}
        }

        Logger.info("Master #{master_index} initialized")

        if hardware_config do
          Logger.info("Hardware configuration: #{inspect(hardware_config)}")
          {:ok, :synced, data}
        else
          {:ok, :offline, data}
        end

      {:error, reason} ->
        Logger.error("Failed to request master: #{inspect(reason)}")
        {:stop, :failed_to_create_master}
    end
  end

  @impl true
  def terminate(_reason, _state, data) do
    stop_thread(data.master_ref, data.thread_pid)
    Logger.info("Master #{data.master_index} terminated")
    Nif.destroy_master(data.master_ref)
    :ok
  end

  def offline(:enter, :offline, data) do
    Logger.info("Entered :offline")
    {data, replies} = reply_to_waiters(data, :offline)
    {:keep_state, data, replies ++ [{:state_timeout, @offline_poll_ms, :poll}]}
  end

  def offline(:enter, _old_state, data) do
    Logger.info("Entered :offline - reset master")
    stop_thread(data.master_ref, data.thread_pid)

    :ok = Nif.reset_master(data.master_ref)
    {data, replies} = reply_to_waiters(data, :offline)
    {:keep_state, data, replies ++ [{:state_timeout, @offline_poll_ms, :poll}]}
  end

  def offline(:state_timeout, :poll, data) do
    case Nif.get_master_info(data.master_ref) do
      {:ok, %{link_up: true, slaves_count: count}} ->
        Logger.info("Link up, #{count} slaves detected")
        new_data = %{data | last_slaves_count: count}
        {:next_state, :stale, new_data}

      {:ok, %{link_up: false}} ->
        {:keep_state_and_data, [{:state_timeout, @offline_poll_ms, :poll}]}

      {:error, reason} ->
        Logger.error("Failed to poll master state: #{inspect(reason)}")
        {:keep_state_and_data, [{:state_timeout, @offline_poll_ms, :poll}]}
    end
  end

  def offline({:call, from}, {:set_hardware_config, config}, data) do
    Logger.info("Hardware config stored (#{length(config.slaves)} slaves)")
    new_data = %{data | hardware_config: config}
    {:keep_state, new_data, [{:reply, from, :ok}]}
  end

  def offline({:call, from}, {:wait_for, state}, data) do
    handle_wait_for(from, state, :offline, data)
  end

  def offline({:call, from}, _event, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :offline}}]}
  end

  def offline(_event_type, _event, _data) do
    :keep_state_and_data
  end

  def stale(:enter, _old_state, data) do
    Logger.info("Entered :stale - monitoring topology stability")
    {:ok, pid} = start_watch_hardware_thread(data.master_ref)

    new_data = %{data | thread_pid: pid}
    {new_data, replies} = reply_to_waiters(new_data, :stale)

    {:keep_state, new_data,
     replies ++ [{:state_timeout, @stale_check_hardware_ms, :check_hardware}]}
  end

  def stale(:state_timeout, :check_hardware, %{hardware_config: nil}) do
    {:keep_state_and_data, [{:state_timeout, @stale_check_hardware_ms, :check_hardware}]}
  end

  def stale(:state_timeout, :check_hardware, data) do
    if hardware_config_matches?(
         data.master_ref,
         data.hardware_config.slaves,
         data.last_slaves_count
       ) do
      {:next_state, :synced, data}
    else
      Logger.warning("Hardware configuration mismatch")
      {:keep_state_and_data, [{:state_timeout, @stale_check_hardware_ms, :check_hardware}]}
    end
  end

  def stale({:call, from}, {:set_hardware_config, config}, data) do
    Logger.info("New config set (#{length(config.slaves)} slaves)")
    new_data = %{data | hardware_config: config}
    {:keep_state, new_data, [{:reply, from, :ok}]}
  end

  def stale({:call, from}, {:wait_for, state}, data) do
    handle_wait_for(from, state, :stale, data)
  end

  def stale({:call, from}, _event, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :stale}}]}
  end

  def stale(:info, :link_down, data) do
    Logger.warning("Link down")
    {:next_state, :offline, data}
  end

  def stale(:info, {:topology_changed, slaves_count, slave_states}, data) do
    Logger.info("Slave count changed to #{slaves_count}")
    Logger.debug(inspect(slave_states))
    new_data = %{data | last_slaves_count: slaves_count}
    {:keep_state, new_data}
  end

  def stale(_event_type, _event, _data) do
    :keep_state_and_data
  end

  defp hardware_config_matches?(master_ref, slave_configs, count) do
    length(slave_configs) == count and
      slave_configs
      |> Enum.with_index()
      |> Enum.all?(fn {config, pos} ->
        case Nif.get_slave_info(master_ref, pos) do
          {:ok, info} ->
            config.device_identity.vendor_id == info.vendor_id and
              config.device_identity.product_code == info.product_code

          # config.device_identity.revision_no == info.revision_no and
          # config.device_identity.serial_no == info.serial_no

          {:error, _} ->
            false
        end
      end)
  end

  def synced(:enter, old_state, data) do
    Logger.info("Entered :synced from #{old_state}")

    {data, replies} = reply_to_waiters(data, :synced)

    # stop watch_hardware_thread
    stop_thread(data.master_ref, data.thread_pid)

    # derive cyclic_interval_us from smallest domain update_rate_us
    cyclic_interval_us =
      data.hardware_config.domains
      |> Enum.map(& &1.update_rate_us)
      |> Enum.min()

    # set master settings
    :ok = Nif.set_cyclic_interval(data.master_ref, cyclic_interval_us)
    :ok = Nif.set_cyclic_core(data.master_ref, Application.get_env(:ethercat, :cyclic_core, 0))

    domains =
      Enum.map(data.hardware_config.domains, fn domain ->
        if rem(domain.update_rate_us, cyclic_interval_us) != 0 do
          Logger.warning(
            "Domain #{domain.name} update_rate_us (#{domain.update_rate_us}) is not a multiple of cyclic_interval_us (#{cyclic_interval_us})"
          )
        end

        cycle_count = div(domain.update_rate_us, cyclic_interval_us)
        {:ok, ref} = Nif.create_domain(data.master_ref, cycle_count)

        {domain.name, %{ref: ref, update_rate_us: domain.update_rate_us}}
      end)
      |> Map.new()

    Logger.info("Created domains #{inspect(domains)}")

    slaves =
      Enum.map(data.hardware_config.slaves, fn slave ->
        driver = slave.driver || EtherCAT.Slave.GenericDriver
        spec = driver.child_spec(name: slave.name, config: slave.config)
        {:ok, pid} = DynamicSupervisor.start_child(EtherCAT.SlaveSupervisor, spec)

        {:ok, slave_ref} =
          Nif.create_slave(
            data.master_ref,
            0x0000,
            slave.position,
            slave.device_identity.vendor_id,
            slave.device_identity.product_code
          )

        :ok = driver.configure(pid)

        {slave.position,
         %{
           name: slave.name,
           ref: slave_ref,
           pdo_entries: slave.registered_entries,
           configured?: false
         }}
      end)
      |> Map.new()

    Logger.info("Created slaves #{inspect(slaves)}")

    new_data = %{data | domains: domains, slaves: slaves}
    {:keep_state, new_data, replies}
  end

  def synced({:call, from}, {:wait_for, state}, data) do
    handle_wait_for(from, state, :synced, data)
  end

  def synced({:call, from}, {:slave_configured, configured_pdos}, data) do
    # pdos in the form %{{:pdo_name, :entry_name} => {direction, {index, subindex, bit_length}}
    {position, slave} = get_slave_from(data, from)

    {pdo_entries, entry_to_index} =
      for {domain_name, registered_entries} <- slave.pdo_entries,
          {pdo_name, entry_name} <- registered_entries do
        {direction, {entry_index, entry_subindex, bit_length}} =
          configured_pdos[{pdo_name, entry_name}]

        {:ok, pdo_index} =
          Nif.register_pdo_entry(
            slave.ref,
            data.domains[domain_name].ref,
            entry_index,
            entry_subindex,
            bit_length,
            direction
          )

        pdo_entry = {slave.name, pdo_name, entry_name}
        index_to_entry = {pdo_index, pdo_entry}
        entry_to_index = {pdo_entry, {domain_name, position, pdo_index}}
        {index_to_entry, entry_to_index}
      end
      |> Enum.unzip()
      |> then(&{Map.new(elem(&1, 0)), Map.new(elem(&1, 1))})

    new_slaves =
      Map.update!(data.slaves, position, fn slave ->
        %{slave | pdo_entries: pdo_entries, configured?: true}
      end)

    new_data = %{
      data
      | slaves: new_slaves,
        entry_to_index: Map.merge(data.entry_to_index, entry_to_index)
    }

    configured_slaves = Enum.count(new_data.slaves, fn {_k, slave} -> slave.configured? end)
    Logger.info("Slave configured #{configured_slaves}/#{Map.size(new_data.slaves)}")

    if Enum.all?(new_data.slaves, fn {_k, slave} -> slave.configured? end) do
      Logger.info("All slaves configured")
      {:next_state, :operational, new_data, [{:reply, from, :ok}]}
    else
      {:keep_state, new_data, [{:reply, from, :ok}]}
    end
  end

  def synced({:call, from}, {:slave_config, method, args}, data) do
    {_position, slave} = get_slave_from(data, from)

    result =
      case method do
        :sdo ->
          [index, subindex, data] = args
          Nif.slave_config_sdo(slave.ref, index, subindex, data)

        :sync_manager ->
          [sm_index, direction, watchdog] = args
          Nif.slave_config_sync_manager(slave.ref, sm_index, direction, watchdog)

        :pdo_assign_clear ->
          [index] = args
          Nif.slave_config_pdo_assign_clear(slave.ref, index)

        :pdo_assign_add ->
          [sm_index, pdo_index] = args
          Nif.slave_config_pdo_assign_add(slave.ref, sm_index, pdo_index)

        :pdo_mapping_clear ->
          [pdo_index] = args
          Nif.slave_config_pdo_mapping_clear(slave.ref, pdo_index)

        :pdo_mapping_add ->
          [pdo_index, entry_index, entry_subindex, bit_length] = args

          Nif.slave_config_pdo_mapping_add(
            slave.ref,
            pdo_index,
            entry_index,
            entry_subindex,
            bit_length
          )
      end

    {:keep_state_and_data, [{:reply, from, result}]}
  end

  def synced({:call, from}, _event, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_operational}}]}
  end

  def synced(_event_type, _event, _data) do
    :keep_state_and_data
  end

  def operational(:enter, _old_state, data) do
    Logger.info("Entered :operational - cyclic task active")

    domain_refs =
      data.domains
      |> Enum.map(fn {_key, domain} -> domain.ref end)

    {:ok, pid} = start_cyclic_thread(data.master_ref, domain_refs)
    new_data = %{data | thread_pid: pid}
    {new_data, replies} = reply_to_waiters(new_data, :operational)
    {:keep_state, new_data, replies}
  end

  def operational({:call, from}, {:read_pdo_entry, entry}, data) do
    {domain_name, _slave_id, entry_index} = data.entry_to_index[entry]
    domain_ref = data.domains[domain_name].ref

    case Nif.read_pdo_value(domain_ref, entry_index) do
      {:ok, value} ->
        {:keep_state_and_data, [{:reply, from, {:ok, value}}]}

      _ ->
        {:keep_state_and_data, [{:reply, from, {:error, :not_found}}]}
    end
  end

  def operational({:call, from}, {:write_pdo_entry, entry, value}, data) do
    {domain_name, slave_id, entry_id} = data.entry_to_index[entry]
    domain = data.domains[domain_name]

    case Nif.write_pdo_value(domain.ref, entry_id, value) do
      :ok ->
        request_id = {:write_pdo_entry, slave_id, entry_id}
        pending_requests = Map.put(data.pending_requests, request_id, from)

        {:keep_state, %{data | pending_requests: pending_requests},
         [{{:timeout, request_id}, div(domain.update_rate_us, 1000) * 3, :pdo_write_timeout}]}

      {:error, :already_set} ->
        {:keep_state_and_data, [{:reply, from, :ok}]}

      {:error, error} ->
        {:keep_state_and_data, [{:reply, from, {:error, error}}]}
    end
  end

  def operational({:call, from}, :stop_thread, data) do
    stop_thread(data.master_ref, data.thread_pid)
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  def operational({:call, from}, {:wait_for, state}, data) do
    handle_wait_for(from, state, :operational, data)
  end

  def operational({:call, from}, _event, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :invalid_in_operational}}]}
  end

  def operational({:timeout, request_id}, :pdo_write_timeout, data) do
    case Map.pop(data.pending_requests, request_id) do
      {from, pending_requests} when from != nil ->
        Logger.warning("PDO write timeout: #{inspect(request_id)}")

        {:keep_state, %{data | pending_requests: pending_requests},
         [{:reply, from, {:error, :timeout}}]}

      {nil, _} ->
        # Already completed, ignore
        :keep_state_and_data
    end
  end

  def operational(:info, {:output_changed, slave_id, entry_id}, data) do
    request_id = {:write_pdo_entry, slave_id, entry_id}

    case Map.pop(data.pending_requests, request_id) do
      {from, pending_requests} when from != nil ->
        {:keep_state, %{data | pending_requests: pending_requests},
         [
           {{:timeout, request_id}, :infinity, nil},
           {:reply, from, :ok}
         ]}

      {nil, _} ->
        # No pending request (already timed out or duplicate message)
        :keep_state_and_data
    end
  end

  def operational(:info, {:input_changed, slave_id, entry_id, value}, data) do
    case data.slaves[slave_id] do
      nil ->
        :keep_state_and_data

      slave ->
        entry = slave.pdo_entries[entry_id]

        case Process.whereis(slave.name) do
          nil ->
            Logger.warning("Slave #{slave.name} not found")

          pid ->
            send(pid, {:ec_update, entry, value})
        end

        :keep_state_and_data
    end
  end

  def operational(:info, _msg, _data) do
    :keep_state_and_data
  end

  defp start_watch_hardware_thread(master_ref) do
    case Nif.enable_thread(master_ref) do
      :ok ->
        pid = spawn_link(fn -> Nif.create_watch_hardware_thread(master_ref) end)
        {:ok, pid}

      error ->
        error
    end
  end

  defp start_cyclic_thread(master_ref, domain_refs) do
    case Nif.enable_thread(master_ref) do
      :ok ->
        pid = spawn_link(fn -> Nif.create_cyclic_thread(master_ref, domain_refs) end)
        {:ok, pid}

      error ->
        error
    end
  end

  defp stop_thread(_master_ref, nil) do
    Logger.warning("No thread to stop")
    {:error, :no_thread}
  end

  defp stop_thread(master_ref, thread_pid) do
    case Nif.stop_thread(master_ref) do
      :ok ->
        receive do
          {:EXIT, ^thread_pid, reason} ->
            Logger.info("Thread stopped with reason: #{inspect(reason)}")
            :ok
        after
          1000 ->
            Logger.error("Thread exit timeout")
            {:error, :timeout}
        end

      {:error, :thread_not_started} ->
        :ok

      {:error, error} ->
        Logger.error("Failed to stop thread: #{inspect(error)}")
        {:error, error}
    end
  end

  defp get_slave_from(data, {pid, _ref}) do
    Enum.find(data.slaves, fn {_key, slave} ->
      Process.whereis(slave.name) == pid
    end)
  end

  defp reply_to_waiters(data, current_state) do
    {waiters, remaining} =
      Map.split_with(data.pending_requests, fn {_ref, request} ->
        match?({:wait_for, _from, ^current_state}, request)
      end)

    replies =
      Enum.map(waiters, fn {_ref, {:wait_for, from, _state}} ->
        {:reply, from, :ok}
      end)

    {%{data | pending_requests: remaining}, replies}
  end

  defp handle_wait_for(from, requested_state, current_state, data) do
    if current_state == requested_state do
      {:keep_state_and_data, [{:reply, from, :ok}]}
    else
      ref = make_ref()
      pending = Map.put(data.pending_requests, ref, {:wait_for, from, requested_state})
      {:keep_state, %{data | pending_requests: pending}}
    end
  end
end
