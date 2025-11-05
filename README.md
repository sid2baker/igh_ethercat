# EtherCAT

A real-time EtherCAT master implementation for Elixir/Erlang, wrapping the IgH EtherCAT Master library via Zig NIFs. Designed for industrial automation, robotics, and distributed control systems requiring deterministic fieldbus communication.

**Based on:** [IgH EtherCAT Master](https://etherlab.org/en/ethercat/) - the open-source EtherCAT master stack for Linux

## Architecture

```
┌─────────────────────────────────────────┐
│  Elixir/OTP Layer                       │
│  ├─ Master (GenStatem)                  │
│  │  └─ State Machine: offline → stale  │
│  │     → synced → operational           │
│  ├─ Domain (GenServer)                  │
│  │  └─ PDO registration & data routing  │
│  └─ Slave (GenServer)                   │
│     └─ Pluggable driver architecture    │
└─────────────────────────────────────────┘
              ↓
┌─────────────────────────────────────────┐
│  Zig NIF Layer (22KB compiled)          │
│  ├─ 30+ native functions                │
│  ├─ Threaded cyclic task (µs timing)    │
│  ├─ Bit-level change detection          │
│  └─ Zero-copy domain access             │
└─────────────────────────────────────────┘
              ↓
┌─────────────────────────────────────────┐
│  IgH EtherCAT Master (C library)        │
│  └─ libethercat via Linux kernel module │
└─────────────────────────────────────────┘
```

## Key Features

**Real-time Safety**
- Zig NIFs with microsecond-precision cyclic tasks
- Preemptable threaded operations with BEAM scheduler integration
- Zero-copy domain data access for minimum latency

**OTP Architecture**
- Master as GenStatem managing network lifecycle
- Per-slave GenServers with supervised failure isolation
- Domains as GenServers for PDO subscription & routing

**Flexible Driver System**
- Generic driver: auto-discovers slave PDOs via EEPROM inspection
- Device-specific drivers: hardcode known mappings for performance
- Driver behavior protocol: `configure/2`, `list_pdos/1`, `pdo_info/2`

**Bit-Level Change Detection**
- Cyclic task compares domain buffers via XOR + `@ctz` for changed bits
- Selective notifications to subscribing processes (offset-based)
- Efficient for high-speed I/O with sparse updates

## Quick Start

```elixir
# Start master and connect to network
{:ok, master} = EtherCAT.Master.start_link(update_interval: 1000)
:ok = EtherCAT.Master.connect(master)

# Discover slaves on bus
{:ok, slaves} = EtherCAT.Master.sync_slaves(master)
[slave1, slave2 | _] = slaves

# Configure slave PDOs (generic driver auto-discovers)
EtherCAT.Slave.configure(slave2, [])
pdos = EtherCAT.Slave.list_pdos(slave2)

# Register PDOs to default domain
EtherCAT.Slave.register_all_pdos(slave2, :default_domain)
EtherCAT.Domain.get_ready(:default_domain)

# Activate for cyclic operation
EtherCAT.Master.activate(master)
```

## Installation

Add to `mix.exs`:

```elixir
def deps do
  [
    {:ethercat, "~> 0.1.0"}
  ]
end
```

**Prerequisites:**
- IgH EtherCAT Master installed (`libethercat` + kernel module)
- Zig 0.15.2
- Elixir 1.19+ / Erlang OTP 28+

## Implementation Details

**Master State Machine:**
1. **:offline** - No network link
2. **:stale** - Link up, waiting for slave enumeration
3. **:synced** - Slaves discovered, configuration allowed
4. **:operational** - Cyclic task running, real-time I/O active

**Cyclic Task (threaded NIF):**
- Runs at configurable interval (default 10ms)
- Sequence: `ecrt_master_receive` → process domains → `ecrt_master_send`
- Monitors: working counter, domain state, master AL state
- Yields to BEAM scheduler every 100ms for fairness

**Domain Management:**
- Pre-activation: register PDO entries (index/subindex → bit offset)
- Post-activation: receive `{:data_changed, data, [offsets]}` messages
- Multiple domains supported with independent update intervals

**Resource Management:**
- Master/Domain/SlaveConfig as NIF resources with RAII cleanup
- Destructor callback releases IgH master on GC

## Driver Example

```elixir
defmodule MyDriver do
  use EtherCAT.Slave.Driver

  def configure(state, _config), do: {:ok, state}

  def list_pdos(_state) do
    [:digital_input_1, :digital_output_1]
  end

  def pdo_info(_state, :digital_input_1) do
    {:ok, %{
      sync_manager: {0, 2, 0},  # SM0, dir=input, no watchdog
      pdo_index: 0x1A00,
      entry: {0x6000, 0x01, 1}  # index, subindex, bits
    }}
  end

  def terminate(_state), do: :ok
end
```

## Known Limitations

- Linux-only (IgH master requirement)
- Requires root or `CAP_NET_RAW` for raw Ethernet access
- Cyclic timing dependent on Linux kernel RT patches for hard real-time
- Zig 0.15.2 specific (uses `ArrayList{}` initialization syntax)

## References

- [IgH EtherCAT Master Documentation](https://etherlab.org/doc/)
- [EtherCAT Technology Group](https://www.ethercat.org/)
- [Zigler - Zig NIFs for Erlang](https://hexdocs.pm/zigler/)

## License

[See LICENSE file]
