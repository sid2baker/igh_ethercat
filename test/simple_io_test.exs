defmodule SimpleIOTest do
  use ExUnit.Case
  require Logger

  @tag :ethercat
  test "simple I/O test" do
    Logger.info("Starting simple I/O test...")

    # Use the new simplified API
    {:ok, master} = EtherCAT.start_link(update_interval: 1000)
    :ok = EtherCAT.connect(master)
    {:ok, [_coupler, i, o]} = EtherCAT.list_slaves(master)

    EtherCAT.configure_slave(i, [])
    EtherCAT.configure_slave(o, [])
    EtherCAT.register_all_pdos(i, :default_domain)
    EtherCAT.register_all_pdos(o, :default_domain)
    EtherCAT.start_cyclic(master)

    Logger.info("Waiting for slaves to be ready...")
    :timer.sleep(2000)

    Logger.info("Setting output HIGH...")
    result = EtherCAT.set_pdo(o, "pdo_7000:1", true)
    Logger.info("Set result: #{inspect(result)}")

    :timer.sleep(2000)

    Logger.info("Reading input...")
    input_val = EtherCAT.get_pdo(i, "pdo_6000:1")
    Logger.info("Input value: #{inspect(input_val)}")

    Logger.info("Setting output LOW...")
    EtherCAT.set_pdo(o, "pdo_7000:1", false)

    :timer.sleep(2000)

    Logger.info("Reading input again...")
    input_val2 = EtherCAT.get_pdo(i, "pdo_6000:1")
    Logger.info("Input value: #{inspect(input_val2)}")

    Logger.info("Test complete!")
  end
end
