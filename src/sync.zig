//! pthread-backed mutex and condition variable: Zig 0.17's std.Thread no
//! longer ships them, and the walker's worker pool needs a real condvar,
//! not a spinlock. Sized for pthread_mutex_t / pthread_cond_t on any Mac.
const std = @import("std");

const c = struct {
    extern "c" fn pthread_mutex_init(m: *anyopaque, attr: ?*const anyopaque) c_int;
    extern "c" fn pthread_mutex_lock(m: *anyopaque) c_int;
    extern "c" fn pthread_mutex_unlock(m: *anyopaque) c_int;
    extern "c" fn pthread_cond_init(c: *anyopaque, attr: ?*const anyopaque) c_int;
    extern "c" fn pthread_cond_signal(c: *anyopaque) c_int;
    extern "c" fn pthread_cond_broadcast(c: *anyopaque) c_int;
    extern "c" fn pthread_cond_wait(c: *anyopaque, m: *anyopaque) c_int;
};

pub const Mutex = extern struct {
    bytes: [80]u8 align(8) = undefined,

    pub fn init(m: *Mutex) void {
        _ = c.pthread_mutex_init(@ptrCast(m), null);
    }

    pub fn lock(m: *Mutex) void {
        _ = c.pthread_mutex_lock(@ptrCast(m));
    }

    pub fn unlock(m: *Mutex) void {
        _ = c.pthread_mutex_unlock(@ptrCast(m));
    }
};

pub const Condition = extern struct {
    bytes: [80]u8 align(8) = undefined,

    pub fn init(c_: *Condition) void {
        _ = c.pthread_cond_init(@ptrCast(c_), null);
    }

    pub fn wait(c_: *Condition, m: *Mutex) void {
        _ = c.pthread_cond_wait(@ptrCast(c_), @ptrCast(m));
    }

    pub fn signal(c_: *Condition) void {
        _ = c.pthread_cond_signal(@ptrCast(c_));
    }

    pub fn broadcast(c_: *Condition) void {
        _ = c.pthread_cond_broadcast(@ptrCast(c_));
    }
};
