const std = @import("std");
const podman = @import("podman");
const linux = std.os.linux;

pub const directory = "container-journal-v1";
const prefix = "podtest-owned-";
pub const Name = [prefix.len + 32]u8;
const max_records = 256;
const max_record_bytes = 1024;
pub const Kind = enum { container, network, image };

pub const Record = struct {
    invoker_id: []const u8,
    epoch: []const u8,
    run_id: []const u8,
    nonce: [32]u8,
    kind: Kind = .container,
    // Set only after Libpod metadata has confirmed that create completed.
    observed_id: ?podman.Id = null,

    pub fn labels(self: *const Record) podman.ContainerLabels {
        return .{
            .@"podtest.invoker_id" = self.invoker_id,
            .@"podtest.process_epoch" = self.epoch,
            .@"podtest.run_id" = self.run_id,
            .@"podtest.journal_id" = &self.nonce,
            .@"podtest.resource_kind" = @tagName(self.kind),
        };
    }

    pub fn name(self: Record) Name {
        return prefix.* ++ self.nonce;
    }
};

/// Borrow the locked state directory inode for the whole lifetime. The
/// supervisor must serialize reservations and sweeps within this process.
pub const Journal = struct {
    io: std.Io,
    state: std.Io.Dir,
    invoker_id: []const u8,
    epoch: []const u8,

    pub fn reserve(self: Journal, a: std.mem.Allocator, run_id: []const u8) !Record {
        return self.reserveKind(a, run_id, .container);
    }

    pub fn reserveKind(self: Journal, a: std.mem.Allocator, run_id: []const u8, kind: Kind) !Record {
        var nonce: [16]u8 = undefined;
        try self.io.randomSecure(&nonce);
        const record: Record = .{ .invoker_id = self.invoker_id, .epoch = self.epoch, .run_id = run_id, .nonce = std.fmt.bytesToHex(nonce, .lower), .kind = kind };
        if (!valid(record)) return error.InvalidContainerIntent;
        self.state.createDir(self.io, directory, .fromMode(0o700)) catch |err| if (err != error.PathAlreadyExists) return err;
        // Also covers a previous failed directory sync.
        try sync(self.state);
        const dir = try self.open();
        defer dir.close(self.io);
        var it = dir.iterate();
        var count: usize = 0;
        while (try it.next(self.io)) |_| {
            count += 1;
            if (count >= max_records) return error.ContainerJournalFull;
        }
        try self.publish(a, dir, record, false);
        return record;
    }

    fn publish(self: Journal, a: std.mem.Allocator, dir: std.Io.Dir, record: Record, replace: bool) !void {
        const json = try std.json.Stringify.valueAlloc(a, record, .{});
        defer a.free(json);
        var file = try dir.createFileAtomic(self.io, &record.name(), .{ .permissions = .fromMode(0o600), .replace = replace });
        defer file.deinit(self.io);
        try file.file.writeStreamingAll(self.io, json);
        try file.file.sync(self.io);
        if (replace) try file.replace(self.io) else try file.link(self.io);
        try sync(dir);
    }

    /// The live owner may forget only after confirmed removal.
    pub fn finish(self: Journal, record: Record) !void {
        if (!valid(record) or !eq(record.invoker_id, self.invoker_id) or !eq(record.epoch, self.epoch)) return error.InvalidContainerIntent;
        const dir = try self.open();
        defer dir.close(self.io);
        try self.forget(dir, &record.name());
    }

    pub const Summary = struct { removed: usize = 0, unresolved: usize = 0, rejected: usize = 0 };

    /// Recover only resources authenticated by both a durable local intent
    /// and matching Libpod metadata. Image removal is by temporary tag only.
    pub fn sweep(self: Journal, a: std.mem.Allocator, client: podman.Client, stop_fd: ?c_int) !Summary {
        const dir = self.open() catch |err| switch (err) {
            error.FileNotFound => return .{},
            else => return err,
        };
        defer dir.close(self.io);
        var summary: Summary = .{};
        var buf: [128 << 10]u8 = undefined;
        var rootless_checked = false;
        for ([_]Kind{ .container, .network, .image }) |kind| {
            var it = dir.iterate();
            var scanned: usize = 0;
            while (try it.next(self.io)) |entry| {
                if (stop_fd) |fd| {
                    var pfd: linux.pollfd = .{ .fd = fd, .events = linux.POLL.IN, .revents = 0 };
                    const ready = linux.poll(@ptrCast(&pfd), 1, 0);
                    if (ready != 0) return error.ContainerSweepInterrupted;
                }
                scanned += 1;
                if (scanned > max_records) return error.ContainerJournalFull;
                var arena = std.heap.ArenaAllocator.init(a);
                defer arena.deinit();
                const tmp = arena.allocator();
                var record = self.read(dir, tmp, entry.name) catch |err| switch (err) {
                    error.InvalidContainerIntent => {
                        if (kind == .container) summary.rejected += 1;
                        continue;
                    },
                    else => return err,
                };
                if (record.kind != kind) continue;
                if (!eq(record.invoker_id, self.invoker_id)) {
                    summary.rejected += 1;
                    continue;
                }
                if (eq(record.epoch, self.epoch)) continue;
                if (!rootless_checked) {
                    const Info = struct { host: struct { security: struct { rootless: bool } } };
                    const info = try std.json.parseFromSliceLeaky(Info, tmp, try client.info(&buf), .{ .ignore_unknown_fields = true });
                    if (!info.host.security.rootless) return error.RootlessRequired;
                    rootless_checked = true;
                }
                const response = (switch (kind) {
                    .container => client.inspectContainerName(entry.name, &buf),
                    .network => client.inspectNetworkName(entry.name, &buf),
                    .image => client.inspectTagMetadata(entry.name, &buf),
                }) catch |err| switch (err) {
                    // A request may still finish server-side after the client dies.
                    // Keep the intent, even after a 404, and revisit on the next pass.
                    error.PodmanNotFound => {
                        if (record.observed_id != null) {
                            try self.forget(dir, entry.name);
                            summary.removed += 1;
                        } else summary.unresolved += 1;
                        continue;
                    },
                    else => return err,
                };
                const id = resourceId(tmp, record, response) catch |err| switch (err) {
                    error.InvalidContainerOwnership => {
                        summary.rejected += 1;
                        continue;
                    },
                    else => return err,
                };
                if (record.observed_id) |known| {
                    if (!eq(&known, &id)) {
                        summary.rejected += 1;
                        continue;
                    }
                } else {
                    record.observed_id = id;
                    try self.publish(tmp, dir, record, true);
                }
                // Force-remove alone can wait for Podman's stop timeout. Kill
                // first; a stopped container is still eligible for removal.
                if (kind == .container) client.kill(id) catch |err| switch (err) {
                    error.PodmanNotFound, error.PodmanConflict, error.PodmanHttpRejected => {},
                    else => return err,
                };
                (switch (kind) {
                    .container => client.remove(id),
                    .network => client.removeNetwork(id),
                    .image => client.removeTag(entry.name, &buf),
                }) catch |err| switch (err) {
                    error.PodmanNotFound => {},
                    error.PodmanConflict => {
                        summary.unresolved += 1;
                        continue;
                    },
                    else => return err,
                };
                try self.forget(dir, entry.name);
                summary.removed += 1;
            }
        }
        return summary;
    }

    fn open(self: Journal) !std.Io.Dir {
        const dir = try self.state.openDir(self.io, directory, .{ .iterate = true, .follow_symlinks = false });
        errdefer dir.close(self.io);
        if ((try dir.stat(self.io)).permissions.toMode() & 0o077 != 0) return error.UnsafeContainerJournal;
        return dir;
    }

    fn read(self: Journal, dir: std.Io.Dir, a: std.mem.Allocator, name: []const u8) !Record {
        if (name.len != prefix.len + 32 or !std.mem.startsWith(u8, name, prefix) or !hex(name[prefix.len..])) return error.InvalidContainerIntent;
        const info = try dir.statFile(self.io, name, .{ .follow_symlinks = false });
        if (info.kind != .file or info.nlink != 1 or info.permissions.toMode() & 0o077 != 0 or info.size > max_record_bytes) return error.InvalidContainerIntent;
        const file = try dir.openFile(self.io, name, .{ .follow_symlinks = false });
        defer file.close(self.io);
        const bytes = try a.alloc(u8, @intCast(info.size));
        if (try file.readPositionalAll(self.io, bytes, 0) != bytes.len) return error.InvalidContainerIntent;
        const record = std.json.parseFromSliceLeaky(Record, a, bytes, .{}) catch |err| {
            if (err == error.OutOfMemory) return err;
            return error.InvalidContainerIntent;
        };
        if (!valid(record) or !eq(name, &record.name())) return error.InvalidContainerIntent;
        return record;
    }

    fn forget(self: Journal, dir: std.Io.Dir, name: []const u8) !void {
        dir.deleteFile(self.io, name) catch |err| if (err != error.FileNotFound) return err;
        try sync(dir);
    }
};

