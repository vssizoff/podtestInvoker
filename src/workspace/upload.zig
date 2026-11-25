const std = @import("std");
const download = @import("download.zig");
const spool = @import("spool.zig");
const linux = std.os.linux;

pub const Target = struct {
    id: []const u8,
    url: [:0]const u8,
    expires_ms: i64,
    checksum: []const u8,
    content_length: []const u8,
    complete: bool,
};

pub const Pending = struct {
    invoker_id: []const u8,
    process_epoch: []const u8,
    attempt_id: []const u8,
    run_id: []const u8,
    fencing_token: [32]u8,
    client_id: []const u8,
    kind: []const u8,
    descriptor: download.Descriptor,
};

pub const Journal = struct {
    io: std.Io,
    dir: std.Io.Dir,

    pub fn open(io: std.Io, absolute_path: []const u8) !Journal {
        const dir = try spool.openLocked(io, absolute_path);
        return .{ .io = io, .dir = dir };
    }

    pub fn close(self: *Journal) void {
        self.dir.close(self.io);
    }

    pub fn save(self: *Journal, pending: Pending) !void {
        try download.validateName(pending.client_id);
        if (pending.client_id.len > 120 or pending.kind.len == 0 or pending.kind.len > 64 or
            pending.invoker_id.len == 0 or pending.invoker_id.len > 64 or
            pending.process_epoch.len == 0 or pending.process_epoch.len > 64 or pending.attempt_id.len == 0 or pending.attempt_id.len > 64 or pending.run_id.len == 0 or pending.run_id.len > 64)
            return error.InvalidUploadIntent;
        const receipt = try receiptName(std.heap.page_allocator, pending.client_id);
        defer std.heap.page_allocator.free(receipt);
        if (self.dir.statFile(self.io, receipt, .{ .follow_symlinks = false })) |_| {
            return error.PathAlreadyExists;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        const json = try std.json.Stringify.valueAlloc(std.heap.page_allocator, pending, .{});
        defer std.heap.page_allocator.free(json);
        if (json.len >= 2048) return error.InvalidUploadIntent;
        const name = try intentName(std.heap.page_allocator, pending.client_id);
        defer std.heap.page_allocator.free(name);
        try self.publish(name, json);
    }

    fn publish(self: *Journal, name: []const u8, bytes: []const u8) !void {
        var file = try self.dir.createFileAtomic(self.io, name, .{ .permissions = .fromMode(0o600) });
        defer file.deinit(self.io);
        try file.file.writeStreamingAll(self.io, bytes);
        try file.file.sync(self.io);
        try file.link(self.io);
        try syncDir(self.dir);
    }

    pub fn load(self: *Journal, allocator: std.mem.Allocator, client_id: []const u8) !std.json.Parsed(Pending) {
        const name = try intentName(allocator, client_id);
        defer allocator.free(name);
        const parsed = try self.loadEntry(allocator, name);
        errdefer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.client_id, client_id)) return error.InvalidUploadIntent;
        return parsed;
    }

    pub fn loadEntry(self: *Journal, allocator: std.mem.Allocator, name: []const u8) !std.json.Parsed(Pending) {
        try download.validateName(name);
        const stat = try self.dir.statFile(self.io, name, .{ .follow_symlinks = false });
        if (stat.kind != .file or stat.nlink != 1 or stat.permissions.toMode() & 0o077 != 0 or stat.size > 2048) return error.UnsafeUploadIntent;
        const bytes = try self.dir.readFileAlloc(self.io, name, allocator, .limited(2048));
        defer allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(Pending, allocator, bytes, .{ .allocate = .alloc_always });
        errdefer parsed.deinit();
        const expected = try intentName(allocator, parsed.value.client_id);
        defer allocator.free(expected);
        if (!std.mem.eql(u8, name, expected)) return error.InvalidUploadIntent;
        return parsed;
    }

    pub fn remove(self: *Journal, client_id: []const u8) !void {
        const name = try intentName(std.heap.page_allocator, client_id);
        defer std.heap.page_allocator.free(name);
        self.dir.deleteFile(self.io, name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        try syncDir(self.dir);
    }

    /// Release the spool only after Backend confirmation is durably recorded.
    /// A confirmed intent needs no live lease or RPC to finish local cleanup.
    /// The confirmation receipt must be retained until consumed by the result WAL.
    pub fn recover(self: *Journal, allocator: std.mem.Allocator, path: []const u8, client_id: []const u8, options: download.Options, control: anytype) !void {
        const parsed = try self.load(allocator, client_id);
        defer parsed.deinit();
        // A previous process may have linked an intent and died before the
        // directory sync. Persist that entry before issuing any remote calls.
        try syncDir(self.dir);
        const name = try receiptName(allocator, client_id);
        defer allocator.free(name);
        const receipt = self.readReceipt(allocator, name) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        defer if (receipt) |id| allocator.free(id);
        if (receipt == null) {
            const id = try confirm(self.io, path, parsed.value, options, control);
            try self.publish(name, id);
        }
        try spool.remove(self.io, path, client_id);
    }

    pub fn confirmed(self: *Journal, allocator: std.mem.Allocator, client_id: []const u8) ![]u8 {
        const name = try receiptName(allocator, client_id);
        defer allocator.free(name);
        const id = try self.readReceipt(allocator, name);
        errdefer allocator.free(id);
        try syncDir(self.dir);
        return id;
    }

    pub fn reportRecorded(self: *Journal, allocator: std.mem.Allocator, client_id: []const u8) !bool {
        const name = try reportName(allocator, client_id);
        defer allocator.free(name);
        const marker = self.readReceipt(allocator, name) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer allocator.free(marker);
        if (!std.mem.eql(u8, marker, "reported-v1")) return error.InvalidReportMarker;
        try syncDir(self.dir);
        return true;
    }

    pub fn markReportRecorded(self: *Journal, allocator: std.mem.Allocator, client_id: []const u8) !void {
        const name = try reportName(allocator, client_id);
        defer allocator.free(name);
        try self.publish(name, "reported-v1");
    }

    fn readReceipt(self: *Journal, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
        const stat = try self.dir.statFile(self.io, name, .{ .follow_symlinks = false });
        if (stat.kind != .file or stat.nlink != 1 or stat.permissions.toMode() & 0o077 != 0 or stat.size > 120) return error.UnsafeUploadReceipt;
        const id = try self.dir.readFileAlloc(self.io, name, allocator, .limited(121));
        errdefer allocator.free(id);
        try download.validateName(id);
        return id;
    }
};

