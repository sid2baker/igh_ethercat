defmodule IODiagnosisTest do
  use ExUnit.Case
  require Logger

  @tag :ethercat
  test "EtherCAT I/O diagnosis" do
    Logger.info("=== EtherCAT I/O Diagnosis ===")

    {_m, i, o} = EtherCAT.test()
    :timer.sleep(2000)

    Logger.info("=== Domain State ===")
    {:ok, state} = EtherCAT.Domain.get_state(:default_domain)
    Logger.info("Domain State: #{inspect(state)}")
    Logger.info("Working Counter: #{state.working_counter} (should be 2 for input+output slaves)")

    Logger.info("\n=== PDO Offsets ===")
    {:ok, {in_offset, in_size}} = EtherCAT.Domain.get_entry(:default_domain, "pdo_6000:1")
    {:ok, {out_offset, out_size}} = EtherCAT.Domain.get_entry(:default_domain, "pdo_7000:1")

    Logger.info(
      "Input pdo_6000:1: offset=#{in_offset} bits (byte #{div(in_offset, 8)}), size=#{in_size}"
    )

    Logger.info(
      "Output pdo_7000:1: offset=#{out_offset} bits (byte #{div(out_offset, 8)}), size=#{out_size}"
    )

    Logger.info("\n=== I/O Loop Test ===")

    Logger.info("Setting output LOW...")
    EtherCAT.Slave.set_pdo_value(o, "pdo_7000:1", false)
    :timer.sleep(1000)
    out_val = EtherCAT.Slave.get_pdo_value(o, "pdo_7000:1")
    in_val = EtherCAT.Slave.get_pdo_value(i, "pdo_6000:1")
    Logger.info("  Output=#{out_val}, Input=#{in_val}")

    Logger.info("Setting output HIGH...")
    EtherCAT.Slave.set_pdo_value(o, "pdo_7000:1", true)
    :timer.sleep(1000)
    out_val = EtherCAT.Slave.get_pdo_value(o, "pdo_7000:1")
    in_val = EtherCAT.Slave.get_pdo_value(i, "pdo_6000:1")
    Logger.info("  Output=#{out_val}, Input=#{in_val}")

    Logger.info("Setting output LOW again...")
    EtherCAT.Slave.set_pdo_value(o, "pdo_7000:1", false)
    :timer.sleep(1000)
    out_val = EtherCAT.Slave.get_pdo_value(o, "pdo_7000:1")
    in_val = EtherCAT.Slave.get_pdo_value(i, "pdo_6000:1")
    Logger.info("  Output=#{out_val}, Input=#{in_val}")

    :timer.sleep(1000)
    Logger.info("\n=== Test Complete ===")
  end
end
