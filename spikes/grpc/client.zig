const std = @import("std");
const pb = @import("control-pb.zig");
const lease_pb = @import("lease-pb.zig");
const journal = @import("outbox.zig");
const lease_state = @import("lease.zig");
const ProtoEventEncoder = struct {
    event: *pb.Podtest__Invoker__V1__Event,
    buffer: [256]u8 = undefined,
    pub fn encode(self: *@This(), run_id: []const u8, sequence: u64, event_id: [16]u8) ![]const u8 {
        if (!std.mem.eql(u8, run_id, "run")) return error.InvalidFixtureRunId;
        var event = self.event.*;
        event.run_id = @constCast("run");
        event.sequence = sequence;
        event.event_id = .{ .len = event_id.len, .data = @constCast(&event_id) };
        const size = pb.podtest__invoker__v1__event__get_packed_size(&event);
        if (size > self.buffer.len) return error.EventTooLarge;
        const length = pb.podtest__invoker__v1__event__pack(&event, &self.buffer);
        return self.buffer[0..length];
    }
};

extern fn rpc([*:0]const u8, [*:0]const u8, [*]const u8, usize, [*]u8, usize, *usize) c_int;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4) return error.ExpectedTargetStateAndMode;
    const target = args[1];
    var outbox = try journal.Outbox.open(init.io, args[2], 4096);
    defer outbox.close();
    const reporter: Reporter = .{ .target = target };
    if (std.mem.eql(u8, args[3], "replay")) {
        try std.testing.expectEqual(@as(u64, 1), outbox.sequence);
        try std.testing.expectEqual(@as(usize, 1), try outbox.flush(init.gpa, reporter));
        try outbox.compact(init.gpa);
        return;
    }
    if (std.mem.eql(u8, args[3], "verify-empty")) {
        try std.testing.expectEqual(@as(u64, 1), outbox.sequence);
        try std.testing.expectEqual(@as(usize, 0), try outbox.flush(init.gpa, reporter));
        return;
    }
    if (std.mem.eql(u8, args[3], "lease-fixture")) {
        try exerciseLeaseFixture(target);
        return;
    }
    if (!std.mem.eql(u8, args[3], "enqueue")) return error.InvalidMode;
    var response: [512]u8 = undefined;
    var input: [512]u8 = undefined;
    var length: usize = 0;

    var heartbeat = std.mem.zeroes(pb.Podtest__Invoker__V1__HeartbeatRequest);
    pb.podtest__invoker__v1__heartbeat_request__init(&heartbeat);
    var formats = [_][*c]u8{ @constCast("standard"), @constCast("scripted_lua") };
    heartbeat.invoker_id = @constCast("spike");
    heartbeat.protocol_version = 1;
    heartbeat.n_execution_formats = formats.len;
    heartbeat.execution_formats = &formats;
    heartbeat.capacity = 4;
    heartbeat.load = 2;
    const heartbeat_length = pb.podtest__invoker__v1__heartbeat_request__pack(&heartbeat, &input);
    if (rpc(target, "/podtest.invoker.v1.Control/Heartbeat", &input, heartbeat_length, &response, response.len, &length) != 0) return error.HeartbeatFailed;
    try std.testing.expect(try decodeAck(response[0..length]));

    var claim = std.mem.zeroes(pb.Podtest__Invoker__V1__ClaimRequest);
    pb.podtest__invoker__v1__claim_request__init(&claim);
    claim.invoker_id = @constCast("spike");
    claim.attempt_id = @constCast("attempt");
    claim.run_id = @constCast("run");
    const claim_length = pb.podtest__invoker__v1__claim_request__pack(&claim, &input);
    const method = "/podtest.invoker.v1.Control/Claim";
    if (rpc(target, method, &input, claim_length, &response, response.len, &length) != 0) return error.ClaimFailed;
    const unpacked = pb.podtest__invoker__v1__claim_response__unpack(null, length, &response) orelse return error.InvalidClaimResponse;
    defer pb.podtest__invoker__v1__claim_response__free_unpacked(unpacked, null);
    if (unpacked.*.lease_expires_unix != 1800000000 or
        !std.mem.eql(u8, std.mem.span(unpacked.*.source_url), "https://invalid.example/source") or
        !std.mem.eql(u8, std.mem.span(unpacked.*.bundle_url), "https://invalid.example/bundle")) return error.InvalidClaimResponse;
    if (rpc(target, method, &input, 0, &response, response.len, &length) != 3) return error.ExpectedInvalidArgument;
    claim.run_id = @constCast("wait-for-deadline");
    const delayed_length = pb.podtest__invoker__v1__claim_request__pack(&claim, &input);
    if (rpc(target, method, &input, delayed_length, &response, response.len, &length) != 4) return error.ExpectedDeadlineExceeded;

    var event = std.mem.zeroes(pb.Podtest__Invoker__V1__Event);
    pb.podtest__invoker__v1__event__init(&event);
    event.attempt_id = @constCast("attempt");
    event.submission_id = @constCast("submission");
    event.invoker_id = @constCast("spike");
    event.schema_version = 1;
    event.occurred_at_unix_millis = 1800000000000;
    event.kind = pb.PODTEST__INVOKER__V1__EVENT__KIND__TEST_FINISHED;
    event.verdict = @constCast("OK");
    event.score_presence_case = pb.PODTEST__INVOKER__V1__EVENT__SCORE_PRESENCE_SCORE;
    event.unnamed_0.score = @constCast("1.125");
    event.test_id = @constCast("test");
    event.subgroup_id = @constCast("subgroup");
    event.artifact_id = @constCast("artifact");
    var event_encoder: ProtoEventEncoder = .{ .event = &event };
    try std.testing.expectEqual(@as(u64, 1), try outbox.enqueue(init.gpa, "run", &event_encoder));
    try std.testing.expectError(error.BackendUnavailable, outbox.flush(init.gpa, reporter));
    try std.testing.expectEqual(@as(u64, 1), outbox.pending_events);
}

