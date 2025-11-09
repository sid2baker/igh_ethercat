# SDO API Research & Slave.configure/2 Design

> **⚠️ ARCHITECTURE UPDATED**: This design has been superseded by the driver-based approach documented in `SDO_IMPLEMENTATION_PLAN.md`.
>
> **Key Change**: Instead of core library schemas, SDO configuration now happens in device drivers via the existing `Driver.configure/2` callback. This document remains for reference on SDO API research and verification findings.

## Executive Summary

This document presents research findings on the IgH EtherCAT Master SDO (Service Data Object) API and proposes a design for a high-level `Slave.configure/2` function that enables pre-activation configuration of EtherCAT slaves via SDO operations.

**Key Finding**: SDO configuration must happen **before master activation** using `ecrt_slave_config_sdo*()` functions. This allows automatic, persistent configuration that survives slave reboots.

**Critical Constraint**: SDO configuration **must not** modify PDO assignment/mapping objects (0x1C10-0x1C2F, 0x1600-0x1BFF), as these are managed by the master's PDO configuration API.

---

## 1. SDO API Research Findings (ecrt.h)

### 1.1 Three SDO Operation Paradigms

The IgH EtherCAT Master provides three distinct approaches to SDO operations:

#### A. Master-Level Blocking SDOs (Pre/Post Activation)

```c
int ecrt_master_sdo_download(ec_master_t *master, uint16_t slave_position,
    uint16_t index, uint8_t subindex, uint8_t *data, size_t data_size,
    uint32_t *abort_code);

int ecrt_master_sdo_upload(ec_master_t *master, uint16_t slave_position,
    uint16_t index, uint8_t subindex, uint8_t *target, size_t target_size,
    size_t *result_size, uint32_t *abort_code);
```

**Characteristics:**
- Can be called **before or after** master activation
- **Blocks** until operation completes
- **NOT realtime-safe** - for configuration/debug use only
- Settings **lost on slave reboot** (one-time operation)
- Returns 0 on success, negative on failure

**Use Case**: Interactive debugging, one-time parameter changes, reading slave info

---

#### B. Configuration SDOs (Pre-Activation Only) ⭐ **PRIMARY FOCUS**

```c
int ecrt_slave_config_sdo(ec_slave_config_t *sc, uint16_t index,
    uint8_t subindex, const uint8_t *data, size_t size);

int ecrt_slave_config_sdo8(ec_slave_config_t *sc, uint16_t index,
    uint8_t subindex, uint8_t value);
int ecrt_slave_config_sdo16(ec_slave_config_t *sc, uint16_t index,
    uint8_t subindex, uint16_t value);
int ecrt_slave_config_sdo32(ec_slave_config_t *sc, uint16_t index,
    uint8_t subindex, uint32_t value);
```

**Characteristics:**
- **MUST** be called **before** `ecrt_master_activate()`
- **Asynchronous** - only returns allocation errors immediately
- **Persistent** - automatically re-downloaded if slave reboots/reconnects
- **Automatic endianness** correction for typed helpers
- Stored in slave configuration object, freed with master

**Critical Restriction (from API docs):**
> "The SDOs for PDO assignment (0x1C10 - 0x1C2F) and PDO mapping (0x1600 - 0x17FF and 0x1A00 - 0x1BFF) should NOT be configured with this function, because they are part of the slave configuration done by the master. Please use ecrt_slave_config_pdos() and friends instead."

**Use Case**: **Setting slave parameters that configure device behavior** (filters, limits, scales, calibration, etc.)

---

#### C. Runtime SDO Requests (Post-Activation, Realtime-Safe)

```c
ec_sdo_request_t *ecrt_slave_config_create_sdo_request(
    ec_slave_config_t *sc, uint16_t index, uint8_t subindex, size_t size);

void ecrt_sdo_request_read(ec_sdo_request_t *req);
void ecrt_sdo_request_write(ec_sdo_request_t *req);
ec_request_state_t ecrt_sdo_request_state(ec_sdo_request_t *req);
uint8_t *ecrt_sdo_request_data(ec_sdo_request_t *req);
```

**Characteristics:**
- Request object created **before activation**
- Operations executed **after activation** in cyclic task
- **Non-blocking state machine**: initiate → poll state → retrieve result
- **Realtime-safe** - integrates with cyclic communication
- **Not persistent** - lost on slave reboot

**Use Case**: Dynamic parameter updates during operation, reading live diagnostics

---

### 1.2 Lifecycle Timeline

