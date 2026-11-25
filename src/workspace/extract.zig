const std = @import("std");
const linux = std.os.linux;

pub const Limits = struct { entries: usize, bytes: u64, depth: usize, path_bytes: usize };
pub const Kind = enum { directory, regular, symlink, hardlink, special };
pub const Entry = struct { path: []const u8, kind: Kind, size: u64 = 0 };
const staging_prefix = ".extract-";
const manifest_name = "manifest.json";
const Node = enum { implicit_dir, explicit_dir, file };

pub const BundleLimits = struct {
    entries: usize,
    archive_bytes: u64,
    unpacked_bytes: u64,
    depth: usize,
    path_bytes: usize,
};

/// Bundle v1 uses uncompressed USTAR with a required first regular entry
/// named manifest.json. The manifest describes all remaining regular files.
/// The caller supplies the trusted size and digest of the complete archive.
pub fn materializeTar(io: std.Io, parent: std.Io.Dir, workspace_name: []const u8, allocator: std.mem.Allocator, limits: BundleLimits, archive: *std.Io.Reader, archive_bytes: u64, expected_archive_sha256: [32]u8, expected_execution_format: []const u8, expected_execution_format_version: u32) !void {
    return materializeInputs(io, parent, workspace_name, allocator, limits, archive, archive_bytes, expected_archive_sha256, expected_execution_format, expected_execution_format_version, null);
}

pub const SubmissionSource = struct { reader: *std.Io.Reader, bytes: u64, sha256: [32]u8 };

/// Both pinned inputs become visible together, or neither does. Bundle v1
/// reserves solution/, so the task bundle cannot supply the submission.
pub fn materializeInputs(io: std.Io, parent: std.Io.Dir, workspace_name: []const u8, allocator: std.mem.Allocator, limits: BundleLimits, archive: *std.Io.Reader, archive_bytes: u64, expected_archive_sha256: [32]u8, expected_execution_format: []const u8, expected_execution_format_version: u32, submission: ?SubmissionSource) !void {
    if (archive_bytes > limits.archive_bytes) return error.ArchiveByteLimit;
    if (archive_bytes < 2048 or archive_bytes % 512 != 0) return error.InvalidTarLength;
    try materialize(io, parent, workspace_name, allocator, .{
        .entries = limits.entries,
        .bytes = limits.unpacked_bytes,
        .depth = limits.depth,
        .path_bytes = limits.path_bytes,
    }, TarSource{
        .allocator = allocator,
        .reader = archive,
        .expected_bytes = archive_bytes,
        .expected_sha256 = expected_archive_sha256,
        .expected_execution_format = expected_execution_format,
        .expected_execution_format_version = expected_execution_format_version,
        .limits = limits,
        .submission = submission,
    });
}

