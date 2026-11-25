const std = @import("std");
const podman = @import("client.zig");
const resource = @import("resource");
const History = @import("history").History;
const group = @import("group.zig");
extern fn podtest_ping([*:0]const u8, [*:0]const u8) c_int;

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const socket = init.environ_map.get("PODTEST_PODMAN_SOCKET") orelse return error.ExpectedRootlessSocket;
    const image_id = init.environ_map.get("PODTEST_TEST_IMAGE_ID") orelse return error.ExpectedLocalAlpineImageId;
    if (image_id.len != 64) return error.ExpectedLocalAlpineImageId;
    const image: podman.Id = image_id[0..64].*;
    const client: podman.Client = .{ .socket = try a.dupeSentinel(u8, socket, 0), .api_version = "6.2.0" };
    if (podtest_ping(client.socket, client.api_version) != 0) return error.LibpodVersionCheckFailed;
    if (podtest_ping(client.socket, "1.0.0") != 4) return error.LibpodVersionMismatchNotDetected;
    try client.ping();
    const out = try a.alloc(u8, 128 << 10);
    const info = try client.info(out);
    const Info = struct { host: struct { security: struct { rootless: bool } } };
    const host = try std.json.parseFromSliceLeaky(Info, a, info, .{ .ignore_unknown_fields = true });
    if (!host.host.security.rootless) return error.RootlessRequired;
    _ = try client.inspectVersion(out);
    _ = try client.inspectImage(image, out);
    var random: [12]u8 = undefined;
    try init.io.randomSecure(&random);
    const name = try std.fmt.allocPrint(a, "podtest-phase4-{x}", .{&random});
    try checkBuild(a, init.io, client, image, name);
    const network = try client.createNetwork(a, name, name, out);
    var network_removed = false;
    defer if (!network_removed) client.removeNetwork(network) catch |err| std.log.err("network cleanup failed: {s}", .{@errorName(err)});
    const Network = struct { internal: bool, dns_enabled: bool };
    const inspected_network = try std.json.parseFromSliceLeaky(Network, a, try client.inspectNetwork(network, out), .{ .ignore_unknown_fields = true });
    if (!inspected_network.internal or inspected_network.dns_enabled) return error.UnsafeNetworkConfig;
    const id = try client.create(a, .{ .name = name, .image = image, .command = &.{ "/bin/sh", "-c", "grep -q '^NoNewPrivs:[[:space:]]*1$' /proc/self/status && printf phase4-ok && exit 23; exit 24" } });
    var removed = false;
    defer if (!removed) client.remove(id) catch |err| std.log.err("container cleanup failed: {s}", .{@errorName(err)});
    const Inspect = struct { HostConfig: struct { NetworkMode: []const u8, ReadonlyRootfs: bool, Privileged: bool, Memory: i64, PidsLimit: i64 }, Config: struct { User: []const u8 } };
    const inspect = try std.json.parseFromSlice(Inspect, a, try client.inspect(id, out), .{ .ignore_unknown_fields = true });
    defer inspect.deinit();
    const cfg = inspect.value.HostConfig;
    if (!std.mem.eql(u8, cfg.NetworkMode, "none") or !cfg.ReadonlyRootfs or cfg.Privileged or cfg.Memory != 128 << 20 or cfg.PidsLimit != 64 or !std.mem.eql(u8, inspect.value.Config.User, "65534:65534")) return error.UnsafeContainerConfig;
    try client.start(id);
    if (try client.wait(id, 10000) != 23) return error.UnexpectedExitCode;
    var logs: Capture = .{};
    try client.logs(id, 5000, Capture.append, &logs);
    if (std.mem.indexOf(u8, logs.data[0..logs.len], "phase4-ok") == null) return error.MissingContainerOutput;
    if (client.logs(id, 5000, Capture.abort, &logs)) |_| {
        return error.LogStreamDidNotAbort;
    } else |err| if (err != error.PodmanStreamAborted) return err;
    try client.remove(id);
    removed = true;
    if (client.inspect(id, out)) |_| {
        return error.RemovedContainerStillExists;
    } else |err| if (err != error.PodmanNotFound) return err;
    try checkStopAndKill(a, init.io, client, image, name);
    try checkResources(a, init.io, client, image, name);
    try checkAttach(a, init.io, client, image, name);
    try checkGroup(a, init.io, client, image, name);
    try client.removeNetwork(network);
    network_removed = true;
    if (client.inspectNetwork(network, out)) |_| return error.RemovedNetworkStillExists else |err| if (err != error.PodmanNotFound) return err;
    std.log.info("Rootless Libpod adapter and resource/I/O acceptance passed", .{});
}

