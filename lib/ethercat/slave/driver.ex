defmodule EtherCAT.Slave.Driver do
  @moduledoc """
  Behaviour for EtherCAT slave drivers.

  Drivers encapsulate device-specific configuration and PDO (Process Data Object)
  mappings for EtherCAT slaves. This behaviour provides a pluggable architecture
  for supporting different EtherCAT slave devices with varying capabilities.

  ## Callbacks

  Each driver must implement the following callbacks:

  - `configure/2` - Apply device-specific settings and initialize driver state
  - `list_pdos/1` - Return available PDO names for this device
  - `pdo_info/2` - Provide sync manager, PDO index, and entry details for a given PDO
  - `terminate/1` - Clean up resources when the driver is stopped

  ## Driver State

  Drivers maintain their own state, which is passed to all callbacks. This state
  can be used to cache PDO mappings, configuration parameters, or any other
  device-specific data.

  ## Sync Manager Configuration

  The sync manager tuple format is `{sync_index, direction, watchdog_mode}` where:
  - `sync_index` - The sync manager index (0-15)
  - `direction` - 1 for output (master -> slave), 2 for input (slave -> master)
  - `watchdog_mode` - Watchdog configuration (0 = default, 1 = enabled, 2 = disabled)

  ## PDO Entry Configuration

  The PDO entry tuple format is `{entry_index, entry_subindex, bit_length}` where:
  - `entry_index` - The PDO entry index (e.g., 0x6000)
  - `entry_subindex` - The PDO entry subindex (e.g., 0x01)
  - `bit_length` - The size in bits (e.g., 1 for bool, 8 for uint8, 16 for uint16)

  ## Example

      defmodule MyDevice.Driver do
        use EtherCAT.Slave.Driver

        @impl true
        def configure(state, _config) do
          # Initialize driver state
          {:ok, Map.put(state, :initialized, true)}
        end

        @impl true
        def list_pdos(_state) do
          [:input1, :input2, :output1]
        end

        @impl true
        def pdo_info(_state, :input1) do
          {:ok,
           %{
             sync_manager: {0, 2, 0},
             pdo_index: 0x1A00,
             entry: {0x6000, 0x01, 1}
           }}
        end

        @impl true
        def pdo_info(_state, :output1) do
          {:ok,
           %{
             sync_manager: {1, 1, 0},
             pdo_index: 0x1600,
             entry: {0x7000, 0x01, 1}
           }}
        end

        @impl true
        def terminate(_state), do: :ok
      end
  """

  @typedoc "Driver-specific state maintained across callbacks"
  @type state :: term()

  @typedoc "PDO identifier (typically an atom like :input1 or :output1)"
  @type pdo_name :: atom() | String.t()

  @typedoc """
  Sync manager configuration tuple: {sync_index, direction, watchdog_mode}

  - sync_index: 0-15
  - direction: 1 (output/write) or 2 (input/read)
  - watchdog_mode: 0 (default), 1 (enabled), 2 (disabled)
  """
  @type sync_manager_config :: {
          sync_index :: non_neg_integer(),
          direction :: 1 | 2,
          watchdog_mode :: 0 | 1 | 2
        }

  @typedoc """
  PDO entry configuration tuple: {entry_index, entry_subindex, bit_length}

  - entry_index: Object dictionary index (e.g., 0x6000)
  - entry_subindex: Object dictionary subindex (e.g., 0x01)
  - bit_length: Size in bits (1, 8, 16, 32, etc.)
  """
  @type pdo_entry_config :: {
          entry_index :: non_neg_integer(),
          entry_subindex :: non_neg_integer(),
          bit_length :: pos_integer()
        }

  @typedoc """
  Complete PDO information including sync manager, PDO index, and entry details
  """
  @type pdo_info :: %{
          sync_manager: sync_manager_config(),
          pdo_index: non_neg_integer(),
          entry: pdo_entry_config()
        }

  @doc """
  Configure the driver with device-specific settings.

  Called when a slave is being configured. The driver receives a function
  to call for SDO configuration.

  ## Parameters
  - `config_sdo` - Function to configure SDOs: `(index, subindex, data) -> :ok | {:error, reason}`
  - `state` - Current driver state
  - `config` - Configuration map passed from user code

  ## Returns
  - `{:ok, new_state}` on success
  - `{:error, reason}` on failure

  ## Example

      def configure(config_sdo, state, config) do
        # Configure SDO parameters
        limit = Map.get(config, :temperature_limit, 1000)
        data = <<limit::little-signed-16>>
        :ok = config_sdo.(0x8000, 0x13, data)

        {:ok, Map.put(state, :configured, true)}
      end
  """
  @callback configure(
              config_sdo :: (0x0000..0xFFFF, 0x00..0xFF, binary() ->
                               :ok | {:error, term()}),
              state :: state(),
              config :: map()
            ) ::
              {:ok, state()} | {:error, term()}

  @doc """
  List all available PDO names for this driver.

  Returns a list of PDO identifiers that can be registered for cyclic data exchange.
  """
  @callback list_pdos(state :: state()) :: [pdo_name()]

  @doc """
  Get detailed information about a specific PDO.

  Returns PDO configuration including sync manager settings, PDO index,
  and entry details needed for registration.
  """
  @callback pdo_info(state :: state(), pdo :: pdo_name()) ::
              {:ok, pdo_info()} | {:error, term()}

  @doc """
  Clean up driver resources when the slave process terminates.

  This callback is called during slave process termination and should
  release any resources held by the driver.
  """
  @callback terminate(state :: state()) :: :ok

  defmacro __using__(_opts) do
    quote do
      @behaviour EtherCAT.Slave.Driver
    end
  end
end
