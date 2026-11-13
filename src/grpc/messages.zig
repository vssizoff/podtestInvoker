//! Hand-written protobuf codec for proto/invoker.proto.
//!
//! Only the messages used by the invoker are encoded; decoding is limited to
//! RunRequest which is the only message sent by clients.
const std = @import("std");
const events = @import("../events.zig");
const gpa = @import("../util/mem.zig").gpa;

pub const Error = error{ MalformedProtobuf, Truncated, OutOfMemory };

pub const Wire = enum(u3) {
    varint = 0,
    fixed64 = 1,
    len = 2,
    fixed32 = 5,
};

pub const Buf = struct {
    list: *std.ArrayList(u8),

    pub fn init(list: *std.ArrayList(u8)) Buf {
        return .{ .list = list };
    }

    pub fn varint(self: Buf, v: u64) !void {
        var x = v;
        while (x >= 0x80) {
            try self.list.append(gpa, @as(u8, @truncate(x)) | 0x80);
            x >>= 7;
        }
        try self.list.append(gpa, @truncate(x));
    }

    pub fn tag(self: Buf, field: u32, wire: Wire) !void {
        try self.varint((@as(u64, field) << 3) | @backingInt(wire));
    }

    pub fn uintField(self: Buf, field: u32, v: u64) !void {
        try self.tag(field, .varint);
        try self.varint(v);
    }

    pub fn boolField(self: Buf, field: u32, v: bool) !void {
        try self.uintField(field, @intFromBool(v));
    }

    pub fn bytesField(self: Buf, field: u32, data: []const u8) !void {
        try self.tag(field, .len);
        try self.varint(data.len);
        try self.list.appendSlice(gpa, data);
    }

    pub fn stringField(self: Buf, field: u32, data: []const u8) !void {
        try self.bytesField(field, data);
    }

    pub fn doubleField(self: Buf, field: u32, v: f64) !void {
        try self.tag(field, .fixed64);
        const bits: u64 = @bitCast(v);
        var raw: [8]u8 = undefined;
        std.mem.writeInt(u64, &raw, bits, .little);
        try self.list.appendSlice(gpa, &raw);
    }

    /// Append a length-delimited nested message.
    pub fn messageField(self: Buf, field: u32, inner: []const u8) !void {
        try self.bytesField(field, inner);
    }
};

pub const Start = struct {
    run_id: []const u8,
    runner: []const u8,
    timeout_ms: u64,
};

pub const Request = union(enum) {
    start: Start,
    archive_chunk: []const u8,
    archive_end: void,
    stop: []const u8,
};

const Cursor = struct {
    data: []const u8,
    pos: usize = 0,

    fn done(self: *Cursor) bool {
        return self.pos >= self.data.len;
    }

    fn varint(self: *Cursor) Error!u64 {
        var result: u64 = 0;
        var shift: u6 = 0;
        var count: usize = 0;
        while (count < 10) : (count += 1) {
            if (self.pos >= self.data.len) return error.Truncated;
            const b = self.data[self.pos];
            self.pos += 1;
            result |= @as(u64, b & 0x7f) << shift;
            if (b & 0x80 == 0) return result;
            if (shift >= 63) return error.MalformedProtobuf;
            shift += 7;
        }
        return error.MalformedProtobuf;
    }

    fn field(self: *Cursor) Error!struct { number: u32, wire: Wire } {
        const key = try self.varint();
        const wire_num = key & 0x7;
        const w: Wire = switch (wire_num) {
            0 => .varint,
            1 => .fixed64,
            2 => .len,
            5 => .fixed32,
            else => return error.MalformedProtobuf,
        };
        const number = key >> 3;
        if (number == 0 or number > std.math.maxInt(u32)) return error.MalformedProtobuf;
        return .{ .number = @intCast(number), .wire = w };
    }

    fn bytes(self: *Cursor) Error![]const u8 {
        const len = try self.varint();
        if (len > self.data.len - self.pos) return error.Truncated;
        const out = self.data[self.pos .. self.pos + @as(usize, @intCast(len))];
        self.pos += @intCast(len);
        return out;
    }

    fn skip(self: *Cursor, wire: Wire) Error!void {
        switch (wire) {
            .varint => _ = try self.varint(),
            .fixed64 => {
                if (self.data.len - self.pos < 8) return error.Truncated;
                self.pos += 8;
            },
            .fixed32 => {
                if (self.data.len - self.pos < 4) return error.Truncated;
                self.pos += 4;
            },
            .len => _ = try self.bytes(),
        }
    }
};