fn checkGroup(a: std.mem.Allocator, io: std.Io, client: podman.Client, image: podman.Id, name: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDir(io, name, .fromMode(0o700));
    defer cwd.deleteTree(io, name) catch |err| std.log.err("group spool cleanup failed: {s}", .{@errorName(err)});
    const dir = try cwd.openDir(io, name, .{});
    defer dir.close(io);
    const producer_name = try std.fmt.allocPrint(a, "{s}-p", .{name});
    const consumer_name = try std.fmt.allocPrint(a, "{s}-c", .{name});
    const Scenario = enum { transfer, cancel, early_exit, cycle, run_limit, setup_error };
    for ([_]Scenario{ .transfer, .cancel, .early_exit, .cycle, .run_limit, .setup_error }) |scenario| {
        const parent_name = @tagName(scenario);
        try dir.createDir(io, parent_name, .fromMode(0o700));
        const parent = try dir.openDir(io, parent_name, .{});
        defer parent.close(io);
        try parent.createDir(io, "p", .fromMode(0o700));
        try parent.createDir(io, "c", .fromMode(0o700));
        const pd = try parent.openDir(io, "p", .{});
        defer pd.close(io);
        const cd = try parent.openDir(io, "c", .{});
        defer cd.close(io);
        const pm: [3]@import("history").Mode = .{ if (scenario == .cycle) .pipe else .none, .pipe, .none };
        const cm: [3]@import("history").Mode = .{ .pipe, if (scenario == .cycle) .pipe else .once, .none };
        var ph = try History.open(io, pd, pm, 1 << 20);
        defer ph.close();
        var ch = try History.open(io, cd, cm, 1 << 20);
        defer ch.close();
        const nodes: []const group.Node = &.{
            .{ .spec = .{ .name = producer_name, .image = image, .command = switch (scenario) {
                .cancel => &.{ "/bin/sleep", "60" },
                .early_exit => &.{ "/bin/sh", "-c", "sleep 0.3; printf late; exit 23" },
                .cycle => &.{ "/bin/sh", "-c", "printf 'ping\\n'; read -r msg; test \"$msg\" = pong" },
                else => &.{ "/bin/sh", "-c", "dd if=/dev/zero bs=4096 count=64 2>/dev/null" },
            } }, .history = &ph, .modes = pm },
            .{ .spec = .{ .name = consumer_name, .image = if (scenario == .setup_error) @splat('0') else image, .command = switch (scenario) {
                .early_exit => &.{"/bin/true"},
                .cycle => &.{ "/bin/sh", "-c", "read -r msg; test \"$msg\" = ping && printf 'pong\\n'" },
                else => &.{ "/bin/sh", "-c", "sleep 0.2; wc -c" },
            } }, .history = &ch, .modes = cm },
        };
        var results: [2]group.Result = undefined;
        var edges: [2]group.EdgeResult = undefined;
        const links = [_]group.Link{ .{ .from = 0, .to = 1 }, .{ .from = 1, .to = 0 } };
        const edge_count: usize = if (scenario == .cycle) 2 else 1;
        var timer: CancelAfter = .{ .io = io, .start = std.Io.Clock.awake.now(io), .delay = 2500 };
        group.run(a, io, client, nodes, links[0..edge_count], .{
            .wall_ms = 10000,
            .history_limit = if (scenario == .run_limit) 6144 else 2 << 20,
            .cancellation = if (scenario == .cancel) .{ .check = CancelAfter.poll, .context = &timer } else null,
        }, &results, edges[0..edge_count]) catch |err| {
            if (scenario == .setup_error and (err == error.PodmanNotFound or err == error.PodmanServerError or err == error.PodmanHttpRejected)) {
                var scratch: [4096]u8 = undefined;
                if (client.inspectContainerName(producer_name, &scratch)) |_| return error.PartialGroupLeaked else |lookup_err| if (lookup_err != error.PodmanNotFound) return lookup_err;
                continue;
            }
            return err;
        };
        if (scenario == .cancel) {
            if (edges[0] != .cancelled or !results[0].exit.cancelled or !results[1].exit.cancelled) return error.GroupCancellationMissing;
        } else if (scenario == .early_exit) {
            if (edges[0] != .broken_pipe or results[0].exit.code != 23 or results[1].exit.code != 0) return error.GroupPeerClosedIncorrectly;
        } else if (scenario == .cycle) {
            if (results[0].exit.code != 0 or results[1].exit.code != 0 or ch.lengths[0] != 5 or ph.lengths[0] != 5) return error.GroupCycleFailed;
        } else if (scenario == .run_limit) {
            if (ph.total + ch.total != 6144 or !results[0].exit.output_limited or !results[1].exit.output_limited) return error.GroupLimitMissing;
        } else if (scenario == .setup_error) {
            return error.GroupSetupDidNotFail;
        } else {
            if (edges[0] != .eof or results[0].exit.code != 0 or results[1].exit.code != 0) return error.GroupTransferFailed;
            var buf: [64]u8 = undefined;
            const n = try ch.readAt(.stdout, 0, &buf);
            if (!std.mem.eql(u8, std.mem.trim(u8, buf[0..n], " \n"), "262144") or ph.total != 262144 or ch.lengths[0] != 262144) return error.GroupTransferIncomplete;
            const metrics = results[1].metrics orelse return error.GroupMetricsMissing;
            if (metrics.cpu.usage_usec == 0 or metrics.memory_peak == 0) return error.GroupMetricsEmpty;
        }
    }
}

