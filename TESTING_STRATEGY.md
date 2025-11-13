# EtherCAT Testing Strategy

## Executive Summary

This document outlines a progressive testing strategy for the `igh_ethercat` library that enables:
- **CI/CD automation** without physical hardware
- **Fast local development** feedback loops
- **Comprehensive coverage** of edge cases and state machines
- **Living documentation** through test examples

**Current Approach (Phase 1):** Start with simple Elixir test helpers and hardware verification infrastructure. This provides immediate value with minimal complexity while keeping the door open for FakeEtherCAT integration later.

**Future Consideration:** FakeEtherCAT (libfakeethercat) for full virtual slave simulation. Deferred until the complexity is justified by testing needs.

---

## Current Implementation (Phase 1: Test Infrastructure)

### What We Have Now

**✅ Hardware Verification System**
- `EtherCAT.HardwareLayout` - Declarative hardware configuration
- `EtherCAT.HardwareVerifier` - Automatic verification with detailed error reporting
- `EtherCAT.SlaveConfig` - Slave specification struct
- Discovery mode: `EtherCAT.open()` (no verification)
- Strict mode: `EtherCAT.open(expected: layout, match: :exact)` (fails on mismatch)

**✅ Test Helpers** (`test/support/test_helpers.ex`)
- `find_slave/3` - Find slave by vendor/product ID
- `find_slaves_by_vendor/2` - Find all slaves from a vendor
- `assert_hardware_matches!/2` - Assert layout matches with helpful errors
- `wait_for_slaves/3` - Wait for slaves to enumerate
- `minimal_layout/2` - Create test fixtures quickly

**✅ Example Layouts** (`test/support/example_layouts.ex`)
- `simple_io_layout/0` - Single generic I/O slave
- `beckhoff_temperature_layout/0` - Real Beckhoff EL3202 device
- `multi_slave_layout/0` - 4-slave mixed vendor bus
- `aliased_layout/0` - Demonstrates alias addressing
- `large_bus_layout/0` - 16-slave performance testing

**✅ Example Tests**
- `test/unit/hardware_layout_test.exs` - Tests for layout generation and verification
- `test/unit/test_helpers_test.exs` - Demonstrates usage patterns

### Usage Patterns

#### Pattern 1: Hardware Verification
```elixir
defmodule MyApp.ProductionTest do
  use ExUnit.Case
  import EtherCAT.ExampleLayouts

  test "production hardware matches expected layout" do
    layout = multi_slave_layout()

    # Fails fast if hardware doesn't match
    {:ok, master, slaves} = EtherCAT.open(expected: layout, match: :exact)

    # Continue with tests...
    EtherCAT.close(master)
  end
end
```

#### Pattern 2: Hardware Discovery
```elixir
test "discover and document current hardware" do
  # Connect without expectations
  {:ok, master, slaves} = EtherCAT.open()

  # Generate layout from discovered hardware
  layout = EtherCAT.HardwareLayout.from_slaves(slaves)

  # Save for future use
  source = EtherCAT.HardwareLayout.generate_module(layout,
    module_name: "MyApp.DiscoveredLayout"
  )
  File.write!("test/fixtures/my_layout.ex", source)

  EtherCAT.close(master)
end
```

#### Pattern 3: Selective Testing
```elixir
test "works with any Beckhoff temperature sensor" do
  import EtherCAT.TestHelpers

  {:ok, master, slaves} = EtherCAT.open()

  # Find specific devices
  beckhoff_slaves = find_slaves_by_vendor(slaves, 0x00000002)
  temp_sensor = find_slave(slaves, 0x00000002, 0x0C823052)

  # Test with found devices...
  EtherCAT.close(master)
end
```

#### Pattern 4: Quick Test Fixtures
```elixir
test "handles 5-slave bus" do
  import EtherCAT.TestHelpers

  # Generate minimal test layout
  layout = minimal_layout(5, vendor_id: 0xDEAD, product_code: 0x0001)

  # Use for testing (still requires real hardware for now)
  # ...
end
```

### Benefits of Current Approach

