const std = @import("std");
const linux = std.os.linux;

pub const fd_t = linux.fd_t;

pub const Error = error{
    NotFound,
    AlreadyExists,
    NotDir,
    IsDir,
    AccessDenied,
    SymlinkLoop,
    CrossDevice,
    Again,
    Interrupted,
    NameTooLong,
    NoSpace,
    TooManyLinks,
    BadFd,
    NoMemory,
    Pipe,
    Unexpected,
};

pub fn mapErrno(e: linux.E) Error {
    return switch (e) {
        .NOENT => error.NotFound,
        .EXIST => error.AlreadyExists,
        .NOTDIR => error.NotDir,
        .ISDIR => error.IsDir,
        .ACCES, .PERM => error.AccessDenied,
        .LOOP => error.SymlinkLoop,
        .XDEV => error.CrossDevice,
        .AGAIN => error.Again,
        .INTR => error.Interrupted,
        .NAMETOOLONG => error.NameTooLong,
        .NOSPC => error.NoSpace,
        .MLINK => error.TooManyLinks,
        .BADF => error.BadFd,
        .NOMEM => error.NoMemory,
        .PIPE => error.Pipe,
        else => error.Unexpected,
    };
}

fn check(rc: usize) Error!usize {
    const e = linux.errno(rc);
    if (e != .SUCCESS) return mapErrno(e);
    return rc;
}

pub fn close(fd: fd_t) void {
    if (fd < 0) return;
    _ = linux.close(fd);
}

pub fn openat(dirfd: fd_t, path: [:0]const u8, flags: linux.O, mode: u32) Error!fd_t {
    const rc = linux.openat(dirfd, path.ptr, flags, mode);
    const e = linux.errno(rc);
    if (e != .SUCCESS) return mapErrno(e);
    return @intCast(rc);
}

pub fn read(fd: fd_t, buf: []u8) Error!usize {
    while (true) {
        const rc = linux.read(fd, buf.ptr, buf.len);
        const e = linux.errno(rc);
        if (e == .INTR) continue;
        if (e != .SUCCESS) return mapErrno(e);
        return rc;
    }
}

pub fn write(fd: fd_t, data: []const u8) Error!usize {
    while (true) {
        const rc = linux.write(fd, data.ptr, data.len);
        const e = linux.errno(rc);
        if (e == .INTR) continue;
        if (e != .SUCCESS) return mapErrno(e);
        return rc;
    }
}

pub fn writeAll(fd: fd_t, data: []const u8) Error!void {
    var off: usize = 0;
    while (off < data.len) {
        const n = try write(fd, data[off..]);
        if (n == 0) return error.Unexpected;
        off += n;
    }
}

pub fn mkdirat(dirfd: fd_t, path: [:0]const u8, mode: u32) Error!void {
    const rc = linux.mkdirat(dirfd, path.ptr, mode);
    const e = linux.errno(rc);
    if (e != .SUCCESS) return mapErrno(e);
}

pub fn unlinkat(dirfd: fd_t, path: [:0]const u8, flags: u32) Error!void {
    const rc = linux.unlinkat(dirfd, path.ptr, flags);
    const e = linux.errno(rc);
    if (e != .SUCCESS) return mapErrno(e);
}

pub fn symlinkat(target: [:0]const u8, dirfd: fd_t, linkpath: [:0]const u8) Error!void {
    const rc = linux.symlinkat(target.ptr, dirfd, linkpath.ptr);
    const e = linux.errno(rc);
    if (e != .SUCCESS) return mapErrno(e);
}

pub fn readlinkat(dirfd: fd_t, path: [:0]const u8, buf: []u8) Error![]u8 {
    const rc = linux.readlinkat(dirfd, path.ptr, buf.ptr, buf.len);
    const e = linux.errno(rc);
    if (e != .SUCCESS) return mapErrno(e);
    return buf[0..rc];
}

pub fn linkat(olddirfd: fd_t, oldpath: [:0]const u8, newdirfd: fd_t, newpath: [:0]const u8, flags: u32) Error!void {
    const rc = linux.linkat(olddirfd, oldpath.ptr, newdirfd, newpath.ptr, flags);
    const e = linux.errno(rc);
    if (e != .SUCCESS) return mapErrno(e);
}