```
┌────────────────────────────────────────────────────────────────┐
│ PRE-ACTIVATION PHASE                                           │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│  1. ecrt_master_request()                                      │
│  2. ecrt_master_slave_config()                                 │
│  3. ecrt_slave_config_pdos()        ◄── Configure PDO mapping  │
│  4. ecrt_slave_config_sdo*()        ◄── Configure parameters   │ ⭐
│  5. ecrt_slave_config_create_sdo_request()  ◄── For runtime    │
│  6. ecrt_domain_reg_pdo_entry_list()                           │
│                                                                │
│  7. ecrt_master_activate()          ◄── ACTIVATION POINT       │
│     ↓                                                          │
│     └─► Downloads configuration SDOs to slave                  │
│                                                                │
└────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────┐
│ POST-ACTIVATION PHASE (Cyclic Task Running)                    │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│  - ecrt_sdo_request_read/write()    ◄── Runtime requests       │
│  - ecrt_master_sdo_download/upload()  ◄── Blocking debug ops   │
│                                                                │
│  If slave reboots:                                             │
│    └─► Configuration SDOs automatically re-downloaded          │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

---

### 1.3 SDO vs PDO Relationship

**PDOs (Process Data Objects):**
- Cyclic, fast, realtime data exchange
- Defined by assignment (0x1C10-0x1C2F) and mapping (0x1600-0x1BFF) objects
- Configured via `ecrt_slave_config_pdos()` **before activation**
- Determines domain memory layout

**SDOs (Service Data Objects):**
- Acyclic, slower, configuration/parameter access
- Can read/write any object dictionary entry (except reserved PDO config objects)
- Configure slave behavior that may **indirectly affect** available PDO mappings

**Example with EL3202 (RTD input terminal):**
- SDO 0x8000:0x02 "Presentation" - Changes data format (raw/engineering units)
- SDO 0x8000:0x15 "Filter settings" - Enables signal filtering
- **These SDOs don't change PDO mapping structure** (still 0x1A00/0x1A01)
- They change what **values appear** in the PDO, not the mapping itself

**Devices with SDO-Configurable PDO Mappings:**
Some advanced slaves allow PDO mapping changes via SDO, but this must be done via the master's PDO API, not direct SDO configuration.

---

## 2. Design Decisions

### 2.1 Chosen Approach: Configuration SDOs

For `Slave.configure/2`, we use **Configuration SDOs (Paradigm B)** because:

✅ **Persistent** - Survives slave reboots automatically
✅ **Declarative** - Defined once before activation
✅ **Safe** - Managed by master's configuration lifecycle
✅ **Simple** - No state machine polling required

**Rejected alternatives:**
- ❌ Master blocking SDOs - Not persistent, requires manual re-application
- ❌ Runtime requests - Requires state machine management, complex for simple config

---

### 2.2 Configuration Philosophy

```elixir
# BAD: Low-level, error-prone
Slave.sdo_write(slave, 0x8000, 0x13, <<100::little-16>>)  # What is this?
Slave.sdo_write(slave, 0x8000, 0x14, <<200::little-16>>)

# GOOD: High-level, self-documenting
Slave.configure(slave,
  ch1_limit1: 100,      # Degrees Celsius
  ch1_limit2: 200
)
```

**Design Principles:**
1. **Named parameters** over raw SDO indices
2. **Type safety** - automatic conversion to SDO data types
3. **Validation** - check ranges and compatibility
4. **Device-specific schemas** - EL3202 knows its own parameters
5. **Pre-activation only** - fail fast if called after activation

---

## 3. Slave.configure/2 API Design

### 3.1 Module Structure

```
lib/ethercat/
├── slave.ex                    # Existing high-level slave API
├── slave/
│   ├── configuration.ex        # NEW: Configuration orchestration
│   └── device_schemas/
│       ├── el3202.ex           # NEW: EL3202 parameter schema
│       └── base.ex             # NEW: Base device schema behavior
└── nif.ex                      # MODIFIED: Add SDO NIF bindings
```

---

### 3.2 Core API

#### Slave.configure/2

```elixir
@spec configure(slave_config_ref(), keyword()) :: :ok | {:error, term()}
```

**Parameters:**
- `slave_config_ref` - Slave configuration reference (from `Master.slave_config/4`)
- `config` - Keyword list of device-specific parameters

**Returns:**
- `:ok` - Configuration SDOs queued successfully
- `{:error, :already_activated}` - Master already activated
- `{:error, {:unknown_parameter, key}}` - Invalid parameter name
- `{:error, {:invalid_value, key, value, reason}}` - Parameter validation failed
- `{:error, {:nif_error, reason}}` - Low-level NIF call failed

**Timing Constraint:**
Must be called **after** `Master.slave_config/4` but **before** `Master.activate/1`.

**Example:**
```elixir
{:ok, master} = Master.request(0)

slave = Master.slave_config(master,
  alias: 0,
  position: 0,
  vendor_id: 0x00000002,  # Beckhoff
  product_code: 0x0C823052 # EL3202
)

# Configure before activation
:ok = Slave.configure(slave,
  ch1_enable_user_scale: true,
  ch1_user_scale_offset: -50,
  ch1_user_scale_gain: 100_000,
  ch1_enable_filter: true,
  ch1_filter_settings: 0x0A,
  ch1_enable_limit1: true,
  ch1_limit1: 100,
  ch1_enable_limit2: true,
  ch1_limit2: 200,
  ch2_enable_filter: true,
  ch2_filter_settings: 0x05
)

# PDO configuration (separate concern)
{:ok, _unique_names} = Slave.register_pdos(slave, domain, [
  {:rx, 0x1A00, 1},
  {:rx, 0x1A01, 1}
])

:ok = Master.activate(master)  # SDOs downloaded here
```

---

### 3.3 Device Schema Behavior

```elixir
defmodule Ethercat.Slave.DeviceSchemas.Base do
  @moduledoc """
  Behaviour for device-specific parameter schemas.

  Each device module defines:
  - Available parameters with types and SDO mappings
  - Validation rules
  - Default values
  """

  @type parameter_name :: atom()
  @type parameter_value :: term()
  @type sdo_index :: 0x0000..0xFFFF
  @type sdo_subindex :: 0x00..0xFF
  @type sdo_type :: :uint8 | :uint16 | :uint32 | :int16 | :int32 | :bool

  @type parameter_spec :: %{
    sdo_index: sdo_index(),
    sdo_subindex: sdo_subindex(),
    type: sdo_type(),
    validator: (parameter_value() -> :ok | {:error, term()}),
    description: String.t()
  }

  @callback parameters() :: %{parameter_name() => parameter_spec()}
  @callback validate_config(keyword()) :: :ok | {:error, term()}
