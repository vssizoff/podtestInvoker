const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const gpa = @import("mem.zig").gpa;
const log = @import("log.zig");

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Response = struct {
    status: u16,
    headers: std.ArrayList(Header) = .empty,
    body: []u8 = &.{},

    pub fn deinit(self: *Response) void {
        for (self.headers.items) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        self.headers.deinit(gpa);
        if (self.body.len > 0) gpa.free(self.body);
        self.* = undefined;
    }

    pub fn header(self: *const Response, name: []const u8) ?[]const u8 {
        for (self.headers.items) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }
};

pub const Error = error{
    ConnectFailed,
    Protocol,
    ResponseTooLarge,
    Timeout,
    Closed,
    OutOfMemory,
} || sys.Error;

fn setNonblock(fd: sys.fd_t) void {
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    _ = linux.fcntl(fd, linux.F.SETFL, flags | 0o4000);
}

fn waitFd(fd: sys.fd_t, events: i16, timeout_ms: i32) Error!void {
    var pfds = [_]linux.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
    const n = try sys.poll(&pfds, timeout_ms);
    if (n == 0) return error.Timeout;
    if (pfds[0].revents & (linux.POLL.ERR | linux.POLL.NVAL) != 0) return error.ConnectFailed;
}

pub fn connectUnix(path: []const u8) Error!sys.fd_t {
    const fd = try sys.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    errdefer sys.close(fd);
    var addr: linux.sockaddr.un = std.mem.zeroes(linux.sockaddr.un);
    addr.family = linux.AF.UNIX;
    if (path.len >= addr.path.len) return error.NameTooLong;
    @memcpy(addr.path[0..path.len], path);
    try sys.connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
    return fd;
}

pub const TcpAddr = struct {
    ip: [4]u8,
    port: u16,
};

pub fn parseTcpAddr(s: []const u8) !TcpAddr {
    const idx = std.mem.lastIndexOfScalar(u8, s, ':') orelse return error.InvalidAddress;
    const host = s[0..idx];
    const port = try std.fmt.parseInt(u16, s[idx + 1 ..], 10);
    var ip: [4]u8 = .{ 0, 0, 0, 0 };
    if (!std.mem.eql(u8, host, "localhost") and !std.mem.eql(u8, host, "*")) {
        var it = std.mem.splitScalar(u8, host, '.');
        var i: usize = 0;
        while (it.next()) |part| : (i += 1) {
            if (i >= 4) return error.InvalidAddress;
            ip[i] = try std.fmt.parseInt(u8, part, 10);
        }
        if (i != 4) return error.InvalidAddress;
    }
    return .{ .ip = ip, .port = port };
}

pub fn connectTcp(addr: TcpAddr) Error!sys.fd_t {
    const fd = try sys.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    errdefer sys.close(fd);
    var sa = linux.sockaddr.in{
        .family = linux.AF.INET,
        .port = std.mem.nativeToBig(u16, addr.port),
        .addr = @bitCast(addr.ip),
    };
    try sys.connect(fd, @ptrCast(&sa), @sizeOf(@TypeOf(sa)));
    return fd;
}

pub fn listenTcp(addr: TcpAddr, backlog: u31) Error!sys.fd_t {
    const fd = try sys.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    errdefer sys.close(fd);
    var one: u32 = 1;
    try sys.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&one));
    var sa = linux.sockaddr.in{
        .family = linux.AF.INET,
        .port = std.mem.nativeToBig(u16, addr.port),
        .addr = @bitCast(addr.ip),
    };
    try sys.bind(fd, @ptrCast(&sa), @sizeOf(@TypeOf(sa)));
    try sys.listen(fd, backlog);
    return fd;
}

fn writeAllFd(fd: sys.fd_t, data: []const u8, timeout_ms: i32) Error!void {
    var off: usize = 0;
    while (off < data.len) {
        const n = sys.write(fd, data[off..]) catch |e| switch (e) {
            error.Again => blk: {
                try waitFd(fd, linux.POLL.OUT, timeout_ms);
                break :blk try sys.write(fd, data[off..]);
            },
            else => return e,
        };
        if (n == 0) return error.Closed;
        off += n;
    }
}

