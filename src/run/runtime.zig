//! Data model shared by the Lua executor and the gRPC front end.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("../util/sys.zig");
const fs = @import("../util/fs.zig");
const http = @import("../util/http.zig");
const clock = @import("../util/clock.zig");
const log = @import("../util/log.zig");
const mutexmod = @import("../util/mutex.zig");
const podman = @import("../podman/client.zig");
const events = @import("../events.zig");
const configmod = @import("../config.zig");
const gpa = @import("../util/mem.zig").gpa;

const Mutex = mutexmod.Mutex;
const Condition = mutexmod.Condition;

pub const StdioMode = enum {
    none,
    capture,
    stream,
    pipe,

    pub fn parse(s: []const u8) ?StdioMode {
        if (std.mem.eql(u8, s, "none") or std.mem.eql(u8, s, "null")) return .none;
        if (std.mem.eql(u8, s, "capture") or std.mem.eql(u8, s, "captured")) return .capture;
        if (std.mem.eql(u8, s, "stream") or std.mem.eql(u8, s, "streamed")) return .stream;
        if (std.mem.eql(u8, s, "pipe") or std.mem.eql(u8, s, "piped")) return .pipe;
        return null;
    }
};

pub const Stream = enum { stdout, stderr };

pub const ContainerState = enum { created, running, exited, removed, failed };

/// Bounded byte history with a read cursor.  All access is serialised by the
/// owning container's mutex.
pub const History = struct {
    buf: std.ArrayList(u8) = .empty,
    head: usize = 0,
    read_pos: usize = 0,
    truncated: bool = false,
    eof: bool = false,
    cap: usize,

    pub fn init(cap: usize) History {
        return .{ .cap = cap };
    }

    pub fn deinit(self: *History) void {
        self.buf.deinit(gpa);
        self.* = undefined;
    }

    pub fn len(self: *const History) usize {
        return self.buf.items.len - self.head;
    }

    pub fn available(self: *const History) usize {
        if (self.read_pos >= self.buf.items.len) return 0;
        return self.buf.items.len - self.read_pos;
    }

    /// Append data, dropping the oldest retained bytes if the cap is reached.
    /// Returns the number of bytes dropped from the front.
    pub fn append(self: *History, data: []const u8) !usize {
        if (data.len == 0) return 0;
        var dropped: usize = 0;
        if (data.len >= self.cap) {
            dropped = self.len();
            self.buf.clearRetainingCapacity();
            self.head = 0;
            self.read_pos = 0;
            const keep = data.len - self.cap;
            try self.buf.appendSlice(gpa, data[keep..]);
            self.truncated = true;
            return dropped + keep;
        }
        try self.buf.appendSlice(gpa, data);
        while (self.len() > self.cap) {
            const excess = self.len() - self.cap;
            self.head += excess;
            dropped += excess;
            self.truncated = true;
            if (self.read_pos < self.head) self.read_pos = self.head;
        }
        // Compact when the discarded prefix grows large.
        if (self.head > 64 * 1024 and self.head * 2 > self.buf.items.len) {
            const rest = self.buf.items.len - self.head;
            std.mem.copyForwards(u8, self.buf.items[0..rest], self.buf.items[self.head..]);
            self.buf.shrinkRetainingCapacity(rest);
            self.read_pos -= self.head;
            self.head = 0;
        }
        return dropped;
    }

    /// Copy unread data (at most `max`) and advance the read cursor.
    pub fn take(self: *History, max: usize) ![]u8 {
        const n = @min(self.available(), max);
        if (n == 0) return gpa.alloc(u8, 0);
        const out = try gpa.dupe(u8, self.buf.items[self.read_pos .. self.read_pos + n]);
        self.read_pos += n;
        return out;
    }

    pub fn snapshot(self: *const History) ![]u8 {
        return gpa.dupe(u8, self.buf.items[self.head..]);
    }

    pub fn unreadCopy(self: *const History, max: usize) ![]u8 {
        const n = @min(self.available(), max);
        return gpa.dupe(u8, self.buf.items[self.read_pos .. self.read_pos + n]);
    }
};