end
```

---

### 3.4 EL3202 Device Schema

```elixir
defmodule Ethercat.Slave.DeviceSchemas.EL3202 do
  @behaviour Ethercat.Slave.DeviceSchemas.Base

  @moduledoc """
  Beckhoff EL3202 - 2-Channel RTD (PT100/PT1000) Input Terminal

  Supports configuration of:
  - User scaling (offset/gain)
  - Signal filtering
  - Limit values (alarms)
  - Calibration settings
  - RTD element type and connection technology

  ## Parameter Naming Convention

  - `ch1_*` - Channel 1 (SDO 0x8000)
  - `ch2_*` - Channel 2 (SDO 0x8010)

  ## Example

      Slave.configure(slave,
        ch1_enable_filter: true,
        ch1_filter_settings: 10,  # 10 Hz cutoff
        ch1_enable_limit1: true,
        ch1_limit1: 1000,         # 100.0°C (0.1° resolution)
        ch2_rtd_element: :pt100,
        ch2_connection_technology: :three_wire
      )
  """

  @impl true
  def parameters do
    %{
      # Channel 1 - Enable bits (0x8000:0x01-0x0B)
      ch1_enable_user_scale:       sdo(0x8000, 0x01, :bool, "Enable user scale"),
      ch1_presentation:            sdo(0x8000, 0x02, :uint8, "Presentation format",
                                       &validate_presentation/1),
      ch1_siemens_bits:            sdo(0x8000, 0x05, :bool, "Siemens bit format"),
      ch1_enable_filter:           sdo(0x8000, 0x06, :bool, "Enable signal filter"),
      ch1_enable_limit1:           sdo(0x8000, 0x07, :bool, "Enable limit 1 alarm"),
      ch1_enable_limit2:           sdo(0x8000, 0x08, :bool, "Enable limit 2 alarm"),
      ch1_enable_automatic_cal:    sdo(0x8000, 0x09, :bool, "Enable auto calibration"),
      ch1_enable_user_cal:         sdo(0x8000, 0x0A, :bool, "Enable user calibration"),
      ch1_enable_vendor_cal:       sdo(0x8000, 0x0B, :bool, "Enable vendor calibration"),

      # Channel 1 - Values (0x8000:0x11-0x1B)
      ch1_user_scale_offset:       sdo(0x8000, 0x11, :int16, "User scale offset"),
      ch1_user_scale_gain:         sdo(0x8000, 0x12, :int32, "User scale gain"),
      ch1_limit1:                  sdo(0x8000, 0x13, :int16, "Limit 1 value (0.1° resolution)"),
      ch1_limit2:                  sdo(0x8000, 0x14, :int16, "Limit 2 value (0.1° resolution)"),
      ch1_filter_settings:         sdo(0x8000, 0x15, :uint16, "Filter cutoff frequency"),
      ch1_calibration_interval:    sdo(0x8000, 0x16, :uint16, "Auto-cal interval (minutes)"),
      ch1_user_cal_offset:         sdo(0x8000, 0x17, :int16, "User cal offset"),
      ch1_user_cal_gain:           sdo(0x8000, 0x18, :uint16, "User cal gain"),
      ch1_rtd_element:             sdo(0x8000, 0x19, :uint16, "RTD element type",
                                       &validate_rtd_element/1),
      ch1_connection_technology:   sdo(0x8000, 0x1A, :uint16, "Connection technology",
                                       &validate_connection_tech/1),
      ch1_wire_calibration:        sdo(0x8000, 0x1B, :int16, "Wire calibration (1/32 Ohm)"),

      # Channel 2 - Same structure at 0x8010
      ch2_enable_user_scale:       sdo(0x8010, 0x01, :bool, "Enable user scale"),
      ch2_presentation:            sdo(0x8010, 0x02, :uint8, "Presentation format",
                                       &validate_presentation/1),
      # ... (mirror ch1 parameters)
    }
  end

  defp sdo(index, subindex, type, description, validator \\ &default_validator/1) do
    %{
      sdo_index: index,
      sdo_subindex: subindex,
      type: type,
      validator: validator,
      description: description
    }
  end

  defp default_validator(_value), do: :ok

  defp validate_presentation(value) when value in 0..7, do: :ok
  defp validate_presentation(value),
    do: {:error, "Presentation must be 0-7, got #{value}"}

  defp validate_rtd_element(:pt100), do: :ok
  defp validate_rtd_element(:pt1000), do: :ok
  defp validate_rtd_element(value),
    do: {:error, "RTD element must be :pt100 or :pt1000, got #{inspect(value)}"}

  defp validate_connection_tech(tech) when tech in [:two_wire, :three_wire, :four_wire],
    do: :ok
  defp validate_connection_tech(value),
    do: {:error, "Connection tech must be :two_wire, :three_wire, or :four_wire, got #{inspect(value)}"}

  @impl true
  def validate_config(config) do
    # Cross-parameter validation
    if Keyword.get(config, :ch1_enable_user_scale) &&
       !Keyword.has_key?(config, :ch1_user_scale_gain) do
      {:error, "ch1_enable_user_scale requires ch1_user_scale_gain"}
    else
      :ok
    end
  end
