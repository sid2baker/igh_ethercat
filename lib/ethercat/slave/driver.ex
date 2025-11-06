defmodule EtherCAT.Slave.Driver do
  @moduledoc """
  Behaviour for EtherCAT slave drivers.

  Drivers encapsulate device-specific configuration and PDO (Process Data Object)
  mappings for EtherCAT slaves. Each driver must implement callbacks for:

  - Configuration: Apply device-specific settings
  - PDO listing: Return available PDO names
  - PDO info: Provide sync manager, PDO index, and entry details for a given PDO
  - Termination: Clean up resources

  ## Example

      defmodule MyDriver do
        use EtherCAT.Slave.Driver

        @impl true
        def configure(state, _config), do: {:ok, state}

        @impl true
        def list_pdos(_state), do: [:input1, :output1]

        @impl true
        def pdo_info(_state, :input1),
          do: {:ok, %{sync_manager: {0, 2, 0}, pdo_index: 0x1A00, entry: {0x6000, 0x01, 1}}}

        @impl true
        def terminate(_state), do: :ok
      end
  """

  @type state :: term()
  @type pdo :: atom()
  @type sync_manager_config :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  @type pdo_entry_config :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  @type pdo_info :: %{
          sync_manager: sync_manager_config(),
          pdo_index: non_neg_integer(),
          entry: pdo_entry_config()
        }

  @callback configure(state :: state(), config :: map()) :: {:ok, state()} | {:error, term()}
  @callback list_pdos(state :: state()) :: [pdo()]
  @callback pdo_info(state :: state(), pdo :: pdo()) :: {:ok, pdo_info()} | {:error, term()}
  @callback terminate(state :: state()) :: :ok

  defmacro __using__(_opts) do
    quote do
      @behaviour EtherCAT.Slave.Driver
    end
  end
end