fn exerciseLeaseFixture(target: [:0]const u8) !void {
    var token = [_]u8{ 0, 1 };
    var lease = std.mem.zeroes(lease_pb.Podtest__Invoker__V1__RunLease);
    lease_pb.podtest__invoker__v1__run_lease__init(&lease);
    lease.invoker_id = @constCast("spike");
    lease.process_epoch = @constCast("epoch");
    lease.attempt_id = @constCast("attempt");
    lease.run_id = @constCast("run");
    lease.fencing_token = .{ .len = token.len, .data = &token };
    var renew = std.mem.zeroes(lease_pb.Podtest__Invoker__V1__RenewLeaseRequest);
    lease_pb.podtest__invoker__v1__renew_lease_request__init(&renew);
    renew.lease = &lease;
    var request: [256]u8 = undefined;
    var response: [256]u8 = undefined;
    var length: usize = 0;
    const request_len = lease_pb.podtest__invoker__v1__renew_lease_request__pack(&renew, &request);
    const renew_method = "/podtest.invoker.v1.LeaseFixture/RenewLease";
    if (rpc(target, renew_method, &request, request_len, &response, response.len, &length) != 0) return error.RenewLeaseFailed;
    const renewed = lease_pb.podtest__invoker__v1__renew_lease_response__unpack(null, length, &response) orelse return error.InvalidRenewal;
    defer lease_pb.podtest__invoker__v1__renew_lease_response__free_unpacked(renewed, null);
    if (renewed.*.lease_expires_unix != 1800000030) return error.InvalidRenewal;
    const identity = fromWireLease(&lease);
    const now: lease_state.Time = .{ .unix_seconds = 1799999990, .monotonic_ns = 0 };
    var guard = try lease_state.Guard.init(identity, 1800000000, now);
    try guard.renew(identity, renewed.*.lease_expires_unix, now);
    token[1] = 2;
    const stale_len = lease_pb.podtest__invoker__v1__renew_lease_request__pack(&renew, &request);
    try std.testing.expectEqual(@as(c_int, 9), rpc(target, renew_method, &request, stale_len, &response, response.len, &length));
    token[1] = 1;

    var watcher = std.mem.zeroes(lease_pb.Podtest__Invoker__V1__WatchCommandsRequest);
    lease_pb.podtest__invoker__v1__watch_commands_request__init(&watcher);
    watcher.invoker_id = @constCast("spike");
    watcher.process_epoch = @constCast("epoch");
    const watch_len = lease_pb.podtest__invoker__v1__watch_commands_request__pack(&watcher, &request);
    // The fixture sends exactly one item and closes the stream. This is not a
    // reader for a long-lived WatchCommands stream.
    if (rpc(target, "/podtest.invoker.v1.LeaseFixture/WatchCommands", &request, watch_len, &response, response.len, &length) != 0) return error.WatchCommandsFailed;
    const decoded = lease_pb.podtest__invoker__v1__command__unpack(null, length, &response) orelse return error.InvalidCommand;
    defer lease_pb.podtest__invoker__v1__command__free_unpacked(decoded, null);
    if (decoded.*.payload_case != lease_pb.PODTEST__INVOKER__V1__COMMAND__PAYLOAD_CANCEL_RUN or
        !std.mem.eql(u8, std.mem.span(decoded.*.command_id), "cancel-1")) return error.InvalidCommand;
    const cancel = decoded.*.unnamed_0.cancel_run;
    if (cancel == null or cancel.*.lease == null or !guard.cancel(fromWireLease(cancel.*.lease), now)) return error.InvalidCancellation;
    try std.testing.expectError(error.LeaseInactive, guard.renew(identity, 1800000040, now));
}

fn fromWireLease(lease: *const lease_pb.Podtest__Invoker__V1__RunLease) lease_state.Identity {
    return .{
        .invoker_id = std.mem.span(lease.invoker_id),
        .process_epoch = std.mem.span(lease.process_epoch),
        .attempt_id = std.mem.span(lease.attempt_id),
        .run_id = std.mem.span(lease.run_id),
        .token = if (lease.fencing_token.len == 0) &.{} else lease.fencing_token.data[0..lease.fencing_token.len],
    };
}

const Reporter = struct {
    target: [:0]const u8,

    pub fn report(self: Reporter, payload: []const u8) !void {
        var response: [512]u8 = undefined;
        var length: usize = 0;
        switch (rpc(self.target, "/podtest.invoker.v1.Control/Report", payload.ptr, payload.len, &response, response.len, &length)) {
            0 => {
                _ = try decodeAck(response[0..length]);
            },
            14 => return error.BackendUnavailable,
            else => return error.ReportFailed,
        }
    }
};

fn decodeAck(response: []const u8) !bool {
    const ack = pb.podtest__invoker__v1__acknowledgement__unpack(null, response.len, response.ptr) orelse return error.InvalidAck;
    defer pb.podtest__invoker__v1__acknowledgement__free_unpacked(ack, null);
    return ack.*.duplicate != 0;
}
