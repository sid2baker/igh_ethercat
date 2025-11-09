# SDO Implementation Plan - Driver-Based Architecture

## Overview

Add SDO (Service Data Object) configuration support to the IgH EtherCAT wrapper by:
1. **Core**: NIF bindings for raw SDO operations
2. **Helpers**: Optional utilities for type encoding and validation
3. **Drivers**: Device-specific SDO configuration in driver `configure/2` callbacks

---

## Architecture Decision

✅ **SDO configuration happens in drivers** (not core schemas)
✅ **Core provides primitives** (NIF bindings + helpers)
✅ **Drivers live in same repo** (`lib/ethercat/drivers/`)
✅ **Helpers for power users** who understand SDO protocol

---

## Phase 1: NIF Bindings (Core)

### 1.1 Add to `lib/ethercat/nif.ex`

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
- `data` - Binary data to write

## Returns

- `:ok` - SDO configuration queued successfully
- `{:error, :allocation_failed}` - Memory allocation failed

## Timing

MUST be called BEFORE `ecrt_master_activate()`. Errors are asynchronous.

## Example

    # Configure filter setting (16-bit value)
    NIF.slave_config_sdo(slave_config, 0x8000, 0x15, <<10::little-16>>)
"""
@spec slave_config_sdo(reference(), non_neg_integer(), non_neg_integer(), binary()) ::
        :ok | {:error, term()}
def slave_config_sdo(_slave_config_ref, _sdo_index, _sdo_subindex, _data) do
  :erlang.nif_error(:nif_not_loaded)
end

@doc """
Configure an 8-bit SDO value (pre-activation only).

Convenience wrapper with automatic endianness handling.
"""
@spec slave_config_sdo8(reference(), non_neg_integer(), non_neg_integer(), 0..255) ::
        :ok | {:error, term()}
def slave_config_sdo8(_slave_config_ref, _sdo_index, _sdo_subindex, _value) do
  :erlang.nif_error(:nif_not_loaded)
end

@doc """
Configure a 16-bit SDO value (pre-activation only).

Convenience wrapper with automatic endianness handling.
"""
@spec slave_config_sdo16(reference(), non_neg_integer(), non_neg_integer(), 0..65535) ::
        :ok | {:error, term()}
def slave_config_sdo16(_slave_config_ref, _sdo_index, _sdo_subindex, _value) do
  :erlang.nif_error(:nif_not_loaded)
end

@doc """
Configure a 32-bit SDO value (pre-activation only).

