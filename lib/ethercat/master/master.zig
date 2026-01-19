const std = @import("std");
const beam = @import("beam");
const ecrt = @import("ecrt.zig").c;

// when true, one or more slaves are in the corresponding state
pub const SlaveStates = struct {
    in_init: bool,
    in_preop: bool,
    in_safeop: bool,
    in_op: bool,

    pub fn init() SlaveStates {
        return .{
            .in_init = false,
            .in_preop = false,
            .in_safeop = false,
            .in_op = false,
        };
    }

    pub fn update(self: *SlaveStates, raw_state: u4) bool {
        const new_init = @as(u1, @truncate(raw_state >> 0)) == 1;
        const new_preop = @as(u1, @truncate(raw_state >> 1)) == 1;
        const new_safeop = @as(u1, @truncate(raw_state >> 2)) == 1;
        const new_op = @as(u1, @truncate(raw_state >> 3)) == 1;

        const changed = (self.in_init != new_init) or
            (self.in_preop != new_preop) or
            (self.in_safeop != new_safeop) or
            (self.in_op != new_op);

        self.in_init = new_init;
        self.in_preop = new_preop;
        self.in_safeop = new_safeop;
        self.in_op = new_op;

        return changed;
    }
};

pub const State = struct {
    ec_master: ?*ecrt.ec_master_t,
    index: u8,
    pid: beam.pid,
    interval_us: u64,
    cyclic_core: u8,
    link_up: bool,
    slaves_responding: u32,
    slave_states: SlaveStates,
    should_stop: std.atomic.Value(bool),

    pub fn init(ec_master: *ecrt.ec_master_t, index: u8, pid: beam.pid) State {
        return .{
            .ec_master = ec_master,
            .index = index,
            .pid = pid,
            .interval_us = 10000,
            .cyclic_core = 0,
            .link_up = false,
            .slaves_responding = 0,
            .slave_states = SlaveStates.init(),
            .should_stop = std.atomic.Value(bool).init(true),
        };
    }

    pub fn deinit(self: *State) void {
        self.should_stop.store(true, .release);
        if (self.ec_master) |ec_master| {
            ecrt.ecrt_release_master(ec_master);
            self.ec_master = null;
        }
    }

    pub fn start_thread(self: *State) bool {
        if (self.ec_master == null) return false;
        return self.should_stop.cmpxchgStrong(true, false, .acq_rel, .acquire) == null;
    }

    pub fn stop_thread(self: *State) bool {
        return self.should_stop.cmpxchgStrong(false, true, .acq_rel, .acquire) == null;
    }

    pub fn is_running(self: *const State) bool {
        return !self.should_stop.load(.acquire);
    }
};