fn checkAttach(a: std.mem.Allocator, io: std.Io, client: podman.Client, image: podman.Id, name: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDir(io, name, .fromMode(0o700));
    defer cwd.deleteTree(io, name) catch |err| std.log.err("history cleanup: {s}", .{@errorName(err)});
    const dir = try cwd.openDir(io, name, .{});
    defer dir.close(io);
    const Scenario = enum { once, realtime, output_limit, wall_timeout };
    for ([_]Scenario{ .once, .realtime, .output_limit, .wall_timeout }) |scenario| {
        const limited = scenario == .output_limit;
        const timed_out = scenario == .wall_timeout;
        const spec: podman.ContainerSpec = .{ .name = name, .image = image, .command = switch (scenario) {
            .output_limit => &.{ "/bin/sh", "-c", "printf 123456789; exec sleep 60" },
            .wall_timeout => &.{ "/bin/sleep", "60" },
            else => &.{ "/bin/sh", "-c", "cat; printf err >&2" },
        } };
        const subdir = @tagName(scenario);
        try dir.createDir(io, subdir, .fromMode(0o700));
        const spool = try dir.openDir(io, subdir, .{});
        defer spool.close(io);
        const modes: [3]@import("history").Mode = switch (scenario) {
            .once => .{ .once, .once, .once },
            .realtime => .{ .realtime, .realtime, .once },
            else => .{ .none, .once, .none },
        };
        var history = try History.open(io, spool, modes, if (limited) 5 else 100);
        defer history.close();
        const input = "a\x00\xffb";
        var realtime: RealtimeFixture = .{ .input = input };
        var results: [1]group.Result = undefined;
        try group.run(a, io, client, &.{.{
            .spec = spec,
            .history = &history,
            .modes = modes,
            .limits = .{ .wall_ms = if (timed_out) 400 else 5000 },
            .input = if (scenario == .once) input else "",
            .realtime = if (scenario == .realtime) .{ .context = &realtime, .pull = RealtimeFixture.pull, .push = RealtimeFixture.push } else null,
        }}, &.{}, .{ .wall_ms = 5000, .history_limit = 100 }, &results, &.{});
        var buffer: [1024]u8 = undefined;
        if (results[0].exit.output_limited != limited or results[0].exit.timed_out != timed_out or results[0].exit.code != @as(i32, if (limited or timed_out) 137 else 0)) return error.UnexpectedAttachExit;
        const n = try history.readAt(.stdout, 0, &buffer);
        if (!std.mem.eql(u8, buffer[0..n], if (limited) "12345" else if (timed_out) "" else input)) return error.UnexpectedAttachOutput;
        if (!limited and !timed_out) {
            if (scenario == .realtime and !std.mem.eql(u8, realtime.output[0..realtime.received], input)) return error.MissingRealtimeOutput;
            const stderr_len = try history.readAt(.stderr, 0, &buffer);
            if (!std.mem.eql(u8, buffer[0..stderr_len], "err")) return error.UnexpectedAttachStderr;
            const stdin_len = try history.readAt(.stdin, 0, &buffer);
            if (!std.mem.eql(u8, buffer[0..stdin_len], input)) return error.UnexpectedAttachStdin;
        }
    }
}