end
```

---

### 3.5 Configuration Module Logic

```elixir
defmodule Ethercat.Slave.Configuration do
  alias Ethercat.NIF
  alias Ethercat.Slave.DeviceSchemas

  @moduledoc """
  Handles slave configuration via SDO operations.
  """

  @doc """
  Configure slave with device-specific parameters.

  ## Workflow

  1. Detect device type from slave config (vendor_id + product_code)
  2. Load appropriate device schema
  3. Validate all parameters against schema
  4. Convert values to SDO binary format
  5. Call NIF to queue configuration SDOs
  """
  @spec configure(reference(), keyword()) :: :ok | {:error, term()}
  def configure(slave_config_ref, params) when is_reference(slave_config_ref) do
    with {:ok, schema_module} <- get_device_schema(slave_config_ref),
         :ok <- validate_parameters(schema_module, params),
         :ok <- schema_module.validate_config(params),
         sdo_operations <- build_sdo_operations(schema_module, params),
         :ok <- apply_sdo_operations(slave_config_ref, sdo_operations) do
      :ok
    end
  end

  defp get_device_schema(_slave_config_ref) do
    # TODO: Query device identity from slave_config_ref
    # For now, hardcode EL3202
    {:ok, DeviceSchemas.EL3202}
  end

  defp validate_parameters(schema_module, params) do
    parameter_specs = schema_module.parameters()

    Enum.reduce_while(params, :ok, fn {key, value}, :ok ->
      case Map.fetch(parameter_specs, key) do
        {:ok, spec} ->
          case spec.validator.(value) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {:invalid_value, key, value, reason}}}
          end

        :error ->
          {:halt, {:error, {:unknown_parameter, key}}}
      end
    end)
  end

  defp build_sdo_operations(schema_module, params) do
    parameter_specs = schema_module.parameters()

    Enum.map(params, fn {key, value} ->
      spec = Map.fetch!(parameter_specs, key)

      %{
        index: spec.sdo_index,
        subindex: spec.sdo_subindex,
        type: spec.type,
        value: value
      }
    end)
  end

  defp apply_sdo_operations(slave_config_ref, operations) do
    Enum.reduce_while(operations, :ok, fn op, :ok ->
      data = encode_sdo_value(op.type, op.value)

      case NIF.slave_config_sdo(slave_config_ref, op.index, op.subindex, data) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:nif_error, reason}}}
      end
    end)
  end

  defp encode_sdo_value(:bool, true), do: <<1::8>>
  defp encode_sdo_value(:bool, false), do: <<0::8>>
  defp encode_sdo_value(:uint8, value), do: <<value::little-unsigned-8>>
  defp encode_sdo_value(:uint16, value), do: <<value::little-unsigned-16>>
  defp encode_sdo_value(:uint32, value), do: <<value::little-unsigned-32>>
  defp encode_sdo_value(:int16, value), do: <<value::little-signed-16>>
  defp encode_sdo_value(:int32, value), do: <<value::little-signed-32>>

  # Enum conversions
  defp encode_sdo_value(:uint16, :pt100), do: <<0::little-unsigned-16>>
  defp encode_sdo_value(:uint16, :pt1000), do: <<1::little-unsigned-16>>
  defp encode_sdo_value(:uint16, :two_wire), do: <<0::little-unsigned-16>>
  defp encode_sdo_value(:uint16, :three_wire), do: <<1::little-unsigned-16>>
  defp encode_sdo_value(:uint16, :four_wire), do: <<2::little-unsigned-16>>
end
```

---

## 4. Required NIF Additions

### 4.1 New NIF Functions

Add to `lib/ethercat/nif.ex`:

```elixir
@doc """
Configure an SDO for a slave (pre-activation only).

Queues an SDO download that will be executed during slave configuration
(typically at master activation). The configuration persists and is
automatically re-applied if the slave reboots.

## Parameters

- `slave_config_ref` - Slave configuration reference
- `sdo_index` - SDO index (0x0000-0xFFFF)
- `sdo_subindex` - SDO subindex (0x00-0xFF)
- `data` - Binary data to write (endianness must match device expectations)

## Returns

- `:ok` - SDO configuration queued successfully
- `{:error, :allocation_failed}` - Memory allocation failed
- `{:error, :already_activated}` - Master already activated

## Restrictions

Do NOT configure PDO assignment (0x1C10-0x1C2F) or PDO mapping
(0x1600-0x1BFF) objects. Use `slave_config_pdos/3` instead.
"""
@spec slave_config_sdo(reference(), 0x0000..0xFFFF, 0x00..0xFF, binary()) ::
        :ok | {:error, term()}
def slave_config_sdo(_slave_config_ref, _sdo_index, _sdo_subindex, _data) do
  :erlang.nif_error(:nif_not_loaded)
end

@doc """
Configure an 8-bit SDO value (pre-activation only).

Convenience wrapper with automatic endianness handling.
"""
@spec slave_config_sdo8(reference(), 0x0000..0xFFFF, 0x00..0xFF, 0..255) ::
        :ok | {:error, term()}
def slave_config_sdo8(_slave_config_ref, _sdo_index, _sdo_subindex, _value) do
  :erlang.nif_error(:nif_not_loaded)
end

@doc """
Configure a 16-bit SDO value (pre-activation only).

Convenience wrapper with automatic endianness handling.
"""
@spec slave_config_sdo16(reference(), 0x0000..0xFFFF, 0x00..0xFF, 0..65535) ::
        :ok | {:error, term()}
def slave_config_sdo16(_slave_config_ref, _sdo_index, _sdo_subindex, _value) do
  :erlang.nif_error(:nif_not_loaded)
end

@doc """
Configure a 32-bit SDO value (pre-activation only).

Convenience wrapper with automatic endianness handling.
"""
@spec slave_config_sdo32(reference(), 0x0000..0xFFFF, 0x00..0xFF, 0..4_294_967_295) ::
        :ok | {:error, term()}
def slave_config_sdo32(_slave_config_ref, _sdo_index, _sdo_subindex, _value) do
  :erlang.nif_error(:nif_not_loaded)
end
```

---

### 4.2 Zig NIF Implementation Outline

Add to NIF C/Zig bindings:

```c
// In nif.c or equivalent Zig file

