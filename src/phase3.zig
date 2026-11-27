const std = @import("std");
const rpc = @import("control/artifact_rpc.zig");
const job = @import("control/job.zig");
const lease = @import("control/lease.zig");
const download = @import("workspace/download.zig");
const inputs = @import("workspace/inputs.zig");
const extract = @import("workspace/extract.zig");
const spool = @import("workspace/spool.zig");
const upload = @import("workspace/upload.zig");
const outbox = @import("control/outbox.zig");

pub const Service = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    state: std.Io.Dir,
    root: []const u8,
    invoker_id: []const u8,
    channel: rpc.Channel,
    options: download.Options,

    pub const Ticket = struct {
        invoker_id: []const u8,
        epoch: []const u8,
        attempt_id: []const u8,
        submission_id: []const u8,
        token: [32]u8,
        source: download.Descriptor,
        bundle: download.Descriptor,
    };

    pub fn open(init: std.process.Init, root: []const u8, invoker_id: []const u8) !Service {
        const io = init.io;
        const a = init.arena.allocator();
        const state = try std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true, .follow_symlinks = false });
        errdefer state.close(io);
        for ([_][]const u8{ "upload-journal", "upload-spool", "input-spool", "workspaces", "claim-intents" }) |name| {
            state.createDir(io, name, .fromMode(0o700)) catch |err| if (err != error.PathAlreadyExists) return err;
            const sub = try std.fs.path.join(a, &.{ root, name });
            var dir = try std.Io.Dir.openDirAbsolute(io, sub, .{ .iterate = true, .follow_symlinks = false });
            defer dir.close(io);
            try secureDirectory(dir);
        }
        try sync(state);
        const endpoint = try setting(init, "PODTEST_CONTROL_ENDPOINT");
        const ca = try pem(init, "PODTEST_CONTROL_CA");
        const cert = try pem(init, "PODTEST_CONTROL_CERT");
        const key = try pem(init, "PODTEST_CONTROL_KEY");
        const origin = try setting(init, "PODTEST_ARTIFACT_ORIGIN");
        if (!std.mem.startsWith(u8, origin, "https://")) return error.ArtifactUrlRejected;
        const artifact_ca = if (init.environ_map.get("PODTEST_ARTIFACT_CA")) |v| try a.dupeSentinel(u8, v, 0) else null;
        try download.init();
        errdefer download.deinit();
        return .{ .io = io, .allocator = a, .state = state, .root = root, .invoker_id = invoker_id, .channel = try rpc.Channel.open(endpoint, ca, cert, key), .options = .{ .origin = origin, .ca_file = artifact_ca, .timeout_ms = 10_000, .byte_budget = 256 << 20 } };
    }

    pub fn close(self: Service) void {
        self.channel.close();
        download.deinit();
        self.state.close(self.io);
    }

    /// Publish liveness only. Until execution is enabled, advertise no slots.
    pub fn heartbeat(self: Service) !void {
        var invoker: [129]u8 = undefined;
        if (self.invoker_id.len >= invoker.len) return error.InvalidInvokerId;
        @memcpy(invoker[0..self.invoker_id.len], self.invoker_id);
        invoker[self.invoker_id.len] = 0;
        try self.channel.heartbeat(invoker[0..self.invoker_id.len :0], 0, 0, "");
    }

    /// Called under the instance lock. Input transfers are disposable because
    /// Claim identity and descriptors are persisted separately from the bytes.
    pub fn cleanInterruptedInputs(self: Service) !void {
        const io = self.io;
        const workspaces = try self.state.openDir(io, "workspaces", .{ .iterate = true, .follow_symlinks = false });
        defer workspaces.close(io);
        _ = try extract.cleanInterrupted(io, workspaces);
        const input_spool = try self.state.openDir(io, "input-spool", .{ .iterate = true, .follow_symlinks = false });
        defer input_spool.close(io);
        var entries = input_spool.iterate();
        while (try entries.next(io)) |entry| {
            if (entry.kind != .directory or !job.validId(entry.name)) return error.UnsafeInputSpoolEntry;
            try input_spool.deleteTree(io, entry.name);
        }
        try sync(input_spool);
    }

    /// Process each stored intent independently; failures never drop its payload.
    pub fn recover(self: Service) !usize {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var journal = try upload.Journal.open(self.io, try std.fs.path.join(a, &.{ self.root, "upload-journal" }));
        defer journal.close();
        var events = try outbox.Outbox.open(self.io, self.root, 64 << 20);
        defer events.close();
        const payloads = try std.fs.path.join(a, &.{ self.root, "upload-spool" });
        var it = journal.dir.iterate();
        var failed: usize = 0;
        var unknown_intent = false;
        var blocked: std.StringHashMapUnmanaged(void) = .empty;
        while (try it.next(self.io)) |entry| {
            if (!std.mem.startsWith(u8, entry.name, "upload-")) continue;
            const parsed = journal.loadEntry(a, entry.name) catch {
                unknown_intent = true;
                failed += 1;
                continue;
            };
            defer parsed.deinit();
            self.recoverEntry(&journal, &events, payloads, parsed.value) catch {
                failed += 1;
                if (job.validId(parsed.value.run_id)) {
                    try blocked.put(a, try a.dupe(u8, parsed.value.run_id), {});
                } else {
                    unknown_intent = true;
                }
            };
        }
        // An unreadable intent may belong to any pending event. Otherwise
        // preserve only the affected runs until their markers are durable.
        if (!unknown_intent) {
            failed += try events.flushRuns(std.heap.page_allocator, &blocked, self.channel);
            try events.compact(std.heap.page_allocator);
        }
        return failed;
    }

    fn recoverEntry(self: Service, journal: *upload.Journal, events: *outbox.Outbox, payloads: []const u8, pending: upload.Pending) !void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        if (!job.validId(pending.run_id) or !std.mem.eql(u8, pending.invoker_id, self.invoker_id)) return error.UploadIdentityMismatch;
        if (try journal.reportRecorded(allocator, pending.client_id)) return;
        const pin_path = try std.fmt.allocPrint(allocator, "claim-intents/pin-{s}", .{pending.run_id});
        defer allocator.free(pin_path);
        const ticket_bytes = try self.state.readFileAlloc(self.io, pin_path, allocator, .limited(2048));
        defer allocator.free(ticket_bytes);
        const ticket = try std.json.parseFromSlice(Ticket, allocator, ticket_bytes, .{});
        defer ticket.deinit();
        if (!std.mem.eql(u8, ticket.value.invoker_id, pending.invoker_id) or !std.mem.eql(u8, ticket.value.epoch, pending.process_epoch) or !std.mem.eql(u8, ticket.value.attempt_id, pending.attempt_id) or !std.mem.eql(u8, &ticket.value.token, &pending.fencing_token)) return error.UploadIdentityMismatch;
        var control: rpc.Upload = .{ .channel = self.channel, .invoker_id = self.invoker_id };
        try journal.recover(allocator, payloads, pending.client_id, self.options, &control);
        const artifact_id = try journal.confirmed(allocator, pending.client_id);
        var encoder: rpc.ArtifactEvent = .{
            .identity = .{
                .invoker = try allocator.dupeSentinel(u8, pending.invoker_id, 0),
                .epoch = try allocator.dupeSentinel(u8, pending.process_epoch, 0),
                .attempt = try allocator.dupeSentinel(u8, pending.attempt_id, 0),
                .run = try allocator.dupeSentinel(u8, pending.run_id, 0),
                .token = pending.fencing_token,
            },
            .submission = try allocator.dupeSentinel(u8, ticket.value.submission_id, 0),
            .artifact = try allocator.dupeSentinel(u8, artifact_id, 0),
            .timestamp_ms = @intCast(std.Io.Clock.real.now(self.io).toMilliseconds()),
        };
        _ = try events.enqueue(std.heap.page_allocator, pending.run_id, &encoder);
        try journal.markReportRecorded(allocator, pending.client_id);
    }

    /// Explicitly prepare an already assigned attempt. This does not consume
    /// JetStream advertisements, start containers, or submit judging events.
    pub fn prepare(self: Service, assignment: job.Job, process_epoch: []const u8) !void {
        _ = try self.claimAssigned(assignment, process_epoch, false);
    }

    /// Claim and fsync the lease without downloading inputs.
    pub fn pinAssigned(self: Service, assignment: job.Job, process_epoch: []const u8) !rpc.Claim {
        return self.claimAssigned(assignment, process_epoch, true);
    }

    pub const ClaimIntent = struct { epoch: []const u8, job: job.Job, invoker: []const u8 };

    pub fn loadClaim(self: Service, run: []const u8) !ClaimIntent {
        if (!job.validId(run)) return error.ClaimIntentMismatch;
        const a = self.allocator;
        const path = try std.fmt.allocPrint(a, "claim-intents/{s}", .{run});
        const saved = try self.state.readFileAlloc(self.io, path, a, .limited(16 << 10));
        const record = try std.json.parseFromSliceLeaky(ClaimIntent, a, saved, .{});
        const canonical = try std.json.Stringify.valueAlloc(a, record.job, .{});
        const parsed = try job.parse(a, canonical);
        defer parsed.deinit();
        if (!std.mem.eql(u8, record.job.run_id, run) or !std.mem.eql(u8, record.invoker, self.invoker_id) or !job.validId(record.epoch)) return error.ClaimIntentMismatch;
        return record;
    }

    pub fn loadTicket(self: Service, run: []const u8) !Ticket {
        if (!job.validId(run)) return error.ClaimIntentMismatch;
        const path = try std.fmt.allocPrint(self.allocator, "claim-intents/pin-{s}", .{run});
        const saved = try self.state.readFileAlloc(self.io, path, self.allocator, .limited(2048));
        return std.json.parseFromSliceLeaky(Ticket, self.allocator, saved, .{});
    }

    /// Recover just this run's artifact into its first event before producing scores.
    pub fn recordArtifact(self: Service, journal: *upload.Journal, events: *outbox.Outbox, pending: upload.Pending) !void {
        const payloads = try std.fs.path.join(self.allocator, &.{ self.root, "upload-spool" });
        try self.recoverEntry(journal, events, payloads, pending);
    }

    fn claimAssigned(self: Service, assignment: job.Job, process_epoch: []const u8, pin_only: bool) !rpc.Claim {
        const a = self.allocator;
        const io = self.io;
        const intent_path = try std.fs.path.join(a, &.{ self.root, "claim-intents" });
        const intents = try spool.openLocked(io, intent_path);
        defer intents.close(io);
        // Persist the Claim request epoch before the first RPC. An ambiguous
        // response or restart must retry with the same epoch, never reclaim.
        const proposed = try std.json.Stringify.valueAlloc(a, .{ .epoch = process_epoch, .job = assignment, .invoker = self.invoker_id }, .{});
        var intent = try intents.createFileAtomic(io, assignment.run_id, .{ .permissions = .fromMode(0o600) });
        defer intent.deinit(io);
        try intent.file.writeStreamingAll(io, proposed);
        try intent.file.sync(io);
        intent.link(io) catch |err| if (err != error.PathAlreadyExists) return err;
        try sync(intents);
        const saved = try intents.readFileAlloc(io, assignment.run_id, a, .limited(16 << 10));
        const record = try std.json.parseFromSliceLeaky(ClaimIntent, a, saved, .{});
        if (!std.meta.eql(record.job, assignment) or !std.mem.eql(u8, record.invoker, self.invoker_id)) {
            const expected = try std.json.Stringify.valueAlloc(a, assignment, .{});
            const previous = try std.json.Stringify.valueAlloc(a, record.job, .{});
            if (!std.mem.eql(u8, expected, previous) or !std.mem.eql(u8, record.invoker, self.invoker_id)) return error.ClaimIntentMismatch;
        }
        var identity: rpc.Identity = .{ .invoker = try a.dupeSentinel(u8, self.invoker_id, 0), .epoch = try a.dupeSentinel(u8, record.epoch, 0), .attempt = try a.dupeSentinel(u8, assignment.judging_attempt_id, 0), .run = try a.dupeSentinel(u8, assignment.run_id, 0) };
        var claim: rpc.Claim = undefined;
        try self.channel.claim(&identity, false, &claim);
        identity.token = claim.token;
        var guard = try lease.Guard.init(.{ .invoker_id = self.invoker_id, .process_epoch = record.epoch, .attempt_id = assignment.judging_attempt_id, .run_id = assignment.run_id, .token = &identity.token }, claim.expires, now(io));
        const name = try std.fmt.allocPrint(a, "lease-{s}", .{assignment.run_id});
        const pinned = claim.artifacts();
        const ticket = try std.json.Stringify.valueAlloc(a, Ticket{
            .invoker_id = self.invoker_id,
            .epoch = record.epoch,
            .attempt_id = assignment.judging_attempt_id,
            .submission_id = assignment.submission_id,
            .token = claim.token,
            .source = pinned.source.descriptor,
            .bundle = pinned.bundle.descriptor,
        }, .{});
        const pin_name = try std.fmt.allocPrint(a, "pin-{s}", .{assignment.run_id});
        var pin = try intents.createFileAtomic(io, pin_name, .{ .permissions = .fromMode(0o600) });
        defer pin.deinit(io);
        try pin.file.writeStreamingAll(io, ticket);
        try pin.file.sync(io);
        pin.link(io) catch |err| if (err != error.PathAlreadyExists) return err;
        try sync(intents);
        if (!std.mem.eql(u8, ticket, try intents.readFileAlloc(io, pin_name, a, .limited(2048)))) return error.PinnedInputsChanged;
        if (pin_only) {
            const lease_name = try std.fmt.allocPrint(a, "expires-{s}", .{assignment.run_id});
            const expires = try std.fmt.allocPrint(a, "{d}", .{claim.expires});
            var file = try intents.createFileAtomic(io, lease_name, .{ .permissions = .fromMode(0o600), .replace = true });
            defer file.deinit(io);
            try file.file.writeStreamingAll(io, expires);
            try file.file.sync(io);
            try file.replace(io);
            try sync(intents);
            return claim;
        }
        const spool_parent = try spool.openLocked(io, try std.fs.path.join(a, &.{ self.root, "input-spool" }));
        defer spool_parent.close(io);
        spool_parent.createDir(io, assignment.run_id, .fromMode(0o700)) catch |err| if (err != error.PathAlreadyExists) return err;
        const run_spool = try std.fs.path.join(a, &.{ self.root, "input-spool", assignment.run_id });
        const workspace = try self.state.openDir(io, "workspaces", .{ .iterate = true, .follow_symlinks = false });
        defer workspace.close(io);
        if (intents.readFileAlloc(io, name, a, .limited(2048))) |existing| {
            if (!std.mem.eql(u8, existing, ticket)) return error.ClaimIntentMismatch;
            const dir = try workspace.openDir(io, assignment.run_id, .{ .follow_symlinks = false });
            dir.close(io);
            try spool_parent.deleteTree(io, assignment.run_id);
            try sync(spool_parent);
            if (!guard.active(now(io))) return error.LeaseInactive;
            return claim;
        } else |err| if (err != error.FileNotFound) return err;
        // A previous process may have published the workspace but not its
        // ticket. It was never handed off; discard it and verify both inputs.
        try workspace.deleteTree(io, assignment.run_id);
        var current = pinned;
        var refreshed: rpc.Claim = undefined;
        for (0..3) |attempt| {
            if (!guard.active(now(io))) return error.LeaseInactive;
            if (guard.deadline_ns - now(io).monotonic_ns <= 30 * std.time.ns_per_s) {
                const renewed = try self.channel.renew(&identity);
                if (renewed.cancel_requested != 0) return error.RunCancellationRequested;
                const expires = renewed.expires;
                const received = now(io);
                if (!guard.active(received)) return error.LeaseInactive;
                if (expires < guard.expires_unix) return error.NonAdvancingRenewal;
                if (expires > guard.expires_unix) {
                    try guard.renew(guard.identity, expires, received);
                    claim.expires = expires;
                }
            }
            const time_left = @divFloor(guard.deadline_ns - now(io).monotonic_ns, std.time.ns_per_ms);
            if (time_left <= 0) return error.LeaseInactive;
            var options = self.options;
            options.timeout_ms = @intCast(@min(time_left, options.timeout_ms));
            try spool.remove(io, run_spool, "bundle.tar");
            try spool.remove(io, run_spool, "source.bin");
            const result = inputs.prepare(io, a, run_spool, .{ .bytes = 512 << 20, .files = 2 }, workspace, assignment.run_id, .{ .entries = 16384, .archive_bytes = 256 << 20, .unpacked_bytes = 512 << 20, .depth = 32, .path_bytes = 256 }, @tagName(assignment.execution_format), assignment.execution_format_version, current, options);
            if (result) |_| {
                try spool_parent.deleteTree(io, assignment.run_id);
                try sync(spool_parent);
                if (!guard.active(now(io))) {
                    try workspace.deleteTree(io, assignment.run_id);
                    try sync(workspace);
                    return error.LeaseInactive;
                }
                var file = try intents.createFileAtomic(io, name, .{ .permissions = .fromMode(0o600) });
                defer file.deinit(io);
                try file.file.writeStreamingAll(io, ticket);
                try file.file.sync(io);
                try file.link(io);
                try sync(intents);
                return claim;
            } else |err| switch (err) {
                error.ArtifactHttpRejected, error.ArtifactTimeout, error.ArtifactTransientFailure => if (attempt == 2) return err,
                else => return err,
            }
            try self.channel.claim(&identity, true, &refreshed);
            if (!std.mem.eql(u8, &identity.token, &refreshed.token)) return error.LeaseIdentityMismatch;
            current = try pinned.withRefreshedUrls(refreshed.artifacts());
        }
        unreachable;
    }

    /// A trusted result producer hands off a closed file, never a workload path.
    pub fn stage(self: Service, run: []const u8, client: []const u8, kind: []const u8, path: []const u8) !void {
        if (!job.validId(run) or !job.validId(client)) return error.InvalidArtifactIdentity;
        var supported = false;
        for ([_][]const u8{ "build_log", "runner_log", "test_io", "custom", "metrics" }) |s| supported = supported or std.mem.eql(u8, kind, s);
        if (!supported) return error.InvalidArtifactKind;
        const a = self.allocator;
        const io = self.io;
        const intents = try spool.openLocked(io, try std.fs.path.join(a, &.{ self.root, "claim-intents" }));
        defer intents.close(io);
        const name = try std.fmt.allocPrint(a, "lease-{s}", .{run});
        const saved = try intents.readFileAlloc(io, name, a, .limited(2048));
        const ticket = try std.json.parseFromSliceLeaky(Ticket, a, saved, .{});
        if (!std.mem.eql(u8, ticket.invoker_id, self.invoker_id)) return error.ClaimIntentMismatch;
        const f = try std.Io.Dir.cwd().openFile(io, path, .{ .follow_symlinks = false });
        defer f.close(io);
        const stat = try f.stat(io);
        if (stat.kind != .file or stat.size > 256 << 20) return error.InvalidArtifactFile;
        var journal = try upload.Journal.open(io, try std.fs.path.join(a, &.{ self.root, "upload-journal" }));
        defer journal.close();
        const payloads = try std.fs.path.join(a, &.{ self.root, "upload-spool" });
        // Hash first so the immutable intent can precede publication of the
        // payload. A crash here can be retried with the same ID and bytes.
        var buffer: [32768]u8 = undefined;
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        var offset: u64 = 0;
        while (offset < stat.size) {
            const n = try f.readPositional(io, &.{buffer[0..@intCast(@min(stat.size - offset, buffer.len))]}, offset);
            if (n == 0) return error.InvalidArtifactFile;
            hash.update(buffer[0..n]);
            offset += n;
        }
        const pending: upload.Pending = .{ .invoker_id = self.invoker_id, .process_epoch = ticket.epoch, .attempt_id = ticket.attempt_id, .run_id = run, .fencing_token = ticket.token, .client_id = client, .kind = kind, .descriptor = .{ .bytes = stat.size, .sha256 = hash.finalResult() } };
        journal.save(pending) catch |err| {
            if (err != error.PathAlreadyExists) return err;
            const existing = try journal.load(a, client);
            defer existing.deinit();
            if (!std.mem.eql(u8, try std.json.Stringify.valueAlloc(a, pending, .{}), try std.json.Stringify.valueAlloc(a, existing.value, .{}))) return error.UploadIntentMismatch;
            if (journal.confirmed(a, client)) |receipt| {
                a.free(receipt);
                return;
            } else |receipt_err| if (receipt_err != error.FileNotFound) return receipt_err;
        };
        var reader = f.reader(io, &buffer);
        try spool.stageExpected(io, payloads, .{ .bytes = 512 << 20, .files = 512 }, client, pending.descriptor, &reader.interface);
    }
};

