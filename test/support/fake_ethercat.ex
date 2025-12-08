defmodule FakeEtherCAT do
  @moduledoc """
  Helper for fakeethercat testing.

  This module provides utilities for testing EtherCAT applications without
  physical hardware using libfakeethercat.

  ## Key Features

  - **Environment setup**: Configures RtIPC bulletin board for process data sharing
  - **Config inversion**: Swaps sync manager directions (INPUT ↔ OUTPUT) to create
    matching slave emulators that can run back-to-back with your real application

  ## Fakeethercat Overview

  Libfakeethercat implements the complete EtherCAT master API but operates in
  userspace without requiring actual hardware. It uses RtIPC (shared memory) to
  exchange process data between applications.

  ## Testing Modes

  ### 1. Single Master (Simple)
  Just verify that configuration and writes don't crash. Fakeethercat accepts
  all operations and returns success without actual slaves.

  ```elixir
  setup do
    FakeEtherCAT.setup()
  end

  test "configure without hardware" do
    {:ok, master} = start_supervised({EtherCAT.Master, master_id: 0})
    {:ok, slaves} = EtherCAT.configure_hardware(master, my_config)
    assert :ok = EtherCAT.write(slaves.do, :channel_1, :output, true)
  end
  ```

  ### 2. Dual Master (Advanced)
  Run two applications back-to-back: one with real config, one with inverted
  config. They share process data via RtIPC, creating a true loopback.

  ```elixir
  real_config = MyHardwareConfig.config()
  fake_config = FakeEtherCAT.invert_config(real_config)

  # Start master with real config
  {:ok, master1} = start_supervised({EtherCAT.Master, master_id: 0})
  {:ok, slaves1} = EtherCAT.configure_hardware(master1, real_config)

  # Start emulator with inverted config (separate process/master)
  {:ok, master2} = start_supervised({EtherCAT.Master, master_id: 1})
  {:ok, _slaves2} = EtherCAT.configure_hardware(master2, fake_config)

  # Write to master1, read from master2 (they share RtIPC memory)
  :ok = EtherCAT.write(slaves1.do, :channel_1, :output, true)
  ```

  ## Environment Variables

  Fakeethercat uses these environment variables (all optional with defaults):
  - `FAKE_EC_HOMEDIR`: Directory for RtIPC bulletin board (default: system temp)
  - `FAKE_EC_NAME`: Name for RtIPC config (default: "FakeEtherCAT")
  - `FAKE_EC_PREFIX`: Prefix for RtIPC variables (default: none)

  The defaults work fine for testing, no configuration needed.
  """

  @doc """
  Sets up the fakeethercat environment for testing.

  Currently a no-op as fakeethercat defaults work fine.
  Kept for consistency with test setup patterns.

  ## Example

      setup do
        FakeEtherCAT.setup()
      end
  """
  def setup do
    :ok
  end

  @doc """
  Inverts a hardware config for slave emulation.

  Swaps EC_DIR_INPUT ↔ EC_DIR_OUTPUT in sync manager configurations so the
  emulator writes where the master reads and vice versa. This allows running
  two applications back-to-back that exchange process data via RtIPC.

  ## How It Works

  For each slave's sync manager configuration:
  1. Extract sync manager configurations
  2. Swap `:input` ↔ `:output` for each sync manager's direction
  3. Return new config with inverted sync managers

  ## Example

      real_config = TestHardwareConfig.config()
      fake_config = FakeEtherCAT.invert_config(real_config)

      # Real config: EL2809 has outputs (master writes, slave reads)
      # Fake config: EL2809 with inverted SMs has inputs (slave writes, master reads)

      # Start both masters - they share process data via RtIPC
      {:ok, master1} = EtherCAT.Master.start_link(master_id: 0)
      {:ok, master2} = EtherCAT.Master.start_link(master_id: 1)

      EtherCAT.configure_hardware(master1, real_config)
      EtherCAT.configure_hardware(master2, fake_config)
  """
  def invert_config(%{slaves: slaves} = hardware_config) do
    %{hardware_config | slaves: Enum.map(slaves, &invert_slave/1)}
  end

  defp invert_slave(slave) do
    inverted_sync_managers =
      slave.config.sync_managers
      |> Enum.map(&invert_sync_manager/1)

    inverted_config = %{slave.config | sync_managers: inverted_sync_managers}
    %{slave | config: inverted_config}
  end

  defp invert_sync_manager(sync_manager) do
    %{sync_manager | direction: invert_direction(sync_manager.direction)}
  end

  defp invert_direction(:input), do: :output
  defp invert_direction(:output), do: :input
end