fn parseStart(data: []const u8) Error!Start {
    var c = Cursor{ .data = data };
    var start = Start{ .run_id = "", .runner = "", .timeout_ms = 0 };
    while (!c.done()) {
        const f = try c.field();
        switch (f.number) {
            1 => if (f.wire == .len) {
                start.run_id = try c.bytes();
            } else try c.skip(f.wire),
            2 => if (f.wire == .len) {
                start.runner = try c.bytes();
            } else try c.skip(f.wire),
            3 => if (f.wire == .varint) {
                start.timeout_ms = try c.varint();
            } else try c.skip(f.wire),
            else => try c.skip(f.wire),
        }
    }
    return start;
}

fn parseStop(data: []const u8) Error![]const u8 {
    var c = Cursor{ .data = data };
    var reason: []const u8 = "";
    while (!c.done()) {
        const f = try c.field();
        switch (f.number) {
            1 => if (f.wire == .len) {
                reason = try c.bytes();
            } else try c.skip(f.wire),
            else => try c.skip(f.wire),
        }
    }
    return reason;
}

/// Decode one RunRequest.  Returned slices point into `data`.
pub fn parseRequest(data: []const u8) Error!Request {
    var c = Cursor{ .data = data };
    var result: ?Request = null;
    while (!c.done()) {
        const f = try c.field();
        switch (f.number) {
            1 => {
                if (f.wire != .len) {
                    try c.skip(f.wire);
                    continue;
                }
                const inner = try c.bytes();
                if (result != null) return error.MalformedProtobuf;
                result = .{ .start = try parseStart(inner) };
            },
            2 => {
                if (f.wire != .len) {
                    try c.skip(f.wire);
                    continue;
                }
                if (result != null) return error.MalformedProtobuf;
                result = .{ .archive_chunk = try c.bytes() };
            },
            3 => {
                if (f.wire != .len) {
                    try c.skip(f.wire);
                    continue;
                }
                _ = try c.bytes();
                if (result != null) return error.MalformedProtobuf;
                result = .{ .archive_end = {} };
            },
            4 => {
                if (f.wire != .len) {
                    try c.skip(f.wire);
                    continue;
                }
                const inner = try c.bytes();
                if (result != null) return error.MalformedProtobuf;
                result = .{ .stop = try parseStop(inner) };
            },
            else => try c.skip(f.wire),
        }
    }
    return result orelse error.MalformedProtobuf;
}

