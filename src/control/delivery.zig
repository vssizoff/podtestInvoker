const std = @import("std");
const advertisement = @import("job.zig");

test {
    _ = @import("lease.zig");
}

pub const Claim = union(enum) {
    retry,
    stale,
    already_claimed,
    terminal,
    cancelled,
    granted: Lease,
};

pub const Lease = struct {
    fencing_token: []const u8,
    expires_unix: i64,
};

pub const Outcome = enum { deferred, ignored, rejected, started };

/// Delivery supplies ack(), retry(delay_ns), and reject(). Handler supplies
/// claim(job), persist(job, lease), and start(job, lease). Callbacks borrow the
/// job; claim tokens are borrowed from the handler through the final callback.
/// Persist must durably save the grant and reserve the local run ID. Start
/// must take its own copies before returning if it launches asynchronous work.
/// Errors stop the flow at that point. A claimed run that cannot start is
/// recovered by Backend lease expiration, including on uncertain ACK delivery.
pub fn handle(allocator: std.mem.Allocator, payload: []const u8, clock: anytype, delay_ns: i64, message: anytype, handler: anytype) !Outcome {
    const parsed = advertisement.parse(allocator, payload) catch |err| switch (err) {
        error.InvalidAdvertisement => {
            try message.reject();
            return .rejected;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer parsed.deinit();
    const job = parsed.value;
    switch (try handler.claim(job)) {
        .retry => {
            try message.retry(delay_ns);
            return .deferred;
        },
        .stale, .already_claimed, .terminal, .cancelled => {
            try message.ack();
            return .ignored;
        },
        .granted => |lease| {
            const expires = lease.expires_unix;
            if (lease.fencing_token.len == 0 or expires <= clock.now()) return error.InvalidLease;
            try handler.persist(job, lease);
            if (expires <= clock.now()) {
                try message.retry(delay_ns);
                return .deferred;
            }
            try message.ack();
            if (expires <= clock.now()) return error.LeaseExpiredBeforeStart;
            try handler.start(job, lease);
            return .started;
        },
    }
}

const Fixture = struct {
    calls: [4]u8 = undefined,
    len: usize = 0,
    result: Claim = .{ .granted = .{ .fencing_token = "token", .expires_unix = 200 } },
    fail_at: u8 = 0,

    fn record(self: *Fixture, step: u8) !void {
        self.calls[self.len] = step;
        self.len += 1;
        if (self.fail_at == step) return error.Injected;
    }
    pub fn claim(self: *Fixture, _: advertisement.Job) !Claim {
        try self.record('C');
        return self.result;
    }
    pub fn persist(self: *Fixture, _: advertisement.Job, _: Lease) !void {
        try self.record('P');
    }
    pub fn ack(self: *Fixture) !void {
        try self.record('A');
    }
    pub fn start(self: *Fixture, _: advertisement.Job, _: Lease) !void {
        try self.record('S');
    }
    pub fn retry(self: *Fixture, _: i64) !void {
        try self.record('N');
    }
    pub fn reject(self: *Fixture) !void {
        try self.record('R');
    }
};

const TestClock = struct {
    unix: i64 = 100,
    fn now(self: TestClock) i64 {
        return self.unix;
    }
};

test "persist before ACK and start, and stop on failed persistence or ACK" {
    const payload = advertisement.test_payload;
    var f: Fixture = .{};
    try std.testing.expectEqual(.started, try handle(std.testing.allocator, payload, TestClock{}, 1, &f, &f));
    try std.testing.expectEqualStrings("CPAS", f.calls[0..f.len]);
    for ([_]u8{ 'C', 'P', 'A' }, 1..) |step, count| {
        f = .{ .fail_at = step };
        try std.testing.expectError(error.Injected, handle(std.testing.allocator, payload, TestClock{}, 1, &f, &f));
        try std.testing.expectEqualStrings("CPAS"[0..count], f.calls[0..f.len]);
    }
    f = .{};
    try std.testing.expectError(error.InvalidLease, handle(std.testing.allocator, payload, TestClock{ .unix = 200 }, 1, &f, &f));
    try std.testing.expectEqualStrings("C", f.calls[0..f.len]);
}

test "classified claim decisions and malformed deliveries" {
    for ([_]Claim{ .stale, .already_claimed, .terminal, .cancelled }) |decision| {
        var f: Fixture = .{ .result = decision };
        try std.testing.expectEqual(.ignored, try handle(std.testing.allocator, advertisement.test_payload, TestClock{}, 1, &f, &f));
        try std.testing.expectEqualStrings("CA", f.calls[0..f.len]);
    }
    var f: Fixture = .{ .result = .retry };
    try std.testing.expectEqual(.deferred, try handle(std.testing.allocator, advertisement.test_payload, TestClock{}, 1, &f, &f));
    try std.testing.expectEqualStrings("CN", f.calls[0..f.len]);
    f = .{};
    try std.testing.expectEqual(.rejected, try handle(std.testing.allocator, "{}", TestClock{}, 1, &f, &f));
    try std.testing.expectEqualStrings("R", f.calls[0..f.len]);
}

const TickingClock = struct {
    tick: *u32,
    expire_at: u32,

    pub fn now(self: @This()) i64 {
        self.tick.* += 1;
        return if (self.tick.* < self.expire_at) 100 else 200;
    }
};

test "lease expiring during persistence is retried without ACK or start" {
    var tick: u32 = 0;
    var f: Fixture = .{};
    try std.testing.expectEqual(.deferred, try handle(std.testing.allocator, advertisement.test_payload, TickingClock{ .tick = &tick, .expire_at = 2 }, 1, &f, &f));
    try std.testing.expectEqualStrings("CPN", f.calls[0..f.len]);
}

test "lease expiring before confirmed ACK returns does not start a run" {
    var tick: u32 = 0;
    var f: Fixture = .{};
    try std.testing.expectError(error.LeaseExpiredBeforeStart, handle(std.testing.allocator, advertisement.test_payload, TickingClock{ .tick = &tick, .expire_at = 3 }, 1, &f, &f));
    try std.testing.expectEqualStrings("CPA", f.calls[0..f.len]);
}
