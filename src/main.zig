const std = @import("std");

test {
    if (@import("build_options").artifact_control) _ = @import("standard/report.zig");
}
const core = @import("core.zig");
const linux = std.os.linux;
const janitor = @import("janitor");

extern fn podtest_lock(path: [*:0]const u8) c_int;
extern fn podtest_ping(path: [*:0]const u8, version: [*:0]const u8) c_int;

pub fn main(init: std.process.Init) u8 {
    run(init) catch |err| {
        log(init.io, .{ .subsystem = "process", .operation = "command_failed", .error_code = @errorName(err) }) catch return 1;
        return if (err == error.InvalidArguments) 2 else 1;
    };
    return 0;
}

fn run(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) {
        return log(init.io, .{ .version = "0.1.0", .zig = @import("builtin").zig_version_string });
    }
    if (args.len < 3) return error.InvalidArguments;
    const check = std.mem.eql(u8, args[1], "check");
    const serve = std.mem.eql(u8, args[1], "serve-diagnostics");
    const artifacts = std.mem.eql(u8, args[1], "serve-artifacts");
    const prepare = std.mem.eql(u8, args[1], "prepare-assigned");
    const stage = std.mem.eql(u8, args[1], "stage-artifact");
    const fixture = std.mem.eql(u8, args[1], "test-claim-delivery");
    const standard_once = std.mem.eql(u8, args[1], "work-standard-once");
    const standard = standard_once or std.mem.eql(u8, args[1], "serve-standard");
    const sweep = std.mem.eql(u8, args[1], "sweep-resources") or std.mem.eql(u8, args[1], "sweep-containers");
    const calibrate = std.mem.eql(u8, args[1], "calibrate-cpu");
    if (!check and !serve and !artifacts and !prepare and !stage and !fixture and !standard and !sweep and !calibrate) return error.InvalidArguments;
    if (args.len != @as(usize, if (fixture or stage) 7 else if (prepare or calibrate) 4 else 3)) return error.InvalidArguments;

    const config = try loadConfig(init, args[2]);
    const a = init.arena.allocator();
    const fd = podtest_lock(try a.dupeSentinel(u8, config.state_dir, 0));
    if (fd == -2) return error.InstanceAlreadyRunning;
    if (fd < 0) return error.UnsafeOrUnavailableStateDirectory;
    defer _ = linux.close(fd);

    if (calibrate) {
        if (@import("builtin").mode != .safe) return error.CalibrationRequiresReleaseSafe;
        const reference = std.fmt.parseInt(u64, args[3], 10) catch return error.InvalidCalibrationReference;
        return log(init.io, try @import("calibration.zig").measure(init.io, reference));
    }

    if (fixture) {
        if (comptime !@import("build_options").claim_fixture) return error.ClaimFixtureNotBuilt;
        return @import("claim_fixture.zig").run(init, config, args[3..7]);
    }

    if (artifacts or prepare or stage) {
        if (comptime !@import("build_options").artifact_control) return error.ArtifactControlNotBuilt;
        return runArtifacts(init, config, args[3..]);
    }

    const signal_fd = if (serve or standard) try shutdownFd() else -1;
    defer if (signal_fd >= 0) {
        _ = linux.close(signal_fd);
    };
    const timestamp = std.Io.Clock.awake.now(init.io);
    switch (podtest_ping(try a.dupeSentinel(u8, config.podman_socket, 0), try a.dupeSentinel(u8, config.libpod_api_version, 0))) {
        0 => {},
        2 => return error.PodmanProbeTimedOut,
        3 => return error.InvalidPodmanPing,
        4 => return error.LibpodVersionMismatch,
        else => return error.PodmanProbeFailed,
    }
    const duration = timestamp.durationTo(std.Io.Clock.awake.now(init.io));
    var random: [16]u8 = undefined;
    try std.Io.randomSecure(init.io, &random);
    const identity = core.ProcessIdentity.init(config.invoker_id, random);
    const journal: janitor.Journal = .{ .io = init.io, .state = .{ .handle = fd }, .invoker_id = identity.invoker_id, .epoch = &identity.process_epoch };
    const client: @import("podman").Client = .{ .socket = try a.dupeSentinel(u8, config.podman_socket, 0), .api_version = try a.dupeSentinel(u8, config.libpod_api_version, 0) };
    if (standard) {
        if (comptime !@import("build_options").standard_worker) return error.StandardWorkerNotBuilt;
        try sweepContainers(init, journal, client, true, signal_fd);
        return @import("standard_worker.zig").run(init, config, journal, client, signal_fd, standard_once);
    }
    if (sweep or serve) {
        try sweepContainers(init, journal, client, sweep, if (serve) signal_fd else null);
        if (sweep) return;
    }
    try log(init.io, .{
        .subsystem = "process",
        .operation = if (serve) "diagnostics_started" else "host_check_passed",
        .invoker_id = identity.invoker_id,
        .process_epoch = identity.process_epoch[0..],
        .libpod_api_version = config.libpod_api_version,
        .duration_ms = duration.toMilliseconds(),
        .execution_ready = false,
        .active_slots = 0,
        .free_slots = 0,
        .configured_slots = config.max_active_runs,
    });
    if (serve) {
        var info: linux.signalfd_siginfo = undefined;
        while (true) {
            var poll = [_]linux.pollfd{.{ .fd = signal_fd, .events = linux.POLL.IN, .revents = 0 }};
            const ready = linux.poll(&poll, poll.len, 30_000);
            switch (linux.errno(ready)) {
                .SUCCESS => {},
                .INTR => continue,
                else => return error.ShutdownSignalReadFailed,
            }
            if (ready == 0) {
                sweepContainers(init, journal, client, false, signal_fd) catch |err| try log(init.io, .{ .operation = "container_sweep_failed", .error_code = @errorName(err) });
                continue;
            }
            const result = linux.read(signal_fd, std.mem.asBytes(&info).ptr, @sizeOf(linux.signalfd_siginfo));
            if (linux.errno(result) == .INTR) continue;
            if (result != @sizeOf(linux.signalfd_siginfo)) return error.ShutdownSignalReadFailed;
            break;
        }
        try log(init.io, .{ .subsystem = "process", .operation = "shutdown", .invoker_id = identity.invoker_id, .process_epoch = identity.process_epoch[0..] });
    }
}

