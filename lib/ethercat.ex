defmodule EtherCAT do
  @moduledoc """
  Simplified EtherCAT industrial I/O interface for the IgH EtherCAT Master.

  ## Quick Start

      # Open: auto-connects and discovers slaves
      {:ok, master, [_coupler, input, output]} = EtherCAT.open()

      # Configure: get available PDOs
      {:ok, in_pdos} = EtherCAT.configure_slave(master, input, %{})
      {:ok, out_pdos} = EtherCAT.configure_slave(master, output, %{})

      # Register: PDOs to domains (returns unique names)
      {:ok, [in_name | _]} = EtherCAT.register_pdos(master, input, in_pdos)
      {:ok, [out_name | _]} = EtherCAT.register_pdos(master, output, out_pdos)

      # Start: cyclic communication
      EtherCAT.start_cyclic(master)

      # I/O: read and write using unique names
      EtherCAT.write(master, out_name, true)
      {:ok, value} = EtherCAT.read(master, in_name)

      # Watch: subscribe to changes
      EtherCAT.watch(master, in_name)
      receive do
        {:data_changed, ^in_name, val} -> IO.puts("Changed: \#{val}")
      end

      # Cleanup
      EtherCAT.close(master)

  ## Multi-Domain (Advanced)

      # Create domains with different update rates
      EtherCAT.create_domain(master, :fast_io, 1)     # Every cycle
      EtherCAT.create_domain(master, :slow, 100)      # Every 100 cycles

      # Register PDOs to specific domains
      EtherCAT.register_pdos(master, slave, pdos, :fast_io)
  """

  alias EtherCAT.{Master, Slave, Domain}
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

  @doc "Closes master and cleans up all resources."
  @spec close(pid()) :: :ok
  def close(master), do: GenServer.stop(master, :normal)

  @doc "Creates domain with name and interval multiplier."
  @spec create_domain(pid(), atom(), pos_integer()) :: {:ok, reference()} | {:error, term()}
  def create_domain(master, name, interval), do: Master.create_domain(master, name, interval)

  @doc "Configures slave and returns available PDO names."
  @spec configure_slave(pid(), pid(), map()) :: {:ok, list()}
  def configure_slave(_master, slave, config) do
    :ok = Slave.configure(slave, config)
    {:ok, Slave.list_pdos(slave)}
  end

  @doc """
  Registers PDOs to domain. Returns unique names (`slave_N:pdo_name`).

  PDOs can only be registered to one domain - returns error if already registered elsewhere.
  """
  @spec register_pdos(pid(), pid(), [Slave.name()], Slave.domain()) ::
          {:ok, [String.t()]} | {:error, term()}
  def register_pdos(_master, slave, pdo_names, domain \\ :default_domain) do
    case Slave.register_pdos(slave, pdo_names, domain) do
      :ok ->
        position = get_slave_position(slave)
        unique_names = Enum.map(pdo_names, &"slave_#{position}:#{&1}")
        {:ok, unique_names}

      error ->
        error
    end
  end

  @doc "Reads PDO value using unique name."
  @spec read(pid(), String.t()) :: {:ok, term()} | {:error, term()}
  def read(master, unique_pdo) do
    case parse_unique_pdo(master, unique_pdo) do
      {:ok, slave, pdo_name} -> Slave.get_pdo_value(slave, pdo_name)
      error -> error
    end
  end

  @doc "Writes value to PDO using unique name."
  @spec write(pid(), String.t(), term()) :: :ok | {:error, term()}
  def write(master, unique_pdo, value) do
    case parse_unique_pdo(master, unique_pdo) do
      {:ok, slave, pdo_name} -> Slave.set_pdo_value(slave, pdo_name, value)
      error -> error
    end
  end

  @doc "Subscribes to PDO changes. Sends `{:data_changed, unique_pdo, value}` messages."
  @spec watch(pid(), String.t()) :: :ok | {:error, term()}
  def watch(master, unique_pdo) do
    case parse_unique_pdo(master, unique_pdo) do
      {:ok, slave, pdo_name} -> Slave.watch_pdo(slave, pdo_name, self())
      error -> error
    end
  end

  @doc "Unsubscribes from PDO change notifications."
  @spec unwatch(pid(), String.t()) :: :ok | {:error, term()}
  def unwatch(master, unique_pdo) do
    case parse_unique_pdo(master, unique_pdo) do
      {:ok, slave, pdo_name} -> Slave.unwatch_pdo(slave, pdo_name, self())
      error -> error
    end
  end

  @doc "Starts cyclic communication. Locks configuration - no changes allowed after this."
  @spec start_cyclic(pid()) :: :ok
  def start_cyclic(master), do: Master.start_cyclic_mode(master)

  # Private Helpers

  # Parses a unique PDO name into slave PID and PDO name
  # Format: "slave_<position>:<pdo_name>"
  defp parse_unique_pdo(master, unique_pdo) do
    case String.split(unique_pdo, ":", parts: 2) do
      ["slave_" <> position_str, pdo_name] ->
        case Integer.parse(position_str) do
          {position, ""} ->
            case find_slave_by_position(master, position) do
              {:ok, slave} -> {:ok, slave, pdo_name}
              error -> error
            end

          _ ->
            {:error, {:invalid_unique_pdo, unique_pdo}}
        end

      _ ->
        {:error, {:invalid_unique_pdo, unique_pdo}}
    end
  end

  # Finds a slave process by its position using the Registry
  defp find_slave_by_position(master, position) do
    case Registry.lookup(EtherCAT.Registry, {:slave, master, position}) do
      [{slave_pid, _}] -> {:ok, slave_pid}
      [] -> {:error, {:slave_not_found, position}}
    end
  end

  # Gets the position of a slave process using Registry
  defp get_slave_position(slave_pid) do
    case Registry.keys(EtherCAT.Registry, slave_pid) do
      [{:slave, _master, position}] -> position
      _ -> nil
    end
  end
end
