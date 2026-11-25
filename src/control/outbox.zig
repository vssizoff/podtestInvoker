const std = @import("std");

pub const Kind = enum(u8) { event = 1, lease = 2, acknowledge = 3, checkpoint = 4, run_event = 5, run_cursor = 6 };
const header_size = 28;
const max_record_bytes = 4 * 1024 * 1024;
const filename = "event-outbox.wal";
const compact_filename = "event-outbox.compact";
pub const Record = struct {
    kind: Kind,
    sequence: u64,
    payload: []const u8,
};

pub const Outbox = struct {
    io: std.Io,
    dir: std.Io.Dir,
    file: std.Io.File,
    sequence: u64,
    max_bytes: u64,
    poisoned: bool = false,
    pending_events: u64 = 0,

    /// State directory must already be private and exclusively locked.
    /// At most one process may open an Outbox for a state directory.
    pub fn open(io: std.Io, absolute_state_dir: []const u8, max_bytes: u64) !Outbox {
        if (max_bytes < 128 or max_bytes > 64 * 1024 * 1024 or !std.fs.path.isAbsolute(absolute_state_dir)) return error.InvalidOutboxConfig;
        const dir = try std.Io.Dir.openDirAbsolute(io, absolute_state_dir, .{ .follow_symlinks = false, .iterate = true });
        errdefer dir.close(io);
        const file = dir.createFile(io, filename, .{ .read = true, .exclusive = true, .permissions = .fromMode(0o600) }) catch |err| switch (err) {
            error.PathAlreadyExists => try dir.openFile(io, filename, .{ .mode = .read_write, .follow_symlinks = false, .resolve_beneath = true }),
            else => return err,
        };
        errdefer file.close(io);
        const stat = try file.stat(io);
        if (stat.kind != .file or stat.nlink != 1 or stat.permissions.toMode() & 0o077 != 0) return error.UnsafeOutboxFile;
        var outbox = Outbox{ .io = io, .dir = dir, .file = file, .sequence = 0, .max_bytes = max_bytes };
        try outbox.syncDirectory();
        const recovered = try outbox.replay(std.heap.smp_allocator);
        freeRecords(std.heap.smp_allocator, recovered);
        // A previous write may have reached the page cache without its sync
        // completing. Make the recovered state durable before acting on it.
        try file.sync(io);
        try outbox.discardInterruptedCompaction();
        return outbox;
    }

    pub fn close(self: *Outbox) void {
        self.file.close(self.io);
        self.dir.close(self.io);
    }

    /// Appends the payload and fsyncs it before returning the assigned sequence.
    pub fn append(self: *Outbox, kind: Kind, payload: []const u8) !u64 {
        if ((kind != .event and kind != .lease) or payload.len == 0 or payload.len > max_record_bytes) return error.InvalidOutboxRecord;
        return self.appendRecord(kind, payload);
    }

    /// Serial producer API. The encoder must put the provided run ID, sequence
    /// and event ID in its wire message. It may return borrowed bytes, valid
    /// until enqueue returns. The encoder must not reenter the outbox.
    pub fn enqueue(self: *Outbox, allocator: std.mem.Allocator, run_id: []const u8, encoder: anytype) !u64 {
        if (run_id.len == 0 or run_id.len > 255) return error.InvalidRunId;
        const records = try self.replay(allocator);
        defer freeRecords(allocator, records);
        var last: u64 = 0;
        const Encoder = switch (@typeInfo(@TypeOf(encoder))) {
            .pointer => |ptr| ptr.child,
            else => @TypeOf(encoder),
        };
        for (records) |record| {
            if (record.kind != .run_event and record.kind != .run_cursor) continue;
            const entry = try runEntry(record.payload, record.kind);
            if (!std.mem.eql(u8, entry.run_id, run_id)) continue;
            if (@hasDecl(Encoder, "matchesPending") and record.kind == .run_event) {
                if (try encoder.matchesPending(entry.wire)) return entry.sequence;
            }
            last = @max(last, entry.sequence);
        }
        const next = std.math.add(u64, last, 1) catch return error.SequenceExhausted;
        var event_id: [16]u8 = undefined;
        try self.io.randomSecure(&event_id);
        event_id[6] = (event_id[6] & 0x0f) | 0x40;
        event_id[8] = (event_id[8] & 0x3f) | 0x80;
        const wire = try encoder.encode(run_id, next, event_id);
        if (wire.len == 0 or wire.len > max_record_bytes - 9 - run_id.len) return error.InvalidOutboxRecord;
        const payload = try allocator.alloc(u8, 9 + run_id.len + wire.len);
        defer allocator.free(payload);
        payload[0] = @intCast(run_id.len);
        std.mem.writeInt(u64, payload[1..9], next, .little);
        @memcpy(payload[9..][0..run_id.len], run_id);
        @memcpy(payload[9 + run_id.len ..], wire);
        _ = try self.appendRecord(.run_event, payload);
        return next;
    }

    fn appendRecord(self: *Outbox, kind: Kind, payload: []const u8) !u64 {
        if (self.poisoned) return error.OutboxNeedsReopen;
        const stat = try self.file.stat(self.io);
        // Leave room for one tombstone per pending event, even at the quota.
        const pending = self.pending_events + @as(u64, if (kind == .event or kind == .run_event) 1 else 0);
        if (pending > self.max_bytes / header_size) return error.OutboxFull;
        const record_size = header_size + payload.len + pending * header_size;
        if (stat.size > self.max_bytes or record_size > self.max_bytes - stat.size) return error.OutboxFull;
        const next = std.math.add(u64, self.sequence, 1) catch return error.SequenceExhausted;
        try self.writeRecord(kind, next, payload, stat.size);
        self.sequence = next;
        self.pending_events = pending;
        return next;
    }

    /// Sends stored wire bytes in journal order. Reporter returns success only
    /// for a valid Backend ACK (including duplicate); errors stop the drain.
    /// Call serially; the reporter must not reenter the outbox.
    pub fn flush(self: *Outbox, allocator: std.mem.Allocator, reporter: anytype) !usize {
        const records = try self.replay(allocator);
        defer freeRecords(allocator, records);
        var count: usize = 0;
        for (records) |record| {
            const wire = switch (record.kind) {
                .event => record.payload,
                .run_event => (try runEntry(record.payload, .run_event)).wire,
                else => continue,
            };
            try reporter.report(wire);
            try self.acknowledge(record.sequence);
            count += 1;
        }
        return count;
    }

    /// Attempt one ordered drain per run. Transport rejections leave that
    /// run's head pending, while WAL write failures stop the entire drain.
    pub fn flushRuns(self: *Outbox, allocator: std.mem.Allocator, blocked: *std.StringHashMapUnmanaged(void), reporter: anytype) !usize {
        const records = try self.replay(allocator);
        defer freeRecords(allocator, records);
        var rejected: std.StringHashMapUnmanaged(void) = .empty;
        defer rejected.deinit(allocator);
        for (records) |record| {
            if (record.kind != .run_event) continue;
            const entry = try runEntry(record.payload, .run_event);
            if (blocked.contains(entry.run_id) or rejected.contains(entry.run_id)) continue;
            reporter.report(entry.wire) catch {
                try rejected.put(allocator, entry.run_id, {});
                continue;
            };
            try self.acknowledge(record.sequence);
        }
        return rejected.count();
    }

    fn acknowledge(self: *Outbox, sequence: u64) !void {
        const stat = try self.file.stat(self.io);
        if (stat.size > self.max_bytes or header_size > self.max_bytes - stat.size) return error.OutboxFull;
        try self.writeRecord(.acknowledge, sequence, "", stat.size);
        self.pending_events -= 1;
    }

    /// Rewrites pending events and retained lease records to a private sibling, fsyncs it,
    /// atomically renames it over the journal, and fsyncs the directory. The
    /// state directory lock must be held for the entire operation.
    pub fn compact(self: *Outbox, allocator: std.mem.Allocator) !void {
        if (self.poisoned) return error.OutboxNeedsReopen;
        const records = try self.replay(allocator);
        defer freeRecords(allocator, records);
        var latest: std.StringHashMapUnmanaged(u64) = .empty;
        defer latest.deinit(allocator);
        for (records) |record| {
            if (record.kind != .run_event and record.kind != .run_cursor) continue;
            const entry = try runEntry(record.payload, record.kind);
            try latest.put(allocator, entry.run_id, record.sequence);
        }
        // First compute whether the checkpoint and remaining records actually
        // fit and save space; the replacement may coexist with the old file.
        var replacement_size: u64 = header_size;
        for (records) |record| {
            if (!try survivesCompaction(record, &latest)) continue;
            replacement_size += header_size + record.payload.len;
        }
        if (replacement_size >= (try self.file.stat(self.io)).size) return;
        const tmp = try self.dir.createFile(self.io, compact_filename, .{ .read = true, .exclusive = true, .permissions = .fromMode(0o600) });
        var renamed = false;
        errdefer if (!renamed) {
            tmp.close(self.io);
            self.discardInterruptedCompaction() catch {
                self.poisoned = true;
            };
        };
        var header: [header_size]u8 = undefined;
        fillHeader(&header, .checkpoint, self.sequence, "");
        try tmp.writePositionalAll(self.io, &header, 0);
        var offset: u64 = header_size;
        for (records) |record| {
            if (!try survivesCompaction(record, &latest)) continue;
            fillHeader(&header, record.kind, record.sequence, record.payload);
            try tmp.writePositionalAll(self.io, &header, offset);
            try tmp.writePositionalAll(self.io, record.payload, offset + header.len);
            offset += header.len + record.payload.len;
        }
        try tmp.sync(self.io);
        try self.dir.rename(compact_filename, self.dir, filename, self.io);
        renamed = true;
        self.file.close(self.io);
        self.file = tmp;
        errdefer self.poisoned = true;
        try self.syncDirectory();
    }

    fn discardInterruptedCompaction(self: *Outbox) !void {
        self.dir.deleteFile(self.io, compact_filename) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        try self.syncDirectory();
    }

    fn syncDirectory(self: *Outbox) !void {
        const linux = std.os.linux;
        while (true) switch (linux.errno(linux.fsync(self.dir.handle))) {
            .SUCCESS => return,
            .INTR => continue,
            else => return error.OutboxDirectorySyncFailed,
        };
    }

    fn writeRecord(self: *Outbox, kind: Kind, sequence: u64, payload: []const u8, offset: u64) !void {
        var header: [header_size]u8 = undefined;
        fillHeader(&header, kind, sequence, payload);
        errdefer self.poisoned = true;
        try self.file.writePositionalAll(self.io, &header, offset);
        try self.file.writePositionalAll(self.io, payload, offset + header.len);
        try self.file.sync(self.io);
    }

    fn fillHeader(header: *[header_size]u8, kind: Kind, sequence: u64, payload: []const u8) void {
        @memcpy(header[0..4], "PTOB");
        header[4] = 2;
        header[5] = @backingInt(kind);
        header[6] = 0;
        header[7] = 0;
        std.mem.writeInt(u64, header[8..16], sequence, .little);
        std.mem.writeInt(u32, header[16..20], @intCast(payload.len), .little);
        std.mem.writeInt(u32, header[20..24], std.hash.Crc32.hash(payload), .little);
        std.mem.writeInt(u32, header[24..28], std.hash.Crc32.hash(header[0..24]), .little);
    }

    /// Returns only complete CRC-validated records. A final torn write is
    /// truncated to the preceding durable boundary; interior corruption fails.
    pub fn replay(self: *Outbox, allocator: std.mem.Allocator) ![]Record {
        if (self.poisoned) return error.OutboxNeedsReopen;
        const stat = try self.file.stat(self.io);
        if (stat.size > self.max_bytes) return error.OutboxCorrupt;
        const bytes = try allocator.alloc(u8, @intCast(stat.size));
        defer allocator.free(bytes);
        if (try self.file.readPositionalAll(self.io, bytes, 0) != bytes.len) return error.OutboxCorrupt;
        var records: std.ArrayList(Record) = .empty;
        errdefer {
            for (records.items) |record| allocator.free(record.payload);
            records.deinit(allocator);
        }
        var maximum_sequence: u64 = 0;
        var checkpoint: u64 = 0;
        var pending: u64 = 0;
        var offset: usize = 0;
        while (offset < bytes.len) {
            if (bytes.len - offset >= 5 and std.mem.eql(u8, bytes[offset..][0..4], "PTOB") and bytes[offset + 4] != 2) return error.UnsupportedOutboxVersion;
            if (bytes.len - offset < header_size) break;
            const header = bytes[offset..][0..header_size];
            if (std.hash.Crc32.hash(header[0..24]) != std.mem.readInt(u32, header[24..28], .little)) return error.OutboxCorrupt;
            if (!std.mem.eql(u8, header[0..4], "PTOB") or header[4] != 2 or header[6] != 0 or header[7] != 0) return error.OutboxCorrupt;
            const kind = switch (header[5]) {
                1 => Kind.event,
                2 => Kind.lease,
                3 => Kind.acknowledge,
                4 => Kind.checkpoint,
                5 => Kind.run_event,
                6 => Kind.run_cursor,
                else => return error.OutboxCorrupt,
            };
            const sequence = std.mem.readInt(u64, header[8..16], .little);
            const len = std.mem.readInt(u32, header[16..20], .little);
            if (len > max_record_bytes or (len == 0) != (kind == .acknowledge or kind == .checkpoint)) return error.OutboxCorrupt;
            const end = offset + header_size + len;
            if (end > bytes.len) break;
            const payload = bytes[offset + header_size .. end];
            if (std.hash.Crc32.hash(payload) != std.mem.readInt(u32, header[20..24], .little)) return error.OutboxCorrupt;
            if (kind == .checkpoint) {
                if (offset != 0 or sequence == 0) return error.OutboxCorrupt;
                checkpoint = sequence;
            } else if (kind == .acknowledge) {
                if (sequence == 0 or sequence > @max(checkpoint, maximum_sequence)) return error.OutboxCorrupt;
                const found = std.sort.binarySearch(Record, records.items, sequence, orderSequence) orelse return error.OutboxCorrupt;
                const acked_record = &records.items[found];
                if (acked_record.kind == .run_event) {
                    const entry = try runEntry(acked_record.payload, .run_event);
                    const cursor = try allocator.dupe(u8, acked_record.payload[0 .. 9 + entry.run_id.len]);
                    allocator.free(acked_record.payload);
                    acked_record.kind = .run_cursor;
                    acked_record.payload = cursor;
                } else {
                    if (acked_record.kind != .event) return error.OutboxCorrupt;
                    acked_record.kind = .acknowledge;
                    allocator.free(acked_record.payload);
                    acked_record.payload = &.{};
                }
                pending -= 1;
            } else {
                if (sequence == 0 or sequence <= maximum_sequence) return error.OutboxCorrupt;
                if (sequence > checkpoint and sequence - 1 != @max(checkpoint, maximum_sequence)) return error.OutboxCorrupt;
                if (kind == .run_event or kind == .run_cursor) _ = try runEntry(payload, kind);
                if (kind == .run_cursor and sequence > checkpoint) return error.OutboxCorrupt;
                const owned = try allocator.dupe(u8, payload);
                errdefer allocator.free(owned);
                try records.append(allocator, .{ .kind = kind, .sequence = sequence, .payload = owned });
                maximum_sequence = sequence;
                if (kind == .event or kind == .run_event) pending += 1;
            }
            offset = end;
        }
        if (offset != bytes.len) {
            errdefer self.poisoned = true;
            try self.file.setLength(self.io, offset);
            try self.file.sync(self.io);
        }
        if (offset + pending * header_size > self.max_bytes) return error.OutboxFull;
        var kept: usize = 0;
        for (records.items) |record| {
            if (record.kind == .acknowledge) continue;
            records.items[kept] = record;
            kept += 1;
        }
        records.items.len = kept;
        const result = try records.toOwnedSlice(allocator);
        self.sequence = @max(checkpoint, maximum_sequence);
        self.pending_events = pending;
        return result;
    }
};