pub const RequestOptions = struct {
    method: []const u8,
    path: []const u8,
    headers: []const Header = &.{},
    body: []const u8 = "",
    timeout_ms: i32 = 60_000,
    max_response: usize = 64 * 1024 * 1024,
};

pub const Conn = struct {
    fd: sys.fd_t,
    buf: [64 * 1024]u8 = undefined,
    start: usize = 0,
    end: usize = 0,
    timeout_ms: i32,

    pub fn init(fd: sys.fd_t, timeout_ms: i32) Conn {
        return .{ .fd = fd, .timeout_ms = timeout_ms };
    }

    fn fill(self: *Conn) Error!bool {
        if (self.start < self.end) return true;
        self.start = 0;
        self.end = 0;
        const n = sys.read(self.fd, &self.buf) catch |e| switch (e) {
            error.Again => {
                try waitFd(self.fd, linux.POLL.IN, self.timeout_ms);
                return self.fill();
            },
            else => return e,
        };
        if (n == 0) return false;
        self.end = n;
        return true;
    }

    pub fn readExact(self: *Conn, out: []u8) Error!void {
        var off: usize = 0;
        while (off < out.len) {
            if (self.start == self.end) {
                if (!try self.fill()) return error.Closed;
            }
            const avail = self.end - self.start;
            const n = @min(avail, out.len - off);
            @memcpy(out[off .. off + n], self.buf[self.start .. self.start + n]);
            self.start += n;
            off += n;
        }
    }

    pub fn readLine(self: *Conn, out: []u8) Error![]u8 {
        var len: usize = 0;
        while (true) {
            if (self.start == self.end) {
                if (!try self.fill()) return error.Closed;
            }
            const c = self.buf[self.start];
            self.start += 1;
            if (c == '\n') {
                if (len > 0 and out[len - 1] == '\r') len -= 1;
                return out[0..len];
            }
            if (len >= out.len) return error.ResponseTooLarge;
            out[len] = c;
            len += 1;
        }
    }

    pub fn readAll(self: *Conn, limit: usize) Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        while (true) {
            if (self.start == self.end) {
                if (!try self.fill()) break;
            }
            const avail = self.end - self.start;
            if (out.items.len + avail > limit) return error.ResponseTooLarge;
            try out.appendSlice(gpa, self.buf[self.start..self.end]);
            self.start = self.end;
        }
        return out.toOwnedSlice(gpa);
    }
};

fn parseHead(conn: *Conn, resp: *Response) !void {
    var line_buf: [16 * 1024]u8 = undefined;
    const status_line = try conn.readLine(&line_buf);
    if (!std.mem.startsWith(u8, status_line, "HTTP/1.")) return error.Protocol;
    const sp = std.mem.indexOfScalar(u8, status_line, ' ') orelse return error.Protocol;
    const rest = status_line[sp + 1 ..];
    const sp2 = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    resp.status = std.fmt.parseInt(u16, rest[0..sp2], 10) catch return error.Protocol;
    while (true) {
        const line = try conn.readLine(&line_buf);
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        try resp.headers.append(gpa, .{
            .name = try gpa.dupe(u8, name),
            .value = try gpa.dupe(u8, value),
        });
    }
}

fn readChunked(conn: *Conn, limit: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var line_buf: [1024]u8 = undefined;
    while (true) {
        const line = try conn.readLine(&line_buf);
        const semi = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
        const size = std.fmt.parseInt(usize, line[0..semi], 16) catch return error.Protocol;
        if (size == 0) {
            // trailers
            while (true) {
                const t = try conn.readLine(&line_buf);
                if (t.len == 0) break;
            }
            break;
        }
        if (out.items.len + size > limit) return error.ResponseTooLarge;
        const old = out.items.len;
        try out.resize(gpa, old + size);
        try conn.readExact(out.items[old..][0..size]);
        var crlf: [2]u8 = undefined;
        try conn.readExact(&crlf);
    }
    return out.toOwnedSlice(gpa);
}

