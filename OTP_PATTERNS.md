# OTP Patterns and Best Practices

This document describes the OTP patterns implemented in the EtherCAT library for robust, production-ready operation.

## Table of Contents

1. [Supervision Tree](#supervision-tree)
2. [Process Discovery with Registry](#process-discovery-with-registry)
3. [Child Specifications](#child-specifications)
4. [Error Handling](#error-handling)
5. [Graceful Termination](#graceful-termination)
6. [Timeouts](#timeouts)
7. [State Machine Patterns](#state-machine-patterns)
8. [Telemetry Integration](#telemetry-integration)

## Supervision Tree

The EtherCAT library implements a comprehensive supervision hierarchy for fault tolerance and automatic recovery.

### Architecture

```
EtherCAT.Supervisor (one_for_one)
  ├─ EtherCAT.Registry (Registry)
  │  └─ Process discovery for all components
  ├─ EtherCAT.DomainSupervisor (DynamicSupervisor)
  │  └─ Supervises domain processes
  └─ EtherCAT.SlaveSupervisor (DynamicSupervisor)
     └─ Supervises slave processes

EtherCAT.Master (standalone or supervised)
  ├─ Creates and manages slaves
  ├─ Creates and manages domains
  └─ Monitors all children
```

### Why This Design?

1. **Isolation**: Each component can crash without affecting siblings
2. **Dynamic Children**: Slaves and domains are added/removed as the bus topology changes
3. **Registry**: Provides reliable process discovery without relying on named processes
4. **Restart Strategies**: Different components have appropriate restart policies

### Supervision Configuration

```elixir
# Application supervisor - restarts infrastructure components
strategy: :one_for_one
max_restarts: 3
max_seconds: 5

# DynamicSupervisors - allow many children without cascade failures
strategy: :one_for_one
max_restarts: 10  # Higher limit for dynamic components
```

## Process Discovery with Registry

All EtherCAT processes register themselves in `EtherCAT.Registry` for reliable discovery.

### Registration Keys

```elixir
# Master processes
{:master, master_index}

# Domain processes
{:domain, master_pid, domain_name}

# Slave processes
{:slave, master_pid, position}
```

### Usage Example

```elixir
# Find a master by index
case Registry.lookup(EtherCAT.Registry, {:master, 0}) do
  [{pid, _metadata}] -> {:ok, pid}
  [] -> {:error, :not_found}
end

# Find all slaves for a master
Registry.select(EtherCAT.Registry, [
  {{{:slave, master_pid, :_}, :_, :_}, [], [:"$_"]}
])
```

### Benefits

1. **No Name Collisions**: Multiple masters can coexist
2. **Automatic Cleanup**: Registry entries are removed on process death
3. **Metadata Storage**: Store additional info with each registration
4. **Pattern Matching**: Query processes using pattern matching

## Child Specifications

All processes provide proper child specifications for supervision.

### Master Child Spec

```elixir
defmodule MyApp.Application do
  def start(_type, _args) do
    children = [
      # Start master under application supervision
      {EtherCAT.Master, master_index: 0, update_interval: 1_000}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

### Domain Child Spec

```elixir
# Domains are typically started by the Master
# But can be manually started under a supervisor if needed
domain_spec = %{
  name: :my_domain,
  master: master_pid,
  resource: domain_ref,
  interval: 1
}

DynamicSupervisor.start_child(EtherCAT.DomainSupervisor, domain_spec)
```

### Slave Child Spec

```elixir
# Slaves are started by the Master during sync_slaves
# They're automatically supervised by EtherCAT.SlaveSupervisor
```

## Error Handling

The library implements defensive error handling throughout.

### Try-Rescue for NIF Calls

```elixir
def offline({:call, from}, :connect, data) do
  try do
    master_state = Nif.get_master_state(data.master_ref)
    # ... handle success
  rescue
    error ->
      Logger.error("Error connecting master: #{inspect(error)}")
      {:keep_state_and_data, [{:reply, from, {:error, :nif_error}}]}
  end
end
```

### EXIT Message Handling

The Master traps exits and handles child process failures:

```elixir
Process.flag(:trap_exit, true)

def handle_exit(pid, reason, state, data) do
  cond do
    pid == data.task_pid ->
      # Cyclic task crashed - transition to offline
      {:next_state, :offline, %{data | task_pid: nil}}

    pid in data.domains ->
      # Domain crashed - supervisor will restart it
      {:keep_state, %{data | domains: List.delete(data.domains, pid)}}

    # ... other cases
  end
end
```

### Graceful Degradation

When errors occur, the system degrades gracefully:

- NIF errors don't crash the process
- Child failures are logged and handled
- State machine prevents invalid operations
- Timeouts prevent indefinite blocking

## Graceful Termination

All processes implement proper cleanup in terminate callbacks.

### Master Termination

```elixir
def terminate(reason, _state, data) do
  Logger.info("EtherCAT Master terminating: #{inspect(reason)}")

  # Stop cyclic task
  if data.task_pid && Process.alive?(data.task_pid) do
    Process.exit(data.task_pid, :shutdown)
  end

  # Terminate all children
  Enum.each(data.slaves, &terminate_child/1)
  Enum.each(data.domains, &terminate_child/1)

  :ok
end
```

### Domain Termination

```elixir
def terminate(reason, state) do
  # Notify subscribers of shutdown
  Enum.each(state.subscribers, fn {_name, pids} ->
    Enum.each(pids, fn pid ->
      send(pid, {:domain_shutdown, self()})
    end)
  end)

  :ok
end
```

### Slave Termination

```elixir
def terminate(reason, state) do
  # Call driver cleanup
  state.driver.terminate(state.driver_state)
  :ok
end
```

## Timeouts

All synchronous operations have configurable timeouts to prevent deadlocks.

### GenServer/GenStatem Calls

```elixir
# Default timeout: 5 seconds for most operations
def connect(master, timeout \\ 5000) do
  :gen_statem.call(master, :connect, timeout)
end

# Longer timeout for expensive operations
def sync_slaves(master, timeout \\ 10_000) do
  :gen_statem.call(master, :sync_slaves, timeout)
end
```

### State Timeouts

```elixir
def stale(:enter, _old_state, data) do
  # Set state timeout for periodic updates
  actions = [{:state_timeout, data.update_interval, :update_master_state}]
  {:keep_state_and_data, actions}
end

def stale(:state_timeout, :update_master_state, data) do
  # Check master state periodically
  master_state = Nif.get_master_state(data.master_ref)
  # ... handle state update
end
```

### Why Timeouts Matter

1. **Prevent Deadlocks**: Calls won't hang forever
2. **Resource Management**: Free up resources quickly
3. **Error Detection**: Identify slow or stuck operations
4. **User Experience**: Provide timely feedback

## State Machine Patterns

The Master uses GenStatem with state functions for clear state management.

### Callback Mode

```elixir
def callback_mode(), do: [:state_functions, :state_enter]
```

Benefits:
- **state_functions**: Each state is a separate function
- **state_enter**: Automatic callbacks on state entry

### State Function Pattern

```elixir
def state_name(:enter, _old_state, data) do
  # Called when entering this state
  # Initialize state-specific resources
  :keep_state_and_data
end

def state_name({:call, from}, :event, data) do
  # Handle synchronous events
  {:next_state, :new_state, new_data, [{:reply, from, :ok}]}
end

def state_name(:info, {:EXIT, pid, reason}, data) do
  # Handle process exits
  handle_exit(pid, reason, :state_name, data)
end

def state_name(event_type, event_content, data) do
  # Catch-all for unexpected events
  handle_unexpected(event_type, event_content, :state_name, data)
end
```

### State Transition Guards

Prevent invalid operations in wrong states:

```elixir
def offline({:call, from}, :activate, _data) do
  # Can't activate while offline
  {:keep_state_and_data, [{:reply, from, {:error, :offline}}]}
end
```

## Telemetry Integration

Comprehensive telemetry for observability.

### Event Emission

```elixir
def offline(:enter, _old_state, _data) do
  :telemetry.execute([:ethercat, :master, :state], %{}, %{state: :offline})
  :keep_state_and_data
end

def connect(master, timeout) do
  start_time = System.monotonic_time()

  result = :gen_statem.call(master, :connect, timeout)

  duration = System.monotonic_time() - start_time
  :telemetry.execute(
    [:ethercat, :master, :connect],
    %{duration: duration},
    %{result: result}
  )

  result
end
```

### Metrics

Track:
- State transitions
- Operation durations
- Error rates
- Resource counts (slaves, domains)
- Termination reasons

See [TELEMETRY.md](TELEMETRY.md) for complete event reference.

## Best Practices Summary

### DO

✅ Use supervision trees for all processes
✅ Register processes in Registry for discovery
✅ Provide child_spec/1 for all supervisable modules
✅ Trap exits in processes that manage children
✅ Implement terminate/2 for cleanup
✅ Add timeouts to all synchronous calls
✅ Use try-rescue around NIF calls
✅ Emit telemetry events for observability
✅ Log important state changes and errors
✅ Use state machines for complex lifecycle management

### DON'T

❌ Create unsupervised processes
❌ Rely on process names for discovery
❌ Ignore error cases from NIFs
❌ Block indefinitely without timeouts
❌ Swallow errors silently
❌ Mix supervision with business logic
❌ Create deep supervisor hierarchies
❌ Use atoms for dynamic process names
❌ Forget to clean up resources in terminate
❌ Make synchronous calls to children in terminate

## Migration Guide

If upgrading from an earlier version without these OTP patterns:

### 1. Update Dependencies

```elixir
# mix.exs
def deps do
  [
    {:zigler, "~> 0.15", runtime: false},
    {:telemetry, "~> 1.2"}  # Add this
  ]
end
```

### 2. Optional: Start Master Under Supervision

Before:
```elixir
{:ok, master} = EtherCAT.Master.start_link()
```

After (optional):
```elixir
# Add to your application supervision tree
children = [
  {EtherCAT.Master, master_index: 0, name: MyApp.EtherCATMaster}
]
```

### 3. Add Telemetry Handlers

```elixir
def start(_type, _args) do
  # Attach telemetry before starting components
  :telemetry.attach_many(
    "my-app-ethercat",
    [
      [:ethercat, :master, :state],
      [:ethercat, :master, :connect],
      # ... more events
    ],
    &handle_telemetry/4,
    nil
  )

  # Start supervision tree
  Supervisor.start_link(children, strategy: :one_for_one)
end
```

### 4. Use Registry for Process Discovery

Before:
```elixir
GenServer.call(EtherCAT.Master, :some_operation)
```

After:
```elixir
case Registry.lookup(EtherCAT.Registry, {:master, 0}) do
  [{pid, _}] -> GenServer.call(pid, :some_operation)
  [] -> {:error, :master_not_found}
end
```

## References

- [Elixir Supervisor Documentation](https://hexdocs.pm/elixir/Supervisor.html)
- [DynamicSupervisor Documentation](https://hexdocs.pm/elixir/DynamicSupervisor.html)
- [Registry Documentation](https://hexdocs.pm/elixir/Registry.html)
- [GenStateMachine Documentation](https://hexdocs.pm/gen_state_machine/)
- [Telemetry Documentation](https://hexdocs.pm/telemetry/)
- [OTP Design Principles](https://erlang.org/doc/design_principles/des_princ.html)
