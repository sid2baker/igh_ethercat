# EtherCAT

**Declarative** real-time EtherCAT master for Elixir via Zig NIFs, wrapping [IgH EtherCAT Master](https://etherlab.org/en/ethercat/).

Define your hardware configuration once using a beautiful Spark DSL, then use semantic names for all I/O operations.

## Installation

```elixir
def deps do
  [
    {:ethercat, "~> 0.1.0"},
    {:spark, "~> 2.0"}
  ]
end
```

**Requirements:** IgH EtherCAT Master (libethercat + kernel module), Zig 0.15.2, Elixir 1.19+, Linux

## Quick Start

### 1. Define Your Hardware

```elixir
defmodule MyMachine do
  use EtherCAT.Config

  # Define domains with update intervals
  domain :fast_loop, interval: 1      # 1ms critical control
  domain :slow_loop, interval: 10     # 10ms diagnostics

  # Configure each slave
  slave position: 0, name: :temp_sensor do
    driver EtherCAT.Drivers.EL3202
    expect vendor: 0x00000002, product: 0x0C5A3052

    config do
      limit1 1000
      limit2 2000
      filter :enabled
    end

    entry :ch1, :value, domain: :fast_loop
    entry :ch1, :error, domain: :slow_loop
    entry :ch2, :value, domain: :fast_loop
  end

  slave position: 1, name: :valve_outputs do
    driver EtherCAT.Drivers.EL2008

    entry :ch1, :value, domain: :fast_loop
    entry :ch2, :value, domain: :fast_loop
    entry :ch3, :value, domain: :fast_loop
  end
end
```

### 2. Use Your Configuration

```elixir
# Open system with configuration
{:ok, system} = EtherCAT.open(MyMachine)

# Read using semantic names
{:ok, temp} = EtherCAT.read(system, :temp_sensor, :ch1, :value)
{:ok, error} = EtherCAT.read(system, :temp_sensor, :ch1, :error)

# Write using semantic names
:ok = EtherCAT.write(system, :valve_outputs, :ch1, :value, true)
:ok = EtherCAT.write(system, :valve_outputs, :ch2, :value, false)

# Subscribe to changes
:ok = EtherCAT.watch(system, :temp_sensor, :ch1, :value)
receive do
  {:pdo_value_changed, _name, new_temp} ->
    IO.puts("Temperature changed: #{new_temp}")
end

# Cleanup
EtherCAT.close(system)
```

## Discovery Mode

Don't know your hardware configuration yet? Use discovery mode:

```elixir
# Connect without configuration
{:ok, system} = EtherCAT.open()

# Generate configuration from discovered hardware
config = EtherCAT.generate_config(system)
IO.inspect(config, pretty: true)

# Use the output to create your Spark DSL module
```

## Why Declarative?

### Before (Imperative)
```elixir
{:ok, master, [s0, s1]} = EtherCAT.open()
{:ok, _} = EtherCAT.configure_slave(s0, %{})
{:ok, [h1, h2, h3]} = EtherCAT.register_entries(s0, [{:ch1, :value}, {:ch1, :error}])
EtherCAT.start_cyclic(master)
{:ok, temp} = EtherCAT.read(h1)  # Which entry is h1 again?
```

### After (Declarative)
```elixir
{:ok, system} = EtherCAT.open(MyMachine)
{:ok, temp} = EtherCAT.read(system, :temp_sensor, :ch1, :value)  # Clear!
```

**Benefits:**
- ✅ **Type-safe**: Spark validates at compile time
- ✅ **Self-documenting**: Configuration is the documentation
- ✅ **Semantic names**: No more tracking PIDs and handles
- ✅ **Reusable**: Same config across dev/test/prod
- ✅ **Version controlled**: Hardware config in your repo

## Configuration

By default, the library looks for IgH EtherCAT headers and libraries at:
- **Host:** `/usr/local/include` and `/usr/local/lib64`
- **Nerves:** Auto-detected from `NERVES_SDK_SYSROOT`

Override these paths in your application config if needed:

```elixir
# config/config.exs or config/host.exs
config :ethercat,
  igh_include_dir: "/opt/etherlab/include",
  igh_lib_dir: "/opt/etherlab/lib"
```

For Nerves projects, paths are automatically detected from the sysroot. You can override them in `config/target.exs` if using a custom Nerves system:

```elixir
# config/target.exs
config :ethercat,
  igh_include_dir: "#{System.get_env("NERVES_SDK_SYSROOT")}/usr/include",
  igh_lib_dir: "#{System.get_env("NERVES_SDK_SYSROOT")}/usr/lib"
```

## Architecture

```
┌─────────────────────────────────────────────┐
│ Spark DSL Configuration                     │
│   MyMachine module (compile-time validated)│
├─────────────────────────────────────────────┤
│ EtherCAT.System (orchestration)            │
│   ├─ Semantic name lookup                   │
│   └─ Multi-domain routing                   │
├─────────────────────────────────────────────┤
│ EtherCAT.Master (gen_statem)               │
│   State: offline → synced → operational     │
│   ├─ Slave (per device)                     │
│   └─ Domain (PDO grouping)                  │
├─────────────────────────────────────────────┤
│ Zig NIF Layer (22KB)                       │
│   ├─ Cyclic task (µs timing)               │
│   ├─ Bit-level change detection            │
│   └─ Zero-copy domain access               │
├─────────────────────────────────────────────┤
│ IgH EtherCAT Master (C/Kernel)             │
└─────────────────────────────────────────────┘
```

### Configuration Flow

The declarative system follows EtherLab's recommended configuration sequence:

1. **SDO Configuration** (Service Data Objects)
   - Set device parameters (modes, limits, sample rates)
   - Happens in driver's `configure/2` callback

2. **PDO Configuration** (Process Data Objects) - **Done Upfront**
   - Configure sync managers
   - Clear and assign ALL PDO assignments
   - Clear and add ALL PDO entry mappings
   - Complete before any domain registration

3. **Domain Registration**
   - Route entries to domains (on-demand)
   - No hardware configuration, just memory mapping

4. **Cyclic Operation**
   - Start cyclic communication
   - Configuration locked

This ensures all hardware configuration happens atomically during `configure_slave`, making `register_entry` a pure domain routing operation.

## Multi-Domain Support

Organize entries by update rate for efficient control loops:

```elixir
defmodule MyMachine do
  use EtherCAT.Config

  domain :critical, interval: 1    # 1ms - servo control
  domain :normal, interval: 10     # 10ms - I/O
  domain :monitoring, interval: 100  # 100ms - diagnostics

  slave position: 0, name: :servo do
    driver MyServoDriver

    entry :position, :actual, domain: :critical
    entry :velocity, :actual, domain: :critical
    entry :position, :setpoint, domain: :critical
    entry :temperature, :motor, domain: :monitoring
    entry :error_flags, :all, domain: :monitoring
  end
end
```

Each domain creates its own FMMU (Fieldbus Memory Management Unit) mapping, allowing different update rates for the same sync manager.

## Custom Drivers

Device-specific drivers encapsulate PDO mappings and configuration:

```elixir
defmodule MyDriver do
  @behaviour EtherCAT.Slave.Driver

  def list_pdos(_state), do: [:ch1, :ch2]

  def pdo_info(_state, :ch1) do
    {:ok,
     %{
       sync_manager: {2, :input, :disable},  # SM index, direction, watchdog
       pdo_index: 0x1A00,
       entries: %{
         value: {:sint16, 0x6000, 0x01, 16},
         error: {:uint8, 0x6000, 0x02, 8}
       }
     }}
  end

  def configure(_ctx, state, config) do
    # Optional: Configure device via SDO before PDO setup
    # Slave.config_sdo(ctx.slave_pid, 0x8000, 0x01, <<value::16>>)
    {:ok, Map.merge(state, config)}
  end

  def supports_pdo_config?(_state), do: true

  # Optional: Custom encoding/decoding
  def decode_value(_state, :ch1, :value, binary) do
    <<value::little-signed-16>> = binary
    {:ok, value / 10.0}  # Convert to engineering units
  end

  def encode_value(_state, :ch1, :setpoint, value) do
    {:ok, <<trunc(value * 10)::little-signed-16>>}
  end
end
```

**Generic driver** auto-discovers PDOs from EEPROM for devices without specific drivers.

## Hardware Verification

The system can verify connected hardware matches your configuration:

```elixir
slave position: 0, name: :temp_sensor do
  driver EtherCAT.Drivers.EL3202
  expect vendor: 0x00000002, product: 0x0C5A3052  # ← Verified at runtime
  # ...
end
```

If hardware doesn't match, `EtherCAT.open/1` returns a detailed error:
```elixir
{:error, {:hardware_mismatch, 0, "Expected vendor 0x2, product 0x0C5A3052, but found vendor 0x2, product 0x07D83052"}}
```

## API Reference

### System Operations

- `EtherCAT.open(config_module, opts)` - Open with Spark DSL configuration
- `EtherCAT.open(opts)` - Open in discovery mode
- `EtherCAT.close(system)` - Close and release resources
- `EtherCAT.generate_config(system)` - Generate config from discovered hardware

### I/O Operations

- `EtherCAT.read(system, slave_name, pdo_name, entry_name)` - Read entry value
- `EtherCAT.write(system, slave_name, pdo_name, entry_name, value)` - Write entry value
- `EtherCAT.watch(system, slave_name, pdo_name, entry_name)` - Subscribe to changes
- `EtherCAT.unwatch(system, slave_name, pdo_name, entry_name)` - Unsubscribe

## Troubleshooting

**Permission Denied:**
```bash
sudo chmod 666 /dev/EtherCAT0
# or
sudo usermod -a -G ethercat $USER
```

**No Slaves Found:**
- Check physical connections and power
- Verify kernel module: `lsmod | grep ec_`
- Check master state: `ethercat master`

**Hardware Mismatch:**
- Use discovery mode to see actual hardware
- Update `expect vendor:` and `product:` in config
- Check slave position numbers

**Compilation Errors:**
- Run `mix deps.get` to install Spark
- Ensure driver modules are compiled
- Check DSL syntax (domains before slaves)

## License

[See LICENSE file]
