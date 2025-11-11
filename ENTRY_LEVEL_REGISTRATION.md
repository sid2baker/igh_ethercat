# Entry-Level PDO Registration

## Overview

The refactored `EtherCAT.Slave` module now supports **two levels of registration granularity**:

1. **Entry-Level (Granular)** - Register only specific PDO entries you need
2. **PDO-Level (Convenient)** - Register all entries in a PDO at once

This provides flexibility to optimize memory and performance by registering only the data you actually use.

## Semantic Slave Naming

Slaves can now be assigned **semantic names** for more readable unique identifiers:

```elixir
# Without names (default):
# unique_name = "s0:ch1:value"

# With semantic names:
EtherCAT.set_slave_name(slave, :temp_sensor_1)
# unique_name = "temp_sensor_1:ch1:value"
```

This makes logs, debugging, and code much more readable in systems with multiple slaves.

## State Machine

The Slave module now uses `gen_statem` with explicit states:

```
:unconfigured (created, driver loaded)
    │ configure/2
    ▼
:configured (driver configured, ready for registration)
    │ lock/1 (called by Master on activation)
    ▼
:operational (locked, no changes allowed)
```

## API Comparison

### Before (PDO-Level Only)

```elixir
# You had to register ALL entries in a PDO
{:ok, master, [slave]} = EtherCAT.open(index: 0)
:ok = EtherCAT.configure_slave(slave, %{})

# Registers ALL 6 entries from :ch1 (underrange, overrange, limit1, limit2, error, value)
{:ok, handles} = EtherCAT.register_pdos(master, slave, [:ch1])
# Returns 6 handles even though you only want the temperature value!
```

### After (Entry-Level + PDO-Level)

```elixir
{:ok, master, [slave]} = EtherCAT.open(index: 0)
:ok = EtherCAT.configure_slave(slave, %{})

# Option 1: Register only specific entries (NEW!)
{:ok, temp} = EtherCAT.register_entry(master, slave, :ch1, :value)
{:ok, error} = EtherCAT.register_entry(master, slave, :ch1, :error)

# Option 2: Register multiple entries at once (NEW!)
{:ok, [temp, error]} = EtherCAT.register_entries(master, slave, [
  {:ch1, :value},
  {:ch1, :error}
])

# Option 3: Register all entries (EXISTING, still works!)
{:ok, all_handles} = EtherCAT.register_pdos(master, slave, [:ch1])
```

## Entry-Level Registration Examples

### Example 1: Minimal Registration

```elixir
# EL3202 Temperature Sensor - Register only temperature values, skip error flags

{:ok, master, [slave]} = EtherCAT.open(index: 0)

# Optional: Set semantic name for better readability
EtherCAT.set_slave_name(slave, :temp_sensor)

{:ok, _pdos} = EtherCAT.configure_slave(slave, %{})

# Register only the temperature values from both channels
# unique_name will be "temp_sensor:ch1:value" (or "s0:ch1:value" without naming)
{:ok, temp1} = EtherCAT.register_entry(master, slave, :ch1, :value)
{:ok, temp2} = EtherCAT.register_entry(master, slave, :ch2, :value)

EtherCAT.start_cyclic(master)

# Read temperatures
{:ok, t1} = EtherCAT.read(temp1)
{:ok, t2} = EtherCAT.read(temp2)
IO.puts("Ch1: #{t1}, Ch2: #{t2}")
```

### Example 2: Selective Monitoring

```elixir
# Register value + error flag, skip other diagnostic bits

{:ok, [temp, err]} = EtherCAT.register_entries(master, slave, [
  {:ch1, :value},
  {:ch1, :error}
])

EtherCAT.start_cyclic(master)

# Watch for changes
EtherCAT.watch(temp)
EtherCAT.watch(err)

receive do
  {:data_changed, _name, value} when is_integer(value) ->
    IO.puts("Temperature: #{value}")
  {:data_changed, _name, true} ->
    IO.puts("ERROR: Sensor fault!")
end
```

### Example 3: Multi-Rate Control with Different Domains

```elixir
# Device with outputs (SM2) and inputs (SM3)
# Different sync managers can use different domains (and even entries
# from the SAME sync manager can use different domains!)

{:ok, master, [slave]} = EtherCAT.open(index: 0)
{:ok, _} = EtherCAT.create_domain(master, :fast_outputs, 1)
{:ok, _} = EtherCAT.create_domain(master, :slow_inputs, 10)
{:ok, _pdos} = EtherCAT.configure_slave(slave, %{})

# Outputs (SM2) to fast domain (1x base rate)
{:ok, cmd} = EtherCAT.register_entry(master, slave, :output1, :command, :fast_outputs)

# Inputs (SM3) to slow domain (10x base rate)
{:ok, status} = EtherCAT.register_entry(master, slave, :input1, :status, :slow_inputs)

EtherCAT.start_cyclic(master)
```