1. **Immediate Value**: Works with existing hardware tests right now
2. **Simple**: Pure Elixir, no C compilation, no complex setup
3. **Self-Documenting**: Hardware requirements are explicit in code
4. **Fail-Fast**: Wrong hardware detected at startup, not during test execution
5. **Maintainable**: Easy to understand and modify
6. **Foundation**: Infrastructure ready for future FakeEtherCAT integration

### Limitations

- Still requires real hardware or hardware abstraction for full CI/CD
- Cannot test master/slave state machine transitions in isolation
- PDO I/O testing needs physical devices

### Next Steps

Consider FakeEtherCAT integration when:
- Need to test without any hardware (full CI/CD automation)
- Want to test error conditions that are hard to reproduce with real hardware
- Need to test timing-sensitive scenarios
- Want to simulate hardware failures

---

## Future Option: FakeEtherCAT Integration (Deferred)

> **Note:** The sections below describe a more complex testing approach using FakeEtherCAT
> (libfakeethercat) for full virtual slave simulation. This approach has been **deferred**
> in favor of the simpler Elixir test helpers described above. The information is preserved
> for future reference when the complexity is justified.

### Why Deferred?

FakeEtherCAT requires:
- Two separate processes (master application + fake slave application)
- RtIPC shared memory setup and direction swapping
- C compilation for fake slave programs
- Complex debugging across process boundaries
- Additional build system integration

**Decision:** Start simple with Elixir helpers. Revisit FakeEtherCAT when we need:
- Full CI/CD without any hardware
- Error injection testing
- Hardware failure simulation
- State machine isolation testing

---

## Historical Context: Original Analysis

### Existing Tests
- ✅ **1 unit test** (`test/ethercat_test.exs`) - Basic API surface
- ✅ **8 hardware tests** (`test/hardware/*.exs`) - 1,168 lines requiring physical devices
- ❌ **No mocking infrastructure**
- ❌ **No CI-compatible tests**

### Architecture
```
EtherCAT (API)
    ↓
Master/Slave/Domain (GenServer/GenStatem)
    ↓
Zig NIF (1,000+ lines)
    ↓
IgH EtherCAT C Library (libethercat)
    ↓
/dev/EtherCAT0 (kernel module)
```

**Hardware Coupling Points:**
- Master request/activation
- Slave enumeration & configuration
- Domain I/O (cyclic task)
- SDO reads/writes

---

## Testing Strategy Overview

### Three-Tier Approach

```
┌─────────────────────────────────────────────────────────┐
│ Tier 1: Pure Unit Tests (No Hardware/FakeEtherCAT)     │
│ - State machine logic                                    │
│ - Domain layout validation                               │
│ - Driver encoding/decoding                               │
│ - Error handling paths                                   │
│ Speed: <1s | Frequency: Every save                      │
└─────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────┐
│ Tier 2: Virtual Hardware Tests (FakeEtherCAT)          │
│ - Master/slave lifecycle                                 │
│ - PDO registration & I/O                                 │
│ - Multi-domain coordination                              │
│ - Driver integration                                     │
│ Speed: ~10s | Frequency: Pre-commit, CI                 │
└─────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────┐
│ Tier 3: Real Hardware Tests (Existing)                 │
│ - Full stack validation                                  │
│ - Timing behavior                                        │
│ - Vendor-specific quirks                                 │
│ Speed: ~60s | Frequency: Pre-release, manual            │
└─────────────────────────────────────────────────────────┘
```

---

## Phase 1: Minimal CI Setup (Weeks 1-2)

### Goal
Get CI green with 1-2 simple virtual slaves covering basic Master → Slave → Domain → I/O flow.

### 1.1 FakeEtherCAT Setup

#### Prerequisites
```bash
# Install RtIPC (required for libfakeethercat shared memory)
sudo apt-get install rtipc-dev

# Configure IgH Master with FakeEtherCAT support
cd /path/to/ethercat-master-source
./configure --enable-fakeuserlib
make
sudo make install
```

#### Verify Installation
```bash
# Check for libfakeethercat
ls -l /usr/local/lib/libfakeethercat*

# Expected output:
# libfakeethercat.so -> libfakeethercat.so.1.0.0
# libfakeethercat.so.1 -> libfakeethercat.so.1.0.0
# libfakeethercat.so.1.0.0
```

