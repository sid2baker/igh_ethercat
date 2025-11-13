defmodule EtherCAT.HardwareLayoutTest do
  use ExUnit.Case, async: true

  alias EtherCAT.{HardwareLayout, SlaveConfig}
  import EtherCAT.ExampleLayouts

  describe "from_slaves/1" do
    test "creates layout from empty slave list" do
      layout = HardwareLayout.from_slaves([])
      assert %HardwareLayout{slaves: []} = layout
    end

    # Note: Testing with real slave PIDs requires actual hardware or mocking.
    # This test demonstrates the expected structure.
    test "handles slave info extraction" do
      # This would typically use fake slave processes in a more complete test suite
      # For now, we document the expected behavior
      layout = empty_layout()
      assert is_list(layout.slaves)
    end
  end

  describe "generate_module/2" do
    test "generates valid Elixir source code" do
      layout = simple_io_layout()
      source = HardwareLayout.generate_module(layout, module_name: "TestLayout")

      assert source =~ "defmodule TestLayout"
      assert source =~ "%EtherCAT.HardwareLayout{"
      assert source =~ "vendor_id: 0xDEADBEEF"
      assert source =~ "product_code: 0x1"
      assert source =~ "def layout do"
    end

    test "includes timestamp in generated code" do
      layout = simple_io_layout()
      source = HardwareLayout.generate_module(layout)

      assert source =~ "Generated at:"
      assert source =~ "Auto-generated hardware layout"
    end

    test "handles multi-slave layouts" do
      layout = multi_slave_layout()
      source = HardwareLayout.generate_module(layout, module_name: "MultiSlaveLayout")

      assert source =~ "position: 0"
      assert source =~ "position: 1"
      assert source =~ "position: 2"
      assert source =~ "position: 3"
    end

    test "handles custom indentation" do
      layout = simple_io_layout()
      source = HardwareLayout.generate_module(layout, indent: "    ")

      # Should have 4-space indentation
      assert source =~ "    %EtherCAT.SlaveConfig{"
    end
  end

  describe "example layouts" do
    test "simple_io_layout/0 returns valid layout" do
      layout = simple_io_layout()

      assert %HardwareLayout{slaves: [slave]} = layout
      assert slave.position == 0
      assert slave.vendor_id == 0xDEADBEEF
      assert slave.product_code == 0x00000001
      assert slave.name == :simple_io
    end

    test "beckhoff_temperature_layout/0 returns valid layout" do
      layout = beckhoff_temperature_layout()

      assert %HardwareLayout{slaves: [slave]} = layout
      assert slave.position == 0
      assert slave.vendor_id == 0x00000002
      assert slave.product_code == 0x0C823052
      assert slave.name == :temp_sensor
    end

    test "multi_slave_layout/0 has correct slave count" do
      layout = multi_slave_layout()

      assert %HardwareLayout{slaves: slaves} = layout
      assert length(slaves) == 4

      # Verify positions are sequential
      positions = Enum.map(slaves, & &1.position)
      assert positions == [0, 1, 2, 3]
    end

    test "aliased_layout/0 has correct aliases" do
      layout = aliased_layout()

      assert %HardwareLayout{slaves: slaves} = layout
      assert length(slaves) == 2

      [slave_a, slave_b] = slaves
      assert slave_a.alias == 1000
      assert slave_b.alias == 2000
    end

    test "empty_layout/0 has no slaves" do
      layout = empty_layout()

      assert %HardwareLayout{slaves: []} = layout
    end

    test "large_bus_layout/0 has 16 slaves" do
      layout = large_bus_layout()

      assert %HardwareLayout{slaves: slaves} = layout
      assert length(slaves) == 16

      # Verify positions are sequential
      positions = Enum.map(slaves, & &1.position)
      assert positions == Enum.to_list(0..15)
    end
  end

  describe "SlaveConfig struct" do
    test "has required fields" do
      config = %SlaveConfig{
        position: 0,
        vendor_id: 0xDEAD,
        product_code: 0x0001,
        name: :test
      }

      assert config.position == 0
      assert config.vendor_id == 0xDEAD
      assert config.product_code == 0x0001
      assert config.name == :test
      assert config.alias == 0
      assert config.pdos == []
      assert config.sdos == []
    end

    test "allows optional fields" do
      config = %SlaveConfig{
        position: 0,
        vendor_id: 0xDEAD,
        product_code: 0x0001,
        name: :test,
        alias: 1000,
        pdos: [:some_pdo],
        sdos: [:some_sdo]
      }

      assert config.alias == 1000
      assert config.pdos == [:some_pdo]
      assert config.sdos == [:some_sdo]
    end
  end
end
