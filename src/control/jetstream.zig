const std = @import("std");
const js = @import("nats").jetstream;
const delivery = @import("delivery.zig");

pub const Consumer = struct {
    pull: js.PullSubscription,
    subject: []const u8,

    /// The JetStream context and configuration strings must outlive the consumer.
    /// Backend owns stream and consumer provisioning.
    pub fn bind(context: *js.JetStream, stream: []const u8, durable: []const u8, subject: []const u8) !Consumer {
        if (subject.len == 0 or std.mem.indexOfAny(u8, subject, "*> \t\r\n") != null) return error.InvalidJobSubject;
        var pull: js.PullSubscription = .{ .js = context, .stream = stream };
        try pull.setConsumer(durable);
        var info = try context.consumerInfo(stream, durable);
        defer info.deinit();
        const config = info.value.config orelse return error.InvalidConsumerConfig;
        if (config.ack_policy != .explicit or config.deliver_subject != null or config.headers_only == true or
            config.filter_subjects != null or !std.mem.eql(u8, durable, config.durable_name orelse "") or
            !std.mem.eql(u8, subject, config.filter_subject orelse "")) return error.InvalidConsumerConfig;
        return .{ .pull = pull, .subject = subject };
    }

    pub const Gate = struct {
        free_slots: usize,
        podman_available: bool,
        disk_available: bool,
    };

    /// Call serially with a fresh capacity snapshot. One pull reserves at most
    /// one slot. The handler must reserve it durably before acknowledging.
    pub fn step(self: *Consumer, allocator: std.mem.Allocator, io: std.Io, gate: Gate, handler: anytype) !?delivery.Outcome {
        if (gate.free_slots == 0 or !gate.podman_available or !gate.disk_available) return null;
        var message = (try self.pull.next(500)) orelse return null;
        defer message.deinit();
        if (!std.mem.eql(u8, message.msg.subject, self.subject)) return error.UnexpectedJobSubject;
        var transport: Message = .{ .message = &message };
        const attempts = if (message.metadata()) |metadata| metadata.num_delivered else 1;
        const exponent: u6 = @intCast(@min(attempts -| 1, 6));
        const delay_ns: i64 = @min(@as(i64, 250 * std.time.ns_per_ms) << exponent, 10 * std.time.ns_per_s);
        return try delivery.handle(allocator, message.data(), WallClock{ .io = io }, delay_ns, &transport, handler);
    }
};

const WallClock = struct {
    io: std.Io,

    pub fn now(self: WallClock) i64 {
        return std.Io.Clock.real.now(self.io).toSeconds();
    }
};

const Message = struct {
    message: *js.JsMsg,

    pub fn ack(self: Message) !void {
        const msg = self.message;
        const reply = msg.msg.reply_to orelse return error.MissingAckSubject;
        // Check the optional response directly. The pinned client's doubleAck
        // also returns success if request() returns null.
        const confirmation = (try msg.client.request(reply, "+ACK", 1000)) orelse return error.AckUnconfirmed;
        defer confirmation.deinit();
        if (confirmation.status()) |status| if (status >= 300) return error.AckRejected;
        if (confirmation.data.len != 0) return error.InvalidAckConfirmation;
    }

    pub fn retry(self: Message, delay_ns: i64) !void {
        if (self.message.msg.reply_to == null) return error.MissingAckSubject;
        try self.message.nakWithDelay(delay_ns);
    }

    pub fn reject(self: Message) !void {
        if (self.message.msg.reply_to == null) return error.MissingAckSubject;
        try self.message.term();
    }
};
