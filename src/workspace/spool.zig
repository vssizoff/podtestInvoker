const std = @import("std");
const download = @import("download.zig");
const linux = std.os.linux;

pub const Limits = struct { bytes: u64, files: usize };

/// One flat staging directory per spool. Its parent must be trusted and every
/// writer must use this API, or take the same directory lock. Workloads must
/// not have access. Concurrent callers get SpoolBusy and can retry later.
pub fn get(io: std.Io, absolute_path: []const u8, limits: Limits, name: []const u8, url: [:0]const u8, descriptor: download.Descriptor, options: download.Options) !void {
    if (limits.files == 0) return error.InvalidSpoolConfig;
    try download.validateName(name);
    const dir = try openLocked(io, absolute_path);
    defer dir.close(io);

    const remaining = try reserve(io, dir, limits, descriptor.bytes);
    var transfer_options = options;
    transfer_options.byte_budget = @min(options.byte_budget, remaining);
    try download.get(io, dir, name, url, descriptor, transfer_options);
}

/// Persist exactly the declared number of bytes from a completed output.
/// The descriptor is returned only after no-replace publication and sync.
pub fn stage(io: std.Io, absolute_path: []const u8, limits: Limits, name: []const u8, size: u64, reader: *std.Io.Reader) !download.Descriptor {
    return stageImpl(io, absolute_path, limits, name, size, reader, null);
}

pub fn stageExpected(io: std.Io, path: []const u8, limits: Limits, name: []const u8, expected: download.Descriptor, reader: *std.Io.Reader) !void {
    _ = try stageImpl(io, path, limits, name, expected.bytes, reader, expected.sha256);
}

fn stageImpl(io: std.Io, absolute_path: []const u8, limits: Limits, name: []const u8, size: u64, reader: *std.Io.Reader, expected: ?[32]u8) !download.Descriptor {
    try download.validateName(name);
    const dir = try openLocked(io, absolute_path);
    defer dir.close(io);
    if (expected) |digest| {
        if (fileInfo(io, dir, name)) |info| {
            if (info.size != size) return error.ArtifactSizeMismatch;
            const file = try dir.openFile(io, name, .{ .follow_symlinks = false });
            defer file.close(io);
            var hash = std.crypto.hash.sha2.Sha256.init(.{});
            var buffer: [32768]u8 = undefined;
            var offset: u64 = 0;
            while (offset < size) {
                const n = try file.readPositional(io, &.{buffer[0..@intCast(@min(size - offset, buffer.len))]}, offset);
                if (n == 0) return error.ArtifactSizeMismatch;
                hash.update(buffer[0..n]);
                offset += n;
            }
            if (!std.mem.eql(u8, &digest, &hash.finalResult())) return error.ArtifactDigestMismatch;
            try syncDirectory(dir, error.ArtifactPublicationUncertain);
            return .{ .bytes = size, .sha256 = digest };
        } else |err| if (err != error.FileNotFound) return err;
    }
    _ = try reserve(io, dir, limits, size);

    var staged = try dir.createFileAtomic(io, name, .{ .permissions = .fromMode(0o600) });
    defer staged.deinit(io);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var remaining = size;
    var buffer: [32 * 1024]u8 = undefined;
    while (remaining > 0) {
        const chunk = buffer[0..@min(remaining, buffer.len)];
        reader.readSliceAll(chunk) catch |err| switch (err) {
            error.EndOfStream => return error.ArtifactSizeMismatch,
            else => return err,
        };
        try staged.file.writeStreamingAll(io, chunk);
        hash.update(chunk);
        remaining -= chunk.len;
    }
    if (reader.takeByte()) |_| {
        return error.ArtifactSizeMismatch;
    } else |err| {
        if (err != error.EndOfStream) return err;
    }
    var descriptor: download.Descriptor = .{ .bytes = size, .sha256 = undefined };
    hash.final(&descriptor.sha256);
    if (expected) |digest| if (!std.mem.eql(u8, &digest, &descriptor.sha256)) return error.ArtifactDigestMismatch;
    try staged.file.sync(io);
    try staged.link(io);
    try syncDirectory(dir, error.ArtifactPublicationUncertain);
    return descriptor;
}

fn reserve(io: std.Io, dir: std.Io.Dir, limits: Limits, bytes: u64) !u64 {
    if (limits.files == 0) return error.InvalidSpoolConfig;
    var remaining = limits.bytes;
    var files_left = limits.files;
    var entries = dir.iterate();
    while (try entries.next(io)) |entry| {
        if (files_left == 0) return error.SpoolFileLimit;
        const info = try fileInfo(io, dir, entry.name);
        if (info.size > remaining) return error.SpoolByteLimit;
        remaining -= info.size;
        files_left -= 1;
    }
    if (files_left == 0) return error.SpoolFileLimit;
    if (bytes > remaining) return error.SpoolByteLimit;
    return remaining;
}