pub fn now(io: std.Io) lease.Time {
    return .{ .unix_seconds = std.Io.Clock.real.now(io).toSeconds(), .monotonic_ns = std.Io.Clock.awake.now(io).nanoseconds };
}

fn secureDirectory(dir: std.Io.Dir) !void {
    const linux = std.os.linux;
    var stat: linux.Statx = undefined;
    if (linux.errno(linux.statx(dir.handle, "", linux.AT.EMPTY_PATH, .{ .MODE = true, .UID = true }, &stat)) != .SUCCESS or
        !stat.mask.MODE or !stat.mask.UID or stat.uid != linux.geteuid() or stat.mode & 0o077 != 0) return error.UnsafeArtifactDirectory;
}

pub fn sync(dir: std.Io.Dir) !void {
    const linux = std.os.linux;
    while (true) switch (linux.errno(linux.fsync(dir.handle))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return error.ArtifactStateSyncFailed,
    };
}

fn setting(init: std.process.Init, name: []const u8) ![:0]const u8 {
    const value = init.environ_map.get(name) orelse return error.MissingArtifactControlSetting;
    if (value.len == 0) return error.MissingArtifactControlSetting;
    return init.arena.allocator().dupeSentinel(u8, value, 0);
}

fn pem(init: std.process.Init, name: []const u8) ![:0]const u8 {
    const path = try setting(init, name);
    const a = init.arena.allocator();
    const data = try std.Io.Dir.cwd().readFileAlloc(init.io, path, a, .limited(128 << 10));
    if (data.len == 0 or std.mem.indexOfScalar(u8, data, 0) != null) return error.InvalidControlPEM;
    return a.dupeSentinel(u8, data, 0);
}
