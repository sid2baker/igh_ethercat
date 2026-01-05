pub const PdoDirection = enum(u8) {
    invalid = 0,
    output = 1,
    input = 2,
};

pub const WatchdogMode = enum(u8) {
    default = 0,
    enabled = 1,
    disabled = 2,
};
