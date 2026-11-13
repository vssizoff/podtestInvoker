const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const gpa = @import("mem.zig").gpa;

pub const max_path = 4000;

/// Validate a path that must stay inside a run directory.  Returns a
/// normalised path (components joined with '/', "." components dropped).
/// Absolute paths, empty components and ".." are rejected.
pub fn normalizeRel(buf: []u8, path: []const u8) ![]const u8 {
    if (path.len == 0) return error.EmptyPath;
    if (path.len > max_path) return error.PathTooLong;
    if (path[0] == '/') return error.AbsolutePath;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    var out: usize = 0;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |comp| {
        if (comp.len == 0) continue;
        if (std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) return error.PathEscape;
        if (out != 0) {
            if (out + 1 > buf.len) return error.PathTooLong;
            buf[out] = '/';
            out += 1;
        }
        if (out + comp.len > buf.len) return error.PathTooLong;
        @memcpy(buf[out .. out + comp.len], comp);
        out += comp.len;
    }
    if (out == 0) return error.EmptyPath;
    return buf[0..out];
}

pub fn baseName(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
    return path;
}

pub fn dirName(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| {
        if (i == 0) return ".";
        return path[0..i];
    }
    return ".";
}

fn zPath(buf: []u8, path: []const u8) ![:0]const u8 {
    if (path.len + 1 > buf.len) return error.PathTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

pub fn openDirBeneath(rootfd: sys.fd_t, rel: []const u8) !sys.fd_t {
    var nb: [max_path + 1]u8 = undefined;
    const norm = try normalizeRel(&nb, rel);
    var zb: [max_path + 1]u8 = undefined;
    const z = try zPath(&zb, norm);
    return sys.openBeneath(rootfd, z, .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .CLOEXEC = true,
    }, 0);
}

/// Walk (and create) parent directories of `rel_dir`, never following
/// symlinks.  Returns an open fd for the final directory.
pub fn ensureDirBeneath(rootfd: sys.fd_t, rel_dir: []const u8) !sys.fd_t {
    if (rel_dir.len == 0 or std.mem.eql(u8, rel_dir, ".")) {
        return sys.openat(rootfd, ".", .{
            .ACCMODE = .RDONLY,
            .DIRECTORY = true,
            .CLOEXEC = true,
        }, 0);
    }
    var nb: [max_path + 1]u8 = undefined;
    const norm = try normalizeRel(&nb, rel_dir);
    var cur = try sys.openat(rootfd, ".", .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .CLOEXEC = true,
    }, 0);
    errdefer sys.close(cur);
    var it = std.mem.splitScalar(u8, norm, '/');
    while (it.next()) |comp| {
        if (comp.len == 0) continue;
        var zb: [max_path + 1]u8 = undefined;
        const z = try zPath(&zb, comp);
        const next = sys.openat(cur, z, .{
            .ACCMODE = .RDONLY,
            .DIRECTORY = true,
            .NOFOLLOW = true,
            .CLOEXEC = true,
        }, 0) catch |e| switch (e) {
            error.NotFound => blk: {
                sys.mkdirat(cur, z, 0o755) catch |me| switch (me) {
                    error.AlreadyExists => {},
                    else => return me,
                };
                break :blk try sys.openat(cur, z, .{
                    .ACCMODE = .RDONLY,
                    .DIRECTORY = true,
                    .NOFOLLOW = true,
                    .CLOEXEC = true,
                }, 0);
            },
            else => return e,
        };
        sys.close(cur);
        cur = next;
    }
    return cur;
}

pub fn makeDirBeneath(rootfd: sys.fd_t, rel_dir: []const u8) !void {
    const fd = try ensureDirBeneath(rootfd, rel_dir);
    sys.close(fd);
}

pub fn writeFileBeneath(rootfd: sys.fd_t, rel: []const u8, data: []const u8) !void {
    var nb: [max_path + 1]u8 = undefined;
    const norm = try normalizeRel(&nb, rel);
    const parent = try ensureDirBeneath(rootfd, dirName(norm));
    defer sys.close(parent);
    var zb: [max_path + 1]u8 = undefined;
    const z = try zPath(&zb, baseName(norm));
    const fd = try sys.openBeneath(parent, z, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
        .CLOEXEC = true,
    }, 0o644);
    defer sys.close(fd);
    try sys.writeAll(fd, data);
}

