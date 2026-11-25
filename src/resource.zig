const std = @import("std");

pub const HardCaps = struct {
    memory_bytes: u64 = 512 << 20,
    swap_bytes: u64 = 0,
    pids: u32 = 128,
    cpu_quota_micros: u64 = 200_000,
    wall_ms: u64 = 300_000,
    output_bytes: u64 = 512 << 20,
};

pub const Request = struct {
    memory_bytes: u64 = 128 << 20,
    swap_bytes: u64 = 0,
    pids: u32 = 64,
    cpu_quota_micros: u64 = 100_000,
    wall_ms: u64 = 300_000,
    output_bytes: u64 = 512 << 20,
};

pub const Policy = struct {
    memory_bytes: u64,
    swap_bytes: u64,
    pids: u32,
    cpu_quota_micros: u64,
    wall_ms: u64,
    output_bytes: u64,

    pub fn resolve(request: Request, hard: HardCaps) error{InvalidResourceRequest}!Policy {
        if (request.memory_bytes == 0 or request.pids == 0 or request.cpu_quota_micros == 0 or request.wall_ms == 0 or request.output_bytes == 0) return error.InvalidResourceRequest;
        if (request.memory_bytes > hard.memory_bytes or request.swap_bytes > hard.swap_bytes or request.pids > hard.pids or request.cpu_quota_micros > hard.cpu_quota_micros or request.wall_ms > hard.wall_ms or request.output_bytes > hard.output_bytes) return error.InvalidResourceRequest;
        if (request.memory_bytes > std.math.maxInt(i64) or request.swap_bytes > std.math.maxInt(i64) - request.memory_bytes or request.cpu_quota_micros > std.math.maxInt(i64)) return error.InvalidResourceRequest;
        return .{
            .memory_bytes = request.memory_bytes,
            .swap_bytes = request.swap_bytes,
            .pids = request.pids,
            .cpu_quota_micros = request.cpu_quota_micros,
            .wall_ms = request.wall_ms,
            .output_bytes = request.output_bytes,
        };
    }
};

pub const Watchdog = struct {
    deadline_ns: i128,

    pub fn start(now_ns: i128, wall_ms: u64) error{InvalidResourceRequest}!Watchdog {
        if (wall_ms == 0) return error.InvalidResourceRequest;
        return .{ .deadline_ns = std.math.add(i128, now_ns, @as(i128, @intCast(wall_ms)) * std.time.ns_per_ms) catch return error.InvalidResourceRequest };
    }

    pub fn expired(self: Watchdog, now_ns: i128) bool {
        return now_ns >= self.deadline_ns;
    }

    pub fn remainingMs(self: Watchdog, now_ns: i128) u64 {
        if (self.expired(now_ns)) return 0;
        return @intCast(@min(std.math.maxInt(u64), @divFloor(self.deadline_ns -| now_ns, std.time.ns_per_ms)));
    }
};

pub const CpuStat = struct { usage_usec: u64, user_usec: u64, system_usec: u64 };

pub fn parseCpuStat(input: []const u8) error{InvalidCgroupStat}!CpuStat {
    var result: CpuStat = .{ .usage_usec = 0, .user_usec = 0, .system_usec = 0 };
    var usage = false;
    var user = false;
    var system = false;
    var lines = std.mem.tokenizeScalar(u8, input, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const key = fields.next() orelse continue;
        const value = fields.next() orelse return error.InvalidCgroupStat;
        if (fields.next() != null) return error.InvalidCgroupStat;
        const number = std.fmt.parseInt(u64, value, 10) catch return error.InvalidCgroupStat;
        if (std.mem.eql(u8, key, "usage_usec")) {
            if (usage) return error.InvalidCgroupStat;
            result.usage_usec = number;
            usage = true;
        } else if (std.mem.eql(u8, key, "user_usec")) {
            if (user) return error.InvalidCgroupStat;
            result.user_usec = number;
            user = true;
        } else if (std.mem.eql(u8, key, "system_usec")) {
            if (system) return error.InvalidCgroupStat;
            result.system_usec = number;
            system = true;
        }
    }
    if (!usage or !user or !system) return error.InvalidCgroupStat;
    return result;
}