const TarSource = struct {
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    expected_bytes: u64,
    expected_sha256: [32]u8,
    expected_execution_format: []const u8,
    expected_execution_format_version: u32,
    limits: BundleLimits,
    submission: ?SubmissionSource,

    fn readEntries(self: @This(), writer: *Writer) !void {
        var tar: TarReader = .{ .reader = self.reader, .remaining = self.expected_bytes };
        const first = try tar.header();
        if (!std.mem.eql(u8, first.path(), manifest_name) or first.size > 1024 * 1024)
            return error.InvalidBundleManifestEntry;
        if (first.size > self.limits.unpacked_bytes) return error.ArchiveByteLimit;
        const json = try self.allocator.alloc(u8, @intCast(first.size));
        defer self.allocator.free(json);
        try tar.read(json);
        try tar.padding(first.size);
        const parsed = try std.json.parseFromSlice(Manifest, self.allocator, json, .{
            .duplicate_field_behavior = .@"error",
            .ignore_unknown_fields = false,
        });
        defer parsed.deinit();
        const manifest = parsed.value;
        const is_lua = std.mem.eql(u8, manifest.execution_format, "scripted_lua");
        const is_standard = std.mem.eql(u8, manifest.execution_format, "standard");
        if (!is_lua and !is_standard) return error.UnsupportedExecutionFormat;
        if (manifest.format_version != 1 or manifest.execution_format_version != 1 or
            manifest.execution_format_version != self.expected_execution_format_version or
            !std.mem.eql(u8, manifest.execution_format, self.expected_execution_format))
            return error.UnsupportedBundleVersion;
        if (is_lua) {
            if (manifest.runner_api_version.value != 1) return error.UnsupportedRunnerApiVersion;
        } else if (manifest.runner_api_version.value != null) return error.UnexpectedRunnerApiVersion;
        if (manifest.files.len >= self.limits.entries) return error.ArchiveEntryLimit;
        var total = first.size;
        var has_runner = false;
        var previous: ?[]const u8 = null;
        for (manifest.files) |file| {
            try validatePath(file.path, writer.limits);
            if (!std.unicode.utf8ValidateSlice(file.path) or isReservedBundlePath(file.path)) return error.InvalidArchivePath;
            if (previous) |path| if (std.mem.order(u8, path, file.path) != .lt) return error.BundleFileOrder;
            previous = file.path;
            if (file.size > self.limits.unpacked_bytes - total) return error.ArchiveByteLimit;
            total += file.size;
            has_runner = has_runner or std.mem.eql(u8, file.path, "runner.lua");
        }
        if (is_lua and !has_runner) return error.MissingBundleRunner;

        var body = std.Io.Reader.fixed(json);
        try writer.add(.{ .path = manifest_name, .kind = .regular, .size = first.size }, &body);
        for (manifest.files) |file| {
            var expected: [32]u8 = undefined;
            for (file.sha256) |c| switch (c) {
                '0'...'9', 'a'...'f' => {},
                else => return error.InvalidBundleFileDigest,
            };
            const decoded = std.fmt.hexToBytes(&expected, file.sha256) catch return error.InvalidBundleFileDigest;
            if (decoded.len != expected.len) return error.InvalidBundleFileDigest;
            const header = try tar.header();
            if (!std.mem.eql(u8, file.path, header.path()) or file.size != header.size)
                return error.BundleFileDescriptorMismatch;
            try tar.reserve(file.size);
            var file_hash = Sha256.init(.{});
            try writer.addHashed(.{ .path = file.path, .kind = .regular, .size = file.size }, tar.reader, .{ .archive = &tar.hash, .file = &file_hash });
            if (!std.mem.eql(u8, &file_hash.finalResult(), &expected)) return error.BundleFileDigestMismatch;
            try tar.padding(file.size);
        }

        var terminator: [1024]u8 = undefined;
        try tar.read(&terminator);
        if (!allZero(&terminator) or tar.remaining != 0) return error.InvalidTarTerminator;
        if (tar.reader.takeByte()) |_| return error.TrailingArchiveData else |err| switch (err) {
            error.EndOfStream => {},
            else => return err,
        }
        if (!std.mem.eql(u8, &tar.hash.finalResult(), &self.expected_sha256)) return error.BundleArchiveDigestMismatch;
        if (self.submission) |submission| {
            var hash = Sha256.init(.{});
            try writer.addHashed(.{ .path = "solution/source", .kind = .regular, .size = submission.bytes }, submission.reader, .{ .file = &hash });
            if (!std.mem.eql(u8, &hash.finalResult(), &submission.sha256)) return error.SourceDigestMismatch;
            if (submission.reader.takeByte()) |_| return error.TrailingSourceData else |err| switch (err) {
                error.EndOfStream => {},
                else => return err,
            }
        }
    }
};

const Sha256 = std.crypto.hash.sha2.Sha256;
const PayloadHashes = struct { archive: ?*Sha256 = null, file: *Sha256 };
const Manifest = struct {
    format_version: u32,
    execution_format: []const u8,
    execution_format_version: u32,
    runner_api_version: RunnerApiVersion = .{ .value = null },
    files: []const struct { path: []const u8, size: u64, sha256: []const u8 },
};

const RunnerApiVersion = struct {
    value: ?u32,

    // Only an omitted key gets the default; null and coerced numbers are invalid.
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!RunnerApiVersion {
        const token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
        const digits = switch (token) {
            .number, .allocated_number => |bytes| bytes,
            else => return error.UnexpectedToken,
        };
        for (digits) |digit| if (digit < '0' or digit > '9') return error.InvalidNumber;
        return .{ .value = try std.fmt.parseInt(u32, digits, 10) };
    }
};

fn isReservedBundlePath(path: []const u8) bool {
    const first = path[0 .. std.mem.indexOfScalar(u8, path, '/') orelse path.len];
    return std.mem.eql(u8, first, manifest_name) or std.mem.eql(u8, first, "solution");
}

const TarHeader = struct {
    name: [256]u8 = undefined,
    len: usize,
    size: u64,

    fn path(self: *const TarHeader) []const u8 {
        return self.name[0..self.len];
    }
};

