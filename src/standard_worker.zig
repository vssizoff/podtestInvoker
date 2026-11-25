//! Opt-in single-slot queue consumer. The installed diagnostics unit does not use it.
const std = @import("std");
const linux = std.os.linux;
const nats = @import("nats");
const podman = @import("podman");
const janitor = @import("janitor");
const core = @import("core.zig");
const job = @import("control/job.zig");
const lease = @import("control/lease.zig");
const delivery = @import("control/delivery.zig");
const rpc = @import("control/artifact_rpc.zig");
const Consumer = @import("control/jetstream.zig").Consumer;
const phase3 = @import("phase3.zig");
const Service = phase3.Service;
const executor = @import("standard/executor.zig");
const report = @import("standard/report.zig");
const Result = @import("standard/result.zig").Result;
const Journal = @import("workspace/upload.zig").Journal;
const Outbox = @import("control/outbox.zig").Outbox;

extern fn podtest_has_disk_space(fd: c_int) c_int;

pub fn run(init: std.process.Init, config: core.Config, journal: janitor.Journal, client: podman.Client, signals: c_int, once: bool) !void {
    var service = try Service.open(init, config.state_dir, config.invoker_id);
    defer service.close();
    try service.cleanInterruptedInputs();
    const io = init.io;
    service.state.createDir(io, "standard-runs", .fromMode(0o700)) catch |err| if (err != error.PathAlreadyExists) return err;
    try phase3.sync(service.state);
    const outputs = try service.state.openDir(io, "standard-runs", .{ .iterate = true, .follow_symlinks = false });
    defer outputs.close(io);
    const a = service.allocator;
    const invoker = try a.dupeSentinel(u8, config.invoker_id, 0);
    if (!job.validId(invoker)) return error.InvalidInvokerId;
    if (podtest_has_disk_space(service.state.handle) != 1) return error.InsufficientWorkerDisk;
    const images: executor.Images = .{
        .posix_sh = try imageId(init.environ_map.get("PODTEST_STANDARD_SH_IMAGE_ID")),
        .javascript = try imageId(init.environ_map.get("PODTEST_STANDARD_JS_IMAGE_ID")),
        .testlib = try imageId(init.environ_map.get("PODTEST_TESTLIB_IMAGE_ID")),
        .cpp23 = try imageId(init.environ_map.get("PODTEST_STANDARD_CPP23_IMAGE_ID")),
        .python314 = try imageId(init.environ_map.get("PODTEST_STANDARD_PYTHON314_IMAGE_ID")),
    };
    if (images.posix_sh == null and images.javascript == null and images.cpp23 == null and images.python314 == null) return error.StandardImagesNotConfigured;
    // Backend currently schedules by execution format, so a persistent worker
    // has to support the baseline languages published as Standard v1.
    if (!once and (images.posix_sh == null or images.javascript == null)) return error.StandardImagesNotConfigured;
    const buffer = try a.alloc(u8, 128 << 10);
    const Info = struct { host: struct { security: struct { rootless: bool } } };
    const info = try std.json.parseFromSliceLeaky(Info, a, try client.info(buffer), .{ .ignore_unknown_fields = true });
    if (!info.host.security.rootless) return error.RootlessRequired;
    if (images.posix_sh) |image| try validateImage(a, client, image, buffer);
    if (images.javascript) |image| try validateImage(a, client, image, buffer);
    if (images.testlib) |image| try validateImage(a, client, image, buffer);
    if (images.cpp23) |image| try validateImage(a, client, image, buffer);
    if (images.python314) |image| try validateImage(a, client, image, buffer);

    var handler: Handler = .{ .service = service, .journal = journal, .client = client, .signals = signals, .outputs = outputs, .images = images, .timeout = config.run_timeout_seconds };
    // A previous process may have received the JetStream ACK or the terminal
    // Report ACK without recording the corresponding local progress.
    while (try handler.recover()) {
        if (once or stopping(signals)) return;
    }
    const url = init.environ_map.get("PODTEST_NATS_URL") orelse return error.MissingNatsUrl;
    const connection = try nats.Client.connect(init.gpa, io, url, .{});
    defer connection.deinit();
    var js = try nats.jetstream.JetStream.init(connection, .{});
    var consumer = try Consumer.bind(&js, "PODTEST_JUDGING", "podtest-standard", "podtest.judging.jobs.v1");
    defer service.heartbeat() catch |err| std.log.warn("withdrawing Standard capacity: {s}", .{@errorName(err)});
    var heartbeat_at: i128 = 0;
    while (!stopping(signals)) {
        if (podtest_has_disk_space(service.state.handle) != 1) return error.InsufficientWorkerDisk;
        const stamp = phase3.now(io).monotonic_ns;
        if (heartbeat_at == 0 or stamp >= heartbeat_at) {
            try service.channel.heartbeat(invoker, 1, 0, "standard");
            heartbeat_at = stamp + 5 * std.time.ns_per_s;
        }
        var arena = std.heap.ArenaAllocator.init(init.gpa);
        defer arena.deinit();
        handler.service.allocator = arena.allocator();
        const outcome = try consumer.step(init.gpa, io, .{ .free_slots = 1, .podman_available = true, .disk_available = true }, &handler);
        if (outcome == .started) {
            if (once or stopping(signals)) return;
            // Execution is serial, so no resources owned by this process are
            // live here. Sweep under the same instance lock before pulling.
            var idle_journal = journal;
            idle_journal.epoch = "";
            const cleanup = idle_journal.sweep(init.gpa, client, signals) catch |err| switch (err) {
                error.ContainerSweepInterrupted => return,
                else => return err,
            };
            if (cleanup.rejected != 0 or cleanup.unresolved != 0) return error.ContainerRecoveryPending;
            heartbeat_at = 0;
        }
    }
}

