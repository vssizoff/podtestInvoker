const std = @import("std");
const download = @import("download.zig");
const spool = @import("spool.zig");
const extract = @import("extract.zig");

fn verifyBundle(io: std.Io, allocator: std.mem.Allocator, args: []const [:0]const u8, dir: std.Io.Dir) !void {
    var descriptor: download.Descriptor = .{ .bytes = try std.fmt.parseInt(u64, args[5], 10), .sha256 = undefined };
    if (args[6].len != 64) return error.InvalidFixtureDigest;
    _ = try std.fmt.hexToBytes(&descriptor.sha256, args[6]);
    const mode = args[7];
    const is_standard = std.mem.eql(u8, mode, "standard");
    const unsupported = std.mem.eql(u8, mode, "lua-unsupported");
    if (!is_standard and !unsupported and !std.mem.eql(u8, mode, "lua")) return error.InvalidFixtureMode;
    const url = try std.fmt.allocPrintSentinel(allocator, "{s}/bundle/{s}?signature=fixture", .{ args[1], mode }, 0);
    try spool.get(io, args[3], .{ .bytes = 8192, .files = 1 }, "bundle.tar", url, descriptor, .{
        .origin = args[1],
        .ca_file = args[2],
        .timeout_ms = 2000,
        .byte_budget = 8192,
    });
    const parent = try std.Io.Dir.openDirAbsolute(io, args[4], .{ .iterate = true, .follow_symlinks = false });
    defer parent.close(io);
    const archive = try dir.openFile(io, "bundle.tar", .{ .follow_symlinks = false });
    defer archive.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = archive.reader(io, &buffer);
    const expected_format: []const u8 = if (is_standard) "standard" else "scripted_lua";
    const result = extract.materializeTar(io, parent, "workspace", allocator, .{
        .entries = 8,
        .archive_bytes = 8192,
        .unpacked_bytes = 4096,
        .depth = 4,
        .path_bytes = 256,
    }, &reader.interface, descriptor.bytes, descriptor.sha256, expected_format, 1);
    if (unsupported) {
        try std.testing.expectError(error.UnsupportedRunnerApiVersion, result);
        var entries = parent.iterate();
        try std.testing.expect((try entries.next(io)) == null);
        return;
    }
    try result;
    const published_path = if (is_standard) "workspace/tests/abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrst/input.txt" else "workspace/runner.lua";
    const input = try parent.openFile(io, published_path, .{});
    defer input.close(io);
    var contents: [10]u8 = undefined;
    const len = try input.readPositionalAll(io, &contents, 0);
    try std.testing.expectEqualStrings(if (is_standard) "42\n" else "return 0\n", contents[0..len]);
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 4 and args.len != 5 and args.len != 8) return error.ExpectedOriginCertificateAndState;
    const dir = try std.Io.Dir.openDirAbsolute(io, args[3], .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(io);
    try download.init();
    defer download.deinit();

    if (args.len == 8) return verifyBundle(io, a, args, dir);

    const payload = "verified artifact\n";
    var descriptor: download.Descriptor = .{ .bytes = payload.len, .sha256 = undefined };
    std.crypto.hash.sha2.Sha256.hash(payload, &descriptor.sha256, .{});
    var options: download.Options = .{ .origin = args[1], .ca_file = args[2], .timeout_ms = 2000, .byte_budget = 1024 };
    const url = try std.fmt.allocPrintSentinel(a, "{s}/ok?signature=test%2Fvalue", .{args[1]}, 0);
    const limits: spool.Limits = .{ .bytes = 2 * payload.len, .files = 2 };
    if (args.len == 5) {
        if (!std.mem.eql(u8, args[4], "verify-reopen")) return error.InvalidMode;
        const upload = try std.fmt.allocPrintSentinel(a, "{s}/upload?signature=fixture", .{args[1]}, 0);
        const retry = try std.fmt.allocPrintSentinel(a, "{s}/upload-retry", .{args[1]}, 0);
        var wrong = descriptor;
        wrong.sha256[0] ^= 1;
        try std.testing.expectError(error.ArtifactDigestMismatch, spool.put(io, args[3], "artifact", upload, wrong, options));
        try std.testing.expectError(error.ArtifactUrlRejected, spool.put(io, args[3], "artifact", "https://example.invalid/upload", descriptor, options));
        try std.testing.expectError(error.ArtifactTransientFailure, spool.put(io, args[3], "artifact", retry, descriptor, options));
        try spool.put(io, args[3], "artifact", retry, descriptor, options);
        try spool.put(io, args[3], "artifact", upload, descriptor, options);
        try std.testing.expectError(error.SpoolByteLimit, spool.get(io, args[3], .{ .bytes = 2 * payload.len - 1, .files = 2 }, "second", url, descriptor, options));
        try std.testing.expectError(error.SpoolFileLimit, spool.get(io, args[3], .{ .bytes = 1024, .files = 1 }, "second", url, descriptor, options));
        {
            try dir.symLink(io, "artifact", "unexpected-link", .{});
            defer dir.deleteFile(io, "unexpected-link") catch {};
            try std.testing.expectError(error.UnsafeSpoolEntry, spool.get(io, args[3], limits, "second", url, descriptor, options));
            try std.testing.expectError(error.UnsafeSpoolEntry, spool.remove(io, args[3], "unexpected-link"));
            try std.testing.expectError(error.UnsafeSpoolEntry, spool.put(io, args[3], "unexpected-link", upload, descriptor, options));
        }
        {
            try dir.symLink(io, "..", "parent-link", .{ .is_directory = true });
            defer dir.deleteFile(io, "parent-link") catch {};
            const indirect = try std.fmt.allocPrint(a, "{s}/parent-link/{s}", .{ args[3], std.fs.path.basename(args[3]) });
            try std.testing.expectError(error.UnsafeSpoolDirectory, spool.get(io, indirect, limits, "second", url, descriptor, options));
        }
        try spool.remove(io, args[3], "artifact");
        try spool.remove(io, args[3], "artifact");
        var short = std.Io.Reader.fixed(payload[0 .. payload.len - 1]);
        try std.testing.expectError(error.ArtifactSizeMismatch, spool.stage(io, args[3], limits, "second", payload.len, &short));
        var long = std.Io.Reader.fixed(payload);
        try std.testing.expectError(error.ArtifactSizeMismatch, spool.stage(io, args[3], limits, "second", payload.len - 1, &long));
        var exact = std.Io.Reader.fixed(payload);
        try std.testing.expectEqual(descriptor, try spool.stage(io, args[3], .{ .bytes = payload.len, .files = 1 }, "second", payload.len, &exact));
        try spool.put(io, args[3], "second", upload, descriptor, options);
        try spool.remove(io, args[3], "second");
        return;
    }
    try spool.get(io, args[3], limits, "artifact", url, descriptor, options);
    try std.testing.expectError(error.PathAlreadyExists, spool.get(io, args[3], limits, "artifact", url, descriptor, options));
    {
        // Simulate another owner of the directory using an independent fd.
        const linux = std.os.linux;
        const held = try std.Io.Dir.openDirAbsolute(io, args[3], .{ .iterate = true, .follow_symlinks = false });
        defer held.close(io);
        try std.testing.expectEqual(.SUCCESS, linux.errno(linux.flock(held.handle, std.posix.LOCK.EX | std.posix.LOCK.NB)));
        try std.testing.expectError(error.SpoolBusy, spool.get(io, args[3], limits, "second", url, descriptor, options));
        try std.testing.expectError(error.SpoolBusy, spool.remove(io, args[3], "artifact"));
    }
    const file = try dir.openFile(io, "artifact", .{});
    defer file.close(io);
    var bytes: [payload.len + 1]u8 = undefined;
    const n = try file.readPositionalAll(io, &bytes, 0);
    try std.testing.expectEqualStrings(payload, bytes[0..n]);

    const cases = [_]struct { path: []const u8, failure: anyerror }{
        .{ .path = "/large", .failure = error.ArtifactSizeMismatch },
        .{ .path = "/short", .failure = error.ArtifactSizeMismatch },
        .{ .path = "/wrong", .failure = error.ArtifactDigestMismatch },
        .{ .path = "/partial", .failure = error.ArtifactHttpRejected },
        .{ .path = "/redirect", .failure = error.ArtifactHttpRejected },
        .{ .path = "/temporary", .failure = error.ArtifactTransientFailure },
        .{ .path = "/forbidden", .failure = error.ArtifactHttpRejected },
    };
    for (cases) |case| {
        const bad_url = try std.fmt.allocPrintSentinel(a, "{s}{s}", .{ args[1], case.path }, 0);
        try std.testing.expectError(case.failure, download.get(io, dir, "rejected", bad_url, descriptor, options));
    }
    const retry_url = try std.fmt.allocPrintSentinel(a, "{s}/retry", .{args[1]}, 0);
    try std.testing.expectError(error.ArtifactTransientFailure, spool.get(io, args[3], limits, "retry", retry_url, descriptor, options));
    try spool.get(io, args[3], limits, "retry", retry_url, descriptor, options);
    try spool.remove(io, args[3], "retry");
    const slow_url = try std.fmt.allocPrintSentinel(a, "{s}/slow", .{args[1]}, 0);
    options.timeout_ms = 150;
    try std.testing.expectError(error.ArtifactTimeout, download.get(io, dir, "rejected", slow_url, descriptor, options));
    options.timeout_ms = 2000;
    var cancel_during: std.atomic.Value(bool) = .init(false);
    const CancelAfter = struct {
        flag: *std.atomic.Value(bool),
        io: std.Io,
        fn run(self: @This()) void {
            self.io.sleep(.fromMilliseconds(70), .awake) catch {};
            self.flag.store(true, .release);
        }
    };
    {
        const cancel_thread = try std.Thread.spawn(.{}, CancelAfter.run, .{CancelAfter{ .flag = &cancel_during, .io = io }});
        defer cancel_thread.join();
        var cancel_options = options;
        cancel_options.cancelled = &cancel_during;
        try std.testing.expectError(error.ArtifactCancelled, spool.get(io, args[3], limits, "rejected", slow_url, descriptor, cancel_options));
    }
    options.origin = "https://localhost:1";
    try std.testing.expectError(error.ArtifactUrlRejected, download.get(io, dir, "rejected", url, descriptor, options));
    options.origin = args[1];
    const authority = args[1]["https://".len..];
    const plain = try std.fmt.allocPrintSentinel(a, "http://{s}/ok", .{authority}, 0);
    const user_info = try std.fmt.allocPrintSentinel(a, "https://user:secret@{s}/ok", .{authority}, 0);
    for ([_][:0]const u8{ plain, user_info }) |rejected_url| {
        try std.testing.expectError(error.ArtifactUrlRejected, download.get(io, dir, "rejected", rejected_url, descriptor, options));
    }
    options.ca_file = null;
    try std.testing.expectError(error.ArtifactTlsFailure, download.get(io, dir, "rejected", url, descriptor, options));
    options.ca_file = args[2];
    var cancelled: std.atomic.Value(bool) = .init(true);
    options.cancelled = &cancelled;
    try std.testing.expectError(error.ArtifactCancelled, download.get(io, dir, "rejected", url, descriptor, options));
    options.cancelled = null;
    options.byte_budget = 1;
    try std.testing.expectError(error.ArtifactBudgetExceeded, download.get(io, dir, "rejected", url, descriptor, options));
    var iter = dir.iterate();
    const entry = (try iter.next(io)) orelse return error.MissingArtifact;
    try std.testing.expectEqualStrings("artifact", entry.name);
    try std.testing.expect((try iter.next(io)) == null);
}