### 1.2 Create Simple Virtual Slave

**File:** `test/support/fake_slaves/simple_io_slave.c`

```c
/**
 * Simple 8-bit I/O slave for testing basic PDO exchange
 * Vendor ID: 0xDEAD (fake)
 * Product Code: 0x0001
 *
 * PDO Layout:
 *   TxPDO (Slave → Master): 1 byte output
 *   RxPDO (Master → Slave): 1 byte input (loopback)
 */

#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <fakeethercat.h>

#define VENDOR_ID 0xDEAD
#define PRODUCT_CODE 0x0001

// Swap directions for slave side
static ec_sync_info_t syncs[] = {
    {0, EC_DIR_OUTPUT, 0, NULL, EC_WD_DISABLE}, // Master writes
    {1, EC_DIR_INPUT,  0, NULL, EC_WD_DISABLE}, // Slave writes
    {0xff}
};

static ec_pdo_entry_info_t channel1_entries[] = {
    {0x6000, 0x01, 8}, // Output byte (master writes)
    {0x7000, 0x01, 8}, // Input byte (master reads)
};

static ec_pdo_info_t channel1_pdos[] = {
    {0x1600, 1, &channel1_entries[0]}, // RxPDO (master → slave)
    {0x1A00, 1, &channel1_entries[1]}, // TxPDO (slave → master)
};

int main(int argc, char **argv) {
    ec_master_t *master;
    ec_domain_t *domain;
    uint8_t *domain_pd;

    unsigned int bit_pos_rx, bit_pos_tx;
    uint8_t input_byte = 0;

    printf("[FakeSlave] Starting simple I/O slave (0x%04X:0x%04X)\n",
           VENDOR_ID, PRODUCT_CODE);

    // Request master (uses FakeEtherCAT internally)
    master = ecrt_request_master(0);
    if (!master) {
        fprintf(stderr, "[FakeSlave] Failed to request master\n");
        return -1;
    }

    // Configure slave at position 0
    ec_slave_config_t *sc = ecrt_master_slave_config(
        master, 0, 0, VENDOR_ID, PRODUCT_CODE
    );
    if (!sc) {
        fprintf(stderr, "[FakeSlave] Failed to configure slave\n");
        return -1;
    }

    // Configure sync managers (SWAPPED for slave side)
    if (ecrt_slave_config_sync_manager(sc, 0, EC_DIR_OUTPUT, EC_WD_DISABLE) ||
        ecrt_slave_config_sync_manager(sc, 1, EC_DIR_INPUT, EC_WD_DISABLE)) {
        fprintf(stderr, "[FakeSlave] Failed to configure SMs\n");
        return -1;
    }

    // Assign PDOs to sync managers
    if (ecrt_slave_config_pdo_assign_clear(sc, 0) < 0 ||
        ecrt_slave_config_pdo_assign_add(sc, 0, 0x1600) < 0) {
        fprintf(stderr, "[FakeSlave] Failed to assign RxPDO\n");
        return -1;
    }

    if (ecrt_slave_config_pdo_assign_clear(sc, 1) < 0 ||
        ecrt_slave_config_pdo_assign_add(sc, 1, 0x1A00) < 0) {
        fprintf(stderr, "[FakeSlave] Failed to assign TxPDO\n");
        return -1;
    }

    // Configure PDO mappings
    if (ecrt_slave_config_pdo_mapping_clear(sc, 0x1600) < 0 ||
        ecrt_slave_config_pdo_mapping_add(sc, 0x1600, 0x6000, 0x01, 8) < 0) {
        fprintf(stderr, "[FakeSlave] Failed to map RxPDO\n");
        return -1;
    }

    if (ecrt_slave_config_pdo_mapping_clear(sc, 0x1A00) < 0 ||
        ecrt_slave_config_pdo_mapping_add(sc, 0x1A00, 0x7000, 0x01, 8) < 0) {
        fprintf(stderr, "[FakeSlave] Failed to map TxPDO\n");
        return -1;
    }

    // Create domain
    domain = ecrt_master_create_domain(master);
    if (!domain) {
        fprintf(stderr, "[FakeSlave] Failed to create domain\n");
        return -1;
    }

    // Register PDO entries to domain
    // Returns byte offset in domain, bit position via pointer
    int byte_offset_rx = ecrt_slave_config_reg_pdo_entry(sc, 0x6000, 0x01, domain, &bit_pos_rx);
    if (byte_offset_rx < 0) {
        fprintf(stderr, "[FakeSlave] Failed to register RxPDO entry\n");
        return -1;
    }

    int byte_offset_tx = ecrt_slave_config_reg_pdo_entry(sc, 0x7000, 0x01, domain, &bit_pos_tx);
    if (byte_offset_tx < 0) {
        fprintf(stderr, "[FakeSlave] Failed to register TxPDO entry\n");
        return -1;
    }

    unsigned int offset_rx = byte_offset_rx; // For simplicity, assuming byte-aligned
    unsigned int offset_tx = byte_offset_tx;

    // Activate master
    if (ecrt_master_activate(master)) {
        fprintf(stderr, "[FakeSlave] Failed to activate master\n");
        return -1;
    }

    domain_pd = ecrt_domain_data(domain);
    printf("[FakeSlave] Slave activated, entering cyclic loop\n");

    // Cyclic loop: echo input back to output
    while (1) {
        ecrt_master_receive(master);
        ecrt_domain_process(domain);

        // Read input byte
        input_byte = EC_READ_U8(domain_pd + offset_rx);

        // Echo back to output (simple loopback)
        EC_WRITE_U8(domain_pd + offset_tx, input_byte);

        ecrt_domain_queue(domain);
        ecrt_master_send(master);

        usleep(1000); // 1ms cycle
    }

    return 0;
}
```