const RunEntry = struct { run_id: []const u8, sequence: u64, wire: []const u8 };

fn runEntry(payload: []const u8, kind: Kind) !RunEntry {
    if (payload.len < 10 or payload[0] == 0) return error.OutboxCorrupt;
    const end: usize = 9 + @as(usize, payload[0]);
    if (end > payload.len or (end == payload.len) != (kind == .run_cursor)) return error.OutboxCorrupt;
    const sequence = std.mem.readInt(u64, payload[1..9], .little);
    if (sequence == 0) return error.OutboxCorrupt;
    return .{ .run_id = payload[9..end], .sequence = sequence, .wire = payload[end..] };
}

fn survivesCompaction(record: Record, latest: *const std.StringHashMapUnmanaged(u64)) !bool {
    if (record.kind != .run_cursor) return true;
    return latest.get((try runEntry(record.payload, .run_cursor)).run_id).? == record.sequence;
}

fn orderSequence(sequence: u64, record: Record) std.math.Order {
    return std.math.order(sequence, record.sequence);
}

pub fn freeRecords(allocator: std.mem.Allocator, records: []Record) void {
    for (records) |record| allocator.free(record.payload);
    allocator.free(records);
}

const EventEncoder = struct {
    buffer: [64]u8 = undefined,

    pub fn encode(self: *@This(), run_id: []const u8, sequence: u64, event_id: [16]u8) ![]const u8 {
        return std.fmt.bufPrint(&self.buffer, "{s}:{d}:{x}", .{ run_id, sequence, event_id[0] });
    }
};