static ERL_NIF_TERM
slave_config_sdo_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    // Extract arguments
    ec_slave_config_t *sc;
    unsigned int sdo_index, sdo_subindex;
    ErlNifBinary data;

    if (!get_slave_config_ref(env, argv[0], &sc) ||
        !enif_get_uint(env, argv[1], &sdo_index) ||
        !enif_get_uint(env, argv[2], &sdo_subindex) ||
        !enif_inspect_binary(env, argv[3], &data))
    {
        return enif_make_badarg(env);
    }

    // Validate ranges
    if (sdo_index > 0xFFFF || sdo_subindex > 0xFF) {
        return enif_make_badarg(env);
    }

    // Call ecrt API
    int result = ecrt_slave_config_sdo(
        sc,
        (uint16_t)sdo_index,
        (uint8_t)sdo_subindex,
        data.data,
        data.size
    );

    if (result < 0) {
        return error_tuple(env, "allocation_failed");
    }

    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM
slave_config_sdo8_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])
{
    ec_slave_config_t *sc;
    unsigned int sdo_index, sdo_subindex, value;

    if (!get_slave_config_ref(env, argv[0], &sc) ||
        !enif_get_uint(env, argv[1], &sdo_index) ||
        !enif_get_uint(env, argv[2], &sdo_subindex) ||
        !enif_get_uint(env, argv[3], &value))
    {
        return enif_make_badarg(env);
    }

    if (sdo_index > 0xFFFF || sdo_subindex > 0xFF || value > 0xFF) {
        return enif_make_badarg(env);
    }

    int result = ecrt_slave_config_sdo8(sc, sdo_index, sdo_subindex, (uint8_t)value);

    return (result < 0) ? error_tuple(env, "allocation_failed")
                        : enif_make_atom(env, "ok");
}

// Similar implementations for sdo16 and sdo32...
```

---

## 5. Implementation Blueprint

### 5.1 File Changes Required

| File | Change Type | Description |
|------|-------------|-------------|
| `lib/ethercat/nif.ex` | **Modify** | Add 4 new NIF function stubs |
| `lib/ethercat/slave.ex` | **Modify** | Add `configure/2` delegation |
| `lib/ethercat/slave/configuration.ex` | **New** | Core configuration logic |
| `lib/ethercat/slave/device_schemas/base.ex` | **New** | Schema behavior definition |
| `lib/ethercat/slave/device_schemas/el3202.ex` | **New** | EL3202 parameter schema |
| NIF implementation (C/Zig) | **Modify** | Add 4 NIF implementations |

---

### 5.2 Development Phases

#### Phase 1: NIF Foundation
1. Implement `slave_config_sdo*` NIF bindings
2. Add unit tests for NIF layer
3. Manual testing with direct NIF calls

#### Phase 2: Schema Infrastructure
1. Create `Base` behavior module
2. Implement `EL3202` schema with full parameter set
3. Unit tests for schema validation

#### Phase 3: Configuration Engine
1. Implement `Configuration` module
2. Add device detection logic
3. Integration tests with mock NIF

#### Phase 4: High-Level API
1. Add `Slave.configure/2` delegation
2. End-to-end tests with actual EL3202 hardware
3. Documentation and examples

---

### 5.3 Testing Strategy

```elixir
# Test 1: Low-level NIF
test "slave_config_sdo writes SDO configuration" do
  {:ok, master} = Master.request(0)
  sc = Master.slave_config(master, alias: 0, position: 0,
                           vendor_id: 0x02, product_code: 0x0C823052)

  # Should succeed before activation
  assert :ok = NIF.slave_config_sdo16(sc, 0x8000, 0x13, 1000)

  # Should fail after activation
  :ok = Master.activate(master)
  assert {:error, _} = NIF.slave_config_sdo16(sc, 0x8000, 0x13, 2000)
end

# Test 2: Schema validation
test "EL3202 schema validates parameters" do
  assert :ok = EL3202.validate_config(ch1_limit1: 1000)
  assert {:error, {:unknown_parameter, :invalid_param}} =
    EL3202.validate_config(invalid_param: 123)
end

# Test 3: High-level configuration
test "configure sets EL3202 channel limits" do
  {:ok, master} = Master.request(0)
  slave = Master.slave_config(master, ...)

  assert :ok = Slave.configure(slave,
    ch1_enable_limit1: true,
    ch1_limit1: 1000,
    ch1_enable_limit2: true,
    ch1_limit2: 2000
  )

  :ok = Master.activate(master)

  # Verify SDOs were applied (would need read-back support)
end
```

---

## 6. Example Usage Scenarios

### 6.1 Basic Limit Configuration

```elixir
defmodule MyApp.EthercatController do
  alias Ethercat.{Master, Slave, Domain}

  def setup_temperature_monitoring do
    {:ok, master} = Master.request(0)

    # Configure EL3202 RTD input terminal
    rtd_slave = Master.slave_config(master,
      alias: 0,
      position: 0,
      vendor_id: 0x00000002,      # Beckhoff
      product_code: 0x0C823052    # EL3202
    )

    # Set temperature limits for alarm monitoring
    :ok = Slave.configure(rtd_slave,
      # Channel 1: Monitor high-temp alarm
      ch1_enable_limit1: true,
      ch1_limit1: 1000,           # 100.0°C (0.1° resolution)
      ch1_enable_filter: true,
      ch1_filter_settings: 0x0A,  # 10 Hz cutoff

      # Channel 2: Monitor over-temp shutdown
      ch2_enable_limit1: true,
      ch2_limit1: 1200            # 120.0°C
    )

    # Register PDOs for reading temperature values
    {:ok, domain} = Domain.create(master)
    {:ok, [ch1_status, ch1_value, ch2_status, ch2_value]} =
      Slave.register_pdos(rtd_slave, domain, [
        {:rx, 0x6000, 0x00},  # Channel 1 status byte
        {:rx, 0x6000, 0x11},  # Channel 1 value
        {:rx, 0x6010, 0x00},  # Channel 2 status byte
        {:rx, 0x6010, 0x11}   # Channel 2 value
      ])

    :ok = Master.activate(master)

    %{
      master: master,
      domain: domain,
      pdos: %{
        ch1_status: ch1_status,
        ch1_value: ch1_value,
        ch2_status: ch2_status,
        ch2_value: ch2_value
      }
    }
  end
