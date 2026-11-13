//! gRPC (HTTP/2) front end built on nghttp2.
//!
//! One bidirectional `Invoker.Run` stream is served per TCP connection.  The
//! connection thread owns the nghttp2 session; executor threads only append
//! framed messages to a queue and wake the connection through an eventfd.
const std = @import("std");
const linux = std.os.linux;
const c = @import("nghttp2_c");
const configmod = @import("../config.zig");
const events = @import("../events.zig");
const manager = @import("../run/manager.zig");
const messages = @import("messages.zig");
const http = @import("../util/http.zig");
const sys = @import("../util/sys.zig");
const clock = @import("../util/clock.zig");
const log = @import("../util/log.zig");
const gpa = @import("../util/mem.zig").gpa;

const GrpcStatus = struct {
    const ok: u32 = 0;
    const cancelled: u32 = 1;
    const invalid_argument: u32 = 3;
    const resource_exhausted: u32 = 8;
    const internal: u32 = 13;
    const unauthenticated: u32 = 16;
    const unimplemented: u32 = 12;
};

pub const Server = struct {
    cfg: *const configmod.Config,
    mgr: *manager.Manager,
    instance_id: []const u8,
    token: []const u8,
    listen_fd: sys.fd_t = -1,
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mutex: @import("../util/mutex.zig").Mutex = .{},
    cond: @import("../util/mutex.zig").Condition = .{},
    conns: std.ArrayList(*Conn) = .empty,

    pub fn init(
        cfg: *const configmod.Config,
        mgr: *manager.Manager,
        instance_id: []const u8,
        token: []const u8,
    ) !*Server {
        const s = try gpa.create(Server);
        s.* = .{
            .cfg = cfg,
            .mgr = mgr,
            .instance_id = instance_id,
            .token = token,
        };
        return s;
    }

    pub fn deinit(self: *Server) void {
        self.stop();
        // Wait for connection threads to finish and release their runs.
        self.mutex.lock();
        while (self.conns.items.len > 0) {
            self.cond.wait(&self.mutex);
        }
        self.conns.deinit(gpa);
        self.mutex.unlock();
        gpa.destroy(self);
    }

    /// Start accepting connections.  Blocks until `stop` is called.
    pub fn run(self: *Server) !void {
        const addr = try http.parseTcpAddr(self.cfg.listen);
        self.listen_fd = try http.listenTcp(addr, 128);
        defer {
            sys.close(self.listen_fd);
            self.listen_fd = -1;
        }
        sys.setNonblocking(self.listen_fd, true);
        log.info("gRPC listening on {s}", .{self.cfg.listen});

        while (!self.stopping.load(.acquire)) {
            const fd = sys.accept(self.listen_fd) catch |e| switch (e) {
                error.Again => {
                    var pfds = [_]linux.pollfd{.{ .fd = self.listen_fd, .events = linux.POLL.IN, .revents = 0 }};
                    _ = sys.poll(&pfds, 200) catch {};
                    continue;
                },
                else => {
                    if (self.stopping.load(.acquire)) break;
                    log.warn("accept failed: {s}", .{@errorName(e)});
                    continue;
                },
            };
            sys.setNonblocking(fd, true);
            self.spawnConn(fd);
        }
    }

    fn spawnConn(self: *Server, fd: sys.fd_t) void {
        const conn = gpa.create(Conn) catch {
            sys.close(fd);
            return;
        };
        conn.* = .{
            .server = self,
            .fd = fd,
            .wake_fd = sys.eventfd() catch {
                sys.close(fd);
                gpa.destroy(conn);
                return;
            },
        };
        self.mutex.lock();
        self.conns.append(gpa, conn) catch {
            self.mutex.unlock();
            conn.deinitResources();
            gpa.destroy(conn);
            return;
        };
        self.mutex.unlock();
        const t = std.Thread.spawn(.{}, connMain, .{conn}) catch {
            self.removeConn(conn);
            conn.deinitResources();
            gpa.destroy(conn);
            return;
        };
        t.detach();
    }

    fn removeConn(self: *Server, conn: *Conn) void {
        self.mutex.lock();
        for (self.conns.items, 0..) |item, i| {
            if (item == conn) {
                _ = self.conns.swapRemove(i);
                break;
            }
        }
        self.cond.broadcast();
        self.mutex.unlock();
    }

    /// Async-signal-safe shutdown request: only touches an atomic.
    pub fn signalStop(self: *Server) void {
        self.stopping.store(true, .release);
    }

    pub fn stop(self: *Server) void {
        self.stopping.store(true, .release);
        self.mutex.lock();
        for (self.conns.items) |conn| conn.requestStop();
        self.mutex.unlock();
        // Wake the blocking accept via a self-connection.
        if (self.listen_fd >= 0) {
            const addr = http.parseTcpAddr(self.cfg.listen) catch return;
            const fd = http.connectTcp(addr) catch return;
            sys.close(fd);
        }
    }

    fn authOk(self: *const Server, value: []const u8) bool {
        if (std.mem.startsWith(u8, value, "Bearer ")) return constantTimeEq(value[7..], self.token);
        return constantTimeEq(value, self.token);
    }
};

