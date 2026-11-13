const std = @import("std");
const configmod = @import("config.zig");
const state = @import("state.zig");
const podman = @import("podman/client.zig");
const cleanup = @import("cleanup.zig");
const calibration = @import("calibration.zig");
const manager = @import("run/manager.zig");
const grpc = @import("grpc/server.zig");
const fs = @import("util/fs.zig");
const log = @import("util/log.zig");
const gpa = @import("util/mem.zig").gpa;

var g_server: ?*grpc.Server = null;

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    if (g_server) |s| s.signalStop();
}

const Options = struct {
    config_path: ?[]const u8 = null,
    listen: ?[]const u8 = null,
    token: ?[]const u8 = null,
    work_root: ?[]const u8 = null,
    state_file: ?[]const u8 = null,
    podman_socket: ?[]const u8 = null,
    podman_api: ?[]const u8 = null,
    log_level: ?[]const u8 = null,
    run_timeout_sec: ?u64 = null,
    history_limit: ?u64 = null,
    max_concurrent: ?u32 = null,
    keep_run_dirs: bool = false,
    no_calibration: bool = false,
    help: bool = false,
};

fn usage() void {
    const text =
        \\podtest-invoker - rootless Podman + Lua test invoker
        \\
        \\Usage: podtest-invoker [options]
        \\
        \\  --config PATH              JSON configuration file
        \\  --listen HOST:PORT         gRPC listen address (default 127.0.0.1:50051)
        \\  --token TOKEN              bearer token required from clients
        \\  --work-root PATH           directory for per-run directories
        \\  --state-file PATH          stable instance-id file
        \\  --podman-socket PATH       rootless Podman API unix socket
        \\  --podman-api PREFIX        Podman API version prefix (default v4.0.0)
        \\  --log-level LEVEL          debug|info|warn|error
        \\  --run-timeout-sec N        default run timeout (default 300)
        \\  --history-limit BYTES      per-stream stdio history limit (default 512MiB)
        \\  --max-concurrent N         limit concurrent runs (0 = unlimited)
        \\  --keep-run-dirs            keep <work_root>/<run_id> after a run ends
        \\  --no-calibration           skip the CPU benchmark at startup
        \\  --help                     show this help
        \\
        \\Environment: PODTEST_INVOKER_TOKEN, PODTEST_INVOKER_LISTEN, XDG_DATA_HOME, XDG_RUNTIME_DIR
        \\
    ;
    std.debug.print("{s}", .{text});
}

fn argValue(args: []const [*:0]const u8, i: *usize) ![]const u8 {
    if (i.* + 1 >= args.len) return error.MissingArgumentValue;
    i.* += 1;
    return std.mem.sliceTo(args[i.*], 0);
}

fn parseArgs(args: []const [*:0]const u8) !Options {
    var o = Options{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = std.mem.sliceTo(args[i], 0);
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            o.help = true;
        } else if (std.mem.eql(u8, a, "--config")) {
            o.config_path = try argValue(args, &i);
        } else if (std.mem.eql(u8, a, "--listen")) {
            o.listen = try argValue(args, &i);
        } else if (std.mem.eql(u8, a, "--token")) {
            o.token = try argValue(args, &i);
        } else if (std.mem.eql(u8, a, "--work-root")) {
            o.work_root = try argValue(args, &i);
        } else if (std.mem.eql(u8, a, "--state-file")) {
            o.state_file = try argValue(args, &i);
        } else if (std.mem.eql(u8, a, "--podman-socket")) {
            o.podman_socket = try argValue(args, &i);
        } else if (std.mem.eql(u8, a, "--podman-api")) {
            o.podman_api = try argValue(args, &i);
        } else if (std.mem.eql(u8, a, "--log-level")) {
            o.log_level = try argValue(args, &i);
        } else if (std.mem.eql(u8, a, "--run-timeout-sec")) {
            o.run_timeout_sec = try std.fmt.parseInt(u64, try argValue(args, &i), 10);
        } else if (std.mem.eql(u8, a, "--history-limit")) {
            o.history_limit = try std.fmt.parseInt(u64, try argValue(args, &i), 10);
        } else if (std.mem.eql(u8, a, "--max-concurrent")) {
            o.max_concurrent = try std.fmt.parseInt(u32, try argValue(args, &i), 10);
        } else if (std.mem.eql(u8, a, "--keep-run-dirs")) {
            o.keep_run_dirs = true;
        } else if (std.mem.eql(u8, a, "--no-calibration")) {
            o.no_calibration = true;
        } else {
            log.err("unknown option: {s}", .{a});
            return error.UnknownOption;
        }
    }
    return o;
}

fn setString(field: *[]const u8, value: []const u8) !void {
    const copy = try gpa.dupe(u8, value);
    gpa.free(field.*);
    field.* = copy;
}

fn env(name: [*:0]const u8) ?[]const u8 {
    const p = std.c.getenv(name) orelse return null;
    return std.mem.sliceTo(p, 0);
}

fn defaultDataDir() ?[]const u8 {
    if (env("XDG_DATA_HOME")) |x| {
        if (x.len > 0) {
            return std.fmt.allocPrint(gpa, "{s}/podtest-invoker", .{x}) catch null;
        }
    }
    if (env("HOME")) |h| {
        if (h.len > 0) {
            return std.fmt.allocPrint(gpa, "{s}/.local/share/podtest-invoker", .{h}) catch null;
        }
    }
    return gpa.dupe(u8, "/tmp/podtest-invoker") catch null;
}

