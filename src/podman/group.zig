const std = @import("std");
const podman = @import("client.zig");
const resource = @import("resource");
const stdio = @import("history");
const pipe = @import("pipe");

pub const Node = struct {
    spec: podman.ContainerSpec,
    limits: resource.Request = .{},
    history: *stdio.History,
    modes: [3]stdio.Mode,
    input: []const u8 = "",
    realtime: ?Realtime = null,
};

/// Callbacks must not block. Pull returns null for EOF, 0 when not ready.
/// Push reads the newly committed range from disk, without a second queue.
pub const Realtime = struct {
    context: *anyopaque,
    pull: ?*const fn (*anyopaque, []u8) anyerror!?usize = null,
    push: ?*const fn (*anyopaque, *const stdio.History, stdio.Stream, u64, usize) anyerror!void = null,
};

pub const Link = struct { from: usize, to: usize };
pub const PeerPolicy = enum { close_edge, stop_group };
pub const EdgeResult = enum { eof, broken_pipe, cancelled };
pub const Options = struct {
    wall_ms: u64,
    history_limit: u64,
    peer_policy: PeerPolicy = .close_edge,
    cancellation: ?podman.Cancellation = null,
};
pub const Result = struct { exit: resource.Exit, metrics: ?resource.Metrics };

const max_nodes = 8;
const Edge = struct { queue: pipe.Buffer, result: ?EdgeResult = null };
const Active = struct {
    id: ?podman.Id = null,
    attach: ?podman.Attach = null,
    watchdog: ?resource.Watchdog = null,
    cgroup: ?std.Io.Dir = null,
    metrics: ?resource.Metrics = null,
    result: ?resource.Exit = null,
    reason: ?resource.StopReason = null,
    input_offset: usize = 0,
    pending: [4096]u8 = undefined,
    pending_start: usize = 0,
    pending_end: usize = 0,
};