const Handler = struct {
    service: Service,
    journal: janitor.Journal,
    client: podman.Client,
    signals: c_int,
    outputs: std.Io.Dir,
    images: executor.Images,
    timeout: u32,
    token: [32]u8 = undefined,

    pub fn claim(self: *Handler, assignment: job.Job) !delivery.Claim {
        if (assignment.execution_format != .standard) return .retry;
        const grant = self.service.pinAssigned(assignment, self.journal.epoch) catch |err| switch (err) {
            error.ControlRetry => return .retry,
            error.LeaseInactive => return .stale,
            else => return err,
        };
        self.token = grant.token;
        return .{ .granted = .{ .fencing_token = &self.token, .expires_unix = grant.expires } };
    }

    pub fn persist(_: *Handler, _: job.Job, _: delivery.Lease) !void {} // Claim fsynced the intent and grant.

    pub fn start(self: *Handler, assignment: job.Job, _: delivery.Lease) !void {
        // The assignment itself occupies the sole Backend slot. Even if the
        // capacity withdrawal times out, handle the already-ACKed job.
        self.service.heartbeat() catch |err| std.log.warn("withdrawing Standard capacity: {s}", .{@errorName(err)});
        try self.execute(assignment);
    }

    fn recover(self: *Handler) !bool {
        const io = self.service.io;
        const intents = try self.service.state.openDir(io, "claim-intents", .{ .iterate = true, .follow_symlinks = false });
        defer intents.close(io);
        var it = intents.iterate();
        while (try it.next(io)) |entry| {
            if (!std.mem.startsWith(u8, entry.name, "pin-")) continue;
            const run_id = entry.name[4..];
            if (!job.validId(run_id)) return error.ClaimIntentMismatch;
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            var worker = self.*;
            worker.service.allocator = arena.allocator();
            const record = try worker.service.loadClaim(run_id);
            if (record.job.execution_format != .standard) continue;
            if (try worker.hasMarker(run_id, "done")) continue;
            worker.execute(record.job) catch |err| switch (err) {
                error.LeaseInactive, error.LeaseExpired => continue,
                else => return err,
            };
            return true;
        }
        return false;
    }

    fn hasMarker(self: Handler, run_id: []const u8, marker: []const u8) !bool {
        const path = try std.fmt.allocPrint(self.service.allocator, "{s}/{s}", .{ run_id, marker });
        return exists(self.service.io, self.outputs, path);
    }

    fn execute(self: *Handler, assignment: job.Job) !void {
        const svc = self.service;
        const io = svc.io;
        const a = svc.allocator;
        const run_id = assignment.run_id;
        if (stopping(self.signals)) return error.WorkerStopping;
        self.outputs.createDir(io, run_id, .fromMode(0o700)) catch |err| if (err != error.PathAlreadyExists) return err;
        try phase3.sync(self.outputs);
        const dir = try self.outputs.openDir(io, run_id, .{ .iterate = true, .follow_symlinks = false });
        defer dir.close(io);
        if (try exists(io, dir, "done")) return;
        var box = try Outbox.open(io, svc.root, 64 << 20);
        defer box.close();
        if (try exists(io, dir, "report-ready")) {
            try box.flushRun(a, run_id, svc.channel);
        } else {
            const record = try svc.loadClaim(run_id);
            const grant = try svc.pinAssigned(assignment, record.epoch);
            const ticket = try svc.loadTicket(run_id);
            var control = try Supervisor.init(self.*, ticket, run_id, grant.expires);
            if (!(try exists(io, dir, "execution/result.json"))) {
                try svc.prepare(assignment, record.epoch);
                // An interrupted executor cannot have produced artifact intents
                // until result.json exists. Its private output can be rebuilt.
                try dir.deleteTree(io, "execution");
                try dir.createDir(io, "execution", .fromMode(0o700));
                try phase3.sync(dir);
                const execution = try dir.openDir(io, "execution", .{ .iterate = true, .follow_symlinks = false });
                defer execution.close(io);
                const workspace_path = try std.fmt.allocPrint(a, "workspaces/{s}", .{run_id});
                const workspace = try svc.state.openDir(io, workspace_path, .{ .follow_symlinks = false });
                defer workspace.close(io);
                try control.checkpoint();
                executor.runSelected(a, io, self.client, workspace, execution, self.images, assignment.language, .{ .check = Supervisor.cancelled, .context = &control }, .{ .journal = self.journal, .run_id = run_id }) catch |err| return control.failure orelse err;
            }
            try control.checkpoint();
            const log_path = try std.fs.path.join(a, &.{ svc.root, "standard-runs", run_id, "execution", "build.log" });
            try svc.stage(run_id, run_id, "build_log", log_path);
            var uploads = try Journal.open(io, try std.fs.path.join(a, &.{ svc.root, "upload-journal" }));
            defer uploads.close();
            const pending = try uploads.load(a, run_id);
            defer pending.deinit();
            try svc.recordArtifact(&uploads, &box, pending.value);
            const result_bytes = try dir.readFileAlloc(io, "execution/result.json", a, .limited(256 << 10));
            const result = try std.json.parseFromSliceLeaky(Result, a, result_bytes, .{});
            const submission = try a.dupeSentinel(u8, ticket.submission_id, 0);
            try report.enqueue(&box, a, &uploads, pending.value, &.{run_id}, submission, @intCast(std.Io.Clock.real.now(io).toMilliseconds()), 2, result);
            try mark(io, dir, "report-ready");
            try box.flushRun(a, run_id, &control);
        }
        try mark(io, dir, "done");
        try box.compact(a);
    }
};

