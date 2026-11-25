const std = @import("std");

pub const Stream = enum { stdin, stdout, stderr };
pub const Mode = enum { none, once, realtime, pipe };
const names = [_][]const u8{ "stdin.bin", "stdout.bin", "stderr.bin" };

/// Serial access only. The caller owns the private, per-container directory
/// and removes its contents after handing off the captured files.
pub const History = struct {
    io: std.Io,
    files: [3]?std.Io.File = @splat(null),
    lengths: [3]u64 = @splat(0),
    total: u64 = 0,
    limit: u64,
    stream_limits: [3]u64 = @splat(std.math.maxInt(u64)),
    exceeded: bool = false,
    failed: bool = false,

    pub fn open(io: std.Io, dir: std.Io.Dir, modes: [3]Mode, limit: u64) !History {
        if (limit == 0) return error.InvalidHistoryLimit;
        var history: History = .{ .io = io, .limit = limit };
        errdefer {
            for (history.files, names) |file, name| {
                if (file) |f| {
                    f.close(io);
                    dir.deleteFile(io, name) catch {};
                }
            }
        }
        for (modes, names, &history.files) |mode, name, *file| {
            if (mode != .none) file.* = try dir.createFile(io, name, .{ .exclusive = true, .read = true, .permissions = .fromMode(0o600) });
        }
        return history;
    }

    pub fn close(self: *History) void {
        for (&self.files) |*file| {
            if (file.*) |f| f.close(self.io);
            file.* = null;
        }
    }

    pub fn append(self: *History, stream: Stream, data: []const u8) !void {
        const index = @backingInt(stream);
        const file = self.files[index] orelse return;
        if (self.failed) return error.HistoryWriteFailed;
        const count = @min(self.available(stream), data.len);
        if (count != 0) {
            file.writePositionalAll(self.io, data[0..count], self.lengths[index]) catch |err| {
                // A partial write has unknown length. Do not resume appending.
                self.failed = true;
                return err;
            };
            self.lengths[index] += count;
            self.total += count;
        }
        if (count != data.len) {
            self.exceeded = true;
            return error.OutputLimit;
        }
    }

    pub fn readAt(self: *const History, stream: Stream, offset: u64, buffer: []u8) !usize {
        const index = @backingInt(stream);
        const file = self.files[index] orelse return error.HistoryUnavailable;
        if (offset >= self.lengths[index]) return 0;
        const limit: usize = @intCast(@min(self.lengths[index] - offset, buffer.len));
        return file.readPositionalAll(self.io, buffer[0..limit], offset);
    }

    pub fn sync(self: *const History) !void {
        if (self.failed) return error.HistoryWriteFailed;
        for (self.files) |file| if (file) |f| try f.sync(self.io);
    }

    pub fn available(self: *const History, stream: Stream) usize {
        const i = @backingInt(stream);
        return @intCast(@min(self.limit -| self.total, self.stream_limits[i] -| self.lengths[i], std.math.maxInt(usize)));
    }
};

test "disk history keeps binary streams separate and preserves the capped prefix" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    var history = try History.open(std.testing.io, dir.dir, .{ .none, .once, .realtime }, 6);
    defer history.close();
    try history.append(.stdin, "ignored");
    try history.append(.stdout, "a\x00b");
    try history.append(.stderr, "c");
    try history.append(.stdout, "de");
    try std.testing.expectError(error.OutputLimit, history.append(.stderr, "f"));
    try std.testing.expectEqual(@as(u64, 6), history.total);
    try history.sync();
    var buffer: [8]u8 = undefined;
    try std.testing.expectError(error.HistoryUnavailable, history.readAt(.stdin, 0, &buffer));
    const count = try history.readAt(.stdout, 0, &buffer);
    try std.testing.expectEqualStrings("a\x00bde", buffer[0..count]);
    const errors = try history.readAt(.stderr, 0, &buffer);
    try std.testing.expectEqualStrings("c", buffer[0..errors]);
}

test "history never overwrites existing files and rolls back partial open" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const file = try dir.dir.createFile(std.testing.io, "stderr.bin", .{ .exclusive = true });
    file.close(std.testing.io);
    try std.testing.expectError(error.PathAlreadyExists, History.open(std.testing.io, dir.dir, .{ .once, .once, .once }, 8));
    var history = try History.open(std.testing.io, dir.dir, .{ .once, .once, .none }, 8);
    defer history.close();
    try std.testing.expectError(error.OutputLimit, history.append(.stdout, "123456789"));
    var buffer: [16]u8 = undefined;
    const count = try history.readAt(.stdout, 0, &buffer);
    try std.testing.expectEqualStrings("12345678", buffer[0..count]);
}
