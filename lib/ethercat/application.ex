defmodule EtherCAT.Application do
  @moduledoc """
  OTP Application supervising EtherCAT Master and Registry.

  The application starts:
  - Registry for process discovery
  - EtherCAT Master (infrastructure, auto-connects to network)

  ## Configuration

  Configure the master in config.exs:

      config :ethercat, :master,
        master_index: 0,
        scan_interval: 100_000  # 100ms hardware scanning

  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Registry for process discovery across all EtherCAT components
      {Registry, keys: :unique, name: EtherCAT.Registry},

      # EtherCAT Master (infrastructure)
      {EtherCAT.Master, get_master_opts()}
    ]

    opts = [
      strategy: :one_for_one,
      name: EtherCAT.Supervisor
    ]

    Supervisor.start_link(children, opts)
  end

  defp get_master_opts do
    Application.get_env(:ethercat, :master, [])
    |> Keyword.put_new(:master_index, 0)
    |> Keyword.put_new(:scan_interval, 100_000)
  end
end
