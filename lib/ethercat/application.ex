defmodule EtherCAT.Application do
  @moduledoc """
  OTP Application starting Registry for process discovery.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Registry for process discovery across all EtherCAT components
      {Registry, keys: :unique, name: EtherCAT.Registry}
    ]

    opts = [
      strategy: :one_for_one,
      name: EtherCAT.Supervisor
    ]

    Supervisor.start_link(children, opts)
  end
end
