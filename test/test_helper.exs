# Start ExUnit
ExUnit.start()

# Start EtherCAT Master for tests
# Tests can access the master via Process.whereis(EtherCAT.Master)
{:ok, _master} = EtherCAT.Master.start_link(master_index: 0, name: EtherCAT.Master)

# Give hardware time to initialize
Process.sleep(100)
