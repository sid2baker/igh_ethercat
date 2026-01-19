const std = @import("std");
const beam = @import("beam");
const types = @import("types.zig");
const errors = @import("errors.zig");
const ecrt = @import("ecrt.zig").c;

pub const PdoEntry = struct {
    id: u32, // Auto-incremented ID
    is_output: bool,
    is_dirty: bool,
    slave_id: u16,
    bit_offset: u16,
    bit_length: u8,
    value: ?std.atomic.Value(u64),
};

/// Domain with integer-indexed PDO entries
pub const State = struct {
    ec_domain: ?*ecrt.ec_domain_t,
    cycle_multiplier: u32,
    entries: std.ArrayList(PdoEntry),
    next_entry_id: u32,
    data: []u8, // Pointer to ecrt-managed buffer

    pub fn init(ec_domain: *ecrt.ec_domain_t, cycle_multiplier: u32) State {
        return .{
            .ec_domain = ec_domain,
            .cycle_multiplier = cycle_multiplier,
            .entries = .{},
            .next_entry_id = 0,
            .data = &[_]u8{},
        };
    }

    pub fn init_domain_data(self: *State) !void {
        const ec_domain = self.ec_domain;
        const size = ecrt.ecrt_domain_size(ec_domain);
        const data_ptr = ecrt.ecrt_domain_data(ec_domain) orelse {
            return error.InvalidDomainData;
        };

        self.data = data_ptr[0..size];
    }

    pub fn deinit(self: *State) void {
        self.entries.deinit(beam.allocator);
    }

    pub fn add_entry(self: *State, slave_id: u16, bit_offset: u16, bit_length: u8, is_output: bool) !u32 {
        const entry_id = self.next_entry_id;
        self.next_entry_id += 1;

        try self.entries.append(beam.allocator, .{
            .id = entry_id,
            .is_output = is_output,
            .is_dirty = false,
            .slave_id = slave_id,
            .bit_offset = bit_offset,
            .bit_length = bit_length,
            .value = null,
        });
        return entry_id;
    }

    pub fn update_value(self: *State, entry_id: u32) errors.BitError!bool {
        const pdo_entry = self.entries.items[entry_id];
        const bit_offset = pdo_entry.bit_offset;
        const bit_length = pdo_entry.bit_length;

        const value = try read_bits(self.data, bit_offset, bit_length);
        if (pdo_entry.is_output) {
            const next_value = self.get_value(entry_id) orelse {
                // when output initialized, set value to current value
                self.set_value(entry_id, value);
                return false;
            };
            if (value != next_value) {
                try write_bits(self.data, bit_offset, bit_length, next_value);
                return true;
            }
        } else {
            const last_value = self.get_value(entry_id);
            if (value != last_value) {
                self.set_value(entry_id, value);
                return true;
            }
        }

        return false;
    }

    pub fn set_value(self: *State, entry_id: u32, value: u64) void {
        var pdo_entry = &self.entries.items[entry_id];
        if (pdo_entry.value) |*atomic_value| {
            atomic_value.store(value, .release);
        } else {
            // Lazy initialization on first use
            pdo_entry.value = std.atomic.Value(u64).init(value);
        }
    }

    pub fn get_value(self: *State, entry_id: u32) ?u64 {
        const pdo_entry = &self.entries.items[entry_id];
        if (pdo_entry.value) |*atomic_value| {
            return atomic_value.load(.acquire);
        }
        return null;
    }
};

/// Extract bits in little-endian bit order.
/// Bit 0 is the LSB of byte 0, bit 8 is the LSB of byte 1, etc.
fn read_bits(data: []const u8, bit_offset: u16, bit_length: u8) errors.BitError!u64 {
    if (bit_length == 0 or bit_length > 64) return error.InvalidLength;
    if (@as(usize, bit_offset) + bit_length > data.len * 8) return error.OutOfBounds;

    const start_byte = bit_offset / 8;
    const start_bit: u6 = @intCast(bit_offset % 8);

    // Ensure the bit field fits in a u64 after alignment adjustment
    // Max bytes we can handle: 8 bytes + partial byte = need start_bit + bit_length <= 64
    if (@as(usize, start_bit) + bit_length > 64) return error.SpansTooManyBytes;

    const bytes_needed = (bit_length + start_bit + 7) / 8;

    // Load affected bytes into a u64 (little-endian: first byte is lowest bits)
    var temp: u64 = 0;
    for (data[start_byte..][0..bytes_needed], 0..) |b, i| {
        temp |= @as(u64, b) << @as(u6, @intCast(i * 8));
    }

    // Shift down to align the field to bit 0
    temp >>= start_bit;

    // Mask to the requested bit length
    const mask = mask_for_bits(bit_length);
    return temp & mask;
}

/// Write bits in little-endian bit order without touching other bits.
/// Bit 0 is the LSB of byte 0, bit 8 is the LSB of byte 1, etc.
fn write_bits(data: []u8, bit_offset: u16, bit_length: u8, value: u64) errors.BitError!void {
    if (bit_length == 0 or bit_length > 64) return error.InvalidLength;
    if (@as(usize, bit_offset) + bit_length > data.len * 8) return error.OutOfBounds;

    const start_byte = bit_offset / 8;
    const start_bit: u6 = @intCast(bit_offset % 8);

    // Ensure the bit field fits in a u64 after alignment adjustment
    if (@as(usize, start_bit) + bit_length > 64) return error.SpansTooManyBytes;

    // Validate that value fits in bit_length bits
    const mask = mask_for_bits(bit_length);
    if (value & ~mask != 0) return error.ValueTooLarge;

    const bytes_needed = (bit_length + start_bit + 7) / 8;

    // Load the affected bytes into a u64
    var temp: u64 = 0;
    for (data[start_byte..][0..bytes_needed], 0..) |b, i| {
        temp |= @as(u64, b) << @as(u6, @intCast(i * 8));
    }

    // Clear the target field and insert the new value
    const shifted_mask = mask << start_bit;
    temp = (temp & ~shifted_mask) | (value << start_bit);

    // Write back the modified bytes
    for (data[start_byte..][0..bytes_needed], 0..) |*b, i| {
        b.* = @truncate(temp >> @as(u6, @intCast(i * 8)));
    }
}

/// Create a mask with `n` lowest bits set.
/// Handles n=64 without overflow.
inline fn mask_for_bits(n: usize) u64 {
    if (n >= 64) return ~@as(u64, 0);
    return (@as(u64, 1) << @as(u6, @intCast(n))) - 1;
}