Convenience wrapper with automatic endianness handling.
"""
@spec slave_config_sdo32(reference(), non_neg_integer(), non_neg_integer(), 0..4_294_967_295) ::
        :ok | {:error, term()}
def slave_config_sdo32(_slave_config_ref, _sdo_index, _sdo_subindex, _value) do
  :erlang.nif_error(:nif_not_loaded)
end
```

### 1.2 Zig/C NIF Implementation

Add to NIF bindings (likely in Zig):

```zig
// slave_config_sdo
fn slave_config_sdo_nif(env: beam.env, argc: c_int, argv: [*c]const beam.term)
    callconv(.C) beam.term
{
    if (argc != 4) return beam.make_badarg(env);

    // Extract slave_config reference
    var slave_config: *ecrt.ec_slave_config_t = undefined;
    if (!get_slave_config_ref(env, argv[0], &slave_config)) {
        return beam.make_badarg(env);
    }

    // Extract index, subindex
    var index: c_uint = undefined;
    var subindex: c_uint = undefined;
    if (!beam.get_uint(env, argv[1], &index) or
        !beam.get_uint(env, argv[2], &subindex)) {
        return beam.make_badarg(env);
    }

    // Extract binary data
    var data: beam.binary = undefined;
    if (!beam.inspect_binary(env, argv[3], &data)) {
        return beam.make_badarg(env);
    }

    // Validate ranges
    if (index > 0xFFFF or subindex > 0xFF) {
        return beam.make_badarg(env);
    }

    // Call ecrt API
    const result = ecrt.ecrt_slave_config_sdo(
        slave_config,
        @intCast(u16, index),
        @intCast(u8, subindex),
        data.data,
        data.size
    );

    if (result < 0) {
        return error_tuple(env, "allocation_failed");
    }

    return beam.make_atom(env, "ok");
}

// slave_config_sdo8/16/32 - similar pattern
fn slave_config_sdo8_nif(...) { ... }
fn slave_config_sdo16_nif(...) { ... }
fn slave_config_sdo32_nif(...) { ... }

// Export functions
export const nif_funcs = [_]beam.ErlNifFunc{
    // ... existing functions
    beam.ErlNifFunc{ .name = "slave_config_sdo", .arity = 4, .fptr = slave_config_sdo_nif, .flags = 0 },
    beam.ErlNifFunc{ .name = "slave_config_sdo8", .arity = 4, .fptr = slave_config_sdo8_nif, .flags = 0 },
    beam.ErlNifFunc{ .name = "slave_config_sdo16", .arity = 4, .fptr = slave_config_sdo16_nif, .flags = 0 },
    beam.ErlNifFunc{ .name = "slave_config_sdo32", .arity = 4, .fptr = slave_config_sdo32_nif, .flags = 0 },
};
```

---

## Phase 2: Helper Utilities (Optional)

### 2.1 Create `lib/ethercat/sdo.ex`

```elixir
defmodule EtherCAT.SDO do
  @moduledoc """
  Helper utilities for SDO (Service Data Object) configuration.

  Provides type encoding, validation, and common patterns for driver authors.
  Use these helpers if you understand the EtherCAT SDO protocol.

  ## Warning

  Incorrect SDO configuration can:
  - Prevent slave from reaching operational state
  - Cause incorrect sensor readings
  - Damage hardware in extreme cases

  Always consult device documentation before configuring SDOs.
  """

  alias EtherCAT.NIF

  @type sdo_index :: 0x0000..0xFFFF
  @type sdo_subindex :: 0x00..0xFF
  @type slave_config :: reference()

  ## Type Encoding Helpers

  @doc """
  Encode a boolean value to SDO binary format.
  """
  @spec encode_bool(boolean()) :: <<_::8>>
  def encode_bool(true), do: <<1::8>>
  def encode_bool(false), do: <<0::8>>

  @doc """
  Encode an 8-bit unsigned integer.
  """
  @spec encode_uint8(0..255) :: <<_::8>>
  def encode_uint8(value) when value in 0..255, do: <<value::8>>

  @doc """
  Encode a 16-bit unsigned integer (little-endian).
  """
  @spec encode_uint16(0..65535) :: <<_::16>>
  def encode_uint16(value) when value in 0..65535, do: <<value::little-16>>

  @doc """
  Encode a 32-bit unsigned integer (little-endian).
  """
  @spec encode_uint32(0..4_294_967_295) :: <<_::32>>
  def encode_uint32(value) when value in 0..4_294_967_295, do: <<value::little-32>>

  @doc """
  Encode a 16-bit signed integer (little-endian).
  """
  @spec encode_int16(-32768..32767) :: <<_::16>>
  def encode_int16(value) when value in -32768..32767, do: <<value::little-signed-16>>

  @doc """
  Encode a 32-bit signed integer (little-endian).
  """
  @spec encode_int32(integer()) :: <<_::32>>
  def encode_int32(value), do: <<value::little-signed-32>>

  ## Configuration Helpers

  @doc """
  Configure multiple SDOs in sequence.

  Stops on first error and returns the failing SDO index/subindex.

  ## Example

      SDO.configure_batch(slave_config, [
        {0x8000, 0x06, <<1>>},           # Enable filter
        {0x8000, 0x15, <<10::little-16>>}, # Filter setting
        {0x8000, 0x13, <<100::little-16>>} # Limit 1
      ])
  """
  @spec configure_batch(slave_config(), [{sdo_index(), sdo_subindex(), binary()}]) ::
          :ok | {:error, {sdo_index(), sdo_subindex(), term()}}
  def configure_batch(slave_config, sdo_list) do
    Enum.reduce_while(sdo_list, :ok, fn {index, subindex, data}, :ok ->
      case NIF.slave_config_sdo(slave_config, index, subindex, data) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {index, subindex, reason}}}
      end
    end)
  end

  @doc """
  Configure an SDO with optional validation.

  ## Options

  - `:validate_range` - `{min, max}` tuple to check value is in range
  - `:allow_pdo_config` - Allow PDO mapping SDOs (default: false)

  ## Example

      # Configure with range validation
      SDO.configure(slave_config, 0x8000, 0x13, <<100::little-16>>,
        validate_range: {0, 1000})

      # Allow PDO configuration (advanced)
      SDO.configure(slave_config, 0x1C12, 0x01, <<0x1604::little-16>>,
        allow_pdo_config: true)
  """
  @spec configure(slave_config(), sdo_index(), sdo_subindex(), binary(), keyword()) ::
          :ok | {:error, term()}
  def configure(slave_config, index, subindex, data, opts \\ []) do
    with :ok <- validate_pdo_restriction(index, opts),
         :ok <- validate_range(data, opts) do
      NIF.slave_config_sdo(slave_config, index, subindex, data)
    end
  end

  @doc """
  Check if an SDO index is in the restricted PDO range.

  Returns `true` for PDO assignment (0x1C10-0x1C2F) or PDO mapping (0x1600-0x1BFF).
  """
  @spec pdo_sdo?(sdo_index()) :: boolean()
  def pdo_sdo?(index) do
    (index >= 0x1C10 and index <= 0x1C2F) or
    (index >= 0x1600 and index <= 0x17FF) or
    (index >= 0x1A00 and index <= 0x1BFF)
  end

  ## Private Helpers

  defp validate_pdo_restriction(index, opts) do
    if pdo_sdo?(index) and not Keyword.get(opts, :allow_pdo_config, false) do
      {:error, {:restricted_sdo, index,
                "PDO configuration SDO. Use allow_pdo_config: true to override."}}
    else
      :ok
    end
  end

  defp validate_range(data, opts) do
    case Keyword.get(opts, :validate_range) do
      {min, max} ->
        # Decode as signed 16-bit for validation
        case data do
          <<value::little-signed-16>> when value >= min and value <= max -> :ok
          <<value::little-signed-16>> -> {:error, {:out_of_range, value, min, max}}
          _ -> :ok  # Skip validation for non-16-bit
        end
      nil -> :ok
    end
  end
end
```

---

## Phase 3: Driver Integration

### 3.1 Update `lib/ethercat/slave.ex`

Expose slave_config reference to drivers:

```elixir
# In Slave struct, ensure slave_config is accessible
defstruct [
  :driver,
  :driver_state,
  :master,
  :slave_config,  # ← Drivers need this for SDO config
  # ... other fields
]

# Pass slave_config to driver in init
def init({master, position, driver, slave_config, sync_count}) do
  initial_state = %{
    slave_config: slave_config,  # ← Available to driver
    sync_count: sync_count
  }

  {:ok, driver_state} = driver.configure(initial_state, %{})

  {:ok, %__MODULE__{
    driver: driver,
    driver_state: driver_state,
    master: master,
    slave_config: slave_config,
    # ...
  }}
end
```

### 3.2 Example EL3202 Driver

Create `lib/ethercat/drivers/el3202.ex`:

```elixir
defmodule EtherCAT.Drivers.EL3202 do
  @moduledoc """
  Beckhoff EL3202 - 2-Channel RTD (PT100/PT1000) Input Terminal

  ## Supported Configuration

  Pass a configuration map to `configure/2` with any of these options:

  ### Channel 1
  - `:ch1_enable_filter` - Enable signal filtering (boolean)
  - `:ch1_filter_settings` - Filter cutoff frequency (0-65535)
  - `:ch1_enable_limit1` - Enable limit 1 alarm (boolean)
  - `:ch1_limit1` - Limit 1 value in 0.1°C resolution (int16)
  - `:ch1_enable_limit2` - Enable limit 2 alarm (boolean)
  - `:ch1_limit2` - Limit 2 value in 0.1°C resolution (int16)
  - `:ch1_rtd_element` - RTD type: `:pt100` or `:pt1000`
  - `:ch1_connection_tech` - Connection: `:two_wire`, `:three_wire`, `:four_wire`

  ### Channel 2
  - Same options as channel 1, with `ch2_` prefix

  ## Example

      config = %{
        ch1_enable_filter: true,
        ch1_filter_settings: 10,  # 10 Hz cutoff
        ch1_enable_limit1: true,
        ch1_limit1: 1000,         # 100.0°C
        ch2_rtd_element: :pt1000
      }

      {:ok, state} = EL3202.configure(initial_state, config)
  """
  use EtherCAT.Slave.Driver
  alias EtherCAT.{NIF, SDO}

  @impl true
  def configure(state, config) do
    slave_config = state.slave_config

    with :ok <- configure_channel_1(slave_config, config),
         :ok <- configure_channel_2(slave_config, config) do
      {:ok, Map.put(state, :configured, true)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def list_pdos(_state) do
    [
      :ch1_status,      # 0x6000:00 - Channel 1 status byte
      :ch1_value,       # 0x6000:11 - Channel 1 temperature value
      :ch2_status,      # 0x6010:00 - Channel 2 status byte
      :ch2_value        # 0x6010:11 - Channel 2 temperature value
    ]
  end

  @impl true
  def pdo_info(_state, :ch1_status) do
    {:ok, %{
      sync_manager: {3, 2, 0},  # SM3, input, default watchdog
      pdo_index: 0x1A00,
      entry: {0x6000, 0x00, 16}
    }}
  end

  def pdo_info(_state, :ch1_value) do
    {:ok, %{
      sync_manager: {3, 2, 0},
      pdo_index: 0x1A00,
      entry: {0x6000, 0x11, 16}
    }}
  end

  def pdo_info(_state, :ch2_status) do
    {:ok, %{
      sync_manager: {3, 2, 0},
      pdo_index: 0x1A01,
      entry: {0x6010, 0x00, 16}
    }}
  end

  def pdo_info(_state, :ch2_value) do
    {:ok, %{
      sync_manager: {3, 2, 0},
      pdo_index: 0x1A01,
      entry: {0x6010, 0x11, 16}
    }}
  end

  @impl true
  def terminate(_state), do: :ok

  ## Private Configuration Functions

  defp configure_channel_1(slave_config, config) do
    sdos = build_channel_sdos(0x8000, config, :ch1)
    SDO.configure_batch(slave_config, sdos)
  end

  defp configure_channel_2(slave_config, config) do
    sdos = build_channel_sdos(0x8010, config, :ch2)
    SDO.configure_batch(slave_config, sdos)
  end

  defp build_channel_sdos(base_index, config, channel_prefix) do
    [
      # Enable bits (0x01-0x0B)
      if config[:"#{channel_prefix}_enable_filter"] do
        {base_index, 0x06, SDO.encode_bool(true)}
      end,

      if config[:"#{channel_prefix}_enable_limit1"] do
        {base_index, 0x07, SDO.encode_bool(true)}
      end,

      if config[:"#{channel_prefix}_enable_limit2"] do
        {base_index, 0x08, SDO.encode_bool(true)}
      end,

      # Value settings (0x11-0x1B)
      if filter_val = config[:"#{channel_prefix}_filter_settings"] do
        {base_index, 0x15, SDO.encode_uint16(filter_val)}
      end,

      if limit1 = config[:"#{channel_prefix}_limit1"] do
        {base_index, 0x13, SDO.encode_int16(limit1)}
      end,

      if limit2 = config[:"#{channel_prefix}_limit2"] do
        {base_index, 0x14, SDO.encode_int16(limit2)}
      end,

      # RTD element type
      if rtd_elem = config[:"#{channel_prefix}_rtd_element"] do
        {base_index, 0x19, encode_rtd_element(rtd_elem)}
      end,

      # Connection technology
      if conn_tech = config[:"#{channel_prefix}_connection_tech"] do
        {base_index, 0x1A, encode_connection_tech(conn_tech)}
      end
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp encode_rtd_element(:pt100), do: <<0::little-16>>
  defp encode_rtd_element(:pt1000), do: <<1::little-16>>

  defp encode_connection_tech(:two_wire), do: <<0::little-16>>
  defp encode_connection_tech(:three_wire), do: <<1::little-16>>
  defp encode_connection_tech(:four_wire), do: <<2::little-16>>
end
```

---

## Phase 4: User API

### 4.1 Usage Pattern

```elixir
# Start master
{:ok, master} = EtherCAT.Master.create()

# Create slave with EL3202 driver
{:ok, slave} = EtherCAT.Slave.start_link(
  master: master,
  position: 0,
  driver: EtherCAT.Drivers.EL3202,
  slave_config: slave_config_ref,
  sync_count: 4
)

# Configure slave (calls driver's configure/2 with SDO operations)
config = %{
  ch1_enable_filter: true,
  ch1_filter_settings: 10,
  ch1_enable_limit1: true,
  ch1_limit1: 1000,  # 100.0°C
  ch2_rtd_element: :pt1000
}

{:ok, _state} = EtherCAT.Slave.configure(slave, config)

# Register PDOs (separate from SDO config)
{:ok, _} = EtherCAT.Slave.register_pdos(slave, [:ch1_value, :ch2_value], :default_domain)

# Activate master (SDO downloads happen here)
:ok = EtherCAT.Master.activate(master)
```

---

## Testing Strategy

### Unit Tests

```elixir
defmodule EtherCAT.SDOTest do
  use ExUnit.Case
  alias EtherCAT.SDO

  describe "type encoding" do
    test "encode_bool/1" do
      assert SDO.encode_bool(true) == <<1>>
      assert SDO.encode_bool(false) == <<0>>
    end

    test "encode_uint16/1" do
      assert SDO.encode_uint16(0x0A0B) == <<0x0B, 0x0A>>  # Little-endian
    end

    test "encode_int16/1" do
      assert SDO.encode_int16(-100) == <<156, 255>>  # Two's complement
    end
  end

  describe "pdo_sdo?/1" do
    test "detects PDO assignment range" do
      assert SDO.pdo_sdo?(0x1C12)
      assert SDO.pdo_sdo?(0x1C13)
    end

    test "detects PDO mapping range" do
      assert SDO.pdo_sdo?(0x1A00)
      assert SDO.pdo_sdo?(0x1600)
    end

    test "allows non-PDO SDOs" do
      refute SDO.pdo_sdo?(0x8000)
      refute SDO.pdo_sdo?(0x1000)
    end
  end
end
```

### Hardware Integration Test

```elixir
defmodule EtherCAT.Drivers.EL3202Test do
  use ExUnit.Case

  @moduletag :hardware  # Only run with actual EL3202

  test "configures EL3202 with limits" do
    {:ok, master} = EtherCAT.Master.create()

    {:ok, slave} = EtherCAT.Slave.start_link(
      master: master,
      position: 0,
      driver: EtherCAT.Drivers.EL3202,
      slave_config: get_slave_config(),
      sync_count: 4
    )

    config = %{
      ch1_enable_limit1: true,
      ch1_limit1: 1000
    }

    assert {:ok, _} = EtherCAT.Slave.configure(slave, config)
    assert :ok = EtherCAT.Master.activate(master)

    # Verify slave reaches OP state
    assert_slave_operational(slave, timeout: 5000)
  end
end
```

---

## Documentation

### 5.1 Add to README.md

```markdown
## SDO Configuration

EtherCAT slaves can be configured via SDO (Service Data Object) operations
before master activation. SDO configuration is handled by device drivers.

### Using Pre-Built Drivers

```elixir
# EL3202 RTD temperature input
{:ok, slave} = Slave.start_link(
  driver: EtherCAT.Drivers.EL3202,
  # ... other options
)

Slave.configure(slave, %{
  ch1_enable_filter: true,
  ch1_filter_settings: 10,
  ch1_limit1: 1000  # 100.0°C alarm threshold
})
```

### Writing Custom Drivers

Use the `EtherCAT.SDO` helpers in your driver's `configure/2` callback:

```elixir
defmodule MyDevice.Driver do
  use EtherCAT.Slave.Driver
  alias EtherCAT.{NIF, SDO}

  @impl true
  def configure(state, config) do
    slave_config = state.slave_config

    # Configure device-specific SDOs
    :ok = NIF.slave_config_sdo16(slave_config, 0x8000, 0x15, config[:filter_hz])
    :ok = SDO.configure_batch(slave_config, [
      {0x8000, 0x06, SDO.encode_bool(true)},
      {0x8000, 0x13, SDO.encode_int16(config[:limit])}
    ])

    {:ok, state}
  end
end
```
```

---

## Migration Path

1. **Phase 1**: Implement NIF bindings (1-2 days)
2. **Phase 2**: Add SDO helper module (1 day)
3. **Phase 3**: Create EL3202 driver as example (1 day)
4. **Phase 4**: Documentation and tests (1 day)
5. **Phase 5**: Hardware validation with your EL3202 (1 day)

Total: ~1 week for complete implementation

---

## Benefits of This Architecture

✅ **Lean Core** - Only 4 NIF functions, no device bloat
✅ **Driver Encapsulation** - SDO config lives with PDO config
✅ **Flexible** - Users can write custom drivers easily
✅ **Safe** - Helpers provide validation for those who want it
✅ **Maintainable** - Device knowledge stays in drivers
✅ **Consistent** - Same pattern as existing driver architecture

---

## Next Steps

Ready to implement Phase 1 (NIF bindings)?

**Implementation checklist:**
- [ ] Add NIF function signatures to `lib/ethercat/nif.ex`
- [ ] Implement Zig/C bindings for `ecrt_slave_config_sdo*`
- [ ] Add basic tests
- [ ] Verify compilation

Shall we proceed?
