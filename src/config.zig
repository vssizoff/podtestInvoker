const std = @import("std");
const log = @import("util/log.zig");
const fs = @import("util/fs.zig");
const http = @import("util/http.zig");
const gpa = @import("util/mem.zig").gpa;

pub const Config = struct {
    podman_socket: []const u8 = "/run/user/1000/podman/podman.sock",
    listen: []const u8 = "",
    token: []const u8 = "",
    work_root: []const u8 = "",
    state_file: []const u8 = "",
    run_timeout_ms: u64 = 300_000,
    stdio_history_limit: usize = 512 * 1024 * 1024,
    stop_grace_ms: u64 = 500,
    calibration_runs: u32 = 5,
    calibration_interval_ms: u64 = 3_600_000,
    grpc_max_message: usize = 64 * 1024 * 1024,
    event_chunk: usize = 1024 * 1024,
    max_concurrent_runs: u32 = 0,
    keep_run_dirs: bool = false,
    log_level: log.Level = .info,
    podman_api: []const u8 = "v4.0.0",

    pub fn initDefaults() !Config {
        return .{
            .podman_socket = try gpa.dupe(u8, "/run/user/1000/podman/podman.sock"),
            .listen = try gpa.dupe(u8, ""),
            .token = try gpa.dupe(u8, ""),
            .work_root = try gpa.dupe(u8, ""),
            .state_file = try gpa.dupe(u8, ""),
            .podman_api = try gpa.dupe(u8, "v4.0.0"),
        };
    }

    pub fn deinit(self: *Config) void {
        gpa.free(self.podman_socket);
        gpa.free(self.listen);
        gpa.free(self.token);
        gpa.free(self.work_root);
        gpa.free(self.state_file);
        gpa.free(self.podman_api);
        self.* = undefined;
    }

    pub fn validate(self: *const Config) !void {
        if (self.listen.len == 0) return error.MissingListenAddress;
        _ = http.parseTcpAddr(self.listen) catch return error.InvalidListenAddress;
        if (self.token.len == 0) return error.MissingToken;
        if (self.work_root.len == 0 or self.work_root[0] != '/') return error.InvalidWorkRoot;
        if (std.mem.eql(u8, self.work_root, "/")) return error.InvalidWorkRoot;
        if (self.state_file.len == 0 or self.state_file[0] != '/') return error.InvalidStateFile;
        if (self.run_timeout_ms == 0) return error.InvalidRunTimeout;
        if (self.stdio_history_limit < 1024) return error.InvalidHistoryLimit;
        if (self.grpc_max_message < 1024) return error.InvalidGrpcLimit;
        if (self.event_chunk == 0 or self.event_chunk > self.grpc_max_message) return error.InvalidChunkSize;
        if (self.calibration_runs == 0) return error.InvalidCalibration;
    }
};