pub fn appendFileBeneath(rootfd: sys.fd_t, rel: []const u8, data: []const u8) !void {
    var nb: [max_path + 1]u8 = undefined;
    const norm = try normalizeRel(&nb, rel);
    const parent = try ensureDirBeneath(rootfd, dirName(norm));
    defer sys.close(parent);
    var zb: [max_path + 1]u8 = undefined;
    const z = try zPath(&zb, baseName(norm));
    const fd = try sys.openBeneath(parent, z, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
        .CLOEXEC = true,
    }, 0o644);
    defer sys.close(fd);
    try sys.writeAll(fd, data);
}

pub const StatInfo = struct {
    is_dir: bool,
    size: u64,
    mode: u32,
};

pub fn statBeneath(rootfd: sys.fd_t, rel: []const u8, follow: bool) !StatInfo {
    var nb: [max_path + 1]u8 = undefined;
    const norm = try normalizeRel(&nb, rel);
    var zb: [max_path + 1]u8 = undefined;
    const z = try zPath(&zb, norm);
    const flags: u32 = if (follow) 0 else linux.AT.SYMLINK_NOFOLLOW;
    const st = try sys.statx(rootfd, z, flags);
    return .{ .is_dir = st.is_dir, .size = st.size, .mode = st.mode };
}

pub fn readFileBeneath(rootfd: sys.fd_t, rel: []const u8, limit: usize) ![]u8 {
    var nb: [max_path + 1]u8 = undefined;
    const norm = try normalizeRel(&nb, rel);
    var zb: [max_path + 1]u8 = undefined;
    const z = try zPath(&zb, norm);
    const fd = try sys.openBeneath(rootfd, z, .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
    }, 0);
    defer sys.close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try sys.read(fd, &buf);
        if (n == 0) break;
        if (out.items.len + n > limit) return error.FileTooLarge;
        try out.appendSlice(gpa, buf[0..n]);
    }
    return out.toOwnedSlice(gpa);
}

/// Resolve a path inside the run directory to an absolute host path.  The
/// path must already exist.  Symlinks are resolved, and the final path is
/// verified to stay inside `root_abs`.
pub fn resolveWithin(rootfd: sys.fd_t, root_abs: []const u8, rel: []const u8) ![]u8 {
    var nb: [max_path + 1]u8 = undefined;
    const norm = try normalizeRel(&nb, rel);
    var zb: [max_path + 1]u8 = undefined;
    const z = try zPath(&zb, norm);
    const fd = try sys.openBeneath(rootfd, z, .{
        .ACCMODE = .RDONLY,
        .PATH = true,
        .CLOEXEC = true,
    }, 0);
    defer sys.close(fd);
    var link_buf: [max_path + 1]u8 = undefined;
    const proc = try std.fmt.bufPrint(&link_buf, "/proc/self/fd/{d}", .{fd});
    var zproc: [max_path + 1]u8 = undefined;
    const zp = try zPath(&zproc, proc);
    var out_buf: [max_path + 1]u8 = undefined;
    const resolved = try sys.readlinkat(linux.AT.FDCWD, zp, &out_buf);
    if (!std.mem.startsWith(u8, resolved, root_abs)) return error.PathEscape;
    if (resolved.len > root_abs.len and resolved[root_abs.len] != '/') return error.PathEscape;
    return gpa.dupe(u8, resolved);
}

pub fn removeTreeBeneath(rootfd: sys.fd_t, rel: []const u8) !void {
    var nb: [max_path + 1]u8 = undefined;
    const norm = try normalizeRel(&nb, rel);
    var zb: [max_path + 1]u8 = undefined;
    const z = try zPath(&zb, norm);
    // stat without following symlinks
    const st = sys.statx(rootfd, z, linux.AT.SYMLINK_NOFOLLOW) catch |e| switch (e) {
        error.NotFound => return,
        else => return e,
    };
    if (!st.is_dir) {
        try sys.unlinkat(rootfd, z, 0);
        return;
    }
    const dir = try sys.openat(rootfd, z, .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, 0);
    defer sys.close(dir);
    try removeDirContents(dir);
    try sys.unlinkat(rootfd, z, linux.AT.REMOVEDIR);
}