/// Build the serialised `Event` message (without the RunEvent wrapper).
pub fn encodeEvent(ev: events.Event, out: *std.ArrayList(u8)) Error!void {
    var inner: std.ArrayList(u8) = .empty;
    defer inner.deinit(gpa);
    var b = Buf.init(&inner);
    switch (ev) {
        .test_started => |v| {
            var sub: std.ArrayList(u8) = .empty;
            defer sub.deinit(gpa);
            var sb = Buf.init(&sub);
            try sb.uintField(1, v.n);
            try b.messageField(2, sub.items);
        },
        .test_verdict => |v| {
            var sub: std.ArrayList(u8) = .empty;
            defer sub.deinit(gpa);
            var sb = Buf.init(&sub);
            try sb.uintField(1, v.n);
            try sb.stringField(2, v.verdict);
            if (v.score) |s| try sb.doubleField(3, s);
            if (v.grader_data) |d| try sb.bytesField(4, d);
            try b.messageField(3, sub.items);
        },
        .subgroup_score => |v| {
            var sub: std.ArrayList(u8) = .empty;
            defer sub.deinit(gpa);
            var sb = Buf.init(&sub);
            try sb.stringField(1, v.id);
            try sb.doubleField(2, v.score);
            if (v.grader_data) |d| try sb.bytesField(3, d);
            try b.messageField(4, sub.items);
        },
        .problem_score => |v| {
            var sub: std.ArrayList(u8) = .empty;
            defer sub.deinit(gpa);
            var sb = Buf.init(&sub);
            try sb.doubleField(1, v.score);
            if (v.grader_data) |d| try sb.bytesField(2, d);
            try b.messageField(5, sub.items);
        },
        .build_log => |v| {
            var sub: std.ArrayList(u8) = .empty;
            defer sub.deinit(gpa);
            var sb = Buf.init(&sub);
            try sb.stringField(1, v.text);
            try b.messageField(6, sub.items);
        },
        .test_stdio => |v| {
            var sub: std.ArrayList(u8) = .empty;
            defer sub.deinit(gpa);
            var sb = Buf.init(&sub);
            try sb.uintField(1, v.n);
            try sb.bytesField(2, v.stdin);
            try sb.bytesField(3, v.stdout);
            try sb.bytesField(4, v.stderr);
            try b.messageField(7, sub.items);
        },
        .runner_error => |v| {
            var sub: std.ArrayList(u8) = .empty;
            defer sub.deinit(gpa);
            var sb = Buf.init(&sub);
            try sb.stringField(1, v.message);
            try sb.stringField(2, v.traceback);
            try b.messageField(8, sub.items);
        },
        .run_finished => |v| {
            var sub: std.ArrayList(u8) = .empty;
            defer sub.deinit(gpa);
            var sb = Buf.init(&sub);
            try sb.boolField(1, v.ok);
            try sb.stringField(2, v.status);
            try b.messageField(9, sub.items);
        },
        .run_timeout => {
            var sub: std.ArrayList(u8) = .empty;
            defer sub.deinit(gpa);
            try b.messageField(10, sub.items);
        },
    }
    try out.appendSlice(gpa, inner.items);
}

pub fn encodeRunStarted(run_id: []const u8, instance_id: []const u8, out: *std.ArrayList(u8)) Error!void {
    var started: std.ArrayList(u8) = .empty;
    defer started.deinit(gpa);
    var sb = Buf.init(&started);
    try sb.stringField(1, run_id);
    try sb.stringField(2, instance_id);

    var event: std.ArrayList(u8) = .empty;
    defer event.deinit(gpa);
    var eb = Buf.init(&event);
    try eb.messageField(1, started.items);
    try wrapEvent(event.items, out);
}

/// Wrap a serialised Event in RunEvent.event (field 1).
pub fn wrapEvent(inner: []const u8, out: *std.ArrayList(u8)) Error!void {
    try out.append(gpa, 0x0a);
    try appendVarint(out, inner.len);
    try out.appendSlice(gpa, inner);
}

/// Wrap EventChunk in RunEvent.chunk (field 2).
pub fn wrapChunk(sequence: u32, total: u32, data: []const u8, out: *std.ArrayList(u8)) Error!void {
    var sub: std.ArrayList(u8) = .empty;
    defer sub.deinit(gpa);
    var b = Buf.init(&sub);
    try b.uintField(1, sequence);
    try b.uintField(2, total);
    try b.bytesField(3, data);
    try out.append(gpa, 0x12);
    try appendVarint(out, sub.items.len);
    try out.appendSlice(gpa, sub.items);
}

fn appendVarint(out: *std.ArrayList(u8), v: usize) Error!void {
    var b = Buf.init(out);
    try b.varint(v);
}

test "request round trip primitives" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var inner: std.ArrayList(u8) = .empty;
    defer inner.deinit(gpa);
    var ib = Buf.init(&inner);
    try ib.stringField(1, "run-1");
    try ib.stringField(2, "runner.lua");
    try ib.uintField(3, 1234);
    var b = Buf.init(&buf);
    try b.messageField(1, inner.items);
    const req = try parseRequest(buf.items);
    try std.testing.expect(req == .start);
    try std.testing.expectEqualStrings("run-1", req.start.run_id);
    try std.testing.expectEqualStrings("runner.lua", req.start.runner);
    try std.testing.expectEqual(@as(u64, 1234), req.start.timeout_ms);
}