test "run drain skips a rejected head and its successors but acknowledges other runs" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const parent = try std.Io.Dir.cwd().realPathFileAlloc(io, ".zig-cache/tmp", a);
    defer a.free(parent);
    const path = try std.fs.path.join(a, &.{ parent, &temp.sub_path });
    defer a.free(path);
    var wal = try Outbox.open(io, path, 4096);
    defer wal.close();
    var encoder: EventEncoder = .{};
    for ([_][]const u8{ "a", "b", "a", "c" }) |id| _ = try wal.enqueue(a, id, &encoder);
    var blocked: std.StringHashMapUnmanaged(void) = .empty;
    defer blocked.deinit(a);
    try blocked.put(a, "c", {});
    const Reporter = struct {
        calls: usize = 0,
        pub fn report(self: *@This(), wire: []const u8) !void {
            self.calls += 1;
            if (std.mem.startsWith(u8, wire, "a:1:")) return error.Rejected;
            try std.testing.expect(std.mem.startsWith(u8, wire, "b:1:"));
        }
    };
    var reporter: Reporter = .{};
    try std.testing.expectEqual(@as(usize, 1), try wal.flushRuns(a, &blocked, &reporter));
    try std.testing.expectEqual(@as(usize, 2), reporter.calls);
    try wal.compact(a);
    const records = try wal.replay(a);
    defer freeRecords(a, records);
    try std.testing.expectEqual(@as(u64, 3), wal.pending_events);
    try std.testing.expectEqual(Kind.run_cursor, records[1].kind);
    try std.testing.expectEqualStrings("b", (try runEntry(records[1].payload, .run_cursor)).run_id);
}