const TarReader = struct {
    reader: *std.Io.Reader,
    remaining: u64,
    hash: Sha256 = Sha256.init(.{}),

    fn reserve(self: *TarReader, count: u64) !void {
        if (count > self.remaining) return error.TruncatedArchiveEntry;
        self.remaining -= count;
    }

    fn read(self: *TarReader, out: []u8) !void {
        try self.reserve(out.len);
        try readPayload(self.reader, out);
        self.hash.update(out);
    }

    fn padding(self: *TarReader, size: u64) !void {
        var buffer: [511]u8 = undefined;
        const bytes = buffer[0..@intCast((512 - size % 512) % 512)];
        try self.read(bytes);
        if (!allZero(bytes)) return error.InvalidTarPadding;
    }

    fn header(self: *TarReader) !TarHeader {
        var block: [512]u8 = undefined;
        try self.read(&block);
        if (!std.mem.eql(u8, block[257..265], "ustar\x0000")) return error.InvalidTarHeader;
        const checksum = try parseOctal(block[148..156]);
        var sum: u64 = 8 * ' ';
        for (block[0..148]) |byte| sum += byte;
        for (block[156..]) |byte| sum += byte;
        if (checksum != sum) return error.InvalidTarChecksum;
        if ((block[156] != '0' and block[156] != 0) or !allZero(block[157..257])) return error.UnsupportedArchiveEntry;
        if (!allZero(block[500..512])) return error.InvalidTarHeader;

        const name = try tarString(block[0..100]);
        const prefix = try tarString(block[345..500]);
        if (name.len == 0) return error.InvalidTarHeader;
        var result: TarHeader = .{ .len = 0, .size = try parseOctal(block[124..136]) };
        if (prefix.len > 0) {
            @memcpy(result.name[0..prefix.len], prefix);
            result.name[prefix.len] = '/';
            result.len = prefix.len + 1;
        }
        @memcpy(result.name[result.len..][0..name.len], name);
        result.len += name.len;
        return result;
    }
};

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn tarString(bytes: []const u8) ![]const u8 {
    const end = std.mem.indexOfScalar(u8, bytes, 0) orelse return bytes;
    if (!allZero(bytes[end..])) return error.InvalidTarHeader;
    return bytes[0..end];
}

fn parseOctal(field: []const u8) !u64 {
    const digits = std.mem.trimEnd(u8, std.mem.trimStart(u8, field, " "), " \x00");
    if (digits.len == 0) return error.InvalidTarHeader;
    var value: u64 = 0;
    for (digits) |digit| {
        if (digit < '0' or digit > '7') return error.InvalidTarHeader;
        value = value * 8 + (digit - '0');
    }
    return value;
}

fn testTarEntry(out: []u8, path: []const u8, kind: u8, body: []const u8) void {
    @memcpy(out[0..path.len], path);
    @memset(out[124..135], '0');
    var size = body.len;
    var index: usize = 135;
    while (size != 0) : (size /= 8) {
        index -= 1;
        out[index] = '0' + @as(u8, @intCast(size % 8));
    }
    out[156] = kind;
    @memcpy(out[257..265], "ustar\x0000");
    testTarChecksum(out[0..512]);
    @memcpy(out[512..][0..body.len], body);
}

fn testTarChecksum(header: []u8) void {
    var sum: u64 = 8 * ' ';
    for (header[0..148]) |byte| sum += byte;
    for (header[156..512]) |byte| sum += byte;
    var index: usize = 154;
    @memset(header[148..154], '0');
    while (sum != 0) : (sum /= 8) {
        index -= 1;
        header[index] = '0' + @as(u8, @intCast(sum % 8));
    }
    header[154] = 0;
    header[155] = ' ';
}