const RealtimeFixture = struct {
    input: []const u8,
    sent: usize = 0,
    received: usize = 0,
    output: [16]u8 = undefined,

    fn pull(ctx: *anyopaque, out: []u8) !?usize {
        const self: *RealtimeFixture = @ptrCast(@alignCast(ctx));
        if (self.sent == self.input.len) return null;
        out[0] = self.input[self.sent];
        self.sent += 1;
        return 1;
    }

    fn push(ctx: *anyopaque, history: *const History, channel: @import("history").Stream, offset: u64, count: usize) !void {
        const self: *RealtimeFixture = @ptrCast(@alignCast(ctx));
        if (channel != .stdout or count > self.output.len - self.received) return error.InvalidRealtimeOutput;
        if (try history.readAt(channel, offset, self.output[self.received..][0..count]) != count) return error.InvalidRealtimeOutput;
        self.received += count;
    }
};

fn checkBuild(a: std.mem.Allocator, io: std.Io, client: podman.Client, image: podman.Id, tag: []const u8) !void {
    const context: []const podman.ContextFile = &.{
        .{ .path = "Dockerfile", .contents = try std.fmt.allocPrint(a, "FROM {s}\nCOPY nested/message /message\nRUN cat /message\n", .{&image}) },
        .{ .path = "nested/message", .contents = "phase4-build-ok\n" },
    };
    var file = try std.Io.Dir.cwd().createFileAtomic(io, tag, .{ .permissions = .fromMode(0o600) });
    defer file.deinit(io);
    var build_log = DiskLog{ .io = io, .file = file.file };
    const inspect = try a.alloc(u8, 128 << 10);
    defer a.free(inspect);
    if (client.inspectTag(a, tag, inspect)) |_| return error.FixtureTagConflict else |err| if (err != error.PodmanNotFound) return err;
    var removed_image = false;
    defer if (!removed_image) client.removeTag(tag, inspect) catch |err| {
        if (err != error.PodmanNotFound) std.log.err("build image cleanup failed: {s}", .{@errorName(err)});
    };
    var was_cancelled = true;
    const cancel: podman.Cancellation = .{ .check = Cancellation.cancelled, .context = &was_cancelled };
    if (client.buildTrusted(a, context, tag, 120000, DiskLog.append, &build_log, cancel)) |_| {
        return error.BuildNotCancelled;
    } else |err| if (err != error.PodmanCancelled) return err;
    was_cancelled = false;
    const bad_context: []const podman.ContextFile = &.{.{ .path = "Dockerfile", .contents = try std.fmt.allocPrint(a, "FROM {s}\nRUN exit 42\n", .{&image}) }};
    if (client.buildTrusted(a, bad_context, tag, 30000, DiskLog.append, &build_log, cancel)) |_| {
        return error.FailedBuildReportedSuccess;
    } else |err| if (err != error.PodmanBuildFailed) return err;
    if (client.inspectTag(a, tag, inspect)) |_| return error.FailedBuildPublishedTag else |err| if (err != error.PodmanNotFound) return err;
    const success_offset = build_log.bytes;
    const built = try client.buildTrusted(a, context, tag, 120000, DiskLog.append, &build_log, cancel);
    try file.file.sync(io);
    var build_output: [16384]u8 = undefined;
    const n = try file.file.readPositionalAll(io, &build_output, success_offset);
    if (std.mem.indexOf(u8, build_output[0..n], "phase4-build-ok") == null) return error.BuildLogsMissing;
    const image_json = try client.inspectImage(built, inspect);
    if (std.mem.indexOf(u8, image_json, "sha256:") == null) return error.ImageInspectMissingDigest;
    const container = try client.create(a, .{ .name = tag, .image = built, .command = &.{ "/bin/cat", "/message" } });
    var removed_container = false;
    defer if (!removed_container) client.remove(container) catch {};
    try client.start(container);
    if (try client.wait(container, 10000) != 0) return error.BuiltImageFailed;
    var logs: Capture = .{};
    try client.logs(container, 5000, Capture.append, &logs);
    if (std.mem.indexOf(u8, logs.data[0..logs.len], "phase4-build-ok") == null) return error.BuiltImageOutputMissing;
    try client.remove(container);
    removed_container = true;
    try client.removeTag(tag, inspect);
    removed_image = true;
    if (client.inspectTag(a, tag, inspect)) |_| return error.RemovedTagStillExists else |err| if (err != error.PodmanNotFound) return err;
}

const DiskLog = struct {
    io: std.Io,
    file: std.Io.File,
    bytes: u64 = 0,

    fn append(context: *anyopaque, data: []const u8) !void {
        const self: *DiskLog = @ptrCast(@alignCast(context));
        try self.file.writeStreamingAll(self.io, data);
        self.bytes += data.len;
    }
};

const Cancellation = struct {
    fn cancelled(context: *anyopaque) bool {
        return @as(*bool, @ptrCast(@alignCast(context))).*;
    }
};

