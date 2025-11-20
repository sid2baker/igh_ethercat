defmodule Examples.SimpleIOTest do
  @moduledoc """
  Interactive testing module for simple digital I/O cards.

  This module provides an easy-to-use interface for manually testing
  EtherCAT digital I/O hardware (EL1809 inputs + EL2809 outputs).

  ## Physical Hardware Setup
  - Position 0: EK1100 EtherCAT Coupler
  - Position 1: EL1809 16-channel digital input (24V DC)
  - Position 2: EL2809 16-channel digital output (24V DC, 0.5A)

  ## Wiring
  For loopback testing, connect each output to its corresponding input:
  - Output Channel 1 → Input Channel 1
  - Output Channel 2 → Input Channel 2
  - ... etc through Channel 16

  ## Quick Start

      iex> Examples.SimpleIOTest.start()
      iex> Examples.SimpleIOTest.pattern_test()
      iex> Examples.SimpleIOTest.loopback_test()
      iex> Examples.SimpleIOTest.stop()

  ## Manual Control

      iex> Examples.SimpleIOTest.set_output(0, true)
      iex> Examples.SimpleIOTest.get_input(0)
      {:ok, true}

  ## Monitoring

      iex> Examples.SimpleIOTest.subscribe_input(0)
      iex> Examples.SimpleIOTest.set_output(0, false)
      iex> flush()
      {:pdo_value_changed, :default_domain, "digital_inputs:Input:Channel_1", <<0>>}
  """

  require Logger

  alias EtherCAT.Master

  # Master always registers as EtherCAT.Master (hardcoded in start_link)
  @master_name EtherCAT.Master

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start the EtherCAT master with simple I/O configuration.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec start() :: :ok | {:error, term()}
  def start do
    config = SimpleHardwareConfig.hardware_config()

    # Start master process (registers as EtherCAT.Master automatically)
    case Master.start_link(master_index: 0) do
      {:ok, _pid} ->
        Logger.info("Master started successfully")

        # Configure and activate
        case Master.configure_and_activate(@master_name, config) do
          {:ok, _slaves} ->
            Logger.info("Hardware configured and activated!")
            Logger.info("Ready for I/O operations")
            print_quick_start()
            :ok

          {:error, reason} = error ->
            Logger.error("Failed to configure hardware: #{inspect(reason)}")
            GenServer.stop(@master_name)
            error
        end

      {:error, {:already_started, _pid}} ->
        Logger.warning("Master already running")
        :ok

      {:error, reason} = error ->
        Logger.error("Failed to start master: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Stop the EtherCAT master.
  """
  @spec stop() :: :ok
  def stop do
    case Process.whereis(@master_name) do
      nil ->
        Logger.info("Master not running")
        :ok

      _pid ->
        GenServer.stop(@master_name)
        Logger.info("Master stopped")
        :ok
    end
  end

  @doc """
  Set a single output channel.

  ## Parameters
  - `channel`: Output channel number (0-15)
  - `value`: Boolean value (true = on, false = off)

  ## Examples
      Examples.SimpleIOTest.set_output(0, true)   # Turn on channel 0
      Examples.SimpleIOTest.set_output(5, false)  # Turn off channel 5
  """
  @spec set_output(0..15, boolean()) :: :ok | {:error, term()}
  def set_output(channel, value) when channel in 0..15 and is_boolean(value) do
    unique_name = "digital_outputs:channel_#{channel + 1}:output"
    binary_value = if value, do: <<1>>, else: <<0>>

    case Master.write_pdo_entry(@master_name, unique_name, binary_value) do
      :ok ->
        Logger.debug("Set output channel #{channel} to #{value}")
        :ok

      {:error, reason} = error ->
        Logger.error("Failed to set output: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Read a single input channel.

  ## Parameters
  - `channel`: Input channel number (0-15)

  ## Returns
  - `{:ok, boolean}` - The current state of the input
  - `{:error, reason}` - On failure

  ## Examples
      {:ok, state} = Examples.SimpleIOTest.get_input(0)
      IO.puts("Input 0 is \#{state}")
  """
  @spec get_input(0..15) :: {:ok, boolean()} | {:error, term()}
  def get_input(channel) when channel in 0..15 do
    unique_name = "digital_inputs:channel_#{channel + 1}:input"

    case Master.read_pdo_entry(@master_name, unique_name) do
      {:ok, <<value>>} ->
        {:ok, value == 1}

      {:error, reason} = error ->
        Logger.error("Failed to read input: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Set all outputs at once.

  ## Parameters
  - `states`: List of 16 boolean values, one per channel

  ## Examples
      # Turn on first 8, turn off last 8
      Examples.SimpleIOTest.set_all_outputs(
        List.duplicate(true, 8) ++ List.duplicate(false, 8)
      )
  """
  @spec set_all_outputs([boolean()]) :: :ok
  def set_all_outputs(states) when is_list(states) and length(states) == 16 do
    states
    |> Enum.with_index()
    |> Enum.each(fn {state, channel} ->
      set_output(channel, state)
    end)

    :ok
  end

  @doc """
  Read all inputs at once.

  ## Returns
  - `{:ok, [boolean]}` - List of 16 input states
  - `{:error, reason}` - On failure
  """
  @spec get_all_inputs() :: {:ok, [boolean()]} | {:error, term()}
  def get_all_inputs do
    results =
      0..15
      |> Enum.map(&get_input/1)
      |> Enum.reduce_while({:ok, []}, fn
        {:ok, state}, {:ok, acc} -> {:cont, {:ok, [state | acc]}}
        error, _acc -> {:halt, error}
      end)

    case results do
      {:ok, states} -> {:ok, Enum.reverse(states)}
      error -> error
    end
  end

  @doc """
  Toggle all outputs (flip their current state).

  This is useful for testing connectivity - if outputs are properly wired to inputs,
  the inputs should change state after calling this function.
  """
  @spec toggle_all() :: :ok
  def toggle_all do
    Logger.info("Toggling all outputs...")

    0..15
    |> Enum.each(fn channel ->
      case get_input(channel) do
        {:ok, current_state} ->
          set_output(channel, not current_state)

        {:error, reason} ->
          Logger.warning("Could not read channel #{channel}: #{inspect(reason)}")
      end
    end)

    :ok
  end

  @doc """
  Run a pattern test that cycles through all channels.

  This sequentially turns on each output one at a time, waits 200ms,
  then moves to the next. Useful for visual verification of wiring.

  ## Parameters
  - `cycles`: Number of complete cycles to run (default: 1)
  """
  @spec pattern_test(pos_integer()) :: :ok
  def pattern_test(cycles \\ 1) do
    Logger.info("Running pattern test for #{cycles} cycle(s)...")

    Enum.each(1..cycles, fn cycle ->
      Logger.info("Cycle #{cycle}/#{cycles}")

      Enum.each(0..15, fn channel ->
        # Turn on current channel, turn off all others
        states = Enum.map(0..15, fn ch -> ch == channel end)
        set_all_outputs(states)

        # Check if input matches (for wired setups)
        Process.sleep(200)

        case get_input(channel) do
          {:ok, true} ->
            Logger.info("✓ Channel #{channel}: Output ON → Input HIGH")

          {:ok, false} ->
            Logger.warning("✗ Channel #{channel}: Output ON but Input LOW (check wiring?)")

          {:error, reason} ->
            Logger.error("✗ Channel #{channel}: Could not read input - #{inspect(reason)}")
        end
      end)

      # Clear all outputs at end of cycle
      set_all_outputs(List.duplicate(false, 16))
      Process.sleep(500)
    end)

    Logger.info("Pattern test complete!")
    :ok
  end

  @doc """
  Run a loopback verification test.

  Tests that each output channel correctly drives its corresponding input channel.
  This assumes outputs are wired to inputs (Output 0 → Input 0, etc.).

  ## Returns
  - `{:ok, results}` - Map of channel results (%{channel => :pass | {:fail, reason}})
  - `{:error, reason}` - On failure
  """
  @spec loopback_test() :: {:ok, map()} | {:error, term()}
  def loopback_test do
    Logger.info("Running loopback test...")

    # First, set all outputs to 0
    set_all_outputs(List.duplicate(false, 16))
    Process.sleep(100)

    results =
      Enum.map(0..15, fn channel ->
        # Test LOW → LOW
        set_output(channel, false)
        Process.sleep(50)

        low_result =
          case get_input(channel) do
            {:ok, false} -> :pass
            {:ok, true} -> {:fail, :stuck_high}
            {:error, reason} -> {:error, reason}
          end

        # Test HIGH → HIGH
        set_output(channel, true)
        Process.sleep(50)

        high_result =
          case get_input(channel) do
            {:ok, true} -> :pass
            {:ok, false} -> {:fail, :stuck_low}
            {:error, reason} -> {:error, reason}
          end

        # Clear output
        set_output(channel, false)

        result =
          case {low_result, high_result} do
            {:pass, :pass} -> :pass
            {low, high} -> {:fail, {low, high}}
          end

        {channel, result}
      end)
      |> Map.new()

    # Print summary
    passed = Enum.count(results, fn {_ch, result} -> result == :pass end)
    failed = 16 - passed

    Logger.info("Loopback test complete: #{passed}/16 passed, #{failed}/16 failed")

    if failed > 0 do
      Logger.warning("Failed channels:")

      Enum.each(results, fn
        {channel, {:fail, reason}} ->
          Logger.warning("  Channel #{channel}: #{inspect(reason)}")

        {channel, {:error, reason}} ->
          Logger.error("  Channel #{channel}: #{inspect(reason)}")

        _ ->
          :ok
      end)
    end

    {:ok, results}
  end

  @doc """
  Subscribe to changes on a specific input channel.

  The calling process will receive messages of the form:
  `{:pdo_value_changed, domain_name, unique_name, value}`

  ## Parameters
  - `channel`: Input channel number (0-15)
  - `pid`: Process to receive notifications (default: self())

  ## Examples
      # In IEx
      Examples.SimpleIOTest.subscribe_input(0)
      # Now toggle output 0 and watch for messages
      Examples.SimpleIOTest.set_output(0, true)
      flush()  # Should show {:pdo_value_changed, ...}
  """
  @spec subscribe_input(0..15, pid()) :: :ok | {:error, term()}
  def subscribe_input(channel, pid \\ self()) when channel in 0..15 do
    entry_name = "digital_inputs:Input:Channel_#{channel + 1}"

    case Master.subscribe(@master_name, :default_domain, entry_name, pid) do
      :ok ->
        Logger.info("Subscribed to input channel #{channel}")
        :ok

      error ->
        Logger.error("Failed to subscribe: #{inspect(error)}")
        error
    end
  end

  @doc """
  Unsubscribe from input channel changes.

  ## Parameters
  - `channel`: Input channel number (0-15)
  - `pid`: Process to unsubscribe (default: self())
  """
  @spec unsubscribe_input(0..15, pid()) :: :ok | {:error, term()}
  def unsubscribe_input(channel, pid \\ self()) when channel in 0..15 do
    entry_name = "digital_inputs:Input:Channel_#{channel + 1}"

    case Master.unsubscribe(@master_name, :default_domain, entry_name, pid) do
      :ok ->
        Logger.info("Unsubscribed from input channel #{channel}")
        :ok

      error ->
        Logger.error("Failed to unsubscribe: #{inspect(error)}")
        error
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp print_quick_start do
    IO.puts("""

    ========================================
    Simple I/O Test Ready!
    ========================================

    Try these commands:
      Examples.SimpleIOTest.pattern_test()       # Visual test
      Examples.SimpleIOTest.loopback_test()      # Verify wiring
      Examples.SimpleIOTest.set_output(0, true)  # Manual control
      Examples.SimpleIOTest.get_input(0)         # Read input

    Type: h Examples.SimpleIOTest
    ========================================
    """)
  end
end
