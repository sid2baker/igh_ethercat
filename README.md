# EtherCAT

Real-time EtherCAT master for Elixir/Erlang via Zig NIFs, wrapping [IgH EtherCAT Master](https://etherlab.org/en/ethercat/). Built for industrial automation, robotics, and distributed control.

## Quick Start

```elixir
# Open master, auto-discover and configure slaves
{:ok, master, slaves} = EtherCAT.open(index: 0)

# Configure first slave with generic driver (auto-discovers PDOs)
{:ok, pdos} = EtherCAT.configure_slave(master, hd(slaves), %{})

# Register PDOs for I/O
{:ok, handles} = EtherCAT.register_pdos(master, hd(slaves), pdos)

# Start cyclic operation
EtherCAT.start_cyclic(master)

# Read/Write
EtherCAT.read(hd(handles))        # => {:ok, false}
EtherCAT.write(hd(handles), true) # => :ok

# Subscribe to changes
EtherCAT.watch(hd(handles))       # => {:data_changed, "pdo_name", true}
```

## Installation

```elixir
def deps do
  [{:ethercat, "~> 0.1.0"}]
end
```

**Requirements:** IgH EtherCAT Master (libethercat + kernel module), Zig 0.15.2, Elixir 1.19+

## Architecture

```
EtherCAT.Master (GenStatem)          Manages network lifecycle
  ├─ State: offline → stale          Link detection
  │        → synced → operational    Slave config → Cyclic I/O
  ├─ Slave (GenServer)               Per-device configuration
  └─ Domain (GenServer)              PDO grouping & updates

Zig NIF Layer (22KB)                 30+ native functions
  ├─ Cyclic task (µs timing)         Deterministic real-time loop
  ├─ Bit-level change detection      XOR-based diffing
  └─ Zero-copy domain access         Direct memory access

IgH EtherCAT Master (C)              Linux kernel module
```

## Key Features

**Real-Time**: Microsecond-precision cyclic tasks, zero-copy I/O, preemptable NIFs
**OTP-Native**: GenStatem/GenServer architecture, Registry-based discovery, telemetry
**Flexible**: Generic auto-discovery driver or custom device-specific drivers
**Multi-Master**: Independent networks with scoped domains

## State Machine

```
:offline ──connect──▶ :stale ──sync_slaves──▶ :synced ──activate──▶ :operational
    ▲                                                                      │
    └──────────────────────────────── shutdown ─────────────────────────┘
```

**States:**
- `:offline` - No link, NIF master created
- `:stale` - Link up, waiting for enumeration
- `:synced` - Slaves discovered, configuration allowed
- `:operational` - Cyclic task running, real-time I/O active

## Multi-Master Example

```elixir
# Two independent networks
{:ok, master1, _slaves1} = EtherCAT.open(index: 0)
{:ok, master2, _slaves2} = EtherCAT.open(index: 1)

# Same domain names, no collision
EtherCAT.create_domain(master1, :default, 1)
EtherCAT.create_domain(master2, :default, 1)
```

## Custom Driver

```elixir
defmodule MyDriver do
  use EtherCAT.Slave.Driver

  def list_pdos(_state), do: [:input_1, :output_1]

  def pdo_info(_state, :input_1) do
    {:ok, %{
      sync_manager: {0, 2, 0},  # SM0, input, no watchdog
      pdo_index: 0x1A00,
      entry: {0x6000, 0x01, 1}  # index, subindex, bits
    }}
  end
end
```

## Documentation

- **[OTP_PATTERNS.md](OTP_PATTERNS.md)** - Supervision, Registry, error handling
- **[TELEMETRY.md](TELEMETRY.md)** - Monitoring events and metrics

## Limitations

- Linux-only (IgH requirement)
- Requires root or `CAP_NET_RAW`
- Hard real-time needs RT kernel patches
- Zig 0.15.2 specific

## License

[See LICENSE file]