fn deleteFileAbs(path: []const u8) void {
    if (path.len == 0) return;
    var zb: [4097]u8 = undefined;
    if (path.len + 1 > zb.len) return;
    @memcpy(zb[0..path.len], path);
    zb[path.len] = 0;
    sys.unlinkat(std.os.linux.AT.FDCWD, zb[0..path.len :0], 0) catch {};
}

fn constantTimeEq(a: []const u8, b: []const u8) bool {
    var diff: usize = a.len ^ b.len;
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n) : (i += 1) diff |= a[i] ^ b[i];
    return diff == 0;
}

fn connMain(conn: *Conn) void {
    conn.serve();
    conn.server.removeConn(conn);
    conn.deinitResources();
    gpa.destroy(conn);
}

/// Send FIN, then drain inbound bytes until the peer closes (or a short
/// deadline).  Closing a socket with unread request data makes the kernel
/// emit RST, which can discard the response before the client reads it.
fn gracefulClose(fd: sys.fd_t, deadline_ms: u64) void {
    if (fd < 0) return;
    sys.shutdown(fd, std.os.linux.SHUT.WR);
    const deadline = clock.nowNs() + @as(i128, @intCast(deadline_ms)) * 1_000_000;
    var buf: [16 * 1024]u8 = undefined;
    while (clock.nowNs() < deadline) {
        var pfds = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
        const n = sys.poll(&pfds, 50) catch break;
        if (n == 0) continue;
        if (pfds[0].revents & linux.POLL.IN != 0) {
            const got = sys.read(fd, &buf) catch break;
            if (got == 0) break;
        }
        if (pfds[0].revents & (linux.POLL.ERR | linux.POLL.HUP | linux.POLL.NVAL) != 0 and
            pfds[0].revents & linux.POLL.IN == 0)
        {
            break;
        }
    }
    sys.close(fd);
}

const HeaderBuf = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,

    fn set(self: *HeaderBuf, value: []const u8) void {
        self.len = @min(value.len, self.buf.len);
        @memcpy(self.buf[0..self.len], value[0..self.len]);
    }

    fn get(self: *const HeaderBuf) []const u8 {
        return self.buf[0..self.len];
    }
};

