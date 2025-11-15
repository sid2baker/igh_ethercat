# EtherCAT Master Refactor Summary

## Overview

Major simplification of the EtherCAT library architecture:
- **Removed:** Domain.ex, Slave.ex (wrapper), old Driver behaviour
- **Added:** Master2 (gen_statem), new Driver behaviour (processes), Generic2 driver
- **Simplified:** Domains are MapSets in Master, Drivers ARE the slaves

## Key Changes

### 1. Driver Behaviour Redesigned

**Old Pattern** (Drivers were modules):
```elixir
defmodule EtherCAT.Drivers.EL3202 do
  use EtherCAT.Slave.Driver

  def configure(ctx, state, config), do: {:ok, state}
  def list_pdos(state), do: [:ch1, :ch2]
  def pdo_info(state, pdo_name), do: {:ok, pdo_info}
  def encode_value(state, pdo, entry, value), do: {:ok, binary}
  def decode_value(state, pdo, entry, binary), do: {:ok, value}
end
```

**New Pattern** (Drivers are GenServer processes):
```elixir
defmodule EtherCAT.Drivers.EL3202_v2 do
  use GenServer

  # Driver Behaviour callbacks
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def get_sdo_config(pid), do: GenServer.call(pid, :get_sdo_config)
  def get_pdo_config(pid), do: GenServer.call(pid, :get_pdo_config)
  def read(pid, pdo, entry), do: GenServer.call(pid, {:read, pdo, entry})
  def write(pid, pdo, entry, value), do: GenServer.call(pid, {:write, pdo, entry, value})
  def subscribe(pid, pdo, entry, sub_pid), do: GenServer.call(pid, {:subscribe, pdo, entry, sub_pid})
  def unsubscribe(pid, pdo, entry, sub_pid), do: GenServer.call(pid, {:unsubscribe, pdo, entry, sub_pid})
end
```

### 2. Master Simplified with gen_statem

**State Machine:**
```
:offline ──connect──> :scanning ──discover──> :ready ──activate──> :operational
                                                  ↑                      │
                                                  └──────stop_cyclic─────┘
```

**State Structure:**
```elixir
%Master2{
  master_ref: reference(),
  slaves: %{position => %{pid, name, vendor, product, driver}},
  domains: %{domain_name => %{ref, interval}},  # Simplified!
  subscribers: %{{slave_name, pdo, entry} => [pids]},  # Moved from Domain
  hardware_config: map(),  # Expected configuration
  hardware_diff: map()     # Diff tree
}
```

### 3. Domain Removal

**Old:** Separate Domain processes
```elixir
{:ok, domain_pid} = Domain.start_link(master, :default, 1000)
Domain.register_pdo_entry(domain_pid, ...)
Domain.subscribe(domain_pid, pid, unique_name)
```

**New:** Domains are MapSets in Master2
```elixir
{:ok, domain_ref} = Master2.create_domain(:default, 1000)
# Domain is just %{ref, interval} in Master2 state
# Subscribers stored directly in Master2
Master2.subscribe(master, slave_name, pdo, entry, pid)
```

### 4. Subscriber Pattern Simplified

**Old:** Domain tracks subscribers per unique_name
```elixir
domain_state.subscribers: %{unique_name => MapSet.t(pid)}
```

**New:** Master tracks subscribers per {slave, pdo, entry}
```elixir
master_state.subscribers: %{{slave_name, pdo, entry} => [pid]}
```

**Benefits:**
- Natural semantic grouping
- No need to parse unique_names during subscription
- Easier to query "who's subscribed to this slave's PDO?"

### 5. Hardware Diff Tracking

Master2 tracks expected vs actual hardware configuration:

```elixir
diff_tree = %{
  type: :match | :mismatch | :partial_match,
  path: [:slave_0],
  changes: %{vendor_id: {expected, actual}},
  children: [nested_diffs]
}
```

Algorithm:
1. Match nodes by label (position, serial, etc.)
2. Compare attributes (vendor, product, etc.)
3. Recursively diff children
4. Mark as :match/:mismatch/:partial_match

## Architecture Comparison

### Old Architecture
```
Master (GenServer)
  ├─ Domain (GenServer) - :default_domain
  │   ├─ update_interval: 1000µs
  │   ├─ entries: %{unique_name => metadata}
  │   └─ subscribers: %{unique_name => [pids]}
  │
  └─ Slaves (gen_statem wrappers)
      ├─ Slave #0
      │   ├─ Driver: module (not a process)
      │   ├─ driver_state: map
      │   └─ entries: %{{pdo, entry} => metadata}
      │
      └─ Slave #1...
```

### New Architecture (Master2)
```
Master2 (gen_statem)
  ├─ domains: %{:default_domain => %{ref, interval}}
  ├─ slaves: %{0 => %{pid, name, vendor, product}}
  ├─ subscribers: %{{:slave_0, :ch1, :value} => [pids]}
  └─ hardware_diff: tree

  Drivers (GenServers) - slaves ARE drivers
    ├─ Generic2 #0 (pid from slaves map)
    ├─ EL3202_v2 #1
    └─ ...
```

## Data Flow