**Makefile:** `test/support/fake_slaves/Makefile`

```makefile
CC = gcc
CFLAGS = -Wall -I/usr/local/include
LDFLAGS = -L/usr/local/lib -lfakeethercat -lrtipc

SLAVES = simple_io_slave

all: $(SLAVES)

simple_io_slave: simple_io_slave.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

clean:
	rm -f $(SLAVES)

.PHONY: all clean
```

### 1.3 Create Virtual Hardware Test Case

**File:** `test/virtual_hardware_test.exs`

```elixir
defmodule EtherCAT.VirtualHardwareTest do
  use ExUnit.Case, async: false

  @moduletag :virtual_hardware
  @moduletag timeout: 10_000

  setup do
    # Start fake slave process
    slave_path = Path.join([
      __DIR__,
      "support",
      "fake_slaves",
      "simple_io_slave"
    ])

    unless File.exists?(slave_path) do
      raise """
      Fake slave binary not found. Build it first:
        cd test/support/fake_slaves && make
      """
    end

    # Launch fake slave in background
    port = Port.open({:spawn_executable, slave_path}, [
      :binary,
      :exit_status,
      {:line, 256}
    ])

    # Give slave time to register with FakeEtherCAT
    Process.sleep(500)

    on_exit(fn ->
      Port.close(port)
    end)

    :ok
  end

  test "basic master open and slave discovery" do
    {:ok, master, slaves} = EtherCAT.open(update_interval: 1000)

    # Should discover our fake slave
    assert length(slaves) >= 1

    # Find our fake slave by vendor ID
    fake_slave = Enum.find(slaves, fn s ->
      s.vendor_id == 0xDEAD && s.product_code == 0x0001
    end)

    assert fake_slave != nil, "Fake slave not discovered"

    EtherCAT.close(master)
  end

  test "basic PDO I/O with fake slave" do
    {:ok, master, slaves} = EtherCAT.open(update_interval: 1000)

    # Find fake slave
    fake_slave = Enum.find(slaves, fn s ->
      s.vendor_id == 0xDEAD && s.product_code == 0x0001
    end)

    assert fake_slave != nil

    # Configure slave (Generic driver will auto-discover PDOs)
    {:ok, available_pdos} = EtherCAT.configure_slave(fake_slave, %{})
    IO.inspect(available_pdos, label: "Discovered PDOs")

    # Register all PDOs
    {:ok, pdo_handles} = EtherCAT.register_pdos(fake_slave, available_pdos)

    # Find input and output handles
    # Generic driver creates pdo names from indices: pdo_1600, pdo_1A00
    input_handle = Enum.find(pdo_handles, fn h ->
      h.pdo_name == :pdo_1600 && h.entry_name == :"1"
    end)

    output_handle = Enum.find(pdo_handles, fn h ->
      h.pdo_name == :pdo_1A00 && h.entry_name == :"1"
    end)

    assert input_handle != nil, "Input handle not found"
    assert output_handle != nil, "Output handle not found"

    # Start cyclic communication
    {:ok, _domain} = EtherCAT.start_cyclic(master)

    # Wait for operational state
    assert_receive {:master_state_changed, ^master, :operational}, 2000

    # Write test value (master writes to 0x6000, fake slave echoes to 0x7000)
    :ok = EtherCAT.write(input_handle, <<0xAB>>)

    # Fake slave echoes back, should see it in output
    Process.sleep(100)
    {:ok, <<value>>} = EtherCAT.read(output_handle)
    assert value == 0xAB

    # Try different value
    :ok = EtherCAT.write(input_handle, <<0x42>>)
    Process.sleep(100)
    {:ok, <<value>>} = EtherCAT.read(output_handle)
    assert value == 0x42

    EtherCAT.close(master)
  end

  test "watch entry changes with fake slave" do
    {:ok, master, slaves} = EtherCAT.open(update_interval: 1000)

    fake_slave = Enum.find(slaves, fn s ->
      s.vendor_id == 0xDEAD && s.product_code == 0x0001
    end)

    {:ok, available_pdos} = EtherCAT.configure_slave(fake_slave, %{})
    {:ok, pdo_handles} = EtherCAT.register_pdos(fake_slave, available_pdos)

    # Find output handle (slave → master)
    output_handle = Enum.find(pdo_handles, fn h ->
      h.pdo_name == :pdo_1A00
    end)

    assert output_handle != nil

    # Watch for changes
    :ok = EtherCAT.watch(output_handle)

    {:ok, _domain} = EtherCAT.start_cyclic(master)
    assert_receive {:master_state_changed, ^master, :operational}, 2000

    # Should receive initial value notification
    assert_receive {:entry_changed, ^output_handle, <<_::8>>}, 1000

    EtherCAT.close(master)
  end
end
```

