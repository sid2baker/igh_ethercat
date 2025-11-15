# Master2 Architecture - NIF Requirements

This document outlines the NIF functions required for the simplified Master2 architecture to work.

## Current NIF Functions Used by Master2

### Master Management
- `Nif.request_master/1` - Request EtherCAT master by index
- `Nif.get_master_state/1` - Get master state (link_up, slaves_responding, etc.)
- `Nif.master_activate/1` - Activate master for cyclic operation
- `Nif.master_get_slave/2` - Get slave info by position
- `Nif.master_slave_config/4` - Create slave configuration

### Domain Management
- `Nif.master_create_domain/3` - Create domain with interval
- `Nif.domain_set_pid/2` - Set PID for domain callbacks
- `Nif.get_value/2` - Read PDO entry value from domain
- `Nif.set_value/3` - Write PDO entry value to domain

### Slave Configuration (SDO/PDO)
- `Nif.slave_config_sdo/4` - Configure SDO value
- `Nif.slave_config_sync_manager/4` - Configure sync manager
- `Nif.slave_config_pdo_assign_clear/2` - Clear PDO assignments
- `Nif.slave_config_pdo_assign_add/3` - Add PDO assignment
- `Nif.slave_config_pdo_mapping_clear/2` - Clear PDO mappings
- `Nif.slave_config_pdo_mapping_add/5` - Add PDO entry mapping
- `Nif.slave_config_reg_pdo_entry/7` - Register PDO entry to domain

### PDO Discovery (for Generic driver)
- `Nif.master_get_sync_manager/3` - Get sync manager info
- `Nif.master_get_pdo/4` - Get PDO info
- `Nif.master_get_pdo_entry/5` - Get PDO entry info

### Cyclic Task
- `Nif.cyclic_task/5` - Run cyclic task in background thread

## Simplified NIF Interface (Proposed Changes)

The current NIF interface works well, but here are potential simplifications:

### 1. **Consolidate Domain Operations**

Current:
```elixir
{:ok, ref} = Nif.master_create_domain(master_ref, pid, interval)
:ok = Nif.domain_set_pid(ref, pid)
```

Proposed:
```elixir
{:ok, ref} = Nif.master_create_domain(master_ref, pid, interval)
# Automatically sets PID during creation
```

### 2. **Batch PDO Registration**

Current:
```elixir
# One call per entry
offset1 = Nif.slave_config_reg_pdo_entry(slave_config, "name1", ...)
offset2 = Nif.slave_config_reg_pdo_entry(slave_config, "name2", ...)
```

Proposed:
```elixir
# Register multiple entries at once
offsets = Nif.slave_config_reg_pdo_entries(slave_config, [
  %{name: "name1", index: 0x6000, subindex: 1, bit_length: 16},
  %{name: "name2", index: 0x6000, subindex: 2, bit_length: 16}
], domain_ref, direction)
```

### 3. **Unified Slave Configuration**

Current - multiple separate calls:
```elixir
Nif.slave_config_sync_manager(...)
Nif.slave_config_pdo_assign_clear(...)
Nif.slave_config_pdo_assign_add(...)
Nif.slave_config_pdo_mapping_clear(...)
Nif.slave_config_pdo_mapping_add(...)
```

Proposed - single call with complete config:
```elixir
Nif.slave_config_pdos(slave_config, %{
  sync_managers: [
    %{index: 3, direction: :input, watchdog: :default}
  ],
  pdo_assignments: [
    %{sm_index: 3, pdo_index: 0x1A00}
  ],
  pdo_mappings: [
    %{pdo_index: 0x1A00, entries: [
      {0x6000, 1, 16},
      {0x6000, 2, 16}
    ]}
  ]
})
```

### 4. **Data Change Notifications**

Current behavior (needs verification):
```elixir
# NIF sends message to Master2 process
{:data_changed, unique_name, binary_value}
```

This works well! Master2 parses unique_name and routes to subscribers.

## Master2 Data Flow

### Configuration Flow
```
Driver.get_sdo_config/1
  ↓
Master2.configure_single_slave/3
  ↓
Nif.slave_config_sdo/4
  ↓
Driver.get_pdo_config/1
  ↓
Master2.configure_sync_manager/4
  ↓
Nif.slave_config_sync_manager/4
Nif.slave_config_pdo_assign_*/N
Nif.slave_config_pdo_mapping_*/N
  ↓
Master2.register_pdo_to_domain/5
  ↓
Nif.slave_config_reg_pdo_entry/7
```

### Runtime I/O Flow
```
Driver.read/3
  ↓
Master2.read_pdo_entry/3
  ↓
Nif.get_value/2 (domain_ref, unique_name)
  ↓
Driver decodes binary
  ↓
Application gets value
```

```
Driver.write/4
  ↓
Driver encodes value to binary
  ↓
Master2.write_pdo_entry/4
  ↓
Nif.set_value/3 (domain_ref, unique_name, binary)
  ↓
NIF writes to hardware
```

### Subscribe/Notify Flow
```
Driver.subscribe/4
  ↓
Master2.subscribe/5 (slave_name, pdo, entry, pid)
  ↓
Master2 stores in subscribers map
  ↓
(Cyclic task running...)
  ↓
NIF detects value change
  ↓
NIF sends {:data_changed, unique_name, value} to Master2
  ↓
Master2 parses unique_name → {slave_name, pdo, entry}
  ↓
Master2 looks up subscribers for key
  ↓
Master2 sends {:pdo_value_changed, slave_name, pdo, entry, value} to each subscriber
```

## Minimal Changes Needed

**The current NIF interface works well for Master2!**

Only **optional** improvements:
1. Auto-set PID during `master_create_domain` (minor convenience)
2. Batch registration functions (performance optimization for large configs)
3. Unified configuration function (reduce call count, but more complex)

**Bottom line:** Master2 can work with the existing NIF interface. The simplifications above are nice-to-have optimizations, not requirements.

## Key Architectural Decisions

1. **Domains are lightweight** - Just ref + interval in Master2 state
2. **Subscribers tracked in Master2** - `%{{slave_name, pdo, entry} => [pids]}`
3. **Unique names encode identity** - Format: `"slave_name:pdo_name:entry_name"`
4. **Drivers are GenServers** - Handle encoding/decoding, call Master2 for I/O
5. **Master2 is gen_statem** - Clear state transitions (offline → scanning → ready → operational)

## Testing Strategy

To validate Master2 + Generic2 architecture:

1. **Unit test** - Mock NIF, test state transitions
2. **Integration test** - Use loopback/virtual master if available
3. **Hardware test** - Real EtherCAT network with Generic2 driver

Example test flow:
```elixir
# Start Master2
{:ok, _master} = Master2.start_link(master_index: 0)

# Create domain
{:ok, _domain_ref} = Master2.create_domain(:default_domain, 1000)

# Wait for scanning → ready
# (slaves auto-discovered and configured)

# Get slave PIDs
{:ok, [slave_pid | _]} = Master2.get_slaves()

# Read PDO value through driver
{:ok, value} = Generic2.read(slave_pid, :"0x1a00", :"0x6000:11")

# Subscribe to changes
:ok = Generic2.subscribe(slave_pid, :"0x1a00", :"0x6000:11", self())

# Start cyclic mode
:ok = Master2.start_cyclic(1000, 100)

# Receive notifications
receive do
  {:pdo_value_changed, :slave_0, :"0x1a00", :"0x6000:11", new_value} ->
    IO.puts("Value changed: #{new_value}")
end
```
