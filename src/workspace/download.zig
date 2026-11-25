const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Descriptor = struct { bytes: u64, sha256: [Sha256.digest_length]u8 };
pub const Options = struct {
    origin: [:0]const u8,
    ca_file: ?[:0]const u8 = null,
    timeout_ms: u32,
    /// Caller reserves these bytes in the workspace before calling get.
    byte_budget: u64,
    cancelled: ?*const std.atomic.Value(bool) = null,
};

extern fn curl_global_init(c_long) c_int;
extern fn curl_global_cleanup() void;
extern fn podtest_artifact_get([*:0]const u8, [*:0]const u8, ?[*:0]const u8, c_long, *const fn ([*]const u8, usize, *Sink) callconv(.c) usize, *const fn (*Sink) callconv(.c) c_int, *Sink) c_int;
extern fn podtest_artifact_put([*:0]const u8, [*:0]const u8, ?[*:0]const u8, c_long, i64, *const fn ([*]u8, usize, *UploadSource) callconv(.c) usize, *const fn (*UploadSource) callconv(.c) c_int, *UploadSource, [*:0]const u8) c_int;

/// Call once, before starting transfer threads; deinit after they have stopped.
pub fn init() !void {
    if (curl_global_init(3) != 0) return error.ArtifactTransportSetup;
}

pub fn deinit() void {
    curl_global_cleanup();
}

pub fn validateName(name: []const u8) !void {
    if (name.len == 0 or name.len > 255 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or
        std.mem.indexOfAny(u8, name, "/\\\x00") != null) return error.InvalidArtifactName;
}

/// dir is a private, trusted staging directory opened with iteration enabled
/// (so its fd supports fsync). No runtime workload may have access to it.
pub fn get(io: std.Io, dir: std.Io.Dir, name: []const u8, url: [:0]const u8, descriptor: Descriptor, options: Options) !void {
    try validateName(name);
    if (descriptor.bytes > options.byte_budget) return error.ArtifactBudgetExceeded;
    if (options.timeout_ms == 0 or url.len == 0 or url.len > 16384 or options.origin.len == 0 or options.origin.len > 2048 or
        std.mem.indexOfScalar(u8, url, 0) != null or std.mem.indexOfScalar(u8, options.origin, 0) != null) return error.InvalidArtifactRequest;
    if (options.cancelled) |flag| if (flag.load(.acquire)) return error.ArtifactCancelled;

    var staging = try dir.createFileAtomic(io, name, .{ .permissions = .fromMode(0o600) });
    defer staging.deinit(io);
    var sink: Sink = .{ .io = io, .file = staging.file, .remaining = descriptor.bytes, .cancelled = options.cancelled };
    const result = podtest_artifact_get(url.ptr, options.origin.ptr, if (options.ca_file) |path| path.ptr else null, options.timeout_ms, Sink.write, Sink.isCancelled, &sink);
    if (sink.failure) |failure| return failure;
    switch (result) {
        0 => {},
        2 => return error.ArtifactUrlRejected,
        3 => return error.ArtifactTlsFailure,
        4 => return error.ArtifactTimeout,
        5 => return error.ArtifactTransientFailure,
        6 => return error.ArtifactHttpRejected,
        7 => return error.ArtifactCancelled,
        else => return error.ArtifactTransportSetup,
    }
    if (sink.remaining != 0) return error.ArtifactSizeMismatch;
    var digest: [Sha256.digest_length]u8 = undefined;
    sink.hash.final(&digest);
    if (!std.mem.eql(u8, &digest, &descriptor.sha256)) return error.ArtifactDigestMismatch;
    try staging.file.sync(io);
    if (sink.isCancelled() != 0) return error.ArtifactCancelled;
    try staging.link(io);
    const linux = std.os.linux;
    while (true) switch (linux.errno(linux.fsync(dir.handle))) {
        .SUCCESS => return,
        .INTR => continue,
        // The complete verified object may already be visible. Do not retry
        // blindly if publication durability is uncertain.
        else => return error.ArtifactPublicationUncertain,
    };
}

