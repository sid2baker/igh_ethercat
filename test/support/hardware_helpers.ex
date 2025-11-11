defmodule HardwareHelpers do
  @moduledoc """
  Shared helper functions for hardware tests.

  Provides common utilities for loopback testing, notification handling,
  and slave selection to reduce duplication across test files.
  """

  require Logger

  @doc """
  Asserts loopback behavior: write to output, verify on input.

  ## Parameters
  - `input_pdo` - Input PDO handle
  - `output_pdo` - Output PDO handle
  - `expected_value` - Value to write and expect
  - `opts` - Options (stabilization_delay: ms, default: 500)
  """
  def assert_loopback(input_pdo, output_pdo, expected_value, opts \\ []) do
    import ExUnit.Assertions

    stabilization_delay = Keyword.get(opts, :stabilization_delay, 500)

    assert :ok = EtherCAT.write(output_pdo, expected_value)
    :timer.sleep(stabilization_delay)

    assert {:ok, actual_value} = EtherCAT.read(input_pdo)

    assert actual_value == expected_value,
           "Loopback failed: expected #{inspect(expected_value)}, got #{inspect(actual_value)}"

    output_name = format_pdo_name(output_pdo)
    input_name = format_pdo_name(input_pdo)

    Logger.debug("Loopback OK: #{output_name} -> #{input_name} = #{inspect(expected_value)}")

    :ok
  end

  # Helper to format PDOEntry for logging
  defp format_pdo_name(%{pdo_name: pdo_name, entry_name: entry_name}) do
    "#{pdo_name}:#{entry_name}"
  end

  @doc """
  Flushes all messages from the process mailbox.
  """
  def flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  @doc """
  Collects notifications from mailbox with timeout.

  Returns list of `{name, value}` tuples for all `:data_changed` messages.
  """
  def collect_notifications(timeout \\ 2000, collected \\ []) do
    receive do
      {:data_changed, name, value} ->
        collect_notifications(timeout, [{name, value} | collected])
    after
      timeout -> Enum.reverse(collected)
    end
  end

  @doc """
  Counts available notifications in mailbox without blocking.
  """
  def count_notifications do
    count_notifications(0)
  end

  defp count_notifications(count) do
    receive do
      {:data_changed, _, _} -> count_notifications(count + 1)
    after
      0 -> count
    end
  end

  @doc """
  Selects slaves by skipping the coupler (first slave).

  Returns `{input_slave, output_slave}` for typical DI/DO setup.
  Raises if insufficient slaves found.

  ## Options
  - `:skip_coupler` - Whether to skip first slave (default: true)
  - `:min_slaves` - Minimum required slaves after skipping
  """
  def select_io_slaves(slaves, opts \\ []) do
    skip_coupler = Keyword.get(opts, :skip_coupler, true)
    min_required = Keyword.get(opts, :min_slaves, 2)

    actual_slaves = if skip_coupler and length(slaves) >= 3, do: tl(slaves), else: slaves

    if length(actual_slaves) < min_required do
      raise "Expected at least #{min_required} slaves, got #{length(actual_slaves)}"
    end

    case actual_slaves do
      [input, output | _] -> {input, output}
      _ -> raise "Could not select input/output slaves from #{inspect(actual_slaves)}"
    end
  end

  @doc """
  Finds slave at position or returns last slave as fallback.

  Useful for finding specific device types (e.g., EL3202 at position 3).
  """
  def find_slave(slaves, position) do
    Enum.at(slaves, position) || List.last(slaves)
  end

  @doc """
  Waits for system stabilization after activation.

  Default: 500ms. Use longer delays for complex slave configurations.
  """
  def wait_stabilization(delay \\ 500) do
    :timer.sleep(delay)
  end

  @doc """
  Asserts notification received within timeout.

  Raises if notification not received or has wrong value.
  """
  def assert_notification(unique_name, expected_value, timeout \\ 2000) do
    import ExUnit.Assertions

    receive do
      {:data_changed, ^unique_name, ^expected_value} ->
        Logger.debug("✓ Notification: #{unique_name} = #{inspect(expected_value)}")
        :ok

      {:data_changed, ^unique_name, other_value} ->
        flunk("Wrong value: expected #{inspect(expected_value)}, got #{inspect(other_value)}")

      {:data_changed, other_name, _} ->
        flunk("Wrong PDO: expected #{unique_name}, got #{other_name}")

      other ->
        flunk("Unexpected message: #{inspect(other)}")
    after
      timeout ->
        flunk("Timeout waiting for notification: #{unique_name} = #{inspect(expected_value)}")
    end
  end
end
