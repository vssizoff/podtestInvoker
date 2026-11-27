const std = @import("std");
const report = @import("result.zig");
const contract = @import("contract.zig");
const testlib = @import("testlib.zig");
const engine = @import("engine");
const podman = engine.podman;
const group = engine.group;
const resource = @import("resource");
const History = @import("history").History;

pub const Images = struct { posix_sh: ?podman.Id = null, javascript: ?podman.Id = null, testlib: ?podman.Id = null, cpp23: ?podman.Id = null, python314: ?podman.Id = null };
pub const Verdict = report.Verdict;
pub const TestResult = report.TestResult;
pub const GroupResult = report.GroupResult;

pub const Progress = struct {
    pub const Event = union(enum) {
        build_started,
        build_finished,
        test_started: []const u8,
    };

    context: *anyopaque,
    emit: *const fn (*anyopaque, Event) anyerror!void,

    fn report(progress: ?Progress, event: Event) !void {
        if (progress) |observer| try observer.emit(observer.context, event);
    }
};

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
pub fn run(backing: std.mem.Allocator, io: std.Io, client: podman.Client, workspace: std.Io.Dir, outputs: std.Io.Dir, images: Images, cancel: ?podman.Cancellation, ownership: ?group.Ownership) !void {
    return runSelected(backing, io, client, workspace, outputs, images, null, cancel, ownership, null);
}

