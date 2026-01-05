pub const BitError = error{
    InvalidLength,
    OutOfBounds,
    ValueTooLarge,
    SpansTooManyBytes,
};

pub const Error = BitError;
