# EtherCAT API Redesign - Before & After

## Overview

The EtherCAT module has been redesigned to provide a cleaner, more intuitive API while maintaining full access to lower-level functionality when needed.

## API Comparison

### Starting a Master

**Before:**
```elixir
{:ok, master} = EtherCAT.Master.start_link(update_interval: 1000)
```

**After:**
```elixir
{:ok, master} = EtherCAT.start_link(update_interval: 1000)
```

### Connecting to Network

**Before:**
```elixir
:ok = EtherCAT.Master.connect(master)
```

**After:**
```elixir
:ok = EtherCAT.connect(master)
```

### Discovering Slaves

**Before:**
```elixir
{:ok, slaves} = EtherCAT.Master.sync_slaves(master)
```

**After:**
```elixir
{:ok, slaves} = EtherCAT.list_slaves(master)  # More intuitive name
```

### Configuring Slaves

**Before:**
```elixir
EtherCAT.Slave.configure(slave, [])
EtherCAT.Slave.list_pdos(slave)
EtherCAT.Slave.register_all_pdos(slave, :default_domain)
```

**After:**
```elixir
EtherCAT.configure_slave(slave, [])
EtherCAT.list_pdos(slave)
EtherCAT.register_all_pdos(slave, :default_domain)
```

### Starting Cyclic Operation

**Before:**
```elixir
EtherCAT.Master.start_cyclic_mode(master)
```

**After:**
```elixir
EtherCAT.start_cyclic(master)
# OR
EtherCAT.activate(master)  # Alternative, more concise name
```

### Reading/Writing PDOs

**Before:**
```elixir
EtherCAT.Slave.set_pdo_value(slave, :output1, true)
{:ok, value} = EtherCAT.Slave.get_pdo_value(slave, :input1)
```

**After:**
```elixir
EtherCAT.set_pdo(slave, :output1, true)
{:ok, value} = EtherCAT.get_pdo(slave, :input1)
```

### Watching for Changes

**Before:**
```elixir
EtherCAT.Slave.watch_pdo(slave, :temperature)
```

**After:**
```elixir
EtherCAT.watch_pdo(slave, :temperature)
```

### Creating Domains

**Before:**
```elixir
EtherCAT.Master.create_domain(master, :slow_domain, 100)
```

**After:**
```elixir
EtherCAT.create_domain(master, :slow_domain, 100)
```

## Complete Example - Before

```elixir
# Old verbose API
{:ok, master} = EtherCAT.Master.start_link(update_interval: 1000)
:ok = EtherCAT.Master.connect(master)
{:ok, [_coupler, input, output]} = EtherCAT.Master.sync_slaves(master)

EtherCAT.Slave.configure(input, [])
EtherCAT.Slave.register_all_pdos(input, :default_domain)
EtherCAT.Slave.configure(output, [])
EtherCAT.Slave.register_all_pdos(output, :default_domain)

EtherCAT.Master.start_cyclic_mode(master)

EtherCAT.Slave.set_pdo_value(output, :output1, true)
{:ok, value} = EtherCAT.Slave.get_pdo_value(input, :input1)
```

## Complete Example - After

```elixir
# New simplified API
{:ok, master} = EtherCAT.start_link(update_interval: 1000)
:ok = EtherCAT.connect(master)
{:ok, [_coupler, input, output]} = EtherCAT.list_slaves(master)

EtherCAT.configure_slave(input, [])
EtherCAT.register_all_pdos(input, :default_domain)
EtherCAT.configure_slave(output, [])
EtherCAT.register_all_pdos(output, :default_domain)

EtherCAT.start_cyclic(master)

EtherCAT.set_pdo(output, :output1, true)
{:ok, value} = EtherCAT.get_pdo(input, :input1)
```

## Key Improvements

1. **Reduced Namespace Noise**: Most common operations now available at `EtherCAT.*` instead of `EtherCAT.Module.*`
2. **Clearer Function Names**:
   - `sync_slaves` → `list_slaves` (more intuitive)
   - `start_cyclic_mode` → `start_cyclic` (more concise)
   - `set_pdo_value` → `set_pdo` (shorter, cleaner)
   - `get_pdo_value` → `get_pdo` (shorter, cleaner)
3. **Consistent Patterns**: Slave operations grouped under similar naming conventions
4. **Backwards Compatibility**: All original `EtherCAT.Master.*`, `EtherCAT.Slave.*`, and `EtherCAT.Domain.*` functions remain available for advanced users

## Advanced Usage

For users who need fine-grained control, all the original module functions are still accessible:

```elixir
# Still available for advanced users:
EtherCAT.Master.get_ref(master)
EtherCAT.Slave.get_sync_manager(slave, 0)
EtherCAT.Slave.configure_pdo_mapping(slave, 0x1600, entries)
EtherCAT.Domain.get_ref(:default_domain)
```

## Test Organization

Tests have been reorganized for better hardware testing:

**Before:**
- Interactive test functions lived in `lib/ethercat.ex`
- Required calling `EtherCAT.test()`, `EtherCAT.test2()`, `EtherCAT.test3()`

**After:**
- Hardware tests moved to `test/hardware/` directory
- Each test has its own file with clear documentation
- Tests tagged with `:hardware` for selective running
- Both ExUnit tests and interactive `run/0` functions provided

**New Test Structure:**
```
test/
├── hardware/
│   ├── README.md              # Hardware setup documentation
│   ├── basic_io_test.exs      # Basic I/O loopback test
│   ├── selective_pdo_test.exs # Selective PDO registration
│   └── multi_domain_test.exs  # Multi-rate domains
├── ethercat_test.exs          # API surface tests
├── simple_io_test.exs         # Updated to use new API
└── io_diagnosis_test.exs      # Updated to use new API
```

## Running Tests

```bash
# Run all tests (excluding hardware)
mix test

# Run hardware tests
mix test --include hardware

# Run specific hardware test
mix test test/hardware/basic_io_test.exs --include hardware

# Interactive testing in IEx
iex -S mix
iex> {m, i, o} = Hardware.BasicIOTest.run()
```

## Migration Guide

If you have existing code using the old API, here's a simple find-and-replace guide:

1. `EtherCAT.Master.start_link` → `EtherCAT.start_link`
2. `EtherCAT.Master.connect` → `EtherCAT.connect`
3. `EtherCAT.Master.sync_slaves` → `EtherCAT.list_slaves`
4. `EtherCAT.Master.start_cyclic_mode` → `EtherCAT.start_cyclic`
5. `EtherCAT.Master.create_domain` → `EtherCAT.create_domain`
6. `EtherCAT.Slave.configure` → `EtherCAT.configure_slave`
7. `EtherCAT.Slave.list_pdos` → `EtherCAT.list_pdos`
8. `EtherCAT.Slave.register_pdos` → `EtherCAT.register_pdos`
9. `EtherCAT.Slave.register_all_pdos` → `EtherCAT.register_all_pdos`
10. `EtherCAT.Slave.set_pdo_value` → `EtherCAT.set_pdo`
11. `EtherCAT.Slave.get_pdo_value` → `EtherCAT.get_pdo`
12. `EtherCAT.Slave.watch_pdo` → `EtherCAT.watch_pdo`

**Note**: The old API remains fully functional, so migration can be done gradually.

## Benefits

- **Faster to write**: Less typing, clearer intent
- **Easier to learn**: Intuitive function names at the top level
- **Better discoverability**: Autocomplete shows common functions first
- **Maintained flexibility**: Power users can still access everything
- **Better testing**: Hardware tests are organized and documented
