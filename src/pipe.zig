const std = @import("std");

pub const State = enum { open, half_closed, cancelled, broken };

/// Fixed-capacity byte ring. A producer gets backpressure when full and never
/// grows memory in response to a slow consumer.
pub const Buffer = struct {
    storage: []u8,
    head: usize = 0,
    len: usize = 0,
    state: State = .open,

    pub fn init(storage: []u8) error{InvalidPipeCapacity}!Buffer {
        if (storage.len == 0) return error.InvalidPipeCapacity;
        return .{ .storage = storage };
    }

    pub fn write(self: *Buffer, bytes: []const u8) error{ Backpressure, BrokenPipe, Cancelled }!usize {
        if (self.state == .cancelled) return error.Cancelled;
        if (self.state == .broken) return error.BrokenPipe;
        if (self.state == .half_closed) return error.BrokenPipe;
        if (self.len == self.storage.len) return error.Backpressure;
        const count = @min(bytes.len, self.storage.len - self.len);
        const tail = (self.head + self.len) % self.storage.len;
        const first = @min(count, self.storage.len - tail);
        @memcpy(self.storage[tail .. tail + first], bytes[0..first]);
        if (first < count) @memcpy(self.storage[0 .. count - first], bytes[first..count]);
        self.len += count;
        return count;
    }

    pub fn read(self: *Buffer, out: []u8) error{ WouldBlock, EndOfStream, Cancelled, BrokenPipe }!usize {
        if (self.len == 0) return switch (self.state) {
            .half_closed => error.EndOfStream,
            .cancelled => error.Cancelled,
            .broken => error.BrokenPipe,
            .open => error.WouldBlock,
        };
        const count = @min(out.len, self.len);
        const first = @min(count, self.storage.len - self.head);
        @memcpy(out[0..first], self.storage[self.head .. self.head + first]);
        if (first < count) @memcpy(out[first..count], self.storage[0 .. count - first]);
        self.head = (self.head + count) % self.storage.len;
        self.len -= count;
        return count;
    }

    pub fn halfClose(self: *Buffer) void {
        if (self.state == .open) self.state = .half_closed;
    }

    pub fn consumerClosed(self: *Buffer) void {
        if (self.state == .open or self.state == .half_closed) {
            self.state = .broken;
            self.len = 0;
        }
    }

    pub fn readable(self: *const Buffer) []const u8 {
        return self.storage[self.head..][0..@min(self.len, self.storage.len - self.head)];
    }

    pub fn discard(self: *Buffer, count: usize) void {
        std.debug.assert(count <= self.len);
        self.head = (self.head + count) % self.storage.len;
        self.len -= count;
    }

    pub fn cancel(self: *Buffer) void {
        self.state = .cancelled;
        self.len = 0;
        self.head = 0;
    }
};

test "bounded pipe applies backpressure and returns buffered bytes before EOF" {
    var storage: [4]u8 = undefined;
    var pipe = try Buffer.init(&storage);
    try std.testing.expectEqual(@as(usize, 4), try pipe.write("abcdef"));
    try std.testing.expectError(error.Backpressure, pipe.write("x"));
    var out: [8]u8 = undefined;
    try std.testing.expectEqualStrings("abcd", out[0..try pipe.read(&out)]);
    _ = try pipe.write("ef");
    pipe.halfClose();
    try std.testing.expectEqualStrings("ef", out[0..try pipe.read(&out)]);
    try std.testing.expectError(error.EndOfStream, pipe.read(&out));
}

test "pipe cancellation and broken consumer wake blocked endpoints distinctly" {
    var storage: [2]u8 = undefined;
    var pipe = try Buffer.init(&storage);
    _ = try pipe.write("ab");
    pipe.consumerClosed();
    try std.testing.expectError(error.BrokenPipe, pipe.write("c"));
    pipe.cancel();
    try std.testing.expectError(error.Cancelled, pipe.read(&storage));
}