fn removeDirContents(dir: sys.fd_t) !void {
    const Ctx = struct {
        dir: sys.fd_t,
        err: ?anyerror = null,
    };
    const ctx = Ctx{ .dir = dir };
    const cb = struct {
        fn run(c: *Ctx, ent: sys.DirEntry) anyerror!void {
            var nb: [max_path + 1]u8 = undefined;
            if (ent.name.len + 1 > nb.len) return error.NameTooLong;
            @memcpy(nb[0..ent.name.len], ent.name);
            nb[ent.name.len] = 0;
            const z = nb[0..ent.name.len :0];
            switch (ent.kind) {
                .dir => {
                    const sub = sys.openat(c.dir, z, .{
                        .ACCMODE = .RDONLY,
                        .DIRECTORY = true,
                        .NOFOLLOW = true,
                        .CLOEXEC = true,
                    }, 0) catch |e| switch (e) {
                        error.NotFound => return,
                        else => return e,
                    };
                    defer sys.close(sub);
                    try removeDirContents(sub);
                    try sys.unlinkat(c.dir, z, linux.AT.REMOVEDIR);
                },
                else => try sys.unlinkat(c.dir, z, 0),
            }
        }
    }.run;
    // getdents64 invalidates names as we unlink; collect first.
    const Collector = struct {
        names: std.ArrayList([]u8) = .empty,
        kinds: std.ArrayList(sys.DirEntry.Kind) = .empty,
        fn add(self: *@This(), ent: sys.DirEntry) anyerror!void {
            try self.names.append(gpa, try gpa.dupe(u8, ent.name));
            try self.kinds.append(gpa, ent.kind);
        }
    };
    var coll = Collector{};
    defer {
        for (coll.names.items) |n| gpa.free(n);
        coll.names.deinit(gpa);
        coll.kinds.deinit(gpa);
    }
    try sys.listDir(dir, &coll, Collector.add);
    for (coll.names.items, coll.kinds.items) |name, kind| {
        var nb: [max_path + 1]u8 = undefined;
        if (name.len + 1 > nb.len) return error.NameTooLong;
        @memcpy(nb[0..name.len], name);
        nb[name.len] = 0;
        const z = nb[0..name.len :0];
        switch (kind) {
            .dir => {
                const sub = sys.openat(dir, z, .{
                    .ACCMODE = .RDONLY,
                    .DIRECTORY = true,
                    .NOFOLLOW = true,
                    .CLOEXEC = true,
                }, 0) catch |e| switch (e) {
                    error.NotFound => continue,
                    else => return e,
                };
                defer sys.close(sub);
                try removeDirContents(sub);
                try sys.unlinkat(dir, z, linux.AT.REMOVEDIR);
            },
            else => {
                sys.unlinkat(dir, z, 0) catch |e| switch (e) {
                    error.NotFound => {},
                    else => return e,
                };
            },
        }
    }
    _ = ctx;
    _ = cb;
}

/// Remove every entry of an open directory (used for startup cleanup).
pub fn clearDir(dir: sys.fd_t) !void {
    try removeDirContents(dir);
}

pub fn readFileAbsolute(path: []const u8, limit: usize) ![]u8 {
    var zb: [max_path + 1]u8 = undefined;
    const z = try zPath(&zb, path);
    const fd = try sys.openat(linux.AT.FDCWD, z, .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
    }, 0);
    defer sys.close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try sys.read(fd, &buf);
        if (n == 0) break;
        if (out.items.len + n > limit) return error.FileTooLarge;
        try out.appendSlice(gpa, buf[0..n]);
    }
    return out.toOwnedSlice(gpa);
}

pub fn writeFileAbsolute(path: []const u8, data: []const u8) !void {
    var zb: [max_path + 1]u8 = undefined;
    const z = try zPath(&zb, path);
    const fd = try sys.openat(linux.AT.FDCWD, z, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
        .CLOEXEC = true,
    }, 0o644);
    defer sys.close(fd);
    try sys.writeAll(fd, data);
}

pub fn makeDirAbsolute(path: []const u8) !void {
    var zb: [max_path + 1]u8 = undefined;
    const z = try zPath(&zb, path);
    sys.mkdirat(linux.AT.FDCWD, z, 0o755) catch |e| switch (e) {
        error.AlreadyExists => {},
        else => return e,
    };
}

