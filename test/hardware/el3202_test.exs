defmodule Hardware.EL3202Test do
  use ExUnit.Case, async: false
  require Logger

  @moduledoc """
  EL3202 RTD temperature input test.

  This test demonstrates SDO configuration and PDO reading for the
  Beckhoff EL3202 2-channel RTD (PT100/PT1000) temperature input terminal.

  ## Hardware Setup

  Expected configuration:
  - Slave 0: Bus coupler (e.g., EK1100)
  - Slave 1: Digital input (optional, e.g., EL1008)
  - Slave 2: Digital output (optional, e.g., EL2008)
  - Slave 3: EL3202 RTD temperature input (2 channels)

  Connect PT100 or PT1000 sensors to the EL3202 channels.

  ## Running

  To run this test with actual hardware:

      mix test test/hardware/el3202_test.exs --include hardware

  Or run in IEx for interactive testing:

      iex> Hardware.EL3202Test.run()
  """

  @tag :hardware
  @tag timeout: 30_000
  test "EL3202 temperature reading with limits" do
    {:ok, master, temp_values} = run()

    assert is_list(temp_values)
    assert length(temp_values) > 0

    EtherCAT.close(master)
  end

  @doc """
  Interactive test function for manual testing in IEx.

  Returns master_pid and temperature_values for continued monitoring.
  """
  def run do
    Logger.info("Starting EL3202 RTD Temperature Test...")

    {:ok, master, slaves} = EtherCAT.open(update_interval: 1000)
    Logger.info("Discovered #{length(slaves)} slaves")

    # Find EL3202 - typically at position 3, but flexible
    el3202 = Enum.at(slaves, 3) || List.last(slaves)

    if el3202 == nil do
      Logger.error("No slaves found. Check hardware setup.")
      {:error, :no_slaves_found}
    else
      config = %{
        ch1_limit1: 180,
        ch1_limit2: 280,
        ch1_enable_limit1: true,
        ch1_enable_limit2: true,
        ch1_enable_filter: true,
        ch1_filter_settings: 10,
        ch2_limit1: 0,
        ch2_limit2: 500,
        ch2_enable_limit1: true,
        ch2_enable_limit2: true,
        ch2_enable_filter: true,
        ch2_filter_settings: 10
      }

      Logger.info("Configuring EL3202 with temperature limits...")
      {:ok, available_pdos} = EtherCAT.configure_slave(el3202, config)
      Logger.info("Available PDOs: #{inspect(available_pdos)}")
      # Available PDOs will be [:ch1, :ch2] - each representing a complete channel

      pdos_to_register = [
        # Registers all 6 entries: underrange, overrange, limit1, limit2, error, value
        :ch1,
        # Registers all 6 entries: underrange, overrange, limit1, limit2, error, value
        :ch2
      ]

      Logger.info("Registering PDOs (each PDO contains all entries for one channel)...")
      {:ok, pdo_handles} = EtherCAT.register_pdos(master, el3202, pdos_to_register)

      Logger.info("Starting cyclic mode...")
      EtherCAT.start_cyclic(master)

      :timer.sleep(2000)

      Logger.info("Reading temperature values...")

      ch1_handle =
        Enum.find(pdo_handles, fn h ->
          String.contains?(h.unique_name, "ch1:value")
        end)

      ch2_handle =
        Enum.find(pdo_handles, fn h ->
          String.contains?(h.unique_name, "ch2:value")
        end)

      temp_values =
        if ch1_handle do
          case EtherCAT.read(ch1_handle) do
            {:ok, raw_value} ->
              temp_c = raw_value / 10.0
              Logger.info("Channel 1 Temperature: #{temp_c} C (raw: #{raw_value})")
              [{:ch1, temp_c, raw_value}]

            {:error, reason} ->
              Logger.warning("Failed to read channel 1: #{inspect(reason)}")
              []
          end
        else
          []
        end

      temp_values =
        if ch2_handle do
          case EtherCAT.read(ch2_handle) do
            {:ok, raw_value} ->
              temp_c = raw_value / 10.0
              Logger.info("Channel 2 Temperature: #{temp_c} C (raw: #{raw_value})")
              [{:ch2, temp_c, raw_value} | temp_values]

            {:error, reason} ->
              Logger.warning("Failed to read channel 2: #{inspect(reason)}")
              temp_values
          end
        else
          temp_values
        end

      Logger.info("Subscribing to temperature changes...")
      if ch1_handle, do: EtherCAT.watch(ch1_handle)
      if ch2_handle, do: EtherCAT.watch(ch2_handle)

      Logger.info("Monitoring temperature for 5 seconds...")
      monitor_temperature(5000)

      Logger.info("Test completed successfully!")
      {:ok, master, temp_values}
    end
  end

  defp monitor_temperature(duration) do
    start_time = System.monotonic_time(:millisecond)
    monitor_loop(start_time, duration)
  end

  defp monitor_loop(start_time, duration) do
    elapsed = System.monotonic_time(:millisecond) - start_time

    if elapsed < duration do
      receive do
        {:data_changed, name, value} ->
          temp_c = value / 10.0
          Logger.info("Temperature changed: #{name} = #{temp_c} C (raw: #{value})")
          monitor_loop(start_time, duration)
      after
        1000 ->
          monitor_loop(start_time, duration)
      end
    else
      :ok
    end
  end
end
