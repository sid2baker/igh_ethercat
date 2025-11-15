defmodule EtherCAT.HardwareLayout do
  @moduledoc """
  Defines the expected layout of EtherCAT slaves on the bus.

  This module provides a data structure and utilities for defining the expected
  hardware configuration of an EtherCAT network. It enables:

  - **Hardware verification**: Ensure physical hardware matches expectations
  - **Self-documentation**: Explicit declaration of required slaves
  - **Safety**: Fail fast if wrong hardware is connected
  - **Testing**: Generate fake slaves matching the expected layout

  ## Usage

  ### Manual Definition

      layout = %EtherCAT.HardwareLayout{
        slaves: [
          %EtherCAT.Config.SlaveConfig{
            position: 0,
            expected: %{vendor: 0xDEAD, product: 0x0001},
            name: :simple_io
          },
          %EtherCAT.Config.SlaveConfig{
            position: 1,
            expected: %{vendor: 0x00000002, product: 0x0C1E3052},
            name: :temp_sensor
          }
        ]
      }

      # Use with verification
      {:ok, master, slaves} = EtherCAT.open(expected: layout, match: :exact)

  ### Discovery and Generation

      # Discover hardware without expectations
      {:ok, master, slaves} = EtherCAT.open()

      # Generate layout from discovered slaves
      layout = EtherCAT.HardwareLayout.from_slaves(slaves)

      # Inspect and save for future use
      IO.inspect(layout)

  ## Future Enhancements

  In future versions, a DSL macro will be provided for more convenient syntax:

      defmodule MyApp.ProductionLayout do
        use EtherCAT.HardwareConfig

        slave 0, vendor: 0xDEAD, product: 0x0001, name: :simple_io
        slave 1, vendor: 0x00000002, product: 0x0C1E3052, name: :temp_sensor
      end
  """

  alias EtherCAT.Config.SlaveConfig

  @type t :: %__MODULE__{
          slaves: [SlaveConfig.t()]
        }

  @type mismatch ::
          {:missing_slave, map()}
          | {:extra_slave, map()}
          | {:wrong_vendor, map()}
          | {:wrong_product, map()}

  @type verification_result :: :ok | {:error, [mismatch()]}

  defstruct slaves: []

  @doc """
  Generates a hardware layout from currently discovered slaves.

  This function creates a `HardwareLayout` struct by extracting the identity
  information (position, vendor ID, product code) from discovered slave processes.

  ## Parameters

  - `slaves` - List of slave PIDs returned from `EtherCAT.open/1`
  - `opts` - Options (currently unused, reserved for future extensions)

  ## Returns

  A `%EtherCAT.HardwareLayout{}` struct containing the slave configurations.

  ## Example

      {:ok, master, slaves} = EtherCAT.open()
      layout = EtherCAT.HardwareLayout.from_slaves(slaves)

      # Returns something like:
      # %EtherCAT.HardwareLayout{
      #   slaves: [
      #     %EtherCAT.Config.SlaveConfig{position: 0, expected: %{vendor: 0x00000002, ...}, ...},
      #     %EtherCAT.Config.SlaveConfig{position: 1, expected: %{vendor: 0xDEAD, ...}, ...}
      #   ]
      # }
  """
  @spec from_slaves([pid()], keyword()) :: t()
  def from_slaves(slaves, _opts \\ []) do
    slave_configs =
      slaves
      |> Enum.map(fn slave_pid ->
        # Get slave info from the process
        # The Slave GenStatem stores this in its data
        try do
          info = EtherCAT.Slave.get_info(slave_pid)

          %SlaveConfig{
            position: info.position,
            name: info.name,
            driver: nil,
            expected: %{
              vendor: info.vendor_id,
              product: info.product_code
            },
            config: %{},
            entries: [],
            alias: info.alias
          }
        catch
          :exit, reason ->
            # Slave process died or couldn't be reached
            raise "Failed to get info from slave #{inspect(slave_pid)}: #{inspect(reason)}"
        end
      end)

    %__MODULE__{slaves: slave_configs}
  end

  @doc """
  Verifies that discovered slaves match this hardware layout.

  This function compares the expected hardware layout (this struct) against
  the actual slaves discovered on the EtherCAT bus. It is used to ensure that
  the physical hardware matches expectations before proceeding with operation.

  ## Verification Strategies

  Currently supports `:exact` match strategy:
  - All expected slaves must be present
  - No extra slaves allowed
  - Position, vendor ID, and product code must match exactly

  Future strategies may include:
  - `:subset` - Allow extra slaves beyond expected ones
  - `:presence` - Ignore position, just verify slaves exist

  ## Parameters

  - `layout` - This `%HardwareLayout{}` struct defining expected configuration
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

      # Define expected layout
      layout = %EtherCAT.HardwareLayout{
        slaves: [
          %EtherCAT.Config.SlaveConfig{
            position: 0,
            expected: %{vendor: 0xDEAD, product: 0x0001}
          }
        ]
      }

      # Verify discovered slaves
      {:ok, master, slaves} = EtherCAT.open()
      case EtherCAT.HardwareLayout.verify(layout, slaves, match: :exact) do
        :ok ->
          # Hardware matches, proceed
        {:error, mismatches} ->
          # Hardware doesn't match expectations
          IO.inspect(mismatches)
      end
  """
  @spec verify(t(), [pid()], keyword()) :: verification_result()
  def verify(%__MODULE__{} = layout, actual_slaves, opts \\ []) do
    match_strategy = Keyword.get(opts, :match, :exact)

    case match_strategy do
      :exact -> verify_exact(layout, actual_slaves)
      other -> {:error, [{:unsupported_strategy, other}]}
    end
  end

  ## Private Verification Functions

  @doc false
  @spec verify_exact(t(), [pid()]) :: verification_result()
  defp verify_exact(%__MODULE__{slaves: expected_slaves}, actual_slave_pids) do
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
             expected_vendor: expected.expected.vendor,
             expected_product: expected.expected.product,
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
    if expected.expected.vendor != actual.vendor_id do
      [
        {:wrong_vendor,
         %{
           position: position,
           expected: expected.expected.vendor,
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
    if expected.expected.product != actual.product_code do
      [
        {:wrong_product,
         %{
           position: position,
           expected: expected.expected.product,
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