const Conn = struct {
    server: *Server,
    fd: sys.fd_t,
    wake_fd: sys.fd_t,
    session: ?*c.nghttp2_session = null,
    stream_id: i32 = 0,
    response_started: bool = false,
    request_headers_done: bool = false,
    stream_closed: bool = false,

    method: HeaderBuf = .{},
    path: HeaderBuf = .{},
    content_type: HeaderBuf = .{},
    auth: HeaderBuf = .{},

    // Incoming gRPC message reassembly.
    in_buf: std.ArrayList(u8) = .empty,
    in_off: usize = 0,

    // Request state.
    start: ?messages.Start = null,
    archive: ?manager.ArchiveUpload = null,
    archive_done: bool = false,
    run: ?*manager.RunHandle = null,
    started_at: i128 = 0,

    // Outgoing queue: concatenated gRPC messages.
    out_mutex: @import("../util/mutex.zig").Mutex = .{},
    out: std.ArrayList(u8) = .empty,
    out_off: usize = 0,
    deferred: bool = false,
    finishing: bool = false,
    data_eof: bool = false,
    trailers_sent: bool = false,
    rejected: bool = false,
    final_status: u32 = GrpcStatus.ok,
    final_message: []u8 = &.{},

    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn requestStop(self: *Conn) void {
        self.stop.store(true, .release);
        sys.eventfdSignal(self.wake_fd);
    }

    fn deinitResources(self: *Conn) void {
        if (self.archive) |*a| a.deinit();
        if (self.session) |s| c.nghttp2_session_del(s);
        self.session = null;
        self.in_buf.deinit(gpa);
        self.out.deinit(gpa);
        if (self.final_message.len > 0) gpa.free(self.final_message);
        sys.close(self.wake_fd);
        // fd is closed by run(), but be defensive if setup failed early.
        if (self.fd >= 0) {
            sys.close(self.fd);
            self.fd = -1;
        }
    }

    fn serve(self: *Conn) void {
        log.debug("conn: accepted", .{});
        defer log.debug("conn: closed", .{});
        defer if (self.fd >= 0) {
            gracefulClose(self.fd, 500);
            self.fd = -1;
        };

        var cbs: ?*c.nghttp2_session_callbacks = null;
        if (c.nghttp2_session_callbacks_new(&cbs) != 0) return;
        defer c.nghttp2_session_callbacks_del(cbs);
        c.nghttp2_session_callbacks_set_on_frame_recv_callback(cbs, onFrameRecv);
        c.nghttp2_session_callbacks_set_on_data_chunk_recv_callback(cbs, onDataChunk);
        c.nghttp2_session_callbacks_set_on_header_callback(cbs, onHeader);
        c.nghttp2_session_callbacks_set_on_begin_headers_callback(cbs, onBeginHeaders);
        c.nghttp2_session_callbacks_set_on_stream_close_callback(cbs, onStreamClose);
        c.nghttp2_session_callbacks_set_send_callback(cbs, onSend);

        var session: ?*c.nghttp2_session = null;
        if (c.nghttp2_session_server_new(&session, cbs, self) != 0) return;
        self.session = session;
        _ = c.nghttp2_submit_settings(session, c.NGHTTP2_FLAG_NONE, null, 0);

        var buf: [64 * 1024]u8 = undefined;
        while (!self.stop.load(.acquire)) {
            var events_ready = false;
            self.out_mutex.lock();
            events_ready = self.out.items.len > self.out_off or self.finishing;
            self.out_mutex.unlock();
            if (events_ready) {
                self.out_mutex.lock();
                const needs_resume = self.deferred and (self.out.items.len > self.out_off or self.finishing);
                self.out_mutex.unlock();
                if (needs_resume) {
                    _ = c.nghttp2_session_resume_data(session, self.stream_id);
                    self.deferred = false;
                }
            }

            if (self.finishing) {
                if (self.run) |h| {
                    // The executor emits run_finished as its last event;
                    // joining here guarantees the sink context stays alive
                    // while queued events are drained.
                    if (h.isDone()) h.join();
                }
            }

            const rv = c.nghttp2_session_send(session);
            if (rv != 0) {
                log.debug("nghttp2 send failed: {d}", .{rv});
                break;
            }
            if (self.data_eof and !self.trailers_sent) {
                self.submitTrailers();
                _ = c.nghttp2_session_send(session);
            }
            if (self.trailers_sent and !self.sessionWantsWrite(session)) break;

            var pfds = [_]linux.pollfd{
                .{ .fd = self.fd, .events = linux.POLL.IN, .revents = 0 },
                .{ .fd = self.wake_fd, .events = linux.POLL.IN, .revents = 0 },
            };
            const pr = sys.poll(&pfds, 200) catch break;
            if (pr == 0) continue;
            if (pfds[1].revents & linux.POLL.IN != 0) sys.eventfdDrain(self.wake_fd);
            if (pfds[0].revents & (linux.POLL.ERR | linux.POLL.HUP | linux.POLL.NVAL) != 0 and
                pfds[0].revents & linux.POLL.IN == 0)
            {
                log.debug("conn: poll error revents={d}", .{pfds[0].revents});
                break;
            }
            if (pfds[0].revents & linux.POLL.IN != 0) {
                const n = sys.read(self.fd, &buf) catch |e| switch (e) {
                    error.Again => continue,
                    else => break,
                };
                if (n == 0) break;
                const consumed = c.nghttp2_session_mem_recv(session, buf[0..n].ptr, n);
                if (consumed < 0) {
                    log.debug("nghttp2 recv failed: {d}", .{consumed});
                    break;
                }
            }
            if (!self.sessionWantsRead(session) and !self.sessionWantsWrite(session)) break;
        }

        // Client went away or the server is stopping: cancel the run and wait
        // for the executor before the sink context is destroyed.
        if (self.run) |h| {
            if (!h.isDone()) h.cancel("client disconnected");
            h.join();
            h.destroy();
            self.run = null;
        }
        if (self.archive) |*a| {
            a.deinit();
            self.archive = null;
        }
        if (self.start) |st| {
            gpa.free(st.run_id);
            gpa.free(st.runner);
            self.start = null;
        }
    }

    fn sessionWantsRead(self: *Conn, session: ?*c.nghttp2_session) bool {
        _ = self;
        return c.nghttp2_session_want_read(session) != 0;
    }

    fn sessionWantsWrite(self: *Conn, session: ?*c.nghttp2_session) bool {
        _ = self;
        return c.nghttp2_session_want_write(session) != 0;
    }

    fn submitTrailers(self: *Conn) void {
        self.trailers_sent = true;
        const session = self.session orelse return;
        var status_buf: [16]u8 = undefined;
        const status = std.fmt.bufPrint(&status_buf, "{d}", .{self.final_status}) catch "13";
        var msg_buf: [512]u8 = undefined;
        const msg = if (self.final_message.len > 0)
            std.fmt.bufPrint(&msg_buf, "{s}", .{self.final_message}) catch "error"
        else
            "";
        var nva = [_]c.nghttp2_nv{
            nv("grpc-status", status),
            nv("grpc-message", msg),
        };
        _ = c.nghttp2_submit_headers(session, c.NGHTTP2_FLAG_END_STREAM, self.stream_id, null, &nva, nva.len, null);
    }

    fn fail(self: *Conn, status: u32, message: []const u8) void {
        self.final_status = status;
        if (self.final_message.len > 0) gpa.free(self.final_message);
        self.final_message = gpa.dupe(u8, message) catch &.{};
        self.finishing = true;
        sys.eventfdSignal(self.wake_fd);
    }

    fn respondHeaders(self: *Conn) void {
        const session = self.session orelse return;
        var nva = [_]c.nghttp2_nv{
            nv(":status", "200"),
            nv("content-type", "application/grpc"),
            nv("grpc-accept-encoding", "identity"),
        };
        var provider = c.nghttp2_data_provider{
            .source = .{ .ptr = self },
            .read_callback = onReadData,
        };
        const rv = c.nghttp2_submit_response(session, self.stream_id, &nva, nva.len, &provider);
        if (rv == 0) self.response_started = true;
    }

    fn respondTrailersOnly(self: *Conn, status: u32, message: []const u8) void {
        const session = self.session orelse return;
        var status_buf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&status_buf, "{d}", .{status}) catch "13";
        var nva = [_]c.nghttp2_nv{
            nv(":status", "200"),
            nv("content-type", "application/grpc"),
            nv("grpc-status", s),
            nv("grpc-message", message),
        };
        _ = c.nghttp2_submit_response(session, self.stream_id, &nva, nva.len, null);
        self.response_started = true;
        self.trailers_sent = true;
        self.stream_closed = true;
        self.rejected = true;
    }

    fn enqueue(self: *Conn, frame: []const u8) void {
        self.out_mutex.lock();
        defer self.out_mutex.unlock();
        self.out.appendSlice(gpa, frame) catch return;
        sys.eventfdSignal(self.wake_fd);
    }

    fn enqueueGrpc(self: *Conn, payload: []const u8) void {
        var frame: std.ArrayList(u8) = .empty;
        defer frame.deinit(gpa);
        var head: [5]u8 = .{ 0, 0, 0, 0, 0 };
        std.mem.writeInt(u32, head[1..5], @intCast(payload.len), .big);
        frame.appendSlice(gpa, &head) catch return;
        frame.appendSlice(gpa, payload) catch return;
        self.enqueue(frame.items);
    }

    fn sink(self: *Conn) events.Sink {
        return .{ .ctx = self, .emit_fn = sinkEmit };
    }

    fn sinkEmit(ctx: *anyopaque, ev: events.Event) void {
        const self: *Conn = @ptrCast(@alignCast(ctx));
        self.emitEvent(ev);
    }

    fn emitEvent(self: *Conn, ev: events.Event) void {
        var owned = ev;
        defer owned.deinit();
        var inner: std.ArrayList(u8) = .empty;
        defer inner.deinit(gpa);
        messages.encodeEvent(ev, &inner) catch {
            self.fail(GrpcStatus.internal, "cannot encode event");
            return;
        };

        const limit = self.server.cfg.event_chunk;
        if (inner.items.len <= limit) {
            var wrapped: std.ArrayList(u8) = .empty;
            defer wrapped.deinit(gpa);
            messages.wrapEvent(inner.items, &wrapped) catch {
                self.fail(GrpcStatus.internal, "cannot encode event");
                return;
            };
            self.enqueueGrpc(wrapped.items);
        } else {
            const total: u32 = @intCast((inner.items.len + limit - 1) / limit);
            var seq: u32 = 0;
            var off: usize = 0;
            while (off < inner.items.len) : (seq += 1) {
                const end = @min(off + limit, inner.items.len);
                var wrapped: std.ArrayList(u8) = .empty;
                defer wrapped.deinit(gpa);
                messages.wrapChunk(seq, total, inner.items[off..end], &wrapped) catch {
                    self.fail(GrpcStatus.internal, "cannot encode event chunk");
                    return;
                };
                self.enqueueGrpc(wrapped.items);
                off = end;
            }
        }

        if (ev == .run_finished) {
            self.finishing = true;
            sys.eventfdSignal(self.wake_fd);
        }
    }

    fn processInput(self: *Conn) void {
        if (self.rejected or self.finishing) {
            self.in_buf.clearRetainingCapacity();
            self.in_off = 0;
            return;
        }
        while (self.in_buf.items.len - self.in_off >= 5) {
            const base = self.in_off;
            const compressed = self.in_buf.items[base];
            const len = std.mem.readInt(u32, self.in_buf.items[base + 1 ..][0..4], .big);
            if (compressed != 0) {
                self.fail(GrpcStatus.invalid_argument, "compressed gRPC messages are not supported");
                self.in_buf.clearRetainingCapacity();
                self.in_off = 0;
                return;
            }
            if (len > self.server.cfg.grpc_max_message) {
                self.fail(GrpcStatus.resource_exhausted, "message too large");
                self.in_buf.clearRetainingCapacity();
                self.in_off = 0;
                return;
            }
            const total = 5 + @as(usize, len);
            if (self.in_buf.items.len - self.in_off < total) return;
            const msg = self.in_buf.items[base + 5 .. base + total];
            if (!self.handleRequestMessage(msg)) {
                self.in_buf.clearRetainingCapacity();
                self.in_off = 0;
                return;
            }
            self.in_off += total;
            if (self.in_off == self.in_buf.items.len) {
                self.in_buf.clearRetainingCapacity();
                self.in_off = 0;
            } else if (self.in_off > 1024 * 1024) {
                const rest = self.in_buf.items.len - self.in_off;
                std.mem.copyForwards(u8, self.in_buf.items[0..rest], self.in_buf.items[self.in_off..]);
                self.in_buf.shrinkRetainingCapacity(rest);
                self.in_off = 0;
            }
        }
    }

    fn handleRequestMessage(self: *Conn, msg: []const u8) bool {
        const req = messages.parseRequest(msg) catch |e| {
            log.debug("conn: cannot parse {d}-byte message: {s} first={x}", .{ msg.len, @errorName(e), @as(u8, if (msg.len > 0) msg[0] else 0) });
            self.fail(GrpcStatus.invalid_argument, "malformed RunRequest");
            return false;
        };
        switch (req) {
            .start => |start| {
                if (self.start != null or self.run != null or self.archive != null) {
                    self.fail(GrpcStatus.invalid_argument, "duplicate RunStart");
                    return false;
                }
                if (start.run_id.len == 0) {
                    self.fail(GrpcStatus.invalid_argument, "run_id is required");
                    return false;
                }
                const runner = if (start.runner.len == 0) "runner.lua" else start.runner;
                self.start = .{
                    .run_id = gpa.dupe(u8, start.run_id) catch {
                        self.fail(GrpcStatus.internal, "out of memory");
                        return false;
                    },
                    .runner = gpa.dupe(u8, runner) catch {
                        self.fail(GrpcStatus.internal, "out of memory");
                        return false;
                    },
                    .timeout_ms = start.timeout_ms,
                };
                self.archive = manager.beginArchive(self.server.mgr) catch |e| {
                    log.warn("run {s}: cannot create archive: {s}", .{ start.run_id, @errorName(e) });
                    self.fail(GrpcStatus.internal, "cannot create archive");
                    return false;
                };
                self.started_at = clock.nowNs();
                return true;
            },
            .archive_chunk => |chunk| {
                if (self.archive == null or self.archive_done) {
                    self.fail(GrpcStatus.invalid_argument, "archive chunk before RunStart");
                    return false;
                }
                self.archive.?.append(chunk) catch |e| {
                    self.fail(if (e == error.ArchiveTooLarge) GrpcStatus.resource_exhausted else GrpcStatus.internal, @errorName(e));
                    return false;
                };
                return true;
            },
            .archive_end => {
                if (self.archive == null or self.archive_done) {
                    self.fail(GrpcStatus.invalid_argument, "archive already ended");
                    return false;
                }
                self.archive_done = true;
                const st = self.start orelse {
                    self.fail(GrpcStatus.invalid_argument, "missing RunStart");
                    return false;
                };
                const path = self.archive.?.finish() catch {
                    self.fail(GrpcStatus.internal, "cannot finish archive");
                    return false;
                };
                var a = self.archive.?;
                a.deinit();
                self.archive = null;

                const run_id = st.run_id;
                const runner = st.runner;
                // Queue run_started before the executor can emit anything.
                var started: std.ArrayList(u8) = .empty;
                defer started.deinit(gpa);
                messages.encodeRunStarted(run_id, self.server.instance_id, &started) catch {
                    self.fail(GrpcStatus.internal, "cannot encode run_started");
                    return false;
                };
                self.enqueueGrpc(started.items);

                self.run = self.server.mgr.startRun(run_id, runner, st.timeout_ms, path, self.sink()) catch |e| {
                    deleteFileAbs(path);
                    gpa.free(path);
                    // Drop the optimistic run_started event.
                    self.out_mutex.lock();
                    self.out.clearRetainingCapacity();
                    self.out_off = 0;
                    self.out_mutex.unlock();
                    log.warn("run {s}: cannot start: {s}", .{ run_id, @errorName(e) });
                    self.fail(switch (e) {
                        error.RunExists,
                        error.InvalidRunId,
                        error.InvalidArchive,
                        error.UnsupportedEntry,
                        error.ChecksumMismatch,
                        error.Truncated,
                        error.PathEscape,
                        error.AbsolutePath,
                        error.InvalidPath,
                        error.EmptyPath,
                        error.PathTooLong,
                        error.GzipError,
                        error.LinkTargetMissing,
                        => GrpcStatus.invalid_argument,
                        error.TooManyRuns => GrpcStatus.resource_exhausted,
                        else => GrpcStatus.internal,
                    }, @errorName(e));
                    return false;
                };
                return true;
            },
            .stop => |reason| {
                const why = if (reason.len > 0) reason else "client requested stop";
                if (self.run) |h| {
                    h.cancel(why);
                } else if (self.start != null) {
                    // Stop arrived before the archive was complete: there is
                    // no run to cancel, so terminate the RPC as cancelled.
                    self.fail(GrpcStatus.cancelled, why);
                    return false;
                }
                return true;
            },
        }
    }

    fn handleHeadersDone(self: *Conn) void {
        self.request_headers_done = true;
        const session = self.session orelse return;
        if (self.stream_id == 0) return;
        if (!std.mem.eql(u8, self.method.get(), "POST") or
            !std.mem.eql(u8, self.path.get(), "/invoker.v1.Invoker/Run"))
        {
            self.respondTrailersOnly(GrpcStatus.unimplemented, "unknown method");
            _ = session;
            return;
        }
        if (!std.mem.startsWith(u8, self.content_type.get(), "application/grpc")) {
            self.respondTrailersOnly(GrpcStatus.invalid_argument, "content-type must be application/grpc");
            return;
        }
        if (!self.server.authOk(self.auth.get())) {
            self.respondTrailersOnly(GrpcStatus.unauthenticated, "invalid token");
            return;
        }
        self.respondHeaders();
    }
};