pub fn renameat(olddirfd: fd_t, oldpath: [:0]const u8, newdirfd: fd_t, newpath: [:0]const u8) Error!void {
    const rc = linux.renameat(olddirfd, oldpath.ptr, newdirfd, newpath.ptr);
    const e = linux.errno(rc);
    if (e != .SUCCESS) return mapErrno(e);
}

pub fn poll(fds: []linux.pollfd, timeout_ms: i32) Error!usize {
    while (true) {
        const rc = linux.poll(fds.ptr, @intCast(fds.len), timeout_ms);
        const e = linux.errno(rc);
        if (e == .INTR) continue;
        if (e != .SUCCESS) return mapErrno(e);
        return rc;
    }
}

pub fn eventfd() Error!fd_t {
    const rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    const e = linux.errno(rc);
    if (e != .SUCCESS) return mapErrno(e);
    return @intCast(rc);
}

pub fn eventfdSignal(fd: fd_t) void {
    var one: u64 = 1;
    _ = linux.write(fd, @ptrCast(&one), 8);
}

pub fn eventfdDrain(fd: fd_t) void {
    var buf: [8]u8 = undefined;
    while (true) {
        const rc = linux.read(fd, &buf, buf.len);
        const e = linux.errno(rc);
        if (e == .AGAIN) break;
        if (e != .SUCCESS) break;
        if (rc < 8) break;
    }
}

pub fn getrandom(buf: []u8) Error!void {
    var off: usize = 0;
    while (off < buf.len) {
        const rc = linux.getrandom(buf.ptr + off, buf.len - off, 0);
        const e = linux.errno(rc);
        if (e == .INTR) continue;
        if (e != .SUCCESS) return mapErrno(e);
        if (rc == 0) return error.Unexpected;
        off += rc;
    }
}

pub fn kill(pid: linux.pid_t, sig: linux.SIG) void {
    _ = linux.kill(pid, sig);
}

// ---------------------------------------------------------------------------
// openat2: safe resolution beneath a directory (protects from `..` and
// symlink escapes).  RESOLVE_BENEATH and RESOLVE_NO_MAGICLINKS are used.
// ---------------------------------------------------------------------------

pub const OpenHow = extern struct {
    flags: u64 = 0,
    mode: u64 = 0,
    resolve: u64 = 0,
};

pub const RESOLVE_NO_XDEV: u64 = 0x01;
pub const RESOLVE_NO_MAGICLINKS: u64 = 0x02;
pub const RESOLVE_NO_SYMLINKS: u64 = 0x04;
pub const RESOLVE_BENEATH: u64 = 0x08;
pub const RESOLVE_IN_ROOT: u64 = 0x10;
pub const RESOLVE_CACHED: u64 = 0x20;

pub fn openBeneath(dirfd: fd_t, path: [:0]const u8, flags: linux.O, mode: u32) Error!fd_t {
    const how = OpenHow{
        .flags = @as(u32, @bitCast(flags)),
        .mode = mode,
        .resolve = RESOLVE_BENEATH | RESOLVE_NO_MAGICLINKS,
    };
    const rc = linux.syscall4(
        .openat2,
        @as(u32, @bitCast(dirfd)),
        @intFromPtr(path.ptr),
        @intFromPtr(&how),
        @sizeOf(OpenHow),
    );
    const e = linux.errno(rc);
    if (e != .SUCCESS) return mapErrno(e);
    return @intCast(rc);
}

// ---------------------------------------------------------------------------
// directory listing
// ---------------------------------------------------------------------------

pub const DirEntry = struct {
    name: []const u8,
    kind: Kind,

    pub const Kind = enum { file, dir, symlink, other };
};

const LinuxDirent64 = extern struct {
    ino: u64,
    off: i64,
    reclen: u16,
    type: u8,
    name: [0]u8,
};