pub fn runSelected(backing: std.mem.Allocator, io: std.Io, client: podman.Client, workspace: std.Io.Dir, outputs: std.Io.Dir, images: Images, requested: ?[]const u8, cancel: ?podman.Cancellation, ownership: ?group.Ownership, progress: ?Progress) !void {
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
    const language = try contract.selectLanguage(task, requested);
    const build_log = try outputs.createFile(io, "build.log", .{ .exclusive = true, .permissions = .fromMode(0o600) });
    defer build_log.close(io);
    var log: Log = .{ .io = io, .file = build_log };
    const base = (switch (language) {
        .posix_sh => images.posix_sh,
        .javascript => images.javascript,
        .cpp23 => images.cpp23,
        .python314 => images.python314,
    }) orelse {
        try Log.append(&log, "Submission language image is not configured");
        try build_log.sync(io);
        return finish(io, a, outputs, .{ .version = 1, .tests = &.{}, .groups = &.{}, .problem_score_milli = 0, .infrastructure_error = true }, cancel);
    };
    const source = try read(a, io, workspace, "solution/source", contract.max_source);
    const payloads = try a.alloc(struct { input: []const u8, answer: []const u8 }, task.tests.len);
    const custom = task.checker == .testlib;
    const file_limit: usize = if (custom) contract.testlib_file else contract.max_file;
    var remaining: usize = if (custom) contract.testlib_payload else contract.max_payload;
    for (task.tests, payloads) |item, *payload| {
        try checkCancel(cancel);
        payload.input = try read(a, io, workspace, item.input, @min(file_limit, @min(remaining, task.limits.output_bytes)));
        remaining -= payload.input.len;
        payload.answer = try read(a, io, workspace, item.answer, @min(file_limit, remaining));
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
    try Progress.report(progress, .build_started);
    const program = if (language == .cpp23) (try compileCpp(a, io, client, outputs, base, source, &log, cancel, ownership)) orelse {
        try Progress.report(progress, .build_finished);
        try build_log.sync(io);
        return finish(io, a, outputs, .{ .version = 1, .tests = &.{}, .groups = &.{}, .problem_score_milli = 0, .compilation_error = true }, cancel);
    } else source;
    var dummy: u8 = 0;
    const cancellation = cancel orelse podman.Cancellation{ .check = neverCancel, .context = &dummy };
    var checker_id: ?podman.Id = null;
    var checker_tag: ?[]const u8 = null;
    var checker_intent: ?engine.janitor.Record = null;
    defer if (checker_tag) |name| cleanupImage(client, name, info_buf, ownership, checker_intent) catch |err| {
        std.log.err("checker image cleanup failed: {s}", .{@errorName(err)});
    };
    if (custom) {
        const compiler = images.testlib orelse {
            try Log.append(&log, "Testlib compiler image is not configured");
            try build_log.sync(io);
            return finish(io, a, outputs, .{ .version = 1, .tests = &.{}, .groups = &.{}, .problem_score_milli = 0, .infrastructure_error = true }, cancel);
        };
        const compiler_image = try std.json.parseFromSliceLeaky(Image, a, try client.inspectImage(compiler, info_buf), .{ .ignore_unknown_fields = true });
        if (compiler_image.Config.OnBuild) |triggers| if (triggers.len != 0) return error.UnsupportedImageOnBuild;
        const cpp = try read(a, io, workspace, "checker/checker.cpp", contract.max_source);
        const header = try read(a, io, workspace, "checker/testlib.h", contract.max_source);
        const compiler_input = try testlib.packFiles(a, &.{ "checker.cpp", "testlib.h" }, &.{ cpp, header });
        const compiler_name = try std.fmt.allocPrint(a, "podtest-phase7-{x}-cc", .{&nonce});
        try outputs.createDir(io, "checker-compile", .fromMode(0o700));
        const compile_dir = try outputs.openDir(io, "checker-compile", .{ .follow_symlinks = false });
        defer compile_dir.close(io);
        const modes = .{ .once, .once, .once };
        const cap = compiler_input.len + (2 << 20);
        var history = try History.open(io, compile_dir, modes, cap);
        defer history.close();
        history.stream_limits = .{ compiler_input.len, 1 << 20, 64 << 10 };
        var measured: [1]group.Result = undefined;
        try group.run(a, io, client, &.{.{
            .spec = .{ .name = compiler_name, .image = compiler, .command = testlib.compiler_command, .scratch = true },
            .limits = .{ .memory_bytes = 512 << 20, .cpu_quota_micros = 200_000, .wall_ms = 60_000, .output_bytes = cap },
            .history = &history,
            .modes = modes,
            .input = compiler_input,
        }}, &.{}, .{ .wall_ms = 70_000, .history_limit = cap, .cancellation = cancel, .ownership = ownership }, &measured, &.{});
        const exit = measured[0].exit;
        if (exit.cancelled) return error.PodmanCancelled;
        const diagnostics = try a.alloc(u8, @intCast(history.lengths[2]));
        const diag_len = try history.readAt(.stderr, 0, diagnostics);
        if (diag_len != 0) try Log.append(&log, diagnostics[0..diag_len]);
        if (exit.code != 0 or exit.timed_out or exit.oom_killed or exit.output_limited or history.lengths[1] == 0) {
            try Log.append(&log, "Testlib compilation failed or exceeded its limits");
            try build_log.sync(io);
            return finish(io, a, outputs, .{ .version = 1, .tests = &.{}, .groups = &.{}, .problem_score_milli = 0, .infrastructure_error = true }, cancel);
        }
        const binary = try a.alloc(u8, @intCast(history.lengths[1]));
        if (try history.readAt(.stdout, 0, binary) != binary.len) return error.IncompleteCheckerBinary;
        checker_intent = if (ownership) |owner| try owner.journal.reserveKind(a, owner.run_id, .image) else null;
        const name = if (checker_intent) |intent| try a.dupe(u8, &intent.name()) else try std.fmt.allocPrint(a, "podtest-phase7-{x}-checker", .{&nonce});
        if (client.inspectTag(a, name, info_buf)) |_| return error.StandardTagConflict else |err| if (err != error.PodmanNotFound) return err;
        checker_tag = name;
        const checker_labels = if (checker_intent) |intent| try engine.janitor.imageLabels(a, intent) else "";
        const checker_recipe = try std.fmt.allocPrint(a, "FROM {s}\nCOPY checker /podtest-checker\n{s}", .{ &compiler, checker_labels });
        checker_id = client.buildTrusted(a, &.{ .{ .path = "Dockerfile", .contents = checker_recipe }, .{ .path = "checker", .contents = binary, .executable = true } }, name, 30_000, Log.append, &log, cancellation) catch |err| {
            if (err != error.PodmanBuildFailed) return err;
            try build_log.sync(io);
            try cleanupImage(client, name, info_buf, ownership, checker_intent);
            checker_tag = null;
            return finish(io, a, outputs, .{ .version = 1, .tests = &.{}, .groups = &.{}, .problem_score_milli = 0, .infrastructure_error = true }, cancel);
        };
    }
    const image_intent = if (ownership) |owner| try owner.journal.reserveKind(a, owner.run_id, .image) else null;
    const tag = if (image_intent) |intent| try a.dupe(u8, &intent.name()) else try std.fmt.allocPrint(a, "podtest-phase7-{x}", .{&nonce});
    if (client.inspectTag(a, tag, info_buf)) |_| return error.StandardTagConflict else |err| if (err != error.PodmanNotFound) return err;
    const labels = if (image_intent) |intent| try engine.janitor.imageLabels(a, intent) else "";
    const recipe = try std.fmt.allocPrint(a, "FROM {s}\nCOPY source /podtest-source\n{s}", .{ &base, labels });
    var remove_image = image_intent == null;
    defer if (remove_image) {
        cleanupImage(client, tag, info_buf, ownership, image_intent) catch |err|
            std.log.err("standard image cleanup failed: {s}", .{@errorName(err)});
    };
    const built = try client.buildTrusted(a, &.{ .{ .path = "Dockerfile", .contents = recipe }, .{ .path = "source", .contents = program, .executable = language == .cpp23 } }, tag, 30_000, Log.append, &log, cancellation);
    remove_image = true;
    try Progress.report(progress, .build_finished);
    try build_log.sync(io);
    const command: []const []const u8 = switch (language) {
        .posix_sh => &.{ "/bin/sh", "/podtest-source" },
        .javascript => &.{ "/usr/local/bin/node", "/podtest-source" },
        .cpp23 => &.{"/podtest-source"},
        .python314 => &.{ "/usr/local/bin/python3.14", "-I", "-B", "/podtest-source" },
    };
    const tests = try a.alloc(TestResult, task.tests.len);
    var scores: [contract.max_tests]contract.GroupScore = @splat(.{});
    const actual = try a.alloc(u8, @intCast(task.limits.output_bytes));
    for (task.tests, payloads, tests, 0..) |item, payload, *result, i| {
        try checkCancel(cancel);
        try Progress.report(progress, .{ .test_started = item.id });
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
        }}, &.{}, .{ .wall_ms = @min(300_000, task.limits.wall_ms + 10_000), .history_limit = task.limits.output_bytes, .cancellation = cancel, .ownership = ownership }, &measured, &.{});
        const exit = measured[0].exit;
        if (exit.cancelled) return error.PodmanCancelled;
        var points: u32 = 0;
        const verdict: Verdict = if (exit.timed_out) .wall_timeout else if (exit.output_limited) .output_limit else if (exit.oom_killed) .memory_limit else if (exit.code != 0) .runtime_error else blk: {
            const count = try history.readAt(.stdout, 0, actual);
            if (count != history.lengths[1]) return error.IncompleteStandardOutput;
            if (checker_id) |image_id| {
                const decision = try checkTestlib(backing, io, client, dir, name, image_id, task.testset, item.group, payload.input, actual[0..count], payload.answer, item.points_milli, cancel, ownership);
                points = decision.points;
                break :blk decision.verdict;
            }
            if (!contract.matches(task.checker, actual[0..count], payload.answer)) break :blk .wrong_answer;
            points = item.points_milli;
            break :blk .accepted;
        };
        if (verdict == .testing_error) {
            try cleanupImage(client, checker_tag.?, info_buf, ownership, checker_intent);
            checker_tag = null;
            try cleanupImage(client, tag, info_buf, ownership, image_intent);
            remove_image = false;
            return finish(io, a, outputs, .{ .version = 1, .tests = &.{}, .groups = &.{}, .problem_score_milli = 0, .infrastructure_error = true }, cancel);
        }
        scores[try contract.groupIndex(task.groups, item.group)].recordPoints(item.points_milli, points, verdict == .accepted);
        result.* = .{ .id = item.id, .verdict = verdict, .score_milli = points, .exit_code = exit.code, .metrics = measured[0].metrics };
    }
    const groups = try a.alloc(GroupResult, task.groups.len);
    var total: u64 = 0;
    for (task.groups, groups, 0..) |item, *result, i| {
        result.* = .{ .id = item.id, .score_milli = scores[i].value(item) };
        total += result.score_milli;
    }
    try checkCancel(cancel);
    if (checker_tag) |name| try cleanupImage(client, name, info_buf, ownership, checker_intent);
    checker_tag = null;
    try cleanupImage(client, tag, info_buf, ownership, image_intent);
    remove_image = false;
    try finish(io, a, outputs, .{ .version = 1, .tests = tests, .groups = groups, .problem_score_milli = total }, cancel);
}

