//! Deterministic CPU-bound reference benchmark.
//!
//! The same source and the same binary are shipped with every invoker.  The
//! benchmark is intentionally single threaded and mixes integer arithmetic,
//! floating point arithmetic and memory accesses so that its cgroup CPU time
//! is a stable proxy for the speed of one core of the host.
//!
//! The workload is fixed (no calibration loop inside the binary).  A machine
//! whose single-core performance is the reference performance finishes it in
//! T_nominal = 1.0 "reference seconds"; the invoker computes
//!     k = T_nominal / median(raw CPU seconds)
//! and normalises every measured container CPU time as `k * raw`.
const std = @import("std");

const N: usize = 100000000;
const ARR: usize = 4096;

var sink: u64 = 0;

fn mix(x: u64) u64 {
    var z = x;
    z ^= z >> 30;
    z *%= 0xbf58476d1ce4e5b9;
    z ^= z >> 27;
    z *%= 0x94d049bb133111eb;
    z ^= z >> 31;
    return z;
}

pub fn main() !void {
    var mem: [ARR]u64 = undefined;
    var i: usize = 0;
    while (i < ARR) : (i += 1) mem[i] = mix(@as(u64, i) +% 0x9e3779b97f4a7c15);

    var a: u64 = 0x243f6a8885a308d3;
    var f: f64 = 1.0;
    var sum: u64 = 0;

    var it: usize = 0;
    while (it < N) : (it += 1) {
        // integer / bit mixing
        a = mix(a +% @as(u64, it));
        sum +%= a ^ (@as(u64, it) *% 0x2545f4914f6cdd1d);
        a ^= a >> 17;

        // floating point
        const x: f64 = @floatFromInt(it & 1023);
        f = @sqrt(f + x * 0.5 + 1.0);
        if (f > 1.0e9) f = 1.0;

        // memory access with a data-dependent index
        const idx = (a >> 7) & (ARR - 1);
        mem[idx] = mix(mem[idx] +% a);
        sum +%= mem[(idx + 1) & (ARR - 1)] >> 3;
        @as(*volatile u64, &sink).* = sum;
    }

    // consume the results so nothing can be optimised away
    sink = sum +% @as(u64, @bitCast(f)) +% mem[0];
}
