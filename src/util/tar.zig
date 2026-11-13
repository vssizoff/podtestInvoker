const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const fs = @import("fs.zig");
const log = @import("log.zig");
const gpa = @import("mem.zig").gpa;

const gzFile = ?*anyopaque;
extern fn gzopen(path: [*:0]const u8, mode: [*:0]const u8) gzFile;
extern fn gzread(file: gzFile, buf: [*]u8, len: c_uint) c_int;
extern fn gzclose(file: gzFile) c_int;

pub const Error = error{
    InvalidArchive,
    UnsupportedEntry,
    ChecksumMismatch,
    Truncated,
    PathEscape,
    AbsolutePath,
    InvalidPath,
    EmptyPath,
    PathTooLong,
    OutOfMemory,
    GzipError,
    LinkTargetMissing,
} || sys.Error;

const Reader = struct {
    kind: enum { plain, gzip },
    fd: sys.fd_t = -1,
    gz: gzFile = null,
    remaining: usize = 0, // for entry payload reads

    fn read(self: *Reader, buf: []u8) Error!usize {
        if (buf.len == 0) return 0;
        switch (self.kind) {
            .plain => return sys.read(self.fd, buf),
            .gzip => {
                const n = gzread(self.gz, buf.ptr, @intCast(@min(buf.len, std.math.maxInt(c_int))));
                if (n < 0) return error.GzipError;
                return @intCast(n);
            },
        }
    }

    fn readExact(self: *Reader, out: []u8) Error!void {
        var off: usize = 0;
        while (off < out.len) {
            const n = try self.read(out[off..]);
            if (n == 0) return error.Truncated;
            off += n;
        }
    }

    fn readExactAllowEof(self: *Reader, out: []u8) Error!usize {
        var off: usize = 0;
        while (off < out.len) {
            const n = try self.read(out[off..]);
            if (n == 0) break;
            off += n;
        }
        return off;
    }

    fn skip(self: *Reader, n: usize) Error!void {
        var left = n;
        var buf: [64 * 1024]u8 = undefined;
        while (left > 0) {
            const take = @min(left, buf.len);
            try self.readExact(buf[0..take]);
            left -= take;
        }
    }

    fn close(self: *Reader) void {
        switch (self.kind) {
            .plain => sys.close(self.fd),
            .gzip => _ = gzclose(self.gz),
        }
    }
};

const Header = struct {
    name: []const u8,
    prefix: []const u8,
    linkname: []const u8,
    size: u64,
    mode: u32,
    typeflag: u8,
    pax_path: ?[]const u8 = null,
    pax_linkpath: ?[]const u8 = null,
    pax_size: ?u64 = null,
};

fn parseOctal(field: []const u8) Error!u64 {
    var i: usize = 0;
    while (i < field.len and (field[i] == ' ' or field[i] == 0)) : (i += 1) {}
    if (i < field.len and (field[i] & 0x80) != 0) {
        // GNU base-256
        var value: u64 = field[i] & 0x7f;
        i += 1;
        while (i < field.len) : (i += 1) {
            value = (value << 8) | field[i];
        }
        return value;
    }
    var value: u64 = 0;
    var any = false;
    while (i < field.len and field[i] >= '0' and field[i] <= '7') : (i += 1) {
        value = value * 8 + (field[i] - '0');
        any = true;
    }
    if (!any) {
        // all-NUL / spaces means zero
        return 0;
    }
    return value;
}

fn parseHeader(block: *const [512]u8) Error!Header {
    // checksum
    const stored = try parseOctal(block[148..156]);
    var sum: u64 = 0;
    for (block, 0..) |b, i| {
        sum += if (i >= 148 and i < 156) ' ' else b;
    }
    if (stored != sum) return error.ChecksumMismatch;

    const name = std.mem.sliceTo(block[0..100], 0);
    const prefix = std.mem.sliceTo(block[345..500], 0);
    const linkname = std.mem.sliceTo(block[157..257], 0);
    return .{
        .name = name,
        .prefix = prefix,
        .linkname = linkname,
        .size = try parseOctal(block[124..136]),
        .mode = @intCast(try parseOctal(block[100..108]) & 0o7777),
        .typeflag = block[156],
    };
}

