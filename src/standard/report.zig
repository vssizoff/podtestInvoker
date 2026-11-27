const std = @import("std");
const rpc = @import("../control/artifact_rpc.zig");
const Outbox = @import("../control/outbox.zig").Outbox;
const upload = @import("../workspace/upload.zig");
const gate = @import("../result_outbox.zig");
const Result = @import("result.zig").Result;

/// Retry with the same immutable result, artifact list and first ordinal.
/// Artifact events must already own the preceding ordinals for this run.
pub fn enqueue(box: *Outbox, a: std.mem.Allocator, journal: *upload.Journal, run: upload.Pending, required: []const []const u8, submission: [:0]const u8, stamp: i64, first: u64, result: Result) !void {
    if (result.version != 1 or first == 0 or (result.infrastructure_error and result.compilation_error) or
        (if (result.infrastructure_error or result.compilation_error) result.tests.len != 0 or result.groups.len != 0 or result.problem_score_milli != 0 else result.tests.len == 0 or result.tests.len > 64 or result.groups.len > result.tests.len)) return error.InvalidStandardResult;
    const terminal = try std.math.add(u64, first, result.tests.len + result.groups.len + 1);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var event: rpc.ResultEvent = .{
        .identity = .{
            .invoker = try scratch.dupeSentinel(u8, run.invoker_id, 0),
            .epoch = try scratch.dupeSentinel(u8, run.process_epoch, 0),
            .attempt = try scratch.dupeSentinel(u8, run.attempt_id, 0),
            .run = try scratch.dupeSentinel(u8, run.run_id, 0),
            .token = run.fencing_token,
        },
        .submission = submission,
        .timestamp_ms = stamp,
        .result = undefined,
    };
    if (result.infrastructure_error) {
        event.result = .infrastructure_error;
        _ = try box.enqueueAt(a, run.run_id, first, &event);
        return;
    }
    var sequence = first;
    for (result.tests) |item| {
        event.result = .{ .test_finished = .{ .id = try scratch.dupeSentinel(u8, item.id, 0), .verdict = @tagName(item.verdict), .score_milli = item.score_milli } };
        _ = try box.enqueueAt(a, run.run_id, sequence, &event);
        sequence += 1;
    }
    for (result.groups) |item| {
        event.result = .{ .subgroup_score = .{ .id = try scratch.dupeSentinel(u8, item.id, 0), .score_milli = item.score_milli } };
        _ = try box.enqueueAt(a, run.run_id, sequence, &event);
        sequence += 1;
    }
    event.result = .{ .problem_score = result.problem_score_milli };
    _ = try box.enqueueAt(a, run.run_id, sequence, &event);
    event.result = .{ .success = @tagName(result.verdict()) };
    _ = try gate.enqueueSuccessAt(box, a, journal, run, required, terminal, try event.successEncoder());
}

test "reopening Standard reporting does not duplicate pending or acknowledged events" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try temp.dir.setPermissions(io, .fromMode(0o700));
    const path = try temp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);
    var journal = try upload.Journal.open(io, path);
    defer journal.close();
    const run: upload.Pending = .{ .invoker_id = "node", .process_epoch = "epoch", .attempt_id = "attempt", .run_id = "run", .fencing_token = @splat(1), .client_id = "log", .kind = "build_log", .descriptor = .{ .bytes = 0, .sha256 = @splat(0) } };
    try journal.save(run);
    const result: Result = .{ .version = 1, .tests = &.{.{ .id = "t", .verdict = .wrong_answer, .score_milli = 0, .exit_code = 0, .metrics = null }}, .groups = &.{.{ .id = "g", .score_milli = 0 }}, .problem_score_milli = 0 };
    const Reporter = struct {
        pub fn report(_: @This(), _: []const u8) !void {}
    };
    {
        var box = try Outbox.open(io, path, 8192);
        defer box.close();
        var artifact: rpc.ArtifactEvent = .{
            .identity = .{ .invoker = "node", .epoch = "epoch", .attempt = "attempt", .run = "run", .token = @splat(1) },
            .submission = "submission",
            .artifact = "backend-log",
            .timestamp_ms = 1,
        };
        _ = try box.enqueue(a, "run", &artifact);
        try std.testing.expectError(error.RequiredArtifactUnconfirmed, enqueue(&box, a, &journal, run, &.{"log"}, "submission", 1, 2, result));
        try std.testing.expectEqual(@as(usize, 4), try box.flush(a, Reporter{}));
        try box.compact(a);
    }
    const ArtifactControl = struct {
        pub fn create(_: @This(), _: upload.Pending) !upload.Target {
            return .{ .id = "backend-log", .url = "", .checksum = "", .content_length = "", .expires_ms = 0, .complete = true };
        }

        pub fn complete(_: @This(), _: []const u8) error{UploadMissing}!void {
            unreachable;
        }
    };
    try temp.dir.createDir(io, "spool", .fromMode(0o700));
    const spool_path = try std.fs.path.join(a, &.{ path, "spool" });
    defer a.free(spool_path);
    try journal.recover(a, spool_path, "log", .{ .origin = "https://example.invalid", .timeout_ms = 100, .byte_budget = 10 }, ArtifactControl{});
    try journal.markReportRecorded(a, "log");
    var box = try Outbox.open(io, path, 8192);
    defer box.close();
    try enqueue(&box, a, &journal, run, &.{"log"}, "submission", 1, 2, result);
    try enqueue(&box, a, &journal, run, &.{"log"}, "submission", 1, 2, result);
    try std.testing.expectEqual(@as(usize, 1), try box.flush(a, Reporter{}));
}