test "outbox syncs monotonic sequence, recovers, and truncates torn tail" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const dir_path = try std.Io.Dir.cwd().realPathFileAlloc(io, ".zig-cache/tmp", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);
    const name = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ dir_path, &temp.sub_path });
    defer std.testing.allocator.free(name);

    {
        var first = try Outbox.open(io, name, 128);
        defer first.close();
        try std.testing.expectEqual(@as(u64, 1), try first.append(.event, "event-one"));
        try std.testing.expectEqual(@as(u64, 2), try first.append(.lease, "lease-two"));
        try std.testing.expectError(error.OutboxFull, first.append(.event, &@as([64]u8, @splat('x'))));
    }

    const wal = try temp.dir.openFile(io, "event-outbox.wal", .{ .mode = .read_write });
    try wal.writePositionalAll(io, "short", 2 * header_size + "event-one".len + "lease-two".len);
    wal.close(io);

    var recovered = try Outbox.open(io, name, 256);
    defer recovered.close();
    try std.testing.expectEqual(@as(u64, 2), recovered.sequence);
    const records = try recovered.replay(std.testing.allocator);
    defer {
        for (records) |record| std.testing.allocator.free(record.payload);
        std.testing.allocator.free(records);
    }
    try std.testing.expectEqual(@as(usize, 2), records.len);
    try std.testing.expectEqualStrings("event-one", records[0].payload);
    try std.testing.expectEqual(.lease, records[1].kind);
    try std.testing.expectEqual(@as(u64, 3), try recovered.append(.event, "event-three"));
    const Reporter = struct {
        pub fn report(_: @This(), payload: []const u8) !void {
            if (std.mem.eql(u8, payload, "event-three")) return error.Retry;
            try std.testing.expectEqualStrings("event-one", payload);
        }
    };
    try std.testing.expectError(error.Retry, recovered.flush(std.testing.allocator, Reporter{}));
    const pending = try recovered.replay(std.testing.allocator);
    defer freeRecords(std.testing.allocator, pending);
    try std.testing.expectEqual(@as(usize, 2), pending.len);
    try std.testing.expectEqual(@as(u64, 2), pending[0].sequence);
    try std.testing.expectEqual(@as(u64, 3), pending[1].sequence);
}

