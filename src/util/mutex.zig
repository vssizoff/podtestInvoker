const std = @import("std");

/// Thin wrapper around a normal (non-recursive) pthread mutex.
pub const Mutex = struct {
    inner: std.c.pthread_mutex_t = std.mem.zeroes(std.c.pthread_mutex_t),

    pub fn lock(self: *Mutex) void {
        _ = std.c.pthread_mutex_lock(&self.inner);
    }

    pub fn unlock(self: *Mutex) void {
        _ = std.c.pthread_mutex_unlock(&self.inner);
    }
};

pub const Condition = struct {
    inner: std.c.pthread_cond_t = std.mem.zeroes(std.c.pthread_cond_t),

    pub fn wait(self: *Condition, mutex: *Mutex) void {
        _ = std.c.pthread_cond_wait(&self.inner, &mutex.inner);
    }

    pub fn signal(self: *Condition) void {
        _ = std.c.pthread_cond_signal(&self.inner);
    }

    pub fn broadcast(self: *Condition) void {
        _ = std.c.pthread_cond_broadcast(&self.inner);
    }
};

pub const Guard = struct {
    m: *Mutex,
    pub fn init(m: *Mutex) Guard {
        m.lock();
        return .{ .m = m };
    }
    pub fn deinit(self: *Guard) void {
        self.m.unlock();
    }
};
