defmodule EtherCAT do
  @moduledoc """
  EtherCAT industrial I/O interface for the IgH EtherCAT Master.
  """

  alias EtherCAT.{Master, Slave, Domain, PDO}
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
    # Register each PDO individually using the new singular API
    results =
      Enum.map(pdo_names, fn pdo_name ->
        Slave.register_pdo(slave, pdo_name, domain)
      end)

    # Check if any failed
    case Enum.find(results, fn result -> match?({:error, _}, result) end) do
      {:error, _} = error ->
        error

      nil ->
        unique_names = Enum.map(results, fn {:ok, name} -> name end)

        handles =
          Enum.map(unique_names, fn unique_name ->
            PDO.new(domain, unique_name, master)
          end)

        {:ok, handles}
    end
  end

  @doc "Reads PDO value from handle."
  @spec read(PDO.t()) :: {:ok, term()} | {:error, term()}
  def read(%PDO{domain: domain_name, unique_name: name, master: master}) do
    case Domain.find_domain(master, domain_name) do
      {:ok, domain} -> Domain.get_pdo_value(domain, name)
      error -> error
    end
  end

  @doc "Writes value to PDO handle."
  @spec write(PDO.t(), term()) :: :ok | {:error, term()}
  def write(%PDO{domain: domain_name, unique_name: name, master: master}, value) do
    case Domain.find_domain(master, domain_name) do
      {:ok, domain} -> Domain.set_pdo_value(domain, name, value)
      error -> error
    end
  end

  @doc "Subscribes to PDO change notifications."
  @spec watch(PDO.t()) :: :ok | {:error, term()}
  def watch(%PDO{domain: domain_name, unique_name: name, master: master}) do
    case Domain.find_domain(master, domain_name) do
      {:ok, domain} -> Domain.subscribe(domain, self(), name)
      error -> error
    end
  end

  @doc "Unsubscribes from PDO change notifications."
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

  @doc "Gets domain update interval."
  @spec get_domain_interval(pid(), atom()) :: {:ok, pos_integer()} | {:error, term()}
  def get_domain_interval(master, domain_name) do
    case Domain.find_domain(master, domain_name) do
      {:ok, domain} -> {:ok, Domain.get_interval(domain)}
      error -> error
    end
  end
end