pub const MemoryEvents = struct { low: u64, high: u64, max: u64, oom: u64, oom_kill: u64 };

pub fn parseMemoryEvents(input: []const u8) error{InvalidCgroupStat}!MemoryEvents {
    var result: MemoryEvents = .{ .low = 0, .high = 0, .max = 0, .oom = 0, .oom_kill = 0 };
    var seen: u8 = 0;
    var lines = std.mem.tokenizeScalar(u8, input, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const key = fields.next() orelse continue;
        const value = fields.next() orelse return error.InvalidCgroupStat;
        if (fields.next() != null) return error.InvalidCgroupStat;
        const number = std.fmt.parseInt(u64, value, 10) catch return error.InvalidCgroupStat;
        const index: u3 = if (std.mem.eql(u8, key, "low")) 0 else if (std.mem.eql(u8, key, "high")) 1 else if (std.mem.eql(u8, key, "max")) 2 else if (std.mem.eql(u8, key, "oom")) 3 else if (std.mem.eql(u8, key, "oom_kill")) 4 else continue;
        const mask = @as(u8, 1) << index;
        if (seen & mask != 0) return error.InvalidCgroupStat;
        seen |= mask;
        switch (index) {
            0 => result.low = number,
            1 => result.high = number,
            2 => result.max = number,
            3 => result.oom = number,
            4 => result.oom_kill = number,
            else => unreachable,
        }
    }
    if (seen != 0b11111) return error.InvalidCgroupStat;
    return result;
}

pub const Metrics = struct {
    cpu: CpuStat,
    events: MemoryEvents,
    memory_peak: u64,

    pub fn read(io: std.Io, dir: std.Io.Dir) !Metrics {
        var buffer: [4096]u8 = undefined;
        const cpu = try parseCpuStat(try readCounter(io, dir, "cpu.stat", &buffer));
        const events = try parseMemoryEvents(try readCounter(io, dir, "memory.events", &buffer));
        const peak = try readCounter(io, dir, "memory.peak", &buffer);
        return .{ .cpu = cpu, .events = events, .memory_peak = std.fmt.parseInt(u64, std.mem.trim(u8, peak, "\n"), 10) catch return error.InvalidCgroupStat };
    }

    fn readCounter(io: std.Io, dir: std.Io.Dir, name: []const u8, buffer: []u8) ![]const u8 {
        const file = try dir.openFile(io, name, .{ .follow_symlinks = false });
        defer file.close(io);
        const n = try file.readPositionalAll(io, buffer, 0);
        if (n == buffer.len) return error.InvalidCgroupStat;
        return buffer[0..n];
    }
};

pub const Exit = struct {
    code: i32,
    oom_killed: bool,
    timed_out: bool,
    output_limited: bool,
    cancelled: bool = false,

    pub fn reason(self: Exit) []const u8 {
        if (self.timed_out) return "wall_timeout";
        if (self.output_limited) return "output_limit";
        if (self.cancelled) return "cancelled";
        if (self.oom_killed) return "oom";
        return if (self.code == 0) "exited" else "nonzero_exit";
    }
};

pub const StopReason = enum { wall_timeout, output_limit, cancelled };

