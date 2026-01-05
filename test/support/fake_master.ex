defmodule Support.FakeMaster do
  @moduledoc """
  Manages a peer node for the fake EtherCAT master.

  Uses OTP's `:peer` module to spawn a separate BEAM with environment
  variables needed by libfakeethercat (FAKE_EC_NAME=Simulator).

  The NIF reads FAKE_EC_NAME at load time, so we must:
  1. Start the peer with env vars but WITHOUT project code paths
  2. Start Elixir applications
  3. Add project code paths
  4. Then load the EtherCAT modules (which loads the NIF)
  """

  @fake_ec_homedir "/tmp/FakeEtherCAT"
  @project_path_pattern ~r"/igh_ethercat/_build"

  def start_link(name \\ :fake_master) do
    all_paths = :code.get_path()

    # Separate project paths from system paths
    # Project paths contain the NIF which reads env at load time
    {project_paths, system_paths} =
      Enum.split_with(all_paths, fn p ->
        to_string(p) =~ @project_path_pattern
      end)

    pa_args = Enum.flat_map(system_paths, fn path -> [~c"-pa", path] end)
    cookie = Node.get_cookie() |> Atom.to_charlist()

    {:ok, pid, node} =
      :peer.start(%{
        name: name,
        host: ~c"127.0.0.1",
        longnames: true,
        args: pa_args ++ [~c"-setcookie", cookie],
        env: [
          {~c"FAKE_EC_NAME", ~c"Simulator"},
          {~c"FAKE_EC_HOMEDIR", to_charlist(@fake_ec_homedir)},
          {~c"MIX_ENV", ~c"test"}
        ]
      })

    # Start Elixir applications first (before loading NIF)
    :ok = :erpc.call(node, :application, :start, [:compiler])
    :ok = :erpc.call(node, :application, :start, [:elixir])
    :ok = :erpc.call(node, :application, :start, [:logger])

    # Now add project code paths (NIF will load with correct env)
    Enum.each(project_paths, fn p ->
      :erpc.call(node, :code, :add_patha, [p])
    end)

    # Load the NIF module (reads FAKE_EC_NAME env var at load time)
    :erpc.call(node, Code, :ensure_loaded, [EtherCAT.Master.Nif])

    {:ok, _sup} = :erpc.call(node, Support.FakeMaster, :do_create_supervisor, [])

    {:ok, %{pid: pid, node: node}}
  end

  def start_master(%{node: node}, config) do
    :erpc.call(node, DynamicSupervisor, :start_child, [
      FakeMaster.Supervisor,
      {EtherCAT, [hardware_config: config]}
    ])
  end

  def connect(%{node: node}, slave_from, slave_to) do
    from_pdos =
      node
      |> :erpc.call(EtherCAT, :get_pdos, [slave_from])
      |> Map.keys()
      |> Enum.map(fn {pdo, entry} -> {slave_from, pdo, entry} end)

    to_pdos =
      node
      |> :erpc.call(EtherCAT, :get_pdos, [slave_to])
      |> Map.keys()
      |> Enum.map(fn {pdo, entry} -> {slave_to, pdo, entry} end)

    connections =
      Enum.zip(from_pdos, to_pdos)
      |> Map.new()

    {:ok, _} =
      :erpc.call(node, DynamicSupervisor, :start_child, [
        FakeMaster.Supervisor,
        {Support.HardwareConnection, connections}
      ])
  end

  def read(%{node: node}, slave, pdo_name, entry_name) do
    :erpc.call(node, GenServer, :call, [slave, {:read_pdo_entry, pdo_name, entry_name}])
  end

  def write(%{node: node}, slave, pdo_name, entry_name, value) do
    :erpc.call(node, GenServer, :call, [slave, {:write_pdo_entry, pdo_name, entry_name, value}])
  end

  def stop(%{pid: pid}) do
    if Process.alive?(pid) do
      :peer.stop(pid)
    else
      :ok
    end
  end

  @doc false
  def do_create_supervisor() do
    {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one, name: FakeMaster.Supervisor)
    Process.unlink(sup)
    {:ok, sup}
  end
end
