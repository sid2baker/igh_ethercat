const std = @import("std");
const beam = @import("beam");
const ecrt = @import("ecrt.zig").c;

pub const State = struct {
    ec_slave_config: ?*ecrt.ec_slave_config_t,
    position: u16,

    pub fn init(ec_slave_config: *ecrt.ec_slave_config, position: u16) State {
        return .{
            .ec_slave_config = ec_slave_config,
            .position = position,
        };
    }
    pub fn deinit(self: *State) void {
        _ = self;
    }
};
