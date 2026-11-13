//! Run registry, archive uploads and per-run threads.
const std = @import("std");
const configmod = @import("../config.zig");
const events = @import("../events.zig");
const runtime = @import("runtime.zig");
const executor = @import("executor.zig");
const tar = @import("../util/tar.zig");
const fs = @import("../util/fs.zig");
const sys = @import("../util/sys.zig");
const clock = @import("../util/clock.zig");
const log = @import("../util/log.zig");
const gpa = @import("../util/mem.zig").gpa;

pub const Error = error{
    InvalidRunId,
    RunExists,
    TooManyRuns,
    ArchiveMissing,
    NotPrepared,
} || std.mem.Allocator.Error;

pub const RunHandle = struct {
    mgr: *Manager,
    id: []u8,
    runner: []u8,
    rt: *runtime.RunContext,
    thread: std.Thread,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    joined: bool = false,

    /// Ask the executor to stop at the next scheduler tick.  Container
    /// processes are killed immediately.
    pub fn cancel(self: *RunHandle, reason: []const u8) void {
        if (!self.done.load(.acquire)) self.rt.cancel(reason);
    }

    pub fn isDone(self: *const RunHandle) bool {
        return self.done.load(.acquire);
    }

    /// Wait for the executor thread.  Safe to call more than once.
    pub fn join(self: *RunHandle) void {
        if (!self.joined) {
            self.thread.join();
            self.joined = true;
        }
    }

    /// Wait until the run is finished or the deadline expires.
    pub fn waitDone(self: *RunHandle, timeout_ms: u64) bool {
        const deadline = clock.nowNs() + @as(i128, @intCast(timeout_ms)) * 1_000_000;
        while (!self.done.load(.acquire)) {
            if (clock.nowNs() >= deadline) return false;
            clock.sleepMs(2);
        }
        return true;
    }

    /// Called by the connection thread after `join`.  The manager must have
    /// already removed the handle from its active table.
    pub fn destroy(self: *RunHandle) void {
        self.join();
        gpa.free(self.id);
        gpa.free(self.runner);
        gpa.destroy(self);
    }
};