### 1.4 CI Configuration

**File:** `.github/workflows/ci.yml`

```yaml
name: CI

on:
  push:
    branches: [ main, claude/** ]
  pull_request:
    branches: [ main ]

jobs:
  test:
    runs-on: ubuntu-22.04

    env:
      MIX_ENV: test
      ETHERCAT_VERSION: "1.6.2"  # Or your required version

    steps:
      - uses: actions/checkout@v3

      - name: Set up Elixir
        uses: erlef/setup-beam@v1
        with:
          elixir-version: '1.19'
          otp-version: '27'

      - name: Install system dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y build-essential autoconf automake libtool

      - name: Install RtIPC
        run: |
          git clone https://gitlab.com/etherlab.org/rtipc.git /tmp/rtipc
          cd /tmp/rtipc
          ./bootstrap
          ./configure
          make
          sudo make install
          sudo ldconfig

      - name: Install IgH EtherCAT Master with FakeEtherCAT
        run: |
          wget https://gitlab.com/etherlab.org/ethercat/-/archive/${{ env.ETHERCAT_VERSION }}/ethercat-${{ env.ETHERCAT_VERSION }}.tar.gz
          tar xzf ethercat-${{ env.ETHERCAT_VERSION }}.tar.gz
          cd ethercat-${{ env.ETHERCAT_VERSION }}
          ./bootstrap
          ./configure --enable-fakeuserlib --disable-kernel
          make
          sudo make install
          sudo ldconfig

      - name: Install Zig
        run: |
          wget https://ziglang.org/download/0.15.2/zig-linux-x86_64-0.15.2.tar.xz
          tar xf zig-linux-x86_64-0.15.2.tar.xz
          sudo mv zig-linux-x86_64-0.15.2 /usr/local/zig
          echo "/usr/local/zig" >> $GITHUB_PATH

      - name: Cache Mix dependencies
        uses: actions/cache@v3
        with:
          path: |
            deps
            _build
          key: ${{ runner.os }}-mix-${{ hashFiles('**/mix.lock') }}

      - name: Install Mix dependencies
        run: mix deps.get

      - name: Build fake slaves
        run: |
          cd test/support/fake_slaves
          make

      - name: Run unit tests
        run: mix test --exclude hardware --exclude virtual_hardware

      - name: Run virtual hardware tests
        run: mix test --only virtual_hardware

      - name: Check formatting
        run: mix format --check-formatted

      - name: Run Credo
        run: mix credo --strict
```

