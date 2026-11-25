const std = @import("std");
const extract = @import("extract");
const executor = @import("executor.zig");
const podman = @import("engine").podman;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const socket = init.environ_map.get("PODTEST_PODMAN_SOCKET") orelse return error.ExpectedRootlessSocket;
    const sh = init.environ_map.get("PODTEST_TEST_IMAGE_ID") orelse return error.ExpectedLocalAlpineImageId;
    const js = init.environ_map.get("PODTEST_TEST_NODE_IMAGE_ID") orelse return error.ExpectedLocalNodeImageId;
    if (sh.len != 64 or js.len != 64) return error.InvalidFixtureImageId;
    const client: podman.Client = .{ .socket = try a.dupeSentinel(u8, socket, 0), .api_version = "6.2.0" };
    var nonce: [12]u8 = undefined;
    try io.randomSecure(&nonce);
    const name = try std.fmt.allocPrint(a, "podtest-phase7-fixture-{x}", .{&nonce});
    const cwd = std.Io.Dir.cwd();
    try cwd.createDir(io, name, .fromMode(0o700));
    defer cwd.deleteTree(io, name) catch |err| std.log.err("fixture cleanup failed: {s}", .{@errorName(err)});
    const parent = try cwd.openDir(io, name, .{});
    defer parent.close(io);

    const images: executor.Images = .{ .posix_sh = sh[0..64].*, .javascript = js[0..64].* };
    try check(init, client, parent, images, false);
    try check(init, client, parent, images, true);
    std.log.info("Standard v1 USTAR and rootless judging acceptance passed for shell and JavaScript", .{});
}

