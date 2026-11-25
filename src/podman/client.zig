const std = @import("std");
const resource = @import("resource");

pub const Client = struct {
    socket: [:0]const u8,
    api_version: [:0]const u8,

    pub fn ping(self: Client) !void {
        var length: usize = 0;
        try status(podtest_podman_request(self.socket, self.api_version, "GET", "/_ping", null, 0, null, &length, 3000, null, null, null, null, null));
    }

    pub fn inspectVersion(self: Client, out: []u8) ![]u8 {
        var length = out.len;
        try status(podtest_podman_request(self.socket, self.api_version, "GET", "/version", null, 0, out.ptr, &length, 5000, null, null, null, null, null));
        return out[0..length];
    }

    pub fn info(self: Client, out: []u8) ![]u8 {
        return self.request("GET", "/info", null, out, 5000);
    }

    /// Only for trusted fixture contexts. Offline RUN is not an egress policy for arbitrary Dockerfiles.
    pub fn buildTrusted(self: Client, a: std.mem.Allocator, files: []const ContextFile, tag: []const u8, timeout_ms: u32, sink: *const fn (*anyopaque, []const u8) anyerror!void, sink_context: *anyopaque, cancellation: Cancellation) !Id {
        if (!validTag(tag) or timeout_ms == 0) return error.PodmanInvalidRequest;
        if (cancellation.check(cancellation.context)) return error.PodmanCancelled;
        for (files) |file| {
            if (std.mem.eql(u8, file.path, "Dockerfile")) break;
        } else return error.BuildfileNotFound;
        const tar = try packContext(a, files);
        defer a.free(tar);
        const out = try a.alloc(u8, 128 << 10);
        defer a.free(out);
        if (self.inspectTag(a, tag, out)) |_| return error.PodmanConflict else |err| if (err != error.PodmanNotFound) return err;
        var path_buf: [512]u8 = undefined;
        const path = try std.fmt.bufPrintSentinel(&path_buf, "/build?t=localhost%2F{s}%3A{s}&dockerfile=Dockerfile&pullpolicy=never&networkmode=none&forcerm=true&rm=true&nocache=true&memory=268435456&memswap=268435456&cpuquota=100000&cpuperiod=100000&httpproxy=false", .{ tag, tagVersion(tag) }, 0);
        var capture = BuildCapture{ .allocator = a, .sink = sink, .context = sink_context };
        defer capture.line.deinit(a);
        var cancel = cancellation;
        const rc = podtest_podman_request(self.socket, self.api_version, "POST", path, tar.ptr, tar.len, null, null, timeout_ms, buildSink, &capture, "Content-Type: application/x-tar", Cancellation.poll, &cancel);
        if (capture.failure) |err| return err;
        try status(rc);
        if (capture.line.items.len != 0) return error.PodmanProtocol;
        return self.inspectTag(a, tag, out);
    }

    fn buildSink(context: ?*anyopaque, data: [*]const u8, length: usize) callconv(.c) c_int {
        const capture: *BuildCapture = @ptrCast(@alignCast(context.?));
        return capture.consume(data[0..length]) catch |err| {
            capture.failure = err;
            return 1;
        };
    }

    const BuildCapture = struct {
        allocator: std.mem.Allocator,
        sink: *const fn (*anyopaque, []const u8) anyerror!void,
        context: *anyopaque,
        line: std.ArrayList(u8) = .empty,
        failure: ?anyerror = null,
        remaining: usize = 8 << 20,

        fn consume(self: *BuildCapture, bytes: []const u8) !c_int {
            if (bytes.len > self.remaining) return error.PodmanBuildOutputLimit;
            self.remaining -= bytes.len;
            for (bytes) |byte| {
                if (byte == '\n') {
                    try self.consumeLine(self.line.items);
                    self.line.clearRetainingCapacity();
                } else {
                    if (self.line.items.len >= 65536) return error.PodmanBuildLineTooLong;
                    try self.line.append(self.allocator, byte);
                }
            }
            return 0;
        }

        fn consumeLine(self: *BuildCapture, line: []const u8) !void {
            if (line.len == 0) return;
            const Message = struct { stream: ?[]const u8 = null, @"error": ?[]const u8 = null, errorDetail: ?struct { message: []const u8 } = null };
            const parsed = std.json.parseFromSlice(Message, self.allocator, line, .{ .ignore_unknown_fields = true }) catch return error.PodmanProtocol;
            defer parsed.deinit();
            if (parsed.value.@"error" orelse if (parsed.value.errorDetail) |detail| detail.message else null) |message| {
                try self.sink(self.context, message);
                return error.PodmanBuildFailed;
            }
            if (parsed.value.stream) |text| try self.sink(self.context, text);
        }
    };

    pub fn inspectTag(self: Client, a: std.mem.Allocator, tag: []const u8, out: []u8) !Id {
        const bytes = try self.inspectTagMetadata(tag, out);
        const parsed = try std.json.parseFromSlice(struct { Id: []const u8 }, a, bytes, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const raw = if (std.mem.startsWith(u8, parsed.value.Id, "sha256:")) parsed.value.Id[7..] else parsed.value.Id;
        if (raw.len != 64) return error.PodmanProtocol;
        const id = raw[0..64].*;
        try validateId(id);
        return id;
    }

    pub fn inspectTagMetadata(self: Client, tag: []const u8, out: []u8) ![]u8 {
        var buf: [160]u8 = undefined;
        return self.request("GET", try tagPath(&buf, tag, "/json"), null, out, 5000);
    }

    pub fn removeTag(self: Client, tag: []const u8, out: []u8) !void {
        var buf: [160]u8 = undefined;
        _ = try self.request("DELETE", try tagPath(&buf, tag, "?force=false"), null, out, 10000);
    }

    fn request(self: Client, method: [*:0]const u8, path: [*:0]const u8, body: ?[]const u8, out: []u8, timeout_ms: u32) ![]u8 {
        var length = out.len;
        const bytes = if (body) |value| value.ptr else null;
        const count = if (body) |value| value.len else 0;
        try status(podtest_podman_request(self.socket, self.api_version, method, path, bytes, count, out.ptr, &length, timeout_ms, null, null, null, null, null));
        return out[0..length];
    }

    fn cSink(context: ?*anyopaque, data: [*]const u8, length: usize) callconv(.c) c_int {
        const state: *SinkContext = @ptrCast(@alignCast(context.?));
        state.callback(state.user, data[0..length]) catch return 1;
        return 0;
    }

    const SinkContext = struct { callback: *const fn (*anyopaque, []const u8) anyerror!void, user: *anyopaque };

    pub fn logs(self: Client, id: Id, timeout_ms: u32, sink: *const fn (*anyopaque, []const u8) anyerror!void, context: *anyopaque) !void {
        var state = SinkContext{ .callback = sink, .user = context };
        var buf: [160]u8 = undefined;
        const path = try containerPath(&buf, id, "/logs?stdout=true&stderr=true&follow=false");
        try status(podtest_podman_request(self.socket, self.api_version, "GET", path, null, 0, null, null, timeout_ms, cSink, &state, null, null, null));
    }

    pub fn create(self: Client, a: std.mem.Allocator, spec: ContainerSpec) !Id {
        return self.createWithLimits(a, spec, .{});
    }

    pub fn createWithLimits(self: Client, a: std.mem.Allocator, spec: ContainerSpec, limits: resource.Request) !Id {
        const policy = try resource.Policy.resolve(limits, .{});
        try validateSpec(spec);
        const body = try std.json.Stringify.valueAlloc(a, .{
            .name = spec.name,
            .image = &spec.image,
            .command = spec.command,
            .entrypoint = &[_][]const u8{},
            .netns = .{ .nsmode = "none" },
            .pidns = .{ .nsmode = "private" },
            .ipcns = .{ .nsmode = "private" },
            .user = "65534:65534",
            .privileged = false,
            .no_new_privileges = true,
            .cap_drop = &[_][]const u8{"ALL"},
            .read_only_filesystem = true,
            .read_write_tmpfs = false,
            .mounts = if (spec.scratch) &scratch_mount else &no_mounts,
            .image_volume_mode = "ignore",
            .http_proxy = false,
            .stdin = spec.stdin,
            .terminal = false,
            .labels = spec.labels,
            .log_configuration = .{ .driver = if (spec.live_io) "none" else "k8s-file", .size = @as(i64, 1 << 20) },
            .resource_limits = .{
                .memory = .{ .limit = policy.memory_bytes, .swap = policy.memory_bytes + policy.swap_bytes },
                .pids = .{ .limit = policy.pids },
                .cpu = .{ .quota = policy.cpu_quota_micros, .period = @as(u64, 100_000) },
            },
        }, .{});
        defer a.free(body);
        var out: [4096]u8 = undefined;
        const bytes = try self.request("POST", "/containers/create", body, &out, 30000);
        const decoded = try std.json.parseFromSlice(struct { Id: []const u8 }, a, bytes, .{ .ignore_unknown_fields = true });
        defer decoded.deinit();
        if (decoded.value.Id.len != 64) return error.PodmanProtocol;
        const id: Id = decoded.value.Id[0..64].*;
        try validateId(id);
        return id;
    }

    pub fn createNetwork(self: Client, a: std.mem.Allocator, name: []const u8, run_id: []const u8, out: []u8) !Id {
        return self.createNetworkWithLabels(a, name, run_id, null, out);
    }

    pub fn createNetworkWithLabels(self: Client, a: std.mem.Allocator, name: []const u8, run_id: []const u8, labels: ?ContainerLabels, out: []u8) !Id {
        if (!validName(name) or !validName(run_id)) return error.PodmanInvalidRequest;
        const body = try std.json.Stringify.valueAlloc(a, .{
            .name = name,
            .driver = "bridge",
            .internal = true,
            .dns_enabled = false,
            .labels = labels orelse ContainerLabels{ .@"podtest.invoker_id" = "", .@"podtest.process_epoch" = "", .@"podtest.run_id" = run_id, .@"podtest.resource_kind" = "network", .@"podtest.journal_id" = "" },
        }, .{});
        defer a.free(body);
        const bytes = try self.request("POST", "/networks/create", body, out, 30000);
        const Response = struct { id: []const u8 };
        const decoded = try std.json.parseFromSlice(Response, a, bytes, .{ .ignore_unknown_fields = true });
        defer decoded.deinit();
        if (decoded.value.id.len != 64) return error.PodmanProtocol;
        const id: Id = decoded.value.id[0..64].*;
        try validateId(id);
        return id;
    }

    pub fn removeNetwork(self: Client, id: Id) !void {
        try validateId(id);
        var path: [128]u8 = undefined;
        const endpoint = try std.fmt.bufPrintSentinel(&path, "/networks/{s}", .{&id}, 0);
        try status(podtest_podman_request(self.socket, self.api_version, "DELETE", endpoint, null, 0, null, null, 10000, null, null, null, null, null));
    }

    pub fn inspectNetwork(self: Client, id: Id, out: []u8) ![]u8 {
        try validateId(id);
        var path: [128]u8 = undefined;
        const endpoint = try std.fmt.bufPrintSentinel(&path, "/networks/{s}/json", .{&id}, 0);
        return self.request("GET", endpoint, null, out, 5000);
    }

    pub fn inspectNetworkName(self: Client, name: []const u8, out: []u8) ![]u8 {
        if (!validName(name)) return error.PodmanInvalidRequest;
        var path: [128]u8 = undefined;
        const endpoint = try std.fmt.bufPrintSentinel(&path, "/networks/{s}/json", .{name}, 0);
        return self.request("GET", endpoint, null, out, 5000);
    }

    pub fn inspect(self: Client, id: Id, out: []u8) ![]u8 {
        var buf: [160]u8 = undefined;
        return self.request("GET", try containerPath(&buf, id, "/json"), null, out, 5000);
    }

    pub fn inspectContainerName(self: Client, name: []const u8, out: []u8) ![]u8 {
        if (!validName(name)) return error.PodmanInvalidRequest;
        var buf: [160]u8 = undefined;
        const path = try std.fmt.bufPrintSentinel(&buf, "/containers/{s}/json", .{name}, 0);
        return self.request("GET", path, null, out, 5000);
    }

    pub const RuntimeState = struct { OOMKilled: bool, CgroupPath: []const u8 = "", Running: bool };
    pub const RuntimeInspect = struct { State: RuntimeState };

    pub fn runtimeState(self: Client, a: std.mem.Allocator, id: Id, out: []u8) !std.json.Parsed(RuntimeInspect) {
        return std.json.parseFromSlice(RuntimeInspect, a, try self.inspect(id, out), .{ .ignore_unknown_fields = true });
    }

    pub fn inspectImage(self: Client, id: Id, out: []u8) ![]u8 {
        try validateId(id);
        var buf: [128]u8 = undefined;
        const path = try std.fmt.bufPrintSentinel(&buf, "/images/{s}/json", .{&id}, 0);
        return self.request("GET", path, null, out, 5000);
    }

    pub fn start(self: Client, id: Id) !void {
        try self.action("POST", id, "/start", 30000);
    }

    pub fn initContainer(self: Client, id: Id) !void {
        try self.action("POST", id, "/init", 5000);
    }

    pub fn attach(self: Client, id: Id, input: bool, timeout: u32) !Attach {
        var endpoint: [192]u8 = undefined;
        const path = try containerPath(&endpoint, id, if (input)
            "/attach?stream=true&stdin=true&stdout=true&stderr=true&detachKeys="
        else
            "/attach?stream=true&stdin=false&stdout=true&stderr=true&detachKeys=");
        var fd: c_int = undefined;
        try status(podtest_attach_open(self.socket, self.api_version, path, timeout, &fd));
        return .{ .fd = fd, .input_open = input };
    }

    pub fn stop(self: Client, id: Id) !void {
        try self.action("POST", id, "/stop?t=1", 15000);
    }

    pub fn kill(self: Client, id: Id) !void {
        try self.action("POST", id, "/kill?signal=KILL", 5000);
    }

    pub fn remove(self: Client, id: Id) !void {
        try self.action("DELETE", id, "?force=true", 10000);
    }

    pub fn wait(self: Client, id: Id, timeout_ms: u32) !i32 {
        return self.waitCancelable(id, timeout_ms, null);
    }

    // The caller retains ownership and must remove the container on every exit path.
    pub fn waitSupervised(self: Client, io: std.Io, a: std.mem.Allocator, id: Id, watchdog: resource.Watchdog) !resource.Exit {
        var supervisor: resource.Supervisor = .{ .watchdog = watchdog, .output_limit = std.math.maxInt(u64) };
        const code = self.waitUntil(id, io, watchdog) catch |err| switch (err) {
            error.PodmanTimeout => blk: {
                supervisor.stop_reason = .wall_timeout;
                self.kill(id) catch |kill_err| if (kill_err != error.PodmanConflict) return kill_err;
                break :blk try self.wait(id, 5000);
            },
            else => return err,
        };
        const out = try a.alloc(u8, 128 << 10);
        defer a.free(out);
        const state = try std.json.parseFromSlice(struct { State: struct { OOMKilled: bool } }, a, try self.inspect(id, out), .{ .ignore_unknown_fields = true });
        defer state.deinit();
        return supervisor.exit(code, state.value.State.OOMKilled);
    }

    fn waitUntil(self: Client, id: Id, io: std.Io, watchdog: resource.Watchdog) !i32 {
        while (true) {
            const remaining = watchdog.remainingMs(std.Io.Clock.awake.now(io).nanoseconds);
            if (remaining == 0) return error.PodmanTimeout;
            const slice: u32 = @intCast(@min(remaining, 1000));
            if (self.wait(id, slice)) |code| return code else |err| switch (err) {
                error.PodmanTimeout => continue,
                else => return err,
            }
        }
    }

    pub fn waitCancelable(self: Client, id: Id, timeout_ms: u32, cancellation: ?Cancellation) !i32 {
        var path: [160]u8 = undefined;
        var out: [128]u8 = undefined;
        var length: usize = out.len;
        var cancel = cancellation;
        const endpoint = try containerPath(&path, id, "/wait?condition=exited");
        try status(podtest_podman_request(self.socket, self.api_version, "POST", endpoint, null, 0, &out, &length, timeout_ms, null, null, null, if (cancel != null) Cancellation.poll else null, if (cancel) |*state| state else null));
        const bytes = out[0..length];
        return std.fmt.parseInt(i32, std.mem.trim(u8, bytes, " \n\r\t"), 10) catch error.PodmanProtocol;
    }

    fn action(self: Client, method: [*:0]const u8, id: Id, suffix: []const u8, timeout_ms: u32) !void {
        var path: [160]u8 = undefined;
        try status(podtest_podman_request(self.socket, self.api_version, method, try containerPath(&path, id, suffix), null, 0, null, null, timeout_ms, null, null, null, null, null));
    }
};

pub const Id = [64]u8;
pub const ContainerLabels = struct {
    @"managed-by": []const u8 = "podtest-invoker",
    @"podtest.invoker_id": []const u8,
    @"podtest.process_epoch": []const u8,
    @"podtest.run_id": []const u8,
    @"podtest.resource_kind": []const u8 = "container",
    @"podtest.journal_id": []const u8,
};

const Mount = struct { type: []const u8, destination: []const u8, options: []const []const u8 };
const scratch_mount = [_]Mount{.{ .type = "tmpfs", .destination = "/tmp", .options = &.{ "size=96m", "mode=1777", "noexec", "nosuid", "nodev" } }};
const no_mounts = [_]Mount{};
pub const ContainerSpec = struct { name: []const u8, image: Id, command: []const []const u8, stdin: bool = false, live_io: bool = false, labels: ?ContainerLabels = null, scratch: bool = false };

pub fn validateSpec(spec: ContainerSpec) !void {
    if (!validName(spec.name) or spec.command.len == 0) return error.PodmanInvalidRequest;
    try validateId(spec.image);
}

pub const Attach = struct {
    fd: c_int,
    input_open: bool,
    header: [8]u8 = undefined,
    used: usize = 0,
    left: u32 = 0,
    channel: u8 = 0,
    pub const Chunk = struct { stream: enum { stdout, stderr }, len: usize };

    pub fn close(self: *Attach) void {
        if (self.fd >= 0) podtest_attach_close(self.fd);
        self.fd = -1;
        self.input_open = false;
    }

    pub fn closeInput(self: *Attach) !void {
        if (!self.input_open) return;
        self.input_open = false;
        if (podtest_attach_half_close(self.fd) != 0) return error.BrokenPipe;
    }

    pub fn write(self: *Attach, bytes: []const u8) !usize {
        if (!self.input_open) return error.BrokenPipe;
        return ioResult(podtest_attach_io(self.fd, @constCast(bytes.ptr), bytes.len, 1));
    }

    pub fn read(self: *Attach, buffer: []u8) !?Chunk {
        if (buffer.len == 0) return error.PodmanInvalidRequest;
        if (self.left == 0) {
            const n = try ioResult(podtest_attach_io(self.fd, self.header[self.used..].ptr, 8 - self.used, 0));
            if (n == 0) return if (self.used == 0) null else error.PodmanProtocol;
            self.used += n;
            if (self.used < 8) return error.WouldBlock;
            self.used = 0;
            if (self.header[0] == 3) return error.PodmanServerError;
            if (self.header[0] > 2 or !std.mem.allEqual(u8, self.header[1..4], 0)) return error.PodmanProtocol;
            self.channel = self.header[0];
            self.left = std.mem.readInt(u32, self.header[4..8], .big);
            if (self.left == 0) return error.WouldBlock;
        }
        const n = try ioResult(podtest_attach_io(self.fd, buffer.ptr, @min(buffer.len, self.left), 0));
        if (n == 0) return error.PodmanProtocol;
        self.left -= @intCast(n);
        // Channel 0 is echoed stdin, not output from the container.
        if (self.channel == 0) return error.WouldBlock;
        return .{ .stream = if (self.channel == 1) .stdout else .stderr, .len = n };
    }

    fn ioResult(n: c_long) !usize {
        return switch (n) {
            -1 => error.WouldBlock,
            -2 => error.BrokenPipe,
            -3 => error.PodmanTransport,
            else => @intCast(n),
        };
    }
};
pub const ContextFile = struct { path: []const u8, contents: []const u8, executable: bool = false };

/// Archive only explicit file bytes, not paths into the host filesystem.
pub fn packContext(a: std.mem.Allocator, files: []const ContextFile) ![]u8 {
    if (files.len == 0 or files.len > 128) return error.BuildContextLimit;
    const sorted = try a.dupe(ContextFile, files);
    defer a.free(sorted);
    std.mem.sort(ContextFile, sorted, {}, struct {
        fn less(_: void, left: ContextFile, right: ContextFile) bool {
            return std.mem.lessThan(u8, left.path, right.path);
        }
    }.less);
    var out = std.Io.Writer.Allocating.init(a);
    defer out.deinit();
    var tar: std.tar.Writer = .{ .underlying_writer = &out.writer };
    var total: usize = 0;
    for (sorted, 0..) |entry, i| {
        if (entry.path.len == 0 or entry.path.len > 100 or entry.contents.len > 1 << 20) return error.InvalidBuildContextEntry;
        var components = std.mem.splitScalar(u8, entry.path, '/');
        while (components.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidBuildContextEntry;
            for (part) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '_' and c != '-') return error.InvalidBuildContextEntry;
        }
        if (i > 0 and std.mem.eql(u8, sorted[i - 1].path, entry.path)) return error.DuplicateBuildContextPath;
        var parents = std.mem.splitScalar(u8, entry.path, '/');
        while (parents.next()) |part| {
            const end = @intFromPtr(part.ptr) - @intFromPtr(entry.path.ptr) + part.len;
            if (end == entry.path.len) break;
            for (sorted[0..i]) |parent| if (std.mem.eql(u8, parent.path, entry.path[0..end])) return error.InvalidBuildContextEntry;
        }
        total += entry.contents.len;
        if (total > 4 << 20) return error.BuildContextLimit;
        try tar.writeFileBytes(entry.path, entry.contents, .{ .mode = if (entry.executable) 0o755 else 0o644 });
    }
    try tar.finishPedantically();
    return out.toOwnedSlice();
}

