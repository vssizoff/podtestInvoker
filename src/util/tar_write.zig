//! Minimal deterministic ustar writer used to build Podman build contexts.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const fs = @import("fs.zig");
const gpa = @import("mem.zig").gpa;

pub const Error = error{
    InvalidPath,
    NameTooLong,
    OutOfMemory,
} || sys.Error;

pub const Builder = struct {
    out: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Builder) void {
        self.out.deinit(gpa);
    }

    pub fn finish(self: *Builder) ![]u8 {
        // two zero blocks terminate the archive
        try self.out.appendNTimes(gpa, 0, 1024);
        return self.out.toOwnedSlice(gpa);
    }

    fn octal(field: []u8, value: u64) void {
        @memset(field, 0);
        const text = std.fmt.bufPrint(field[0 .. field.len - 1], "{o}", .{value}) catch {
            @memset(field, '0');
            return;
        };
        _ = text;
        // pad with leading zeroes, tar prefers NUL termination
        var used: usize = 0;
        while (used < field.len and field[used] != 0) : (used += 1) {}
        if (used < field.len - 1) {
            const shift = field.len - 1 - used;
            var i: usize = used;
            while (i > 0) {
                i -= 1;
                field[i + shift] = field[i];
            }
            @memset(field[0..shift], '0');
        }
    }

    fn header(self: *Builder, name: []const u8, mode: u32, size: u64, typeflag: u8, linkname: []const u8) !void {
        var block: [512]u8 = @splat(0);
        if (name.len > 100) return error.NameTooLong;
        @memcpy(block[0..name.len], name);
        octal(block[100..108], mode & 0o7777);
        octal(block[108..116], 0);
        octal(block[116..124], 0);
        octal(block[124..136], size);
        octal(block[136..148], 0);
        @memset(block[148..156], ' ');
        block[156] = typeflag;
        if (linkname.len > 100) return error.NameTooLong;
        @memcpy(block[157 .. 157 + linkname.len], linkname);
        @memcpy(block[257..263], "ustar\x00");
        @memcpy(block[263..265], "00");
        @memcpy(block[265..269], "root");
        @memcpy(block[297..301], "root");

        var sum: u64 = 0;
        for (block) |b| sum += b;
        var cksum: [8]u8 = undefined;
        _ = std.fmt.bufPrint(&cksum, "{o:0>6}\x00 ", .{sum}) catch unreachable;
        @memcpy(block[148..156], &cksum);

        try self.out.appendSlice(gpa, &block);
    }

    fn longName(self: *Builder, name: []const u8) !void {
        const data = try gpa.dupe(u8, name);
        defer gpa.free(data);
        try self.header("././@LongLink", 0o644, name.len, 'L', "");
        try self.out.appendSlice(gpa, data);
        const pad = (name.len + 511) & ~@as(usize, 511);
        try self.out.appendNTimes(gpa, 0, pad - name.len);
    }

    fn nameField(self: *Builder, name: []const u8) ![]const u8 {
        if (name.len <= 100) return name;
        try self.longName(name);
        return name[0..100];
    }

    pub fn addFile(self: *Builder, name: []const u8, data: []const u8, mode: u32) !void {
        const nm = try self.nameField(name);
        try self.header(nm, mode, data.len, '0', "");
        try self.out.appendSlice(gpa, data);
        const pad = (data.len + 511) & ~@as(usize, 511);
        try self.out.appendNTimes(gpa, 0, pad - data.len);
    }

    pub fn addDir(self: *Builder, name_in: []const u8) !void {
        var name = name_in;
        var buf: [fs.max_path + 1]u8 = undefined;
        if (name.len == 0 or name[name.len - 1] != '/') {
            if (name.len + 1 > buf.len) return error.NameTooLong;
            @memcpy(buf[0..name.len], name);
            buf[name.len] = '/';
            name = buf[0 .. name.len + 1];
        }
        const nm = try self.nameField(name);
        try self.header(nm, 0o755, 0, '5', "");
    }

    pub fn addSymlink(self: *Builder, name: []const u8, target: []const u8) !void {
        const nm = try self.nameField(name);
        if (target.len > 100) return error.NameTooLong;
        try self.header(nm, 0o777, 0, '2', target);
    }
};