/// Owns all containers from creation through removal. Histories are borrowed.
/// All endpoints are registered and attached before the first start.
pub fn run(a: std.mem.Allocator, io: std.Io, client: podman.Client, nodes: []const Node, links: []const Link, options: Options, results: []Result, edge_results: []EdgeResult) !void {
    if (nodes.len == 0 or nodes.len > max_nodes or links.len > nodes.len or results.len != nodes.len or edge_results.len != links.len or
        options.history_limit == 0 or options.history_limit > 512 << 20 or options.wall_ms == 0 or options.wall_ms > 300_000) return error.InvalidGroup;
    var outgoing: [max_nodes]?usize = @splat(null);
    var incoming: [max_nodes]?usize = @splat(null);
    var storage: [max_nodes][4096]u8 = undefined;
    var edges: [max_nodes]Edge = undefined;
    for (links, 0..) |link, i| {
        if (link.from >= nodes.len or link.to >= nodes.len or outgoing[link.from] != null or incoming[link.to] != null) return error.InvalidPipeGraph;
        outgoing[link.from] = i;
        incoming[link.to] = i;
        edges[i] = .{ .queue = try pipe.Buffer.init(&storage[i]) };
    }
    var aggregate_memory: u64 = 0;
    var aggregate_cpu: u64 = 0;
    for (nodes, 0..) |node, i| {
        try podman.validateSpec(node.spec);
        const policy = try resource.Policy.resolve(node.limits, .{});
        aggregate_memory += policy.memory_bytes;
        aggregate_cpu += policy.cpu_quota_micros;
        if (aggregate_memory > 512 << 20 or aggregate_cpu > 800_000) return error.InvalidGroup;
        if ((node.modes[0] == .pipe) != (incoming[i] != null) or (node.modes[1] == .pipe) != (outgoing[i] != null) or node.modes[2] == .pipe) return error.InvalidPipeGraph;
        if (node.input.len != 0 and node.modes[0] != .once) return error.InvalidGroup;
        if (node.modes[0] == .realtime and (node.realtime orelse return error.InvalidGroup).pull == null) return error.InvalidGroup;
        for (node.modes, node.history.files) |mode, file| if ((mode == .none) != (file == null)) return error.InvalidGroup;
        if (node.history.total != 0 or node.history.limit > policy.output_bytes) return error.InvalidGroup;
        for (nodes[0..i]) |previous| if (node.history == previous.history or std.mem.eql(u8, node.spec.name, previous.spec.name)) return error.InvalidGroup;
    }

    var state: [max_nodes]Active = @splat(.{});
    const active = state[0..nodes.len];
    defer for (active) |*entry| {
        if (entry.attach) |*stream| stream.close();
        if (entry.cgroup) |dir| dir.close(io);
        if (entry.id) |id| client.remove(id) catch |err| {
            if (err != error.PodmanNotFound) std.log.err("group container cleanup failed: {s}", .{@errorName(err)});
        };
    };
    const deadline = try resource.Watchdog.start(now(io), options.wall_ms);
    try checkSetup(io, deadline, options);
    for (nodes, active) |node, *entry| {
        try checkSetup(io, deadline, options);
        var spec = node.spec;
        spec.stdin = node.modes[0] != .none;
        spec.live_io = true;
        entry.id = try client.createWithLimits(a, spec, node.limits);
        try checkSetup(io, deadline, options);
        try client.initContainer(entry.id.?);
        try checkSetup(io, deadline, options);
        entry.attach = try client.attach(entry.id.?, spec.stdin, @intCast(@max(1, @min(3000, deadline.remainingMs(now(io))))));
    }
    var inspect: [128 << 10]u8 = undefined;
    for (nodes, active) |node, *entry| {
        try checkSetup(io, deadline, options);
        entry.watchdog = try resource.Watchdog.start(now(io), node.limits.wall_ms);
        try client.start(entry.id.?);
        entry.cgroup = try openCgroup(a, io, client, entry.id.?, &inspect);
        try sample(io, entry);
    }

    var left = nodes.len;
    var total: u64 = 0;
    var group_stop: ?resource.StopReason = null;
    var last_sample = now(io);
    while (left != 0) {
        const stamp = now(io);
        if (group_stop == null) {
            if (isCancelled(options)) group_stop = .cancelled else if (deadline.expired(stamp)) group_stop = .wall_timeout;
        }
        var progress = false;
        for (nodes, active, 0..) |node, *entry, i| {
            if (group_stop != null) for (edges[0..links.len]) |*edge| {
                if (edge.result == null) edge.result = .cancelled;
                edge.queue.cancel();
            };
            if (entry.result != null) continue;
            if (entry.reason == null) entry.reason = group_stop orelse if (entry.watchdog.?.expired(now(io))) resource.StopReason.wall_timeout else null;
            if (entry.reason != null) {
                try sample(io, entry);
                // Podman may wait for its attach writer during kill. Once the
                // stop reason is set, no more output is admitted to history.
                entry.attach.?.close();
                client.kill(entry.id.?) catch |err| if (err != error.PodmanConflict) return err;
                try finish(a, io, client, entry, &inspect, 5000);
            } else {
                const input_edge = if (incoming[i]) |e| &edges[e] else null;
                if (try pumpInput(node, entry, input_edge, &total, options.history_limit)) progress = true;
                if (input_edge) |edge| if (edge.result == .broken_pipe and options.peer_policy == .stop_group) {
                    group_stop = .cancelled;
                };
                if (entry.reason == .output_limit and total == options.history_limit) group_stop = .output_limit;
                if (entry.reason != null) continue;
                const edge = if (outgoing[i]) |e| &edges[e] else null;
                var buf: [4096]u8 = undefined;
                const capacity = if (edge) |e| if (e.queue.state == .open) e.queue.storage.len - e.queue.len else buf.len else buf.len;
                if (capacity == 0) continue;
                const read = entry.attach.?.read(buf[0..capacity]) catch |err| {
                    switch (err) {
                        error.WouldBlock => continue,
                        else => return err,
                    }
                };
                if (read) |chunk| {
                    progress = true;
                    const channel: stdio.Stream = if (chunk.stream == .stdout) .stdout else .stderr;
                    const mode = node.modes[@backingInt(channel)];
                    if (mode == .none) continue;
                    const bytes = buf[0..chunk.len];
                    if (!try record(node, channel, bytes, &total, options.history_limit)) {
                        entry.reason = .output_limit;
                        if (total == options.history_limit) group_stop = .output_limit;
                        continue;
                    }
                    if (mode == .pipe) if (edge) |e| {
                        if (e.queue.state == .open) _ = try e.queue.write(bytes);
                    };
                    continue;
                } else {
                    try finish(a, io, client, entry, &inspect, 20);
                    if (entry.result == null) continue;
                }
            }
            left -= 1;
            progress = true;
            if (outgoing[i]) |e| edges[e].queue.halfClose();
            if (incoming[i]) |e| {
                if (edges[e].result == null) edges[e].result = .broken_pipe;
                edges[e].queue.consumerClosed();
                if (edges[e].result == .broken_pipe and options.peer_policy == .stop_group and group_stop == null) group_stop = .cancelled;
            }
        }
        if (stamp - last_sample >= 20 * std.time.ns_per_ms) {
            for (active) |*entry| if (entry.result == null) try sample(io, entry);
            last_sample = stamp;
        }
        if (!progress and left != 0) try io.sleep(.fromMilliseconds(1), .awake);
    }

    for (nodes, active, results) |node, *entry, *result| {
        try node.history.sync();
        result.* = .{ .exit = entry.result.?, .metrics = entry.metrics };
        entry.attach.?.close();
        try client.remove(entry.id.?);
        entry.id = null;
    }
    for (edges[0..links.len], edge_results) |edge, *result| result.* = edge.result orelse .broken_pipe;
}

