defmodule EtherCATDriverTest do
  use ExUnit.Case, async: true

  alias EtherCAT.Drivers.{EL1809, EL2809, EL3202}

  describe "EL1809 Driver" do
    test "lists correct PDOs" do
      driver_state = %{}
      assert EL1809.list_pdos(driver_state) == [:inputs]
    end

    test "provides PDO info for inputs" do
      driver_state = %{}
      assert {:ok, pdo_info} = EL1809.pdo_info(driver_state, :inputs)
      assert pdo_info.sync_manager == {3, :input, :default}
      assert pdo_info.pdo_index == 0x1A00
      assert map_size(pdo_info.entries) == 16

      # Check a few specific channels
      assert pdo_info.entries.ch1 == {0x6000, 0x01, 1}
      assert pdo_info.entries.ch8 == {0x6000, 0x08, 1}
      assert pdo_info.entries.ch16 == {0x6000, 0x10, 1}
    end

    test "returns error for unknown PDO" do
      driver_state = %{}
      assert {:error, {:unknown_pdo, :nonexistent}} = EL1809.pdo_info(driver_state, :nonexistent)
    end
  end

  describe "EL2809 Driver" do
    test "lists correct PDOs" do
      driver_state = %{}
      assert EL2809.list_pdos(driver_state) == [:outputs]
    end

    test "provides PDO info for outputs" do
      driver_state = %{}
      assert {:ok, pdo_info} = EL2809.pdo_info(driver_state, :outputs)
      assert pdo_info.sync_manager == {2, :output, :default}
      assert pdo_info.pdo_index == 0x1600
      assert map_size(pdo_info.entries) == 16

      # Check a few specific channels
      assert pdo_info.entries.ch1 == {0x7000, 0x01, 1}
      assert pdo_info.entries.ch8 == {0x7000, 0x08, 1}
      assert pdo_info.entries.ch16 == {0x7000, 0x10, 1}
    end

    test "returns error for unknown PDO" do
      driver_state = %{}
      assert {:error, {:unknown_pdo, :nonexistent}} = EL2809.pdo_info(driver_state, :nonexistent)
    end
  end

  describe "EL3202 Driver" do
    test "lists correct PDOs" do
      driver_state = %{}
      assert EL3202.list_pdos(driver_state) == [:ch1, :ch2]
    end

    test "provides PDO info for channel 1" do
      driver_state = %{}
      assert {:ok, pdo_info} = EL3202.pdo_info(driver_state, :ch1)
      assert pdo_info.sync_manager == {3, :input, :default}
      assert pdo_info.pdo_index == 0x1A00

      # Check essential entries
      assert pdo_info.entries.value == {0x6000, 0x11, 16}
      assert pdo_info.entries.error == {0x6000, 0x07, 1}
    end

    test "provides PDO info for channel 2" do
      driver_state = %{}
      assert {:ok, pdo_info} = EL3202.pdo_info(driver_state, :ch2)
      assert pdo_info.sync_manager == {3, :input, :default}
      assert pdo_info.pdo_index == 0x1A01

      # Check essential entries
      assert pdo_info.entries.value == {0x6010, 0x11, 16}
      assert pdo_info.entries.error == {0x6010, 0x07, 1}
    end

    test "decodes temperature value correctly" do
      # PT100
      driver_state = %{ch1_rtd_element: 0}
      # 20.0°C
      raw_value = <<200::little-signed-16>>

      assert {:ok, 20.0} = EL3202.decode_value(driver_state, :ch1, :value, raw_value)
    end

    test "encodes temperature value correctly" do
      driver_state = %{}

      assert {:ok, <<250::little-signed-16>>} =
               EL3202.encode_value(driver_state, :ch1, :value, 25.0)
    end
  end
end
