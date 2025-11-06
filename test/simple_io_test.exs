require Logger

Logger.info("Starting simple I/O test...")
{m, i, o} = EtherCAT.test()

Logger.info("Waiting for slaves to be ready...")
:timer.sleep(2000)

Logger.info("Setting output HIGH...")
result = EtherCAT.Slave.set_pdo_value(o, "pdo_7000:1", true)
Logger.info("Set result: #{inspect(result)}")

:timer.sleep(2000)

Logger.info("Reading input...")
input_val = EtherCAT.Slave.get_pdo_value(i, "pdo_6000:1")
Logger.info("Input value: #{inspect(input_val)}")

Logger.info("Setting output LOW...")
EtherCAT.Slave.set_pdo_value(o, "pdo_7000:1", false)

:timer.sleep(2000)

Logger.info("Reading input again...")
input_val2 = EtherCAT.Slave.get_pdo_value(i, "pdo_6000:1")
Logger.info("Input value: #{inspect(input_val2)}")

Logger.info("Test complete!")