end
```

---

### 6.2 Advanced Scaling Configuration

```elixir
def configure_pressure_sensor_as_rtd do
  # Use EL3202 with custom pressure sensor (4-wire RTD)
  # Map 0-100 bar pressure to custom scale

  :ok = Slave.configure(rtd_slave,
    # Channel 1: Pressure sensor with user scaling
    ch1_enable_user_scale: true,
    ch1_user_scale_offset: 0,
    ch1_user_scale_gain: 1000,        # Scale factor
    ch1_connection_technology: :four_wire,
    ch1_rtd_element: :pt1000,
    ch1_enable_filter: true,
    ch1_filter_settings: 0x05,        # 5 Hz low-pass

    # Calibration
    ch1_enable_user_cal: true,
    ch1_user_cal_offset: -5,          # Offset correction
    ch1_user_cal_gain: 65535,         # Unity gain

    # Alarm thresholds
    ch1_enable_limit1: true,
    ch1_limit1: 8000,                 # 80 bar warning
    ch1_enable_limit2: true,
    ch1_limit2: 9500                  # 95 bar critical
  )
end
```

---

### 6.3 Multi-Device Configuration

```elixir
def setup_multi_channel_daq do
  {:ok, master} = Master.request(0)

  # Configure 4x EL3202 terminals (8 RTD channels total)
  Enum.each(0..3, fn position ->
    slave = Master.slave_config(master,
      alias: position,
      position: position,
      vendor_id: 0x00000002,
      product_code: 0x0C823052
    )

    # Apply standard configuration to all channels
    :ok = Slave.configure(slave,
      ch1_enable_filter: true,
      ch1_filter_settings: 0x0A,
      ch1_enable_limit1: true,
      ch1_limit1: 850,              # 85°C

      ch2_enable_filter: true,
      ch2_filter_settings: 0x0A,
      ch2_enable_limit1: true,
      ch2_limit1: 850
    )
  end)

  :ok = Master.activate(master)
end
```

---

## 7. Risk Analysis

### 7.1 Top 3 Risks

#### Risk 1: PDO Configuration Conflicts ⚠️

**Scenario:** User attempts to configure PDO mapping/assignment SDOs (0x1C10-0x1C2F, 0x1600-0x1BFF) via `Slave.configure/2`, causing conflict with master's PDO configuration.

**Impact:** Master activation fails or cyclic communication corrupted

**Mitigation:**
- Schema validation **blocks** configuration of restricted SDO ranges
- Documentation clearly explains PDO vs parameter SDO distinction
- Return clear error: `{:error, {:restricted_sdo, index, "Use Slave.register_pdos instead"}}`

```elixir
defp validate_sdo_restrictions(sdo_index) do
  cond do
    sdo_index in 0x1C10..0x1C2F ->
      {:error, {:restricted_sdo, sdo_index, "PDO assignment objects managed by master"}}
    sdo_index in 0x1600..0x17FF or sdo_index in 0x1A00..0x1BFF ->
      {:error, {:restricted_sdo, sdo_index, "PDO mapping objects managed by master"}}
    true ->
      :ok
  end
end
```

---

#### Risk 2: Post-Activation Configuration Attempts ⚠️

**Scenario:** User calls `Slave.configure/2` after `Master.activate/1`, but ecrt API requires pre-activation.

**Impact:** Silent failure or crash (depending on ecrt implementation)

**Mitigation:**
- Track master activation state in GenServer
- Return `{:error, :already_activated}` with helpful message
- NIF-level check (ecrt may return error code)

```elixir
def configure(slave_config_ref, params) do
  case Master.activation_state(slave_config_ref) do
    :not_activated ->
      do_configure(slave_config_ref, params)

    :activated ->
      {:error, {:already_activated,
                "Slave.configure/2 must be called before Master.activate/1. " <>
                "For runtime SDO access, use Slave.sdo_read/write (not yet implemented)."}}
  end
end
```

---

#### Risk 3: Invalid Parameter Values Damage Hardware ⚠️

**Scenario:** User configures invalid calibration gain or RTD type, causing incorrect sensor readings or hardware damage (e.g., overcurrent in 2-wire mode with 4-wire sensor).

**Impact:** Incorrect measurements, potential sensor damage, safety hazard

**Mitigation:**
- **Strong validation** in device schemas with range checks
- **Documentation** includes parameter semantics and safe ranges
- **Fail-safe defaults** - only apply user-provided params, leave others at device defaults
- **Read-back verification** (future enhancement) - read configured SDOs post-activation

```elixir
defp validate_user_cal_gain(value) when value in 1..65535, do: :ok
defp validate_user_cal_gain(0),
  do: {:error, "Calibration gain of 0 would cause division by zero"}
defp validate_user_cal_gain(value),
  do: {:error, "Calibration gain must be 1-65535, got #{value}"}