### Example 4: Multiple Slaves with Semantic Names

```elixir
# Multi-slave system with readable names

{:ok, master, [slave1, slave2, slave3]} = EtherCAT.open(index: 0)

# Assign semantic names to each slave
EtherCAT.set_slave_name(slave1, :reactor_temp)
EtherCAT.set_slave_name(slave2, :coolant_flow)
EtherCAT.set_slave_name(slave3, :pressure_vessel)

# Configure all slaves
Enum.each([slave1, slave2, slave3], fn slave ->
  EtherCAT.configure_slave(slave, %{})
end)

# Register specific entries with semantic names
{:ok, temp} = EtherCAT.register_entry(master, slave1, :ch1, :value)
# unique_name = "reactor_temp:ch1:value"

{:ok, flow} = EtherCAT.register_entry(master, slave2, :sensor, :rate)
# unique_name = "coolant_flow:sensor:rate"

{:ok, pressure} = EtherCAT.register_entry(master, slave3, :gauge, :value)
# unique_name = "pressure_vessel:gauge:value"

EtherCAT.start_cyclic(master)

# Watch for changes - logs will show readable names
EtherCAT.watch(temp)
EtherCAT.watch(flow)
EtherCAT.watch(pressure)

receive do
  {:data_changed, "reactor_temp:ch1:value", val} ->
    IO.puts("Reactor temperature: #{val}°C")
  {:data_changed, "coolant_flow:sensor:rate", val} ->
    IO.puts("Coolant flow rate: #{val} L/min")
  {:data_changed, "pressure_vessel:gauge:value", val} ->
    IO.puts("Vessel pressure: #{val} bar")
end
```

### Example 5: Multi-Rate Control with Same Sync Manager

```elixir
# ✅ VALID: Entries from the same sync manager can go to different domains!
# Each domain creates its own FMMU for independent access.

# Fast control loop (1ms) - critical position data
{:ok, pos} = EtherCAT.register_entry(master, slave, :ch1, :value, :fast)

# Slow monitoring (10ms) - diagnostic data from same sync manager
{:ok, diag} = EtherCAT.register_entry(master, slave, :ch2, :value, :slow)

# Both :ch1 and :ch2 are in SM3, but can use different domains.
# The IgH Master creates one FMMU per domain for this sync manager.
```

## Multi-Domain Registration and FMMUs

**Key Insight:** Entries from the same sync manager CAN be registered to different domains!

### How It Works

When you register entries from a sync manager to different domains, the IgH EtherCAT Master:

1. Creates one **FMMU (Fieldbus Memory Management Unit)** per domain
2. Each FMMU independently maps the **same sync manager memory** to its domain's process data image
3. This enables multi-rate control: critical data updates fast, diagnostic data updates slowly

**Reference:** IgH EtherCAT Master documentation states "each domain occupies one FMMU in each slave involved"

### FMMU Limit

The only constraint is the **number of available FMMUs** per slave:
- Typical slaves have 8-16 FMMUs
- One FMMU is consumed per (domain × slave) combination
- Example: 3 domains × 1 slave = 3 FMMUs used

### How to Know Which Entries Share a Sync Manager?

```elixir
# Check driver's PDO info
{:ok, pdo_info} = driver.pdo_info(state, :ch1)
{sync_index, direction, watchdog} = pdo_info.sync_manager
# All entries in this PDO use the same sync manager (sync_index)

# Example EL3202:
# :ch1 → SM3 (inputs)
# :ch2 → SM3 (inputs)
# Both CAN use different domains - each gets its own FMMU!
```

### Valid Domain Assignments

| Scenario | Valid? | Reason |
|----------|--------|--------|
| `:ch1:value` → `:fast`, `:ch1:error` → `:fast` | ✅ Yes | Same PDO, same SM, same domain |
| `:ch1:value` → `:fast`, `:ch2:value` → `:fast` | ✅ Yes | Different PDOs, same SM3, same domain |
| `:ch1:value` → `:fast`, `:ch2:value` → `:slow` | ✅ **YES!** | Different PDOs, same SM3, **different domains** (uses 2 FMMUs) |
| `:output1` (SM2) → `:fast`, `:input1` (SM3) → `:slow` | ✅ Yes | **Different SMs**, can use different domains |

## API Reference

### `EtherCAT.register_entry/5`

Registers a single PDO entry.

**Parameters:**
- `master` - Master process PID
- `slave` - Slave process PID
- `pdo_name` - PDO identifier (e.g., `:ch1`)
- `entry_name` - Entry identifier (e.g., `:value`, `:error`)
- `domain` - Domain name (default: `:default_domain`)

**Returns:**
- `{:ok, handle}` - PDO handle for read/write/watch
- `{:error, reason}` - Error if registration fails

**Errors:**
- `{:invalid_state, :unconfigured, msg}` - Must call `configure/2` first
- `{:entry_not_found, entry_name, msg}` - Entry doesn't exist in PDO
- `{:slave_operational, msg}` - Cannot register after master activation
- `{:error, :domain_not_found}` - Specified domain doesn't exist