/// Uploads a private spool object only after rechecking its size and digest.
/// The signed target must share the configured HTTPS origin.
pub fn put(io: std.Io, file: std.Io.File, url: [:0]const u8, descriptor: Descriptor, options: Options) !void {
    if (descriptor.bytes > options.byte_budget) return error.ArtifactBudgetExceeded;
    if (descriptor.bytes > std.math.maxInt(i64) or options.timeout_ms == 0 or url.len == 0 or url.len > 16384 or
        std.mem.indexOfScalar(u8, url, 0) != null or options.origin.len == 0 or options.origin.len > 2048 or
        std.mem.indexOfScalar(u8, options.origin, 0) != null) return error.InvalidArtifactRequest;
    var source: UploadSource = .{ .fd = file.handle, .remaining = descriptor.bytes, .cancelled = options.cancelled };
    if (source.isCancelled() != 0) return error.ArtifactCancelled;
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size != descriptor.bytes) return error.ArtifactSizeMismatch;
    var hash = Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < descriptor.bytes) {
        if (source.isCancelled() != 0) return error.ArtifactCancelled;
        const n = @min(buffer.len, descriptor.bytes - offset);
        const got = try file.readPositional(io, &.{buffer[0..n]}, offset);
        if (got == 0) return error.ArtifactSizeMismatch;
        hash.update(buffer[0..got]);
        offset += got;
    }
    var digest: [Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    if (!std.mem.eql(u8, &digest, &descriptor.sha256)) return error.ArtifactDigestMismatch;
    var checksum_bytes: [44]u8 = undefined;
    const checksum_text = std.base64.standard.Encoder.encode(&checksum_bytes, &descriptor.sha256);
    var header_buffer: ["x-amz-checksum-sha256: ".len + 44 + 1]u8 = undefined;
    const header = try std.fmt.bufPrintSentinel(&header_buffer, "x-amz-checksum-sha256: {s}", .{checksum_text}, 0);
    if (source.isCancelled() != 0) return error.ArtifactCancelled;
    const result = podtest_artifact_put(url.ptr, options.origin.ptr, if (options.ca_file) |path| path.ptr else null, options.timeout_ms, @intCast(descriptor.bytes), UploadSource.read, UploadSource.isCancelled, &source, header.ptr);
    if (source.failure) |failure| return failure;
    switch (result) {
        0 => if (source.remaining != 0) return error.ArtifactSizeMismatch,
        2 => return error.ArtifactUrlRejected,
        3 => return error.ArtifactTlsFailure,
        4 => return error.ArtifactTimeout,
        5 => return error.ArtifactTransientFailure,
        6 => return error.ArtifactHttpRejected,
        7 => return error.ArtifactCancelled,
        else => return error.ArtifactTransportSetup,
    }
}

const UploadSource = struct {
    fd: std.posix.fd_t,
    remaining: u64,
    offset: u64 = 0,
    cancelled: ?*const std.atomic.Value(bool),
    failure: ?anyerror = null,

    fn read(data: [*]u8, capacity: usize, self: *UploadSource) callconv(.c) usize {
        if (self.isCancelled() != 0) {
            self.failure = error.ArtifactCancelled;
            return std.math.maxInt(usize);
        }
        if (self.remaining == 0) return 0;
        const n = @min(capacity, self.remaining);
        while (true) {
            const got = std.os.linux.pread(@intCast(self.fd), data, n, @intCast(self.offset));
            switch (std.os.linux.errno(got)) {
                .SUCCESS => {
                    if (got == 0) {
                        self.failure = error.ArtifactSizeMismatch;
                        return std.math.maxInt(usize);
                    }
                    self.offset += got;
                    self.remaining -= got;
                    return @intCast(got);
                },
                .INTR => continue,
                else => {
                    self.failure = error.ArtifactReadFailed;
                    return std.math.maxInt(usize);
                },
            }
        }
    }

    fn isCancelled(self: *UploadSource) callconv(.c) c_int {
        return if (self.cancelled) |flag| @intFromBool(flag.load(.acquire)) else 0;
    }
};

const Sink = struct {
    io: std.Io,
    file: std.Io.File,
    remaining: u64,
    hash: Sha256 = Sha256.init(.{}),
    cancelled: ?*const std.atomic.Value(bool),
    failure: ?anyerror = null,

    fn isCancelled(self: *Sink) callconv(.c) c_int {
        return if (self.cancelled) |flag| @intFromBool(flag.load(.acquire)) else 0;
    }

    fn write(data: [*]const u8, len: usize, self: *Sink) callconv(.c) usize {
        if (self.isCancelled() != 0) {
            self.failure = error.ArtifactCancelled;
            return 0;
        }
        if (len > self.remaining) {
            self.failure = error.ArtifactSizeMismatch;
            return 0;
        }
        const chunk = data[0..len];
        self.file.writeStreamingAll(self.io, chunk) catch |err| {
            self.failure = err;
            return 0;
        };
        self.hash.update(chunk);
        self.remaining -= len;
        return len;
    }
};

test "invalid destination and over-budget descriptors fail before opening a file" {
    const io = std.testing.io;
    const descriptor: Descriptor = .{ .bytes = 2, .sha256 = @splat(0) };
    const options: Options = .{ .origin = "https://example.invalid", .timeout_ms = 500, .byte_budget = 1 };
    for ([_][]const u8{ "", ".", "..", "a/b", "a\\b", "a\x00b" }) |name| {
        try std.testing.expectError(error.InvalidArtifactName, get(io, undefined, name, options.origin, descriptor, options));
    }
    try std.testing.expectError(error.ArtifactBudgetExceeded, get(io, undefined, "source", options.origin, descriptor, options));
}