### Configuration (Startup)
```
Master2 starts
  ↓
:offline → :scanning (discover slaves)
  ↓
For each slave:
  Master2.start_slave_driver/2
    ↓
  Driver.start_link/1
    ↓
  Driver registers in Registry
    ↓
  Driver auto-discovers PDOs (Generic2)
  ↓
:scanning → :ready
```

### PDO Registration (Before Cyclic)
```
Master2.start_cyclic/2
  ↓
Master2.configure_all_slaves/1
  ↓
For each slave:
  Driver.get_sdo_config/1 → write SDOs via NIF
  Driver.get_pdo_config/1 → configure SM/PDO via NIF
  Register entries to domains via NIF
  ↓
Nif.master_activate/1
  ↓
Spawn cyclic task
  ↓
:ready → :operational
```

### Runtime Read
```
Application
  ↓
Driver.read(pid, :ch1, :value)
  ↓
Master2.read_pdo_entry(:default_domain, "slave_0:ch1:value")
  ↓
Nif.get_value(domain_ref, unique_name)
  ↓
Driver decodes binary
  ↓
Application receives decoded value
```

### Runtime Subscribe/Notify
```
Driver.subscribe(pid, :ch1, :value, subscriber_pid)
  ↓
Master2.subscribe(:slave_0, :ch1, :value, subscriber_pid)
  ↓
Master2 stores in subscribers map
  ↓
(Cyclic task detects change...)
  ↓
NIF sends {:data_changed, "slave_0:ch1:value", binary} to Master2
  ↓
Master2 parses unique_name → {:slave_0, :ch1, :value}
  ↓
Master2 looks up subscribers[{:slave_0, :ch1, :value}]
  ↓
Master2 sends {:pdo_value_changed, :slave_0, :ch1, :value, decoded} to each subscriber
```

## File Changes

### Removed
- `lib/ethercat/domain.ex` - Functionality moved to Master2
- (To remove: `lib/ethercat/slave.ex` - Replaced by drivers being processes)
- (To remove: `lib/ethercat/master.ex` - Replaced by Master2)

### Added
- `lib/ethercat/master2.ex` - Simplified master with gen_statem
- `lib/ethercat/drivers/generic2.ex` - Example driver process
- `lib/ethercat/slave/driver.ex` - Updated behaviour definition

### Modified
- `lib/ethercat/slave/driver.ex` - New behaviour: processes with callbacks

## Migration Path

### Option A: Big Swap (Recommended)
1. Ensure all tests pass with old architecture
2. Rename: `Master → MasterOld`, `Slave → SlaveOld`, `Domain → DomainOld`
3. Rename: `Master2 → Master`, `Generic2 → Generic`
4. Update all driver implementations
5. Update tests
6. Remove old files

### Option B: Gradual (Safer but longer)
1. Run both systems side-by-side
2. Migrate drivers one by one
3. Migrate tests incrementally
4. Deprecate old system
5. Remove old files

## Benefits of New Architecture

1. **Simpler state management** - Fewer processes, less message passing
2. **Clear state machine** - gen_statem makes Master states explicit
3. **Drivers own behavior** - Driver processes can have complex internal state machines
4. **Direct I/O routing** - No Domain intermediary for read/write
5. **Semantic subscriptions** - Subscribe by {slave, pdo, entry}, not opaque unique_names
6. **Hardware tracking** - Built-in diff between expected and actual
7. **Fewer abstractions** - Domain is just a reference, not a full process

## Performance Implications

**Potential improvements:**
- Fewer processes (no Domain processes)
- Fewer message hops for I/O (Driver → Master2 → NIF vs Driver → Slave → Domain → NIF)
- Less bookkeeping (single subscribers map in Master2)

**Potential concerns:**
- Master2 state size grows with subscribers (but no worse than old Domain state)
- Single gen_statem handles all calls (but should be fast, non-blocking)

## Testing Strategy

1. **Unit tests for Master2** - Mock NIF, test state transitions
2. **Driver tests** - Test Generic2, EL3202_v2 encode/decode
3. **Integration tests** - Full flow from startup to cyclic I/O
4. **Hardware validation** - Real EtherCAT network

## Next Steps

1. ✅ Implement PDO registration logic
2. ✅ Update Generic2 for new subscribe API
3. ✅ Document NIF requirements
4. **TODO:** Convert one real driver (EL3202 → EL3202_v2)
5. **TODO:** Create integration test
6. **TODO:** Perform the swap (Master2 → Master)
7. **TODO:** Update remaining drivers
8. **TODO:** Update all tests

## Questions for Review

1. Should slave names be `:slave_0` or support custom names?
2. Should we add alias/name support during driver start_link?
3. Hardware diff: when to trigger re-computation?
4. NIF optimizations: batch vs individual calls?
5. Error handling: what happens if PDO registration fails mid-slave?

## Conclusion

This refactor **dramatically simplifies** the architecture while maintaining all functionality:

- **-3 core modules** (Domain, Slave wrapper, old Driver)
- **+1 gen_statem** (Master2 with clear states)
- **New pattern:** Drivers are processes (more flexible, cleaner separation)
- **Simpler domains:** Just ref + interval
- **Better tracking:** Hardware diff, semantic subscriptions

The code is **cleaner, easier to understand, and easier to maintain**.
