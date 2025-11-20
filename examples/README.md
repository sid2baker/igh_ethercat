# EtherCAT Examples

This directory contains documentation and guidance for example code in the EtherCAT library.

## Available Examples

### Simple I/O Testing (`Examples.SimpleIOTest`)

Located in `lib/examples/simple_io_test.ex`, this module provides interactive testing for basic digital I/O cards (EL1809 inputs + EL2809 outputs).

## Automatic Loading in Development

When you start IEx in dev/test mode, examples are automatically loaded and convenient aliases are created:

```bash
iex -S mix
```

You'll see a welcome banner showing available modules and quick start commands.

## Hardware Requirements

- **Position 0**: EK1100 EtherCAT Coupler (Vendor: 0x00000002, Product: 0x044C2C52)
- **Position 1**: EL1809 16-channel digital input terminal (24V DC)
- **Position 2**: EL2809 16-channel digital output terminal (24V DC, 0.5A)

### Wiring Setup

For loopback testing, connect each output channel to its corresponding input channel:
- Output Channel 1 → Input Channel 1
- Output Channel 2 → Input Channel 2
- ... and so on through Channel 16

Alternatively, you can manually control individual channels without loopback wiring.

## Usage

### Quick Start

The `.iex.exs` file provides a convenient `IOTest` alias:

```elixir
# Start hardware
IOTest.start()

# Run visual test
IOTest.pattern_test()

# Run automated wiring verification  
IOTest.loopback_test()

# Manual control
IOTest.set_output(0, true)
IOTest.get_input(0)

# Clean shutdown
IOTest.stop()
```

### Full Module Name

You can also use the full module name:

```elixir
Examples.SimpleIOTest.start()
```

### Available Functions

#### Basic I/O Operations

```elixir
# Set a single output channel (0-15) to ON or OFF
IOTest.set_output(0, true)   # Turn on channel 0
IOTest.set_output(5, false)  # Turn off channel 5

# Read a single input channel (0-15)
{:ok, state} = IOTest.get_input(0)
IO.puts("Input 0 is #{state}")

# Set all 16 outputs at once
IOTest.set_all_outputs([
  true, false, true, false,   # Channels 0-3
  true, false, true, false,   # Channels 4-7
  false, false, false, false, # Channels 8-11
  false, false, false, false  # Channels 12-15
])

# Read all 16 inputs at once
{:ok, states} = IOTest.get_all_inputs()
IO.inspect(states)

# Toggle all outputs (flip current state)
IOTest.toggle_all()
```

#### Test Functions

```elixir
# Visual pattern test - lights up each channel sequentially
IOTest.pattern_test()        # Run once
IOTest.pattern_test(3)       # Run 3 cycles

# Automated loopback test - verifies output→input wiring
{:ok, results} = IOTest.loopback_test()
# Results show :pass or {:fail, reason} for each channel
```

#### Real-time Monitoring

Subscribe to input changes to receive notifications:

```elixir
# Subscribe to channel 0 changes
IOTest.subscribe_input(0)

# Now toggle the output
IOTest.set_output(0, true)

# Check mailbox for notifications
flush()
# => {:pdo_value_changed, :default_domain, "digital_inputs:Input:Channel_1", <<1>>}

# Unsubscribe when done
IOTest.unsubscribe_input(0)
```

### Custom IEx Helpers

The `.iex.exs` file also provides custom helpers:

```elixir
# Automated quick start (starts master + runs pattern test)
quick_start()

# View master internal state
master_state()

# List all EtherCAT-related processes
ethercat_processes()
```

## Example Session

Here's a complete example session:

```elixir
# Start IEx (examples auto-load in dev mode)
$ iex -S mix

# Welcome banner shows available commands

# Start hardware
iex> IOTest.start()
# => [info] Master 0 initialized
# => [info] Hardware configured and activated!
# => :ok

# Run a visual test
iex> IOTest.pattern_test()
# => Lights up each channel in sequence
# => :ok

# Verify wiring with automated test
iex> IOTest.loopback_test()
# => {:ok, %{0 => :pass, 1 => :pass, ..., 15 => :pass}}

# Manual control
iex> IOTest.set_output(0, true)
# => :ok

iex> IOTest.get_input(0)
# => {:ok, true}

# Subscribe to changes
iex> IOTest.subscribe_input(0)
# => :ok

iex> IOTest.set_output(0, false)
# => :ok

iex> flush()
# => {:pdo_value_changed, :default_domain, "digital_inputs:Input:Channel_1", <<0>>}

# Clean up
iex> IOTest.stop()
# => :ok
```

## Troubleshooting

**Hardware not detected:**
- Verify EtherCAT cable connections
- Check that all slaves show up: `ethercat slaves` (command-line tool)
- Ensure you have proper permissions to access `/dev/EtherCAT0`

**Loopback test failures:**
- Verify physical wiring between output and input terminals
- Check terminal power supply (24V DC)
- Ensure common ground between output and input cards

**Permission denied errors:**
- Add your user to the appropriate group (usually `ethercat` or `root`)
- Or run with sudo: `sudo iex -S mix`

**State not changing:**
- Verify cyclic communication is active (started successfully)
- Check for errors in logs
- Ensure hardware is in OP (operational) state

**Module not found:**
- Make sure you're in dev or test environment
- Compile the project: `mix compile`
- Check that `lib/examples/simple_io_test.ex` exists

## Configuration Files

### `.iex.exs`

The project root contains a `.iex.exs` file that:
- Automatically loads in dev/test environments
- Creates convenient aliases (`IOTest`, `Master`, etc.)
- Defines custom helpers (`quick_start()`, `master_state()`)
- Configures IEx with nice colors and formatting
- Shows a welcome banner with quick start commands

You can customize this file to add your own helpers and aliases.

### `SimpleHardwareConfig`

Located in `test/support/simple_hardware_config.ex`, this module defines the hardware topology. It's automatically loaded by `.iex.exs` and used by `Examples.SimpleIOTest`.

## Adding More Examples

To add new example modules:

1. Create a new `.ex` file in `lib/examples/`
2. Use the `Examples.YourModule` namespace
3. Include clear `@moduledoc` and `@doc` documentation
4. Add type specs (`@spec`) for public functions
5. Update `.iex.exs` to create convenient aliases
6. Update this README with usage instructions

### Example Template

```elixir
defmodule Examples.YourExample do
  @moduledoc \"\"\"
  Brief description of what this example demonstrates.

  ## Hardware Setup
  - List hardware requirements

  ## Quick Start
      Examples.YourExample.start()
      Examples.YourExample.do_something()
  \"\"\"

  @doc \"\"\"
  Description of function.
  \"\"\"
  @spec your_function() :: :ok | {:error, term()}
  def your_function do
    # Implementation
  end
end
```

## Contributing

When adding examples, please:
- Use clear, descriptive function names
- Include comprehensive documentation
- Add type specs for all public functions
- Add error handling and logging
- Provide usage examples in documentation
- Test on real hardware before committing
- Follow the existing code style
