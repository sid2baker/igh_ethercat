defmodule IghEthercat.Slave.Driver do
  @moduledoc """
  Behaviour for EtherCAT slave drivers.

  This module defines the interface that all slave drivers must implement
  to handle configuration and value operations.

  ## Usage

      defmodule MyDriver do
        use IghEthercat.Slave.Driver

        @impl true
        def configure(config) do
          # Implementation here
        end

        @impl true
        def set_value(variable, value) do
          # Implementation here
        end

        @impl true
        def get_value(variable) do
          # Implementation here
        end

        @impl true
        def watch_value(variable, pid) do
          # Implementation here
        end
      end
  """

  @doc """
  Configure the driver with the given options.
  """
  @callback configure(config :: keyword()) :: :ok | {:error, term()}

  @doc """
  Set the value of a variable.
  """
  @callback set_value(variable :: term(), value :: term()) :: :ok | {:error, term()}

  @doc """
  Get the value of a variable.
  """
  @callback get_value(variable :: term()) :: {:ok, term()} | {:error, term()}

  @doc """
  Watch a variable for changes and notify the given process.
  """
  @callback watch_value(variable :: term(), pid :: pid()) :: :ok | {:error, term()}

  defmacro __using__(_opts) do
    quote do
      @behaviour IghEthercat.Slave.Driver
    end
  end
end
