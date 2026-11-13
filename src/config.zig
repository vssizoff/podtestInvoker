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
    return cfg;
}