test "outbox detects interior CRC corruption" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const dir_path = try std.Io.Dir.cwd().realPathFileAlloc(io, ".zig-cache/tmp", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);
    const name = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ dir_path, &temp.sub_path });
    defer std.testing.allocator.free(name);
    var outbox = try Outbox.open(io, name, 256);
    try std.testing.expectEqual(@as(u64, 1), try outbox.append(.event, "payload"));
    outbox.close();
    const file = try temp.dir.openFile(io, "event-outbox.wal", .{ .mode = .read_write });
    var byte: [1]u8 = undefined;
    _ = try file.readPositionalAll(io, &byte, header_size);
    byte[0] ^= 1;
    try file.writePositionalAll(io, &byte, header_size);
    file.close(io);
    try std.testing.expectError(error.OutboxCorrupt, Outbox.open(io, name, 256));
}

test "quota reserves enough space to acknowledge all accepted events" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const dir_path = try std.Io.Dir.cwd().realPathFileAlloc(io, ".zig-cache/tmp", allocator);
    defer allocator.free(dir_path);
    const name = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, &temp.sub_path });
    defer allocator.free(name);
    var outbox = try Outbox.open(io, name, 128);
    defer outbox.close();

    _ = try outbox.append(.event, "12345678");
    _ = try outbox.append(.event, "12345678");
    try std.testing.expectError(error.OutboxFull, outbox.append(.lease, "cannot fit"));

    const Reporter = struct {
        pub fn report(_: @This(), payload: []const u8) !void {
            try std.testing.expectEqualStrings("12345678", payload);
        }
    };
    try std.testing.expectEqual(@as(usize, 2), try outbox.flush(allocator, Reporter{}));
    try std.testing.expectEqual(@as(u64, 128), (try outbox.file.stat(io)).size);
    try outbox.compact(allocator);
    try std.testing.expectEqual(@as(u64, header_size), (try outbox.file.stat(io)).size);
    try std.testing.expectEqual(@as(usize, 0), try outbox.flush(allocator, Reporter{}));
    try std.testing.expectEqual(@as(u64, 2), outbox.sequence);
}

