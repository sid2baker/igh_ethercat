# EtherCAT Test Suite

This directory contains tests for the EtherCAT library, organized into fakeethercat integration tests and hardware tests.

## Test Structure

```
test/
├── fakeethercat/      # Integration tests using libfakeethercat (no hardware required)
│   ├── config_test.exs
│   ├── domain_test.exs
│   ├── loopback_test.exs
│   └── simulated_loopback_test.exs
└── support/           # Test support modules
    ├── fake_ethercat.ex          # FakeEtherCAT helper with config inversion
    ├── hardware_configs/
    │   ├── hardware_config.ex
    │   └── simple_hardware_config.ex
    └── drivers/
        ├── el1809.ex
        ├── el2809.ex
        └── el3202.ex
```

## Testing Philosophy

### Fakeethercat Integration Tests (Default)

Tests use `libfakeethercat` to simulate the EtherCAT master without requiring physical hardware. The library implements the complete EtherCAT master API in userspace and uses RtIPC (shared memory) for process data exchange.

**Key Features:**
- No hardware required
- Fast execution
- Test full stack including NIFs, Master, Domain, Slave supervision
- Config inversion allows dual-master loopback testing

**How It Works:**
- In `MIX_ENV=test`, the NIF links against both `libfakeethercat` and `libethercat`
- `libfakeethercat` intercepts EtherCAT API calls and simulates master behavior
- Process data stored in RtIPC shared memory (`/tmp/FakeEtherCAT/`)
- Two masters can run back-to-back with inverted configs for true loopback

### Hardware Tests (Gated)

Tests that require physical EtherCAT hardware are tagged with `@tag :hardware` and only run when `ETHERCAT_HARDWARE=true`.

## Running Tests

### Fakeethercat Tests (Default)

Run all tests without hardware (36 tests):

```bash
mix test
```

Run specific test files:

```bash
# Configuration and inversion tests (15 tests)
mix test test/fakeethercat/config_test.exs

# Domain configuration tests (5 tests)
mix test test/fakeethercat/domain_test.exs

# Config inversion validation (5 tests)
mix test test/fakeethercat/loopback_test.exs

# Simulated I/O operations (11 tests)
mix test test/fakeethercat/simulated_loopback_test.exs
```

## Future: Hardware Integration Tests

Hardware tests can be added later for validation with real EtherCAT hardware.
For now, all testing is performed using libfakeethercat which provides
comprehensive simulation capabilities without requiring physical devices.

## Test Descriptions

### Fakeethercat Integration Tests

#### `fakeethercat/config_test.exs` (15 tests)
Tests basic configuration without physical hardware:
- Master request and activation
- Config inversion logic and validation
- Hardware config structure validation
- Slave metadata preservation

#### `fakeethercat/domain_test.exs` (5 tests)
Tests domain configuration:
- Domain configuration with SimpleHardwareConfig
- Registered entries per domain
- Config inversion preserves domain structure

#### `fakeethercat/loopback_test.exs` (5 tests)
Tests config inversion details:
- Sync manager direction inversion
- PDO configuration preservation
- Watchdog and SDO preservation
- Complete config validation

#### `fakeethercat/simulated_loopback_test.exs` (11 tests)
Simulates hardware tests using fakeethercat:
- Digital I/O write and read operations
- All 16 channels independently
- Alternating patterns and rapid toggling
- Master and slave lifecycle
- Configuration validation

## Test Helpers

### `FakeEtherCAT`

Helper module for fakeethercat testing. Provides:

- **`setup/0`**: Sets up RtIPC environment (FAKE_EC_HOMEDIR, etc.)
- **`invert_config/1`**: Inverts hardware config for slave emulation

**Config Inversion:**

Swaps `EC_DIR_INPUT` ↔ `EC_DIR_OUTPUT` in sync manager configurations. This allows running two applications back-to-back that exchange process data via RtIPC.

```elixir
real_config = TestConfigBuilder.new()
|> TestConfigBuilder.add_slave(:do, position: 1, driver: EL2809)
|> TestConfigBuilder.build()

fake_config = FakeEtherCAT.invert_config(real_config)

# Start master with real config (master writes to outputs)
{:ok, master1} = EtherCAT.Master.start_link(master_id: 0, config: real_config)

# Start emulator with inverted config (master reads from inputs)
{:ok, master2} = EtherCAT.Master.start_link(master_id: 1, config: fake_config)

# Both share process data via RtIPC
```

### Creating Test Hardware Configs

Use `SimpleHardwareConfig` as a template to create additional hardware configs:

```elixir
# Use existing config
config = SimpleHardwareConfig.hardware_config()

# Or create new configs in test/support/hardware_configs/
# Example: minimal_config.ex, rtd_config.ex, etc.
```

## Fakeethercat Environment

When tests run, fakeethercat uses these environment variables:

- **`FAKE_EC_HOMEDIR`**: Directory for RtIPC bulletin board (defaults to `/tmp/fake_ethercat_<pid>`)
- **`FAKE_EC_NAME`**: Name for RtIPC config (defaults to `ethercat_test`)
- **`FAKE_EC_PREFIX`**: Prefix for RtIPC variables (defaults to `test`)

Each test gets a fresh isolated environment that's cleaned up on exit.

## Troubleshooting

### Fakeethercat tests fail to compile

Ensure `libfakeethercat` is installed:

```bash
# Debian/Ubuntu
sudo apt-get install libfakeethercat-dev

# Or build from source (if part of IgH distribution)
./configure --enable-fakeuserlib
make
sudo make install
```

### "undefined reference to ecrt_*" during compilation

The NIF is linking against fakeethercat. Ensure both libraries are available:

```bash
# Check libraries exist
ls /usr/lib64/libfakeethercat.so*
ls /usr/lib64/libethercat.so*

# Or check /usr/lib/x86_64-linux-gnu/ on Debian
```

### Hardware tests fail with "slave not found"

- Verify all EtherCAT slaves are powered and connected
- Check slave positions match the configuration
- Run `ethercat slaves` to see detected hardware

### Digital I/O loopback tests fail

- Verify output channels are correctly wired to input channels
- Check for loose connections
- Ensure 24V power supply is adequate

### RTD tests report incorrect resistance values

- Verify resistor values with multimeter
- Check for good electrical connections
- Ensure EL3202 is configured in OHMS mode (rtd_element = 8)

### Permission errors

- Ensure your user has permission to access the EtherCAT master
- May need to run with sudo or add user to appropriate group

## References

- [IgH EtherCAT Master Documentation](https://etherlab.org/en/ethercat/)
- [Fakeethercat Library Documentation](https://etherlab.org/en/ethercat/master.html#libfakeethercat)
- [RtIPC Documentation](https://etherlab.org/en/rtipc/)
