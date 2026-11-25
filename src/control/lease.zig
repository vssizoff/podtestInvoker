const std = @import("std");

pub const Identity = struct {
    invoker_id: []const u8,
    process_epoch: []const u8,
    attempt_id: []const u8,
    run_id: []const u8,
    token: []const u8,

    fn matches(a: Identity, b: Identity) bool {
        return std.mem.eql(u8, a.invoker_id, b.invoker_id) and
            std.mem.eql(u8, a.process_epoch, b.process_epoch) and
            std.mem.eql(u8, a.attempt_id, b.attempt_id) and
            std.mem.eql(u8, a.run_id, b.run_id) and
            std.mem.eql(u8, a.token, b.token);
    }
};

pub const Time = struct { unix_seconds: i64, monotonic_ns: i128 };

/// Local authority for a single run. Drive serially; the caller owns the identity
/// strings and must stop the supervisor as soon as this guard becomes inactive.
pub const Guard = struct {
    identity: Identity,
    expires_unix: i64,
    deadline_ns: i128,
    state: enum { active, expired, cancelled, fenced } = .active,

    pub fn init(identity: Identity, expires_unix: i64, now: Time) !Guard {
        if (identity.invoker_id.len == 0 or identity.process_epoch.len == 0 or identity.attempt_id.len == 0 or
            identity.run_id.len == 0 or identity.token.len == 0) return error.InvalidIdentity;
        return .{ .identity = identity, .expires_unix = expires_unix, .deadline_ns = try deadline(expires_unix, now) };
    }

    pub fn active(self: *Guard, now: Time) bool {
        if (self.state != .active) return false;
        if (now.monotonic_ns >= self.deadline_ns or now.unix_seconds >= self.expires_unix) {
            self.state = .expired;
            return false;
        }
        return true;
    }

    /// Apply only a correlated renewal response. A delayed response cannot
    /// revive a stopped run or overwrite a newer expiration.
    pub fn renew(self: *Guard, identity: Identity, expires_unix: i64, now: Time) !void {
        if (!self.active(now)) return error.LeaseInactive;
        if (!self.identity.matches(identity)) return error.LeaseIdentityMismatch;
        if (expires_unix <= self.expires_unix) return error.NonAdvancingRenewal;
        const next = try deadline(expires_unix, now);
        const extension = (@as(i128, expires_unix) - self.expires_unix) * std.time.ns_per_s;
        const monotonic_limit = std.math.add(i128, self.deadline_ns, extension) catch return error.InvalidDeadline;
        self.expires_unix = expires_unix;
        self.deadline_ns = @min(next, monotonic_limit);
    }

    /// False means the command was stale or the run already stopped.
    pub fn cancel(self: *Guard, identity: Identity, now: Time) bool {
        if (!self.active(now) or !self.identity.matches(identity)) return false;
        self.state = .cancelled;
        return true;
    }

    /// Call only for an authoritative rejection of the matching lease.
    pub fn fence(self: *Guard, identity: Identity, now: Time) bool {
        if (!self.active(now) or !self.identity.matches(identity)) return false;
        self.state = .fenced;
        return true;
    }
};

fn deadline(expires_unix: i64, now: Time) !i128 {
    const seconds = @as(i128, expires_unix) - now.unix_seconds;
    if (seconds <= 1) return error.LeaseExpired;
    // Unix timestamps are whole seconds. Deduct one second so conversion
    // never adds the discarded fraction to a monotonic lease lifetime.
    return std.math.add(i128, now.monotonic_ns, (seconds - 1) * std.time.ns_per_s) catch error.InvalidDeadline;
}

const id: Identity = .{ .invoker_id = "node", .process_epoch = "epoch", .attempt_id = "attempt", .run_id = "run", .token = "token" };

test "renewal extends a live lease but cannot resurrect it after clock rollback" {
    const ns = std.time.ns_per_s;
    var guard = try Guard.init(id, 110, .{ .unix_seconds = 100, .monotonic_ns = 0 });
    try guard.renew(id, 120, .{ .unix_seconds = 104, .monotonic_ns = 4 * ns });
    try std.testing.expectError(error.NonAdvancingRenewal, guard.renew(id, 119, .{ .unix_seconds = 105, .monotonic_ns = 5 * ns }));
    try std.testing.expect(guard.active(.{ .unix_seconds = 95, .monotonic_ns = 18 * ns }));
    try std.testing.expectError(error.LeaseInactive, guard.renew(id, 130, .{ .unix_seconds = 96, .monotonic_ns = 19 * ns }));
    try std.testing.expectEqual(.expired, guard.state);
}

test "renewal during wall clock rollback cannot inflate the extension" {
    const ns = std.time.ns_per_s;
    var guard = try Guard.init(id, 110, .{ .unix_seconds = 100, .monotonic_ns = 0 });
    try guard.renew(id, 115, .{ .unix_seconds = 90, .monotonic_ns = 3 * ns });
    try std.testing.expectEqual(@as(i128, 14 * ns), guard.deadline_ns);
    try std.testing.expect(!guard.active(.{ .unix_seconds = 91, .monotonic_ns = 14 * ns }));
}

test "stale commands are ignored and authenticated cancellation and fencing are terminal" {
    const now: Time = .{ .unix_seconds = 100, .monotonic_ns = 0 };
    var other = id;
    other.process_epoch = "old";
    var guard = try Guard.init(id, 110, now);
    try std.testing.expect(!guard.cancel(other, now));
    try std.testing.expectError(error.LeaseIdentityMismatch, guard.renew(other, 120, now));
    other = id;
    other.token = "old";
    try std.testing.expect(!guard.fence(other, now));
    try std.testing.expect(guard.cancel(id, now));
    try std.testing.expectError(error.LeaseInactive, guard.renew(id, 120, now));
    try std.testing.expectEqual(.cancelled, guard.state);
    guard = try Guard.init(id, 110, now);
    try std.testing.expect(guard.fence(id, now));
    try std.testing.expect(!guard.active(now));
    try std.testing.expectEqual(.fenced, guard.state);
}