test "compaction survives reopen, preserves sparse ordinals, and discards an interrupted sibling" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const parent = try std.Io.Dir.cwd().realPathFileAlloc(io, ".zig-cache/tmp", a);
    defer a.free(parent);
    const name = try std.fmt.allocPrint(a, "{s}/{s}", .{ parent, &temp.sub_path });
    defer a.free(name);
    const Reporter = struct {
        pub fn report(_: @This(), payload: []const u8) !void {
            if (std.mem.eql(u8, payload, "pending")) return error.Retry;
        }
    };
    {
        var wal = try Outbox.open(io, name, 512);
        defer wal.close();
        _ = try wal.append(.event, "confirmed");
        _ = try wal.append(.lease, "lease");
        _ = try wal.append(.event, "pending");
        try std.testing.expectError(error.Retry, wal.flush(a, Reporter{}));
        const sibling = try temp.dir.createFile(io, compact_filename, .{ .permissions = .fromMode(0o600) });
        defer sibling.close(io);
        try sibling.writeStreamingAll(io, "interrupted");
        try sibling.sync(io);
    }
    {
        var wal = try Outbox.open(io, name, 512);
        defer wal.close();
        try std.testing.expectError(error.FileNotFound, temp.dir.openFile(io, compact_filename, .{}));
        try wal.compact(a);
    }
    var wal = try Outbox.open(io, name, 512);
    defer wal.close();
    try std.testing.expectEqual(@as(u64, 3), wal.sequence);
    const pending = try wal.replay(a);
    defer freeRecords(a, pending);
    try std.testing.expectEqual(@as(usize, 2), pending.len);
    try std.testing.expectEqual(@as(u64, 2), pending[0].sequence);
    try std.testing.expectEqual(@as(u64, 3), pending[1].sequence);
    try std.testing.expectEqualStrings("pending", pending[1].payload);
    try std.testing.expectEqual(@as(u64, 4), try wal.append(.event, "next"));
    try std.testing.expectEqual(@as(usize, 2), try wal.flush(a, struct {
        pub fn report(_: @This(), _: []const u8) !void {}
    }{}));
    const drained = try wal.replay(a);
    defer freeRecords(a, drained);
    try std.testing.expectEqual(@as(usize, 1), drained.len);
    try std.testing.expectEqual(Kind.lease, drained[0].kind);
}

