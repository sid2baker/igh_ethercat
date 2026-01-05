defmodule EtherCAT.NifTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Master.Nif

  test "zig nif" do
    {:ok, master} = Nif.create_master(0)
    :ok = Nif.set_cyclic_interval(master, 100_000)
    {:ok, domain1} = Nif.create_domain(master, 1)
    {:ok, slave1} = Nif.create_slave(master, 0, 0, 0, 0)

    :ok = Nif.slave_config_sync_manager(slave1, 3, :output, :enabled)
    :ok = Nif.slave_config_pdo_assign_add(slave1, 3, 0)
    :ok = Nif.slave_config_pdo_mapping_add(slave1, 0, 0, 0, 8)
    {:ok, entry_id} = Nif.register_pdo_entry(slave1, domain1, 0, 0, 8, :output)

    Task.start(fn -> Nif.start_cyclic_task(master, [domain1]) end)

    :ok = Nif.write_pdo_value(domain1, entry_id, 55)
  end

  test "start_master/2" do
    {:ok, master} = Nif.start_master(0, self())
    {:ok, master} = Nif.start_master(1, self())
  end

  test "cyclic_task" do
    Nif.cyclic_task()
    |> IO.inspect()
  end
end
