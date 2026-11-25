const std = @import("std");
const contract = @import("contract.zig");
const engine = @import("engine");
const podman = engine.podman;
const group = engine.group;
const resource = @import("resource");
const History = @import("history").History;

pub const Images = struct { posix_sh: ?podman.Id = null, javascript: ?podman.Id = null };
pub const Verdict = enum { accepted, wrong_answer, wall_timeout, output_limit, memory_limit, runtime_error };
pub const TestResult = struct { id: []const u8, verdict: Verdict, score_milli: u32, exit_code: i32, metrics: ?resource.Metrics };
pub const GroupResult = struct { id: []const u8, score_milli: u64 };

const Log = struct {
    io: std.Io,
    file: std.Io.File,
    offset: u64 = 0,

    fn append(context: *anyopaque, bytes: []const u8) !void {
        const self: *Log = @ptrCast(@alignCast(context));
        try self.file.writePositionalAll(self.io, bytes, self.offset);
        self.offset += bytes.len;
        try self.file.writePositionalAll(self.io, "\n", self.offset);
        self.offset += 1;
    }
};

/// Inputs must come from verified materialization and remain private and
/// immutable during the run. Outputs must be a separate, fresh private
/// directory; only result.json marks a completed run.
pub fn run(backing: std.mem.Allocator, io: std.Io, client: podman.Client, workspace: std.Io.Dir, outputs: std.Io.Dir, images: Images, cancel: ?podman.Cancellation) !void {
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const a = arena.allocator();
    try checkCancel(cancel);
    const manifest = try std.json.parseFromSliceLeaky(struct {
        format_version: u32,
        execution_format: []const u8,
        execution_format_version: u32,
        files: []const struct { path: []const u8, size: u64, sha256: []const u8 },
    }, a, try read(a, io, workspace, "manifest.json", 1 << 20), .{});
    if (manifest.format_version != 1 or manifest.execution_format_version != 1 or !std.mem.eql(u8, manifest.execution_format, "standard")) return error.UnsupportedStandardManifest;
    const task = (try contract.parse(a, try read(a, io, workspace, "standard.json", 64 << 10))).value;
    const base = (switch (task.language) {
        .posix_sh => images.posix_sh,
        .javascript => images.javascript,
    }) orelse return error.LanguageNotConfigured;
    const source = try read(a, io, workspace, "solution/source", contract.max_source);
    const payloads = try a.alloc(struct { input: []const u8, answer: []const u8 }, task.tests.len);
    var remaining: usize = contract.max_payload;
    for (task.tests, payloads) |item, *payload| {
        try checkCancel(cancel);
        payload.input = try read(a, io, workspace, item.input, @min(contract.max_file, @min(remaining, task.limits.output_bytes)));
        remaining -= payload.input.len;
        payload.answer = try read(a, io, workspace, item.answer, @min(contract.max_file, remaining));
        remaining -= payload.answer.len;
    }

    const info_buf = try a.alloc(u8, 128 << 10);
    const Info = struct { host: struct { security: struct { rootless: bool } } };
    const info = try std.json.parseFromSliceLeaky(Info, a, try client.info(info_buf), .{ .ignore_unknown_fields = true });
    if (!info.host.security.rootless) return error.RootlessRequired;
    const Image = struct { Config: struct { OnBuild: ?[][]const u8 = null } };
    const image = try std.json.parseFromSliceLeaky(Image, a, try client.inspectImage(base, info_buf), .{ .ignore_unknown_fields = true });
    if (image.Config.OnBuild) |triggers| if (triggers.len != 0) return error.UnsupportedImageOnBuild;
    var nonce: [12]u8 = undefined;
    try io.randomSecure(&nonce);
    const tag = try std.fmt.allocPrint(a, "podtest-phase7-{x}", .{&nonce});
    if (client.inspectTag(a, tag, info_buf)) |_| return error.StandardTagConflict else |err| if (err != error.PodmanNotFound) return err;
    const recipe = try std.fmt.allocPrint(a, "FROM {s}\nCOPY source /podtest-source\n", .{&base});
    const build_log = try outputs.createFile(io, "build.log", .{ .exclusive = true, .permissions = .fromMode(0o600) });
    defer build_log.close(io);
    var log: Log = .{ .io = io, .file = build_log };
    var remove_image = true;
    defer if (remove_image) client.removeTag(tag, info_buf) catch |err| {
        if (err != error.PodmanNotFound) std.log.err("standard image cleanup failed: {s}", .{@errorName(err)});
    };
    var dummy: u8 = 0;
    const built = try client.buildTrusted(a, &.{ .{ .path = "Dockerfile", .contents = recipe }, .{ .path = "source", .contents = source } }, tag, 30_000, Log.append, &log, cancel orelse .{ .check = neverCancel, .context = &dummy });
    try build_log.sync(io);
    const command: []const []const u8 = switch (task.language) {
        .posix_sh => &.{ "/bin/sh", "/podtest-source" },
        .javascript => &.{ "/usr/local/bin/node", "/podtest-source" },
    };
    const tests = try a.alloc(TestResult, task.tests.len);
    var scores: [contract.max_tests]contract.GroupScore = @splat(.{});
    const actual = try a.alloc(u8, @intCast(@min(task.limits.output_bytes, contract.max_history)));
    for (task.tests, payloads, tests, 0..) |item, payload, *result, i| {
        try checkCancel(cancel);
        const name = try std.fmt.allocPrint(a, "{s}-{d}", .{ tag, i });
        const dir_name = try std.fmt.allocPrint(a, "test-{d}", .{i});
        try outputs.createDir(io, dir_name, .fromMode(0o700));
        const dir = try outputs.openDir(io, dir_name, .{ .follow_symlinks = false });
        defer dir.close(io);
        var history = try History.open(io, dir, .{ .once, .once, .once }, task.limits.output_bytes);
        defer history.close();
        var measured: [1]group.Result = undefined;
        try group.run(a, io, client, &.{.{
            .spec = .{ .name = name, .image = built, .command = command },
            .limits = task.limits,
            .history = &history,
            .modes = .{ .once, .once, .once },
            .input = payload.input,
        }}, &.{}, .{ .wall_ms = @min(300_000, task.limits.wall_ms + 10_000), .history_limit = task.limits.output_bytes, .cancellation = cancel }, &measured, &.{});
        const exit = measured[0].exit;
        if (exit.cancelled) return error.PodmanCancelled;
        const verdict: Verdict = if (exit.timed_out) .wall_timeout else if (exit.output_limited) .output_limit else if (exit.oom_killed) .memory_limit else if (exit.code != 0) .runtime_error else blk: {
            const count = try history.readAt(.stdout, 0, actual);
            if (count != history.lengths[1]) return error.IncompleteStandardOutput;
            break :blk if (contract.matches(task.checker, actual[0..count], payload.answer)) .accepted else .wrong_answer;
        };
        const passed = verdict == .accepted;
        scores[try contract.groupIndex(task.groups, item.group)].record(item.points_milli, passed);
        result.* = .{ .id = item.id, .verdict = verdict, .score_milli = if (passed) item.points_milli else 0, .exit_code = exit.code, .metrics = measured[0].metrics };
    }
    const groups = try a.alloc(GroupResult, task.groups.len);
    var total: u64 = 0;
    for (task.groups, groups, 0..) |item, *result, i| {
        result.* = .{ .id = item.id, .score_milli = scores[i].value(item) };
        total += result.score_milli;
    }
    try checkCancel(cancel);
    try client.removeTag(tag, info_buf);
    remove_image = false;
    const json = try std.json.Stringify.valueAlloc(a, .{ .version = @as(u32, 1), .tests = tests, .groups = groups, .problem_score_milli = total }, .{});
    var file = try outputs.createFileAtomic(io, "result.json", .{ .permissions = .fromMode(0o600) });
    defer file.deinit(io);
    try file.file.writePositionalAll(io, json, 0);
    try file.file.sync(io);
    try checkCancel(cancel);
    try file.link(io);
}

fn neverCancel(_: *anyopaque) bool {
    return false;
}

fn checkCancel(cancel: ?podman.Cancellation) !void {
    if (cancel) |c| if (c.check(c.context)) return error.PodmanCancelled;
}

fn read(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, limit: usize) ![]const u8 {
    if (std.mem.indexOfScalar(u8, path, '/')) |sep| {
        const sub = try dir.openDir(io, path[0..sep], .{ .follow_symlinks = false });
        defer sub.close(io);
        return read(a, io, sub, path[sep + 1 ..], limit);
    }
    const file = try dir.openFile(io, path, .{ .follow_symlinks = false });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size > limit) return error.InvalidStandardFile;
    const bytes = try a.alloc(u8, @intCast(stat.size));
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.InvalidStandardFile;
    return bytes;
}
