# OTP Patterns

Core OTP patterns for maintainers.

## Supervision Architecture

```
EtherCAT.Supervisor (one_for_one)
  └─ EtherCAT.Registry

EtherCAT.Master (standalone/supervised)
  ├─ Domains (linked)
  └─ Slaves (linked)
```

### Why Linking Instead of Supervision?

Slaves and Domains are **tightly coupled** to Master's NIF resources:

1. **NIF Lifecycle**: `domain_ref` and `slave_config` only valid while Master's `master_ref` exists
2. **Hardware Dependency**: Network connection owned by Master
3. **No Orphans**: Invalid NIF resources = useless processes
4. **Predictable**: Master dies → everything dies → clean restart

**DynamicSupervisor would break this**: Restarted children would have dead NIF references, causing silent failures.

### Failure Handling

- **Slave crashes**: Master receives EXIT, logs, removes from list
- **Domain crashes**: Master receives EXIT, logs, notifies subscribers
- **Master crashes**: All children die (correct), supervisor restarts if configured

## Registry-Based Discovery

All processes register in `EtherCAT.Registry` with composite keys:

```elixir
{:master, master_index}                # Master by index
{:domain, master_pid, domain_name}     # Domain scoped to master
{:slave, master_pid, position}         # Slave scoped to master
```

**Benefits:**
- No name collisions between masters
- Automatic cleanup on death
- Pattern matching queries

```elixir
# Lookup domain
Registry.lookup(EtherCAT.Registry, {:domain, master_pid, :default})

# Find all slaves for a master
Registry.select(EtherCAT.Registry, [
  {{{:slave, master_pid, :_}, :_, :_}, [], [:"$_"]}
])
```

## Error Handling

### NIF Call Protection

```elixir
try do
  Nif.some_operation(resource)
rescue
  error ->
    Logger.error("NIF error: #{inspect(error)}")
    {:error, :nif_error}
end
```

### EXIT Message Handling

Master traps exits:

```elixir
Process.flag(:trap_exit, true)

def handle_info({:EXIT, pid, reason}, state) do
  cond do
    pid == state.task_pid ->
      # Cyclic task died, transition to offline
      {:next_state, :offline, %{state | task_pid: nil}}

    pid in state.domains ->
      # Domain died, remove and continue
      {:keep_state, %{state | domains: List.delete(state.domains, pid)}}
  end
end
```

## Graceful Termination

All processes implement cleanup:

```elixir
def terminate(reason, state) do
  # Stop cyclic task
  if state.task_pid, do: Process.exit(state.task_pid, :shutdown)

  # Terminate children
  Enum.each(state.slaves ++ state.domains, &terminate_child/1)

  # Emit telemetry
  :telemetry.execute([:ethercat, :master, :terminate], %{}, %{reason: reason})

  :ok
end
```

## Timeouts

All sync operations have timeouts:

```elixir
def connect(master, timeout \\ 5_000) do
  :gen_statem.call(master, :connect, timeout)
end

def sync_slaves(master, timeout \\ 10_000) do
  :gen_statem.call(master, :sync_slaves, timeout)
end
```

**Why:** Prevents deadlocks, enables error detection, improves UX

## State Machine Pattern (GenStatem)

```elixir
def callback_mode(), do: [:state_functions, :state_enter]

# State entry
def offline(:enter, _old_state, data) do
  :telemetry.execute([:ethercat, :master, :state], %{}, %{state: :offline})
  :keep_state_and_data
end

# Event handling
def offline({:call, from}, :connect, data) do
  case try_connect(data) do
    :ok -> {:next_state, :stale, data, [{:reply, from, :ok}]}
    error -> {:keep_state_and_data, [{:reply, from, error}]}
  end
end

# Prevent invalid operations
def offline({:call, from}, :activate, _data) do
  {:keep_state_and_data, [{:reply, from, {:error, :offline}}]}
end

# Handle unexpected events
def offline(event_type, event, data) do
  Logger.warning("Unexpected #{event_type} in offline: #{inspect(event)}")
  :keep_state_and_data
end
```

## Telemetry Integration

Emit events for observability:

```elixir
# State transitions
def synced(:enter, _old_state, _data) do
  :telemetry.execute([:ethercat, :master, :state], %{}, %{state: :synced})
  :keep_state_and_data
end

# Operation metrics
def sync_slaves(master, timeout) do
  start = System.monotonic_time()
  result = :gen_statem.call(master, :sync_slaves, timeout)
  duration = System.monotonic_time() - start

  :telemetry.execute(
    [:ethercat, :master, :sync_slaves],
    %{duration: duration, count: length(result)},
    %{result: if(match?({:ok, _}, result), do: :success, else: :error)}
  )

  result
end
```

See [TELEMETRY.md](TELEMETRY.md) for complete event reference.

## Best Practices Checklist

### ✅ DO

- Use Registry for process discovery
- Trap exits in processes managing children
- Implement `terminate/2` for cleanup
- Add timeouts to all sync calls
- Wrap NIF calls in try-rescue
- Emit telemetry for operations
- Log state changes and errors
- Use GenStatem for complex lifecycle
- Provide `child_spec/1` for supervised processes

### ❌ DON'T

- Create unsupervised processes
- Rely on named processes for discovery
- Ignore NIF errors
- Block indefinitely without timeouts
- Swallow errors silently
- Mix supervision with business logic
- Create deep supervisor hierarchies
- Forget resource cleanup in terminate
- Make sync calls to children in terminate

## Child Process Lifecycle

```elixir
# Master starts children via simple linking
{:ok, slave_pid} = Slave.start_link(
  master: self(),
  position: position,
  slave_config: slave_config
)

{:ok, domain_pid} = Domain.start_link(
  master: self(),
  resource: domain_ref,
  name: name
)

# Both linked to Master - automatic cleanup on Master death
# Master receives EXIT messages on child death for handling
```

## References

- [Supervisor](https://hexdocs.pm/elixir/Supervisor.html)
- [Registry](https://hexdocs.pm/elixir/Registry.html)
- [GenStatem](https://hexdocs.pm/gen_state_machine/)
- [Telemetry](https://hexdocs.pm/telemetry/)
- [OTP Design Principles](https://erlang.org/doc/design_principles/des_princ.html)