fn defaultPodmanSocket() []u8 {
    if (env("XDG_RUNTIME_DIR")) |x| {
        if (x.len > 0) return std.fmt.allocPrint(gpa, "{s}/podman/podman.sock", .{x}) catch @panic("out of memory");
    }
    const uid = std.os.linux.getuid();
    return std.fmt.allocPrint(gpa, "/run/user/{d}/podman/podman.sock", .{uid}) catch @panic("out of memory");
}

pub fn main(init: std.process.Init.Minimal) !void {
    const args = init.args.vector;
    const opts = parseArgs(args) catch |e| {
        usage();
        return e;
    };
    if (opts.help) {
        usage();
        return;
    }

    var cfg = if (opts.config_path) |p| try configmod.load(p) else try configmod.Config.initDefaults();
    defer cfg.deinit();

    if (opts.config_path == null) {
        const sock = defaultPodmanSocket();
        defer gpa.free(sock);
        try setString(&cfg.podman_socket, sock);
    }
    if (opts.listen) |v| try setString(&cfg.listen, v);
    if (opts.token) |v| try setString(&cfg.token, v);
    if (opts.work_root) |v| try setString(&cfg.work_root, v);
    if (opts.state_file) |v| try setString(&cfg.state_file, v);
    if (opts.podman_socket) |v| try setString(&cfg.podman_socket, v);
    if (opts.podman_api) |v| try setString(&cfg.podman_api, v);
    if (opts.log_level) |v| cfg.log_level = log.Level.parse(v) orelse return error.InvalidLogLevel;
    if (opts.run_timeout_sec) |v| {
        if (v == 0) return error.InvalidRunTimeout;
        cfg.run_timeout_ms = v * 1000;
    }
    if (opts.history_limit) |v| {
        if (v < 1024) return error.InvalidHistoryLimit;
        cfg.stdio_history_limit = @intCast(v);
    }
    if (opts.max_concurrent) |v| cfg.max_concurrent_runs = v;
    if (opts.keep_run_dirs) cfg.keep_run_dirs = true;

    log.setLevel(cfg.log_level);
    if (cfg.keep_run_dirs) log.info("run directories are kept after completion", .{});

    const data_dir = defaultDataDir() orelse return error.OutOfMemory;
    defer gpa.free(data_dir);
    if (cfg.listen.len == 0) {
        if (env("PODTEST_INVOKER_LISTEN")) |v| try setString(&cfg.listen, v) else try setString(&cfg.listen, "127.0.0.1:50051");
    }
    if (cfg.token.len == 0) {
        if (env("PODTEST_INVOKER_TOKEN")) |v| try setString(&cfg.token, v);
    }
    if (cfg.work_root.len == 0) {
        const p = try std.fmt.allocPrint(gpa, "{s}/runs", .{data_dir});
        defer gpa.free(p);
        try setString(&cfg.work_root, p);
    }
    if (cfg.state_file.len == 0) {
        const p = try std.fmt.allocPrint(gpa, "{s}/state.json", .{data_dir});
        defer gpa.free(p);
        try setString(&cfg.state_file, p);
    }
    try cfg.validate();

    try fs.makeDirAllAbsolute(cfg.work_root);
    if (std.mem.lastIndexOfScalar(u8, cfg.state_file, '/')) |idx| {
        if (idx > 0) try fs.makeDirAllAbsolute(cfg.state_file[0..idx]);
    }

    var st = try state.loadOrCreate(cfg.state_file);
    defer st.deinit();

    var client = podman.Client.init(cfg.podman_socket, cfg.podman_api, st.instance_id);
    client.ping() catch |e| {
        log.err("Podman API is not reachable at {s}: {s}", .{ cfg.podman_socket, @errorName(e) });
        return error.PodmanUnavailable;
    };

    log.info("instance {s}", .{st.instance_id});
    log.info("work root {s}", .{cfg.work_root});
    _ = cleanup.cleanupAll(&client, cfg.work_root);

    const cal = try calibration.Calibration.init(&cfg, &client, st.instance_id);
    defer cal.deinit();
    if (opts.no_calibration) {
        log.info("calibration disabled; CPU factor 1.0", .{});
    } else {
        cal.calibrate();
        cal.startBackground() catch |e| log.warn("cannot start background calibration: {s}", .{@errorName(e)});
    }

    const mgr = try manager.Manager.init(&cfg, &client, st.instance_id, @ptrCast(cal), factorFromCalibration);
    defer mgr.deinit();

    const server = try grpc.Server.init(&cfg, mgr, st.instance_id, cfg.token);
    defer server.deinit();
    g_server = server;

    var act = std.posix.Sigaction{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);

    server.run() catch |e| {
        log.err("gRPC server failed: {s}", .{@errorName(e)});
        return e;
    };
    log.info("shutting down", .{});
    server.stop();
}

fn factorFromCalibration(ctx: *anyopaque) f64 {
    const cal: *calibration.Calibration = @ptrCast(@alignCast(ctx));
    return cal.factor();
}
