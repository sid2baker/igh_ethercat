defmodule HardwareCase do
  @moduledoc """
  Shared test case for hardware tests with common setup and utilities.

  ## Usage

      defmodule Hardware.MyTest do
        use HardwareCase

        # Hardware requirements declared as module attributes
        @required_slaves [:coupler, :digital_input, :digital_output]
        @loopback_required true

        test "my hardware test", %{master: master, slaves: slaves} do
          # Test implementation with auto-injected context
        end
      end

  ## Hardware Configurations

  Tests can declare their hardware requirements:
  - `@required_slaves` - List of expected slave types
  - `@loopback_required` - Whether physical loopback is needed
  - `@min_slaves` - Minimum number of slaves required
  """

  use ExUnit.CaseTemplate
  require Logger

  using do
    quote do
      use ExUnit.Case, async: false
      require Logger
      import HardwareCase
      import HardwareHelpers

      # All hardware tests get this tag automatically
      @moduletag :hardware
      @moduletag timeout: 60_000
    end
  end

  setup tags do
    # Check if hardware requirements are met
    min_slaves = Map.get(tags, :min_slaves, 1)

    {:ok, master, slaves} = EtherCAT.open(update_interval: 1000)

    if length(slaves) < min_slaves do
      EtherCAT.close(master)

      {:error,
       "Hardware requirement not met: expected #{min_slaves} slaves, got #{length(slaves)}"}
    else
      on_exit(fn ->
        try do
          EtherCAT.close(master)
        catch
          :exit, {:noproc, _} ->
            Logger.debug("Master already terminated")
        end

        :erlang.garbage_collect()
      end)

      %{master: master, slaves: slaves}
    end
  end
end