fn receiptName(allocator: std.mem.Allocator, client_id: []const u8) ![]u8 {
    const name = try intentName(allocator, client_id);
    @memcpy(name[0..6], "result");
    return name;
}

fn reportName(allocator: std.mem.Allocator, client_id: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(client_id, &digest, .{});
    return std.fmt.allocPrint(allocator, "reported-{s}", .{std.fmt.bytesToHex(digest, .lower)});
}

fn intentName(allocator: std.mem.Allocator, client_id: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(client_id, &digest, .{});
    return std.fmt.allocPrint(allocator, "upload-{s}.json", .{std.fmt.bytesToHex(digest, .lower)});
}

fn syncDir(dir: std.Io.Dir) !void {
    while (true) switch (linux.errno(linux.fsync(dir.handle))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return error.UploadJournalSyncUncertain,
    };
}

/// One retryable attempt. The caller restores Pending and the original lease
/// after restart. Control is bound to that lease. It must map only a missing
/// staged object to UploadMissing and persist confirmed references idempotently.
pub fn advance(io: std.Io, path: []const u8, pending: Pending, options: download.Options, control: anytype) !void {
    const id = try confirm(io, path, pending, options, control);
    try control.record(pending, id);
    try spool.remove(io, path, pending.client_id);
}

fn confirm(io: std.Io, path: []const u8, pending: Pending, options: download.Options, control: anytype) ![]const u8 {
    try download.validateName(pending.client_id);
    if (options.cancelled) |flag| if (flag.load(.acquire)) return error.ArtifactCancelled;
    const target: Target = try control.create(pending);
    if (target.id.len > 120) return error.InvalidUploadTarget;
    download.validateName(target.id) catch return error.InvalidUploadTarget;
    if (!target.complete) {
        if (control.complete(target.id)) |_| {
            // The previous PUT succeeded, even if its response was lost.
        } else |err| {
            if (err != error.UploadMissing) return err;
            var checksum: [44]u8 = undefined;
            var length: [20]u8 = undefined;
            const expected_checksum = std.base64.standard.Encoder.encode(&checksum, &pending.descriptor.sha256);
            const expected_length = try std.fmt.bufPrint(&length, "{d}", .{pending.descriptor.bytes});
            if (!std.mem.eql(u8, expected_checksum, target.checksum) or
                !std.mem.eql(u8, expected_length, target.content_length)) return error.InvalidUploadTarget;
            const now = std.Io.Clock.real.now(io).toMilliseconds();
            if (target.expires_ms <= now) return error.UploadTargetExpired;
            var bounded = options;
            bounded.timeout_ms = @intCast(@min(options.timeout_ms, @as(i128, target.expires_ms) - now));
            try spool.put(io, path, pending.client_id, target.url, pending.descriptor, bounded);
            try control.complete(target.id);
        }
    }
    return target.id;
}