fn nv(name: []const u8, value: []const u8) c.nghttp2_nv {
    return .{
        .name = @ptrCast(@constCast(name.ptr)),
        .value = @ptrCast(@constCast(value.ptr)),
        .namelen = name.len,
        .valuelen = value.len,
        .flags = c.NGHTTP2_NV_FLAG_NONE,
    };
}

fn onSend(
    session: ?*c.nghttp2_session,
    data: [*c]const u8,
    length: usize,
    flags: c_int,
    user_data: ?*anyopaque,
) callconv(.c) isize {
    _ = session;
    _ = flags;
    const self: *Conn = @ptrCast(@alignCast(user_data.?));
    const slice = data[0..length];
    const n = sys.write(self.fd, slice) catch |e| switch (e) {
        error.Again => return c.NGHTTP2_ERR_WOULDBLOCK,
        else => return c.NGHTTP2_ERR_CALLBACK_FAILURE,
    };
    if (n == 0) return c.NGHTTP2_ERR_WOULDBLOCK;
    return @intCast(n);
}

fn onReadData(
    session: ?*c.nghttp2_session,
    stream_id: i32,
    buf: [*c]u8,
    length: usize,
    data_flags: [*c]u32,
    source: [*c]c.nghttp2_data_source,
    user_data: ?*anyopaque,
) callconv(.c) isize {
    _ = session;
    _ = stream_id;
    _ = source;
    const self: *Conn = @ptrCast(@alignCast(user_data.?));
    self.out_mutex.lock();
    defer self.out_mutex.unlock();
    const available = self.out.items.len - self.out_off;
    if (available == 0) {
        if (self.finishing) {
            data_flags.* |= c.NGHTTP2_DATA_FLAG_EOF | c.NGHTTP2_DATA_FLAG_NO_END_STREAM;
            self.data_eof = true;
            return 0;
        }
        self.deferred = true;
        return c.NGHTTP2_ERR_DEFERRED;
    }
    const n = @min(available, length);
    @memcpy(buf[0..n], self.out.items[self.out_off .. self.out_off + n]);
    self.out_off += n;
    if (self.out_off == self.out.items.len) {
        self.out.clearRetainingCapacity();
        self.out_off = 0;
    }
    return @intCast(n);
}

