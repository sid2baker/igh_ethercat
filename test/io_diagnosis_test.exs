defmodule IODiagnosisTest do
  use ExUnit.Case
  require Logger

  @tag :ethercat
  test "EtherCAT I/O diagnosis" do
    Logger.info("=== EtherCAT I/O Diagnosis ===")

    # Use the new simplified API
    {:ok, master} = EtherCAT.start_link(update_interval: 1000)
    :ok = EtherCAT.connect(master)
    {:ok, [_coupler, i, o]} = EtherCAT.list_slaves(master)

    EtherCAT.configure_slave(i, [])
    EtherCAT.list_pdos(i) |> IO.inspect(label: "Input PDOs")

    EtherCAT.configure_slave(o, [])
    EtherCAT.list_pdos(o) |> IO.inspect(label: "Output PDOs")

    EtherCAT.register_all_pdos(i, :default_domain)
    EtherCAT.register_all_pdos(o, :default_domain)

    EtherCAT.start_cyclic(master)
    :timer.sleep(2000)

    # Note: Domain state and PDO offset inspection functions are not currently
    # exposed in the public API. These would require additional NIF bindings
    # to query domain state from the IgH master.
    #
    # For now, we can verify operation through I/O testing.

    Logger.info("\n=== I/O Loop Test ===")

    Logger.info("Setting output LOW...")
    EtherCAT.set_pdo(o, "pdo_7000:1", false)
    :timer.sleep(1000)
    {:ok, out_val} = EtherCAT.get_pdo(o, "pdo_7000:1")
    {:ok, in_val} = EtherCAT.get_pdo(i, "pdo_6000:1")
    Logger.info("  Output=#{inspect(out_val)}, Input=#{inspect(in_val)}")

    Logger.info("Setting output HIGH...")
    EtherCAT.set_pdo(o, "pdo_7000:1", true)
    :timer.sleep(1000)
    {:ok, out_val} = EtherCAT.get_pdo(o, "pdo_7000:1")
    {:ok, in_val} = EtherCAT.get_pdo(i, "pdo_6000:1")
    Logger.info("  Output=#{inspect(out_val)}, Input=#{inspect(in_val)}")

    Logger.info("Setting output LOW again...")
    EtherCAT.set_pdo(o, "pdo_7000:1", false)
    :timer.sleep(1000)
    {:ok, out_val} = EtherCAT.get_pdo(o, "pdo_7000:1")
    {:ok, in_val} = EtherCAT.get_pdo(i, "pdo_6000:1")
    Logger.info("  Output=#{inspect(out_val)}, Input=#{inspect(in_val)}")

    :timer.sleep(1000)
    Logger.info("\n=== Test Complete ===")
  end
end
