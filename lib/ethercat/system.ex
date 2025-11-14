defmodule EtherCAT.System do
  @moduledoc """
  System handle for declarative EtherCAT configuration.

  A System represents a fully configured EtherCAT network, including master,
  domains, and slaves. It provides the interface for reading/writing PDO entries
  using semantic names.
  """

  alias EtherCAT.{Master, Slave}
  alias EtherCAT.Config.HardwareConfig

  defstruct [
    :master,
    :config,
    :slave_map,
    :entry_handles
  ]

  @type t :: %__MODULE__{
          master: pid(),
          config: HardwareConfig.t(),
          slave_map: %{atom() => pid()},
          entry_handles: %{{atom(), atom(), atom()} => pid()}
        }

  @doc """
  Opens and configures an EtherCAT system from a hardware configuration.

  ## Parameters
  - `config` - HardwareConfig struct (typically from Spark DSL module)
  - `opts` - Options passed to Master.start_link

  ## Returns
  - `{:ok, system}` - System handle on success
  - `{:error, reason}` - Error details

  ## Example

      config = MyMachine.hardware_config()
      {:ok, system} = EtherCAT.System.open(config)
  """
  @spec open(HardwareConfig.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def open(%HardwareConfig{} = config, opts \\ []) do
    # Validate configuration
    with :ok <- HardwareConfig.validate(config),
         # Start master
         {:ok, master} <- Master.start_link(opts),
         # Connect to EtherCAT master
         :ok <- Master.connect(master),
         # Discover slaves
         {:ok, slaves} <- Master.sync_slaves(master),
         # Verify hardware matches config (if expected specified)
         :ok <- verify_hardware(config, slaves),
         # Create all domains
         :ok <- create_domains(master, config.domains),
         # Configure all slaves
         {:ok, slave_map} <- configure_slaves(master, slaves, config.slaves),
         # Register all entries to domains
         :ok <- register_entries(slave_map, config.slaves),
         # Start cyclic communication
         :ok <- Master.start_cyclic_mode(master) do
      # Build entry handle lookup map
      entry_handles = build_entry_handles(slave_map, config.slaves)

      system = %__MODULE__{
        master: master,
        config: config,
        slave_map: slave_map,
        entry_handles: entry_handles
      }

      {:ok, system}
    else
      {:error, _reason} = error ->
        # Cleanup on error - stop master if it was started
        # Only attempt cleanup if master variable is bound (i.e., Master.start_link succeeded)
        error
    end
  end

  @doc """
  Closes the EtherCAT system and releases all resources.
  """
  @spec close(t()) :: :ok
  def close(%__MODULE__{master: master}) do
    Master.stop(master)
  end

  @doc """
  Looks up a slave PID by its configured name.

  ## Returns
  - `{:ok, pid}` if slave with name exists
  - `{:error, :slave_not_found}` otherwise
  """
  @spec find_slave(t(), atom()) :: {:ok, pid()} | {:error, :slave_not_found}
  def find_slave(%__MODULE__{slave_map: slave_map}, name) do
    case Map.fetch(slave_map, name) do
      {:ok, pid} -> {:ok, pid}
      :error -> {:error, :slave_not_found}
    end
  end

  @doc """
  Looks up slave PID for a specific PDO entry.

  ## Returns
  - `{:ok, slave_pid}` if entry exists
  - `{:error, reason}` otherwise
  """
  @spec find_entry(t(), atom(), atom(), atom()) ::
          {:ok, pid()} | {:error, term()}
  def find_entry(%__MODULE__{entry_handles: handles}, slave_name, pdo_name, entry_name) do
    case Map.fetch(handles, {slave_name, pdo_name, entry_name}) do
      {:ok, slave_pid} -> {:ok, slave_pid}
      :error -> {:error, {:entry_not_found, slave_name, pdo_name, entry_name}}
    end
  end

  # Private implementation

  defp verify_hardware(config, slaves) do
    # Check each slave in config has expected hardware (if specified)
    config.slaves
    |> Enum.filter(& &1.expected)
    |> Enum.reduce_while(:ok, fn slave_config, :ok ->
      case Enum.at(slaves, slave_config.position) do
        nil ->
          {:halt, {:error, {:slave_not_found, "No slave at position #{slave_config.position}"}}}

        slave_pid ->
          info = Slave.get_info(slave_pid)

          if info.vendor_id == slave_config.expected.vendor and
               info.product_code == slave_config.expected.product do
            {:cont, :ok}
          else
            {:halt,
             {:error,
              {:hardware_mismatch, slave_config.position,
               "Expected vendor 0x#{Integer.to_string(slave_config.expected.vendor, 16)}, " <>
                 "product 0x#{Integer.to_string(slave_config.expected.product, 16)}, " <>
                 "but found vendor 0x#{Integer.to_string(info.vendor_id, 16)}, " <>
                 "product 0x#{Integer.to_string(info.product_code, 16)}"}}}
          end
      end
    end)
  end

  defp create_domains(master, domain_configs) do
    Enum.reduce_while(domain_configs, :ok, fn domain_config, :ok ->
      case Master.create_domain(master, domain_config.name, domain_config.interval) do
        {:ok, _domain_ref} ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, {:domain_creation_failed, domain_config.name, reason}}}
      end
    end)
  end

  defp configure_slaves(master, slaves, slave_configs) do
    slave_configs
    |> Enum.reduce_while({:ok, %{}}, fn slave_config, {:ok, acc} ->
      case Enum.at(slaves, slave_config.position) do
        nil ->
          {:halt, {:error, {:slave_not_found, slave_config.position}}}

        slave_pid ->
          # Validate driver matches if specified in config
          with :ok <- validate_driver_match(master, slave_pid, slave_config) do
            # Set slave name if provided
            if slave_config.name do
              Slave.set_name(slave_pid, slave_config.name)
            end

            # Configure slave with driver config
            case Slave.configure(slave_pid, slave_config.config) do
              :ok ->
                # Add to slave map (use name or position as key)
                key = slave_config.name || :"s#{slave_config.position}"
                {:cont, {:ok, Map.put(acc, key, slave_pid)}}

              {:error, reason} ->
                {:halt, {:error, {:slave_config_failed, slave_config.position, reason}}}
            end
          else
            {:error, _} = error ->
              {:halt, error}
          end
      end
    end)
  end

  defp register_entries(slave_map, slave_configs) do
    slave_configs
    |> Enum.reduce_while(:ok, fn slave_config, :ok ->
      slave_pid = Map.fetch!(slave_map, slave_config.name || :"s#{slave_config.position}")

      # Register each entry
      result =
        Enum.reduce_while(slave_config.entries, :ok, fn entry_config, :ok ->
          case Slave.register_entry(
                 slave_pid,
                 entry_config.pdo_name,
                 entry_config.entry_name,
                 entry_config.domain
               ) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      case result do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp build_entry_handles(slave_map, slave_configs) do
    slave_configs
    |> Enum.flat_map(fn slave_config ->
      slave_name = slave_config.name || :"s#{slave_config.position}"

      Enum.map(slave_config.entries, fn entry_config ->
        key = {slave_name, entry_config.pdo_name, entry_config.entry_name}
        slave_pid = Map.fetch!(slave_map, slave_name)

        {key, slave_pid}
      end)
    end)
    |> Map.new()
  end

  # Validates that the auto-detected driver matches the configured driver (if specified)
  defp validate_driver_match(master, slave_pid, slave_config) do
    # Skip validation if no driver specified in config
    if slave_config.driver == nil do
      :ok
    else
      info = Slave.get_info(slave_pid)

      # Get the actual driver module from the slave's Registry metadata
      [{_pid, slave_meta}] =
        Registry.lookup(EtherCAT.Registry, {:slave, master, slave_config.position})

      actual_driver = slave_meta.driver

      if actual_driver == slave_config.driver do
        :ok
      else
        {:error,
         {:driver_mismatch, slave_config.position,
          "Config specifies #{inspect(slave_config.driver)}, " <>
            "but hardware (vendor 0x#{Integer.to_string(info.vendor_id, 16)}, " <>
            "product 0x#{Integer.to_string(info.product_code, 16)}) " <>
            "was detected as #{inspect(actual_driver)}"}}
      end
    end
  end
end