fn record(node: Node, channel: stdio.Stream, bytes: []const u8, total: *u64, limit: u64) !bool {
    const index = @backingInt(channel);
    const offset = node.history.lengths[index];
    const count = @min(bytes.len, node.history.available(channel), limit - total.*);
    try node.history.append(channel, bytes[0..count]);
    total.* += count;
    if (channel != .stdin and node.modes[index] == .realtime) if (node.realtime) |hooks| if (hooks.push) |push| {
        if (count != 0) try push(hooks.context, node.history, channel, offset, count);
    };
    return count == bytes.len;
}

fn pumpInput(node: Node, entry: *Active, edge: ?*Edge, total: *u64, limit: u64) !bool {
    const stream = &entry.attach.?;
    if (!stream.input_open) return false;
    const bytes: []const u8 = switch (node.modes[0]) {
        .none => unreachable,
        .once => node.input[entry.input_offset..],
        .pipe => blk: {
            const e = edge.?;
            if (e.queue.len == 0 and e.queue.state == .open) return false;
            break :blk e.queue.readable();
        },
        .realtime => blk: {
            if (entry.pending_start == entry.pending_end) {
                const hooks = node.realtime.?;
                const n = try hooks.pull.?(hooks.context, &entry.pending) orelse break :blk "";
                if (n > entry.pending.len) return error.InvalidRealtimeChunk;
                if (n == 0) return false;
                entry.pending_start = 0;
                entry.pending_end = n;
            }
            break :blk entry.pending[entry.pending_start..entry.pending_end];
        },
    };
    if (bytes.len == 0) {
        stream.closeInput() catch |err| {
            if (err != error.BrokenPipe) return err;
            if (edge) |e| e.result = .broken_pipe;
            return true;
        };
        if (edge) |e| e.result = .eof;
        return true;
    }
    const capacity = @min(bytes.len, node.history.available(.stdin), limit - total.*);
    if (capacity == 0) {
        entry.reason = .output_limit;
        return true;
    }
    const n = stream.write(bytes[0..capacity]) catch |err| switch (err) {
        error.WouldBlock => return false,
        error.BrokenPipe => {
            stream.input_open = false;
            if (edge) |e| {
                e.result = .broken_pipe;
                e.queue.consumerClosed();
            }
            return true;
        },
        else => return err,
    };
    _ = try record(node, .stdin, bytes[0..n], total, limit);
    switch (node.modes[0]) {
        .once => entry.input_offset += n,
        .pipe => edge.?.queue.discard(n),
        .realtime => entry.pending_start += n,
        .none => unreachable,
    }
    return n != 0;
}

fn finish(a: std.mem.Allocator, io: std.Io, client: podman.Client, entry: *Active, scratch: []u8, timeout: u32) !void {
    try sample(io, entry);
    const code = client.wait(entry.id.?, timeout) catch |err| {
        if (err == error.PodmanTimeout and entry.reason == null) return;
        return err;
    };
    try sample(io, entry);
    const inspected = try client.runtimeState(a, entry.id.?, scratch);
    defer inspected.deinit();
    entry.result = .{
        .code = code,
        .oom_killed = inspected.value.State.OOMKilled or (if (entry.metrics) |m| m.events.oom_kill != 0 else false),
        .timed_out = entry.reason == .wall_timeout,
        .output_limited = entry.reason == .output_limit,
        .cancelled = entry.reason == .cancelled,
    };
}

fn now(io: std.Io) i128 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn isCancelled(options: Options) bool {
    return if (options.cancellation) |c| c.check(c.context) else false;
}

fn checkSetup(io: std.Io, deadline: resource.Watchdog, options: Options) !void {
    if (isCancelled(options)) return error.GroupCancelled;
    if (deadline.expired(now(io))) return error.GroupTimeout;
}

fn openCgroup(a: std.mem.Allocator, io: std.Io, client: podman.Client, id: podman.Id, scratch: []u8) !?std.Io.Dir {
    const info = try client.runtimeState(a, id, scratch);
    defer info.deinit();
    const path = info.value.State.CgroupPath;
    if (path.len == 0 and !info.value.State.Running) return null;
    if (path.len < 2 or path[0] != '/' or path.len > 4096) return error.InvalidCgroupPath;
    var parts = std.mem.splitScalar(u8, path[1..], '/');
    var dir = try std.Io.Dir.openDirAbsolute(io, "/sys/fs/cgroup", .{});
    errdefer dir.close(io);
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidCgroupPath;
        const child = dir.openDir(io, part, .{ .follow_symlinks = false }) catch |err| {
            if (err != error.FileNotFound) return err;
            dir.close(io);
            return null;
        };
        dir.close(io);
        dir = child;
    }
    return dir;
}

fn sample(io: std.Io, entry: *Active) !void {
    const dir = entry.cgroup orelse return;
    entry.metrics = resource.Metrics.read(io, dir) catch |err| switch (err) {
        error.FileNotFound, error.Unexpected => return,
        else => return err,
    };
}
