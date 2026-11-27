const std = @import("std");
const inputs = @import("../workspace/inputs.zig");
const upload = @import("../workspace/upload.zig");

pub const Identity = extern struct {
    invoker: [*:0]const u8,
    epoch: [*:0]const u8,
    attempt: [*:0]const u8,
    run: [*:0]const u8,
    token: [32]u8 = @splat(0),
};

pub const Claim = extern struct {
    expires: i64,
    token: [32]u8,
    source_sha: [32]u8,
    bundle_sha: [32]u8,
    source_size: u64,
    bundle_size: u64,
    source: [16384:0]u8,
    bundle: [16384:0]u8,

    pub fn artifacts(self: *const Claim) inputs.ClaimInputs {
        return .{
            .source = .{ .url = std.mem.sliceTo(&self.source, 0), .descriptor = .{ .bytes = self.source_size, .sha256 = self.source_sha } },
            .bundle = .{ .url = std.mem.sliceTo(&self.bundle, 0), .descriptor = .{ .bytes = self.bundle_size, .sha256 = self.bundle_sha } },
        };
    }
};

const Grant = extern struct {
    expires: i64,
    complete: c_int,
    id: [120:0]u8,
    url: [16384:0]u8,
    checksum: [44:0]u8,
    length: [20:0]u8,
};
const Renewed = extern struct { expires: i64, cancel_requested: c_int };

// The C buffers include their terminator; their Zig sentinel is the final slot.
comptime {
    std.debug.assert(@offsetOf(Claim, "bundle") - @offsetOf(Claim, "source") == 16385);
}