fn readBody(conn: *Conn, resp: *Response, limit: usize) !void {
    if (resp.header("transfer-encoding")) |te| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, te, " \t"), "chunked")) {
            resp.body = try readChunked(conn, limit);
            return;
        }
    }
    if (resp.header("content-length")) |cl| {
        const n = std.fmt.parseInt(usize, cl, 10) catch return error.Protocol;
        if (n > limit) return error.ResponseTooLarge;
        resp.body = try gpa.alloc(u8, n);
        errdefer gpa.free(resp.body);
        try conn.readExact(resp.body);
        return;
    }
    resp.body = try conn.readAll(limit);
}

pub const Endpoint = union(enum) {
    unix: []const u8,
    tcp: TcpAddr,

    fn connect(self: Endpoint) Error!sys.fd_t {
        return switch (self) {
            .unix => |p| connectUnix(p),
            .tcp => |a| connectTcp(a),
        };
    }
};

pub fn request(ep: Endpoint, opts: RequestOptions) Error!Response {
    const fd = try ep.connect();
    defer sys.close(fd);
    setNonblock(fd);

    var head: std.ArrayList(u8) = .empty;
    defer head.deinit(gpa);
    try head.print(gpa, "{s} {s} HTTP/1.1\r\nHost: d\r\nConnection: close\r\n", .{ opts.method, opts.path });
    for (opts.headers) |h| {
        try head.print(gpa, "{s}: {s}\r\n", .{ h.name, h.value });
    }
    if (opts.body.len > 0 or std.mem.eql(u8, opts.method, "POST") or std.mem.eql(u8, opts.method, "PUT")) {
        try head.print(gpa, "Content-Length: {d}\r\n", .{opts.body.len});
    }
    try head.appendSlice(gpa, "\r\n");
    try writeAllFd(fd, head.items, opts.timeout_ms);
    if (opts.body.len > 0) try writeAllFd(fd, opts.body, opts.timeout_ms);

    var conn = Conn.init(fd, opts.timeout_ms);
    var resp = Response{ .status = 0 };
    errdefer resp.deinit();
    try parseHead(&conn, &resp);
    try readBody(&conn, &resp, opts.max_response);
    return resp;
}

pub const Hijacked = struct {
    fd: sys.fd_t,
    leftover: []u8,
    pub fn deinit(self: *Hijacked) void {
        sys.close(self.fd);
        if (self.leftover.len > 0) gpa.free(self.leftover);
    }
};

/// Send an HTTP request and return the raw connection after the response
/// headers (used for Podman's attach/hijack endpoint).
pub fn hijack(ep: Endpoint, method: []const u8, path: []const u8, timeout_ms: i32) Error!Hijacked {
    const fd = try ep.connect();
    errdefer sys.close(fd);
    setNonblock(fd);

    var head: std.ArrayList(u8) = .empty;
    defer head.deinit(gpa);
    try head.print(gpa, "{s} {s} HTTP/1.1\r\nHost: d\r\nConnection: Upgrade\r\nUpgrade: tcp\r\nContent-Length: 0\r\n\r\n", .{ method, path });
    try writeAllFd(fd, head.items, timeout_ms);

    var conn = Conn.init(fd, timeout_ms);
    var resp = Response{ .status = 0 };
    defer resp.deinit();
    try parseHead(&conn, &resp);
    if (resp.status != 101 and resp.status != 200) {
        // read a little of the error body for the log
        var msg: [512]u8 = undefined;
        const n = @min(conn.end - conn.start, msg.len);
        @memcpy(msg[0..n], conn.buf[conn.start..][0..n]);
        log.warn("podman hijack {s} failed: HTTP {d}: {s}", .{ path, resp.status, msg[0..n] });
        return error.Protocol;
    }
    const leftover = try gpa.dupe(u8, conn.buf[conn.start..conn.end]);
    return .{ .fd = fd, .leftover = leftover };
}
