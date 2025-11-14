defmodule Unit.DriverTest do
  use ExUnit.Case, async: true

  alias EtherCAT.Drivers.{EL1809, EL2809, EL3202}

  @moduledoc """
  Unit tests for EtherCAT driver modules.

  These tests verify driver behavior without requiring actual hardware:
  - PDO structure and configuration
  - Encoding/decoding of values
  - Driver metadata

  These tests can be run without hardware: mix test test/unit/driver_test.exs
  """

  describe "EL1809 Driver (16-channel digital input)" do
    setup do
      {:ok, driver_state: %{}}
    end

    test "lists all 16 channel PDOs", %{driver_state: state} do
      pdos = EL1809.list_pdos(state)
      assert length(pdos) == 16

      # Verify all channels present
      for i <- 1..16 do
        ch = String.to_atom("ch#{i}")
        assert ch in pdos, "Channel #{i} missing from PDO list"
      end
    end

    test "provides PDO info for channel 1", %{driver_state: state} do
      assert {:ok, pdo_info} = EL1809.pdo_info(state, :ch1)
      assert pdo_info.sync_manager == {0, :input, :default}
      assert pdo_info.pdo_index == 0x1A00
      assert pdo_info.entries.input == {0x6000, 0x01, 1}
    end

    test "provides PDO info for channel 8", %{driver_state: state} do
      assert {:ok, pdo_info} = EL1809.pdo_info(state, :ch8)
      assert pdo_info.sync_manager == {0, :input, :default}
      assert pdo_info.pdo_index == 0x1A07
      assert pdo_info.entries.input == {0x6070, 0x01, 1}
    end

    test "provides PDO info for channel 16", %{driver_state: state} do
      assert {:ok, pdo_info} = EL1809.pdo_info(state, :ch16)
      assert pdo_info.sync_manager == {0, :input, :default}
      assert pdo_info.pdo_index == 0x1A0F
      assert pdo_info.entries.input == {0x60F0, 0x01, 1}
    end

    test "returns error for unknown PDO", %{driver_state: state} do
      assert {:error, {:unknown_pdo, :nonexistent}} = EL1809.pdo_info(state, :nonexistent)
    end

    test "uses default boolean encoding/decoding", %{driver_state: state} do
      assert :default = EL1809.decode_value(state, :ch1, :input, <<1>>)
      assert :default = EL1809.encode_value(state, :ch1, :input, true)
    end

    test "does not support PDO configuration", %{driver_state: state} do
      refute EL1809.supports_pdo_config?(state)
    end
  end

  describe "EL2809 Driver (16-channel digital output)" do
    setup do
      {:ok, driver_state: %{}}
    end

    test "lists all 16 channel PDOs", %{driver_state: state} do
      pdos = EL2809.list_pdos(state)
      assert length(pdos) == 16

      # Verify all channels present
      for i <- 1..16 do
        ch = String.to_atom("ch#{i}")
        assert ch in pdos, "Channel #{i} missing from PDO list"
      end
    end

    test "provides PDO info for channel 1 (SM0)", %{driver_state: state} do
      assert {:ok, pdo_info} = EL2809.pdo_info(state, :ch1)
      assert pdo_info.sync_manager == {0, :output, :default}
      assert pdo_info.pdo_index == 0x1600
      assert pdo_info.entries.output == {0x7000, 0x01, 1}
    end

    test "provides PDO info for channel 8 (SM0)", %{driver_state: state} do
      assert {:ok, pdo_info} = EL2809.pdo_info(state, :ch8)
      assert pdo_info.sync_manager == {0, :output, :default}
      assert pdo_info.pdo_index == 0x1607
      assert pdo_info.entries.output == {0x7070, 0x01, 1}
    end

    test "provides PDO info for channel 9 (SM1)", %{driver_state: state} do
      assert {:ok, pdo_info} = EL2809.pdo_info(state, :ch9)
      assert pdo_info.sync_manager == {1, :output, :default}
      assert pdo_info.pdo_index == 0x1608
      assert pdo_info.entries.output == {0x7080, 0x01, 1}
    end

    test "provides PDO info for channel 16 (SM1)", %{driver_state: state} do
      assert {:ok, pdo_info} = EL2809.pdo_info(state, :ch16)
      assert pdo_info.sync_manager == {1, :output, :default}
      assert pdo_info.pdo_index == 0x160F
      assert pdo_info.entries.output == {0x70F0, 0x01, 1}
    end

    test "returns error for unknown PDO", %{driver_state: state} do
      assert {:error, {:unknown_pdo, :nonexistent}} = EL2809.pdo_info(state, :nonexistent)
    end

    test "uses default boolean encoding/decoding", %{driver_state: state} do
      assert :default = EL2809.decode_value(state, :ch1, :output, <<1>>)
      assert :default = EL2809.encode_value(state, :ch1, :output, true)
    end

    test "does not support PDO configuration", %{driver_state: state} do
      refute EL2809.supports_pdo_config?(state)
    end
  end

  describe "EL3202 Driver (2-channel RTD input)" do
    setup do
      {:ok, driver_state: %{ch1_rtd_element: 8, ch2_rtd_element: 8}}
    end

    test "lists 2 channel PDOs", %{driver_state: state} do
      pdos = EL3202.list_pdos(state)
      assert length(pdos) == 2
      assert :ch1 in pdos
      assert :ch2 in pdos
    end

    test "provides PDO info for channel 1", %{driver_state: state} do
      assert {:ok, pdo_info} = EL3202.pdo_info(state, :ch1)
      assert pdo_info.sync_manager == {3, :input, :default}
      assert pdo_info.pdo_index == 0x1A00

      # Check essential entries
      assert pdo_info.entries.value == {0x6000, 0x11, 16}
      assert pdo_info.entries.error == {0x6000, 0x07, 1}
      assert pdo_info.entries.underrange == {0x6000, 0x01, 1}
      assert pdo_info.entries.overrange == {0x6000, 0x02, 1}
    end

    test "provides PDO info for channel 2", %{driver_state: state} do
      assert {:ok, pdo_info} = EL3202.pdo_info(state, :ch2)
      assert pdo_info.sync_manager == {3, :input, :default}
      assert pdo_info.pdo_index == 0x1A01

      # Check essential entries
      assert pdo_info.entries.value == {0x6010, 0x11, 16}
      assert pdo_info.entries.error == {0x6010, 0x07, 1}
      assert pdo_info.entries.underrange == {0x6010, 0x01, 1}
      assert pdo_info.entries.overrange == {0x6010, 0x02, 1}
    end

    test "returns error for unknown PDO", %{driver_state: state} do
      assert {:error, {:unknown_pdo, :ch3}} = EL3202.pdo_info(state, :ch3)
    end

    test "decodes resistance value correctly (OHMS mode)", %{driver_state: state} do
      # 120.0Ω encoded as 1200 (units of 0.1Ω)
      raw_value = <<1200::little-signed-16>>
      assert {:ok, 120.0} = EL3202.decode_value(state, :ch1, :value, raw_value)

      # 100.0Ω encoded as 1000
      raw_value = <<1000::little-signed-16>>
      assert {:ok, 100.0} = EL3202.decode_value(state, :ch2, :value, raw_value)
    end

    test "decodes temperature value correctly (PT100 mode)" do
      # PT100 mode
      pt100_state = %{ch1_rtd_element: 0}

      # 20.0°C encoded as 200 (units of 0.1°C)
      raw_value = <<200::little-signed-16>>
      assert {:ok, 20.0} = EL3202.decode_value(pt100_state, :ch1, :value, raw_value)

      # -10.5°C encoded as -105
      raw_value = <<-105::little-signed-16>>
      assert {:ok, -10.5} = EL3202.decode_value(pt100_state, :ch1, :value, raw_value)
    end

    test "encodes resistance value correctly", %{driver_state: state} do
      # 120.0Ω should encode to 1200
      assert {:ok, <<1200::little-signed-16>>} = EL3202.encode_value(state, :ch1, :value, 120.0)

      # 100.0Ω should encode to 1000
      assert {:ok, <<1000::little-signed-16>>} = EL3202.encode_value(state, :ch2, :value, 100.0)
    end

    test "encodes temperature value correctly" do
      pt100_state = %{ch1_rtd_element: 0}

      # 20.0°C should encode to 200
      assert {:ok, <<200::little-signed-16>>} = EL3202.encode_value(pt100_state, :ch1, :value, 20.0)

      # -10.5°C should encode to -105
      assert {:ok, <<-105::little-signed-16>>} = EL3202.encode_value(pt100_state, :ch1, :value, -10.5)
    end

    test "uses default encoding for non-value entries", %{driver_state: state} do
      assert :default = EL3202.decode_value(state, :ch1, :error, <<0>>)
      assert :default = EL3202.encode_value(state, :ch1, :error, false)
    end

    test "does not support PDO configuration", %{driver_state: state} do
      refute EL3202.supports_pdo_config?(state)
    end
  end

  describe "EL3202 Driver RTD Element Types" do
    test "decodes with different RTD element types" do
      # PT100 (0)
      pt100_state = %{ch1_rtd_element: 0}
      assert {:ok, 25.0} = EL3202.decode_value(pt100_state, :ch1, :value, <<250::little-signed-16>>)

      # PT1000 (2)
      pt1000_state = %{ch1_rtd_element: 2}
      assert {:ok, 25.0} = EL3202.decode_value(pt1000_state, :ch1, :value, <<250::little-signed-16>>)

      # OHMS (8)
      ohms_state = %{ch1_rtd_element: 8}
      assert {:ok, 25.0} = EL3202.decode_value(ohms_state, :ch1, :value, <<250::little-signed-16>>)

      # Unknown element type (defaults to temperature behavior)
      unknown_state = %{ch1_rtd_element: 99}
      assert {:ok, 25.0} = EL3202.decode_value(unknown_state, :ch1, :value, <<250::little-signed-16>>)
    end
  end

  describe "EL3202 Driver Boundary Values" do
    setup do
      {:ok, driver_state: %{ch1_rtd_element: 8}}
    end

    test "decodes zero resistance", %{driver_state: state} do
      assert {:ok, 0.0} = EL3202.decode_value(state, :ch1, :value, <<0::little-signed-16>>)
    end

    test "decodes negative values", %{driver_state: state} do
      # For temperature sensors, negative values are valid
      assert {:ok, -10.0} = EL3202.decode_value(state, :ch1, :value, <<-100::little-signed-16>>)
    end

    test "decodes maximum positive value", %{driver_state: state} do
      # Maximum int16 value
      max_int16 = 32767
      expected = max_int16 / 10.0
      assert {:ok, ^expected} = EL3202.decode_value(state, :ch1, :value, <<max_int16::little-signed-16>>)
    end

    test "decodes minimum negative value", %{driver_state: state} do
      # Minimum int16 value
      min_int16 = -32768
      expected = min_int16 / 10.0
      assert {:ok, ^expected} = EL3202.decode_value(state, :ch1, :value, <<min_int16::little-signed-16>>)
    end
  end
end
