const std = @import("std");
const linux = std.os.linux;

pub const Ns = i128;
pub const ns_per_sec: Ns = 1_000_000_000;

pub fn nowNs() Ns {
    var ts: linux.timespec = undefined;
    const rc = linux.clock_gettime(.MONOTONIC, &ts);
    if (linux.errno(rc) != .SUCCESS) return 0;
    return @as(Ns, ts.sec) * ns_per_sec + @as(Ns, ts.nsec);
}

pub fn realtimeNs() Ns {
    var ts: linux.timespec = undefined;
    const rc = linux.clock_gettime(.REALTIME, &ts);
    if (linux.errno(rc) != .SUCCESS) return 0;
    return @as(Ns, ts.sec) * ns_per_sec + @as(Ns, ts.nsec);
}

pub fn sleepNs(ns: Ns) void {
    if (ns <= 0) return;
    var req = linux.timespec{
        .sec = @intCast(@divTrunc(ns, ns_per_sec)),
        .nsec = @intCast(@mod(ns, ns_per_sec)),
    };
    while (true) {
        const rc = linux.nanosleep(&req, &req);
        if (linux.errno(rc) != .INTR) break;
    }
}

pub fn sleepMs(ms: u64) void {
    sleepNs(@as(Ns, ms) * 1_000_000);
}

pub fn monoMs() u64 {
    return @intCast(@divTrunc(nowNs(), 1_000_000));
}

/// RFC3339-ish UTC timestamp with milliseconds, e.g. 2026-11-13T00:00:00.000Z
pub fn formatIso(buf: []u8) []const u8 {
    const secs: i64 = @intCast(@divTrunc(realtimeNs(), ns_per_sec));
    const ms: u32 = @intCast(@divTrunc(@mod(realtimeNs(), ns_per_sec), 1_000_000));
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(secs, 0)) };
    const day = epoch.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = epoch.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        yd.year,
        md.month.numeric(),
        md.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
        ms,
    }) catch "1970-01-01T00:00:00.000Z";
}