const Supervisor = struct {
    io: std.Io,
    channel: rpc.Channel,
    identity: rpc.Identity,
    guard: lease.Guard,
    signals: c_int,
    timeout_at: i128,
    renew_at: i128,
    failure: ?anyerror = null,

    fn init(worker: Handler, ticket: Service.Ticket, run_id: []const u8, expires: i64) !Supervisor {
        const a = worker.service.allocator;
        const now = phase3.now(worker.service.io);
        // Keep the guard's token in separately owned storage across return by value.
        const token = try a.dupe(u8, &ticket.token);
        return .{
            .io = worker.service.io,
            .channel = worker.service.channel,
            .identity = .{ .invoker = try a.dupeSentinel(u8, ticket.invoker_id, 0), .epoch = try a.dupeSentinel(u8, ticket.epoch, 0), .attempt = try a.dupeSentinel(u8, ticket.attempt_id, 0), .run = try a.dupeSentinel(u8, run_id, 0), .token = ticket.token },
            .guard = try lease.Guard.init(.{ .invoker_id = ticket.invoker_id, .process_epoch = ticket.epoch, .attempt_id = ticket.attempt_id, .run_id = run_id, .token = token }, expires, now),
            .signals = worker.signals,
            .timeout_at = now.monotonic_ns + @as(i128, worker.timeout) * std.time.ns_per_s,
            .renew_at = now.monotonic_ns,
        };
    }

    fn checkpoint(self: *Supervisor) !void {
        const now = phase3.now(self.io);
        if (stopping(self.signals)) return error.WorkerStopping;
        if (now.monotonic_ns >= self.timeout_at) return error.StandardRunTimeout;
        if (!self.guard.active(now)) return error.LeaseInactive;
        if (now.monotonic_ns < self.renew_at and self.guard.deadline_ns - now.monotonic_ns > 15 * std.time.ns_per_s) return;
        const expires = try self.channel.renew(&self.identity);
        const received = phase3.now(self.io);
        if (!self.guard.active(received)) return error.LeaseInactive;
        if (expires > self.guard.expires_unix) try self.guard.renew(self.guard.identity, expires, received);
        if (expires < self.guard.expires_unix or self.guard.deadline_ns - received.monotonic_ns <= 15 * std.time.ns_per_s) return error.LeaseInactive;
        if (received.monotonic_ns >= self.timeout_at) return error.StandardRunTimeout;
        if (stopping(self.signals)) return error.WorkerStopping;
        self.renew_at = now.monotonic_ns + 5 * std.time.ns_per_s;
    }

    fn cancelled(context: *anyopaque) bool {
        const self: *Supervisor = @ptrCast(@alignCast(context));
        if (self.failure != null) return true;
        self.checkpoint() catch |err| {
            self.failure = err;
            return true;
        };
        return false;
    }

    pub fn report(self: *Supervisor, wire: []const u8) !void {
        try self.checkpoint();
        try self.channel.report(wire);
    }
};

