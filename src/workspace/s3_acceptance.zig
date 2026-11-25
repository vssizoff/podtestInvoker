//! Opt-in integration client. Signed URLs are read from stdin, not argv.
const std = @import("std");
const download = @import("download.zig");
const inputs = @import("inputs.zig");
const spool = @import("spool.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 10) return error.InvalidArguments;
    var descriptor: download.Descriptor = .{ .bytes = try std.fmt.parseInt(u64, args[6], 10), .sha256 = undefined };
    if (args[7].len != 64) return error.InvalidDigest;
    _ = try std.fmt.hexToBytes(&descriptor.sha256, args[7]);
    var input_buffer: [4096]u8 = undefined;
    var input = std.Io.File.stdin().readerStreaming(io, &input_buffer);
    const urls = try input.interface.allocRemaining(allocator, .limited(32770));
    const separator = std.mem.indexOfScalar(u8, urls, '\n') orelse return error.InvalidSignedUrls;
    const url = try allocator.dupeSentinel(u8, urls[0..separator], 0);
    const source_url = try allocator.dupeSentinel(u8, std.mem.trimEnd(u8, urls[separator + 1 ..], "\r\n"), 0);
    if (url.len == 0) return error.InvalidSignedUrls;
    const options: download.Options = .{ .origin = args[2], .ca_file = args[3], .timeout_ms = 5000, .byte_budget = 8192 };
    const limits: spool.Limits = .{ .bytes = 8192, .files = 2 };
    try download.init();
    defer download.deinit();

    if (std.mem.eql(u8, args[1], "put")) {
        var body = std.Io.Reader.fixed("integration artifact\n");
        const staged = try spool.stage(io, args[4], limits, "payload", descriptor.bytes, &body);
        if (!std.mem.eql(u8, &staged.sha256, &descriptor.sha256)) return error.InvalidDigest;
        return spool.put(io, args[4], "payload", url, descriptor, options);
    }
    if (!std.mem.eql(u8, args[1], "bundle")) return error.InvalidArguments;
    if (source_url.len == 0) return error.InvalidSignedUrls;
    var source_descriptor: download.Descriptor = .{ .bytes = try std.fmt.parseInt(u64, args[8], 10), .sha256 = undefined };
    if (args[9].len != 64) return error.InvalidSourceDigest;
    _ = try std.fmt.hexToBytes(&source_descriptor.sha256, args[9]);
    const parent = try std.Io.Dir.openDirAbsolute(io, args[5], .{ .iterate = true, .follow_symlinks = false });
    defer parent.close(io);
    try inputs.prepare(io, allocator, args[4], limits, parent, "workspace", .{
        .entries = 8,
        .archive_bytes = 8192,
        .unpacked_bytes = 4096,
        .depth = 4,
        .path_bytes = 256,
    }, "scripted_lua", 1, .{
        .bundle = .{ .descriptor = descriptor, .url = url },
        .source = .{ .descriptor = source_descriptor, .url = source_url },
    }, options);
}