const PaxResult = struct { path: ?[]const u8 = null, linkpath: ?[]const u8 = null, size: ?u64 = null };

fn parsePax(data: []const u8) Error!PaxResult {
    var res = PaxResult{};
    var off: usize = 0;
    while (off < data.len) {
        const sp = std.mem.indexOfScalarPos(u8, data, off, ' ') orelse return error.InvalidArchive;
        const len = std.fmt.parseInt(usize, data[off..sp], 10) catch return error.InvalidArchive;
        if (len == 0 or off + len > data.len) return error.InvalidArchive;
        const rec = data[sp + 1 .. off + len];
        const rec_clean = std.mem.trimEnd(u8, rec, "\n");
        if (std.mem.startsWith(u8, rec_clean, "path=")) {
            res.path = rec_clean[5..];
        } else if (std.mem.startsWith(u8, rec_clean, "linkpath=")) {
            res.linkpath = rec_clean[9..];
        } else if (std.mem.startsWith(u8, rec_clean, "size=")) {
            res.size = std.fmt.parseInt(u64, rec_clean[5..], 10) catch return error.InvalidArchive;
        }
        off += len;
    }
    return res;
}

fn isAllZero(block: *const [512]u8) bool {
    for (block) |b| if (b != 0) return false;
    return true;
}

fn isSafeLinkTarget(target: []const u8) bool {
    if (target.len == 0) return false;
    if (target[0] == '/') return false;
    var it = std.mem.splitScalar(u8, target, '/');
    while (it.next()) |c| {
        if (std.mem.eql(u8, c, "..")) return false;
    }
    return true;
}

fn entryPath(allocator: std.mem.Allocator, h: *const Header) Error![]u8 {
    const base = if (h.pax_path) |p| p else h.name;
    if (h.prefix.len > 0 and h.pax_path == null) {
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ h.prefix, base }) catch return error.OutOfMemory;
    }
    return allocator.dupe(u8, base) catch return error.OutOfMemory;
}

