defmodule EtherCAT.TestHelpers do
  @moduledoc """
  Test helpers for EtherCAT testing.

  Provides utilities for:
  - Finding slaves by vendor/product ID
  - Hardware layout verification
  - Common test patterns
  - Fixture data
  """

  alias EtherCAT.{HardwareLayout, SlaveConfig}

  @doc """
  Finds a slave by vendor ID and product code.

  ## Parameters

  - `slaves` - List of slave PIDs from `EtherCAT.open/1`
  - `vendor_id` - Vendor identification (e.g., 0xDEAD)
  - `product_code` - Product code (e.g., 0x0001)

  ## Returns

  - Slave PID if found
  - `nil` if not found

  ## Example

      {:ok, master, slaves} = EtherCAT.open()
      slave = TestHelpers.find_slave(slaves, 0x00000002, 0x0C1E3052)
  """
  @spec find_slave([pid()], non_neg_integer(), non_neg_integer()) :: pid() | nil
  def find_slave(slaves, vendor_id, product_code) do
    Enum.find(slaves, fn slave_pid ->
      info = EtherCAT.Slave.get_info(slave_pid)
      info.vendor_id == vendor_id && info.product_code == product_code
    end)
  end

  @doc """
  Finds all slaves matching a vendor ID.

  Useful when you have multiple devices from the same vendor.

  ## Example

      beckhoff_slaves = TestHelpers.find_slaves_by_vendor(slaves, 0x00000002)
  """
  @spec find_slaves_by_vendor([pid()], non_neg_integer()) :: [pid()]
  def find_slaves_by_vendor(slaves, vendor_id) do
    Enum.filter(slaves, fn slave_pid ->
      info = EtherCAT.Slave.get_info(slave_pid)
      info.vendor_id == vendor_id
    end)
  end

  @doc """
  Asserts that hardware layout matches expected configuration.

  Convenience wrapper around hardware verification that fails tests
  with helpful messages if layout doesn't match.

  ## Example

      layout = %HardwareLayout{slaves: [...]}
      {:ok, master, slaves} = EtherCAT.open()
      assert_hardware_matches!(layout, slaves)
  """
  @spec assert_hardware_matches!(HardwareLayout.t(), [pid()]) :: :ok
  def assert_hardware_matches!(%HardwareLayout{} = expected, slaves) do
    case EtherCAT.HardwareVerifier.verify(expected, slaves, match: :exact) do
      :ok ->
        :ok

      {:error, mismatches} ->
        message = format_verification_errors(mismatches)
        raise ExUnit.AssertionError, message: message
    end
  end

  @doc """
  Creates a minimal test layout with N generic slaves.

  Useful for quickly setting up test fixtures.

  ## Example

      layout = TestHelpers.minimal_layout(2, vendor_id: 0xDEAD, product_code: 0x0001)
  """
  @spec minimal_layout(non_neg_integer(), keyword()) :: HardwareLayout.t()
  def minimal_layout(slave_count, opts \\ []) do
    vendor_id = Keyword.get(opts, :vendor_id, 0xFFFF)
    product_code = Keyword.get(opts, :product_code, 0x0001)

    slaves =
      0..(slave_count - 1)
      |> Enum.map(fn position ->
        %SlaveConfig{
          position: position,
          vendor_id: vendor_id,
          product_code: product_code,
          name: :"test_slave_#{position}",
          alias: 0
        }
      end)

    %HardwareLayout{slaves: slaves}
  end

  ## Private Helpers

  defp format_verification_errors(mismatches) do
    errors =
      Enum.map_join(mismatches, "\n", fn
        {:missing_slave, details} ->
          "  - Missing slave at position #{details.position}: " <>
            "expected 0x#{Integer.to_string(details.expected_vendor, 16)}:" <>
            "0x#{Integer.to_string(details.expected_product, 16)}"

        {:extra_slave, details} ->
          "  - Extra slave at position #{details.position}: " <>
            "found 0x#{Integer.to_string(details.actual_vendor, 16)}:" <>
            "0x#{Integer.to_string(details.actual_product, 16)}"

        {:wrong_vendor, details} ->
          "  - Wrong vendor at position #{details.position}: " <>
            "expected 0x#{Integer.to_string(details.expected, 16)}, " <>
            "got 0x#{Integer.to_string(details.actual, 16)}"

        {:wrong_product, details} ->
          "  - Wrong product at position #{details.position}: " <>
            "expected 0x#{Integer.to_string(details.expected, 16)}, " <>
            "got 0x#{Integer.to_string(details.actual, 16)}"
      end)

    "Hardware configuration mismatch:\n#{errors}"
  end
end
