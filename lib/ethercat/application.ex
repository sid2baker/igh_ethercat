defmodule EtherCAT.Application do
  @moduledoc """
  OTP Application for the EtherCAT library.

  This application provides the supervision tree for EtherCAT masters and slaves.
  Currently, it starts an empty supervisor that allows dynamic child processes
  to be added at runtime.

  ## Dynamic Supervision

  EtherCAT masters are started on-demand using `EtherCAT.Master.start_link/1`
  rather than being supervised automatically. This gives applications full control
  over when and how EtherCAT communication is initiated.

  Each master process supervises its own slaves and domains, creating a hierarchical
  supervision tree:

  ```
  EtherCAT.Supervisor (empty, available for future use)
    └─ (no static children)

  EtherCAT.Master (started dynamically)
    ├─ EtherCAT.Slave (1..N slaves)
    └─ EtherCAT.Domain (1..N domains)
  ```

  ## Future Enhancements

  This supervisor can be extended to manage:
  - Global configuration services
  - Master discovery and registration
  - Monitoring and telemetry aggregation
  - Connection pooling for multiple masters
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = []

    opts = [
      strategy: :one_for_one,
      name: EtherCAT.Supervisor
    ]

    Supervisor.start_link(children, opts)
  end
end
