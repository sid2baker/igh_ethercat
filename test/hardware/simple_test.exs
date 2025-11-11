defmodule Hardware.SimpleTest do
  use ExUnit.Case, async: false
  require Logger

  test "basic output" do
    {:ok, master, slaves} = EtherCAT.open(update_interval: 1000)
    [coppler, di1, do1 | _rest] = slaves

    {:ok, [input1 | _rest]} = EtherCAT.configure_slave(di1, %{})
    {:ok, [output1, _, _, _, output5 | _rest]} = EtherCAT.configure_slave(do1, %{})

    {:ok, [i_pdo1]} = EtherCAT.register_pdos(di1, [input1])
    {:ok, [pdo1, _pdo5]} = EtherCAT.register_pdos(do1, [output1, output5])

    EtherCAT.start_cyclic(master)
    :timer.sleep(1000)

    assert {:ok, false} = EtherCAT.read(i_pdo1)

    EtherCAT.write(pdo1, true)

    :timer.sleep(1000)
    assert {:ok, true} = EtherCAT.read(i_pdo1)
  end
end