pub const Container = struct {
    rt: *RunContext,
    id: []u8,
    name: []u8,
    image: []u8,
    stdio: StdioMode = .capture,
    test_no: u32 = 0,
    state: ContainerState = .created,

    mutex: Mutex = .{},
    cond: Condition = .{},
    wait_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    exit_code: i32 = -1,
    oom_killed: bool = false,
    error_message: []u8,
    cgroup_path: ?[]u8 = null,
    cpu_usage_usec: u64 = 0,
    memory_peak: u64 = 0,

    attach_fd: sys.fd_t = -1,
    reader: ?std.Thread = null,
    waiter: ?std.Thread = null,
    sampler: ?std.Thread = null,
    stop_sampler: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stop_reader: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stdin_open: bool = false,
    attached: bool = false,
    removed: bool = false,
    killed: bool = false,
    pipe_to: ?*Container = null,

    stdout: History,
    stderr: History,

    pub fn init(rt: *RunContext, id: []u8, name: []u8, image: []u8, stdio: StdioMode, test_no: u32) !*Container {
        const c = try gpa.create(Container);
        c.* = .{
            .rt = rt,
            .id = id,
            .name = name,
            .image = image,
            .stdio = stdio,
            .test_no = test_no,
            .error_message = try gpa.dupe(u8, ""),
            .stdout = History.init(rt.history_limit),
            .stderr = History.init(rt.history_limit),
        };
        return c;
    }

    pub fn deinit(self: *Container) void {
        // stop and join the reader
        self.stop_reader.store(true, .monotonic);
        self.stop_sampler.store(true, .monotonic);
        if (self.attach_fd >= 0) {
            sys.shutdown(self.attach_fd, linux.SHUT.RDWR);
        }
        if (self.reader) |t| t.join();
        // make sure the container is gone, then join the waiter
        if (!self.removed) {
            self.rt.podman_client.killContainer(self.id) catch {};
            self.rt.podman_client.removeContainer(self.id) catch {};
            self.removed = true;
        }
        if (self.waiter) |t| t.join();
        if (self.attach_fd >= 0) sys.close(self.attach_fd);
        self.stdout.deinit();
        self.stderr.deinit();
        gpa.free(self.id);
        gpa.free(self.name);
        gpa.free(self.image);
        gpa.free(self.error_message);
        if (self.cgroup_path) |p| gpa.free(p);
        gpa.destroy(self);
    }

    pub fn start(self: *Container) !void {
        // Attach before starting so that no output is lost.  The hijacked
        // connection stays open for the lifetime of the container.
        if (self.stdio != .none) {
            const h = self.rt.podman_client.attach(self.id, true, true, true) catch |e| blk: {
                log.warn("attach failed for {s}: {s}", .{ self.name, @errorName(e) });
                break :blk null;
            };
            if (h) |hij| {
                self.attach_fd = hij.fd;
                self.attached = true;
                self.stdin_open = true;
                self.reader = try std.Thread.spawn(.{}, readerThread, .{ self, hij.leftover });
                // hij.leftover ownership moved to the reader; the fd stays.
                // (deinit closes the fd after joining the reader.)
            }
        }
        self.rt.podman_client.startContainer(self.id) catch |e| {
            self.setError(@errorName(e));
            self.state = .failed;
            return e;
        };
        self.state = .running;
        self.sampler = std.Thread.spawn(.{}, samplerThread, .{self}) catch null;
        self.waiter = std.Thread.spawn(.{}, waiterThread, .{self}) catch |e| {
            self.stop_sampler.store(true, .monotonic);
            if (self.sampler) |t| {
                t.join();
                self.sampler = null;
            }
            return e;
        };
    }

    fn setError(self: *Container, msg: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        gpa.free(self.error_message);
        self.error_message = gpa.dupe(u8, msg) catch gpa.dupe(u8, "error") catch return;
    }

    fn addOutput(self: *Container, stream: Stream, data: []const u8) void {
        if (data.len == 0) return;
        self.mutex.lock();
        const h = switch (stream) {
            .stdout => &self.stdout,
            .stderr => &self.stderr,
        };
        const dropped = h.append(data) catch 0;
        _ = dropped;
        const pipe_dest = if (self.pipe_to) |p| p else null;
        if (self.stdio == .stream) {
            self.rt.emitTestStdio(self.test_no, stream, data);
        }
        self.cond.broadcast();
        self.mutex.unlock();
        if (pipe_dest) |p| p.writeStdin(data) catch |e| {
            log.debug("pipe write to {s} failed: {s}", .{ p.name, @errorName(e) });
        };
    }

    fn readerThread(self: *Container, leftover: []u8) void {
        defer if (leftover.len > 0) gpa.free(leftover);
        var pending: std.ArrayList(u8) = .empty;
        defer pending.deinit(gpa);
        if (leftover.len > 0) pending.appendSlice(gpa, leftover) catch {};

        var buf: [64 * 1024]u8 = undefined;
        var header: [8]u8 = undefined;
        var need: usize = 8;

        while (!self.stop_reader.load(.monotonic)) {
            // Try to satisfy the current frame from the pending buffer first.
            while (pending.items.len >= need) {
                if (need == 8) {
                    @memcpy(&header, pending.items[0..8]);
                    const len = std.mem.readInt(u32, header[4..8], .big);
                    if (len > 64 * 1024 * 1024) {
                        self.stop_reader.store(true, .monotonic);
                        return;
                    }
                    need = 8 + len;
                } else {
                    const len = need - 8;
                    const stream_no = header[0];
                    const payload = pending.items[8 .. 8 + len];
                    const st: Stream = if (stream_no == 2) .stderr else .stdout;
                    self.addOutput(st, payload);
                    // remove the frame
                    const rest = pending.items.len - need;
                    std.mem.copyForwards(u8, pending.items[0..rest], pending.items[need..]);
                    pending.shrinkRetainingCapacity(rest);
                    need = 8;
                }
            }

            var pfds = [_]linux.pollfd{.{ .fd = self.attach_fd, .events = linux.POLL.IN, .revents = 0 }};
            const pr = sys.poll(&pfds, 100) catch break;
            if (pr == 0) continue;
            if (pfds[0].revents & (linux.POLL.ERR | linux.POLL.NVAL | linux.POLL.HUP) != 0 and
                pfds[0].revents & linux.POLL.IN == 0)
            {
                break;
            }
            const n = sys.read(self.attach_fd, &buf) catch |e| switch (e) {
                error.Again => continue,
                else => break,
            };
            if (n == 0) break;
            pending.appendSlice(gpa, buf[0..n]) catch break;
        }

        self.mutex.lock();
        self.stdout.eof = true;
        self.stderr.eof = true;
        self.cond.broadcast();
        self.mutex.unlock();
    }

    fn waiterThread(self: *Container) void {
        const code = self.rt.podman_client.waitContainer(self.id) catch |e| blk: {
            self.setError(@errorName(e));
            break :blk @as(i32, -1);
        };
        self.mutex.lock();
        self.exit_code = code;
        self.mutex.unlock();
        if (self.rt.podman_client.inspectContainer(self.id)) |info| {
            defer {
                var i = info;
                i.deinit();
            }
            self.mutex.lock();
            self.exit_code = @intCast(info.exit_code);
            self.oom_killed = info.oom_killed;
            if (info.error_message.len > 0) {
                gpa.free(self.error_message);
                self.error_message = gpa.dupe(u8, info.error_message) catch self.error_message;
            }
            if (self.cgroup_path == null) {
                if (info.cgroup_path.len > 0) {
                    self.cgroup_path = gpa.dupe(u8, info.cgroup_path) catch null;
                } else if (info.pid > 0) {
                    var pbuf: [fs.max_path + 1]u8 = undefined;
                    if (podman.readCgroupPath(info.pid, &pbuf)) |cg| {
                        self.cgroup_path = gpa.dupe(u8, cg) catch null;
                    }
                }
            }
            self.mutex.unlock();
        } else |_| {}

        // The kernel removes the container cgroup as soon as the process
        // exits, so the sampler keeps the last accounting value observed while
        // the container was alive.
        self.stop_sampler.store(true, .monotonic);
        if (self.sampler) |t| {
            t.join();
            self.sampler = null;
        }
        self.mutex.lock();
        if (self.cgroup_path) |cg| {
            const stats = podman.readCgroupStats(cg);
            if (stats.cpu_usage_usec > self.cpu_usage_usec) self.cpu_usage_usec = stats.cpu_usage_usec;
            if (stats.memory_peak > self.memory_peak) self.memory_peak = stats.memory_peak;
        }
        self.state = .exited;
        self.wait_done.store(true, .monotonic);
        self.cond.broadcast();
        self.mutex.unlock();
    }

    /// Sample cgroup CPU/memory accounting while the container is alive.  The
    /// cgroup is deleted on exit, so `waiterThread` reads the last sample.
    fn samplerThread(self: *Container) void {
        var path_buf: [fs.max_path + 1]u8 = undefined;
        var path_len: usize = 0;
        const discovery_deadline = clock.nowNs() + 5 * clock.ns_per_sec;

        while (path_len == 0 and !self.stop_sampler.load(.monotonic)) {
            if (self.rt.podman_client.inspectContainer(self.id)) |info| {
                defer {
                    var i = info;
                    i.deinit();
                }
                if (info.cgroup_path.len > 0 and info.cgroup_path.len <= fs.max_path) {
                    @memcpy(path_buf[0..info.cgroup_path.len], info.cgroup_path);
                    path_len = info.cgroup_path.len;
                } else if (info.pid > 0) {
                    if (podman.readCgroupPath(info.pid, &path_buf)) |cg| path_len = cg.len;
                }
                if (std.mem.eql(u8, info.status, "exited") or std.mem.eql(u8, info.status, "stopped")) return;
            } else |_| {}
            if (path_len > 0) break;
            if (clock.nowNs() >= discovery_deadline) return;
            clock.sleepMs(2);
        }
        if (path_len == 0) return;

        self.mutex.lock();
        if (self.cgroup_path) |old| gpa.free(old);
        self.cgroup_path = gpa.dupe(u8, path_buf[0..path_len]) catch null;
        self.mutex.unlock();

        while (!self.stop_sampler.load(.monotonic)) {
            const stats = podman.readCgroupStats(path_buf[0..path_len]);
            self.mutex.lock();
            if (stats.cpu_usage_usec > self.cpu_usage_usec) self.cpu_usage_usec = stats.cpu_usage_usec;
            if (stats.memory_peak > self.memory_peak) self.memory_peak = stats.memory_peak;
            self.mutex.unlock();
            clock.sleepMs(5);
        }
    }

    pub fn writeStdin(self: *Container, data: []const u8) !void {
        self.mutex.lock();
        if (!self.stdin_open or self.attach_fd < 0) {
            self.mutex.unlock();
            return error.StdinClosed;
        }
        const fd = self.attach_fd;
        self.mutex.unlock();
        try writeAllTimeout(fd, data, 30_000);
    }

    pub fn closeStdin(self: *Container) void {
        self.mutex.lock();
        if (self.stdin_open and self.attach_fd >= 0) {
            sys.shutdown(self.attach_fd, linux.SHUT.WR);
        }
        self.stdin_open = false;
        self.mutex.unlock();
    }

    pub fn stop(self: *Container, grace_ms: u64) void {
        const secs: u32 = @intCast(@min(grace_ms / 1000, 3600));
        self.rt.podman_client.stopContainer(self.id, secs) catch {};
    }

    pub fn kill(self: *Container) void {
        self.killed = true;
        self.rt.podman_client.killContainer(self.id) catch {};
    }

    pub fn remove(self: *Container) void {
        self.rt.podman_client.removeContainer(self.id) catch {};
        self.mutex.lock();
        self.removed = true;
        self.mutex.unlock();
    }

    pub fn waitExit(self: *Container) i32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.exit_code;
    }

    pub fn isDone(self: *Container) bool {
        return self.wait_done.load(.monotonic);
    }

    pub fn readAvailable(self: *Container, stream: Stream, max: usize) !?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const h = switch (stream) {
            .stdout => &self.stdout,
            .stderr => &self.stderr,
        };
        if (h.available() > 0) return try h.take(max);
        if (h.eof or self.wait_done.load(.monotonic)) return null;
        return null;
    }

    pub fn snapshot(self: *Container, stream: Stream) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return switch (stream) {
            .stdout => self.stdout.snapshot(),
            .stderr => self.stderr.snapshot(),
        };
    }

    pub fn truncated(self: *Container, stream: Stream) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return switch (stream) {
            .stdout => self.stdout.truncated,
            .stderr => self.stderr.truncated,
        };
    }
};