```

---

### 7.4 Asynchronous Error Handling ⚠️

**Important**: SDO configuration errors are **asynchronous** and may not be detected immediately.

#### Error Detection Timeline

```
┌─────────────────────────────────────────────────────────┐
│ 1. Slave.configure/2 called                             │
│    └─► Returns :ok if SDO queued (memory allocated)     │
│                                                          │
│ 2. Master.activate/1 called                             │
│    └─► SDO download begins                              │
│    └─► Transfer errors may occur here                   │
│                                                          │
│ 3. Cyclic operation                                     │
│    └─► Slave reaches OP state if successful             │
│    └─► Stays in PREOP/SAFEOP if SDO failed             │
└─────────────────────────────────────────────────────────┘
```

**From IgH API Documentation:**
> "This method has to be called in non-realtime context before ecrt_master_activate(). It returns only allocation errors immediately; SDO transfer errors are reported asynchronously."

#### Example with Error Checking

```elixir
defmodule MyApp.EthercatSetup do
  require Logger

  def setup_with_error_checking do
    {:ok, master} = Master.request(0)

    slave = Master.slave_config(master,
      alias: 0, position: 0,
      vendor_id: 0x02, product_code: 0x0C823052
    )

    # Step 1: Queue configuration (returns :ok if queued)
    case Slave.configure(slave, ch1_limit1: 1000, ch1_limit2: 2000) do
      :ok ->
        Logger.info("SDO configuration queued")

      {:error, reason} ->
        Logger.error("Failed to queue SDO: #{inspect(reason)}")
        return {:error, reason}
    end

    {:ok, domain} = Domain.create(master)
    {:ok, _pdos} = Slave.register_pdos(slave, domain, [...])

    # Step 2: Activate (SDO transfers happen here)
    case Master.activate(master) do
      :ok ->
        Logger.info("Master activated")

      {:error, reason} ->
        # Could be SDO transfer failure
        Logger.error("Activation failed: #{inspect(reason)}")
        return {:error, reason}
    end

    # Step 3: Monitor slave state to verify configuration
    # (Implementation depends on state monitoring API)
    case wait_for_slave_operational(slave, timeout: 5000) do
      :ok ->
        Logger.info("Slave reached OP state - configuration successful")
        {:ok, master}

      {:error, :timeout} ->
        state = get_slave_state(slave)
        Logger.error("Slave stuck in #{state} - possible SDO config error")
        {:error, :configuration_failed}
    end
  end
end
```

#### Mitigation Strategies

1. **Monitor slave state** after activation to detect configuration failures
2. **Use verification mode** (future enhancement) to read back SDO values
3. **Test configurations** on non-production hardware first
4. **Log activation errors** and correlate with SDO configuration

---

## 7.5 Advanced Features

### 7.5.1 Raw SDO Configuration (Bypass PDO Restrictions)

While the high-level `Slave.configure/2` API blocks PDO mapping/assignment SDOs (0x1C10-0x1C2F, 0x1600-0x1BFF) to prevent conflicts, **real-world usage shows this is sometimes necessary** for:

- Custom PDO mappings not available in ESI files
- Dynamic PDO reconfiguration
- Devices with incomplete/incorrect XML descriptions

**New Low-Level API:**

```elixir
defmodule Ethercat.Slave.Configuration do
  @doc """
  Configure SDO with raw index/subindex (advanced users only).

  ## WARNING

  This function bypasses safety checks. Configuring PDO assignment
  (0x1C10-0x1C2F) or PDO mapping (0x1600-0x1BFF) objects can conflict
  with the master's PDO management and cause communication failures.

  Only use this if you fully understand EtherCAT PDO configuration.

  ## Options

  - `allow_pdo_config: boolean` - Set to `true` to allow PDO SDO configuration
    (default: `false`)

  ## Examples

      # Safe configuration (non-PDO SDO)
      :ok = Slave.configure_sdo_raw(slave, 0x8000, 0x15, <<0x0A::16-little>>)

      # Advanced: Custom PDO mapping (use with caution!)
      :ok = Slave.configure_sdo_raw(slave, 0x1C12, 0x00, <<0x00>>,
                                    allow_pdo_config: true)
      :ok = Slave.configure_sdo_raw(slave, 0x1C12, 0x01, <<0x04, 0x16::16-little>>,
                                    allow_pdo_config: true)
  """
  @spec configure_sdo_raw(reference(), sdo_index(), sdo_subindex(),
                          binary(), keyword()) :: :ok | {:error, term()}
  def configure_sdo_raw(slave_ref, index, subindex, data, opts \\ []) do
    if is_pdo_sdo?(index) and not Keyword.get(opts, :allow_pdo_config, false) do
      {:error, {:restricted_sdo, index,
                "PDO configuration blocked. Use allow_pdo_config: true to override (not recommended). " <>
                "Consider using Slave.register_pdos/3 instead."}}
    else
      NIF.slave_config_sdo(slave_ref, index, subindex, data)
    end
  end

  @doc """
  Configure SDO using type-specific helper (8-bit).
  """
  @spec configure_sdo8(reference(), sdo_index(), sdo_subindex(), 0..255, keyword()) ::
          :ok | {:error, term()}
  def configure_sdo8(slave_ref, index, subindex, value, opts \\ []) do
    configure_sdo_raw(slave_ref, index, subindex, <<value::8>>, opts)
  end

  @doc """
  Configure SDO using type-specific helper (16-bit, little-endian).
  """
  @spec configure_sdo16(reference(), sdo_index(), sdo_subindex(), 0..65535, keyword()) ::
          :ok | {:error, term()}
  def configure_sdo16(slave_ref, index, subindex, value, opts \\ []) do
    configure_sdo_raw(slave_ref, index, subindex, <<value::little-16>>, opts)
  end

  @doc """
  Configure SDO using type-specific helper (32-bit, little-endian).
  """
  @spec configure_sdo32(reference(), sdo_index(), sdo_subindex(), 0..4_294_967_295, keyword()) ::
          :ok | {:error, term()}
  def configure_sdo32(slave_ref, index, subindex, value, opts \\ []) do
    configure_sdo_raw(slave_ref, index, subindex, <<value::little-32>>, opts)
  end

  defp is_pdo_sdo?(index) do
    (index >= 0x1C10 and index <= 0x1C2F) or  # PDO assignment
    (index >= 0x1600 and index <= 0x17FF) or  # RxPDO mapping
    (index >= 0x1A00 and index <= 0x1BFF)     # TxPDO mapping
  end
