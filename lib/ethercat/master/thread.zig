const std = @import("std");
const beam = @import("beam");
const ecrt = @import("ecrt.zig").c;
const linux = std.os.linux;

const master = @import("master.zig");
const domain = @import("domain.zig");

pub fn watch_hardware(master_state: *master.State) !void {
    const ec_master = master_state.ec_master orelse return;

    // Activate master before starting watch operation
    _ = ecrt.ecrt_master_activate(ec_master);
    defer _ = ecrt.ecrt_master_deactivate(ec_master);

    while (master_state.is_running()) {
        _ = ecrt.ecrt_master_receive(ec_master);
        _ = ecrt.ecrt_master_send(ec_master);

        check_master_state(master_state);

        std.Thread.sleep(std.time.ns_per_ms);
    }
}

pub fn cyclic(master_state: *master.State, domain_states: []*domain.State) !void {
    const ec_master = master_state.ec_master orelse return;
    const master_pid = master_state.pid;
    const interval_us = master_state.interval_us;

    // Pin thread to configured CPU core
    set_cpu_affinity(master_state.cyclic_core, master_pid);

    // Activate master before starting cyclic operation
    _ = ecrt.ecrt_master_activate(ec_master);
    defer _ = ecrt.ecrt_master_deactivate(ec_master);

    // needs to be called after master activation
    for (domain_states) |domain_state| {
        try domain_state.init_domain_data();
    }

    var counter: u32 = 0;

    const cycle_period_ns: u64 = interval_us *% std.time.ns_per_us;
    var next_cycle_time: u64 = @intCast(std.time.nanoTimestamp());
    var cycle_start_time: u64 = 0;

    while (master_state.is_running()) {
        // 1. Set application time (monotonic counter for DC sync)
        cycle_start_time +%= cycle_period_ns;
        _ = ecrt.ecrt_master_application_time(ec_master, cycle_start_time);

        // 2. Receive frames
        _ = ecrt.ecrt_master_receive(ec_master);

        // 3. Process domains
        for (domain_states) |domain_state| {
            // Only process this domain 1 cycle after it was queued
            if ((counter + 1) % domain_state.cycle_multiplier != 0) {
                continue;
            }

            _ = ecrt.ecrt_domain_process(domain_state.ec_domain);

            for (domain_state.entries.items) |*entry| {
                if (try domain_state.update_value(entry.id)) {
                    if (entry.is_output) {
                        entry.is_dirty = true;
                    } else {
                        const byte_length = (entry.bit_length + 7) / 8;
                        const value_u64 = domain_state.get_value(entry.id) orelse unreachable;
                        var buffer: [8]u8 = undefined;
                        std.mem.writeInt(u64, &buffer, value_u64, .little);
                        _ = try beam.send(master_pid, .{ .input_changed, entry.slave_id, entry.id, buffer[0..byte_length] }, .{});
                    }
                } else if (entry.is_dirty) {
                    entry.is_dirty = false;
                    _ = try beam.send(master_pid, .{ .output_changed, entry.slave_id, entry.id }, .{});
                }
            }

            _ = ecrt.ecrt_domain_queue(domain_state.ec_domain);
        }

        // 4. Send frames
        _ = ecrt.ecrt_master_send(ec_master);

        // 5. Update master state
        check_master_state(master_state);

        // 6. Sleep to maintain cycle rate (u64 arithmetic avoids @intCast panics)
        next_cycle_time +%= cycle_period_ns;
        const now: u64 = @intCast(std.time.nanoTimestamp());

        if (next_cycle_time > now) {
            const sleep_ns = next_cycle_time - now;
            if (sleep_ns < std.time.ns_per_s) {
                std.Thread.sleep(sleep_ns);
            }
        } else {
            const behind_ns = now - next_cycle_time;
            _ = beam.send(master_pid, .{ .cycle_missed, behind_ns }, .{}) catch {};
        }

        counter +%= 1;
    }
}

fn set_cpu_affinity(core: u8, master_pid: beam.pid) void {
    var cpuset: linux.cpu_set_t = std.mem.zeroes(linux.cpu_set_t);
    cpuset[0] = @as(usize, 1) << @intCast(core);

    linux.sched_setaffinity(0, &cpuset) catch |err| {
        const errno: u16 = @intFromError(err);
        _ = beam.send(master_pid, .{ .affinity_failed, core, errno }, .{}) catch {};
    };
}

fn check_master_state(master_state: *master.State) void {
    const ec_master = master_state.ec_master;
    const master_pid = master_state.pid;

    var raw_state: packed struct {
        slaves_responding: u32,
        al_states: u4,
        link_up: u1,
        padding: u27,
    } = undefined;

    _ = ecrt.ecrt_master_state(ec_master, @ptrCast(&raw_state));

    const link_up: bool = @bitCast(raw_state.link_up);
    if (!link_up) {
        _ = beam.send(master_pid, .link_down, .{}) catch {};
        master_state.link_up = link_up;
    }

    const topology_changed = master_state.slaves_responding != raw_state.slaves_responding or master_state.slave_states.update(raw_state.al_states);
    if (topology_changed) {
        _ = beam.send(master_pid, .{ .topology_changed, raw_state.slaves_responding, master_state.slave_states }, .{}) catch {};
        master_state.slaves_responding = raw_state.slaves_responding;
    }
}