fn matchingId(a: std.mem.Allocator, record: Record, bytes: []const u8) !podman.Id {
    const Inspect = struct { Id: [64]u8, Name: []const u8, Config: struct { Labels: ?InspectLabels = null } };
    const value = std.json.parseFromSliceLeaky(Inspect, a, bytes, .{ .ignore_unknown_fields = true }) catch |err| {
        if (err == error.OutOfMemory) return err;
        return error.InvalidContainerOwnership;
    };
    const name = if (std.mem.startsWith(u8, value.Name, "/")) value.Name[1..] else value.Name;
    if (!eq(name, &record.name()) or !hex(&value.Id)) return error.InvalidContainerOwnership;
    const actual = value.Config.Labels orelse return error.InvalidContainerOwnership;
    try checkLabels(record, actual);
    return value.Id;
}

fn checkLabels(record: Record, actual: InspectLabels) !void {
    inline for (.{ "managed-by", "podtest.invoker_id", "podtest.process_epoch", "podtest.run_id", "podtest.resource_kind", "podtest.journal_id" }) |field| {
        if (!eq(@field(actual, field), @field(record.labels(), field))) return error.InvalidContainerOwnership;
    }
}

fn resourceId(a: std.mem.Allocator, record: Record, bytes: []const u8) !podman.Id {
    if (record.kind == .container) return matchingId(a, record, bytes);
    if (record.kind == .network) {
        const value = try parseInspect(struct { id: podman.Id, name: []const u8, labels: InspectLabels }, a, bytes);
        if (!eq(value.name, &record.name()) or !hex(&value.id)) return error.InvalidContainerOwnership;
        try checkLabels(record, value.labels);
        return value.id;
    }
    const value = try parseInspect(struct { Id: []const u8, RepoTags: []const []const u8, Labels: InspectLabels }, a, bytes);
    const tag = try std.fmt.allocPrint(a, "localhost/{s}:temporary", .{&record.name()});
    defer a.free(tag);
    for (value.RepoTags) |candidate| {
        if (eq(candidate, tag)) break;
    } else return error.InvalidContainerOwnership;
    try checkLabels(record, value.Labels);
    const id = if (std.mem.startsWith(u8, value.Id, "sha256:")) value.Id[7..] else value.Id;
    if (id.len != 64 or !hex(id)) return error.InvalidContainerOwnership;
    return id[0..64].*;
}