fn checkTestlib(backing: std.mem.Allocator, io: std.Io, client: podman.Client, dir: std.Io.Dir, name: []const u8, image: podman.Id, testset: []const u8, test_group: []const u8, input: []const u8, actual: []const u8, answer: []const u8, points: u32, cancel: ?podman.Cancellation, ownership: ?group.Ownership) !testlib.Decision {
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const a = arena.allocator();
    const data = try testlib.pack(a, input, actual, answer);
    const modes = .{ .once, .once, .once };
    const cap = data.len + (64 << 10);
    try dir.createDir(io, "checker", .fromMode(0o700));
    const scratch = try dir.openDir(io, "checker", .{ .follow_symlinks = false });
    defer scratch.close(io);
    var history = try History.open(io, scratch, modes, cap);
    defer history.close();
    history.stream_limits[0] = data.len;
    const command = try std.mem.concat(a, []const u8, &.{ testlib.command, &.{ testset, test_group } });
    const checker_name = try std.fmt.allocPrint(a, "{s}-check", .{name});
    var measured: [1]group.Result = undefined;
    try group.run(a, io, client, &.{.{
        .spec = .{ .name = checker_name, .image = image, .command = command, .scratch = true },
        .limits = .{ .memory_bytes = 256 << 20, .pids = 32, .wall_ms = 20_000, .output_bytes = cap },
        .history = &history,
        .modes = modes,
        .input = data,
    }}, &.{}, .{ .wall_ms = 30_000, .history_limit = cap, .cancellation = cancel, .ownership = ownership }, &measured, &.{});
    const exit = measured[0].exit;
    if (exit.cancelled) return error.PodmanCancelled;
    if (exit.timed_out or exit.output_limited or exit.oom_killed or history.lengths[0] != data.len) return .{ .verdict = .testing_error };
    var bytes: [64 << 10]u8 = undefined;
    const n = try history.readAt(.stdout, 0, &bytes);
    return testlib.decide(exit.code, bytes[0..n], points);
}

