# Start ExUnit
ExUnit.start()

# Start EtherCAT Master for hardware tests
# Tests can access the master via Process.whereis(EtherCAT.Master)
if System.get_env("ETHERCAT_HARDWARE") == "true" do
  # Start Master directly for hardware tests with registered name
  {:ok, _master} = EtherCAT.Master.start_link(master_index: 0, name: EtherCAT.Master)

  # Give hardware time to initialize
  Process.sleep(100)
end
