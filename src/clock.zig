//! Wall and monotonic time from C, without an Io instance: a scan and a
//! delete batch need deadlines and ages, not async cancellations.
const std = @import("std");

extern "c" fn time(t: ?*i64) i64;

const Timespec = extern struct { sec: i64, nsec: i64 };
extern "c" fn clock_gettime(clock: c_int, t: *Timespec) c_int;
extern "c" fn usleep(usec: c_uint) c_int;

/// Seconds since the Unix epoch.
pub fn now() i64 {
    return time(null);
}

/// Milliseconds on a clock that never goes back, for deadlines and tracing.
pub fn monotonicMs() i64 {
    const CLOCK_MONOTONIC: c_int = 6;
    var t: Timespec = undefined;
    if (clock_gettime(CLOCK_MONOTONIC, &t) == 0) {
        return t.sec * 1_000 + @divTrunc(t.nsec, 1_000_000);
    }
    return 0;
}

pub fn sleepMs(ms: u32) void {
    _ = usleep(ms * 1_000);
}