test "bundle v1 validates the manifest, payload and complete archive before publish" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const limits: BundleLimits = .{ .entries = 4, .archive_bytes = 4096, .unpacked_bytes = 1024, .depth = 3, .path_bytes = 100 };
    const payload = "return 0\n";
    var hash: [32]u8 = undefined;
    Sha256.hash(payload, &hash, .{});
    const json = try std.fmt.allocPrint(allocator,
        \\{{"format_version":1,"execution_format":"scripted_lua","execution_format_version":1,"runner_api_version":1,"files":[{{"path":"runner.lua","size":{d},"sha256":"{s}"}}]}}
    , .{ payload.len, std.fmt.bytesToHex(hash, .lower) });
    defer allocator.free(json);
    for (0..12) |scenario| {
        var archive: [3073]u8 = @splat(0);
        testTarEntry(archive[0..1024], "manifest.json", '0', json);
        testTarEntry(archive[1024..2048], if (scenario == 6) "other.lua" else "runner.lua", if (scenario == 3) '2' else '0', payload);
        if (scenario == 2) archive[1536] = 'X';
        if (scenario == 4) archive[2048] = 1;
        if (scenario == 5) archive[0] = 'X';
        if (scenario == 7) archive[1536 + payload.len] = 1;
        if (scenario == 9) {
            archive[1024 + 500] = 1;
            testTarChecksum(archive[1024..1536]);
        }
        if (scenario == 10) {
            archive[1024 + 124] = 0x80;
            testTarChecksum(archive[1024..1536]);
        }
        if (scenario == 11) {
            archive[1024 + 12] = 'x'; // Nonzero data after the name's NUL.
            testTarChecksum(archive[1024..1536]);
        }
        Sha256.hash(archive[0..3072], &hash, .{});
        if (scenario == 1) hash[0] ^= 1;
        var reader = std.Io.Reader.fixed(archive[0..if (scenario == 8) @as(usize, 3073) else 3072]);
        var temp = std.testing.tmpDir(.{ .iterate = true });
        defer temp.cleanup();
        const result = materializeTar(io, temp.dir, "workspace", allocator, limits, &reader, 3072, hash, "scripted_lua", 1);
        if (scenario == 0) {
            try result;
            try std.testing.expectEqual(@as(u64, payload.len), (try temp.dir.statFile(io, "workspace/runner.lua", .{})).size);
            continue;
        }
        const errors = [_]anyerror{ error.BundleArchiveDigestMismatch, error.BundleFileDigestMismatch, error.UnsupportedArchiveEntry, error.InvalidTarTerminator, error.InvalidTarChecksum, error.BundleFileDescriptorMismatch, error.InvalidTarPadding, error.TrailingArchiveData, error.InvalidTarHeader, error.InvalidTarHeader, error.InvalidTarHeader };
        try std.testing.expectError(errors[scenario - 1], result);
        var entries = temp.dir.iterate();
        try std.testing.expect((try entries.next(io)) == null);
    }
}

test "submission digest and size are checked before workspace publication" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const limits: BundleLimits = .{ .entries = 4, .archive_bytes = 2048, .unpacked_bytes = 256, .depth = 2, .path_bytes = 100 };
    var archive: [2048]u8 = @splat(0);
    testTarEntry(archive[0..1024], manifest_name, '0', "{\"format_version\":1,\"execution_format\":\"standard\",\"execution_format_version\":1,\"files\":[]}");
    var archive_hash: [32]u8 = undefined;
    var source_hash: [32]u8 = undefined;
    Sha256.hash(&archive, &archive_hash, .{});
    Sha256.hash("source", &source_hash, .{});
    const cases = [_]struct { data: []const u8, failure: anyerror }{
        .{ .data = "forged", .failure = error.SourceDigestMismatch },
        .{ .data = "source!", .failure = error.TrailingSourceData },
        .{ .data = "short", .failure = error.TruncatedArchiveEntry },
    };
    for (cases) |case| {
        var reader = std.Io.Reader.fixed(&archive);
        var source = std.Io.Reader.fixed(case.data);
        var temp = std.testing.tmpDir(.{ .iterate = true });
        defer temp.cleanup();
        try std.testing.expectError(case.failure, materializeInputs(io, temp.dir, "workspace", allocator, limits, &reader, archive.len, archive_hash, "standard", 1, .{ .reader = &source, .bytes = 6, .sha256 = source_hash }));
        var entries = temp.dir.iterate();
        try std.testing.expect((try entries.next(io)) == null);
    }
}

