# Test Infrastructure Improvements

This document outlines improvements made to the hardware test infrastructure to make it more maintainable, extensible, and easier to work with.

## Summary of Changes

### 1. Created Shared Test Support Modules

**Location:** `test/support/`

Three new modules provide reusable utilities for hardware testing:

#### `HardwareCase` - Test Case Template
- Automatic setup/teardown for hardware tests
- Auto-applies `:hardware` tag and 60s timeout
- Validates minimum slave requirements
- Provides clean context injection (`%{master: master, slaves: slaves}`)
- Ensures proper cleanup with `on_exit/1`

#### `HardwareHelpers` - Common Test Utilities
Eliminates duplicate code across test files:
- `assert_loopback/4` - Loopback testing with configurable delays
- `flush_mailbox/0` - Clear process mailbox
- `collect_notifications/2` - Gather notifications with timeout
- `count_notifications/0` - Count available notifications
- `select_io_slaves/2` - Smart slave selection (skip coupler)
- `find_slave/2` - Find slave by position with fallback
- `wait_stabilization/1` - Standardized stabilization delays
- `assert_notification/3` - Assert notification delivery

#### `HardwareConfigs` - Hardware Setup Declarations
Makes hardware requirements explicit and testable:
- `basic_io_loopback/0` - Standard DI/DO loopback setup
- `el3202_temperature/0` - Temperature sensor testing
- `multi_domain/0` - Multi-rate domain testing
- `minimal/0` - Single-slave minimal setup
- `validate/2` - Verify actual hardware matches expectations

### 2. Updated test_helper.exs

Loads all support modules automatically, making them available to all tests.

### 3. Created Example Refactored Test

**Location:** `test/support/example_refactored_test.exs.example`

Demonstrates how to use the new infrastructure. Compare to existing tests to see the improvements.

## Benefits

### Before (Duplicated Code)
```elixir
defmodule Hardware.MyTest do
  use ExUnit.Case, async: false
  require Logger

  @tag :hardware
  @tag timeout: 30_000

  setup do
    {:ok, master, slaves} = EtherCAT.open()

    on_exit(fn ->
      try do
        EtherCAT.close(master)
      catch
        :exit, {:noproc, _} -> :ok
      end
    end)

    %{master: master, slaves: slaves}
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  defp assert_loopback(input, output, value) do
    # 15+ lines of boilerplate...
  end

  # ... rest of test
end
```

### After (Clean, Focused)
```elixir
defmodule Hardware.MyTest do
  use HardwareCase

  @hardware_config :basic_io_loopback
  @tag min_slaves: 3

  test "loopback works", %{master: master, slaves: slaves} do
    {input, output} = select_io_slaves(slaves)
    # Configure and test...
    assert_loopback(input, output, true)
  end
end
```

### Key Improvements

1. **Reduced Duplication** - Common helpers defined once, used everywhere
2. **Explicit Requirements** - Hardware configs make expectations clear
3. **Better Error Messages** - Configuration validation provides helpful feedback
4. **Easier Maintenance** - Fix bugs in one place, not across 6 test files
5. **Faster Test Writing** - Focus on test logic, not boilerplate
6. **Consistent Patterns** - All hardware tests follow same structure
7. **Self-Documenting** - Hardware configs explain what's needed

## Migration Guide

### Quick Migration

For existing tests, migration is gradual and non-breaking:

1. **Keep existing tests working** - No changes required
2. **Use helpers incrementally** - Import `HardwareHelpers` as needed
3. **Full refactor optional** - Use `HardwareCase` for new tests

### Example Migration

**Before:**
```elixir
defmodule Hardware.BasicIOTest do
  use ExUnit.Case, async: false
  require Logger

  @tag :hardware
  @tag timeout: 30_000

  setup do
    {:ok, master, slaves} = EtherCAT.open()
    [di, do_slave | _] = if length(slaves) >= 3, do: tl(slaves), else: slaves

    {:ok, in_pdos} = EtherCAT.configure_slave(di, %{})
    {:ok, out_pdos} = EtherCAT.configure_slave(do_slave, %{})
    {:ok, in_handles} = EtherCAT.register_pdos(master, di, in_pdos)
    {:ok, out_handles} = EtherCAT.register_pdos(master, do_slave, out_pdos)

    EtherCAT.start_cyclic(master)
    :timer.sleep(500)

    %{master: master, input: hd(in_handles), output: hd(out_handles)}
  end

  test "loopback", %{input: input, output: output} do
    assert :ok = EtherCAT.write(output, true)
    :timer.sleep(500)
    assert {:ok, true} = EtherCAT.read(input)
  end
end
```

