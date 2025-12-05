# EtherCAT

**Real-time industrial automation** via declarative EtherCAT master in Elixir, powered by Zig NIFs wrapping [IgH EtherCAT Master](https://etherlab.org/en/ethercat/).

Define your hardware configuration once with type-safe structs, then use semantic names and direct slave PIDs for all I/O operations. Real-time cyclic I/O runs at microsecond precision in a separate thread.

## Installation

```elixir
def deps do
  [
    {:ethercat, "~> 0.1.0"}
  ]
end
```

Add to your application supervision tree:

```elixir
def start(_type, _args) do
  children = [
    {EtherCAT, master_index: 0}  # Starts EtherCAT.Master
  ]

  Supervisor.start_link(children, strategy: :one_for_one)
end
```

**Requirements:** 
- IgH EtherCAT Master (libethercat + kernel module)
- Zig 0.15.2 (compile-time only)
- Elixir 1.19+
- Linux (kernel module required)

## Core Concept

The library separates **configuration** from **operation**:

```
CONFIG PHASE (blocking)          OPERATION PHASE (real-time async)
─────────────────────────────────────────────────────────────────
1. Master starts, waits for link
2. Hardware detected, topology stable
3. Config applied: PDO mappings, SDOs, etc.
4. Slave drivers started
5. Domains created
6. Cyclic task started ───────────→ Continuous I/O at fixed rate
                                  - Read sensor values from network
                                  - Detect changes, send notifications
                                  - Write output values to network
                                  - Synchronize clocks
                                  - Recovery on errors
```

**Two-Phase Usage:**

```elixir
# Phase 1: Start infrastructure (happens automatically)
{:ok, _} = EtherCAT.start_link(master_index: 0, name: EtherCAT.Master)

# Phase 2: Configure hardware (blocks until ready, then runs async)
{:ok, slaves} = EtherCAT.configure_hardware(EtherCAT.Master, MyMachine)
# slaves = %{temp_sensor: #PID<0.123.0>, valve1: #PID<0.124.0>}

# Phase 3: Use slave PIDs directly for I/O
{:ok, temp} = EtherCAT.read(slaves.temp_sensor, :ch1, :value)
:ok = EtherCAT.write(slaves.valve1, :ch1, :value, true)
```

## Quick Start

### 1. Define Your Hardware

Hardware configuration is a module with `hardware_config/0` function returning a `HardwareConfig` struct:

```elixir
defmodule MyMachine do
  alias EtherCAT.Config
  
  def hardware_config do
    %Config.HardwareConfig{
      master: %Config.MasterConfig{
        index: 0,
        cycle_interval: 10_000,      # 10ms cycle
        nif_yield_interval: 100_000   # Yield to BEAM every 100ms
      },
      domains: [
        %Config.DomainConfig{name: :fast_loop, cycle_multiplier: 1},
        %Config.DomainConfig{name: :slow_loop, cycle_multiplier: 10}
      ],
      slaves: [
        %Config.SlaveConfig{
          position: 0,
          name: :temp_sensor,
          device_identity: %{
            vendor_id: 0x00000002,
            product_code: 0x0C5A3052
          },
          driver: nil,  # Auto-discovery
          config: %{},
          registered_entries: %{
            fast_loop: [{:ch1, :value}, {:ch1, :error}],
            slow_loop: [{:ch1, :status}]
          }
        },
        %Config.SlaveConfig{
          position: 1,
          name: :valve_outputs,
          device_identity: %{vendor_id: 0x00000002, product_code: 0x0C5A3053},
          driver: MyDriver,  # Custom driver
          config: %{limits: [1000, 2000]},
          registered_entries: %{
            fast_loop: [{:ch1, :value}, {:ch2, :value}]
          }
        }
      ]
    }
  end
end
```

### 2. Configure and Use

```elixir
# Get master PID (started by supervisor)
master = Process.whereis(EtherCAT.Master)

# Configure hardware - blocks until link up, hardware stable, all slaves synced
{:ok, slaves} = EtherCAT.configure_hardware(master, MyMachine)

# Now use slave PIDs for I/O
{:ok, temp} = EtherCAT.read(slaves.temp_sensor, :ch1, :value)
:ok = EtherCAT.write(slaves.valve_outputs, :ch1, :value, true)

# Subscribe to changes
:ok = EtherCAT.watch(slaves.temp_sensor, :ch1, :value)

receive do
  {:pdo_value_changed, _name, new_temp} ->
    IO.puts("Temperature: #{new_temp}°C")
end
```

## How It Works

### Master State Machine

The Master is a 4-state FSM that progresses from disconnected to operational:

```
:offline → :stale → :synced → :operational
            ↓ ↑                    ↓
            └──────────────────────┘
              (on hardware change)
```

**:offline**
- No EtherCAT link detected
- Waiting for connection
- No slaves known

**:stale**
- Link is up, but topology unstable
- Monitor hardware for stability (1 second timeout)
- Detect topology changes (slave count)
- Once stable → verify and transition to :synced

**:synced**
- Hardware verified and stable
- Slave drivers started
- Domains created (but cyclic task not running)
- Subscribers can be added
- Can apply new configuration

**:operational**
- Cyclic task running
- Real-time I/O active
- Slaves in OP state
- All domains processing every cycle or at cycle_multiplier boundaries
- Notifications sent on changes

### Configuration Application

When you call `configure_hardware/2`:

1. **Validation**: Check config structure, references, etc.
2. **Wait for Link**: Block until EtherCAT link up
3. **Detect Hardware**: Poll for stable topology (1 second)
4. **Apply Config** (atomic):
   - Stop existing slaves and domains
   - For each slave:
     - Apply SDO configuration (device parameters)
     - Configure sync managers and PDO mappings
     - Start driver process
   - Create domain refs and entry routing
5. **Start Cyclic**: Launch real-time task in separate thread
6. **Wait for OP**: Block until all slaves in operational state
7. **Return**: Map of slave names → PIDs

### Cyclic Task (Real-Time Loop)

The `cyclic_task` function (Zig NIF) runs in a separate OS thread at fixed intervals:

```
Loop every cycle_interval (e.g., 10ms):
  1. Sync clock with EtherCAT master
  2. Receive frames from network (slave responses)
  3. For each domain:
     - If time for this domain (cycle % multiplier == 0):
       a. Process domain (update buffer from received frame)
       b. Detect changes: compare buffer with cached values
       c. For inputs: send {:pdo_value_changed, ...} if changed
       d. For outputs: write cached values back to buffer
       e. Queue domain for transmission
  4. Check master state (OP, INIT, etc.)
  5. Send frames to network (slave commands)
  6. Sleep to maintain exact cycle rate
  7. Periodically yield to BEAM scheduler
```

**Change Detection**: The task keeps `current_value` cached for each entry. It compares the domain buffer against cached values. On mismatch:
- **Inputs**: Sends `{:pdo_value_changed, unique_name, value}` to subscribers
- **Outputs**: Writes cached value back to domain (confirms delivery)

**Overrun Handling**: If a cycle takes longer than the interval, the task:
- Logs warning with diagnostic info
- Sends `{:cycle_overrun_alert, ...}` to Master
- Skips cycles if overrun > 50% of interval
- Never blocks (deterministic)

### Multi-Domain Support

Domains allow different update rates for the same device:

```elixir
domains: [
  %DomainConfig{name: :critical, cycle_multiplier: 1},    # Every cycle (10ms)
  %DomainConfig{name: :normal, cycle_multiplier: 5},      # Every 5 cycles (50ms)
  %DomainConfig{name: :monitoring, cycle_multiplier: 100} # Every 100 cycles (1s)
]
```

Each domain gets its own FMMU (Fieldbus Memory Management Unit), allowing:
- Servo control at 1ms
- I/O at 10ms
- Diagnostics at 100ms
- All in one cycle_interval

## Custom Drivers

Drivers encapsulate device-specific logic:

```elixir
defmodule MyTemperatureSensor do
  @behaviour EtherCAT.Slave.Driver
  
  # Describe PDOs that this device supports
  def get_pdo_config(_state) do
    [
      %{
        sync_manager: {2, :input, :disabled},
        pdo_index: 0x1A00,
        pdo_name: :ch1,
        entries: %{
          value: {0x6000, 0x01, 16},   # CoE index/subindex/bits
          error: {0x6000, 0x02, 8}
        }
      }
    ]
  end
  
  # Optional SDO configuration before cyclic starts
  def get_sdo_config(_state) do
    [
      %SdoConfig{index: 0x8000, subindex: 0x01, data: <<1>>},  # Enable RTD
      %SdoConfig{index: 0x8001, subindex: 0x00, data: <<100>>} # Sample rate
    ]
  end
  
  # Optional: Custom encoding/decoding
  def encode_pdo_value(_state, :ch1, :value, raw_binary) do
    {:ok, raw_binary}  # Just return binary, no transformation
  end
  
  def decode_pdo_value(_state, :ch1, :value, raw_binary) do
    <<value::little-signed-16>> = raw_binary
    {:ok, value / 10.0}  # Convert to engineering units
  end
end
```

**Generic Driver** (default): Auto-discovers PDOs from device EEPROM, no custom logic needed.

## Configuration

IgH library paths are detected automatically:
- **Host**: `/usr/local/include`, `/usr/local/lib64`
- **Nerves**: Auto-detected from `$NERVES_SDK_SYSROOT`

Override in application config:

```elixir
# config/config.exs
config :ethercat,
  igh_include_dir: "/opt/etherlab/include",
  igh_lib_dir: "/opt/etherlab/lib"
```

For Nerves targets:

```elixir
# config/target.exs
config :ethercat,
  igh_include_dir: "#{System.get_env("NERVES_SDK_SYSROOT")}/usr/include",
  igh_lib_dir: "#{System.get_env("NERVES_SDK_SYSROOT")}/usr/lib"
```

## API Reference

### Configuration

**`EtherCAT.configure_hardware(master, config_module_or_struct)`**
- Blocks until operational
- Returns `{:ok, %{slave_name => pid}}`
- Applies config atomically
- Starts cyclic task
- All or nothing (no partial config)

**`EtherCAT.generate_config(master)`**
- Discovers slaves on network
- Returns `HardwareConfig` struct (feature incomplete)

**`EtherCAT.stop_slaves(master)`**
- Stops cyclic task
- Stops all slave drivers
- Returns to :synced state

### I/O Operations

**`EtherCAT.read(slave_pid, pdo_name, entry_name)`**
- Returns `{:ok, value}`
- Value is decoded by driver
- Only works in :operational state

**`EtherCAT.write(slave_pid, pdo_name, entry_name, value)`**
- Encodes value via driver
- Returns `:ok` immediately
- Actual write happens in cyclic task
- Confirmation via `{:output_changed, ...}` message when done

**`EtherCAT.watch(slave_pid, pdo_name, entry_name)`**
- Subscribe to value changes
- Calling process receives `{:pdo_value_changed, unique_name, value}`
- Only works in :operational state

**`EtherCAT.unwatch(slave_pid, pdo_name, entry_name)`**
- Unsubscribe from changes

## Architecture

```
┌────────────────────────────────────────────┐
│ Public API: EtherCAT module                │
│ ├─ configure_hardware()                    │
│ ├─ read/write/watch/unwatch                │
│ └─ Delegates to Master                     │
├────────────────────────────────────────────┤
│ Master (gen_statem FSM)                    │
│ ├─ offline → stale → synced → operational  │
│ ├─ Verifies hardware matches config        │
│ ├─ Manages slave driver pool               │
│ ├─ Routes I/O to correct domain            │
│ └─ Handles errors and recovery             │
├────────────────────────────────────────────┤
│ Slave Drivers (GenServer processes)        │
│ ├─ One per device                          │
│ ├─ Encodes/decodes values                  │
│ └─ Handles device-specific logic           │
├────────────────────────────────────────────┤
│ Configuration (Pure Data)                  │
│ ├─ HardwareConfig                          │
│ ├─ SlaveConfig / DomainConfig              │
│ ├─ PdoConfig / SdoConfig                   │
│ └─ Full compile-time validation            │
├────────────────────────────────────────────┤
│ Zig NIF Layer (45KB)                       │
│ ├─ cyclic_task: Real-time loop             │
│ ├─ Bit-level I/O                           │
│ ├─ Change detection                        │
│ ├─ Resource management                     │
│ └─ Zero-copy domain buffers                │
├────────────────────────────────────────────┤
│ IgH EtherCAT Library (C + Linux kernel)   │
│ └─ Network I/O, master sync, slave comms   │
└────────────────────────────────────────────┘
```

## Troubleshooting

**Permission Denied (network access)**
```bash
sudo chmod 666 /dev/EtherCAT0
# or add user to ethercat group
sudo usermod -a -G ethercat $USER
```

**No Slaves Found**
- Check physical connections (power, network cables)
- Verify kernel module is loaded: `lsmod | grep ec_`
- Check master state: `ethercat master`

**Link Down Errors**
- Check EtherCAT power supply
- Verify network connections
- Run ethercat diagnostics: `ethercat slaves -v`

**Compilation Errors**
- Ensure Zig 0.15.2 installed
- Check IgH paths: `pkg-config --cflags libethercat`
- Verify Elixir 1.19+

**Slave Not Responding (Hardware Mismatch)**
- Generate config: `EtherCAT.generate_config(master)`
- Compare with actual hardware
- Update vendor/product in config

## License

See LICENSE file