### 1.5 Update Test Helper

**File:** `test/test_helper.exs`

```elixir
ExUnit.start()

# Exclude hardware tests by default (require physical devices)
ExUnit.configure(exclude: [:hardware])

# Virtual hardware tests run in CI with FakeEtherCAT
# Exclude locally unless FakeEtherCAT is installed
unless System.get_env("CI") == "true" do
  case System.cmd("ldconfig", ["-p"], stderr_to_stdout: true) do
    {output, 0} ->
      if String.contains?(output, "libfakeethercat") do
        IO.puts("✓ FakeEtherCAT detected - virtual hardware tests enabled")
      else
        IO.puts("✗ FakeEtherCAT not found - excluding virtual_hardware tests")
        IO.puts("  Install: ./configure --enable-fakeuserlib && make install")
        ExUnit.configure(exclude: [:virtual_hardware | ExUnit.configuration()[:exclude]])
      end

    _ ->
      ExUnit.configure(exclude: [:virtual_hardware | ExUnit.configuration()[:exclude]])
  end
end
```

---

## Phase 2: Expand Virtual Slave Coverage (Weeks 3-4)

### Goals
- Add EL3202-like temperature sensor slave
- Test Generic driver auto-discovery
- Cover SDO configuration flows

### 2.1 Temperature Sensor Fake Slave

**File:** `test/support/fake_slaves/temp_sensor_slave.c`

```c
/**
 * EL3202-like RTD temperature sensor
 * Vendor ID: 0xDEAD
 * Product Code: 0x0002
 *
 * Features:
 * - 2 channels (ch1, ch2)
 * - SDO configuration (0x8000:11 - underrange, 0x8000:12 - overrange)
 * - Simulates temperature values: 20.0°C to 25.0°C sine wave
 */

#include <math.h>
#include <time.h>
// ... implementation similar to simple_io_slave but with:
// - Temperature value generation
// - SDO request handling
// - Multi-channel PDO layout
```

### 2.2 Test Cases

```elixir
defmodule EtherCAT.VirtualDriverTest do
  use ExUnit.Case, async: false
  @moduletag :virtual_hardware

  test "Generic driver auto-discovers fake slave PDOs" do
    # Test that Generic driver works with unknown vendor IDs
  end

  test "Custom driver handles SDO configuration" do
    # Test EL3202-like driver with fake temp sensor
  end
end
```

---

## Phase 3: Multi-Domain & Edge Cases (Weeks 5-6)

### Goals
- Multiple virtual slaves on same bus
- Different domain update intervals
- Error injection (slave disappearance, bad PDO configs)

### 3.1 Fake Slaves
- `multi_slave_bus.c` - 3+ slaves with different PDO layouts
- `faulty_slave.c` - Intentionally bad configurations for error path testing

### 3.2 Test Scenarios
- Domain layout validation (overlapping entries)
- Slave state machine error handling
- Master recovery from slave loss

---

## Phase 4: Property-Based & Generative Testing (Weeks 7-8)

### Goals
- Use StreamData to generate random slave configurations
- Fuzz testing for edge cases

```elixir
defmodule EtherCAT.PropertyTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  property "domain layout never overlaps entries" do
    check all slave_count <- integer(1..10),
              pdo_configs <- list_of(pdo_entry_generator(), length: slave_count) do
      # Generate fake slaves with random PDO layouts
      # Verify domain.c bit offset calculations never collide
    end
  end
end
```

