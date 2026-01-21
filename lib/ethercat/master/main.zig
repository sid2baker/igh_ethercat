const std = @import("std");
const beam = @import("beam");

const root = @import("root");
const ecrt = @import("ecrt.zig").c;

const errors = @import("errors.zig");
const types = @import("types.zig");

const master = @import("master.zig");
const domain = @import("domain.zig");
const slave = @import("slave.zig");

const thread = @import("thread.zig");

pub const MasterResource = beam.Resource(*master.State, root, .{ .Callbacks = MasterCallbacks });
pub const DomainResource = beam.Resource(*domain.State, root, .{ .Callbacks = DomainCallbacks });
pub const SlaveResource = beam.Resource(*slave.State, root, .{ .Callbacks = SlaveCallbacks });

const MasterCallbacks = struct {
    pub fn dtor(state: **master.State) void {
        std.log.debug("Master gargabe collected", .{});
        state.*.deinit();
        beam.allocator.destroy(state.*);
    }
};

const DomainCallbacks = struct {
    pub fn dtor(state: **domain.State) void {
        std.log.debug("Domain gargabe collected", .{});
        state.*.deinit();
        beam.allocator.destroy(state.*);
    }
};

const SlaveCallbacks = struct {
    pub fn dtor(state: **slave.State) void {
        std.log.debug("Slave gargabe collected", .{});
        state.*.deinit();
        beam.allocator.destroy(state.*);
    }
};

pub fn version() beam.term {
    const v = ecrt.ecrt_version_magic();
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, @intCast(v), .little);
    return beam.make(.{ bytes[1], bytes[0] }, .{});
}

pub fn create_master(index: u8) !beam.term {
    const master_state = try beam.allocator.create(master.State);
    const pid = try beam.self(.{});

    if (ecrt.ecrt_request_master(index)) |ec_master| {
        master_state.* = master.State.init(ec_master, index, pid);
        const resource = try MasterResource.create(master_state, .{});

        return beam.make(.{ .ok, resource }, .{});
    } else {
        return beam.make_error_pair(.master_not_found, .{});
    }
}

pub fn destroy_master(master_resource: MasterResource) !beam.term {
    const master_state = master_resource.unpack();
    master_state.deinit();
    return beam.make(.ok, .{});
}

pub fn reset_master(master_resource: MasterResource) !beam.term {
    const master_state = master_resource.unpack();
    const index = master_state.index;
    const pid = master_state.pid;
    master_state.deinit();
    if (ecrt.ecrt_request_master(master_state.index)) |ec_master| {
        master_state.* = master.State.init(ec_master, index, pid);
        return beam.make(.ok, .{});
    } else {
        return beam.make_error_pair(.master_not_found, .{});
    }
}

pub fn set_cyclic_interval(master_resource: MasterResource, interval_us: u64) beam.term {
    const master_state = master_resource.unpack();
    const result = ecrt.ecrt_master_set_send_interval(master_state.ec_master, interval_us);
    if (result != 0) {
        return beam.make_error_pair(.set_interval_failed, .{});
    }
    master_state.interval_us = interval_us;
    return beam.make(.ok, .{});
}

pub fn set_cyclic_core(master_resource: MasterResource, core: u8) beam.term {
    const master_state = master_resource.unpack();
    master_state.cyclic_core = core;
    return beam.make(.ok, .{});
}

pub fn get_master_info(master_resource: MasterResource) beam.term {
    const ec_master = master_resource.unpack().ec_master;

    // this is needed since zig doesn't support bitfields. See https://github.com/ziglang/zig/issues/1499
    var raw_state: packed struct {
        slaves_count: u32,
        link_up: u1,
        _padding: u31,
        scan_busy: u8,
        app_time: u64,
    } = undefined;

    const result = ecrt.ecrt_master(ec_master, @ptrCast(&raw_state));
    if (result != 0) {
        return beam.make_error_pair(.get_state_failed, .{});
    }

    const master_info = .{
        .slaves_count = raw_state.slaves_count,
        .link_up = raw_state.link_up == 1,
        .scan_busy = raw_state.scan_busy,
        .app_time = raw_state.app_time,
    };

    return beam.make(.{ .ok, master_info }, .{});
}