/// Run-scoped decision state. A single reason wins and cannot be overwritten
/// by a later peer/container event.
pub const Supervisor = struct {
    watchdog: Watchdog,
    output_limit: u64,
    output_bytes: u64 = 0,
    cancellation_requested: bool = false,
    stop_reason: ?StopReason = null,

    pub fn accountOutput(self: *Supervisor, count: usize, now_ns: i128) error{OutputLimit}!void {
        if (self.stop_reason != null) return error.OutputLimit;
        if (self.watchdog.expired(now_ns)) {
            self.stop_reason = .wall_timeout;
            return error.OutputLimit;
        }
        if (self.cancellation_requested) {
            self.stop_reason = .cancelled;
            return error.OutputLimit;
        }
        const remaining = self.output_limit -| self.output_bytes;
        const accepted: u64 = @intCast(@min(remaining, count));
        self.output_bytes += accepted;
        if (accepted != count) {
            self.stop_reason = .output_limit;
            return error.OutputLimit;
        }
    }

    pub fn requestCancel(self: *Supervisor) void {
        self.cancellation_requested = true;
        if (self.stop_reason == null) self.stop_reason = .cancelled;
    }

    pub fn exit(self: Supervisor, code: i32, oom_killed: bool) Exit {
        return .{
            .code = code,
            .oom_killed = oom_killed,
            .timed_out = self.stop_reason == .wall_timeout,
            .output_limited = self.stop_reason == .output_limit,
            .cancelled = self.stop_reason == .cancelled,
        };
    }
};

test "resource requests fail closed above hard caps" {
    const hard: HardCaps = .{};
    const request: Request = .{ .memory_bytes = 128 << 20, .pids = 64, .cpu_quota_micros = 100_000, .wall_ms = 30_000, .output_bytes = 1 << 20 };
    try std.testing.expectEqual(request.memory_bytes, (try Policy.resolve(request, hard)).memory_bytes);
    var excessive = request;
    excessive.memory_bytes = hard.memory_bytes + 1;
    try std.testing.expectError(error.InvalidResourceRequest, Policy.resolve(excessive, hard));
    excessive = request;
    excessive.swap_bytes = 1;
    try std.testing.expectError(error.InvalidResourceRequest, Policy.resolve(excessive, hard));
}

test "wall watchdog is monotonic and has a stable remaining budget" {
    const watchdog = try Watchdog.start(1_000_000, 20);
    try std.testing.expectEqual(@as(u64, 20), watchdog.remainingMs(1_000_000));
    try std.testing.expectEqual(@as(u64, 5), watchdog.remainingMs(16_000_000));
    try std.testing.expect(watchdog.expired(21_000_000));
}

test "cgroup v2 counters parse exact keys and reject duplicate metrics" {
    const cpu = try parseCpuStat("usage_usec 901\nuser_usec 700\nsystem_usec 201\nnr_periods 3\n");
    try std.testing.expectEqual(@as(u64, 901), cpu.usage_usec);
    const memory = try parseMemoryEvents("low 0\nhigh 2\nmax 4\noom 1\noom_kill 1\n");
    try std.testing.expectEqual(@as(u64, 1), memory.oom_kill);
    try std.testing.expectError(error.InvalidCgroupStat, parseCpuStat("usage_usec 1\nusage_usec 2\nuser_usec 1\nsystem_usec 0\n"));
    try std.testing.expectError(error.InvalidCgroupStat, parseMemoryEvents("oom_kill 1\n"));
}

test "exit reason prioritizes timeout and OOM over process exit code" {
    try std.testing.expectEqualStrings("wall_timeout", (Exit{ .code = 137, .oom_killed = true, .timed_out = true, .output_limited = false }).reason());
    try std.testing.expectEqualStrings("oom", (Exit{ .code = 137, .oom_killed = true, .timed_out = false, .output_limited = false }).reason());
}

test "run supervisor caps aggregate output and preserves first stop cause" {
    var supervisor: Supervisor = .{ .watchdog = try Watchdog.start(0, 100), .output_limit = 5 };
    try supervisor.accountOutput(3, 1);
    try std.testing.expectError(error.OutputLimit, supervisor.accountOutput(3, 2));
    supervisor.requestCancel();
    try std.testing.expectEqual(StopReason.output_limit, supervisor.stop_reason.?);
    try std.testing.expectEqualStrings("output_limit", supervisor.exit(137, false).reason());
}