pub const Manager = struct {
    cfg: *const configmod.Config,
    client: *@import("../podman/client.zig").Client,
    instance_id: []const u8,
    cpu_factor: *const fn (*anyopaque) f64,
    factor_ctx: *anyopaque,
    mutex: @import("../util/mutex.zig").Mutex = .{},
    runs: std.StringHashMap(*RunHandle),
    stopping: bool = false,

    pub fn init(
        cfg: *const configmod.Config,
        client: *@import("../podman/client.zig").Client,
        instance_id: []const u8,
        factor_ctx: *anyopaque,
        factor_fn: *const fn (*anyopaque) f64,
    ) !*Manager {
        const m = try gpa.create(Manager);
        m.* = .{
            .cfg = cfg,
            .client = client,
            .instance_id = instance_id,
            .cpu_factor = factor_fn,
            .factor_ctx = factor_ctx,
            .runs = std.StringHashMap(*RunHandle).init(gpa),
        };
        return m;
    }

    pub fn deinit(self: *Manager) void {
        // Ask every active run to stop.  The gRPC front end owns the handles
        // and joins them before the manager is destroyed.
        self.mutex.lock();
        self.stopping = true;
        var it = self.runs.valueIterator();
        while (it.next()) |h| h.*.cancel("shutdown");
        self.mutex.unlock();
        // Give executors a short while to unwind.
        const deadline = clock.nowNs() + 10_000_000_000;
        while (clock.nowNs() < deadline) {
            self.mutex.lock();
            const empty = self.runs.count() == 0;
            self.mutex.unlock();
            if (empty) break;
            clock.sleepMs(10);
        }
        self.mutex.lock();
        var keys = self.runs.keyIterator();
        while (keys.next()) |k| gpa.free(k.*);
        self.runs.deinit();
        self.mutex.unlock();
        gpa.destroy(self);
    }

    pub fn activeCount(self: *Manager) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.runs.count();
    }

    fn removeRun(self: *Manager, id: []const u8) void {
        self.mutex.lock();
        if (self.runs.fetchRemove(id)) |kv| gpa.free(kv.key);
        self.mutex.unlock();
    }

    pub fn runDir(self: *const Manager, run_id: []const u8) ![]u8 {
        return std.fmt.allocPrint(gpa, "{s}/{s}", .{ self.cfg.work_root, run_id });
    }

    /// Start a run from an already uploaded archive file.  The archive is
    /// removed by this function on both success and failure.
    pub fn startRun(
        self: *Manager,
        run_id: []const u8,
        runner: []const u8,
        timeout_ms: u64,
        archive_path: []const u8,
        sink: events.Sink,
    ) !*RunHandle {
        defer unlinkAbsolute(archive_path);
        if (!validRunId(run_id)) return error.InvalidRunId;
        if (runner.len == 0 or runner.len > 1024) return error.InvalidRunId;

        self.mutex.lock();
        if (self.stopping) {
            self.mutex.unlock();
            return error.TooManyRuns;
        }
        if (self.cfg.max_concurrent_runs > 0 and self.runs.count() >= self.cfg.max_concurrent_runs) {
            self.mutex.unlock();
            return error.TooManyRuns;
        }
        if (self.runs.contains(run_id)) {
            self.mutex.unlock();
            return error.RunExists;
        }
        self.mutex.unlock();

        const dir = try self.runDir(run_id);
        defer gpa.free(dir);

        const rootfd = self.prepareDir(dir) catch |e| switch (e) {
            error.PathAlreadyExists => return error.RunExists,
            else => return e,
        };
        var root_owned = true;
        errdefer if (root_owned) sys.close(rootfd);
        errdefer self.removePrepared(run_id);

        tar.extract(archive_path, rootfd) catch |e| {
            log.warn("run {s}: archive extraction failed: {s}", .{ run_id, @errorName(e) });
            return e;
        };

        const factor = self.cpu_factor(self.factor_ctx);
        const raw_timeout = if (timeout_ms == 0) self.cfg.run_timeout_ms else timeout_ms;
        const rt = try runtime.RunContext.init(
            run_id,
            dir,
            rootfd,
            sink,
            self.cfg,
            self.client,
            raw_timeout,
            factor,
        );
        root_owned = false;
        errdefer rt.deinit();

        const hid = try gpa.dupe(u8, run_id);
        errdefer gpa.free(hid);
        const hrunner = try gpa.dupe(u8, runner);
        errdefer gpa.free(hrunner);
        const h = try gpa.create(RunHandle);
        errdefer gpa.destroy(h);
        h.* = .{
            .mgr = self,
            .id = hid,
            .runner = hrunner,
            .rt = rt,
            .thread = undefined,
        };

        const key = try gpa.dupe(u8, run_id);
        errdefer gpa.free(key);
        var inserted = false;
        errdefer if (inserted) {
            self.mutex.lock();
            if (self.runs.fetchRemove(run_id)) |kv| gpa.free(kv.key);
            self.mutex.unlock();
        };
        self.mutex.lock();
        if (self.stopping or self.runs.contains(run_id)) {
            self.mutex.unlock();
            return error.RunExists;
        }
        try self.runs.put(key, h);
        inserted = true;
        self.mutex.unlock();

        h.thread = try std.Thread.spawn(.{}, threadMain, .{h});
        inserted = false; // ownership transferred to the thread/registry
        log.info("run {s}: started (runner={s}, timeout={d}ms)", .{ run_id, runner, raw_timeout });
        return h;
    }

    fn prepareDir(_: *Manager, dir: []const u8) !sys.fd_t {
        var zb: [fs.max_path + 1]u8 = undefined;
        if (dir.len + 1 > zb.len) return error.PathTooLong;
        @memcpy(zb[0..dir.len], dir);
        zb[dir.len] = 0;
        const z = zb[0..dir.len :0];
        sys.mkdirat(std.os.linux.AT.FDCWD, z, 0o700) catch |e| switch (e) {
            error.AlreadyExists => return error.PathAlreadyExists,
            else => return e,
        };
        errdefer sys.unlinkat(std.os.linux.AT.FDCWD, z, std.os.linux.AT.REMOVEDIR) catch {};
        return sys.openat(std.os.linux.AT.FDCWD, z, .{
            .ACCMODE = .RDONLY,
            .DIRECTORY = true,
            .CLOEXEC = true,
        }, 0);
    }

    fn removePrepared(self: *Manager, run_id: []const u8) void {
        var wb: [fs.max_path + 1]u8 = undefined;
        if (self.cfg.work_root.len + 1 > wb.len) return;
        @memcpy(wb[0..self.cfg.work_root.len], self.cfg.work_root);
        wb[self.cfg.work_root.len] = 0;
        const fd = sys.openat(std.os.linux.AT.FDCWD, wb[0..self.cfg.work_root.len :0], .{
            .ACCMODE = .RDONLY,
            .DIRECTORY = true,
            .CLOEXEC = true,
        }, 0) catch return;
        defer sys.close(fd);
        fs.removeTreeBeneath(fd, run_id) catch {};
    }

    fn threadMain(h: *RunHandle) void {
        executor.execute(h.rt, .{ .runner = h.runner });
        h.done.store(true, .release);
        h.mgr.removeRun(h.id);
        log.info("run {s}: finished", .{h.id});
    }
};