fn compileCpp(a: std.mem.Allocator, io: std.Io, client: podman.Client, outputs: std.Io.Dir, image: podman.Id, source: []const u8, log: *Log, cancel: ?podman.Cancellation, ownership: ?group.Ownership) !?[]const u8 {
    const data = try testlib.packFiles(a, &.{"submission.cpp"}, &.{source});
    const command: []const []const u8 = &.{ "/bin/sh", "-ec", "umask 077; cd /tmp; tar -xf -; /usr/local/bin/g++ -std=c++23 -O2 submission.cpp -o submission; cat submission" };
    try outputs.createDir(io, "submission-compile", .fromMode(0o700));
    const dir = try outputs.openDir(io, "submission-compile", .{ .follow_symlinks = false });
    defer dir.close(io);
    const modes = .{ .once, .once, .once };
    const cap = data.len + (2 << 20);
    var history = try History.open(io, dir, modes, cap);
    defer history.close();
    history.stream_limits = .{ data.len, 1 << 20, 64 << 10 };
    var nonce: [12]u8 = undefined;
    try io.randomSecure(&nonce);
    var measured: [1]group.Result = undefined;
    try group.run(a, io, client, &.{.{
        .spec = .{ .name = try std.fmt.allocPrint(a, "podtest-compile-{x}", .{&nonce}), .image = image, .command = command, .scratch = true },
        .limits = .{ .memory_bytes = 512 << 20, .cpu_quota_micros = 200_000, .wall_ms = 60_000, .output_bytes = cap },
        .history = &history,
        .modes = modes,
        .input = data,
    }}, &.{}, .{ .wall_ms = 70_000, .history_limit = cap, .cancellation = cancel, .ownership = ownership }, &measured, &.{});
    const exit = measured[0].exit;
    if (exit.cancelled) return error.PodmanCancelled;
    const diagnostics = try a.alloc(u8, @intCast(history.lengths[2]));
    const diag_len = try history.readAt(.stderr, 0, diagnostics);
    if (diag_len != 0) try Log.append(log, diagnostics[0..diag_len]);
    if (exit.code != 0 or exit.timed_out or exit.oom_killed or exit.output_limited or history.lengths[1] == 0) {
        try Log.append(log, "C++ compilation failed or exceeded its limits");
        return null;
    }
    const binary = try a.alloc(u8, @intCast(history.lengths[1]));
    if (try history.readAt(.stdout, 0, binary) != binary.len) return error.IncompleteSubmissionBinary;
    return binary;
}

fn finish(io: std.Io, a: std.mem.Allocator, outputs: std.Io.Dir, result: report.Result, cancel: ?podman.Cancellation) !void {
    const json = try std.json.Stringify.valueAlloc(a, result, .{});
    const result_dir = try outputs.openDir(io, ".", .{ .iterate = true });
    defer result_dir.close(io);
    var file = try result_dir.createFileAtomic(io, "result.json", .{ .permissions = .fromMode(0o600) });
    defer file.deinit(io);
    try file.file.writePositionalAll(io, json, 0);
    try file.file.sync(io);
    try checkCancel(cancel);
    try file.link(io);
    while (true) switch (std.os.linux.errno(std.os.linux.fsync(result_dir.handle))) {
        .SUCCESS => break,
        .INTR => continue,
        else => return error.ResultDirectorySyncFailed,
    };
}

fn cleanupImage(client: podman.Client, tag: []const u8, scratch: []u8, ownership: ?group.Ownership, intent: ?engine.janitor.Record) !void {
    client.removeTag(tag, scratch) catch |err| if (err != error.PodmanNotFound) return err;
    if (intent) |record| try ownership.?.journal.finish(record);
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