### `EtherCAT.register_entries/4`

Registers multiple PDO entries in one call.

**Parameters:**
- `master` - Master process PID
- `slave` - Slave process PID
- `entries` - List of `{pdo, entry}` or `{pdo, entry, domain}` tuples
- `default_domain` - Domain for entries without explicit domain

**Returns:**
- `{:ok, [handle]}` - List of PDO handles
- `{:error, reason}` - Error if any registration fails (transactional)

### `EtherCAT.register_pdos/4`

Registers all entries in PDOs (convenience wrapper).

**Parameters:**
- `master` - Master process PID
- `slave` - Slave process PID
- `pdo_names` - List of PDO names
- `domain` - Domain name (default: `:default_domain`)

**Returns:**
- `{:ok, [handle]}` - List of handles for ALL entries in ALL PDOs
- `{:error, reason}` - Error if any registration fails

## Slave Module Functions

Direct access via `EtherCAT.Slave` module:

```elixir
# State queries
Slave.get_state(slave)  # Returns :unconfigured | :configured | :operational

# Registration
Slave.register_entry(slave, :ch1, :value, :fast_domain)
Slave.register_entries(slave, [{:ch1, :value}, {:ch1, :error}])
Slave.register_pdo(slave, :ch1, :default_domain)
Slave.register_all_pdos(slave, :default_domain)

# Configuration
Slave.configure(slave, %{option: value})
Slave.config_sdo(slave, 0x8000, 0x13, <<180::little-signed-16>>)

# Introspection
Slave.list_pdos(slave)
Slave.get_sync_manager(slave, 3)
Slave.get_pdo(slave, 3, 0)
Slave.get_pdo_entry(slave, 3, 0, 1)
```

## Migration Guide

### Updating Existing Code

Old code using `register_pdos/4` continues to work unchanged:

```elixir
# This still works exactly as before
{:ok, handles} = EtherCAT.register_pdos(master, slave, [:ch1, :ch2])
```

To optimize for entry-level registration:

```diff
  # Before: Register all 12 entries
- {:ok, handles} = EtherCAT.register_pdos(master, slave, [:ch1, :ch2])
- [_, _, _, _, _, temp1, _, _, _, _, _, temp2] = handles

  # After: Register only what you need
+ {:ok, [temp1, temp2]} = EtherCAT.register_entries(master, slave, [
+   {:ch1, :value},
+   {:ch2, :value}
+ ])
```

## Benefits

### Memory Efficiency
- **Before:** Registering `:ch1` PDO → 6 entries × 2 bytes = 12 bytes + overhead
- **After:** Registering `:ch1:value` entry → 1 entry × 2 bytes = 2 bytes + overhead
- **Savings:** 83% reduction for this example

### Performance
- Fewer PDO entries registered → smaller domain buffer
- Smaller domain buffer → faster cyclic processing
- Less data to check for changes → more efficient change detection

### Clarity
- Code explicitly shows which data you're using
- Easier to understand I/O requirements
- Better self-documenting code

## Implementation Details

### Incremental Configuration

The refactored implementation performs configuration incrementally:

1. **First entry from a sync manager:**
   - Configure sync manager (direction, watchdog)
   - Mark sync manager as configured

2. **First entry from a PDO:**
   - Add PDO to sync manager's assignment list

3. **Each entry:**
   - Add entry to PDO mapping
   - Register entry with domain

### Tracking Structures

```elixir
%Slave{
  # Tracks which entries are registered per PDO
  pdo_registrations: %{
    ch1: %{domain: :fast, entries: MapSet.new([:value, :error])}
  },

  # Tracks sync manager to domain mapping
  sync_manager_domains: %{
    3 => :fast_domain  # SM3 assigned to :fast_domain
  },

  # Tracks which sync managers have been configured
  configured_sync_managers: MapSet.new([3])
}
```

### State Machine Guards

All registration functions check current state:

- `:unconfigured` → Error: "Call configure/2 first"
- `:configured` → Allow registration
- `:operational` → Error: "Cannot modify after master activation"

## Testing

See `test/hardware/selective_pdo_test.exs` for comprehensive tests including:

- Entry-level registration
- PDO-level registration
- Sync manager domain validation
- State machine transitions
- Error handling

## Future Enhancements

Potential improvements:

1. **Batch registration optimization** - Single NIF call for multiple entries
2. **PDO entry iteration** - `Slave.list_entries(slave, :ch1)` to discover entries
3. **Runtime introspection** - Query which entries are registered
4. **Unregister support** - Remove entries before activation (complex, low priority)

## Questions?

See the main README.md for general EtherCAT usage or consult the module documentation:

```elixir
h EtherCAT.Slave
h EtherCAT.register_entry
h EtherCAT.register_entries
```
