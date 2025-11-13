defmodule EtherCAT.HardwareVerifier do
  @moduledoc """
  Verifies that discovered EtherCAT slaves match expected hardware configuration.

  This module compares the expected hardware layout (defined in a `HardwareLayout`)
  against the actual slaves discovered on the EtherCAT bus. It is used to ensure
  that the physical hardware matches expectations before proceeding with operation.

  ## Verification Strategies

  Currently supports `:exact` match strategy:
  - All expected slaves must be present
  - No extra slaves allowed
  - Position, vendor ID, and product code must match exactly

  Future strategies may include:
  - `:subset` - Allow extra slaves beyond expected ones
  - `:presence` - Ignore position, just verify slaves exist

  ## Usage

      # Define expected layout
      layout = %EtherCAT.HardwareLayout{
        slaves: [
          %EtherCAT.SlaveConfig{position: 0, vendor_id: 0xDEAD, product_code: 0x0001}
        ]
      }

      # Verify discovered slaves
      {:ok, master, slaves} = EtherCAT.open()
      case EtherCAT.HardwareVerifier.verify(layout, slaves, match: :exact) do
        :ok ->
          # Hardware matches, proceed
        {:error, mismatches} ->
          # Hardware doesn't match expectations
          IO.inspect(mismatches)
      end
  """

  alias EtherCAT.{HardwareLayout, SlaveConfig}

  @type mismatch ::
          {:missing_slave, map()}
          | {:extra_slave, map()}
          | {:wrong_vendor, map()}
          | {:wrong_product, map()}

  @type verification_result :: :ok | {:error, [mismatch()]}

  @doc """
  Verifies that discovered slaves match the expected hardware layout.

  ## Parameters

  - `expected` - A `%HardwareLayout{}` struct defining expected configuration
  - `actual_slaves` - List of slave PIDs discovered from `EtherCAT.open/1`
  - `opts` - Verification options:
    - `:match` - Match strategy (currently only `:exact` is supported)

  ## Returns

  - `:ok` - Hardware matches expectations
  - `{:error, mismatches}` - List of mismatches found

  ## Mismatch Types

  - `{:missing_slave, details}` - Expected slave not found
  - `{:extra_slave, details}` - Unexpected slave discovered
  - `{:wrong_vendor, details}` - Slave at position has wrong vendor ID
  - `{:wrong_product, details}` - Slave at position has wrong product code

  ## Examples

      # Exact match (default)
      verify(layout, slaves, match: :exact)

      # Future: subset match (allow extras)
      verify(layout, slaves, match: :subset)
  """
  @spec verify(HardwareLayout.t(), [pid()], keyword()) :: verification_result()
  def verify(%HardwareLayout{} = expected, actual_slaves, opts \\ []) do
    match_strategy = Keyword.get(opts, :match, :exact)

    case match_strategy do
      :exact -> verify_exact(expected, actual_slaves)
      other -> {:error, [{:unsupported_strategy, other}]}
    end
  end

  ## Private Functions

  @doc false
  @spec verify_exact(HardwareLayout.t(), [pid()]) :: verification_result()
  defp verify_exact(%HardwareLayout{slaves: expected_slaves}, actual_slave_pids) do
    # Get info from all actual slaves
    actual_slaves =
      Enum.map(actual_slave_pids, fn pid ->
        EtherCAT.Slave.get_info(pid)
      end)

    # Build position maps for easy lookup
    expected_by_pos = Map.new(expected_slaves, fn slave -> {slave.position, slave} end)
    actual_by_pos = Map.new(actual_slaves, fn slave -> {slave.position, slave} end)

    # Find mismatches
    mismatches =
      []
      |> find_missing_slaves(expected_by_pos, actual_by_pos)
      |> find_extra_slaves(expected_by_pos, actual_by_pos)
      |> find_identity_mismatches(expected_by_pos, actual_by_pos)

    case mismatches do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  @doc false
  defp find_missing_slaves(mismatches, expected_by_pos, actual_by_pos) do
    expected_by_pos
    |> Enum.reduce(mismatches, fn {position, expected}, acc ->
      if Map.has_key?(actual_by_pos, position) do
        acc
      else
        [
          {:missing_slave,
           %{
             position: position,
             expected_vendor: expected.vendor_id,
             expected_product: expected.product_code,
             expected_name: expected.name
           }}
          | acc
        ]
      end
    end)
  end

  @doc false
  defp find_extra_slaves(mismatches, expected_by_pos, actual_by_pos) do
    actual_by_pos
    |> Enum.reduce(mismatches, fn {position, actual}, acc ->
      if Map.has_key?(expected_by_pos, position) do
        acc
      else
        [
          {:extra_slave,
           %{
             position: position,
             actual_vendor: actual.vendor_id,
             actual_product: actual.product_code
           }}
          | acc
        ]
      end
    end)
  end

  @doc false
  defp find_identity_mismatches(mismatches, expected_by_pos, actual_by_pos) do
    expected_by_pos
    |> Enum.reduce(mismatches, fn {position, expected}, acc ->
      case Map.get(actual_by_pos, position) do
        nil ->
          # Already reported as missing
          acc

        actual ->
          acc
          |> check_vendor_mismatch(position, expected, actual)
          |> check_product_mismatch(position, expected, actual)
      end
    end)
  end

  @doc false
  defp check_vendor_mismatch(mismatches, position, expected, actual) do
    if expected.vendor_id != actual.vendor_id do
      [
        {:wrong_vendor,
         %{
           position: position,
           expected: expected.vendor_id,
           actual: actual.vendor_id,
           expected_name: expected.name
         }}
        | mismatches
      ]
    else
      mismatches
    end
  end

  @doc false
  defp check_product_mismatch(mismatches, position, expected, actual) do
    if expected.product_code != actual.product_code do
      [
        {:wrong_product,
         %{
           position: position,
           expected: expected.product_code,
           actual: actual.product_code,
           expected_name: expected.name
         }}
        | mismatches
      ]
    else
      mismatches
    end
  end
end
