defmodule EtherCAT.Application do
  @moduledoc """
  OTP Application for the EtherCAT library.

  This application provides the supervision tree for EtherCAT infrastructure.

  ## Supervision Architecture

  ```
  EtherCAT.Supervisor (one_for_one)
    └─ EtherCAT.Registry (Registry)
       └─ Process discovery for masters, domains, and slaves

  EtherCAT.Master (started independently or under your app's supervisor)
    ├─ Domains (linked processes, die with Master)
    └─ Slaves (linked processes, die with Master)
  ```

  ## Lifecycle Management

  **Master owns its children via linking:**
  - When Master dies → all slaves and domains die (correct: NIF resources invalid)
  - When slave/domain dies → Master receives EXIT and can handle it
  - Simple, predictable lifecycle matching the physical hardware dependencies

  **Why no DynamicSupervisor?**
  Slaves and domains are tightly coupled to the Master's NIF resources:
  - `domain_ref` and `slave_config` are only valid while Master is alive
  - Restarting a slave/domain independently would create orphaned processes with invalid resources
  - On Master crash, you need to reconnect and rediscover the bus anyway

  ## Process Discovery

  All EtherCAT processes register themselves in `EtherCAT.Registry`:
  - Masters: `{:master, master_index}`
  - Domains: `{:domain, master_pid, domain_name}`
  - Slaves: `{:slave, master_pid, position}`

  This allows reliable process lookup without relying on process names.

  ## Starting a Master

  **Option 1: Standalone (common for single master)**
  ```elixir
  {:ok, master} = EtherCAT.Master.start_link()
  ```

  **Option 2: Under your application's supervisor (for automatic restart)**
  ```elixir
  children = [
    {EtherCAT.Master, master_index: 0, name: MyApp.EtherCATMaster}
  ]
  Supervisor.start_link(children, strategy: :one_for_one)
  ```
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