/// Iterate over entries of an open directory fd.  The callback receives a name
/// valid only for the duration of the call.
pub fn listDir(fd: fd_t, ctx: anytype, comptime cb: fn (@TypeOf(ctx), DirEntry) anyerror!void) !void {
    var buf: [16 * 1024]u8 align(8) = undefined;
    while (true) {
        const rc = linux.getdents64(fd, &buf, buf.len);
        const e = linux.errno(rc);
        if (e != .SUCCESS) return mapErrno(e);
        if (rc == 0) break;
        var off: usize = 0;
        while (off < rc) {
            const ent: *LinuxDirent64 = @ptrCast(@alignCast(&buf[off]));
            if (ent.reclen == 0) break;
            const name_ptr = @as([*]u8, @ptrCast(ent)) + @offsetOf(LinuxDirent64, "name");
            var name_len: usize = 0;
            while (name_ptr[name_len] != 0) : (name_len += 1) {}
            const name = name_ptr[0..name_len];
            off += ent.reclen;
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            const kind: DirEntry.Kind = switch (ent.type) {
                linux.DT.REG => .file,
                linux.DT.DIR => .dir,
                linux.DT.LNK => .symlink,
                else => .other,
            };
            try cb(ctx, .{ .name = name, .kind = kind });
        }
    }
}

pub const Stat = struct {
    size: u64,
    mode: u32,
    is_dir: bool,
    is_reg: bool,
    is_symlink: bool,
};

pub fn statx(dirfd: fd_t, path: [:0]const u8, flags: u32) Error!Stat {
    var st: linux.Statx = undefined;
    const mask = linux.STATX{ .TYPE = true, .MODE = true, .SIZE = true };
    const rc = linux.statx(dirfd, path.ptr, flags, mask, &st);
    const e = linux.errno(rc);
    if (e != .SUCCESS) return mapErrno(e);
    const fmt = st.mode & 0o170000;
    return .{
        .size = st.size,
        .mode = st.mode,
        .is_dir = fmt == 0o040000,
        .is_reg = fmt == 0o100000,
        .is_symlink = fmt == 0o120000,
    };
}

pub fn fstat(fd: fd_t) Error!Stat {
    return statx(fd, "", linux.AT.EMPTY_PATH);
}

pub fn fchmod(fd: fd_t, mode: u32) Error!void {
    const rc = linux.fchmod(fd, mode);
    const e = linux.errno(rc);
    if (e != .SUCCESS) return mapErrno(e);
}

// ---------------------------------------------------------------------------
// sockets
// ---------------------------------------------------------------------------

pub fn socket(domain: u32, sock_type: u32, protocol: u32) Error!fd_t {
    const rc = linux.socket(domain, sock_type, protocol);
    const e = linux.errno(rc);
    if (e != .SUCCESS) return mapErrno(e);
    return @intCast(rc);
}

pub fn connect(fd: fd_t, addr: *const anyopaque, len: linux.socklen_t) Error!void {
    const rc = linux.connect(fd, addr, len);
    const e = linux.errno(rc);
    if (e != .SUCCESS) return mapErrno(e);
}

pub fn bind(fd: fd_t, addr: *const anyopaque, len: linux.socklen_t) Error!void {
    const rc = linux.bind(fd, @ptrCast(@alignCast(addr)), len);
    const e = linux.errno(rc);
    if (e != .SUCCESS) return mapErrno(e);
}

pub fn listen(fd: fd_t, backlog: u32) Error!void {
    const rc = linux.listen(fd, backlog);
    const e = linux.errno(rc);
    if (e != .SUCCESS) return mapErrno(e);
}

pub fn accept(fd: fd_t) Error!fd_t {
    while (true) {
        const rc = linux.accept(fd, null, null);
        const e = linux.errno(rc);
        if (e == .INTR) continue;
        if (e != .SUCCESS) return mapErrno(e);
        return @intCast(rc);
    }
}

pub fn setsockopt(fd: fd_t, level: i32, optname: u32, value: []const u8) Error!void {
    const rc = linux.setsockopt(fd, level, optname, value.ptr, @intCast(value.len));
    const e = linux.errno(rc);
    if (e != .SUCCESS) return mapErrno(e);
}

pub fn shutdown(fd: fd_t, how: i32) void {
    _ = linux.shutdown(fd, how);
}

pub fn setNonblocking(fd: fd_t, enable: bool) void {
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    const nb: usize = 0o4000;
    _ = linux.fcntl(fd, linux.F.SETFL, if (enable) flags | nb else flags & ~nb);
}