fn onBeginHeaders(
    session: ?*c.nghttp2_session,
    frame: [*c]const c.nghttp2_frame,
    user_data: ?*anyopaque,
) callconv(.c) c_int {
    _ = session;
    const self: *Conn = @ptrCast(@alignCast(user_data.?));
    if (frame.*.hd.type == c.NGHTTP2_HEADERS and frame.*.headers.cat == c.NGHTTP2_HCAT_REQUEST) {
        self.stream_id = frame.*.hd.stream_id;
        self.method.len = 0;
        self.path.len = 0;
        self.content_type.len = 0;
        self.auth.len = 0;
        self.request_headers_done = false;
    }
    return 0;
}

fn onHeader(
    session: ?*c.nghttp2_session,
    frame: [*c]const c.nghttp2_frame,
    name: [*c]const u8,
    namelen: usize,
    value: [*c]const u8,
    valuelen: usize,
    flags: u8,
    user_data: ?*anyopaque,
) callconv(.c) c_int {
    _ = session;
    _ = flags;
    const self: *Conn = @ptrCast(@alignCast(user_data.?));
    if (frame.*.hd.type != c.NGHTTP2_HEADERS or frame.*.headers.cat != c.NGHTTP2_HCAT_REQUEST) return 0;
    const n = name[0..namelen];
    const v = value[0..valuelen];
    if (std.mem.eql(u8, n, ":method")) self.method.set(v) else if (std.mem.eql(u8, n, ":path")) self.path.set(v) else if (std.mem.eql(u8, n, "content-type")) self.content_type.set(v) else if (std.mem.eql(u8, n, "authorization")) self.auth.set(v) else if (std.mem.eql(u8, n, "x-invoker-token")) self.auth.set(v);
    return 0;
}