test "bundle v1 rejects ambiguous manifests and mismatched job metadata" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const limits: BundleLimits = .{ .entries = 4, .archive_bytes = 4096, .unpacked_bytes = 1024, .depth = 3, .path_bytes = 100 };
    const cases = [_]struct { json: []const u8, expected_format: []const u8 = "standard", failure: anyerror }{
        .{ .json = "{\"format_version\":1,\"format_version\":1,\"execution_format\":\"standard\",\"execution_format_version\":1,\"files\":[]}", .failure = error.DuplicateField },
        .{ .json = "{\"format_version\":1,\"execution_format\":\"standard\",\"execution_format_version\":1,\"files\":[],\"required_features\":[\"example\"]}", .failure = error.UnknownField },
        .{ .json = "{\"format_version\":1,\"execution_format\":\"standard\",\"execution_format_version\":1,\"files\":[]}", .expected_format = "scripted_lua", .failure = error.UnsupportedBundleVersion },
        .{ .json = "{\"format_version\":1,\"execution_format\":\"scripted_lua\",\"execution_format_version\":1,\"files\":[]}", .expected_format = "scripted_lua", .failure = error.UnsupportedRunnerApiVersion },
        .{ .json = "{\"format_version\":1,\"execution_format\":\"scripted_lua\",\"execution_format_version\":1,\"runner_api_version\":2,\"files\":[]}", .expected_format = "scripted_lua", .failure = error.UnsupportedRunnerApiVersion },
        .{ .json = "{\"format_version\":1,\"execution_format\":\"scripted_lua\",\"execution_format_version\":1,\"runner_api_version\":1,\"files\":[]}", .expected_format = "scripted_lua", .failure = error.MissingBundleRunner },
        .{ .json = "{\"format_version\":1,\"execution_format\":\"standard\",\"execution_format_version\":1,\"runner_api_version\":1,\"files\":[]}", .failure = error.UnexpectedRunnerApiVersion },
        .{ .json = "{\"format_version\":1,\"execution_format\":\"standard\",\"execution_format_version\":1,\"runner_api_version\":null,\"files\":[]}", .failure = error.UnexpectedToken },
        .{ .json = "{\"format_version\":1,\"execution_format\":\"scripted_lua\",\"execution_format_version\":1,\"runner_api_version\":\"1\",\"files\":[]}", .expected_format = "scripted_lua", .failure = error.UnexpectedToken },
        .{ .json = "{\"format_version\":1,\"execution_format\":\"scripted_lua\",\"execution_format_version\":1,\"runner_api_version\":1.0,\"files\":[]}", .expected_format = "scripted_lua", .failure = error.InvalidNumber },
        .{ .json = "{\"format_version\":2,\"execution_format\":\"standard\",\"execution_format_version\":1,\"files\":[]}", .failure = error.UnsupportedBundleVersion },
        .{ .json = "{\"format_version\":1,\"execution_format\":\"standard\",\"execution_format_version\":1,\"files\":[{\"path\":\"solution/main.c\",\"size\":0,\"sha256\":\"\"}]}", .failure = error.InvalidArchivePath },
        .{ .json = "{\"format_version\":1,\"execution_format\":\"standard\",\"execution_format_version\":1,\"files\":[{\"path\":\"../outside\",\"size\":0,\"sha256\":\"\"}]}", .failure = error.InvalidArchivePath },
    };
    for (cases) |case| {
        var archive: [2048]u8 = @splat(0);
        testTarEntry(archive[0..1024], manifest_name, '0', case.json);
        var hash: [32]u8 = undefined;
        Sha256.hash(&archive, &hash, .{});
        var reader = std.Io.Reader.fixed(&archive);
        var temp = std.testing.tmpDir(.{ .iterate = true });
        defer temp.cleanup();
        try std.testing.expectError(case.failure, materializeTar(io, temp.dir, "workspace", allocator, limits, &reader, archive.len, hash, case.expected_format, 1));
        var entries = temp.dir.iterate();
        try std.testing.expect((try entries.next(io)) == null);
    }
}

/// Run during recovery in a private workspace parent dedicated to this API.
/// Uses the same lock as materialize.
pub fn cleanInterrupted(io: std.Io, workspace_parent: std.Io.Dir) !usize {
    const parent = try lockParent(io, workspace_parent);
    defer parent.close(io);
    var iter = parent.iterate();
    var removed: usize = 0;
    errdefer if (removed != 0) syncDir(parent) catch {};
    while (try iter.next(io)) |entry| {
        if (!isStagingName(entry.name)) continue;
        if (entry.kind != .directory) return error.UnsafeStagingEntry;
        try parent.deleteTree(io, entry.name);
        removed += 1;
    }
    if (removed != 0) try syncDir(parent);
    return removed;
}