---

## Tier 1: Pure Unit Tests (No Hardware)

### State Machine Tests

**File:** `test/ethercat/master_test.exs`

```elixir
defmodule EtherCAT.MasterTest do
  use ExUnit.Case, async: true

  # Mock NIF responses at module level
  import Mox

  setup :verify_on_exit!

  describe "state transitions" do
    test "offline → stale on connect" do
      # Test GenStatem state logic without NIF
    end

    test "cannot start_cyclic before sync_slaves" do
      # Verify guard clauses
    end
  end

  describe "error handling" do
    test "handles slave enumeration timeout" do
      # Mock NIF returning empty slave list
    end
  end
end
```

### Domain Layout Validation

**File:** `test/ethercat/domain_test.exs`

```elixir
defmodule EtherCAT.DomainTest do
  use ExUnit.Case, async: true

  describe "bit offset calculations" do
    test "detects overlapping PDO entries" do
      # Pure logic test - no NIF needed
      entries = [
        %{offset: 0, bit_length: 8},
        %{offset: 4, bit_length: 8}  # Overlaps!
      ]

      assert {:error, :overlapping_entries} = Domain.validate_layout(entries)
    end

    test "handles byte-aligned vs bit-aligned entries" do
      # Test offset calculation logic
    end
  end

  describe "entry registration" do
    test "rejects duplicate entry names" do
      # Verify uniqueness constraints
    end
  end
end
```

### Driver Unit Tests

**File:** `test/ethercat/drivers/el3202_test.exs`

```elixir
defmodule EtherCAT.Drivers.EL3202Test do
  use ExUnit.Case, async: true

  alias EtherCAT.Drivers.EL3202

  describe "temperature decoding" do
    test "converts raw ADC value to celsius" do
      # INT16 value from PDO
      raw_value = <<0xD8, 0x0F>>  # 4056 -> ~20.28°C

      assert {:ok, temp} = EL3202.decode_temperature(raw_value)
      assert_in_delta temp, 20.28, 0.01
    end

    test "handles underrange (0x8000)" do
      raw_value = <<0x00, 0x80>>
      assert {:error, :underrange} = EL3202.decode_temperature(raw_value)
    end

    test "handles overrange (0x7FFF)" do
      raw_value = <<0xFF, 0x7F>>
      assert {:error, :overrange} = EL3202.decode_temperature(raw_value)
    end
  end

  describe "SDO configuration" do
    test "generates correct SDO write commands" do
      config = %{underrange: -50.0, overrange: 150.0}

      sdos = EL3202.configure_channel(1, config)

      assert Enum.any?(sdos, fn {index, subindex, _value} ->
        index == 0x8000 && subindex == 0x11
      end)
    end
  end
end
```

---

## Build System Integration

### Update `mix.exs`

```elixir
defmodule EtherCAT.MixProject do
  use Mix.Project

  def project do
    [
      # ... existing config
      aliases: aliases(),
      preferred_cli_env: [
        "test.all": :test,
        "test.unit": :test,
        "test.virtual": :test,
        "test.hardware": :test
      ]
    ]
  end

  defp aliases do
    [
      "test.all": ["test --include hardware --include virtual_hardware"],
      "test.unit": ["test --exclude hardware --exclude virtual_hardware"],
      "test.virtual": ["test --only virtual_hardware"],
      "test.hardware": ["test --only hardware"],

      # Pre-commit hook
      "pre_commit": [
        "format --check-formatted",
        "credo --strict",
        "test.unit",
        "test.virtual"
      ],

      # Build fake slaves before tests
      "test": ["cmd cd test/support/fake_slaves && make", "test"]
    ]
  end
end
```

---

## Developer Workflow

### Local Setup (One-Time)

```bash
# 1. Install FakeEtherCAT (if not already done)
cd /path/to/ethercat-source
./configure --enable-fakeuserlib
make && sudo make install
sudo ldconfig

# 2. Build fake slaves
cd test/support/fake_slaves
make

# 3. Verify setup
mix test.virtual
```

### Daily Development