/// Upload a staged artifact without removing it. The caller must retain it
/// until Backend confirms the object and the reference is durably recorded.
pub fn put(io: std.Io, absolute_path: []const u8, name: []const u8, url: [:0]const u8, descriptor: download.Descriptor, options: download.Options) !void {
    try download.validateName(name);
    const dir = try openLocked(io, absolute_path);
    defer dir.close(io);
    _ = try fileInfo(io, dir, name);
    const file = try dir.openFile(io, name, .{ .follow_symlinks = false });
    defer file.close(io);
    try download.put(io, file, url, descriptor, options);
}

/// Release quota after the caller has finished using a published artifact.
/// Missing files are accepted so removal can be retried after an uncertain sync.
pub fn remove(io: std.Io, absolute_path: []const u8, name: []const u8) !void {
    try download.validateName(name);
    const dir = try openLocked(io, absolute_path);
    defer dir.close(io);
    const info: ?std.Io.File.Stat = fileInfo(io, dir, name) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (info != null) try dir.deleteFile(io, name);
    try syncDirectory(dir, error.SpoolRemovalUncertain);
}

fn syncDirectory(dir: std.Io.Dir, failure: anyerror) !void {
    while (true) switch (linux.errno(linux.fsync(dir.handle))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return failure,
    };
}

fn fileInfo(io: std.Io, dir: std.Io.Dir, name: []const u8) !std.Io.File.Stat {
    const info = try dir.statFile(io, name, .{ .follow_symlinks = false });
    if (info.kind != .file or info.nlink != 1 or info.permissions.toMode() & 0o077 != 0) return error.UnsafeSpoolEntry;
    return info;
}

pub fn openLocked(io: std.Io, path: []const u8) !std.Io.Dir {
    // Each call needs a separate open file description for flock to serialize it.
    const dir = try openDirectory(io, path);
    errdefer dir.close(io);
    try lock(dir);
    return dir;
}

fn openDirectory(io: std.Io, path: []const u8) !std.Io.Dir {
    if (path.len <= 1 or path[0] != '/') return error.InvalidSpoolConfig;
    var relative: [linux.PATH_MAX]u8 = undefined;
    const length = path.len - 1;
    if (length >= relative.len or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidSpoolConfig;
    var components = std.mem.splitScalar(u8, path[1..], '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return error.InvalidSpoolConfig;
    }
    @memcpy(relative[0..length], path[1..]);
    relative[length] = 0;

    const root = try std.Io.Dir.openDirAbsolute(io, "/", .{ .follow_symlinks = false });
    defer root.close(io);
    const OpenHow = extern struct { flags: u64, mode: u64, resolve: u64 };
    const resolve_no_symlinks = 0x04;
    const resolve_beneath = 0x08;
    const flags: linux.O = .{ .DIRECTORY = true, .CLOEXEC = true };
    const how: OpenHow = .{ .flags = @as(u32, @bitCast(flags)), .mode = 0, .resolve = resolve_no_symlinks | resolve_beneath };
    while (true) {
        const result = linux.syscall4(.openat2, @intCast(root.handle), @intFromPtr(&relative), @intFromPtr(&how), @sizeOf(OpenHow));
        switch (linux.errno(result)) {
            .SUCCESS => return .{ .handle = @intCast(result) },
            .INTR => continue,
            .LOOP, .XDEV => return error.UnsafeSpoolDirectory,
            .NOSYS => return error.SpoolResolutionUnavailable,
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.NotDir,
            .ACCES, .PERM => return error.AccessDenied,
            else => return error.SpoolDirectoryOpenFailed,
        }
    }
}

fn lock(dir: std.Io.Dir) !void {
    var info: linux.Statx = undefined;
    while (true) switch (linux.errno(linux.statx(dir.handle, "", linux.AT.EMPTY_PATH, .{ .MODE = true, .UID = true }, &info))) {
        .SUCCESS => break,
        .INTR => continue,
        else => return error.SpoolDirectoryStatFailed,
    };
    if (!info.mask.MODE or !info.mask.UID or info.uid != linux.geteuid() or info.mode & 0o077 != 0) return error.UnsafeSpoolDirectory;
    while (true) switch (linux.errno(linux.flock(dir.handle, std.posix.LOCK.EX | std.posix.LOCK.NB))) {
        .SUCCESS => return,
        .INTR => continue,
        .AGAIN => return error.SpoolBusy,
        else => return error.SpoolLockFailed,
    };
}