fn isStagingName(name: []const u8) bool {
    if (name.len != staging_prefix.len + 32 or !std.mem.startsWith(u8, name, staging_prefix)) return false;
    for (name[staging_prefix.len..]) |byte| switch (byte) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

fn lockParent(io: std.Io, directory: std.Io.Dir) !std.Io.Dir {
    // Reopen to get an independent open file description for flock.
    const parent = try directory.openDir(io, ".", .{ .iterate = true });
    errdefer parent.close(io);
    while (true) switch (linux.errno(linux.flock(parent.handle, std.posix.LOCK.EX | std.posix.LOCK.NB))) {
        .SUCCESS => return parent,
        .INTR => continue,
        .AGAIN => return error.WorkspaceBusy,
        else => return error.WorkspaceLockFailed,
    };
}

/// The parent must be private, stable, and opened with iteration enabled.
/// The source returns success only after validating the entire archive.
pub fn materialize(io: std.Io, workspace_parent: std.Io.Dir, name: []const u8, allocator: std.mem.Allocator, limits: Limits, source: anytype) !void {
    try validatePath(name, .{ .entries = 1, .bytes = 0, .depth = 1, .path_bytes = 255 });
    if (std.mem.startsWith(u8, name, staging_prefix)) return error.ReservedWorkspaceName;
    const parent = try lockParent(io, workspace_parent);
    defer parent.close(io);
    var nonce: [16]u8 = undefined;
    try io.randomSecure(&nonce);
    const stage_id = std.fmt.bytesToHex(nonce, .lower);
    const staging = staging_prefix ++ stage_id;
    try parent.createDir(io, staging, .fromMode(0o700));
    var published = false;
    errdefer if (!published) {
        const previous = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(previous);
        parent.deleteTree(io, staging) catch {};
        syncDir(parent) catch {};
    };
    const root = try parent.openDir(io, staging, .{ .follow_symlinks = false, .iterate = true });
    defer root.close(io);
    var writer = Writer.init(io, root, allocator, limits);
    defer writer.deinit();
    try source.readEntries(&writer);
    try writer.finish();
    try io.checkCancel();
    const previous = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(previous);
    try parent.renamePreserve(staging, parent, name, io);
    published = true;
    syncDir(parent) catch return error.WorkspacePublicationUncertain;
}

/// The caller owns a fresh private staging tree and keeps it inaccessible to
/// workloads until finish succeeds. On any error, discard the entire tree.
/// The parser must classify entries faithfully and verify the archive terminator
/// before calling finish. Archive permissions and ownership are never applied.
pub const Writer = struct {
    io: std.Io,
    root: std.Io.Dir,
    allocator: std.mem.Allocator,
    limits: Limits,
    nodes: std.StringHashMapUnmanaged(Node) = .empty,
    bytes: u64 = 0,
    state: enum { active, failed, finished } = .active,

    fn init(io: std.Io, root: std.Io.Dir, allocator: std.mem.Allocator, limits: Limits) Writer {
        return .{ .io = io, .root = root, .allocator = allocator, .limits = limits };
    }

    fn deinit(self: *Writer) void {
        var keys = self.nodes.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        self.nodes.deinit(self.allocator);
    }

    /// For a regular file, reads exactly size bytes from the entry payload.
    /// The parser owns framing, padding and input decompression.
    pub fn add(self: *Writer, entry: Entry, payload: ?*std.Io.Reader) !void {
        try self.addHashed(entry, payload, null);
    }

    fn addHashed(self: *Writer, entry: Entry, payload: ?*std.Io.Reader, hashes: ?PayloadHashes) !void {
        if (self.state != .active) return error.ExtractionClosed;
        errdefer self.state = .failed;
        try validatePath(entry.path, self.limits);
        switch (entry.kind) {
            .directory => if (entry.size != 0 or payload != null) return error.InvalidDirectoryEntry,
            .regular => if (payload == null) return error.MissingEntryPayload,
            else => return error.UnsupportedArchiveEntry,
        }
        if (entry.size > self.limits.bytes - self.bytes) return error.ArchiveByteLimit;

        var parent = self.root;
        var own_parent = false;
        defer if (own_parent) parent.close(self.io);
        var components = std.mem.splitScalar(u8, entry.path, '/');
        var prefix_len: usize = 0;
        while (components.next()) |component| {
            prefix_len += component.len;
            const prefix = entry.path[0..prefix_len];
            const last = prefix_len == entry.path.len;
            if (last and entry.kind == .regular) {
                if (self.nodes.contains(prefix)) return error.ArchivePathCollision;
                try self.record(prefix, .file);
                const file = try parent.createFile(self.io, component, .{ .exclusive = true, .permissions = .fromMode(0o600) });
                defer file.close(self.io);
                try copyBody(self.io, file, payload.?, entry.size, hashes);
                try file.sync(self.io);
                try syncDir(parent);
                self.bytes += entry.size;
                return;
            }

            if (self.nodes.getPtr(prefix)) |node| {
                if (node.* == .file or (last and node.* == .explicit_dir)) return error.ArchivePathCollision;
                if (last) node.* = .explicit_dir;
            } else {
                try self.record(prefix, if (last) .explicit_dir else .implicit_dir);
                try parent.createDir(self.io, component, .fromMode(0o700));
                try syncDir(parent);
            }
            if (last) return;
            // Each fd lookup uses a single validated name and refuses symlinks.
            const child = try parent.openDir(self.io, component, .{ .follow_symlinks = false, .iterate = true });
            if (own_parent) parent.close(self.io);
            parent = child;
            own_parent = true;
            prefix_len += 1;
        }
    }

    fn finish(self: *Writer) !void {
        if (self.state != .active) return error.ExtractionClosed;
        errdefer self.state = .failed;
        try syncDir(self.root);
        self.state = .finished;
    }

    fn record(self: *Writer, path: []const u8, node: Node) !void {
        if (self.nodes.count() >= self.limits.entries) return error.ArchiveEntryLimit;
        const owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned);
        try self.nodes.putNoClobber(self.allocator, owned, node);
    }
};

