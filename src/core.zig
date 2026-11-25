const std = @import("std");

pub const Config = struct {
    invoker_id: []const u8,
    state_dir: []const u8,
    podman_socket: []const u8,
    max_active_runs: u32 = 1,
    run_timeout_seconds: u32 = 300,
    stop_grace_ms: u32 = 500,
    stdio_limit_bytes: u64 = 512 * 1024 * 1024,
    libpod_api_version: []const u8 = "6.2.0",

    pub fn validate(self: Config) ConfigError!void {
        if (self.invoker_id.len == 0 or self.invoker_id.len > 128) return error.InvalidInvokerId;
        for (self.invoker_id) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.') return error.InvalidInvokerId;
        }
        if (!std.fs.path.isAbsolute(self.state_dir) or std.mem.indexOfScalar(u8, self.state_dir, 0) != null) return error.StateDirMustBeAbsolute;
        if (!std.fs.path.isAbsolute(self.podman_socket) or self.podman_socket.len > 107 or std.mem.indexOfScalar(u8, self.podman_socket, 0) != null) return error.InvalidPodmanSocket;
        if (self.max_active_runs == 0 or self.max_active_runs > 4096) return error.InvalidCapacity;
        if (self.run_timeout_seconds == 0 or self.run_timeout_seconds > 86400) return error.InvalidRunTimeout;
        if (self.stop_grace_ms == 0 or self.stop_grace_ms > 30000 or self.stdio_limit_bytes == 0 or self.stdio_limit_bytes > 512 * 1024 * 1024) return error.InvalidResourceLimit;
        const api = std.SemanticVersion.parse(self.libpod_api_version) catch return error.InvalidLibpodVersion;
        if (api.pre != null or api.build != null) return error.InvalidLibpodVersion;
    }
};

pub const ConfigError = error{
    InvalidInvokerId,
    StateDirMustBeAbsolute,
    InvalidPodmanSocket,
    InvalidCapacity,
    InvalidRunTimeout,
    InvalidResourceLimit,
    InvalidLibpodVersion,
};

pub const ProcessIdentity = struct {
    invoker_id: []const u8,
    process_epoch: [36]u8,

    pub fn init(invoker_id: []const u8, random: [16]u8) ProcessIdentity {
        var bytes = random;
        bytes[6] = (bytes[6] & 0x0f) | 0x40;
        bytes[8] = (bytes[8] & 0x3f) | 0x80;
        var epoch: [36]u8 = undefined;
        const hex = "0123456789abcdef";
        var output_index: usize = 0;
        for (bytes, 0..) |byte, index| {
            if (index == 4 or index == 6 or index == 8 or index == 10) {
                epoch[output_index] = '-';
                output_index += 1;
            }
            epoch[output_index] = hex[byte >> 4];
            epoch[output_index + 1] = hex[byte & 0x0f];
            output_index += 2;
        }
        return .{ .invoker_id = invoker_id, .process_epoch = epoch };
    }
};

pub const Phase = enum {
    received,
    claimed,
    downloading,
    preparing_workspace,
    starting_executor,
    running,
    finalizing_artifacts,
    reporting_terminal,
    cleanup,
    finished,
    cancelling,
    cancelled,
    timed_out,
    failed,

    pub fn canTransition(from: Phase, to: Phase) bool {
        if (to == .failed or to == .cancelling or to == .timed_out) {
            return from != .finished and from != .cancelled and from != .failed and from != .timed_out;
        }
        return switch (from) {
            .received => to == .claimed,
            .claimed => to == .downloading,
            .downloading => to == .preparing_workspace,
            .preparing_workspace => to == .starting_executor,
            .starting_executor => to == .running,
            .running => to == .finalizing_artifacts,
            .finalizing_artifacts => to == .reporting_terminal,
            .reporting_terminal => to == .cleanup,
            .cleanup => to == .finished or to == .cancelled,
            .cancelling => to == .cleanup,
            .finished, .cancelled, .timed_out, .failed => false,
        };
    }
};

test "config rejects unsafe and zero-valued settings" {
    const good = Config{ .invoker_id = "node-1", .state_dir = "/var/lib/podtest", .podman_socket = "/run/user/1000/podman/podman.sock", .max_active_runs = 4, .run_timeout_seconds = 300 };
    try good.validate();
    var bad = good;
    bad.state_dir = "relative";
    try std.testing.expectError(error.StateDirMustBeAbsolute, bad.validate());
    bad = good;
    bad.max_active_runs = 0;
    try std.testing.expectError(error.InvalidCapacity, bad.validate());
}

test "process epoch is UUID-shaped and process-specific" {
    const one = ProcessIdentity.init("node-1", @splat(0));
    const two = ProcessIdentity.init("node-1", @splat(1));
    try std.testing.expectEqual(@as(usize, 36), one.process_epoch.len);
    try std.testing.expectEqualStrings("00000000-0000-4000-8000-000000000000", &one.process_epoch);
    try std.testing.expect(std.mem.indexOfScalar(u8, &one.process_epoch, '-') != null);
    try std.testing.expect(!std.mem.eql(u8, &one.process_epoch, &two.process_epoch));
}

test "run lifecycle rejects skipped and terminal transitions" {
    try std.testing.expect(Phase.received.canTransition(.claimed));
    try std.testing.expect(!Phase.received.canTransition(.running));
    try std.testing.expect(Phase.running.canTransition(.cancelling));
    try std.testing.expect(!Phase.finished.canTransition(.failed));
}
