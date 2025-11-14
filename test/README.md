# EtherCAT Test Suite

This directory contains tests for the EtherCAT library, organized into unit tests and hardware integration tests.

## Test Structure

```
test/
├── unit/              # Unit tests (no hardware required)
│   └── driver_test.exs
├── hardware/          # Hardware integration tests (require physical EtherCAT hardware)
│   ├── slave_detection_test.exs
│   ├── digital_io_test.exs
│   └── rtd_input_test.exs
└── support/           # Test support modules
    └── hardware_config.ex
```

## Running Tests

### Unit Tests Only (Default)

Run tests that don't require hardware:

```bash
mix test
```

### Hardware Integration Tests

Hardware tests require the following physical setup:

- **Position 0**: EK1100 EtherCAT Coupler
- **Position 1**: EL1809 (16-channel digital input, 24V DC)
- **Position 2**: EL2809 (16-channel digital output, 24V DC, 0.5A)
- **Position 3**: EL3202 (2-channel RTD input)

**Wiring Requirements:**
- Each EL2809 output channel connected to corresponding EL1809 input channel
  - Output Ch1 → Input Ch1
  - Output Ch2 → Input Ch2
  - ... (all 16 channels)
- EL3202 Channel 1: 120Ω resistor connected
- EL3202 Channel 2: 100Ω resistor connected

Run all hardware tests:

```bash
ETHERCAT_HARDWARE=true mix test --only hardware
```

Run specific hardware test suites:

```bash
# Digital I/O loopback tests
ETHERCAT_HARDWARE=true mix test --only hardware:digital_io

# RTD resistor reading tests
ETHERCAT_HARDWARE=true mix test --only hardware:rtd
```

Run all tests (unit + hardware):

```bash
ETHERCAT_HARDWARE=true mix test
```

## Test Descriptions

### Unit Tests

#### `unit/driver_test.exs`
Tests driver modules without requiring hardware:
- PDO structure validation
- Encoding/decoding of values
- Driver metadata and configuration

### Hardware Integration Tests

#### `hardware/slave_detection_test.exs`
Tests basic system initialization and slave detection:
- System opens successfully
- All configured slaves are detected
- Basic read/write operations work

#### `hardware/digital_io_test.exs`
Tests digital I/O loopback (EL2809 → EL1809):
- Single channel operations
- All 16 channels independently
- Pattern testing (binary counter, alternating, walking ones)
- Timing and rapid toggling

#### `hardware/rtd_input_test.exs`
Tests RTD input reading with fixed resistors:
- Basic resistance reading (120Ω and 100Ω)
- Measurement stability over time
- Rapid reading performance
- Range validation

## Hardware Configuration

The test hardware configuration is defined in `test/support/hardware_config.ex`. This module specifies:
- Slave positions and drivers
- Expected vendor and product codes
- PDO and entry mappings
- SDO configuration (for EL3202 OHMS mode)

## Troubleshooting

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
