# EtherCAT

Real-time EtherCAT master for Elixir/Erlang via Zig NIFs, wrapping [IgH EtherCAT Master](https://etherlab.org/en/ethercat/).

## Installation

```elixir
def deps do
  [{:ethercat, "~> 0.1.0"}]
end
```

**Requirements:** IgH EtherCAT Master (libethercat + kernel module), Zig 0.15.2, Elixir 1.19+, Linux

## Quick Start

```elixir
# Open master and discover slaves
{:ok, master, slaves} = EtherCAT.open(index: 0)

# Configure slaves
{:ok, pdos} = EtherCAT.configure_slave(master, hd(slaves), %{})

# Register PDOs and get handles
{:ok, handles} = EtherCAT.register_pdos(master, hd(slaves), pdos)

# Start cyclic communication
EtherCAT.start_cyclic(master)

# Read/write
EtherCAT.write(hd(handles), true)
{:ok, value} = EtherCAT.read(hd(handles))

# Subscribe to changes
EtherCAT.watch(hd(handles))
receive do
  {:data_changed, _name, val} -> IO.puts("Changed: #{val}")
end

# Cleanup
EtherCAT.close(master)
```

## Architecture

```
┌─────────────────────────────────────────────┐
│ Application Layer (Your Code)               │
├─────────────────────────────────────────────┤
│ EtherCAT.Master (GenStatem)                │
│   ├─ State: offline → stale → synced       │
│   │          → operational                  │
│   ├─ Slave (GenServer) - per device        │
│   └─ Domain (GenServer) - PDO grouping     │
├─────────────────────────────────────────────┤
│ Zig NIF Layer (22KB)                       │
│   ├─ Cyclic task (µs timing)               │
│   ├─ Bit-level change detection            │
│   └─ Zero-copy domain access               │
├─────────────────────────────────────────────┤
│ IgH EtherCAT Master (C/Kernel)             │
└─────────────────────────────────────────────┘
```

### State Machine

Master transitions through four states:

- `:offline` - Master created, not connected
- `:stale` - Link up, waiting for enumeration
- `:synced` - Slaves discovered, configuration allowed
- `:operational` - Cyclic task running, I/O active

### OTP Supervision

```
EtherCAT.Supervisor (one_for_one)
  └─ EtherCAT.Registry (process discovery)

EtherCAT.Master (standalone/supervised)
  ├─ Domains (linked, not supervised)
  └─ Slaves (linked, not supervised)
```

**Why linking instead of supervision?** Slaves and Domains are tightly coupled to Master's NIF resources. When Master dies, NIF resources become invalid, so children must die too. Restarting them independently would create orphaned processes with dead references.

## Multi-Rate Domains

Group PDOs by update frequency:

```elixir
# Fast I/O (every cycle)
EtherCAT.create_domain(master, :fast_io, 1)

# Slow sensors (every 100 cycles)
EtherCAT.create_domain(master, :slow, 100)

# Register PDOs to specific domains
EtherCAT.register_pdos(master, slave, pdos, :fast_io)
```

## Custom Drivers

Device-specific drivers encapsulate PDO mappings and configuration:

```elixir
defmodule MyDriver do
  use EtherCAT.Slave.Driver

  def list_pdos(_state), do: [:input_1, :output_1]

  def pdo_info(_state, :input_1) do
    {:ok, %{
      sync_manager: {0, 2, 0},
      pdo_index: 0x1A00,
      entry: {0x6000, 0x01, 1}
    }}
  end
end
```

**Generic driver** auto-discovers PDOs from EEPROM for devices without specific drivers.

## Hardware Testing

Hardware tests require actual EtherCAT slaves connected to `/dev/EtherCAT0`.

### Typical Setup

- **EK1100** - Bus coupler
- **EL1809** - 16ch digital input
- **EL2809** - 16ch digital output
- Physical loopback wire (output 1 → input 1)

### Running Tests

```bash
# Run all hardware tests
mix test test/hardware/ --include hardware

# Run specific test
mix test test/hardware/basic_io_test.exs --include hardware
```

### Interactive Testing

```elixir
iex -S mix

# Run hardware test interactively
{master, input, output} = Hardware.BasicIOTest.run()

# Experiment with devices
EtherCAT.list_pdos(input)
EtherCAT.set_pdo(output, "pdo_7000:1", true)

# Cleanup
GenServer.stop(master)
```

### Troubleshooting

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

**Link Down:**
- Verify network cable connected
- Ensure no other process using EtherCAT master

See `test/hardware/README.md` for detailed hardware test documentation.

## License

[See LICENSE file]