pub const Cancellation = struct {
    check: *const fn (*anyopaque) bool,
    context: *anyopaque,

    fn poll(context: ?*anyopaque) callconv(.c) c_int {
        const state: *Cancellation = @ptrCast(@alignCast(context.?));
        return @intFromBool(state.check(state.context));
    }
};

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 63 or !std.ascii.isAlphanumeric(name[0])) return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    return true;
}

fn validTag(tag: []const u8) bool {
    if (!validName(tag) or !(std.mem.startsWith(u8, tag, "podtest-phase4-") or std.mem.startsWith(u8, tag, "podtest-phase7-") or std.mem.startsWith(u8, tag, "podtest-owned-"))) return false;
    return blk: {
        for (tag) |c| if (std.ascii.isUpper(c)) break :blk false;
        break :blk true;
    };
}

fn tagVersion(tag: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, tag, "podtest-owned-")) "temporary" else if (std.mem.startsWith(u8, tag, "podtest-phase7-")) "phase7" else "phase4";
}

fn tagPath(buf: []u8, tag: []const u8, suffix: []const u8) ![:0]const u8 {
    if (!validTag(tag)) return error.PodmanInvalidRequest;
    return std.fmt.bufPrintSentinel(buf, "/images/localhost%2F{s}:{s}{s}", .{ tag, tagVersion(tag), suffix }, 0);
}

