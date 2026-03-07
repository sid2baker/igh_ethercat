> **Note:** This project (a NIF-based wrapper around IgH EtherCAT Master) is no longer being worked on. I'm pursuing a pure Elixir approach instead — see [github.com/sid2baker/ethercat](https://github.com/sid2baker/ethercat).

# EtherCAT

An Elixir library for real-time EtherCAT fieldbus communication, built on top of the [IgH EtherCAT Master](https://etherlab.org/en/ethercat/).

## Overview

This library provides a high-level Elixir interface to the IgH EtherCAT Master, enabling real-time process data exchange with EtherCAT slave devices. It uses Zig NIFs via [Zigler](https://github.com/ityonemo/zigler) to interface directly with the `libethercat` C library.

### Key Features

- **State machine-driven master**: Automatic topology detection and hardware validation
- **Declarative hardware configuration**: Define your entire EtherCAT network in Elixir structs
- **Pluggable slave drivers**: Implement custom drivers or use the built-in `GenericDriver`
- **Domain-based PDO management**: Group PDO entries by update rate
- **Real-time cyclic exchange**: Deterministic process data communication
- **Nerves support**: Cross-compilation ready for embedded Linux targets

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Elixir Application                       │
├─────────────────────────────────────────────────────────────────┤
│  EtherCAT.Master (gen_statem)                                   │
│  ├── State machine: offline → stale → synced → operational     │
│  ├── Hardware configuration & validation                        │
│  └── PDO read/write API                                         │
├─────────────────────────────────────────────────────────────────┤
│  EtherCAT.Slave.Driver (behaviour)                              │
│  ├── GenericDriver (built-in)                                   │
│  └── Custom drivers (user-defined)                              │
├─────────────────────────────────────────────────────────────────┤
│  EtherCAT.Master.Nif (Zig NIFs)                                 │
│  ├── Master, Domain, Slave resources                            │
│  ├── Cyclic thread (real-time loop)                             │
│  └── Watch hardware thread (topology monitoring)                │
├─────────────────────────────────────────────────────────────────┤
│  libethercat (IgH EtherCAT Master)                              │
│  └── Kernel module: /dev/EtherCAT0                              │
└─────────────────────────────────────────────────────────────────┘
```

## Master State Machine

The `EtherCAT.Master` is implemented as a `gen_statem` with four states:

```
┌─────────┐     link up      ┌───────┐    config match    ┌────────┐   all slaves    ┌─────────────┐
│ offline │ ───────────────► │ stale │ ─────────────────► │ synced │ ──configured──► │ operational │
└─────────┘                  └───────┘                    └────────┘                 └─────────────┘
     ▲                            │                            │                           │
     │         link down          │                            │        link down          │
     └────────────────────────────┴────────────────────────────┴───────────────────────────┘
```

| State | Description |
|-------|-------------|
| **offline** | No EtherCAT link detected. Polls for link status. |
| **stale** | Link up, monitoring topology. Validates hardware against configuration. |
| **synced** | Hardware matches configuration. Configuring slaves (SDOs, PDOs). |
| **operational** | All slaves configured. Cyclic exchange active. PDO read/write enabled. |

## Hardware Configuration

Define your EtherCAT network using configuration structs:

```elixir
alias EtherCAT.HardwareConfig
alias EtherCAT.HardwareConfig.{DomainConfig, SlaveConfig}

config = %HardwareConfig{
  domains: [
    %DomainConfig{
      name: :fast,
      update_rate_us: 1000  # every cycle (1ms)
    },
    %DomainConfig{
      name: :slow,
      update_rate_us: 10_000  # every 10th cycle (10ms)
    }
  ],
  slaves: [
    %SlaveConfig{
      name: :coupler,
      position: 0,
      device_identity: %{
        vendor_id: 0x00000002,
        product_code: 0x044C2C52,
        revision_no: nil,
        serial_no: nil
      },
      driver: nil,  # no driver needed for couplers
      config: %{},
      registered_entries: %{}
    },
    %SlaveConfig{
      name: :digital_io,
      position: 1,
      device_identity: %{
        vendor_id: 0x00000002,
        product_code: 0x07D43052,
        revision_no: nil,
        serial_no: nil
      },
      driver: EtherCAT.Slave.GenericDriver,
      config: %{
        sdos: [],
        sync_managers: [
          %{
            index: 0,
            direction: :output,
            watchdog: :enabled,
            pdos: %{
              channel_1: %{
                index: 0x1600,
                entries: %{
                  output: {0x7000, 0x01, 1}  # {index, subindex, bit_length}
                }
              }
            }
          }
        ]
      },
      registered_entries: %{
        fast: [{:channel_1, :output}]  # register to :fast domain
      }
    }
  ]
}
```

## Slave Drivers

Slave drivers handle device-specific configuration and provide an interface for PDO access.

### Using GenericDriver

The built-in `GenericDriver` works for most standard EtherCAT slaves:

```elixir
%SlaveConfig{
  driver: EtherCAT.Slave.GenericDriver,
  config: %{
    sdos: [
      %{index: 0x8000, subindex: 0x01, data: <<100, 0>>}
    ],
    sync_managers: [
      %{
        index: 2,
        direction: :output,
        watchdog: :enabled,
        pdos: %{...}
      }
    ]
  }
}
```

### Implementing Custom Drivers

Implement the `EtherCAT.Slave.Driver` behaviour for custom functionality:

```elixir
defmodule MyDriver do
  use EtherCAT.Slave.Driver
  use GenServer

  @impl EtherCAT.Slave.Driver
  def start_driver(name, config) do
    GenServer.start_link(__MODULE__, config, name: name)
  end

  @impl EtherCAT.Slave.Driver
  def configure(driver_pid) do
    GenServer.cast(driver_pid, {:configure, self()})
  end

  @impl GenServer
  def handle_cast({:configure, master_pid}, state) do
    # Configure sync managers
    :ok = sync_manager(master_pid, 0, :output, :enabled)
    :ok = pdo_assign_clear(master_pid, 0)
    :ok = pdo_assign_add(master_pid, 0, 0x1600)
    :ok = pdo_mapping_clear(master_pid, 0x1600)
    :ok = pdo_mapping_add(master_pid, 0x1600, 0x7000, 0x01, 8)

    # Signal configuration complete
    configured_pdos = %{
      {:channel_1, :output} => {:output, {0x7000, 0x01, 8}}
    }
    :ok = slave_configured(master_pid, configured_pdos)

    {:noreply, state}
  end

  # Handle PDO updates from the cyclic thread
  @impl GenServer
  def handle_info({:ec_update, {_slave, pdo, entry}, value}, state) do
    # Process input PDO change
    {:noreply, state}
  end
end
```

### Driver Helper Functions

The `use EtherCAT.Slave.Driver` macro injects these helper functions:

| Function | Description |
|----------|-------------|
| `sdo_config/4` | Configure SDO: `(master_pid, index, subindex, data)` |
| `sync_manager/4` | Configure sync manager: `(master_pid, index, direction, watchdog)` |
| `pdo_assign_clear/2` | Clear PDO assignments for sync manager |
| `pdo_assign_add/3` | Assign PDO to sync manager |
| `pdo_mapping_clear/2` | Clear PDO entry mappings |
| `pdo_mapping_add/5` | Add PDO entry mapping |
| `slave_configured/2` | Signal configuration complete |

## Usage

### Starting the Master

```elixir
# Start with configuration
{:ok, pid} = EtherCAT.Master.start_link(
  name: :my_master,
  master_index: 0,
  hardware_config: config
)

# Or start without config and set later
{:ok, pid} = EtherCAT.Master.start_link(name: :my_master, master_index: 0)
:ok = EtherCAT.Master.set_hardware_config(:my_master, config)
```

### Reading and Writing PDOs

Once the master reaches `:operational` state:

```elixir
# Read PDO entry
{:ok, <<value>>} = EtherCAT.Master.read_pdo_entry(:my_master, {:digital_io, :channel_1, :output})

# Write PDO entry
:ok = EtherCAT.Master.write_pdo_entry(:my_master, {:digital_io, :channel_1, :output}, <<1>>)
```

### Supervision

```elixir
children = [
  {EtherCAT.Master, [
    name: :ethercat_master,
    master_index: 0,
    hardware_config: config
  ]}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

## Domains

Domains group PDO entries that share the same update rate. Each domain has an `update_rate_us` that determines how often it's processed. The master's cyclic interval is automatically derived from the smallest domain `update_rate_us`.

```elixir
domains: [
  %DomainConfig{name: :fast, update_rate_us: 1000},     # every 1ms
  %DomainConfig{name: :slow, update_rate_us: 100_000}   # every 100ms
]
```

Register slave entries to domains via `registered_entries`:

```elixir
registered_entries: %{
  fast: [{:position, :value}, {:velocity, :value}],
  slow: [{:temperature, :value}]
}
```

## Cyclic Thread

The NIF spawns a real-time cyclic thread that:

1. Sets application time for distributed clocks
2. Receives EtherCAT frames (`ecrt_master_receive`)
3. Processes each domain (`ecrt_domain_process`)
4. Detects PDO value changes and notifies the master
5. Queues domain data (`ecrt_domain_queue`)
6. Sends EtherCAT frames (`ecrt_master_send`)
7. Sleeps until next cycle

PDO changes trigger messages to the master:
- `{:output_changed, slave_id, entry_id}` - output was written to bus
- `{:input_changed, slave_id, entry_id, value}` - input value changed

## Installation

### Prerequisites

1. **IgH EtherCAT Master** installed and configured
2. **Zig compiler** (for building NIFs)
3. **Zigler** dependency

### Dependencies

```elixir
def deps do
  [
    {:zigler, "~> 0.13", runtime: false}
  ]
end
```

### Configuration

```elixir
# config/config.exs
config :ethercat,
  igh_include_dir: "/usr/local/include",
  igh_lib_dir: "/usr/local/lib64"
```

For Nerves targets, these paths are automatically resolved from `NERVES_SDK_SYSROOT`.

## Testing with FakeEtherCAT

For testing without hardware, the library links against `libfakeethercat` in test mode. This allows running the full stack with simulated slaves using RtIPC shared memory.

See `test/fakeethercat/` for integration test examples.

## Project Structure

```
lib/
├── ethercat.ex                      # Top-level module
├── ethercat/
│   ├── master.ex                    # Master state machine (gen_statem)
│   ├── master/
│   │   ├── nif.ex                   # Zigler NIF definitions
│   │   ├── main.zig                 # NIF implementations
│   │   ├── master.zig               # Master state management
│   │   ├── domain.zig               # Domain & PDO entry management
│   │   ├── slave.zig                # Slave configuration
│   │   ├── thread.zig               # Cyclic & watch threads
│   │   ├── types.zig                # Type definitions
│   │   ├── errors.zig               # Error types
│   │   └── ecrt.zig                 # C header import
│   ├── slave/
│   │   ├── driver.ex                # Driver behaviour
│   │   └── generic_driver.ex        # Built-in generic driver
│   └── hardware_config/
│       ├── master_config.ex         # Master configuration struct
│       ├── domain_config.ex         # Domain configuration struct
│       └── slave_config.ex          # Slave configuration struct
```

## License

See LICENSE file for details.