pub fn makeDirAllAbsolute(path: []const u8) !void {
    if (path.len == 0) return;
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/') {
            const part = path[0..i];
            var zb: [max_path + 1]u8 = undefined;
            const z = try zPath(&zb, part);
            sys.mkdirat(linux.AT.FDCWD, z, 0o755) catch |e| switch (e) {
                error.AlreadyExists => {},
                else => return e,
            };
        }
    }
}

pub fn existsAbsolute(path: []const u8) bool {
    var zb: [max_path + 1]u8 = undefined;
    const z = zPath(&zb, path) catch return false;
    _ = sys.statx(linux.AT.FDCWD, z, 0) catch return false;
    return true;
}

pub fn isDirAbsolute(path: []const u8) bool {
    var zb: [max_path + 1]u8 = undefined;
    const z = zPath(&zb, path) catch return false;
    const st = sys.statx(linux.AT.FDCWD, z, 0) catch return false;
    return st.is_dir;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

fn testZPath(buf: []u8, path: []const u8) ![:0]const u8 {
    if (path.len + 1 > buf.len) return error.PathTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

fn makeTestRoot(buf: []u8, name: []const u8) !struct { path: []const u8, fd: sys.fd_t } {
    const path = try std.fmt.bufPrint(buf, "/tmp/opencode/podtest-{s}-{d}", .{ name, std.os.linux.getpid() });
    try makeDirAllAbsolute(path);
    var zb: [max_path + 1]u8 = undefined;
    const z = try testZPath(&zb, path);
    const fd = try sys.openat(linux.AT.FDCWD, z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    return .{ .path = path, .fd = fd };
}

fn removeTestRoot(path: []const u8) void {
    var zb: [max_path + 1]u8 = undefined;
    const parent = dirName(path);
    const zp = testZPath(&zb, parent) catch return;
    const pfd = sys.openat(linux.AT.FDCWD, zp, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0) catch return;
    defer sys.close(pfd);
    removeTreeBeneath(pfd, baseName(path)) catch {};
}

test "normalizeRel rejects escapes and normalises nested paths" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a/b/c", try normalizeRel(&buf, "a//./b/c/"));
    try std.testing.expectError(error.PathEscape, normalizeRel(&buf, "../x"));
    try std.testing.expectError(error.PathEscape, normalizeRel(&buf, "a/../../x"));
    try std.testing.expectError(error.AbsolutePath, normalizeRel(&buf, "/etc/passwd"));
    try std.testing.expectError(error.EmptyPath, normalizeRel(&buf, ""));
    try std.testing.expectError(error.EmptyPath, normalizeRel(&buf, "./"));
    try std.testing.expectEqualStrings("c.txt", baseName("a/b/c.txt"));
    try std.testing.expectEqualStrings("a/b", dirName("a/b/c.txt"));
    try std.testing.expectEqualStrings(".", dirName("c.txt"));
}

test "nested writes stay beneath the run root" {
    var buf: [256]u8 = undefined;
    const root = try makeTestRoot(&buf, "fs");
    defer sys.close(root.fd);
    defer removeTestRoot(root.path);

    try writeFileBeneath(root.fd, "a/b/c.txt", "hello");
    const data = try readFileBeneath(root.fd, "a/b/c.txt", 1024);
    defer gpa.free(data);
    try std.testing.expectEqualStrings("hello", data);

    try appendFileBeneath(root.fd, "a/b/c.txt", "!");
    const data2 = try readFileBeneath(root.fd, "a/b/c.txt", 1024);
    defer gpa.free(data2);
    try std.testing.expectEqualStrings("hello!", data2);

    try std.testing.expectError(error.PathEscape, writeFileBeneath(root.fd, "../escape.txt", "x"));
    try std.testing.expectError(error.PathEscape, readFileBeneath(root.fd, "a/../../escape.txt", 16));
}

test "symlinks cannot escape the run root" {
    var buf: [256]u8 = undefined;
    const root = try makeTestRoot(&buf, "link");
    defer sys.close(root.fd);
    defer removeTestRoot(root.path);

    try sys.symlinkat("../outside", root.fd, "relative-escape");
    if (writeFileBeneath(root.fd, "relative-escape/file", "x")) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}

    try sys.symlinkat("/etc", root.fd, "absolute-escape");
    if (resolveWithin(root.fd, root.path, "absolute-escape")) |p| {
        gpa.free(p);
        return error.TestUnexpectedResult;
    } else |_| {}
}
