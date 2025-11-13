defmodule EtherCATConfigDslTest do
  use ExUnit.Case

  defmodule TestConfig do
    use EtherCAT.Config

    domain :fast_loop, interval: 1
    domain :slow_loop, interval: 10

    slave do
      position 0
      name :temp_sensor
      driver EtherCAT.Drivers.EL3202

      expect do
        vendor 0x00000002
        product 0x0C5A3052
      end

      config do
        limit1 1000
        limit2 2000
        filter :enabled
      end

      entry :ch1, :value, domain: :fast_loop
      entry :ch1, :error, domain: :slow_loop
      entry :ch2, :value, domain: :fast_loop
    end

    slave do
      position 1
      name :valve_outputs
      driver EtherCAT.Drivers.EL2008

      entry :ch1, :value, domain: :fast_loop
      entry :ch2, :value, domain: :fast_loop
    end
  end

  test "DSL compiles and builds configuration" do
    config = TestConfig.hardware_config()

    assert %EtherCAT.Config.HardwareConfig{} = config
    assert length(config.domains) == 2
    assert length(config.slaves) == 2
  end

  test "domains are configured correctly" do
    config = TestConfig.hardware_config()

    fast_loop = Enum.find(config.domains, &(&1.name == :fast_loop))
    assert fast_loop.interval == 1

    slow_loop = Enum.find(config.domains, &(&1.name == :slow_loop))
    assert slow_loop.interval == 10
  end

  test "slaves are configured correctly" do
    config = TestConfig.hardware_config()

    temp_sensor = Enum.find(config.slaves, &(&1.name == :temp_sensor))
    assert temp_sensor.position == 0
    assert temp_sensor.driver == EtherCAT.Drivers.EL3202
    assert temp_sensor.expected == %{vendor: 0x00000002, product: 0x0C5A3052}
    assert length(temp_sensor.entries) == 3

    valve_outputs = Enum.find(config.slaves, &(&1.name == :valve_outputs))
    assert valve_outputs.position == 1
    assert valve_outputs.driver == EtherCAT.Drivers.EL2008
    assert length(valve_outputs.entries) == 2
  end

  test "entries are configured correctly" do
    config = TestConfig.hardware_config()
    temp_sensor = Enum.find(config.slaves, &(&1.name == :temp_sensor))

    ch1_value = Enum.find(temp_sensor.entries, &(&1.pdo_name == :ch1 && &1.entry_name == :value))
    assert ch1_value.domain == :fast_loop

    ch1_error = Enum.find(temp_sensor.entries, &(&1.pdo_name == :ch1 && &1.entry_name == :error))
    assert ch1_error.domain == :slow_loop
  end

  test "config block is captured" do
    config = TestConfig.hardware_config()
    temp_sensor = Enum.find(config.slaves, &(&1.name == :temp_sensor))

    # Config should be a map with the specified fields
    assert is_map(temp_sensor.config)
    assert temp_sensor.config.limit1 == 1000
    assert temp_sensor.config.limit2 == 2000
    assert temp_sensor.config.filter == :enabled
  end
end