fn sweepContainers(init: std.process.Init, journal: janitor.Journal, client: @import("podman").Client, explicit: bool, stop_fd: ?c_int) !void {
    const result = try journal.sweep(init.gpa, client, stop_fd);
    if (explicit or result.removed != 0 or result.rejected != 0 or result.unresolved != 0) {
        try log(init.io, .{ .operation = "container_sweep", .invoker_id = journal.invoker_id, .removed = result.removed, .rejected = result.rejected, .unresolved = result.unresolved, .execution_ready = false });
    }
    if (explicit and (result.rejected != 0 or result.unresolved != 0)) return error.ContainerRecoveryPending;
}

fn runArtifacts(init: std.process.Init, config: core.Config, args: []const [:0]const u8) !void {
    const phase3 = @import("phase3.zig");
    const io = init.io;
    const a = init.arena.allocator();
    const signals = try shutdownFd();
    defer _ = linux.close(signals);
    const service = try phase3.Service.open(init, config.state_dir, config.invoker_id);
    defer service.close();
    try service.cleanInterruptedInputs();
    if (args.len == 4) {
        try service.stage(args[0], args[1], args[2], args[3]);
        return log(io, .{ .operation = "artifact_staged", .execution_ready = false });
    }
    if (args.len == 1) {
        const path = args[0];
        const jobs = @import("control/job.zig");
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(jobs.max_bytes + 1));
        const assignment = try jobs.parse(a, bytes);
        defer assignment.deinit();
        var random: [16]u8 = undefined;
        try io.randomSecure(&random);
        const id = core.ProcessIdentity.init(config.invoker_id, random);
        try service.prepare(assignment.value, &id.process_epoch);
        return log(io, .{ .operation = "workspace_prepared", .run_id = assignment.value.run_id, .execution_ready = false });
    }
    try log(io, .{ .operation = "artifact_recovery_started", .execution_ready = false, .free_slots = 0 });
    var initial = true;
    while (true) {
        service.heartbeat() catch |err| try log(io, .{ .operation = "heartbeat_failed", .error_code = @errorName(err), .execution_ready = false });
        const failed = service.recover() catch |err| blk: {
            try log(io, .{ .operation = "artifact_recovery_failed", .error_code = @errorName(err) });
            break :blk 1;
        };
        if (failed != 0) try log(io, .{ .operation = "artifact_recovery_pending", .count = failed });
        if (initial) {
            initial = false;
            try log(io, .{ .operation = "artifact_recovery_scanned", .pending = failed, .execution_ready = false });
        }
        var pfd = [_]linux.pollfd{.{ .fd = signals, .events = linux.POLL.IN, .revents = 0 }};
        const result = linux.poll(&pfd, pfd.len, 5000);
        switch (linux.errno(result)) {
            .SUCCESS => if (result != 0) return,
            .INTR => continue,
            else => return error.ShutdownSignalReadFailed,
        }
    }
}

