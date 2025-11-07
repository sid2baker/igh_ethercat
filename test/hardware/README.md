# Hardware Tests

This directory contains tests that require actual EtherCAT hardware to run.

## Overview

These tests demonstrate complete EtherCAT workflows with real devices:

- **basic_io_test.exs** - Simple I/O loopback test with digital inputs/outputs
- **selective_pdo_test.exs** - Selective PDO registration for efficiency
- **multi_domain_test.exs** - Multi-rate control with multiple domains

## Hardware Requirements

### Typical Beckhoff Setup

- **EK1100** or similar bus coupler/terminal
- **EL1809** or similar digital input terminal (16 channels)
- **EL2809** or similar digital output terminal (16 channels)
- Physical wire connecting output channel 1 to input channel 1 (for loopback tests)

### Linux System Requirements

- IgH EtherCAT Master kernel module loaded
- `/dev/EtherCAT0` device accessible
- User has appropriate permissions (root or member of ethercat group)
- Real-time kernel recommended but not required for basic testing

## Running Tests

### Run All Hardware Tests

```bash
mix test test/hardware/ --include hardware
```

### Run a Specific Test

```bash
mix test test/hardware/basic_io_test.exs --include hardware
```

### Interactive Testing in IEx

For manual exploration and debugging:

```elixir
# Start IEx with the project
iex -S mix

# Run a test interactively
iex> {master, input, output} = Hardware.BasicIOTest.run()

# Interact with the devices
iex> EtherCAT.list_pdos(input)
["pdo_6000:1", "pdo_6000:2", ...]

iex> EtherCAT.watch_pdo(input, "pdo_6000:1")
:ok

iex> EtherCAT.set_pdo(output, "pdo_7000:1", true)
:ok

iex> flush()
{:data_changed, "pdo_6000:1", true}
:ok

# Stop the master when done
iex> GenServer.stop(master)
:ok
```

## Test Tags

All hardware tests are tagged with `:hardware` to exclude them from normal test runs:

```elixir
@tag :hardware
@tag timeout: 30_000
test "..." do
  # ...
end
```

By default, `mix test` will skip these tests. Use `--include hardware` to run them.

## Troubleshooting

### Permission Denied on /dev/EtherCAT0

```bash
# Temporary fix (requires root)
sudo chmod 666 /dev/EtherCAT0

# Permanent fix - add user to ethercat group
sudo usermod -a -G ethercat $USER
# Log out and back in for group changes to take effect
```

### No Slaves Found

- Check physical connections and power
- Verify EtherCAT master is loaded: `lsmod | grep ec_`
- Check master state: `ethercat master`
- Check slave list: `ethercat slaves`

### Link Down Error

- Verify network cable is connected
- Check if the network interface is up
- Ensure no other process is using the EtherCAT master

### Working Counter Issues

- Verify all slaves have power
- Check for cable breaks or bad connections
- Ensure slaves are properly terminated (if required)

## Writing New Hardware Tests

When adding new hardware tests:

1. Tag with `@tag :hardware`
2. Set appropriate timeout (30-60 seconds typical)
3. Document required hardware setup in module doc
4. Provide both ExUnit test and interactive `run/0` function
5. Clean up resources (stop master) at test end

Example structure:

```elixir
defmodule Hardware.MyTest do
  use ExUnit.Case
  require Logger

  @moduledoc """
  Description of what this test does.

  ## Hardware Setup
  - List required devices
  - Document physical wiring
  """

  def run do
    # Interactive function for IEx
    # Returns PIDs for continued experimentation
  end

  @tag :hardware
  @tag timeout: 30_000
  test "descriptive name" do
    # Automated test using ExUnit assertions
    # Should cleanup resources at end
  end
end
```

## See Also

- [IgH EtherCAT Master Documentation](https://etherlab.org/doc/)
- [EtherCAT Technology Group](https://www.ethercat.org/)
- Main project README.md for general setup instructions