const WalkCtx = struct {
    builder: *Builder,
    prefix: []u8,
};

/// Add the contents of a directory beneath `rootfd` (relative `rel_dir`) to a
/// tar builder.  Symlinks are preserved as symlink entries; devices and fifos
/// are skipped.
pub fn addTree(builder: *Builder, rootfd: sys.fd_t, rel_dir: []const u8) !void {
    if (std.mem.eql(u8, rel_dir, ".") or rel_dir.len == 0) {
        const dir = try sys.openat(rootfd, ".", .{
            .ACCMODE = .RDONLY,
            .DIRECTORY = true,
            .CLOEXEC = true,
        }, 0);
        defer sys.close(dir);
        var prefix_buf: [1]u8 = undefined;
        var ctx = WalkCtx{ .builder = builder, .prefix = prefix_buf[0..0] };
        try walk(&ctx, dir);
        return;
    }
    var nb: [fs.max_path + 1]u8 = undefined;
    const norm = try fs.normalizeRel(&nb, rel_dir);
    const dir = try fs.openDirBeneath(rootfd, norm);
    defer sys.close(dir);
    var prefix_buf: [fs.max_path + 1]u8 = undefined;
    if (norm.len > prefix_buf.len) return error.NameTooLong;
    @memcpy(prefix_buf[0..norm.len], norm);
    var ctx = WalkCtx{ .builder = builder, .prefix = prefix_buf[0..norm.len] };
    try walk(&ctx, dir);
}

fn walk(ctx: *WalkCtx, dir: sys.fd_t) !void {
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
        var zb: [fs.max_path + 1]u8 = undefined;
        if (name.len + 1 > zb.len) return error.NameTooLong;
        @memcpy(zb[0..name.len], name);
        zb[name.len] = 0;
        const z = zb[0..name.len :0];
        const rel = if (ctx.prefix.len == 0)
            name
        else
            try std.fmt.allocPrint(gpa, "{s}/{s}", .{ ctx.prefix, name });
        defer if (ctx.prefix.len != 0) gpa.free(rel);

        switch (kind) {
            .dir => {
                try ctx.builder.addDir(rel);
                const sub = try sys.openat(dir, z, .{
                    .ACCMODE = .RDONLY,
                    .DIRECTORY = true,
                    .NOFOLLOW = true,
                    .CLOEXEC = true,
                }, 0);
                defer sys.close(sub);
                const old_prefix = ctx.prefix;
                ctx.prefix = @constCast(rel);
                defer ctx.prefix = old_prefix;
                try walk(ctx, sub);
            },
            .symlink => {
                var target_buf: [fs.max_path + 1]u8 = undefined;
                const target = try sys.readlinkat(dir, z, &target_buf);
                try ctx.builder.addSymlink(rel, target);
            },
            .file => {
                const fd = try sys.openat(dir, z, .{
                    .ACCMODE = .RDONLY,
                    .NOFOLLOW = true,
                    .CLOEXEC = true,
                }, 0);
                defer sys.close(fd);
                const st = try sys.fstat(fd);
                var out: std.ArrayList(u8) = .empty;
                defer out.deinit(gpa);
                var buf: [64 * 1024]u8 = undefined;
                while (true) {
                    const n = try sys.read(fd, &buf);
                    if (n == 0) break;
                    try out.appendSlice(gpa, buf[0..n]);
                }
                try ctx.builder.addFile(rel, out.items, st.mode & 0o7777);
            },
            else => {},
        }
    }
}

/// Build a tar archive of `rel_dir` inside a run directory.
pub fn contextFromDir(rootfd: sys.fd_t, rel_dir: []const u8) ![]u8 {
    var b = Builder{};
    defer b.deinit();
    try addTree(&b, rootfd, rel_dir);
    return b.finish();
}

/// Build a tar containing one file at `name`.
pub fn contextWithFile(name: []const u8, data: []const u8, mode: u32) ![]u8 {
    var b = Builder{};
    defer b.deinit();
    try b.addFile(name, data, mode);
    return b.finish();
}
