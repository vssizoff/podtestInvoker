//! CPU-speed calibration using the deterministic benchmark image.
const std = @import("std");
const podman = @import("podman/client.zig");
const configmod = @import("config.zig");
const tar_write = @import("util/tar_write.zig");
const clock = @import("util/clock.zig");
const log = @import("util/log.zig");
const gpa = @import("util/mem.zig").gpa;
const bench_asset = @import("bench_asset");

const dockerfile =
    \\FROM scratch
    \\COPY bench /bench
    \\ENTRYPOINT ["/bench"]
    \\
;

/// Samples the container cgroup while the benchmark runs.  Rootless Podman
/// removes the cgroup when the container exits, so the last value observed
/// while it was alive is the only reliable CPU accounting source.
const Sampler = struct {
    client: *podman.Client,
    id: []const u8,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    usage: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    peak: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    fn run(self: *Sampler) void {
        var path_buf: [4096]u8 = undefined;
        var path_len: usize = 0;
        const deadline = clock.nowNs() + 5 * clock.ns_per_sec;
        while (path_len == 0 and !self.stop.load(.monotonic)) {
            if (self.client.inspectContainer(self.id)) |info| {
                defer {
                    var i = info;
                    i.deinit();
                }
                if (info.cgroup_path.len > 0 and info.cgroup_path.len <= path_buf.len) {
                    @memcpy(path_buf[0..info.cgroup_path.len], info.cgroup_path);
                    path_len = info.cgroup_path.len;
                } else if (info.pid > 0) {
                    if (podman.readCgroupPath(info.pid, &path_buf)) |cg| path_len = cg.len;
                }
                if (std.mem.eql(u8, info.status, "exited") or std.mem.eql(u8, info.status, "stopped")) return;
            } else |_| {}
            if (clock.nowNs() >= deadline) return;
            clock.sleepMs(2);
        }
        while (path_len > 0 and !self.stop.load(.monotonic)) {
            const st = podman.readCgroupStats(path_buf[0..path_len]);
            if (st.cpu_usage_usec > self.usage.load(.monotonic)) self.usage.store(st.cpu_usage_usec, .monotonic);
            if (st.memory_peak > self.peak.load(.monotonic)) self.peak.store(st.memory_peak, .monotonic);
            clock.sleepMs(5);
        }
    }
};

pub const Calibration = struct {
    cfg: *const configmod.Config,
    client: *podman.Client,
    instance_id: []const u8,
    tag: []u8,
    factor_bits: std.atomic.Value(u64) = std.atomic.Value(u64).init(@bitCast(@as(f64, 1.0))),
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    pub fn init(cfg: *const configmod.Config, client: *podman.Client, instance_id: []const u8) !*Calibration {
        const c = try gpa.create(Calibration);
        errdefer gpa.destroy(c);
        const short = instance_id[0..@min(instance_id.len, 8)];
        c.* = .{
            .cfg = cfg,
            .client = client,
            .instance_id = instance_id,
            .tag = try std.fmt.allocPrint(gpa, "podtest-invoker-bench-{s}", .{short}),
        };
        return c;
    }

    pub fn deinit(self: *Calibration) void {
        self.stop.store(true, .monotonic);
        if (self.thread) |t| t.join();
        self.client.removeImage(self.tag) catch {};
        gpa.free(self.tag);
        gpa.destroy(self);
    }

    pub fn factor(self: *const Calibration) f64 {
        return @bitCast(self.factor_bits.load(.acquire));
    }

    fn labels(self: *Calibration) ![]podman.Label {
        const list = try gpa.alloc(podman.Label, 3);
        list[0] = .{ .key = "managed-by", .value = "invoker" };
        list[1] = .{ .key = "invoker.instance", .value = self.instance_id };
        list[2] = .{ .key = "run", .value = "calibration" };
        return list;
    }

    fn buildImage(self: *Calibration) !void {
        var b = tar_write.Builder{};
        defer b.deinit();
        try b.addFile("Dockerfile", dockerfile, 0o644);
        try b.addFile("bench", bench_asset.data, 0o755);
        const tar = try b.finish();
        defer gpa.free(tar);
        const lbl = try self.labels();
        defer gpa.free(lbl);
        try self.client.buildImage(tar, self.tag, "Dockerfile", lbl);
    }

    fn oneRun(self: *Calibration, index: u32) ?f64 {
        const name = std.fmt.allocPrint(gpa, "bench-{s}-{d}", .{ self.instance_id[0..@min(self.instance_id.len, 8)], index }) catch return null;
        defer gpa.free(name);
        const lbl = self.labels() catch return null;
        defer gpa.free(lbl);
        const cmd = [_][]const u8{"/bench"};
        const id = self.client.createContainer(.{
            .image = self.tag,
            .name = name,
            .labels = lbl,
            .stdin = false,
            .stdout = false,
            .stderr = false,
            .command = &cmd,
            .memory_bytes = 1024 * 1024 * 1024,
        }) catch |e| {
            log.warn("calibration: create failed: {s}", .{@errorName(e)});
            return null;
        };
        defer {
            self.client.removeContainer(id) catch {};
            gpa.free(id);
        }
        self.client.startContainer(id) catch |e| {
            log.warn("calibration: start failed: {s}", .{@errorName(e)});
            return null;
        };
        var sampler = Sampler{ .client = self.client, .id = id };
        const sampler_thread = std.Thread.spawn(.{}, Sampler.run, .{&sampler}) catch null;
        const code = self.client.waitContainer(id) catch |e| {
            sampler.stop.store(true, .monotonic);
            if (sampler_thread) |t| t.join();
            log.warn("calibration: wait failed: {s}", .{@errorName(e)});
            return null;
        };
        sampler.stop.store(true, .monotonic);
        if (sampler_thread) |t| t.join();
        const usage = sampler.usage.load(.monotonic);
        if (code != 0) {
            log.warn("calibration: benchmark exited with {d}", .{code});
            return null;
        }
        if (usage == 0) return null;
        return @as(f64, @floatFromInt(usage)) / 1_000_000.0;
    }

    pub fn calibrate(self: *Calibration) void {
        self.buildImage() catch |e| {
            log.warn("calibration: cannot build benchmark image: {s}", .{@errorName(e)});
            return;
        };
        const n = @min(self.cfg.calibration_runs, 64);
        var samples: [64]f64 = undefined;
        var count: usize = 0;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            if (self.stop.load(.monotonic)) return;
            if (self.oneRun(i)) |s| {
                samples[count] = s;
                count += 1;
            }
        }
        if (count == 0) {
            log.warn("calibration: no successful benchmark runs; using factor 1.0", .{});
            return;
        }
        std.mem.sort(f64, samples[0..count], {}, struct {
            fn less(_: void, a: f64, b: f64) bool {
                return a < b;
            }
        }.less);
        const median = samples[count / 2];
        if (median <= 0) return;
        const k = 1.0 / median;
        self.factor_bits.store(@bitCast(k), .release);
        log.info("calibration: median={d:.6}s factor={d:.6} (n={d})", .{ median, k, count });
    }

    pub fn startBackground(self: *Calibration) !void {
        if (self.cfg.calibration_interval_ms == 0) return;
        self.thread = try std.Thread.spawn(.{}, background, .{self});
    }

    fn background(self: *Calibration) void {
        const interval = self.cfg.calibration_interval_ms;
        var elapsed: u64 = 0;
        while (!self.stop.load(.monotonic)) {
            clock.sleepMs(1000);
            elapsed += 1000;
            if (elapsed >= interval) {
                elapsed = 0;
                self.calibrate();
            }
        }
    }
};
