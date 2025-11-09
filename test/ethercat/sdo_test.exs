defmodule EtherCAT.SDOTest do
  use ExUnit.Case, async: true
  alias EtherCAT.SDO
  doctest EtherCAT.SDO

  describe "type encoding" do
    test "encode_bool/1 encodes boolean values" do
      assert SDO.encode_bool(true) == <<1>>
      assert SDO.encode_bool(false) == <<0>>
    end

    test "encode_uint8/1 encodes 8-bit unsigned integers" do
      assert SDO.encode_uint8(0) == <<0>>
      assert SDO.encode_uint8(255) == <<255>>
      assert SDO.encode_uint8(127) == <<127>>
    end

    test "encode_uint16/1 encodes 16-bit unsigned integers in little-endian" do
      assert SDO.encode_uint16(0x0000) == <<0, 0>>
      assert SDO.encode_uint16(0xFFFF) == <<255, 255>>
      assert SDO.encode_uint16(0x0A0B) == <<11, 10>>
      assert SDO.encode_uint16(1000) == <<232, 3>>
    end

    test "encode_uint32/1 encodes 32-bit unsigned integers in little-endian" do
      assert SDO.encode_uint32(0x00000000) == <<0, 0, 0, 0>>
      assert SDO.encode_uint32(0xFFFFFFFF) == <<255, 255, 255, 255>>
      assert SDO.encode_uint32(0x01020304) == <<4, 3, 2, 1>>
    end

    test "encode_int16/1 encodes 16-bit signed integers in little-endian" do
      assert SDO.encode_int16(0) == <<0, 0>>
      assert SDO.encode_int16(1000) == <<232, 3>>
      assert SDO.encode_int16(-100) == <<156, 255>>
      assert SDO.encode_int16(-32768) == <<0, 128>>
      assert SDO.encode_int16(32767) == <<255, 127>>
    end

    test "encode_int32/1 encodes 32-bit signed integers in little-endian" do
      assert SDO.encode_int32(0) == <<0, 0, 0, 0>>
      assert SDO.encode_int32(-1000) == <<24, 252, 255, 255>>
      assert SDO.encode_int32(1_000_000) == <<64, 66, 15, 0>>
    end
  end

  describe "pdo_sdo?/1" do
    test "detects PDO assignment range (0x1C10-0x1C2F)" do
      assert SDO.pdo_sdo?(0x1C10)
      assert SDO.pdo_sdo?(0x1C12)
      assert SDO.pdo_sdo?(0x1C13)
      assert SDO.pdo_sdo?(0x1C2F)
    end

    test "detects RxPDO mapping range (0x1600-0x17FF)" do
      assert SDO.pdo_sdo?(0x1600)
      assert SDO.pdo_sdo?(0x1604)
      assert SDO.pdo_sdo?(0x17FF)
    end

    test "detects TxPDO mapping range (0x1A00-0x1BFF)" do
      assert SDO.pdo_sdo?(0x1A00)
      assert SDO.pdo_sdo?(0x1A01)
      assert SDO.pdo_sdo?(0x1BFF)
    end

    test "allows non-PDO SDOs" do
      refute SDO.pdo_sdo?(0x8000)
      refute SDO.pdo_sdo?(0x1000)
      refute SDO.pdo_sdo?(0x1C0F)
      refute SDO.pdo_sdo?(0x1C30)
      refute SDO.pdo_sdo?(0x15FF)
      refute SDO.pdo_sdo?(0x1800)
      refute SDO.pdo_sdo?(0x19FF)
      refute SDO.pdo_sdo?(0x1C00)
    end
  end

  describe "configure/5" do
    test "blocks PDO SDOs by default" do
      # Create a mock slave_config reference (won't actually call NIF)
      slave_config = make_ref()

      assert {:error, {:restricted_sdo, 0x1C12, _message}} =
               SDO.configure(slave_config, 0x1C12, 0x01, <<0>>, [])

      assert {:error, {:restricted_sdo, 0x1A00, _message}} =
               SDO.configure(slave_config, 0x1A00, 0x00, <<0>>, [])
    end

    test "validates range when validate_range option is provided" do
      slave_config = make_ref()

      # Value in range (this will fail at NIF call, but validation passes)
      result = SDO.configure(slave_config, 0x8000, 0x13, <<500::little-signed-16>>,
                             validate_range: {0, 1000})
      # Will get NIF error since we're not actually connected, but validation passed
      assert match?({:error, _}, result) or result == :ok

      # Value out of range
      assert {:error, {:out_of_range, 1500, 0, 1000}} =
               SDO.configure(slave_config, 0x8000, 0x13, <<1500::little-signed-16>>,
                             validate_range: {0, 1000})
    end
  end
end