fn exists(io: std.Io, dir: std.Io.Dir, path: []const u8) !bool {
    const file = dir.openFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close(io);
    if ((try file.stat(io)).kind != .file) return error.InvalidStandardState;
    return true;
}

fn mark(io: std.Io, dir: std.Io.Dir, name: []const u8) !void {
    var file = try dir.createFileAtomic(io, name, .{ .permissions = .fromMode(0o600) });
    defer file.deinit(io);
    try file.file.sync(io);
    try file.link(io);
    try phase3.sync(dir);
}

fn imageId(value: ?[]const u8) !?podman.Id {
    const id = value orelse return null;
    if (id.len != 64) return error.InvalidStandardImageId;
    for (id) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return error.InvalidStandardImageId;
    return id[0..64].*;
}

fn validateImage(a: std.mem.Allocator, client: podman.Client, image: podman.Id, buffer: []u8) !void {
    const Image = struct { Config: struct { OnBuild: ?[][]const u8 = null } };
    const metadata = try std.json.parseFromSliceLeaky(Image, a, try client.inspectImage(image, buffer), .{ .ignore_unknown_fields = true });
    if (metadata.Config.OnBuild) |triggers| if (triggers.len != 0) return error.UnsupportedImageOnBuild;
}

fn stopping(fd: c_int) bool {
    var fds = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
    return linux.poll(&fds, fds.len, 0) != 0;
}
