const std = @import("std");
const Outbox = @import("outbox.zig").Outbox;
extern fn podtest_lock([*:0]const u8) c_int;

const event = "fixture-event-id:1";

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.InvalidArguments;
    const fd = podtest_lock(args[2]);
    if (fd < 0) return error.CannotLockFixtureState;
    defer _ = std.os.linux.close(fd);
    if (std.mem.eql(u8, args[1], "write")) {
        var box = try Outbox.open(init.io, args[2], 64 << 10);
        defer box.close();
        if (try box.append(.event, event) != 1) return error.UnexpectedSequence;
        var ready = try box.dir.createFileAtomic(init.io, "ready", .{ .permissions = .fromMode(0o600) });
        defer ready.deinit(init.io);
        try ready.link(init.io);
        try init.io.sleep(.fromSeconds(60), .awake);
        return error.ExpectedProcessKill;
    }
    if (!std.mem.eql(u8, args[1], "replay")) return error.InvalidArguments;
    {
        var box = try Outbox.open(init.io, args[2], 64 << 10);
        defer box.close();
        if (try box.flush(init.gpa, Reporter{}) != 1) return error.ExpectedRecoveredEvent;
    }
    var box = try Outbox.open(init.io, args[2], 64 << 10);
    defer box.close();
    if (try box.flush(init.gpa, Reporter{}) != 0) return error.AckNotDurable;
}

const Reporter = struct {
    pub fn report(_: Reporter, bytes: []const u8) !void {
        if (!std.mem.eql(u8, bytes, event)) return error.UnexpectedWireBytes;
    }
};