fn validateId(id: Id) !void {
    for (id) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return error.PodmanInvalidId;
}

fn containerPath(buf: []u8, id: Id, suffix: []const u8) ![:0]const u8 {
    try validateId(id);
    return std.fmt.bufPrintSentinel(buf, "/containers/{s}{s}", .{ &id, suffix }, 0);
}

extern fn podtest_podman_request(socket: [*:0]const u8, version: [*:0]const u8, method: [*:0]const u8, path: [*:0]const u8, body: ?[*]const u8, body_len: usize, response: ?[*]u8, response_len: ?*usize, timeout_ms: u32, sink: ?*const fn (?*anyopaque, [*]const u8, usize) callconv(.c) c_int, context: ?*anyopaque, content_type: ?[*:0]const u8, cancel: ?*const fn (?*anyopaque) callconv(.c) c_int, cancel_context: ?*anyopaque) c_int;
extern fn podtest_attach_open(socket: [*:0]const u8, version: [*:0]const u8, path: [*:0]const u8, timeout: u32, fd: *c_int) c_int;
extern fn podtest_attach_io(fd: c_int, bytes: [*]u8, len: usize, writing: c_int) c_long;
extern fn podtest_attach_half_close(fd: c_int) c_int;
extern fn podtest_attach_close(fd: c_int) void;