fn onDataChunk(
    session: ?*c.nghttp2_session,
    flags: u8,
    stream_id: i32,
    data: [*c]const u8,
    len: usize,
    user_data: ?*anyopaque,
) callconv(.c) c_int {
    _ = session;
    _ = flags;
    const self: *Conn = @ptrCast(@alignCast(user_data.?));
    if (stream_id != self.stream_id) return 0;
    self.in_buf.appendSlice(gpa, data[0..len]) catch return c.NGHTTP2_ERR_CALLBACK_FAILURE;
    self.processInput();
    return 0;
}

fn onFrameRecv(
    session: ?*c.nghttp2_session,
    frame: [*c]const c.nghttp2_frame,
    user_data: ?*anyopaque,
) callconv(.c) c_int {
    _ = session;
    const self: *Conn = @ptrCast(@alignCast(user_data.?));
    const hd = frame.*.hd;
    if (hd.type == c.NGHTTP2_HEADERS and frame.*.headers.cat == c.NGHTTP2_HCAT_REQUEST) {
        self.stream_id = hd.stream_id;
        if (hd.flags & c.NGHTTP2_FLAG_END_HEADERS != 0) {
            if (!self.request_headers_done) self.handleHeadersDone();
        }
    } else if (hd.type == c.NGHTTP2_DATA and hd.stream_id == self.stream_id) {
        if (hd.flags & c.NGHTTP2_FLAG_END_STREAM != 0) {
            if (!self.archive_done and !self.finishing) {
                // The client half-closed before finishing the archive.
                if (self.run == null and self.start != null) {
                    self.fail(GrpcStatus.invalid_argument, "archive incomplete");
                }
            }
        }
    }
    return 0;
}

fn onStreamClose(
    session: ?*c.nghttp2_session,
    stream_id: i32,
    error_code: u32,
    user_data: ?*anyopaque,
) callconv(.c) c_int {
    _ = session;
    const self: *Conn = @ptrCast(@alignCast(user_data.?));
    if (stream_id == self.stream_id) {
        self.stream_closed = true;
        if (error_code != 0 and self.run != null and !self.finishing) {
            if (self.run.?.isDone() == false) self.run.?.cancel("client reset stream");
        }
        if (error_code != 0 and self.run == null) self.stop.store(true, .release);
    }
    return 0;
}
