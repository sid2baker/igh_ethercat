defmodule EtherCAT do
  @moduledoc """
  EtherCAT master implementation using the IgH EtherCAT Master for Linux.

  This module provides an idiomatic Elixir interface to EtherCAT communication,
  with a clean separation of concerns:

  - `EtherCAT.Master` - Manages the EtherCAT master and network lifecycle
  - `EtherCAT.Slave` - Represents individual slaves with configuration and data access
  - `EtherCAT.Domain` - Manages process data domains for cyclic communication

  ## Architecture

  All NIF communication is routed through the Master process to prevent race conditions.
  Slaves and Domains call back into Master using internal APIs that serve as the
  single gateway to the underlying C library.

  ## Example Usage

  See `test/0`, `test2/0`, and `test3/0` for working examples of:
  - Connecting to the network
  - Discovering and configuring slaves
  - Registering PDO entries to domains
  - Activating cyclic communication
  """
  alias EtherCAT.{Master, Slave}

  @doc """
  Basic test - connects to master and discovers slaves.

  Expects a setup with 3 slaves:
  - Slave 0: Bus coupler/terminal (ignored)
  - Slave 1: Digital input card (di1)
  - Slave 2: Digital output card (do1)

  Returns `{master_pid, input_slave_pid, output_slave_pid}` for interactive testing.

  ## Examples

      iex> {m, i, o} = EtherCAT.test()
      iex> EtherCAT.Slave.watch_pdo(i, "pdo_6000:1")  # Watch first input
      iex> EtherCAT.Slave.set_pdo_value(o, "pdo_7000:1", true)  # Set first output
  """
  def test do
    {:ok, master} = Master.start_link(update_interval: 1000)
    :ok = Master.connect(master)
    {:ok, [_koppler, di1, do1]} = Master.sync_slaves(master)
    Slave.configure(di1, [])
    Slave.list_pdos(di1) |> IO.inspect(label: "Input PDOs")
    Slave.configure(do1, [])
    Slave.list_pdos(do1) |> IO.inspect(label: "Output PDOs")
    Slave.register_all_pdos(di1, :default_domain)
    Slave.register_all_pdos(do1, :default_domain)
    Master.activate(master)
    # block till master is ready
    :timer.sleep(1000)
    Slave.set_pdo_value(do1, "pdo_7000:1", true)
    Slave.set_pdo_value(do1, "pdo_7040:1", true)
    Slave.set_pdo_value(do1, "pdo_7060:1", true)
    Slave.set_pdo_value(do1, "pdo_7080:1", true)
    {master, di1, do1}
  end

  @doc """
  Test with PDO registration and activation.
  Demonstrates registering specific PDOs and activating cyclic communication.
  """
  def test2 do
    {:ok, master} = Master.start_link()
    :ok = Master.connect(master)
    {:ok, [_slave1, slave2]} = Master.sync_slaves(master)

    Slave.configure(slave2, [])
    Slave.list_pdos(slave2) |> IO.inspect(label: "Options")
    Slave.register_all_pdos(slave2, :default_domain)

    Slave.register_pdos(
      slave2,
      [:input1, :input2, :input3, :input4, :input5, :input6, :input7, :input9],
      :default_domain
    )

    Master.activate(master)
    slave2
  end

  @doc """
  Test with multiple domains.
  Demonstrates creating additional domains with different update periods.
  """
  def test3 do
    {:ok, master} = Master.start_link()
    :ok = Master.connect(master)
    {:ok, [_slave1, slave2]} = Master.sync_slaves(master)
    Master.create_domain(master, :domain2, 100)

    Slave.configure(slave2, [])
    Slave.register_pdos(slave2, [:input1], :default_domain)
    Slave.register_all_pdos(slave2, :domain2)
    Master.activate(master)
    master
  end

  @doc """
  Gets a domain value at a specific offset.
  Note: This function references a non-existent NIF function and needs updating.
  """
  def get(domain, offset) do
    EtherCAT.Nif.get_domain_value(domain, offset)
  end
end