fn checkStopAndKill(a: std.mem.Allocator, io: std.Io, client: podman.Client, image: podman.Id, name: []const u8) !void {
    const id = try client.create(a, .{ .name = name, .image = image, .command = &.{ "/bin/sleep", "60" } });
    var removed = false;
    defer if (!removed) {
        client.kill(id) catch {};
        client.remove(id) catch |err| std.log.err("container cleanup failed: {s}", .{@errorName(err)});
    };
    try client.start(id);
    if (client.wait(id, 100)) |_| {
        return error.RunningContainerDidNotTimeOut;
    } else |err| if (err != error.PodmanTimeout) return err;
    var timer: CancelAfter = .{ .io = io, .start = std.Io.Clock.awake.now(io) };
    if (client.waitCancelable(id, 5000, .{ .check = CancelAfter.poll, .context = &timer })) |_| {
        return error.RunningWaitDidNotCancel;
    } else |err| if (err != error.PodmanCancelled) return err;
    try client.stop(id);
    const stopped = try client.wait(id, 5000);
    if (stopped != 137 and stopped != 143) return error.UnexpectedStopExitCode;
    try client.remove(id);
    removed = true;
    const kill_id = try client.create(a, .{ .name = name, .image = image, .command = &.{ "/bin/sleep", "60" } });
    var kill_removed = false;
    defer if (!kill_removed) client.remove(kill_id) catch |err| std.log.err("container cleanup failed: {s}", .{@errorName(err)});
    try client.start(kill_id);
    try client.kill(kill_id);
    if (try client.wait(kill_id, 5000) != 137) return error.UnexpectedKillExitCode;
    try client.remove(kill_id);
    kill_removed = true;
}

const CancelAfter = struct {
    io: std.Io,
    start: std.Io.Timestamp,
    delay: i64 = 150,

    fn poll(context: *anyopaque) bool {
        const self: *CancelAfter = @ptrCast(@alignCast(context));
        return self.start.durationTo(std.Io.Clock.awake.now(self.io)).toMilliseconds() >= self.delay;
    }
};

fn checkResources(a: std.mem.Allocator, io: std.Io, client: podman.Client, image: podman.Id, name: []const u8) !void {
    const cases = [_]struct { script: []const u8, wall_ms: u64, reason: []const u8, code: i32 }{
        .{ .script = "test $(cat /sys/fs/cgroup/memory.max) = 16777216 && test $(cat /sys/fs/cgroup/memory.swap.max) = 0 && test $(cat /sys/fs/cgroup/pids.max) = 16 && test \"$(cat /sys/fs/cgroup/cpu.max)\" = '50000 100000' && exit 23; exit 24", .wall_ms = 8000, .reason = "nonzero_exit", .code = 23 },
        .{ .script = "exec sleep 60", .wall_ms = 400, .reason = "wall_timeout", .code = 137 },
        .{ .script = "exec awk 'BEGIN { for (i = 0; i < 1000000; i++) a[i] = sprintf(\"%01024d\", i) }'", .wall_ms = 8000, .reason = "oom", .code = 137 },
    };
    for (cases) |case| {
        const id = try client.createWithLimits(a, .{ .name = name, .image = image, .command = &.{ "/bin/sh", "-c", case.script } }, .{
            .memory_bytes = 16 << 20,
            .pids = 16,
            .cpu_quota_micros = 50_000,
            .wall_ms = case.wall_ms,
        });
        var removed = false;
        defer if (!removed) client.remove(id) catch |err| std.log.err("resource fixture cleanup failed: {s}", .{@errorName(err)});
        try client.start(id);
        const watchdog = try resource.Watchdog.start(std.Io.Clock.awake.now(io).nanoseconds, case.wall_ms);
        const result = try client.waitSupervised(io, a, id, watchdog);
        if (!std.mem.eql(u8, result.reason(), case.reason) or result.code != case.code) {
            std.log.err("expected {s}/{d}, got {s}/{d}", .{ case.reason, case.code, result.reason(), result.code });
            return error.UnexpectedResourceResult;
        }
        try client.remove(id);
        removed = true;
    }
}

const Capture = struct {
    data: [16384]u8 = undefined,
    len: usize = 0,
    fn append(ctx: *anyopaque, bytes: []const u8) !void {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        if (bytes.len > self.data.len - self.len) return error.TestLogOverflow;
        @memcpy(self.data[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }
    fn abort(_: *anyopaque, _: []const u8) !void {
        return error.TestAbort;
    }
};
