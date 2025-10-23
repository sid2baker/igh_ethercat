defmodule IghEthercat.Slave.Driver do
  @moduledoc """
  Behaviour for EtherCAT slave drivers.

  This module defines the interface that all slave drivers must implement
  to handle configuration and value operations.
  """

  @type state :: term()
  @type pdo :: atom()

  @callback configure(state :: state(), config :: map()) :: {:ok, state()} | {:error, term()}
  @callback list_pdos(state :: state()) :: {:ok, [pdo()]} | {:error, term()}
  @callback pdo_info(state :: state(), pdo :: pdo()) :: {:ok, map()} | {:error, term()}
  @callback terminate(state :: state()) :: :ok

  defmacro __using__(_opts) do
    quote do
      @behaviour IghEthercat.Slave.Driver
    end
  end
end