pub fn extract(archive_path: []const u8, dest_fd: sys.fd_t) !void {
    var path_buf: [fs.max_path + 1]u8 = undefined;
    if (archive_path.len + 1 > path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..archive_path.len], archive_path);
    path_buf[archive_path.len] = 0;
    const zpath = path_buf[0..archive_path.len :0];

    // detect gzip by content
    var magic: [2]u8 = undefined;
    const probe = try sys.openat(linux.AT.FDCWD, zpath, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    defer sys.close(probe);
    const got = try sys.read(probe, &magic);
    const is_gz = got == 2 and magic[0] == 0x1f and magic[1] == 0x8b;

    var reader = Reader{ .kind = if (is_gz) .gzip else .plain };
    if (is_gz) {
        reader.gz = gzopen(zpath.ptr, "rb");
        if (reader.gz == null) return error.GzipError;
    } else {
        reader.fd = try sys.openat(linux.AT.FDCWD, zpath, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    }
    defer reader.close();

    var pending_path: ?[]u8 = null;
    var pending_link: ?[]u8 = null;
    var pending_size: ?u64 = null;
    defer if (pending_path) |p| gpa.free(p);
    defer if (pending_link) |p| gpa.free(p);

    var block: [512]u8 = undefined;
    while (true) {
        const n = try reader.readExactAllowEof(&block);
        if (n == 0) break;
        if (n != 512) return error.Truncated;
        if (isAllZero(&block)) break;

        var h = try parseHeader(&block);

        // GNU long name / long link / pax
        if (h.typeflag == 'L' or h.typeflag == 'K') {
            if (h.size > 1024 * 1024) return error.InvalidArchive;
            const data = try gpa.alloc(u8, @intCast(h.size));
            defer gpa.free(data);
            try reader.readExact(data);
            const padded = (h.size + 511) & ~@as(u64, 511);
            if (padded > h.size) try reader.skip(@intCast(padded - h.size));
            if (h.typeflag == 'L') {
                if (pending_path) |p| gpa.free(p);
                pending_path = gpa.dupe(u8, std.mem.sliceTo(data, 0)) catch return error.OutOfMemory;
            } else {
                if (pending_link) |p| gpa.free(p);
                pending_link = gpa.dupe(u8, std.mem.sliceTo(data, 0)) catch return error.OutOfMemory;
            }
            continue;
        }
        if (h.typeflag == 'x' or h.typeflag == 'X') {
            if (h.size > 16 * 1024 * 1024) return error.InvalidArchive;
            const data = try gpa.alloc(u8, @intCast(h.size));
            defer gpa.free(data);
            try reader.readExact(data);
            const padded = (h.size + 511) & ~@as(u64, 511);
            if (padded > h.size) try reader.skip(@intCast(padded - h.size));
            const pax = try parsePax(data);
            if (pax.path) |p| {
                if (pending_path) |old| gpa.free(old);
                pending_path = gpa.dupe(u8, p) catch return error.OutOfMemory;
            }
            if (pax.linkpath) |p| {
                if (pending_link) |old| gpa.free(old);
                pending_link = gpa.dupe(u8, p) catch return error.OutOfMemory;
            }
            if (pax.size) |s| pending_size = s;
            continue;
        }
        if (h.typeflag == 'g') {
            // global pax header: skip
            try reader.skip(@intCast((h.size + 511) & ~@as(u64, 511)));
            continue;
        }

        if (pending_path) |p| {
            h.pax_path = p;
        }
        if (pending_link) |p| {
            h.pax_linkpath = p;
        }
        if (pending_size) |s| {
            h.pax_size = s;
        }

        const raw_path = try entryPath(gpa, &h);
        defer gpa.free(raw_path);
        var norm_buf: [fs.max_path + 1]u8 = undefined;
        const norm = fs.normalizeRel(&norm_buf, raw_path) catch |e| switch (e) {
            error.PathEscape => return error.PathEscape,
            error.AbsolutePath => return error.AbsolutePath,
            error.EmptyPath => return error.EmptyPath,
            error.PathTooLong => return error.PathTooLong,
            else => return error.InvalidPath,
        };
        const base = fs.baseName(norm);
        var zname_buf: [fs.max_path + 1]u8 = undefined;
        @memcpy(zname_buf[0..base.len], base);
        zname_buf[base.len] = 0;
        const zname = zname_buf[0..base.len :0];

        const size: u64 = if (h.pax_size) |s| s else h.size;
        const padded = (size + 511) & ~@as(u64, 511);

        switch (h.typeflag) {
            0, '0', '7' => {
                const parent = try fs.ensureDirBeneath(dest_fd, fs.dirName(norm));
                defer sys.close(parent);
                const fd = try sys.openBeneath(parent, zname, .{
                    .ACCMODE = .WRONLY,
                    .CREAT = true,
                    .TRUNC = true,
                    .CLOEXEC = true,
                }, 0o600);
                defer sys.close(fd);
                var left = size;
                var buf: [64 * 1024]u8 = undefined;
                while (left > 0) {
                    const take: usize = @intCast(@min(left, buf.len));
                    try reader.readExact(buf[0..take]);
                    try sys.writeAll(fd, buf[0..take]);
                    left -= take;
                }
                sys.fchmod(fd, h.mode) catch {};
                if (padded > size) try reader.skip(@intCast(padded - size));
            },
            '5' => {
                try fs.makeDirBeneath(dest_fd, norm);
                // chmod best effort
                const fd = fs.openDirBeneath(dest_fd, norm) catch null;
                if (fd) |d| {
                    sys.fchmod(d, h.mode) catch {};
                    sys.close(d);
                }
                if (padded > 0) try reader.skip(@intCast(padded));
            },
            '2' => {
                const target = if (h.pax_linkpath) |p| p else h.linkname;
                if (!isSafeLinkTarget(target)) return error.PathEscape;
                const parent = try fs.ensureDirBeneath(dest_fd, fs.dirName(norm));
                defer sys.close(parent);
                var zt_buf: [fs.max_path + 1]u8 = undefined;
                if (target.len + 1 > zt_buf.len) return error.PathTooLong;
                @memcpy(zt_buf[0..target.len], target);
                zt_buf[target.len] = 0;
                sys.unlinkat(parent, zname, 0) catch {};
                try sys.symlinkat(zt_buf[0..target.len :0], parent, zname);
                if (padded > 0) try reader.skip(@intCast(padded));
            },
            '1' => {
                const target = if (h.pax_linkpath) |p| p else h.linkname;
                var tnb: [fs.max_path + 1]u8 = undefined;
                const tnorm = fs.normalizeRel(&tnb, target) catch return error.PathEscape;
                const parent = try fs.ensureDirBeneath(dest_fd, fs.dirName(norm));
                defer sys.close(parent);
                var zt_buf: [fs.max_path + 1]u8 = undefined;
                @memcpy(zt_buf[0..tnorm.len], tnorm);
                zt_buf[tnorm.len] = 0;
                sys.unlinkat(parent, zname, 0) catch {};
                sys.linkat(dest_fd, zt_buf[0..tnorm.len :0], parent, zname, 0) catch |e| switch (e) {
                    error.NotFound => return error.LinkTargetMissing,
                    else => return e,
                };
                if (padded > 0) try reader.skip(@intCast(padded));
            },
            else => {
                // devices, fifos and other special entries are ignored
                log.warn("tar: ignoring unsupported entry type '{c}' for {s}", .{ h.typeflag, norm });
                if (padded > 0) try reader.skip(@intCast(padded));
            },
        }

        if (pending_path) |p| {
            gpa.free(p);
            pending_path = null;
        }
        if (pending_link) |p| {
            gpa.free(p);
            pending_link = null;
        }
        pending_size = null;
    }
}

test "tar extraction rejects path escapes and absolute paths" {
    var buf: [256]u8 = undefined;
    const dir = try std.fmt.bufPrint(&buf, "/tmp/opencode/podtest-tar-{d}", .{std.os.linux.getpid()});
    try fs.makeDirAllAbsolute(dir);
    var zb: [fs.max_path + 1]u8 = undefined;
    @memcpy(zb[0..dir.len], dir);
    zb[dir.len] = 0;
    const rootfd = try sys.openat(linux.AT.FDCWD, zb[0..dir.len :0], .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    defer sys.close(rootfd);
    defer {
        var pb: [fs.max_path + 1]u8 = undefined;
        const parent = fs.dirName(dir);
        @memcpy(pb[0..parent.len], parent);
        pb[parent.len] = 0;
        if (sys.openat(linux.AT.FDCWD, pb[0..parent.len :0], .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0)) |pfd| {
            fs.removeTreeBeneath(pfd, fs.baseName(dir)) catch {};
            sys.close(pfd);
        } else |_| {}
    }

    const tar_write = @import("tar_write.zig");
    const cases = [_]struct { name: []const u8, want: anyerror }{
        .{ .name = "../escape.txt", .want = error.PathEscape },
        .{ .name = "/etc/passwd", .want = error.AbsolutePath },
    };
    for (cases, 0..) |case, i| {
        var b = tar_write.Builder{};
        defer b.deinit();
        try b.addFile(case.name, "owned", 0o644);
        const archive = try b.finish();
        defer gpa.free(archive);
        var pb: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&pb, "{s}/case-{d}.tar", .{ dir, i });
        try fs.writeFileAbsolute(path, archive);
        try std.testing.expectError(case.want, extract(path, rootfd));
    }

    var ok = tar_write.Builder{};
    defer ok.deinit();
    try ok.addFile("nested/hello.txt", "hi", 0o644);
    const archive = try ok.finish();
    defer gpa.free(archive);
    var pb: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&pb, "{s}/ok.tar", .{dir});
    try fs.writeFileAbsolute(path, archive);
    try extract(path, rootfd);
    const data = try fs.readFileBeneath(rootfd, "nested/hello.txt", 64);
    defer gpa.free(data);
    try std.testing.expectEqualStrings("hi", data);
}
