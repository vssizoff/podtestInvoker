const std = @import("std");
const download = @import("download.zig");
const extract = @import("extract.zig");
const spool = @import("spool.zig");

pub const Artifact = struct { url: [:0]const u8, descriptor: download.Descriptor };
pub const ClaimInputs = struct {
    bundle: Artifact,
    source: Artifact,

    /// Refresh can change the URLs, never the inputs locked in by Claim.
    pub fn withRefreshedUrls(self: ClaimInputs, refreshed: ClaimInputs) !ClaimInputs {
        if (!std.meta.eql(self.bundle.descriptor, refreshed.bundle.descriptor) or
            !std.meta.eql(self.source.descriptor, refreshed.source.descriptor))
            return error.PinnedInputsChanged;
        return refreshed;
    }
};

/// Uses a private, per-run spool. The caller owns cleanup and lease checking
/// and must not expose the workspace to a workload until this succeeds.
pub fn prepare(io: std.Io, allocator: std.mem.Allocator, spool_path: []const u8, spool_limits: spool.Limits, parent: std.Io.Dir, workspace_name: []const u8, limits: extract.BundleLimits, expected_format: []const u8, expected_version: u32, inputs: ClaimInputs, options: download.Options) !void {
    if (inputs.bundle.descriptor.bytes > limits.archive_bytes or inputs.source.descriptor.bytes > limits.unpacked_bytes)
        return error.ArchiveByteLimit;
    const bytes = std.math.add(u64, inputs.bundle.descriptor.bytes, inputs.source.descriptor.bytes) catch return error.SpoolByteLimit;
    if (bytes > spool_limits.bytes) return error.SpoolByteLimit;
    if (spool_limits.files < 2) return error.SpoolFileLimit;

    try spool.get(io, spool_path, spool_limits, "bundle.tar", inputs.bundle.url, inputs.bundle.descriptor, options);
    errdefer spool.remove(io, spool_path, "bundle.tar") catch {};
    try spool.get(io, spool_path, spool_limits, "source.bin", inputs.source.url, inputs.source.descriptor, options);
    errdefer spool.remove(io, spool_path, "source.bin") catch {};
    const dir = try spool.openLocked(io, spool_path);
    defer dir.close(io);
    const bundle = try dir.openFile(io, "bundle.tar", .{ .follow_symlinks = false });
    defer bundle.close(io);
    const source = try dir.openFile(io, "source.bin", .{ .follow_symlinks = false });
    defer source.close(io);
    var bundle_buffer: [4096]u8 = undefined;
    var source_buffer: [4096]u8 = undefined;
    var bundle_reader = bundle.reader(io, &bundle_buffer);
    var source_reader = source.reader(io, &source_buffer);
    try extract.materializeInputs(io, parent, workspace_name, allocator, limits, &bundle_reader.interface, inputs.bundle.descriptor.bytes, inputs.bundle.descriptor.sha256, expected_format, expected_version, .{
        .reader = &source_reader.interface,
        .bytes = inputs.source.descriptor.bytes,
        .sha256 = inputs.source.descriptor.sha256,
    });
}

test "refresh accepts new URLs and rejects changed pinned descriptors" {
    const pinned: ClaimInputs = .{
        .bundle = .{ .url = "https://example.invalid/bundle?old", .descriptor = .{ .bytes = 2048, .sha256 = @splat(1) } },
        .source = .{ .url = "https://example.invalid/source?old", .descriptor = .{ .bytes = 128, .sha256 = @splat(2) } },
    };
    var refreshed = pinned;
    refreshed.source.url = "https://example.invalid/source?new";
    try std.testing.expectEqualStrings(refreshed.source.url, (try pinned.withRefreshedUrls(refreshed)).source.url);
    refreshed.source.descriptor.sha256[0] ^= 1;
    try std.testing.expectError(error.PinnedInputsChanged, pinned.withRefreshedUrls(refreshed));
    refreshed = pinned;
    refreshed.bundle.descriptor.bytes += 512;
    try std.testing.expectError(error.PinnedInputsChanged, pinned.withRefreshedUrls(refreshed));
}

test {
    _ = std.testing.refAllDecls(extract);
}