fn getString(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = obj.get(name) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn getBool(obj: std.json.ObjectMap, name: []const u8) ?bool {
    const v = obj.get(name) orelse return null;
    return switch (v) {
        .bool => |b| b,
        .integer => |i| i != 0,
        else => null,
    };
}

fn getInt(obj: std.json.ObjectMap, name: []const u8) ?i64 {
    const v = obj.get(name) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

fn dupeOpt(obj: std.json.ObjectMap, name: []const u8, default: []const u8) ![]const u8 {
    if (getString(obj, name)) |s| return gpa.dupe(u8, s);
    return gpa.dupe(u8, default);
}

pub fn load(path: []const u8) !Config {
    const data = try fs.readFileAbsolute(path, 8 * 1024 * 1024);
    defer gpa.free(data);
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, data, .{}) catch return error.InvalidConfigJson;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidConfigJson;
    const obj = parsed.value.object;

    var cfg = try Config.initDefaults();
    errdefer cfg.deinit();

    gpa.free(cfg.podman_socket);
    cfg.podman_socket = try dupeOpt(obj, "podman_socket", "/run/user/1000/podman/podman.sock");
    gpa.free(cfg.listen);
    cfg.listen = try dupeOpt(obj, "listen", "");
    gpa.free(cfg.token);
    cfg.token = try dupeOpt(obj, "token", "");
    gpa.free(cfg.work_root);
    cfg.work_root = try dupeOpt(obj, "work_root", "");
    gpa.free(cfg.state_file);
    cfg.state_file = try dupeOpt(obj, "state_file", "");
    gpa.free(cfg.podman_api);
    cfg.podman_api = try dupeOpt(obj, "podman_api", "v4.0.0");

    if (getInt(obj, "run_timeout_sec")) |v| {
        if (v <= 0) return error.InvalidRunTimeout;
        cfg.run_timeout_ms = @as(u64, @intCast(v)) * 1000;
    }
    if (getInt(obj, "stdio_history_limit_bytes")) |v| {
        if (v <= 0) return error.InvalidHistoryLimit;
        cfg.stdio_history_limit = @intCast(v);
    }
    if (getInt(obj, "stop_grace_ms")) |v| {
        if (v < 0) return error.InvalidConfigJson;
        cfg.stop_grace_ms = @intCast(v);
    }
    if (getInt(obj, "calibration_runs")) |v| {
        if (v <= 0 or v > 1000) return error.InvalidCalibration;
        cfg.calibration_runs = @intCast(v);
    }
    if (getInt(obj, "calibration_interval_sec")) |v| {
        if (v < 0) return error.InvalidConfigJson;
        cfg.calibration_interval_ms = @as(u64, @intCast(v)) * 1000;
    }
    if (getInt(obj, "grpc_max_message_bytes")) |v| {
        if (v <= 0) return error.InvalidGrpcLimit;
        cfg.grpc_max_message = @intCast(v);
    }
    if (getInt(obj, "event_chunk_bytes")) |v| {
        if (v <= 0) return error.InvalidChunkSize;
        cfg.event_chunk = @intCast(v);
    }
    if (getInt(obj, "max_concurrent_runs")) |v| {
        if (v < 0) return error.InvalidConfigJson;
        cfg.max_concurrent_runs = @intCast(v);
    }
    if (getString(obj, "log_level")) |s| {
        cfg.log_level = log.Level.parse(s) orelse return error.InvalidLogLevel;
    }
    if (getBool(obj, "keep_run_dirs")) |b| cfg.keep_run_dirs = b;
    return cfg;
}

test "load reads every documented field and validate rejects bad values" {
    const linux = std.os.linux;
    const sys = @import("util/sys.zig");

    var dir_buf: [256]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "/tmp/opencode/podtest-config-{d}", .{linux.getpid()});
    try fs.makeDirAllAbsolute(dir);
    defer {
        var pb: [fs.max_path + 1]u8 = undefined;
        const parent = fs.dirName(dir);
        if (parent.len + 1 <= pb.len) {
            @memcpy(pb[0..parent.len], parent);
            pb[parent.len] = 0;
            if (sys.openat(linux.AT.FDCWD, pb[0..parent.len :0], .{
                .ACCMODE = .RDONLY,
                .DIRECTORY = true,
                .CLOEXEC = true,
            }, 0)) |pfd| {
                fs.removeTreeBeneath(pfd, fs.baseName(dir)) catch {};
                sys.close(pfd);
            } else |_| {}
        }
    }

    const good =
        \\{
        \\  "podman_socket": "/run/user/1000/podman/podman.sock",
        \\  "listen": "127.0.0.1:50051",
        \\  "token": "secret",
        \\  "work_root": "/var/lib/invoker/runs",
        \\  "state_file": "/var/lib/invoker/state.json",
        \\  "podman_api": "v4.0.0",
        \\  "run_timeout_sec": 42,
        \\  "stdio_history_limit_bytes": 4096,
        \\  "stop_grace_ms": 250,
        \\  "calibration_runs": 3,
        \\  "calibration_interval_sec": 60,
        \\  "grpc_max_message_bytes": 2097152,
        \\  "event_chunk_bytes": 1024,
        \\  "max_concurrent_runs": 7,
        \\  "keep_run_dirs": true,
        \\  "log_level": "debug"
        \\}
    ;
    const good_path = try std.fmt.allocPrint(gpa, "{s}/good.json", .{dir});
    defer gpa.free(good_path);
    try fs.writeFileAbsolute(good_path, good);

    var cfg = try load(good_path);
    defer cfg.deinit();
    try std.testing.expectEqualStrings("127.0.0.1:50051", cfg.listen);
    try std.testing.expectEqualStrings("secret", cfg.token);
    try std.testing.expectEqualStrings("/var/lib/invoker/runs", cfg.work_root);
    try std.testing.expectEqual(@as(u64, 42_000), cfg.run_timeout_ms);
    try std.testing.expectEqual(@as(usize, 4096), cfg.stdio_history_limit);
    try std.testing.expectEqual(@as(u64, 250), cfg.stop_grace_ms);
    try std.testing.expectEqual(@as(u32, 3), cfg.calibration_runs);
    try std.testing.expectEqual(@as(u64, 60_000), cfg.calibration_interval_ms);
    try std.testing.expectEqual(@as(usize, 2 * 1024 * 1024), cfg.grpc_max_message);
    try std.testing.expectEqual(@as(usize, 1024), cfg.event_chunk);
    try std.testing.expectEqual(@as(u32, 7), cfg.max_concurrent_runs);
    try std.testing.expect(cfg.keep_run_dirs);
    try std.testing.expectEqual(log.Level.debug, cfg.log_level);
    try cfg.validate();

    // Defaults are used for fields that are absent from the file.
    const minimal_path = try std.fmt.allocPrint(gpa, "{s}/minimal.json", .{dir});
    defer gpa.free(minimal_path);
    try fs.writeFileAbsolute(minimal_path,
        \\{ "listen": "0.0.0.0:1", "token": "t", "work_root": "/w", "state_file": "/s" }
    );
    var min_cfg = try load(minimal_path);
    defer min_cfg.deinit();
    try std.testing.expectEqual(@as(u64, 300_000), min_cfg.run_timeout_ms);
    try std.testing.expectEqual(@as(usize, 512 * 1024 * 1024), min_cfg.stdio_history_limit);
    try std.testing.expectEqual(@as(usize, 1024 * 1024), min_cfg.event_chunk);
    try std.testing.expectEqual(@as(u32, 0), min_cfg.max_concurrent_runs);
    try std.testing.expect(!min_cfg.keep_run_dirs);
    try std.testing.expectEqualStrings("v4.0.0", min_cfg.podman_api);
    try min_cfg.validate();

    // An event chunk larger than the message limit is rejected by validate.
    const bad_path = try std.fmt.allocPrint(gpa, "{s}/bad.json", .{dir});
    defer gpa.free(bad_path);
    try fs.writeFileAbsolute(bad_path,
        \\{ "listen": "0.0.0.0:1", "token": "t", "work_root": "/w", "state_file": "/s",
        \\  "grpc_max_message_bytes": 1024, "event_chunk_bytes": 4096 }
    );
    var bad_cfg = try load(bad_path);
    defer bad_cfg.deinit();
    try std.testing.expectError(error.InvalidChunkSize, bad_cfg.validate());

    const missing_path = try std.fmt.allocPrint(gpa, "{s}/missing.json", .{dir});
    defer gpa.free(missing_path);
    try std.testing.expectError(error.NotFound, load(missing_path));
}
