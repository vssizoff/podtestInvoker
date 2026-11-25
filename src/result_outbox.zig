//! The execution engine must use this entry point for a successful terminal
//! event. The artifact-only daemon does not produce execution results.
const std = @import("std");
const wal = @import("control/outbox.zig");
const upload = @import("workspace/upload.zig");

pub fn enqueueSuccess(outbox: *wal.Outbox, allocator: std.mem.Allocator, journal: *upload.Journal, run: upload.Pending, required_client_ids: []const []const u8, encoder: anytype) !u64 {
    return enqueue(outbox, allocator, journal, run, required_client_ids, null, encoder);
}

/// Resume a terminal event at the ordinal reserved by a durable result plan.
pub fn enqueueSuccessAt(outbox: *wal.Outbox, allocator: std.mem.Allocator, journal: *upload.Journal, run: upload.Pending, required_client_ids: []const []const u8, ordinal: u64, encoder: anytype) !u64 {
    return enqueue(outbox, allocator, journal, run, required_client_ids, ordinal, encoder);
}

fn enqueue(outbox: *wal.Outbox, allocator: std.mem.Allocator, journal: *upload.Journal, run: upload.Pending, required_client_ids: []const []const u8, ordinal: ?u64, encoder: anytype) !u64 {
    const refs = try allocator.alloc([]u8, required_client_ids.len);
    var loaded: usize = 0;
    defer {
        for (refs[0..loaded]) |ref| allocator.free(ref);
        allocator.free(refs);
    }
    for (required_client_ids) |id| {
        const intent = journal.load(allocator, id) catch |err| switch (err) {
            error.FileNotFound => return error.RequiredArtifactUnconfirmed,
            else => return err,
        };
        defer intent.deinit();
        const p = intent.value;
        if (!std.mem.eql(u8, p.run_id, run.run_id) or !std.mem.eql(u8, p.attempt_id, run.attempt_id) or
            !std.mem.eql(u8, p.invoker_id, run.invoker_id) or !std.mem.eql(u8, p.process_epoch, run.process_epoch) or
            !std.mem.eql(u8, &p.fencing_token, &run.fencing_token)) return error.RequiredArtifactWrongLease;
        refs[loaded] = journal.confirmed(allocator, id) catch |err| switch (err) {
            error.FileNotFound => return error.RequiredArtifactUnconfirmed,
            else => return err,
        };
        loaded += 1;
        if (!try journal.reportRecorded(allocator, id)) return error.RequiredArtifactReportNotRecorded;
    }
    const Encoder = struct {
        refs: []const []u8,
        base: @TypeOf(encoder),
        pub fn encode(self: @This(), run_id: []const u8, sequence: u64, event_id: [16]u8) ![]const u8 {
            return self.base.encode(run_id, sequence, event_id, self.refs);
        }
    };
    const gated: Encoder = .{ .refs = refs, .base = encoder };
    if (ordinal) |sequence| return outbox.enqueueAt(allocator, run.run_id, sequence, gated);
    return outbox.enqueue(allocator, run.run_id, gated);
}

test "missing receipt gates the WAL and does not consume the first sequence" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try temp.dir.setPermissions(io, .fromMode(0o700));
    const path = try temp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);
    var journal = try upload.Journal.open(io, path);
    defer journal.close();
    var outbox = try wal.Outbox.open(io, path, 4096);
    defer outbox.close();
    const intent: upload.Pending = .{ .invoker_id = "node", .process_epoch = "epoch", .attempt_id = "attempt", .run_id = "run", .fencing_token = @splat(1), .client_id = "log", .kind = "runner_log", .descriptor = .{ .bytes = 0, .sha256 = @splat(0) } };
    try journal.save(intent);
    const Encoder = struct {
        pub fn encode(_: @This(), _: []const u8, sequence: u64, _: [16]u8, refs: []const []u8) ![]const u8 {
            try std.testing.expectEqual(@as(u64, 1), sequence);
            try std.testing.expectEqual(@as(usize, 1), refs.len);
            return refs[0];
        }
    };
    try std.testing.expectError(error.RequiredArtifactUnconfirmed, enqueueSuccess(&outbox, a, &journal, intent, &.{"log"}, Encoder{}));
    var other = intent;
    other.fencing_token[0] = 2;
    try std.testing.expectError(error.RequiredArtifactWrongLease, enqueueSuccess(&outbox, a, &journal, other, &.{"log"}, Encoder{}));
    const Fixture = struct {
        pub fn create(_: @This(), _: upload.Pending) !upload.Target {
            return .{ .id = "backend-artifact", .url = "", .checksum = "", .content_length = "", .expires_ms = 0, .complete = true };
        }
        pub fn complete(_: @This(), _: []const u8) error{UploadMissing}!void {
            unreachable;
        }
    };
    try temp.dir.createDir(io, "spool", .fromMode(0o700));
    const spool_path = try std.fs.path.join(a, &.{ path, "spool" });
    defer a.free(spool_path);
    try journal.recover(a, spool_path, "log", .{ .origin = "https://example.invalid", .timeout_ms = 100, .byte_budget = 10 }, Fixture{});
    try std.testing.expectError(error.RequiredArtifactReportNotRecorded, enqueueSuccess(&outbox, a, &journal, intent, &.{"log"}, Encoder{}));
    try journal.markReportRecorded(a, "log");
    try std.testing.expectEqual(@as(u64, 1), try enqueueSuccess(&outbox, a, &journal, intent, &.{"log"}, Encoder{}));
    try std.testing.expectEqual(@as(u64, 1), try enqueueSuccessAt(&outbox, a, &journal, intent, &.{"log"}, 1, Encoder{}));
    const records = try outbox.replay(a);
    defer wal.freeRecords(a, records);
    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expect(std.mem.endsWith(u8, records[0].payload, "backend-artifact"));
}