fn status(rc: c_int) !void {
    return switch (rc) {
        0 => {},
        2 => error.PodmanTimeout,
        4 => error.PodmanResponseTooLarge,
        5 => error.PodmanTransport,
        6 => error.PodmanStreamAborted,
        7 => error.PodmanCancelled,
        404 => error.PodmanNotFound,
        409 => error.PodmanConflict,
        400...403, 405...408, 410...499 => error.PodmanHttpRejected,
        500...599 => error.PodmanServerError,
        1 => error.PodmanInvalidRequest,
        else => error.PodmanProtocol,
    };
}

test "build stream handles chunk boundaries, semantic errors and bounded output" {
    const Sink = struct {
        fn append(context: *anyopaque, bytes: []const u8) !void {
            const list: *std.ArrayList(u8) = @ptrCast(@alignCast(context));
            try list.appendSlice(std.testing.allocator, bytes);
        }
    };
    const a = std.testing.allocator;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(a);
    var capture: Client.BuildCapture = .{ .allocator = a, .sink = Sink.append, .context = &output };
    defer capture.line.deinit(a);
    _ = try capture.consume("{\"stream\":\"log");
    try std.testing.expectEqual(@as(usize, 0), output.items.len);
    _ = try capture.consume("\\n\"}\n");
    try std.testing.expectEqualStrings("log\n", output.items);
    try std.testing.expectError(error.PodmanBuildFailed, capture.consume("{\"errorDetail\":{\"message\":\"failed\"}}\n"));
    try std.testing.expectEqualStrings("log\nfailed", output.items);
    capture.line.clearRetainingCapacity();
    const oversized = try a.alloc(u8, 65537);
    defer a.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectError(error.PodmanBuildLineTooLong, capture.consume(oversized));
    capture.remaining = 0;
    try std.testing.expectError(error.PodmanBuildOutputLimit, capture.consume("x"));
}

test "build context is deterministic and rejects invalid paths" {
    const a = std.testing.allocator;
    const files = [2]ContextFile{ .{ .path = "nested/file", .contents = "x" }, .{ .path = "Dockerfile", .contents = "FROM scratch\n" } };
    const first = try packContext(a, &files);
    defer a.free(first);
    const second = try packContext(a, &.{ files[1], files[0] });
    defer a.free(second);
    try std.testing.expectEqualSlices(u8, first, second);
    try std.testing.expectError(error.InvalidBuildContextEntry, packContext(a, &.{.{ .path = "a/../b", .contents = "x" }}));
    try std.testing.expectError(error.InvalidBuildContextEntry, packContext(a, &.{ files[0], .{ .path = "nested", .contents = "x" } }));
    try std.testing.expectError(error.DuplicateBuildContextPath, packContext(a, &.{ files[0], files[0] }));
}