```bash
# Fast feedback - unit tests only (~1s)
mix test.unit

# Pre-commit - units + virtual (~10s)
mix pre_commit

# Weekly - full suite including hardware (~2min)
mix test.all  # Requires physical EtherCAT devices connected
```

### Git Hooks

**File:** `.git/hooks/pre-commit`

```bash
#!/bin/sh
mix pre_commit
```

---

## Migration Guide

### Converting Existing Hardware Tests

**Before (requires hardware):**
```elixir
@moduletag :hardware

test "EL3202 reads temperature" do
  {:ok, master, [slave]} = EtherCAT.open()
  # ... test with real EL3202
end
```

**After (hardware + virtual versions):**
```elixir
# Keep original for full validation
@tag :hardware
test "EL3202 reads temperature - real hardware" do
  # ... original test
end

# Add virtual version for CI
@tag :virtual_hardware
test "EL3202 reads temperature - virtual slave" do
  # Same test logic, launches temp_sensor_slave.c
end
```

**Porting Checklist:**
1. Extract test logic into shared helper functions
2. Create corresponding fake slave (`.c` file)
3. Add virtual version of test
4. Tag appropriately (`:hardware` vs `:virtual_hardware`)
5. Verify both pass

---

## Success Metrics

### Phase 1 Complete When:
- ✅ CI runs 10+ virtual hardware tests without physical devices
- ✅ Simple I/O loopback test passes with fake slave
- ✅ Test execution time < 15 seconds in CI
- ✅ Developers can run `mix test.virtual` locally

### Phase 2 Complete When:
- ✅ Generic driver tested with 3+ fake slave configurations
- ✅ SDO configuration paths covered
- ✅ Temperature sensor simulation working

### Phase 3 Complete When:
- ✅ Multi-domain tests running virtually
- ✅ Error injection tests (bad configs, missing slaves)
- ✅ 50+ virtual hardware tests

### Phase 4 Complete When:
- ✅ Property-based tests running in CI
- ✅ Fuzz testing catches edge cases
- ✅ 80%+ code coverage (including NIF boundary)

### Overall Success:
- ✅ CI catches regressions before merge
- ✅ Local development doesn't require hardware connection
- ✅ New contributors can run full test suite on laptop
- ✅ Hardware tests remain as gold standard for releases

---

## Maintenance & Evolution

### Adding New Virtual Slaves

1. Create `.c` file in `test/support/fake_slaves/`
2. Update `Makefile`
3. Add corresponding test case
4. Document slave's PDO layout in comments
5. Update this strategy doc

### Troubleshooting FakeEtherCAT

**Shared memory issues:**
```bash
# List RtIPC segments
ipcs -m

# Clean up stale segments
ipcrm -m <shmid>
```

**Slave not discovered:**
- Check fake slave process is running (`ps aux | grep slave`)
- Verify vendor ID matches test expectations
- Enable debug logging in fake slave

**CI failures:**
```yaml
# Add debug step to workflow
- name: Debug FakeEtherCAT
  if: failure()
  run: |
    ldconfig -p | grep fake
    ldd test/support/fake_slaves/simple_io_slave
```

---

## References

- [IgH FakeEtherCAT Documentation](https://docs.etherlab.org/ethercat/1.6/doxygen/libfakeethercat.html)
- [RtIPC GitLab](https://gitlab.com/etherlab.org/rtipc)
- [EtherCAT Master Documentation](https://docs.etherlab.org/ethercat/1.6/pdf/ethercat_doc.pdf)
- Existing hardware tests: `test/hardware/*.exs`

---

## Next Steps

1. **Immediate (This Week):**
   - Build `simple_io_slave.c`
   - Run first virtual hardware test locally
   - Verify FakeEtherCAT installation

2. **Phase 1 (Weeks 1-2):**
   - Implement CI workflow
   - Port 2-3 existing hardware tests to virtual versions
   - Get CI green

3. **Phase 2+ (Progressive):**
   - Expand virtual slave library as gaps found
   - Add unit tests for pure logic
   - Maintain parity with hardware tests

**Questions or blockers?** Open an issue or consult IgH EtherCAT mailing list for FakeEtherCAT specifics.
