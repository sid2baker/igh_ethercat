defmodule EtherCAT.Slave.Driver do
  @moduledoc """
  Behaviour for EtherCAT slave drivers.

  ## Callbacks
  - `start_driver/2` - Initialize driver with name and config
  - `configure/1` - Configure slave (must call `slave_configured/2` when done)

  ## Usage
      use EtherCAT.Slave.Driver

  Injects helper functions for slave configuration: `sdo_config/4`, `sync_manager/4`,
  `pdo_assign_clear/2`, `pdo_assign_add/3`, `pdo_mapping_clear/2`, `pdo_mapping_add/5`.
  """

  alias EtherCAT.Master
  require Logger

  # ========================================================================
  # Behaviour Callbacks
  # ========================================================================

  @doc """
  Returns a child specification for starting the driver under a supervisor.

  Expects a keyword list with `:name` (atom) and `:config` (map) keys.
  """
  @callback child_spec(opts :: keyword()) :: Supervisor.child_spec()

  @doc """
  Initialize driver with slave name and config.
  """
  @callback start_driver(name :: atom(), config :: map()) ::
              {:ok, pid()} | {:error, term()}

  @doc """
  Configure slave. Must call `slave_configured/2` when done. Non-blocking.
  Called by `EtherCAT.Master` (use `self()` for `master_pid`).
  """
  @callback configure(driver_pid :: pid()) :: :ok

  # ========================================================================
  # __using__ macro
  # ========================================================================

  defmacro __using__(_opts) do
    quote do
      @behaviour EtherCAT.Slave.Driver

      @impl EtherCAT.Slave.Driver
      def child_spec(opts) do
        name = Keyword.fetch!(opts, :name)
        config = Keyword.get(opts, :config, %{})

        %{
          id: name,
          start: {__MODULE__, :start_driver, [name, config]},
          restart: :permanent,
          shutdown: 5000,
          type: :worker
        }
      end

      defoverridable child_spec: 1

      @doc "Signal master that slave configuration is complete."
      def slave_configured(configured_pdos) do
        # configured_pdos in the form %{{:pdo_name, :entry_name} => {direction, {index, subindex, bit_length}}
        :gen_statem.call(Master, {:slave_configured, configured_pdos})
      end

      @doc "Configure SDO: index, subindex, data."
      def sdo_config(index, subindex, data) do
        :gen_statem.call(Master, {:slave_config, :sdo, [index, subindex, data]})
      end

      @doc "Configure sync manager: index, direction, watchdog."
      def sync_manager(index, direction, watchdog) do
        :gen_statem.call(Master, {:slave_config, :sync_manager, [index, direction, watchdog]})
      end

      @doc "Clear PDO assignments for sync manager."
      def pdo_assign_clear(sm_index) do
        :gen_statem.call(Master, {:slave_config, :pdo_assign_clear, [sm_index]})
      end

      @doc "Assign PDO to sync manager."
      def pdo_assign_add(sm_index, pdo_index) do
        :gen_statem.call(Master, {:slave_config, :pdo_assign_add, [sm_index, pdo_index]})
      end

      @doc "Clear PDO entry mappings."
      def pdo_mapping_clear(pdo_index) do
        :gen_statem.call(Master, {:slave_config, :pdo_mapping_clear, [pdo_index]})
      end

      @doc "Add PDO entry mapping: pdo_index, entry_index, entry_subindex, bit_length."
      def pdo_mapping_add(pdo_index, entry_index, entry_subindex, bit_length) do
        :gen_statem.call(
          Master,
          {:slave_config, :pdo_mapping_add, [pdo_index, entry_index, entry_subindex, bit_length]}
        )
      end
    end
  end
end
