defmodule EtherCAT do
  @moduledoc """
  EtherCAT industrial I/O interface for the IgH EtherCAT Master.
  """

  alias EtherCAT.{Master, Slave, Domain, PDOEntry}
  require Logger

  @doc "Opens master, connects, and discovers slaves. Returns `{:ok, master, [slaves]}`."
  @spec open(keyword()) :: {:ok, pid(), [pid()]} | {:error, term()}
  def open(opts \\ []) do
    case Master.start_link(opts) do
      {:ok, master} ->
        with :ok <- Master.connect(master),
             {:ok, slaves} <- Master.sync_slaves(master) do
          {:ok, master, slaves}
        else
          error ->
            Master.stop(master)
            error
        end

      error ->
        error
    end
  end

  @doc "Closes master and cleans up all resources."
  @spec close(pid()) :: :ok
  def close(master) do
    Master.stop(master)
  end

  @doc "Creates domain with name and interval multiplier."
  @spec create_domain(pid(), atom(), pos_integer()) :: {:ok, reference()} | {:error, term()}
  def create_domain(master, name, interval), do: Master.create_domain(master, name, interval)

  @doc """
  Sets a semantic name for a slave device.

  The name is used to generate human-readable unique identifiers for PDO entries.
  This is optional - if not set, slaves will use "s<position>" format (e.g., "s0", "s1").

  ## Parameters
  - `slave` - Slave process PID
  - `name` - Atom or string to identify the slave

  ## Returns
  - `:ok` on success

  ## Example

      {:ok, master, [slave1, slave2]} = EtherCAT.open(index: 0)

      # Set semantic names
      EtherCAT.set_slave_name(slave1, :temp_sensor)
      EtherCAT.set_slave_name(slave2, :pressure_sensor)

      # Register entries - now uses semantic names
      {:ok, temp} = EtherCAT.register_entry(master, slave1, :ch1, :value)
      # unique_name = "temp_sensor:ch1:value" (instead of "s0:ch1:value")
  """
  @spec set_slave_name(pid(), atom() | String.t()) :: :ok
  def set_slave_name(slave, name), do: Slave.set_name(slave, name)

  @doc """
  Gets the semantic name of a slave device, if set.

  ## Parameters
  - `slave` - Slave process PID

  ## Returns
  - `{:ok, name}` if name is set
  - `{:ok, nil}` if no name is set

  ## Example

      EtherCAT.set_slave_name(slave, :temp_sensor)
      {:ok, :temp_sensor} = EtherCAT.get_slave_name(slave)
  """
  @spec get_slave_name(pid()) :: {:ok, atom() | String.t() | nil}
  def get_slave_name(slave), do: Slave.get_name(slave)

  @doc "Configures slave and returns available PDO names."
  @spec configure_slave(pid(), map()) :: {:ok, list()}
  def configure_slave(slave, config) do
    :ok = Slave.configure(slave, config)
    {:ok, Slave.list_pdos(slave)}
  end

  @doc """
  Registers a single PDO entry and returns a handle for I/O operations.

  This is the **granular entry-level API** - register only specific entries you need.

  ## Parameters
  - `master` - Master process PID (not used, kept for API compatibility)
  - `slave` - Slave process PID
  - `pdo_name` - PDO name from `configure_slave/2` (e.g., `:ch1`)
  - `entry_name` - Entry name within the PDO (e.g., `:value`, `:error`)
  - `domain` - Domain identifier (default: `:default_domain`)

  ## Returns
  - `{:ok, %PDOEntry{}}` - PDO entry handle for read/write/watch operations
  - `{:error, reason}` - Error if registration fails

  ## Multi-Domain Support
  Entries from the same sync manager can be registered to different domains.
  Each domain creates its own FMMU mapping of the sync manager memory.

  ## Example

      # Register only the temperature value, skip other entries
      {:ok, temp_handle} = EtherCAT.register_entry(master, slave, :ch1, :value)
      {:ok, temp} = EtherCAT.read(temp_handle)
  """
  @spec register_entry(pid(), pid(), Slave.pdo_name(), Slave.entry_name(), Slave.domain()) ::
          {:ok, PDOEntry.t()} | {:error, term()}
  def register_entry(_master, slave, pdo_name, entry_name, domain \\ :default_domain) do
    case Slave.register_entry(slave, pdo_name, entry_name, domain) do
      {:ok, {unique_name, domain_pid}} ->
        {:ok, PDOEntry.new(domain_pid, unique_name)}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Registers multiple PDO entries and returns handles for I/O operations.

  Convenience function for registering several specific entries at once.

  ## Parameters
  - `master` - Master process PID (not used, kept for API compatibility)
  - `slave` - Slave process PID
  - `entries` - List of `{pdo_name, entry_name}` or `{pdo_name, entry_name, domain}` tuples
  - `default_domain` - Domain to use when not specified per entry (default: `:default_domain`)

  ## Returns
  - `{:ok, [%PDOEntry{}]}` - List of PDO entry handles on success
  - `{:error, reason}` - Error if any registration fails

  ## Example

      # Register specific entries from different PDOs
      {:ok, handles} = EtherCAT.register_entries(master, slave, [
        {:ch1, :value},
        {:ch1, :error},
        {:ch2, :value}
      ])

      [temp1, temp1_err, temp2] = handles
  """
  @spec register_entries(pid(), pid(), list(), Slave.domain()) ::
          {:ok, [PDOEntry.t()]} | {:error, term()}
  def register_entries(_master, slave, entries, default_domain \\ :default_domain) do
    case Slave.register_entries(slave, entries, default_domain) do
      {:ok, entry_infos} ->
        handles = Enum.map(entry_infos, fn {unique_name, domain_pid} ->
          PDOEntry.new(domain_pid, unique_name)
        end)

        {:ok, handles}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Registers PDOs (with all their entries) to domain and returns handles.

  This is the **convenient PDO-level API** - register all entries in each PDO at once.

  ## Parameters
  - `master` - Master process PID (not used, kept for API compatibility)
  - `slave` - Slave process PID
  - `pdo_names` - List of PDO names from `configure_slave/2`
  - `domain` - Domain name (default: `:default_domain`)

  ## Returns
  - `{:ok, [%PDOEntry{}]}` - List of handles for all entries in all PDOs
  - `{:error, reason}` - Error if registration fails

  ## Multi-Domain Support
  PDOs and entries can be registered to different domains regardless of sync manager.
  Each domain creates its own FMMU for accessing the sync manager memory.

  ## Example

      # Register all entries from channel 1 and channel 2 PDOs
      {:ok, handles} = EtherCAT.register_pdos(master, slave, [:ch1, :ch2])
      # Returns handles for all 12 entries (6 per channel)
  """
  @spec register_pdos(pid(), pid(), [Slave.pdo_name()], Slave.domain()) ::
          {:ok, [PDOEntry.t()]} | {:error, term()}
  def register_pdos(_master, slave, pdo_names, domain \\ :default_domain) do
    # Register each PDO individually using the PDO-level API
    results =
      Enum.map(pdo_names, fn pdo_name ->
        Slave.register_pdo(slave, pdo_name, domain)
      end)

    # Check if any failed
    case Enum.find(results, fn result -> match?({:error, _}, result) end) do
      {:error, _} = error ->
        error

      nil ->
        # Each result contains {:ok, [{name, pid}, ...]}, so flatten and convert to handles
        handles =
          results
          |> Enum.flat_map(fn {:ok, entry_infos} -> entry_infos end)
          |> Enum.map(fn {unique_name, domain_pid} ->
            PDOEntry.new(domain_pid, unique_name)
          end)

        {:ok, handles}
    end
  end

  @doc "Reads PDO entry value from handle."
  @spec read(PDOEntry.t()) :: {:ok, term()} | {:error, term()}
  def read(%PDOEntry{domain_pid: domain_pid, unique_name: name}) do
    Domain.get_pdo_value(domain_pid, name)
  end

  @doc "Writes value to PDO entry handle."
  @spec write(PDOEntry.t(), term()) :: :ok | {:error, term()}
  def write(%PDOEntry{domain_pid: domain_pid, unique_name: name}, value) do
    Domain.set_pdo_value(domain_pid, name, value)
  end

  @doc "Subscribes to PDO entry change notifications."
  @spec watch(PDOEntry.t()) :: :ok | {:error, term()}
  def watch(%PDOEntry{domain_pid: domain_pid, unique_name: name}) do
    Domain.subscribe(domain_pid, self(), name)
  end

  @doc "Unsubscribes from PDO entry change notifications."
  @spec unwatch(PDOEntry.t()) :: :ok | {:error, term()}
  def unwatch(%PDOEntry{domain_pid: domain_pid, unique_name: name}) do
    Domain.unsubscribe(domain_pid, self(), name)
  end

  @doc "Starts cyclic communication. Locks configuration - no changes allowed after this."
  @spec start_cyclic(pid()) :: :ok
  def start_cyclic(master), do: Master.start_cyclic_mode(master)

  @doc "Gets domain update interval."
  @spec get_domain_interval(pid(), atom()) :: {:ok, pos_integer()} | {:error, term()}
  def get_domain_interval(master, domain_name) do
    case Domain.find_domain(master, domain_name) do
      {:ok, domain} -> {:ok, Domain.get_interval(domain)}
      error -> error
    end
  end
end
