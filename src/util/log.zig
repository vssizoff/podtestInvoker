const std = @import("std");

pub const Level = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,

    pub fn parse(s: []const u8) ?Level {
        if (std.mem.eql(u8, s, "debug")) return .debug;
        if (std.mem.eql(u8, s, "info")) return .info;
        if (std.mem.eql(u8, s, "warn")) return .warn;
        if (std.mem.eql(u8, s, "error")) return .err;
        return null;
    }
};

var g_level = std.atomic.Value(u8).init(@backingInt(Level.info));

pub fn setLevel(level: Level) void {
    g_level.store(@backingInt(level), .monotonic);
}

pub fn enabled(level: Level) bool {
    return @backingInt(level) >= g_level.load(.monotonic);
}

pub fn log(level: Level, comptime fmt: []const u8, args: anytype) void {
    if (!enabled(level)) return;
    const clock = @import("clock.zig");
    const ms = @divTrunc(clock.nowNs(), 1_000_000);
    std.debug.print("[{d: >8}.{d:0>3}] {s:<5} " ++ fmt ++ "\n", .{
        @divTrunc(ms, 1000),
        @mod(ms, 1000),
        @tagName(level),
    } ++ args);
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    log(.debug, fmt, args);
}
pub fn info(comptime fmt: []const u8, args: anytype) void {
    log(.info, fmt, args);
}
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    log(.warn, fmt, args);
}
pub fn err(comptime fmt: []const u8, args: anytype) void {
    log(.err, fmt, args);
}

/// Print a line from runner.lua `print()`; never interpreted as a format string.
pub fn runnerPrint(run_id: []const u8, text: []const u8) void {
    if (!enabled(.info)) return;
    const clock = @import("clock.zig");
    const ms = @divTrunc(clock.nowNs(), 1_000_000);
    std.debug.print("[{d: >8}.{d:0>3}] RUN   {s}: {s}\n", .{
        @divTrunc(ms, 1000),
        @mod(ms, 1000),
        run_id,
        text,
    });
}
