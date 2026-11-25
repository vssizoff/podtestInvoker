//! Runs only against the disposable loopback fixture started by the test script.
const std = @import("std");
const nats = @import("nats");
const Consumer = @import("jetstream.zig").Consumer;
const delivery = @import("delivery.zig");
const advertisement = @import("job.zig");
const Outbox = @import("outbox.zig").Outbox;

const stream = "PODTEST_TEST";
const durable = "invokers";
const subject = "podtest.test.jobs";
const ready: Consumer.Gate = .{ .free_slots = 1, .podman_available = true, .disk_available = true };

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.ExpectedLoopbackPortAndStateDir;
    var outbox = try Outbox.open(init.io, args[2], 1024 * 1024);
    defer outbox.close();
    const port = try std.fmt.parseInt(u16, args[1], 10);
    const url = try std.fmt.allocPrint(init.arena.allocator(), "nats://127.0.0.1:{d}", .{port});
    const client = try nats.Client.connect(init.gpa, init.io, url, .{});
    defer client.deinit();
    const peer = try nats.Client.connect(init.gpa, init.io, url, .{});
    defer peer.deinit();
    var js = try nats.jetstream.JetStream.init(client, .{});
    var peer_js = try nats.jetstream.JetStream.init(peer, .{});

    var created = try js.createStream(.{ .name = stream, .subjects = &.{subject}, .storage = .memory });
    created.deinit();
    var created_consumer = try js.createConsumer(stream, .{
        .durable_name = durable,
        .filter_subject = subject,
        .ack_policy = .explicit,
        .ack_wait = 5 * std.time.ns_per_s,
    });
    created_consumer.deinit();
    try std.testing.expectError(error.InvalidConsumerConfig, Consumer.bind(&js, stream, durable, "podtest.other"));
    var worker = try Consumer.bind(&js, stream, durable, subject);
    var peer_worker = try Consumer.bind(&peer_js, stream, durable, subject);

    try publish(&js, advertisement.test_payload);
    var first: Fixture = .{ .result = .retry };
    var gate = ready;
    gate.free_slots = 0;
    try std.testing.expectEqual(null, try worker.step(init.gpa, init.io, gate, &first));
    gate = ready;
    gate.podman_available = false;
    try std.testing.expectEqual(null, try worker.step(init.gpa, init.io, gate, &first));
    gate = ready;
    gate.disk_available = false;
    try std.testing.expectEqual(null, try worker.step(init.gpa, init.io, gate, &first));
    try std.testing.expectEqual(@as(usize, 0), first.claims);
    try std.testing.expectEqual(.deferred, (try worker.step(init.gpa, init.io, ready, &first)).?);
    try std.testing.expectEqual(@as(usize, 1), first.claims);

    var second: Fixture = .{ .result = .stale };
    // Redelivery goes to another connection on the same durable consumer.
    try std.testing.expectEqual(.ignored, (try peer_worker.step(init.gpa, init.io, ready, &second)).?);
    try std.testing.expectEqual(@as(usize, 1), second.claims);
    var after_ack = try js.consumerInfo(stream, durable);
    defer after_ack.deinit();
    try std.testing.expectEqual(@as(i64, 0), after_ack.value.num_ack_pending);
    try std.testing.expectEqual(@as(u64, 1), after_ack.value.ack_floor.?.stream_seq);
    try std.testing.expectEqual(@as(u64, 2), after_ack.value.delivered.?.consumer_seq);

    try publish(&js, "{}");
    try std.testing.expectEqual(.rejected, (try worker.step(init.gpa, init.io, ready, &first)).?);
    try std.testing.expectEqual(@as(usize, 1), first.claims);
    try std.testing.expectEqual(null, try peer_worker.step(init.gpa, init.io, ready, &second));

    try publish(&js, advertisement.test_payload);
    var granted: Fixture = .{
        .result = .{ .granted = .{ .fencing_token = "test-token", .expires_unix = std.Io.Clock.real.now(init.io).toSeconds() + 30 } },
        .outbox = &outbox,
        .context = &js,
    };
    try std.testing.expectEqual(.started, (try worker.step(init.gpa, init.io, ready, &granted)).?);
    const records = try outbox.replay(init.gpa);
    defer {
        for (records) |record| init.gpa.free(record.payload);
        init.gpa.free(records);
    }
    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectEqual(.lease, records[0].kind);
    try std.testing.expectEqualStrings("test-token", records[0].payload);
    std.debug.print("JetStream gate, NAK/redelivery, malformed delivery and durable lease before confirmed ACK/start verified\n", .{});
}

fn publish(js: *nats.jetstream.JetStream, payload: []const u8) !void {
    var response = try js.publish(subject, payload);
    response.deinit();
}

const Fixture = struct {
    claims: usize = 0,
    result: delivery.Claim,
    outbox: ?*Outbox = null,
    context: ?*nats.jetstream.JetStream = null,

    pub fn claim(self: *Fixture, _: advertisement.Job) !delivery.Claim {
        self.claims += 1;
        return self.result;
    }
    pub fn persist(self: *Fixture, _: advertisement.Job, lease: delivery.Lease) !void {
        const outbox = self.outbox orelse return error.UnexpectedPersist;
        _ = try outbox.append(.lease, lease.fencing_token);
    }
    pub fn start(self: *Fixture, _: advertisement.Job, _: delivery.Lease) !void {
        const outbox = self.outbox orelse return error.UnexpectedStart;
        try std.testing.expectEqual(@as(u64, 1), outbox.sequence);
        var info = try self.context.?.consumerInfo(stream, durable);
        defer info.deinit();
        try std.testing.expectEqual(@as(i64, 0), info.value.num_ack_pending);
        try std.testing.expectEqual(@as(u64, 3), info.value.ack_floor.?.stream_seq);
    }
};