fn check(init: std.process.Init, client: podman.Client, parent: std.Io.Dir, images: executor.Images, js: bool) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const inputs_name = if (js) "js-inputs" else "sh-inputs";
    const outputs_name = if (js) "js-outputs" else "sh-outputs";
    const source = if (js) "process.stdout.write(require('node:fs').readFileSync(0));" else "IFS= read -r mode; case $mode in timeout) exec sleep 30;; output) exec yes;; error) exit 42;; esac; exec cat";
    const input_a = if (js) "a\x00b\n" else "echo\n \ta\x00b\r\n";
    const input_b = if (js) "wrong\n" else "echo\nwrong\n";
    const task = try std.fmt.allocPrint(a,
        \\{{"version":1,"language":"{s}","build":"package_source","checker":"{s}",
        \\"limits":{{"wall_ms":800,"output_bytes":4096}},
        \\"groups":[{{"id":"partial","scoring":"sum"}},{{"id":"whole","scoring":"all_or_nothing"}}],
        \\"tests":[
        \\{{"id":"a","group":"partial","input":"tests/a","answer":"tests/answer","points_milli":1001}},
        \\{{"id":"b","group":"whole","input":"tests/b","answer":"tests/answer","points_milli":2000}},
        \\{{"id":"c","group":"whole","input":"tests/a","answer":"tests/answer","points_milli":3000}}{s}]}}
    , .{
        if (js) "javascript" else "posix_sh",
        if (js) "exact_bytes" else "ascii_tokens",
        if (js) "" else
            \\,{"id":"t","group":"partial","input":"tests/timeout","answer":"tests/answer","points_milli":100},
            \\{"id":"o","group":"partial","input":"tests/output","answer":"tests/answer","points_milli":100},
            \\{"id":"e","group":"partial","input":"tests/error","answer":"tests/answer","points_milli":100}
    });
    const entries = [_]podman.ContextFile{
        .{ .path = "standard.json", .contents = task },
        .{ .path = "tests/a", .contents = input_a },
        .{ .path = "tests/answer", .contents = "a\x00b\n" },
        .{ .path = "tests/b", .contents = input_b },
        .{ .path = "tests/error", .contents = "error\n" },
        .{ .path = "tests/output", .contents = "output\n" },
        .{ .path = "tests/timeout", .contents = "timeout\n" },
    };
    const Descriptor = struct { path: []const u8, size: usize, sha256: [64]u8 };
    var descriptors: [entries.len]Descriptor = undefined;
    for (entries, &descriptors) |entry, *desc| desc.* = .{ .path = entry.path, .size = entry.contents.len, .sha256 = std.fmt.bytesToHex(digest(entry.contents), .lower) };
    const manifest = try std.json.Stringify.valueAlloc(a, .{ .format_version = @as(u32, 1), .execution_format = "standard", .execution_format_version = @as(u32, 1), .files = descriptors }, .{});
    const archive = try podman.packContext(a, &([_]podman.ContextFile{.{ .path = "manifest.json", .contents = manifest }} ++ entries));
    var tar = std.Io.Reader.fixed(archive);
    var submission = std.Io.Reader.fixed(source);
    try extract.materializeInputs(io, parent, inputs_name, a, .{ .entries = 32, .archive_bytes = 64 << 10, .unpacked_bytes = 64 << 10, .depth = 8, .path_bytes = 128 }, &tar, archive.len, digest(archive), "standard", 1, .{ .reader = &submission, .bytes = source.len, .sha256 = digest(source) });
    const inputs = try parent.openDir(io, inputs_name, .{});
    defer inputs.close(io);
    try parent.createDir(io, outputs_name, .fromMode(0o700));
    const outputs = try parent.openDir(io, outputs_name, .{});
    defer outputs.close(io);
    try executor.run(a, io, client, inputs, outputs, images, null);
    const result = try outputs.readFileAlloc(io, "result.json", a, .limited(64 << 10));
    const parsed = try std.json.parseFromSliceLeaky(struct { version: u32, tests: []executor.TestResult, groups: []executor.GroupResult, problem_score_milli: u64 }, a, result, .{});
    const expected: []const executor.Verdict = if (js) &.{ .accepted, .wrong_answer, .accepted } else &.{ .accepted, .wrong_answer, .accepted, .wall_timeout, .output_limit, .runtime_error };
    if (parsed.version != 1 or parsed.tests.len != expected.len or parsed.groups.len != 2 or parsed.problem_score_milli != 1001 or parsed.groups[0].score_milli != 1001 or parsed.groups[1].score_milli != 0) return error.InvalidFixtureScore;
    for (parsed.tests, expected) |actual, verdict| {
        if (actual.verdict != verdict) {
            std.log.err("test {s}: expected {t}, got {t} (exit {d})", .{ actual.id, verdict, actual.verdict, actual.exit_code });
            return error.UnexpectedStandardVerdict;
        }
    }

    if (!js) {
        try parent.createDir(io, "cancelled-outputs", .fromMode(0o700));
        const cancelled_outputs = try parent.openDir(io, "cancelled-outputs", .{});
        defer cancelled_outputs.close(io);
        var cancellation: CancelBeforeSecondTest = .{ .io = io, .outputs = cancelled_outputs };
        executor.run(a, io, client, inputs, cancelled_outputs, images, .{
            .check = CancelBeforeSecondTest.check,
            .context = &cancellation,
        }) catch |err| switch (err) {
            error.GroupCancelled => {
                cancelled_outputs.access(io, "result.json", .{}) catch |access_err| {
                    if (access_err == error.FileNotFound) return;
                    return access_err;
                };
                return error.CancelledRunPublishedResult;
            },
            else => return err,
        };
        return error.ExpectedStandardCancellation;
    }
}

const CancelBeforeSecondTest = struct {
    io: std.Io,
    outputs: std.Io.Dir,

    fn check(context: *anyopaque) bool {
        const self: *CancelBeforeSecondTest = @ptrCast(@alignCast(context));
        self.outputs.access(self.io, "test-1", .{}) catch return false;
        return true;
    }
};

fn digest(bytes: []const u8) [32]u8 {
    var value: [32]u8 = undefined;
    Sha256.hash(bytes, &value, .{});
    return value;
}