fn parseInspect(comptime T: type, a: std.mem.Allocator, bytes: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, a, bytes, .{ .ignore_unknown_fields = true }) catch |err| {
        if (err == error.OutOfMemory) return err;
        return error.InvalidContainerOwnership;
    };
}

pub fn imageLabels(a: std.mem.Allocator, record: Record) ![]u8 {
    if (!valid(record) or record.kind != .image) return error.InvalidContainerIntent;
    return std.fmt.allocPrint(a, "LABEL managed-by=podtest-invoker podtest.invoker_id={s} podtest.process_epoch={s} podtest.run_id={s} podtest.resource_kind=image podtest.journal_id={s}\n", .{ record.invoker_id, record.epoch, record.run_id, &record.nonce });
}

const InspectLabels = struct {
    @"managed-by": []const u8,
    @"podtest.invoker_id": []const u8,
    @"podtest.process_epoch": []const u8,
    @"podtest.run_id": []const u8,
    @"podtest.resource_kind": []const u8,
    @"podtest.journal_id": []const u8,
};

fn sync(dir: std.Io.Dir) !void {
    while (true) switch (linux.errno(linux.fsync(dir.handle))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return error.ContainerJournalSyncFailed,
    };
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn hex(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isDigit(c) and (c < 'a' or c > 'f')) return false;
    return true;
}

fn token(s: []const u8, max: usize) bool {
    if (s.len == 0 or s.len > max) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return false;
    return true;
}

fn valid(record: Record) bool {
    return token(record.invoker_id, 128) and token(record.epoch, 36) and token(record.run_id, 63) and hex(&record.nonce) and
        (if (record.observed_id) |id| hex(&id) else true);
}

test "ownership requires all labels, exact name, and full hexadecimal id" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const tmp = arena.allocator();
    const intent: Record = .{ .invoker_id = "a", .epoch = "old", .run_id = "run", .nonce = @splat('a') };
    const id: podman.Id = @splat('f');
    const name = intent.name();
    const labels = intent.labels();
    const ok = try std.json.Stringify.valueAlloc(tmp, .{ .Id = &id, .Name = &name, .Config = .{ .Labels = labels } }, .{});
    try std.testing.expectEqual(id, try matchingId(tmp, intent, ok));
    var other = intent;
    other.invoker_id = "b";
    try std.testing.expectError(error.InvalidContainerOwnership, matchingId(tmp, other, ok));
    const incomplete = try std.json.Stringify.valueAlloc(tmp, .{ .Id = &id, .Name = &name, .Config = .{ .Labels = .{ .@"podtest.invoker_id" = "a", .@"podtest.process_epoch" = "old", .@"podtest.run_id" = "run", .@"podtest.journal_id" = &intent.nonce } } }, .{});
    try std.testing.expectError(error.InvalidContainerOwnership, matchingId(tmp, intent, incomplete));
    const short = try std.json.Stringify.valueAlloc(tmp, .{ .Id = "fff", .Name = &name, .Config = .{ .Labels = labels } }, .{});
    try std.testing.expectError(error.InvalidContainerOwnership, matchingId(tmp, intent, short));
    const wrong_name = try std.json.Stringify.valueAlloc(tmp, .{ .Id = &id, .Name = "unrelated", .Config = .{ .Labels = labels } }, .{});
    try std.testing.expectError(error.InvalidContainerOwnership, matchingId(tmp, intent, wrong_name));
}