test "a torn ACK is not a durable acknowledgement" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const parent = try std.Io.Dir.cwd().realPathFileAlloc(io, ".zig-cache/tmp", a);
    defer a.free(parent);
    const name = try std.fmt.allocPrint(a, "{s}/{s}", .{ parent, &temp.sub_path });
    defer a.free(name);
    {
        var wal = try Outbox.open(io, name, 128);
        defer wal.close();
        _ = try wal.append(.event, "pending");
        var ack: [header_size]u8 = undefined;
        Outbox.fillHeader(&ack, .acknowledge, 1, "");
        try wal.file.writePositionalAll(io, ack[0 .. ack.len - 1], header_size + "pending".len);
        try wal.file.sync(io);
    }
    var wal = try Outbox.open(io, name, 128);
    defer wal.close();
    try std.testing.expectEqual(@as(u64, 1), wal.pending_events);
    try std.testing.expectEqual(@as(u64, header_size + "pending".len), (try wal.file.stat(io)).size);
    try std.testing.expectEqual(@as(usize, 1), try wal.flush(a, struct {
        pub fn report(_: @This(), payload: []const u8) !void {
            try std.testing.expectEqualStrings("pending", payload);
        }
    }{}));
}

test "per-run event ordinals survive ACK, compaction, and process restart" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const parent = try std.Io.Dir.cwd().realPathFileAlloc(io, ".zig-cache/tmp", a);
    defer a.free(parent);
    const name = try std.fmt.allocPrint(a, "{s}/{s}", .{ parent, &temp.sub_path });
    defer a.free(name);
    var encoder: EventEncoder = .{};
    {
        var wal = try Outbox.open(io, name, 2048);
        defer wal.close();
        try std.testing.expectEqual(@as(u64, 1), try wal.enqueue(a, "run-a", &encoder));
        try std.testing.expectEqual(@as(u64, 1), try wal.enqueue(a, "run-b", &encoder));
        try std.testing.expectEqual(@as(usize, 2), try wal.flush(a, struct {
            pub fn report(_: @This(), _: []const u8) !void {}
        }{}));
        try std.testing.expectEqual(@as(u64, 2), try wal.enqueue(a, "run-a", &encoder));
        try wal.compact(a);
    }
    var wal = try Outbox.open(io, name, 2048);
    defer wal.close();
    try std.testing.expectEqual(@as(u64, 3), try wal.enqueue(a, "run-a", &encoder));
    try std.testing.expectEqual(@as(u64, 2), try wal.enqueue(a, "run-b", &encoder));
    const records = try wal.replay(a);
    defer freeRecords(a, records);
    try std.testing.expectEqual(@as(usize, 4), records.len);
    try std.testing.expectEqual(.run_cursor, records[0].kind);
    const cursor = try runEntry(records[0].payload, .run_cursor);
    try std.testing.expectEqualStrings("run-b", cursor.run_id);
    try std.testing.expectEqual(@as(u64, 1), cursor.sequence);
}

test "opening a legacy journal never truncates it" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const dir_path = try std.Io.Dir.cwd().realPathFileAlloc(io, ".zig-cache/tmp", allocator);
    defer allocator.free(dir_path);
    const name = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, &temp.sub_path });
    defer allocator.free(name);

    const legacy = "PTOB\x01\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00x";
    {
        const file = try temp.dir.createFile(io, filename, .{ .permissions = .fromMode(0o600) });
        defer file.close(io);
        try file.writeStreamingAll(io, legacy);
    }
    try std.testing.expectError(error.UnsupportedOutboxVersion, Outbox.open(io, name, 128));
    const file = try temp.dir.openFile(io, filename, .{});
    defer file.close(io);
    var bytes: [legacy.len]u8 = undefined;
    try std.testing.expectEqual(@as(usize, legacy.len), try file.readPositionalAll(io, &bytes, 0));
    try std.testing.expectEqualStrings(legacy, &bytes);
}
