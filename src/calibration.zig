const std = @import("std");
const linux = std.os.linux;

pub const version = "podtest-mix64-v1";
const rounds = 8_000_000;
const samples = 7;

pub const Measurement = struct { benchmark: []const u8 = version, cpu_index: usize, median_cpu_ns: u64, reference_cpu_ns: u64, factor: f64, measured_unix_seconds: i64 };

/// The reference time is chosen by the fleet operator, using the same
/// benchmark and build profile. Keep raw metrics independent of this factor.
pub fn measure(io: std.Io, reference_cpu_ns: u64) !Measurement {
    if (reference_cpu_ns == 0) return error.InvalidCalibrationReference;
    var original: linux.cpu_set_t = @splat(0);
    if (linux.errno(linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &original)) != .SUCCESS) return error.CalibrationAffinityUnavailable;
    var single: linux.cpu_set_t = @splat(0);
    const word = for (original, 0..) |bits, index| {
        if (bits != 0) break index;
    } else return error.CalibrationAffinityUnavailable;
    const bit = @ctz(original[word]);
    single[word] = @as(usize, 1) << @intCast(bit);
    try linux.sched_setaffinity(0, &single);
    errdefer linux.sched_setaffinity(0, &original) catch {};

    std.mem.doNotOptimizeAway(kernel(rounds, 1));
    var times: [samples]u64 = undefined;
    for (&times, 0..) |*sample, i| {
        const start = std.Io.Clock.cpu_thread.now(io);
        std.mem.doNotOptimizeAway(kernel(rounds, @intCast(i + 2)));
        const duration = start.durationTo(std.Io.Clock.cpu_thread.now(io)).nanoseconds;
        if (duration <= 0 or duration > std.math.maxInt(u64)) return error.CalibrationClockUnavailable;
        sample.* = @intCast(duration);
    }
    try linux.sched_setaffinity(0, &original);
    std.mem.sort(u64, &times, {}, std.sort.asc(u64));
    const median = times[samples / 2];
    return .{ .cpu_index = word * @bitSizeOf(usize) + bit, .median_cpu_ns = median, .reference_cpu_ns = reference_cpu_ns, .factor = @as(f64, @floatFromInt(reference_cpu_ns)) / @as(f64, @floatFromInt(median)), .measured_unix_seconds = std.Io.Clock.real.now(io).toSeconds() };
}

noinline fn kernel(count: usize, seed: u64) u64 {
    var x = seed;
    for (0..count) |_| {
        x ^= x >> 27;
        x *%= 0x2545f4914f6cdd1d;
        x ^= x << 13;
    }
    return x;
}

test "benchmark algorithm and output stay stable" {
    try std.testing.expectEqual(@as(u64, 0x9bd7dd7cd4cf7d1d), kernel(1, 1));
    try std.testing.expectError(error.InvalidCalibrationReference, measure(std.testing.io, 0));
}