pub fn create_domain(master_resource: MasterResource, cycle_count: u32) !beam.term {
    const master_state = master_resource.unpack();
    const ec_domain = ecrt.ecrt_master_create_domain(master_state.ec_master) orelse {
        return beam.make_error_pair(.domain_creation_failed, .{});
    };

    const domain_state = try beam.allocator.create(domain.State);
    domain_state.* = domain.State.init(ec_domain, cycle_count);

    const resource = try DomainResource.create(domain_state, .{});
    return beam.make(.{ .ok, resource }, .{});
}

pub fn get_slave_info(master_resource: MasterResource, position: u16) beam.term {
    const ec_master = master_resource.unpack().ec_master;
    var ec_slave_info: ecrt.ec_slave_info_t = undefined;
    const result = ecrt.ecrt_master_get_slave(ec_master, position, &ec_slave_info);
    if (result != 0) {
        return beam.make_error_pair(.slave_not_found, .{});
    }

    const slave_info = .{
        .position = ec_slave_info.position,
        .vendor_id = ec_slave_info.vendor_id,
        .product_code = ec_slave_info.product_code,
        .revision_no = ec_slave_info.revision_number,
        .serial_no = ec_slave_info.serial_number,
    };

    return beam.make(.{ .ok, slave_info }, .{});
}

pub fn create_slave(master_resource: MasterResource, alias: u16, position: u16, vendor_id: u32, product_code: u32) !beam.term {
    const ec_master = master_resource.unpack().ec_master;
    const slave_config = ecrt.ecrt_master_slave_config(ec_master, alias, position, vendor_id, product_code) orelse {
        return beam.make_error_pair(.slave_config_failed, .{});
    };

    const slave_state = try beam.allocator.create(slave.State);
    slave_state.* = slave.State.init(slave_config, position);

    const resource = try SlaveResource.create(slave_state, .{});
    return beam.make(.{ .ok, resource }, .{});
}

pub fn slave_config_sdo(slave_resource: SlaveResource, index: u16, subindex: u8, data: beam.term) beam.term {
    const slave_config = slave_resource.unpack().ec_slave_config;
    const binary = beam.get([]u8, data, .{}) catch {
        return beam.make_error_pair(.invalid_argument, .{});
    };
    const result = ecrt.ecrt_slave_config_sdo(slave_config, index, subindex, binary.ptr, binary.len);
    if (result < 0) {
        return beam.make_error_pair(.sdo_config_failed, .{});
    }
    return beam.make(.ok, .{});
}

pub fn slave_config_sync_manager(slave_resource: SlaveResource, sync_index: u8, direction: types.PdoDirection, watchdog: types.WatchdogMode) beam.term {
    const slave_config = slave_resource.unpack().ec_slave_config;
    const result = ecrt.ecrt_slave_config_sync_manager(slave_config, sync_index, @intFromEnum(direction), @intFromEnum(watchdog));
    if (result != 0) {
        return beam.make_error_pair(.sync_manager_config_failed, .{});
    }
    return beam.make(.ok, .{});
}

pub fn slave_config_pdo_assign_clear(slave_resource: SlaveResource, sync_index: u8) beam.term {
    const slave_config = slave_resource.unpack().ec_slave_config;
    const result = ecrt.ecrt_slave_config_pdo_assign_clear(slave_config, sync_index);
    if (result != 0) {
        return beam.make_error_pair(.pdo_assign_clear_failed, .{});
    }
    return beam.make(.ok, .{});
}

pub fn slave_config_pdo_assign_add(slave_resource: SlaveResource, sync_index: u8, pdo_index: u16) beam.term {
    const slave_config = slave_resource.unpack().ec_slave_config;
    const result = ecrt.ecrt_slave_config_pdo_assign_add(slave_config, sync_index, pdo_index);
    if (result != 0) {
        return beam.make_error_pair(.pdo_assign_add_failed, .{});
    }
    return beam.make(.ok, .{});
}

pub fn slave_config_pdo_mapping_clear(slave_resource: SlaveResource, pdo_index: u16) beam.term {
    const slave_config = slave_resource.unpack().ec_slave_config;
    const result = ecrt.ecrt_slave_config_pdo_mapping_clear(slave_config, pdo_index);
    if (result != 0) {
        return beam.make_error_pair(.pdo_mapping_clear_failed, .{});
    }
    return beam.make(.ok, .{});
}