fn shutdownFd() !c_int {
    var signals = linux.sigemptyset();
    linux.sigaddset(&signals, .TERM);
    linux.sigaddset(&signals, .INT);
    if (linux.errno(linux.sigprocmask(linux.SIG.BLOCK, &signals, null)) != .SUCCESS) return error.SignalMaskFailed;
    const fd = linux.signalfd(-1, &signals, linux.SFD.CLOEXEC);
    if (linux.errno(fd) != .SUCCESS) return error.SignalFdFailed;
    return @intCast(fd);
}

fn loadConfig(init: std.process.Init, path: []const u8) !core.Config {
    const a = init.arena.allocator();
    const data = try std.Io.Dir.cwd().readFileAlloc(init.io, path, a, .limited(64 * 1024));
    var cfg = std.json.parseFromSliceLeaky(core.Config, a, data, .{}) catch return error.InvalidConfigJson;
    const env = init.environ_map;
    cfg.invoker_id = env.get("PODTEST_INVOKER_ID") orelse cfg.invoker_id;
    cfg.state_dir = env.get("PODTEST_STATE_DIR") orelse cfg.state_dir;
    cfg.podman_socket = env.get("PODTEST_PODMAN_SOCKET") orelse cfg.podman_socket;
    cfg.libpod_api_version = env.get("PODTEST_LIBPOD_API_VERSION") orelse cfg.libpod_api_version;
    if (cfg.podman_socket.len == 0) {
        const runtime_dir = env.get("XDG_RUNTIME_DIR") orelse return error.MissingRuntimeDir;
        cfg.podman_socket = try std.fmt.allocPrint(a, "{s}/podman/podman.sock", .{runtime_dir});
    }
    if (env.get("PODTEST_MAX_ACTIVE_RUNS")) |value| cfg.max_active_runs = std.fmt.parseInt(u32, value, 10) catch return error.InvalidCapacity;
    if (env.get("PODTEST_RUN_TIMEOUT_SECONDS")) |value| cfg.run_timeout_seconds = std.fmt.parseInt(u32, value, 10) catch return error.InvalidRunTimeout;
    if (env.get("PODTEST_STOP_GRACE_MS")) |value| cfg.stop_grace_ms = std.fmt.parseInt(u32, value, 10) catch return error.InvalidResourceLimit;
    if (env.get("PODTEST_STDIO_LIMIT_BYTES")) |value| cfg.stdio_limit_bytes = std.fmt.parseInt(u64, value, 10) catch return error.InvalidResourceLimit;
    try cfg.validate();
    return cfg;
}

fn log(io: std.Io, value: anytype) !void {
    var buf: [2048]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buf);
    try std.json.Stringify.value(value, .{}, &out.interface);
    try out.interface.writeByte('\n');
    try out.interface.flush();
}