fn validRunId(s: []const u8) bool {
    if (s.len == 0 or s.len > 128) return false;
    if (s[0] == '.') return false;
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != '.') return false;
    }
    return true;
}

/// Streaming tar upload.  The archive is written to a private file below the
/// work root and handed to `startRun` once complete.
pub const ArchiveUpload = struct {
    mgr: *Manager,
    path: []u8,
    dirfd: sys.fd_t,
    fd: sys.fd_t,
    size: usize = 0,
    max_size: usize,
    finished: bool = false,

    pub fn append(self: *ArchiveUpload, data: []const u8) !void {
        if (self.fd < 0) return error.ArchiveClosed;
        if (self.size + data.len > self.max_size) return error.ArchiveTooLarge;
        try sys.writeAll(self.fd, data);
        self.size += data.len;
    }

    /// Close the file and return the path.  Ownership of the returned path is
    /// transferred to the caller.
    pub fn finish(self: *ArchiveUpload) ![]u8 {
        if (self.fd < 0) return error.ArchiveClosed;
        sys.close(self.fd);
        self.fd = -1;
        self.finished = true;
        const p = self.path;
        self.path = try gpa.dupe(u8, "");
        return p;
    }

    pub fn deinit(self: *ArchiveUpload) void {
        if (self.fd >= 0) sys.close(self.fd);
        if (self.path.len > 0) unlinkAbsolute(self.path);
        gpa.free(self.path);
        sys.close(self.dirfd);
        self.* = undefined;
    }
};

fn unlinkAbsolute(path: []const u8) void {
    if (path.len == 0) return;
    var zb: [fs.max_path + 1]u8 = undefined;
    if (path.len + 1 > zb.len) return;
    @memcpy(zb[0..path.len], path);
    zb[path.len] = 0;
    sys.unlinkat(std.os.linux.AT.FDCWD, zb[0..path.len :0], 0) catch {};
}

pub fn beginArchive(mgr: *Manager) !ArchiveUpload {
    const incoming = try std.fmt.allocPrint(gpa, "{s}/.incoming", .{mgr.cfg.work_root});
    defer gpa.free(incoming);
    try fs.makeDirAllAbsolute(incoming);
    const fd = try openDirAbsolute(incoming);
    errdefer sys.close(fd);

    var raw: [12]u8 = undefined;
    try sys.getrandom(&raw);
    var name_buf: [32]u8 = undefined;
    const hex = "0123456789abcdef";
    for (raw, 0..) |b, i| {
        name_buf[i * 2] = hex[b >> 4];
        name_buf[i * 2 + 1] = hex[b & 0xf];
    }
    const name = name_buf[0 .. raw.len * 2];
    var nb: [64]u8 = undefined;
    @memcpy(nb[0..name.len], name);
    @memcpy(nb[name.len .. name.len + 4], ".tar");
    const fname = nb[0 .. name.len + 4];
    var zb: [64]u8 = undefined;
    @memcpy(zb[0..fname.len], fname);
    zb[fname.len] = 0;
    const ffd = try sys.openat(fd, zb[0..fname.len :0], .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .EXCL = true,
        .CLOEXEC = true,
    }, 0o600);
    errdefer sys.close(ffd);
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ incoming, fname });
    return .{
        .mgr = mgr,
        .path = path,
        .dirfd = fd,
        .fd = ffd,
        .max_size = @max(mgr.cfg.grpc_max_message, 16 * 1024 * 1024),
    };
}

fn openDirAbsolute(path: []const u8) !sys.fd_t {
    var zb: [fs.max_path + 1]u8 = undefined;
    if (path.len + 1 > zb.len) return error.PathTooLong;
    @memcpy(zb[0..path.len], path);
    zb[path.len] = 0;
    return sys.openat(std.os.linux.AT.FDCWD, zb[0..path.len :0], .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .CLOEXEC = true,
    }, 0);
}