pub fn slave_config_pdo_mapping_add(slave_resource: SlaveResource, pdo_index: u16, entry_index: u16, entry_subindex: u8, bit_length: u8) beam.term {
    const slave_config = slave_resource.unpack().ec_slave_config;
    const result = ecrt.ecrt_slave_config_pdo_mapping_add(slave_config, pdo_index, entry_index, entry_subindex, bit_length);
    if (result != 0) {
        return beam.make_error_pair(.pdo_mapping_add_failed, .{});
    }
    return beam.make(.ok, .{});
}

pub fn register_pdo_entry(slave_resource: SlaveResource, domain_resource: DomainResource, entry_index: u16, entry_subindex: u8, bit_length: u8, direction: types.PdoDirection) beam.term {
    const slave_state = slave_resource.unpack();
    const domain_state = domain_resource.unpack();
    var bit_position: c_uint = 0;

    const result = ecrt.ecrt_slave_config_reg_pdo_entry(slave_state.ec_slave_config, entry_index, entry_subindex, domain_state.ec_domain, &bit_position);

    if (result < 0) {
        return beam.make_error_pair(.pdo_reg_failed, .{});
    }

    const bit_offset = @as(u16, @intCast(result)) * 8 + @as(u16, @intCast(bit_position));

    const entry_id = domain_state.add_entry(slave_state.position, bit_offset, bit_length, direction == types.PdoDirection.output) catch |err| {
        return beam.make_error_pair(err, .{});
    };

    return beam.make(.{ .ok, entry_id }, .{});
}

pub fn read_pdo_value(domain_resource: DomainResource, entry_id: u32) beam.term {
    const domain_state = domain_resource.unpack();
    const pdo_entry = domain_state.entries.items[entry_id];
    const byte_length = (pdo_entry.bit_length + 7) / 8;

    const value_u64 = domain_state.get_value(entry_id) orelse {
        return beam.make_error_pair(.uninitialized, .{});
    };

    var buffer: [8]u8 = undefined;
    std.mem.writeInt(u64, &buffer, value_u64, .little);

    return beam.make(.{ .ok, buffer[0..byte_length] }, .{});
}

pub fn write_pdo_value(domain_resource: DomainResource, entry_id: u32, value: []u8) beam.term {
    const domain_state = domain_resource.unpack();
    const pdo_entry = domain_state.entries.items[entry_id];
    const bit_length = pdo_entry.bit_length;
    const byte_length = (bit_length + 7) / 8;

    const next_value = std.mem.readVarInt(u64, value[0..byte_length], .little);
    const current_value = domain_state.get_value(entry_id);

    if (current_value == next_value) {
        return beam.make_error_pair(.already_set, .{});
    }

    domain_state.set_value(entry_id, next_value);
    return beam.make(.ok, .{});
}

// threaded functions

pub fn create_watch_hardware_thread(master_resource: MasterResource) !void {
    const master_state = master_resource.unpack();

    try thread.watch_hardware(master_state);
}

pub fn create_cyclic_thread(master_resource: MasterResource, domain_resources: []DomainResource) !void {
    const master_state = master_resource.unpack();

    var domain_states: []*domain.State = undefined;
    domain_states = try beam.allocator.alloc(*domain.State, domain_resources.len);
    defer beam.allocator.free(domain_states);

    for (domain_resources, 0..) |domain_resource, i| {
        domain_states[i] = domain_resource.unpack();
    }
    try thread.cyclic(master_state, domain_states);
}

pub fn enable_thread(master_resource: MasterResource) beam.term {
    const master_state = master_resource.unpack();
    if (master_state.start_thread()) {
        return beam.make(.ok, .{});
    } else {
        return beam.make_error_pair(.thread_already_started, .{});
    }
}

pub fn stop_thread(master_resource: MasterResource) beam.term {
    const master_state = master_resource.unpack();
    if (master_state.stop_thread()) {
        return beam.make(.ok, .{});
    } else {
        return beam.make_error_pair(.thread_not_started, .{});
    }
}