**After:**
```elixir
defmodule Hardware.BasicIOTest do
  use HardwareCase

  @hardware_config :basic_io_loopback
  @tag min_slaves: 3

  setup %{master: master, slaves: slaves} do
    {input_slave, output_slave} = select_io_slaves(slaves)

    {:ok, in_pdos} = EtherCAT.configure_slave(input_slave, %{})
    {:ok, out_pdos} = EtherCAT.configure_slave(output_slave, %{})
    {:ok, in_handles} = EtherCAT.register_pdos(master, input_slave, in_pdos)
    {:ok, out_handles} = EtherCAT.register_pdos(master, output_slave, out_pdos)

    EtherCAT.start_cyclic(master)
    wait_stabilization()

    %{input: hd(in_handles), output: hd(out_handles)}
  end

  test "loopback", %{input: input, output: output} do
    assert_loopback(input, output, true)
  end
end
```

**Improvements:**
- 5 fewer lines of boilerplate
- Clearer slave selection with `select_io_slaves/1`
- Named delay with `wait_stabilization/0`
- 1-line loopback assertion vs 3 lines
- Hardware config documents requirements
- Automatic cleanup

## Future Enhancements

### 1. Property-Based Testing
```elixir
defmodule Hardware.PropertyTest do
  use HardwareCase
  use ExUnitProperties

  property "all boolean values loopback correctly", %{input: i, output: o} do
    check all value <- boolean() do
      assert_loopback(i, o, value)
    end
  end
end
```

### 2. Performance Benchmarks
```elixir
defmodule Hardware.BenchmarkTest do
  use HardwareCase

  test "cyclic performance", %{master: master} do
    stats = measure_cycle_time(master, duration: 10_000)
    assert stats.avg_cycle_time < 1000, "Avg: #{stats.avg_cycle_time}µs"
    assert stats.max_cycle_time < 2000, "Max: #{stats.max_cycle_time}µs"
  end
end
```

### 3. Hardware Capability Detection
```elixir
defmodule HardwareDetection do
  def detect_slaves(slaves) do
    Enum.map(slaves, fn slave ->
      # Query slave info via NIF
      # Return %{type: :digital_input, channels: 16, ...}
    end)
  end

  def supports_loopback?(slaves) do
    # Auto-detect if loopback testing is possible
  end
end
```

### 4. Test Fixtures
```elixir
# test/fixtures/slave_data.exs
%{
  el1809: %{
    vendor_id: 0x02,
    product_code: 0x07113052,
    expected_pdos: 16,
    type: :digital_input
  },
  # ...
}
```

### 5. Interactive Test Runner
```bash
mix test.hardware --interactive
# Shows available slaves
# Suggests appropriate tests
# Validates hardware before running
```

## Implementation Notes

### File Structure
```
test/
├── support/
│   ├── hardware_case.ex          # Test case template
│   ├── hardware_helpers.ex       # Utility functions
│   ├── hardware_configs.ex       # Hardware setups
│   └── example_refactored_test.exs.example
├── hardware/
│   ├── basic_io_test.exs         # Existing tests (unchanged)
│   ├── el3202_test.exs
│   └── ...
├── test_helper.exs               # Updated to load support modules
└── ethercat_test.exs
```

### Backward Compatibility

All existing tests continue to work without modification. The new infrastructure is:
- **Additive** - Only adds new capabilities
- **Optional** - Use as much or as little as needed
- **Gradual** - Migrate incrementally
- **Non-breaking** - No changes to existing test behavior

## Testing the Improvements

Run existing tests to verify nothing broke:
```bash
mix test test/hardware/ --include hardware
```

Check that support modules compile:
```bash
mix compile
```

Verify test helper loads support modules:
```bash
mix test --trace
# Should see support modules loaded
```

## Conclusion

These improvements make hardware testing:
- **Faster to write** - Less boilerplate, more focus
- **Easier to maintain** - Centralized utilities
- **More reliable** - Consistent patterns
- **Better documented** - Explicit requirements
- **More extensible** - Easy to add new hardware configs

The infrastructure grows with the project and makes adding new hardware tests straightforward.
