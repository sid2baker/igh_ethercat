defmodule IghEthercat.Slave.Driver do
  @moduledoc """
  Behaviour for EtherCAT slave drivers.

  This module defines the interface that all slave drivers must implement
  to handle registration and subscription operations.

  ## Usage

      defmodule MyDriver do
        use IghEthercat.Slave.Driver

        @impl true
        def register_all(slave) do
          # Implementation here
        end

        @impl true
        def subscribe_all(slave) do
          # Implementation here
        end
      end
  """

  @doc """
  Register all PDOs for the given slave.
  """
  @callback register_all(master :: pid(), slave_config :: reference()) :: :ok | {:error, term()}

  @doc """
  Subscribe to all PDO updates for the given slave.
  """
  @callback subscribe_all(master :: pid(), domain :: reference(), slave_config :: reference()) ::
              :ok | {:error, term()}

  defmacro __using__(_opts) do
    quote do
      @behaviour IghEthercat.Slave.Driver
    end
  end
end