fn validatePath(path: []const u8, limits: Limits) !void {
    if (path.len == 0 or path.len > limits.path_bytes or path.len >= std.os.linux.PATH_MAX or
        std.mem.indexOfAny(u8, path, "\\\x00") != null) return error.InvalidArchivePath;
    var parts = std.mem.splitScalar(u8, path, '/');
    var depth: usize = 0;
    while (parts.next()) |part| {
        depth += 1;
        if (depth > limits.depth or part.len == 0 or part.len > 255 or
            std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidArchivePath;
    }
}

fn readPayload(payload: *std.Io.Reader, chunk: []u8) !void {
    payload.readSliceAll(chunk) catch |err| switch (err) {
        error.EndOfStream => return error.TruncatedArchiveEntry,
        else => return err,
    };
}

fn copyBody(io: std.Io, file: std.Io.File, payload: *std.Io.Reader, size: u64, hashes: ?PayloadHashes) !void {
    var remaining = size;
    var buffer: [32 * 1024]u8 = undefined;
    while (remaining > 0) {
        const chunk = buffer[0..@intCast(@min(remaining, buffer.len))];
        try readPayload(payload, chunk);
        if (hashes) |pair| {
            if (pair.archive) |hash| hash.update(chunk);
            pair.file.update(chunk);
        }
        try file.writeStreamingAll(io, chunk);
        remaining -= chunk.len;
    }
}

fn syncDir(dir: std.Io.Dir) !void {
    while (true) switch (linux.errno(linux.fsync(dir.handle))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return error.WorkspaceSyncFailed,
    };
}

const test_limits: Limits = .{ .entries = 3, .bytes = 4, .depth = 3, .path_bytes = 64 };

test "stream a file through implicit parents and accept a later directory header" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    var writer = Writer.init(io, temp.dir, std.testing.allocator, test_limits);
    defer writer.deinit();
    var body = std.Io.Reader.fixed("dataTAIL");
    try writer.add(.{ .path = "a/b/file", .kind = .regular, .size = 4 }, &body);
    try writer.add(.{ .path = "a/b", .kind = .directory }, null);
    try writer.finish();
    try std.testing.expectEqualStrings("TAIL", body.buffered());
    const file = try temp.dir.openFile(io, "a/b/file", .{});
    defer file.close(io);
    var contents: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try file.readPositionalAll(io, &contents, 0));
    try std.testing.expectEqualStrings("data", &contents);
    try std.testing.expectEqual(@as(u16, 0o600), (try file.stat(io)).permissions.toMode() & 0o777);
}

test "reject invalid archive entries and prevent finishing a failed tree" {
    const io = std.testing.io;
    const cases = [_]struct { entry: Entry, failure: anyerror }{
        .{ .entry = .{ .path = "../escape", .kind = .regular }, .failure = error.InvalidArchivePath },
        .{ .entry = .{ .path = "/absolute", .kind = .regular }, .failure = error.InvalidArchivePath },
        .{ .entry = .{ .path = "a//b", .kind = .regular }, .failure = error.InvalidArchivePath },
        .{ .entry = .{ .path = "a/b/c/d", .kind = .regular }, .failure = error.InvalidArchivePath },
        .{ .entry = .{ .path = "a\\b", .kind = .regular }, .failure = error.InvalidArchivePath },
        .{ .entry = .{ .path = "a\x00b", .kind = .regular }, .failure = error.InvalidArchivePath },
        .{ .entry = .{ .path = "link", .kind = .symlink }, .failure = error.UnsupportedArchiveEntry },
        .{ .entry = .{ .path = "link", .kind = .hardlink }, .failure = error.UnsupportedArchiveEntry },
        .{ .entry = .{ .path = "device", .kind = .special }, .failure = error.UnsupportedArchiveEntry },
        .{ .entry = .{ .path = "large", .kind = .regular, .size = 5 }, .failure = error.ArchiveByteLimit },
        .{ .entry = .{ .path = "truncated", .kind = .regular, .size = 2 }, .failure = error.TruncatedArchiveEntry },
    };
    for (cases) |case| {
        var temp = std.testing.tmpDir(.{ .iterate = true });
        defer temp.cleanup();
        var writer = Writer.init(io, temp.dir, std.testing.allocator, test_limits);
        defer writer.deinit();
        var body = std.Io.Reader.fixed("x");
        try std.testing.expectError(case.failure, writer.add(case.entry, &body));
        try std.testing.expectError(error.ExtractionClosed, writer.finish());
    }
}

