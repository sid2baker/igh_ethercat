defmodule EtherCAT.Application do
  @moduledoc """
  OTP Application for the EtherCAT library.

  This application provides a comprehensive supervision tree for EtherCAT masters,
  slaves, and domains with proper OTP patterns for reliability and fault tolerance.

  ## Supervision Architecture

  The application starts a supervision tree with the following components:

  ```
  EtherCAT.Supervisor (one_for_one)
    ├─ EtherCAT.Registry (Registry)
    │  └─ Process discovery for masters, domains, and slaves
    ├─ EtherCAT.DomainSupervisor (DynamicSupervisor)
    │  └─ Dynamically supervises domain processes
    └─ EtherCAT.SlaveSupervisor (DynamicSupervisor)
       └─ Dynamically supervises slave processes
  ```

  ## Dynamic Supervision

  EtherCAT masters can be started either:
  1. Standalone using `EtherCAT.Master.start_link/1` for manual control
  2. Under the application supervision tree for automatic restart

  Slaves and domains are automatically supervised by their respective DynamicSupervisors,
  ensuring they restart on failure while maintaining system stability.

  ## Process Discovery

  All EtherCAT processes register themselves in `EtherCAT.Registry` with the following keys:
  - Masters: `{:master, master_index}`
  - Domains: `{:domain, master_pid, domain_name}`
  - Slaves: `{:slave, master_pid, position}`

  This allows for reliable process lookup without relying on process names or direct PID storage.

  ## Fault Tolerance

  - **one_for_one strategy**: Each component restarts independently on failure
  - **DynamicSupervisors**: Slaves and domains can crash without affecting siblings
  - **Registry**: Automatic process tracking with cleanup on termination
  - **Isolated failures**: Master crashes don't propagate to the entire application
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Registry for process discovery across all EtherCAT components
      {Registry, keys: :unique, name: EtherCAT.Registry},

      # DynamicSupervisor for domain processes
      # Domains can be started/stopped dynamically as needed
      {DynamicSupervisor,
       name: EtherCAT.DomainSupervisor, strategy: :one_for_one, max_restarts: 10},

      # DynamicSupervisor for slave processes
      # Slaves can be started/stopped as the bus topology changes
      {DynamicSupervisor, name: EtherCAT.SlaveSupervisor, strategy: :one_for_one, max_restarts: 10}
    ]

    opts = [
      strategy: :one_for_one,
      name: EtherCAT.Supervisor,
      max_restarts: 3,
      max_seconds: 5
    ]

    Supervisor.start_link(children, opts)
  end
end