end
```

**Usage Example:**

```elixir
# Custom PDO mapping for device with incomplete ESI
slave = Master.slave_config(master, ...)

# Clear existing PDO mapping
:ok = Slave.configure_sdo8(slave, 0x1A00, 0x00, 0, allow_pdo_config: true)

# Configure new PDO entries
:ok = Slave.configure_sdo32(slave, 0x1A00, 0x01, 0x60410010, allow_pdo_config: true)
:ok = Slave.configure_sdo32(slave, 0x1A00, 0x02, 0x60640020, allow_pdo_config: true)

# Set entry count
:ok = Slave.configure_sdo8(slave, 0x1A00, 0x00, 2, allow_pdo_config: true)

# Assign to sync manager
:ok = Slave.configure_sdo16(slave, 0x1C13, 0x01, 0x1A00, allow_pdo_config: true)
```

---

### 7.5.2 Complete Access SDO Support (Future)

Some devices support "Complete Access" mode where all subindices are written in one operation (more efficient).

**Planned API:**

```elixir
# NIF addition
@spec slave_config_complete_sdo(reference(), sdo_index(), binary()) ::
        :ok | {:error, term()}
def slave_config_complete_sdo(_ref, _index, _data) do
  :erlang.nif_error(:nif_not_loaded)
end

# High-level wrapper
@spec configure_complete(reference(), sdo_index(), map()) :: :ok | {:error, term()}
def configure_complete(slave_ref, index, subindex_data) do
  # Encode map of subindex => value into complete access format
  data = encode_complete_access(subindex_data)
  NIF.slave_config_complete_sdo(slave_ref, index, data)
end

# Example usage
Slave.configure_complete(slave, 0x8000, %{
  0x01 => <<1>>,        # Enable user scale
  0x11 => <<100::16>>,  # Offset
  0x12 => <<1000::32>>  # Gain
})
```

---

## 8. Future Enhancements

### 8.1 Device Auto-Detection

```elixir
# Automatically select schema based on vendor_id + product_code
defp get_device_schema(slave_config_ref) do
  case NIF.get_slave_identity(slave_config_ref) do
    {:ok, %{vendor_id: 0x02, product_code: 0x0C823052}} ->
      {:ok, DeviceSchemas.EL3202}

    {:ok, %{vendor_id: 0x02, product_code: 0x0C824052}} ->
      {:ok, DeviceSchemas.EL3204}  # 4-channel variant

    {:ok, identity} ->
      {:error, {:unsupported_device, identity}}

    {:error, reason} ->
      {:error, {:identity_query_failed, reason}}
  end
end
```

---

### 8.2 Runtime SDO Read/Write

For dynamic parameter access after activation:

```elixir
# Future API
Slave.sdo_write(slave, :ch1_limit1, 1500)  # Updates limit during operation
{:ok, value} = Slave.sdo_read(slave, :ch1_limit1)
```

Requires:
- NIF bindings for `ecrt_slave_config_create_sdo_request`
- State machine management in Elixir
- GenServer to track request lifecycle

---

### 8.3 Configuration Profiles

```elixir
# Reusable configuration presets
defmodule MyApp.SensorProfiles do
  def high_accuracy_rtd do
    [
      enable_filter: true,
      filter_settings: 0x02,        # 2 Hz (slow, accurate)
      enable_automatic_cal: true,
      calibration_interval: 60,     # Every hour
      presentation: :high_resolution
    ]
  end

  def fast_response_rtd do
    [
      enable_filter: false,
      presentation: :low_resolution
    ]
  end
end

# Apply profile
Slave.configure(slave,
  ch1: MyApp.SensorProfiles.high_accuracy_rtd(),
  ch2: MyApp.SensorProfiles.fast_response_rtd()
)
```

---

### 8.4 Verification Mode

Post-activation read-back to verify configuration:

```elixir
Slave.configure(slave, config, verify: true)
# After activation, reads back all configured SDOs and compares
```

---

## 9. References

### 9.1 IgH EtherCAT Master Documentation

- **ecrt.h API Reference**: `/usr/local/include/ecrt.h`
- **Official Documentation**: https://etherlab.org/download/ethercat/ethercat-1.5.2.pdf
- **SDO Configuration Section**: Chapter 7.3 "Service Data Objects"

### 9.2 EtherCAT Specification

- **ETG.1000.6** - EtherCAT Protocol Specification
- **ETG.1020** - CoE (CANopen over EtherCAT) - Defines SDO protocol

### 9.3 Beckhoff EL3202 Documentation

- **Manual**: https://www.beckhoff.com/EL3202
- **Object Dictionary**: Contains full SDO map with descriptions
- **Application Notes**: RTD connection and calibration procedures

---

## 10. Summary

This design provides a **high-level, type-safe, persistent** configuration interface for EtherCAT slaves via SDO operations. The `Slave.configure/2` API:

✅ Uses **pre-activation configuration SDOs** for persistence
✅ Provides **device-specific schemas** with validation
✅ **Prevents PDO configuration conflicts** through restrictions
✅ Enables **declarative, self-documenting** slave setup
✅ Requires **minimal NIF additions** (4 functions)

**Next Steps:**
1. Implement Phase 1 (NIF bindings)
2. Test with hardware EL3202
3. Expand schema library for additional devices
4. Add runtime SDO support for dynamic parameter access

---

**End of Design Document**