test "count implicit directories, reject collisions and refuse a preexisting symlink" {
    const io = std.testing.io;
    for (0..4) |scenario| {
        var temp = std.testing.tmpDir(.{ .iterate = true });
        defer temp.cleanup();
        var writer = Writer.init(io, temp.dir, std.testing.allocator, test_limits);
        defer writer.deinit();
        var body = std.Io.Reader.fixed("");
        switch (scenario) {
            0 => {
                try writer.add(.{ .path = "a/b/c", .kind = .regular }, &body);
                try std.testing.expectError(error.ArchiveEntryLimit, writer.add(.{ .path = "extra", .kind = .directory }, null));
            },
            1 => {
                try writer.add(.{ .path = "a", .kind = .regular }, &body);
                try std.testing.expectError(error.ArchivePathCollision, writer.add(.{ .path = "a/b", .kind = .regular }, &body));
            },
            2 => {
                try writer.add(.{ .path = "a", .kind = .regular }, &body);
                try std.testing.expectError(error.ArchivePathCollision, writer.add(.{ .path = "a", .kind = .regular }, &body));
            },
            else => {
                try temp.dir.symLink(io, "..", "link", .{ .is_directory = true });
                try std.testing.expectError(error.PathAlreadyExists, writer.add(.{ .path = "link/escape", .kind = .regular }, &body));
            },
        }
        try std.testing.expectError(error.ExtractionClosed, writer.finish());
    }
}

test "publish only complete trees and preserve an existing destination" {
    const Source = struct {
        parent: std.Io.Dir,
        fail: bool = false,
        pub fn readEntries(self: @This(), writer: *Writer) !void {
            var body = std.Io.Reader.fixed("data");
            try writer.add(.{ .path = "sub/file", .kind = .regular, .size = 4 }, &body);
            try std.testing.expectError(error.WorkspaceBusy, cleanInterrupted(writer.io, self.parent));
            if (self.fail) return error.InvalidArchiveTerminator;
        }
    };
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try std.testing.expectError(error.InvalidArchiveTerminator, materialize(io, temp.dir, "workspace", allocator, test_limits, Source{ .parent = temp.dir, .fail = true }));
    var empty = temp.dir.iterate();
    try std.testing.expect((try empty.next(io)) == null);
    const source: Source = .{ .parent = temp.dir };
    try materialize(io, temp.dir, "workspace", allocator, test_limits, source);
    try std.testing.expectError(error.PathAlreadyExists, materialize(io, temp.dir, "workspace", allocator, test_limits, source));
    var entries = temp.dir.iterate();
    try std.testing.expectEqualStrings("workspace", (try entries.next(io)).?.name);
    try std.testing.expect((try entries.next(io)) == null);
    try std.testing.expectEqual(@as(u64, 4), (try temp.dir.statFile(io, "workspace/sub/file", .{})).size);
}

test "recovery shares the writer lock and only removes staging directories" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const stage = ".extract-0123456789abcdef0123456789abcdef";
    try temp.dir.createDirPath(io, stage ++ "/partial/sub");
    try temp.dir.writeFile(io, .{ .sub_path = stage ++ "/partial/sub/file", .data = "incomplete" });
    try temp.dir.createDir(io, ".extract-fedcba9876543210fedcba9876543210", .fromMode(0o700));
    try temp.dir.createDir(io, "workspace", .fromMode(0o700));
    try temp.dir.createDir(io, ".extract-not-a-staging-id", .fromMode(0o700));
    {
        const locked = try lockParent(io, temp.dir);
        defer locked.close(io);
        try std.testing.expectError(error.WorkspaceBusy, cleanInterrupted(io, temp.dir));
    }
    try std.testing.expectEqual(@as(usize, 2), try cleanInterrupted(io, temp.dir));
    try std.testing.expectEqual(@as(usize, 0), try cleanInterrupted(io, temp.dir));
    _ = try temp.dir.statFile(io, "workspace", .{});
    _ = try temp.dir.statFile(io, ".extract-not-a-staging-id", .{});
    try temp.dir.symLink(io, "workspace", stage, .{ .is_directory = true });
    try std.testing.expectError(error.UnsafeStagingEntry, cleanInterrupted(io, temp.dir));
    _ = try temp.dir.statFile(io, "workspace", .{});
}