fn writeAllTimeout(fd: sys.fd_t, data: []const u8, timeout_ms: i32) !void {
    var off: usize = 0;
    while (off < data.len) {
        const n = sys.write(fd, data[off..]) catch |e| switch (e) {
            error.Again => blk: {
                var pfds = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.OUT, .revents = 0 }};
                const pr = try sys.poll(&pfds, timeout_ms);
                if (pr == 0) return error.Timeout;
                break :blk try sys.write(fd, data[off..]);
            },
            else => return e,
        };
        if (n == 0) return error.Closed;
        off += n;
    }
}

pub const RunContext = struct {
    run_id: []u8,
    dir_abs: []u8,
    rootfd: sys.fd_t,
    sink: events.Sink,
    cfg: *const configmod.Config,
    podman_client: *podman.Client,
    timeout_ms: u64,
    start_ns: i128,
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cancel_mutex: Mutex = .{},
    cancel_reason: []u8,
    containers_mutex: Mutex = .{},
    containers: std.ArrayList(*Container) = .empty,
    networks_mutex: Mutex = .{},
    networks: std.ArrayList([]u8) = .empty,
    images_mutex: Mutex = .{},
    images: std.ArrayList([]u8) = .empty,
    history_limit: usize,
    seq: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    current_test: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    cpu_factor: f64 = 1.0,

    pub fn init(
        run_id: []const u8,
        dir_abs: []const u8,
        rootfd: sys.fd_t,
        sink: events.Sink,
        cfg: *const configmod.Config,
        client: *podman.Client,
        timeout_ms: u64,
        cpu_factor: f64,
    ) !*RunContext {
        const rt = try gpa.create(RunContext);
        rt.* = .{
            .run_id = try gpa.dupe(u8, run_id),
            .dir_abs = try gpa.dupe(u8, dir_abs),
            .rootfd = rootfd,
            .sink = sink,
            .cfg = cfg,
            .podman_client = client,
            .timeout_ms = timeout_ms,
            .start_ns = clock.nowNs(),
            .cancel_reason = try gpa.dupe(u8, ""),
            .history_limit = cfg.stdio_history_limit,
            .cpu_factor = cpu_factor,
        };
        return rt;
    }

    pub fn deinit(self: *RunContext) void {
        // Containers are normally cleaned up by the executor; this is a last
        // resort for partially initialised runs.
        self.containers_mutex.lock();
        const list = self.containers.toOwnedSlice(gpa) catch &.{};
        self.containers_mutex.unlock();
        for (list) |c| c.deinit();
        if (list.len > 0) gpa.free(list);

        self.networks_mutex.lock();
        const nets = self.networks.toOwnedSlice(gpa) catch &.{};
        self.networks_mutex.unlock();
        for (nets) |n| {
            self.podman_client.removeNetwork(n) catch {};
            gpa.free(n);
        }
        if (nets.len > 0) gpa.free(nets);

        self.images_mutex.lock();
        const imgs = self.images.toOwnedSlice(gpa) catch &.{};
        self.images_mutex.unlock();
        for (imgs) |n| {
            self.podman_client.removeImage(n) catch {};
            gpa.free(n);
        }
        if (imgs.len > 0) gpa.free(imgs);

        sys.close(self.rootfd);
        gpa.free(self.run_id);
        gpa.free(self.dir_abs);
        gpa.free(self.cancel_reason);
        gpa.destroy(self);
    }

    pub fn emit(self: *RunContext, ev: events.Event) void {
        self.sink.emit(ev);
    }

    pub fn emitTestStdio(self: *RunContext, n: u32, stream: Stream, data: []const u8) void {
        const stdin = gpa.alloc(u8, 0) catch return;
        const stdout = if (stream == .stdout) gpa.dupe(u8, data) catch {
            gpa.free(stdin);
            return;
        } else gpa.alloc(u8, 0) catch {
            gpa.free(stdin);
            return;
        };
        const stderr = if (stream == .stderr) gpa.dupe(u8, data) catch {
            gpa.free(stdin);
            gpa.free(stdout);
            return;
        } else gpa.alloc(u8, 0) catch {
            gpa.free(stdin);
            gpa.free(stdout);
            return;
        };
        self.emit(.{ .test_stdio = .{ .n = n, .stdin = stdin, .stdout = stdout, .stderr = stderr } });
    }

    pub fn cancel(self: *RunContext, reason: []const u8) void {
        if (self.cancelled.swap(true, .acq_rel)) return;
        self.cancel_mutex.lock();
        gpa.free(self.cancel_reason);
        self.cancel_reason = gpa.dupe(u8, reason) catch gpa.dupe(u8, "cancelled") catch return;
        self.cancel_mutex.unlock();
        // Kill containers immediately; the executor will join the threads.
        self.containers_mutex.lock();
        const items = self.containers.items;
        self.containers_mutex.unlock();
        for (items) |c| c.kill();
    }

    pub fn isCancelled(self: *RunContext) bool {
        return self.cancelled.load(.acquire);
    }

    pub fn cancelReason(self: *RunContext) []const u8 {
        self.cancel_mutex.lock();
        defer self.cancel_mutex.unlock();
        return self.cancel_reason;
    }

    pub fn elapsedMs(self: *RunContext) u64 {
        const ns = clock.nowNs() - self.start_ns;
        if (ns <= 0) return 0;
        return @intCast(@divTrunc(ns, 1_000_000));
    }

    pub fn timedOut(self: *RunContext) bool {
        return self.elapsedMs() >= self.timeout_ms;
    }

    pub fn addContainer(self: *RunContext, c: *Container) !void {
        self.containers_mutex.lock();
        defer self.containers_mutex.unlock();
        try self.containers.append(gpa, c);
    }

    pub fn removeContainerFromList(self: *RunContext, c: *Container) void {
        self.containers_mutex.lock();
        defer self.containers_mutex.unlock();
        var i: usize = 0;
        while (i < self.containers.items.len) : (i += 1) {
            if (self.containers.items[i] == c) {
                _ = self.containers.orderedRemove(i);
                return;
            }
        }
    }

    pub fn addNetwork(self: *RunContext, name: []const u8) !void {
        self.networks_mutex.lock();
        defer self.networks_mutex.unlock();
        try self.networks.append(gpa, try gpa.dupe(u8, name));
    }

    pub fn addImage(self: *RunContext, name: []const u8) !void {
        self.images_mutex.lock();
        defer self.images_mutex.unlock();
        try self.images.append(gpa, try gpa.dupe(u8, name));
    }

    pub fn nextName(self: *RunContext, prefix: []const u8) ![]u8 {
        const n = self.seq.fetchAdd(1, .monotonic);
        const short = self.run_id[0..@min(self.run_id.len, 8)];
        return std.fmt.allocPrint(gpa, "{s}-{s}-{d}", .{ prefix, short, n });
    }

    pub fn setCurrentTest(self: *RunContext, n: u32) void {
        self.current_test.store(n, .monotonic);
    }

    pub fn currentTest(self: *RunContext) u32 {
        return self.current_test.load(.monotonic);
    }
};
