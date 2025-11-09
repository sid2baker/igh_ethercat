defmodule EtherCAT do
  @moduledoc """
  Simplified EtherCAT industrial I/O interface for the IgH EtherCAT Master.

  ## Quick Start

      # Open: auto-connects and discovers slaves
      {:ok, master, [_coupler, input, output]} = EtherCAT.open()

      # Configure: get available PDOs
      {:ok, in_pdos} = EtherCAT.configure_slave(master, input, %{})
      {:ok, out_pdos} = EtherCAT.configure_slave(master, output, %{})

      # Register: PDOs to domains (returns PDO handles)
      {:ok, [in_handle | _]} = EtherCAT.register_pdos(master, input, in_pdos)
      {:ok, [out_handle | _]} = EtherCAT.register_pdos(master, output, out_pdos)

      # Start: cyclic communication
      EtherCAT.start_cyclic(master)

      # I/O: read and write using handles
      EtherCAT.write(out_handle, true)
      {:ok, value} = EtherCAT.read(in_handle)

      # Watch: subscribe to changes
      EtherCAT.watch(in_handle)
      receive do
        {:data_changed, "slave_1:pdo_name", val} -> IO.puts("Changed: \#{val}")
      end

      # Cleanup
      EtherCAT.close(master)

  ## Multi-Domain (Advanced)

      # Create domains with different update rates
      EtherCAT.create_domain(master, :fast_io, 1)     # Every cycle
      EtherCAT.create_domain(master, :slow, 100)      # Every 100 cycles

      # Register PDOs to specific domains
      EtherCAT.register_pdos(master, slave, pdos, :fast_io)

  ## Multi-Master Support

  Multiple masters can coexist in the same application, each managing independent
  EtherCAT networks. Domains are scoped to their master, so each master can have
  its own `:default_domain` without conflicts.

      # Open two independent masters
      {:ok, master1, slaves1} = EtherCAT.open(index: 0)
      {:ok, master2, slaves2} = EtherCAT.open(index: 1)

      # Each master has its own domains
      EtherCAT.create_domain(master1, :default_domain, 1)
      EtherCAT.create_domain(master2, :default_domain, 1)

      # Configure and use each master independently
      {:ok, handles1} = EtherCAT.register_pdos(master1, hd(slaves1), pdos1)
      {:ok, handles2} = EtherCAT.register_pdos(master2, hd(slaves2), pdos2)
  """

  alias EtherCAT.{Master, Slave, Domain, PDO}
  require Logger

  @doc "Opens master, connects, and discovers slaves. Returns `{:ok, master, [slaves]}`."
  @spec open(keyword()) :: {:ok, pid(), [pid()]} | {:error, term()}
  def open(opts \\ []) do
    with {:ok, master} <- Master.start_link(opts),
         :ok <- Master.connect(master),
         {:ok, slaves} <- Master.sync_slaves(master) do
      {:ok, master, slaves}
    end
  end

  @doc """
  Closes master and cleans up all resources.

  Blocks until the master process has fully terminated and the EtherCAT kernel
  module has released the device. This ensures the next test can acquire the master
  without "device busy" errors.
  """
  @spec close(pid()) :: :ok
  def close(master) do
    # Monitor the master process to know when it terminates
    ref = Process.monitor(master)

    # Stop the master (blocks until terminate/2 completes)
    GenServer.stop(master, :normal)

    # Wait for the process to terminate
    receive do
      {:DOWN, ^ref, :process, ^master, _reason} -> :ok
    after
      5000 ->
        Logger.warning("Master process did not terminate within 5 seconds")
        :ok
    end

    # Give the EtherCAT kernel module time to release the device
    # Empirically determined: 500ms for single test, 3500ms for multiple sequential tests
    # The kernel module needs significant time to fully release resources
    :timer.sleep(3500)

    :ok
  end

  @doc "Creates domain with name and interval multiplier."
  @spec create_domain(pid(), atom(), pos_integer()) :: {:ok, reference()} | {:error, term()}
  def create_domain(master, name, interval), do: Master.create_domain(master, name, interval)

  @doc "Configures slave and returns available PDO names."
  @spec configure_slave(pid(), map()) :: {:ok, list()}
  def configure_slave(slave, config) do
    :ok = Slave.configure(slave, config)
    {:ok, Slave.list_pdos(slave)}
  end

  @doc """
  Registers PDOs to domain and returns PDO handles.

  PDOs can only be registered to one domain - returns error if already registered elsewhere.

  ## Parameters
  - `master` - Master process PID
  - `slave` - Slave process PID
  - `pdo_names` - List of PDO names from `configure_slave/3`
  - `domain` - Domain name (default: `:default_domain`)

  ## Returns
  - `{:ok, [%PDO{}]}` - List of PDO handles on success
  - `{:error, reason}` - Error if registration fails

  ## Example

      {:ok, [temp, pressure]} = EtherCAT.register_pdos(master, slave, ["pdo_6000:1", "pdo_6010:1"])
  """
  @spec register_pdos(pid(), pid(), [Slave.name()], Slave.domain()) ::
          {:ok, [PDO.t()]} | {:error, term()}
  def register_pdos(master, slave, pdo_names, domain \\ :default_domain) do
    case Slave.register_pdos(slave, pdo_names, domain) do
      {:ok, unique_names} ->
        handles =
          Enum.map(unique_names, fn unique_name ->
            PDO.new(domain, unique_name, master)
          end)

        {:ok, handles}

      error ->
        error
    end
  end

  @doc """
  Reads PDO value using a PDO handle.

  ## Parameters
  - `pdo` - PDO handle from `register_pdos/4`

  ## Returns
  - `{:ok, value}` on success
  - `{:error, reason}` if PDO not found or not operational

  ## Example

      {:ok, [temp_handle | _]} = EtherCAT.register_pdos(master, slave, pdos)
      {:ok, temperature} = EtherCAT.read(temp_handle)
  """
  @spec read(PDO.t()) :: {:ok, term()} | {:error, term()}
  def read(%PDO{domain: domain_name, unique_name: name, master: master}) do
    case Domain.find_domain(master, domain_name) do
      {:ok, domain} -> Domain.get_pdo_value(domain, name)
      error -> error
    end
  end

  @doc """
  Writes value to PDO using a PDO handle.

  ## Parameters
  - `pdo` - PDO handle from `register_pdos/4`
  - `value` - Value to write (type depends on PDO configuration)

  ## Returns
  - `:ok` on success
  - `{:error, reason}` if PDO not found or not operational

  ## Example

      {:ok, [output_handle | _]} = EtherCAT.register_pdos(master, slave, pdos)
      EtherCAT.write(output_handle, true)
  """
  @spec write(PDO.t(), term()) :: :ok | {:error, term()}
  def write(%PDO{domain: domain_name, unique_name: name, master: master}, value) do
    case Domain.find_domain(master, domain_name) do
      {:ok, domain} -> Domain.set_pdo_value(domain, name, value)
      error -> error
    end
  end

  @doc """
  Subscribes to PDO changes using a PDO handle.

  The calling process will receive `{:data_changed, unique_name, value}` messages
  whenever the PDO value changes during cyclic operation.

  ## Parameters
  - `pdo` - PDO handle from `register_pdos/4`

  ## Returns
  - `:ok` on success
  - `{:error, reason}` if domain not found

  ## Example

      {:ok, [input_handle | _]} = EtherCAT.register_pdos(master, slave, pdos)
      EtherCAT.watch(input_handle)

      receive do
        {:data_changed, unique_name, value} ->
          IO.puts("PDO \#{unique_name} changed to \#{value}")
      end
  """
  @spec watch(PDO.t()) :: :ok | {:error, term()}
  def watch(%PDO{domain: domain_name, unique_name: name, master: master}) do
    case Domain.find_domain(master, domain_name) do
      {:ok, domain} -> Domain.subscribe(domain, self(), name)
      error -> error
    end
  end

  @doc """
  Unsubscribes from PDO change notifications.

  Removes the subscription previously created with `watch/1`.

  ## Parameters
  - `pdo` - PDO handle from `register_pdos/4`

  ## Returns
  - `:ok` on success
  - `{:error, reason}` if domain not found

  ## Example

      EtherCAT.watch(input_handle)
      # ... receive some notifications ...
      EtherCAT.unwatch(input_handle)
  """
  @spec unwatch(PDO.t()) :: :ok | {:error, term()}
  def unwatch(%PDO{domain: domain_name, unique_name: name, master: master}) do
    case Domain.find_domain(master, domain_name) do
      {:ok, domain} -> Domain.unsubscribe(domain, self(), name)
      error -> error
    end
  end

  @doc "Starts cyclic communication. Locks configuration - no changes allowed after this."
  @spec start_cyclic(pid()) :: :ok
  def start_cyclic(master), do: Master.start_cyclic_mode(master)

  @doc """
  Gets the update interval for a domain.

  ## Parameters
  - `master` - Master process PID
  - `domain_name` - The domain name (atom)

  ## Returns
  - `{:ok, interval}` on success
  - `{:error, :not_found}` if domain doesn't exist

  ## Example

      {:ok, interval} = EtherCAT.get_domain_interval(master, :default_domain)
      #=> {:ok, 1}
  """
  @spec get_domain_interval(pid(), atom()) :: {:ok, pos_integer()} | {:error, term()}
  def get_domain_interval(master, domain_name) do
    case Domain.find_domain(master, domain_name) do
      {:ok, domain} -> {:ok, Domain.get_interval(domain)}
      error -> error
    end
  end
end