test "known completion retries durable recording before spool release" {
    const fixture = struct {
        recorded: bool = false,
        fn create(_: *@This(), _: Pending) !Target {
            return .{ .id = "confirmed", .url = "", .expires_ms = 0, .checksum = "", .content_length = "", .complete = true };
        }
        fn complete(_: *@This(), _: []const u8) error{UploadMissing}!void {
            unreachable;
        }
        fn record(self: *@This(), _: Pending, id: []const u8) !void {
            try std.testing.expectEqualStrings("confirmed", id);
            if (!self.recorded) {
                self.recorded = true;
                return error.JournalUnavailable;
            }
        }
    };
    var control: fixture = .{};
    const pending: Pending = .{ .invoker_id = "invoker", .process_epoch = "epoch", .attempt_id = "attempt", .run_id = "run", .fencing_token = @splat(0), .client_id = "payload", .kind = "build_log", .descriptor = .{ .bytes = 0, .sha256 = @splat(0) } };
    const options: download.Options = .{ .origin = "https://example.invalid", .timeout_ms = 100, .byte_budget = 10 };
    try std.testing.expectError(error.JournalUnavailable, advance(std.testing.io, "", pending, options, &control));
    try std.testing.expectError(error.InvalidSpoolConfig, advance(std.testing.io, "", pending, options, &control));
    try std.testing.expect(control.recorded);
}

test "upload intent survives reopen and stable IDs cannot overwrite pending work" {
    var temp = std.testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try temp.dir.setPermissions(std.testing.io, .fromMode(0o700));
    const path = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const pending: Pending = .{ .invoker_id = "invoker", .process_epoch = "epoch", .attempt_id = "attempt", .run_id = "run", .fencing_token = @splat(0xff), .client_id = "stable-id", .kind = "runner_log", .descriptor = .{ .bytes = 7, .sha256 = @splat(1) } };
    {
        var journal = try Journal.open(std.testing.io, path);
        defer journal.close();
        try journal.save(pending);
    }
    {
        var journal = try Journal.open(std.testing.io, path);
        defer journal.close();
        const parsed = try journal.load(std.testing.allocator, pending.client_id);
        defer parsed.deinit();
        const restored = parsed.value;
        try std.testing.expectEqualStrings(pending.run_id, restored.run_id);
        try std.testing.expectEqualStrings(pending.client_id, restored.client_id);
        try std.testing.expectEqual(pending.descriptor, restored.descriptor);
        try std.testing.expectEqual(pending.fencing_token, restored.fencing_token);
        try std.testing.expectError(error.PathAlreadyExists, journal.save(pending));
        try journal.remove(pending.client_id);
    }
}

test "confirmed receipt survives restart and cleanup needs no control call" {
    const Fixture = struct {
        calls: usize = 0,
        fn create(self: *@This(), _: Pending) !Target {
            self.calls += 1;
            if (self.calls != 1) return error.ControlOffline;
            return .{ .id = "confirmed", .url = "", .expires_ms = 0, .checksum = "", .content_length = "", .complete = false };
        }
        fn complete(_: *@This(), _: []const u8) error{UploadMissing}!void {}
    };
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var state = std.testing.tmpDir(.{ .iterate = true });
    defer state.cleanup();
    try state.dir.setPermissions(io, .fromMode(0o700));
    const path = try state.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    var payloads = std.testing.tmpDir(.{ .iterate = true });
    defer payloads.cleanup();
    try payloads.dir.setPermissions(io, .fromMode(0o700));
    const payload_path = try payloads.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(payload_path);
    var reader: std.Io.Reader = .fixed("log");
    const descriptor = try spool.stage(io, payload_path, .{ .bytes = 3, .files = 1 }, "payload", 3, &reader);
    const pending: Pending = .{ .invoker_id = "invoker", .process_epoch = "epoch", .attempt_id = "attempt", .run_id = "run", .fencing_token = @splat(1), .client_id = "payload", .kind = "build_log", .descriptor = descriptor };
    const options: download.Options = .{ .origin = "https://example.invalid", .timeout_ms = 100, .byte_budget = 10 };
    var control: Fixture = .{};
    {
        var journal = try Journal.open(io, path);
        defer journal.close();
        try journal.save(pending);
        try std.testing.expectError(error.InvalidSpoolConfig, journal.recover(allocator, "", pending.client_id, options, &control));
        _ = try payloads.dir.statFile(io, pending.client_id, .{});
    }
    {
        var journal = try Journal.open(io, path);
        defer journal.close();
        try journal.recover(allocator, payload_path, pending.client_id, options, &control);
        const id = try journal.confirmed(allocator, pending.client_id);
        defer allocator.free(id);
        try std.testing.expectEqualStrings("confirmed", id);
        try std.testing.expectEqual(@as(usize, 1), control.calls);
        try std.testing.expectError(error.FileNotFound, payloads.dir.statFile(io, pending.client_id, .{}));
        try journal.remove(pending.client_id);
        try std.testing.expectError(error.PathAlreadyExists, journal.save(pending));
    }
}