extern fn podtest_control_open([*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8) ?*anyopaque;
extern fn podtest_control_close(*anyopaque) void;
extern fn podtest_control_claim(*anyopaque, *Identity, c_int, *Claim) c_int;
extern fn podtest_control_heartbeat(*anyopaque, [*:0]const u8, u32, u32, u32, [*:0]const u8) c_int;
extern fn podtest_control_create(*anyopaque, *Identity, [*:0]const u8, [*:0]const u8, u64, *const [32]u8, *Grant) c_int;
extern fn podtest_control_complete(*anyopaque, *Identity, [*:0]const u8) c_int;
extern fn podtest_encode_artifact_event(*Identity, [*:0]const u8, [*:0]const u8, *const [16]u8, u64, i64, [*]u8, usize) usize;
extern fn podtest_encode_result_event(*Identity, [*:0]const u8, *const ResultFields, *const [16]u8, u64, i64, [*]u8, usize) usize;
extern fn podtest_encode_progress_event(*Identity, [*:0]const u8, c_uint, ?[*:0]const u8, *const [16]u8, u64, i64, [*]u8, usize) usize;
extern fn podtest_matches_artifact_event([*]const u8, usize, [*:0]const u8) c_int;
extern fn podtest_control_report(*anyopaque, [*]const u8, usize) c_int;
extern fn podtest_control_renew(*anyopaque, *Identity, *Renewed) c_int;

pub const ArtifactEvent = struct {
    identity: Identity,
    submission: [:0]const u8,
    artifact: [:0]const u8,
    timestamp_ms: i64,
    buffer: [1024]u8 = undefined,

    pub fn matchesPending(self: *const ArtifactEvent, wire: []const u8) !bool {
        return switch (podtest_matches_artifact_event(wire.ptr, wire.len, self.artifact)) {
            0 => false,
            1 => true,
            else => error.InvalidOutboxEvent,
        };
    }

    pub fn encode(self: *ArtifactEvent, _: []const u8, sequence: u64, event_id: [16]u8) ![]const u8 {
        const len = podtest_encode_artifact_event(&self.identity, self.submission, self.artifact, &event_id, sequence, self.timestamp_ms, &self.buffer, self.buffer.len);
        if (len == 0) return error.EventTooLarge;
        return self.buffer[0..len];
    }
};

const ResultFields = extern struct {
    test_id: ?[*:0]const u8 = null,
    subgroup_id: ?[*:0]const u8 = null,
    verdict: ?[*:0]const u8 = null,
    score: ?[*:0]const u8 = null,
    outcome: ?[*:0]const u8 = null,
};

pub const ProgressEvent = struct {
    pub const Kind = enum(c_uint) { run_started = 1, build_started = 2, build_finished = 4, test_started = 5 };

    identity: Identity,
    submission: [:0]const u8,
    timestamp_ms: i64,
    kind: Kind,
    test_id: ?[:0]const u8 = null,
    buffer: [1024]u8 = undefined,

    pub fn encode(self: *ProgressEvent, run_id: []const u8, sequence: u64, event_id: [16]u8) ![]const u8 {
        if (!std.mem.eql(u8, run_id, std.mem.span(self.identity.run))) return error.ResultRunMismatch;
        const test_id: ?[*:0]const u8 = if (self.test_id) |id| id.ptr else null;
        const len = podtest_encode_progress_event(&self.identity, self.submission, @backingInt(self.kind), test_id, &event_id, sequence, self.timestamp_ms, &self.buffer, self.buffer.len);
        if (len == 0) return error.EventTooLarge;
        return self.buffer[0..len];
    }
};

pub const ResultEvent = struct {
    identity: Identity,
    submission: [:0]const u8,
    timestamp_ms: i64,
    result: Result,
    buffer: [1024]u8 = undefined,

    pub const Result = union(enum) {
        test_finished: struct { id: [:0]const u8, verdict: [:0]const u8, score_milli: u64 },
        subgroup_score: struct { id: [:0]const u8, score_milli: u64 },
        problem_score: u64,
        success: [:0]const u8,
        infrastructure_error,
        timeout,
        cancelled,
    };

    pub fn encode(self: *ResultEvent, run_id: []const u8, sequence: u64, event_id: [16]u8) ![]const u8 {
        if (!std.mem.eql(u8, run_id, std.mem.span(self.identity.run))) return error.ResultRunMismatch;
        var score: [32]u8 = undefined;
        const fields: ResultFields = switch (self.result) {
            .test_finished => |test_result| .{ .test_id = test_result.id, .verdict = test_result.verdict, .score = try decimal(&score, test_result.score_milli) },
            .subgroup_score => |group| .{ .subgroup_id = group.id, .score = try decimal(&score, group.score_milli) },
            .problem_score => |points| .{ .score = try decimal(&score, points) },
            .success => |verdict| .{ .outcome = "success", .verdict = verdict },
            .infrastructure_error => .{ .outcome = "infrastructure_error" },
            .timeout => .{ .outcome = "timeout" },
            .cancelled => .{ .outcome = "cancelled" },
        };
        const len = podtest_encode_result_event(&self.identity, self.submission, &fields, &event_id, sequence, self.timestamp_ms, &self.buffer, self.buffer.len);
        if (len == 0) return error.EventTooLarge;
        return self.buffer[0..len];
    }

    pub fn successEncoder(self: *ResultEvent) !SuccessEncoder {
        if (self.result != .success) return error.ExpectedSuccessfulResult;
        return .{ .event = self };
    }

    pub const SuccessEncoder = struct {
        event: *ResultEvent,

        pub fn encode(self: SuccessEncoder, run_id: []const u8, sequence: u64, event_id: [16]u8, _: []const []u8) ![]const u8 {
            if (self.event.result != .success) return error.ExpectedSuccessfulResult;
            return self.event.encode(run_id, sequence, event_id);
        }
    };

    fn decimal(buffer: []u8, score_milli: u64) ![:0]const u8 {
        return std.fmt.bufPrintSentinel(buffer, "{d}.{d:0>3}", .{ score_milli / 1000, score_milli % 1000 }, 0);
    }
};

test "result event encodes exact decimal score and distinct protobuf kinds" {
    var event: ResultEvent = .{
        .identity = .{ .invoker = "invoker", .epoch = "epoch", .attempt = "attempt", .run = "run", .token = @splat(1) },
        .submission = "submission",
        .timestamp_ms = 1,
        .result = .{ .test_finished = .{ .id = "test-1", .verdict = "accepted", .score_milli = 500 } },
    };
    const event_id: [16]u8 = @splat(1);
    try std.testing.expectError(error.ExpectedSuccessfulResult, event.successEncoder());
    try std.testing.expectError(error.ResultRunMismatch, event.encode("other", 1, event_id));
    const suffixes = [_]struct { ResultEvent.Result, []const u8 }{
        .{ event.result, "\x48\x06\x52\x08accepted\x5a\x05" ++ "0.500\x62\x06test-1" },
        .{ .{ .subgroup_score = .{ .id = "group-1", .score_milli = 5 } }, "\x48\x07\x5a\x05" ++ "0.005\x6a\x07group-1" },
        .{ .{ .problem_score = 1001 }, "\x48\x08\x5a\x05" ++ "1.001" },
        .{ .{ .success = "accepted" }, "\x48\x0d\x52\x08accepted" },
    };
    for (suffixes) |sample| {
        event.result = sample[0];
        const wire = try event.encode("run", 1, event_id);
        const kind_offset = std.mem.indexOf(u8, wire, "\x40\x01\x48").? + 2;
        try std.testing.expectEqualSlices(u8, sample[1], wire[kind_offset..][0..sample[1].len]);
        if (event.result == .success) {
            const encoder = try event.successEncoder();
            var artifact = "artifact".*;
            const terminal = try encoder.encode("run", 1, event_id, &.{&artifact});
            try std.testing.expect(std.mem.endsWith(u8, terminal, "\x82\x01\x07success"));
        }
    }
}

pub const Channel = struct {
    handle: *anyopaque,
    allocator: std.mem.Allocator,

    pub fn open(endpoint: [:0]const u8, ca: [:0]const u8, cert: [:0]const u8, key: [:0]const u8) !Channel {
        return .{ .handle = podtest_control_open(endpoint, ca, cert, key) orelse return error.ControlSetupFailed, .allocator = std.heap.page_allocator };
    }

    pub fn close(self: Channel) void {
        podtest_control_close(self.handle);
    }

    pub fn report(self: Channel, wire: []const u8) !void {
        try status(podtest_control_report(self.handle, wire.ptr, wire.len));
    }

    pub fn renew(self: Channel, identity: *Identity) !Renewed {
        var result: Renewed = undefined;
        try status(podtest_control_renew(self.handle, identity, &result));
        return result;
    }

    pub fn claim(self: Channel, identity: *Identity, refresh: bool, out: *Claim) !void {
        try status(podtest_control_claim(self.handle, identity, @intFromBool(refresh), out));
    }

    pub fn heartbeat(self: Channel, invoker: [:0]const u8, capacity: u32, load: u32, formats: [:0]const u8) !void {
        try status(podtest_control_heartbeat(self.handle, invoker, 1, capacity, load, formats));
    }
};

pub const Upload = struct {
    channel: Channel,
    invoker_id: []const u8,
    identity: Identity = undefined,
    fields: [6][121:0]u8 = undefined,
    grant: Grant = undefined,

    pub fn create(self: *Upload, pending: upload.Pending) !upload.Target {
        if (!std.mem.eql(u8, pending.invoker_id, self.invoker_id)) return error.UploadIdentityMismatch;
        const strings = [_][]const u8{ pending.invoker_id, pending.process_epoch, pending.attempt_id, pending.run_id, pending.client_id, pending.kind };
        for (strings, &self.fields) |value, *field| {
            if (value.len == 0 or value.len >= field.len or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidUploadIntent;
            @memcpy(field[0..value.len], value);
            field[value.len] = 0;
        }
        self.identity = .{ .invoker = &self.fields[0], .epoch = &self.fields[1], .attempt = &self.fields[2], .run = &self.fields[3], .token = pending.fencing_token };
        try status(podtest_control_create(self.channel.handle, &self.identity, &self.fields[4], &self.fields[5], pending.descriptor.bytes, &pending.descriptor.sha256, &self.grant));
        return .{ .id = std.mem.sliceTo(&self.grant.id, 0), .url = std.mem.sliceTo(&self.grant.url, 0), .expires_ms = self.grant.expires, .checksum = std.mem.sliceTo(&self.grant.checksum, 0), .content_length = std.mem.sliceTo(&self.grant.length, 0), .complete = self.grant.complete != 0 };
    }

    pub fn complete(self: *Upload, id: []const u8) !void {
        if (id.len == 0 or id.len > 120 or std.mem.indexOfScalar(u8, id, 0) != null) return error.InvalidUploadTarget;
        const artifact = try self.channel.allocator.dupeSentinel(u8, id, 0);
        defer self.channel.allocator.free(artifact);
        const rc = podtest_control_complete(self.channel.handle, &self.identity, artifact);
        if (rc == 5) return error.UploadMissing;
        try status(rc);
    }
};

fn status(rc: c_int) !void {
    return switch (rc) {
        0 => {},
        4, 8, 14 => error.ControlRetry,
        9 => error.LeaseInactive,
        7, 16 => error.ControlUnauthorized,
        -1 => error.InvalidControlResponse,
        else => error.ControlRejected,
    };
}
