const std = @import("std");
const http = @import("../util/http.zig");
const sys = @import("../util/sys.zig");
const log = @import("../util/log.zig");
const gpa = @import("../util/mem.zig").gpa;

pub const Error = error{
    PodmanRequestFailed,
    PodmanBuildFailed,
    InvalidResponse,
    ContainerNotFound,
} || http.Error || std.mem.Allocator.Error;

pub const Mount = struct {
    host_abs: []const u8,
    container_path: []const u8,
    read_only: bool = false,
};

pub const CreateContainerOptions = struct {
    image: []const u8,
    name: []const u8,
    labels: []const Label,
    stdin: bool,
    stdout: bool,
    stderr: bool,
    command: ?[]const []const u8 = null,
    mounts: []const Mount = &.{},
    memory_bytes: ?u64 = null,
    networks: []const []const u8 = &.{},
    env: []const []const u8 = &.{},
    workdir: ?[]const u8 = null,
    hostname: ?[]const u8 = null,
    user: ?[]const u8 = null,
    network_mode: ?[]const u8 = null,
};

pub const Label = struct { key: []const u8, value: []const u8 };

pub const ContainerInfo = struct {
    id: []u8,
    pid: i64,
    status: []u8,
    exit_code: i64,
    oom_killed: bool,
    error_message: []u8,
    cgroup_path: []u8,

    pub fn deinit(self: *ContainerInfo) void {
        gpa.free(self.id);
        gpa.free(self.status);
        gpa.free(self.error_message);
        gpa.free(self.cgroup_path);
        self.* = undefined;
    }
};

/// Build the JSON body for `POST /containers/create`.  Exposed for tests.
pub fn buildCreateBody(allocator: std.mem.Allocator, opts: CreateContainerOptions) ![]u8 {
    // The JSON tree shares one arena: nested objects/arrays are stored by
    // value inside their parents, so they must outlive the stringify call.
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var root: std.json.ObjectMap = .empty;
    try root.put(a, "image", .{ .string = opts.image });
    try root.put(a, "name", .{ .string = opts.name });
    try root.put(a, "stdin", .{ .bool = opts.stdin });
    try root.put(a, "stdout", .{ .bool = opts.stdout });
    try root.put(a, "stderr", .{ .bool = opts.stderr });
    try root.put(a, "tty", .{ .bool = false });

    var labels: std.json.ObjectMap = .empty;
    for (opts.labels) |l| try labels.put(a, l.key, .{ .string = l.value });
    try root.put(a, "labels", .{ .object = labels });

    if (opts.network_mode) |mode| {
        var netns: std.json.ObjectMap = .empty;
        try netns.put(a, "nsmode", .{ .string = mode });
        try root.put(a, "netns", .{ .object = netns });
    } else if (opts.networks.len == 0) {
        var netns: std.json.ObjectMap = .empty;
        try netns.put(a, "nsmode", .{ .string = "none" });
        try root.put(a, "netns", .{ .object = netns });
    } else {
        var netns: std.json.ObjectMap = .empty;
        try netns.put(a, "nsmode", .{ .string = "bridge" });
        try root.put(a, "netns", .{ .object = netns });
        var nets: std.json.ObjectMap = .empty;
        for (opts.networks) |n| {
            const empty: std.json.ObjectMap = .empty;
            try nets.put(a, n, .{ .object = empty });
        }
        try root.put(a, "networks", .{ .object = nets });
    }

    if (opts.mounts.len > 0) {
        var arr = std.json.Array.init(a);
        for (opts.mounts) |m| {
            var mo: std.json.ObjectMap = .empty;
            try mo.put(a, "type", .{ .string = "bind" });
            try mo.put(a, "source", .{ .string = m.host_abs });
            try mo.put(a, "destination", .{ .string = m.container_path });
            var oarr = std.json.Array.init(a);
            try oarr.append(.{ .string = "rbind" });
            if (m.read_only) try oarr.append(.{ .string = "ro" }) else try oarr.append(.{ .string = "rw" });
            try mo.put(a, "options", .{ .array = oarr });
            try arr.append(.{ .object = mo });
        }
        try root.put(a, "mounts", .{ .array = arr });
    }

    if (opts.command) |cmd| {
        var arr = std.json.Array.init(a);
        for (cmd) |c| try arr.append(.{ .string = c });
        try root.put(a, "command", .{ .array = arr });
    }

    if (opts.env.len > 0) {
        var arr = std.json.Array.init(a);
        for (opts.env) |e| try arr.append(.{ .string = e });
        try root.put(a, "env", .{ .array = arr });
    }
    if (opts.workdir) |w| try root.put(a, "workdir", .{ .string = w });
    if (opts.hostname) |h| try root.put(a, "hostname", .{ .string = h });
    if (opts.user) |u| try root.put(a, "user", .{ .string = u });

    if (opts.memory_bytes) |mem| {
        var lim: std.json.ObjectMap = .empty;
        try lim.put(a, "limit", .{ .integer = @intCast(mem) });
        // swap == memory means "no swap" (memory.swap.max = 0)
        try lim.put(a, "swap", .{ .integer = @intCast(mem) });
        var rl: std.json.ObjectMap = .empty;
        try rl.put(a, "memory", .{ .object = lim });
        try root.put(a, "resource_limits", .{ .object = rl });
    }

    return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = root }, .{});
}

pub const Client = struct {
    socket_path: []const u8,
    api: []const u8,
    instance_id: []const u8,

    pub fn init(socket_path: []const u8, api: []const u8, instance_id: []const u8) Client {
        return .{ .socket_path = socket_path, .api = api, .instance_id = instance_id };
    }

    fn ep(self: *const Client) http.Endpoint {
        return .{ .unix = self.socket_path };
    }

    fn path(self: *const Client, allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]u8 {
        const tail = try std.fmt.allocPrint(allocator, fmt, args);
        defer allocator.free(tail);
        return std.fmt.allocPrint(allocator, "/{s}/libpod{s}", .{ self.api, tail });
    }

    pub fn ping(self: *const Client) !void {
        const p = try self.path(gpa, "/_ping", .{});
        defer gpa.free(p);
        var resp = http.request(self.ep(), .{ .method = "GET", .path = p, .timeout_ms = 10_000 }) catch |e| {
            log.err("cannot connect to podman socket {s}: {s}", .{ self.socket_path, @errorName(e) });
            return error.PodmanRequestFailed;
        };
        defer resp.deinit();
        if (resp.status != 200) return error.PodmanRequestFailed;
    }

    fn get(self: *const Client, p: []const u8) Error!http.Response {
        return http.request(self.ep(), .{ .method = "GET", .path = p, .timeout_ms = 60_000 });
    }

    fn postJson(self: *const Client, p: []const u8, body: []const u8) Error!http.Response {
        return http.request(self.ep(), .{
            .method = "POST",
            .path = p,
            .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
            .body = body,
            .timeout_ms = 120_000,
        });
    }

    fn delete(self: *const Client, p: []const u8) Error!http.Response {
        return http.request(self.ep(), .{ .method = "DELETE", .path = p, .timeout_ms = 120_000 });
    }

    pub fn createContainer(self: *const Client, opts: CreateContainerOptions) ![]u8 {
        const body = try buildCreateBody(gpa, opts);
        defer gpa.free(body);
        const p = try self.path(gpa, "/containers/create", .{});
        defer gpa.free(p);
        var resp = try self.postJson(p, body);
        defer resp.deinit();
        if (resp.status != 201 and resp.status != 200) {
            log.err("podman create container failed: HTTP {d}: {s}", .{ resp.status, resp.body });
            return error.PodmanRequestFailed;
        }
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, resp.body, .{}) catch return error.InvalidResponse;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidResponse;
        const idv = parsed.value.object.get("Id") orelse return error.InvalidResponse;
        if (idv != .string) return error.InvalidResponse;
        return gpa.dupe(u8, idv.string);
    }

    pub fn startContainer(self: *const Client, id: []const u8) !void {
        const p = try self.path(gpa, "/containers/{s}/start", .{id});
        defer gpa.free(p);
        var resp = try self.postJson(p, "");
        defer resp.deinit();
        if (resp.status != 204 and resp.status != 200 and resp.status != 304) {
            log.err("podman start {s} failed: HTTP {d}: {s}", .{ id, resp.status, resp.body });
            return error.PodmanRequestFailed;
        }
    }

    pub fn stopContainer(self: *const Client, id: []const u8, timeout_sec: u32) !void {
        const p = try std.fmt.allocPrint(gpa, "/{s}/libpod/containers/{s}/stop?t={d}", .{ self.api, id, timeout_sec });
        defer gpa.free(p);
        var resp = try self.postJson(p, "");
        defer resp.deinit();
        if (resp.status != 204 and resp.status != 304 and resp.status != 200 and resp.status != 404) {
            log.warn("podman stop {s}: HTTP {d}", .{ id, resp.status });
        }
    }

    pub fn killContainer(self: *const Client, id: []const u8) !void {
        const p = try self.path(gpa, "/containers/{s}/kill?signal=SIGKILL", .{id});
        defer gpa.free(p);
        var resp = self.postJson(p, "") catch |e| {
            log.warn("podman kill {s}: {s}", .{ id, @errorName(e) });
            return e;
        };
        defer resp.deinit();
        if (resp.status != 204 and resp.status != 200 and resp.status != 404 and resp.status != 409) {
            log.warn("podman kill {s}: HTTP {d}", .{ id, resp.status });
        }
    }

    pub fn removeContainer(self: *const Client, id: []const u8) !void {
        const p = try self.path(gpa, "/containers/{s}?force=true", .{id});
        defer gpa.free(p);
        var resp = self.delete(p) catch |e| {
            log.warn("podman remove container {s}: {s}", .{ id, @errorName(e) });
            return e;
        };
        defer resp.deinit();
        if (resp.status != 204 and resp.status != 200 and resp.status != 404) {
            log.warn("podman remove container {s}: HTTP {d}", .{ id, resp.status });
        }
    }

    /// Blocking wait for the container to exit.  Returns the exit code.
    pub fn waitContainer(self: *const Client, id: []const u8) !i32 {
        const p = try self.path(gpa, "/containers/{s}/wait?condition=exited", .{id});
        defer gpa.free(p);
        var resp = try http.request(self.ep(), .{ .method = "POST", .path = p, .timeout_ms = -1, .max_response = 1024 });
        defer resp.deinit();
        if (resp.status != 200) return error.PodmanRequestFailed;
        const txt = std.mem.trim(u8, resp.body, " \t\r\n");
        return std.fmt.parseInt(i32, txt, 10) catch error.InvalidResponse;
    }

    pub fn inspectContainer(self: *const Client, id: []const u8) !ContainerInfo {
        const p = try self.path(gpa, "/containers/{s}/json", .{id});
        defer gpa.free(p);
        var resp = try self.get(p);
        defer resp.deinit();
        if (resp.status == 404) return error.ContainerNotFound;
        if (resp.status != 200) return error.PodmanRequestFailed;
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, resp.body, .{}) catch return error.InvalidResponse;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidResponse;
        const root = parsed.value.object;
        const state = root.get("State") orelse return error.InvalidResponse;
        if (state != .object) return error.InvalidResponse;
        const so = state.object;
        var info = ContainerInfo{
            .id = try gpa.dupe(u8, id),
            .pid = 0,
            .status = try gpa.dupe(u8, ""),
            .exit_code = 0,
            .oom_killed = false,
            .error_message = try gpa.dupe(u8, ""),
            .cgroup_path = try gpa.dupe(u8, ""),
        };
        errdefer info.deinit();
        if (so.get("Pid")) |v| if (v == .integer) {
            info.pid = v.integer;
        };
        if (so.get("Status")) |v| if (v == .string) {
            gpa.free(info.status);
            info.status = try gpa.dupe(u8, v.string);
        };
        if (so.get("ExitCode")) |v| if (v == .integer) {
            info.exit_code = v.integer;
        };
        if (so.get("OOMKilled")) |v| if (v == .bool) {
            info.oom_killed = v.bool;
        };
        if (so.get("Error")) |v| if (v == .string) {
            gpa.free(info.error_message);
            info.error_message = try gpa.dupe(u8, v.string);
        };
        if (so.get("CgroupPath")) |v| if (v == .string) {
            gpa.free(info.cgroup_path);
            info.cgroup_path = try gpa.dupe(u8, v.string);
        };
        return info;
    }

    pub fn attach(self: *const Client, id: []const u8, want_stdin: bool, want_stdout: bool, want_stderr: bool) !http.Hijacked {
        const p = try std.fmt.allocPrint(gpa, "/{s}/libpod/containers/{s}/attach?stdin={d}&stdout={d}&stderr={d}&stream=1&logs=0", .{
            self.api,
            id,
            @intFromBool(want_stdin),
            @intFromBool(want_stdout),
            @intFromBool(want_stderr),
        });
        defer gpa.free(p);
        return http.hijack(self.ep(), "POST", p, 60_000);
    }

    pub fn buildImage(self: *const Client, context_tar: []const u8, tag: []const u8, dockerfile: []const u8, labels: []const Label) !void {
        var labels_map: std.json.ObjectMap = .empty;
        defer labels_map.deinit(gpa);
        for (labels) |l| try labels_map.put(gpa, l.key, .{ .string = l.value });
        const labels_json = try std.json.Stringify.valueAlloc(gpa, std.json.Value{ .object = labels_map }, .{});
        defer gpa.free(labels_json);

        var pbuf: std.ArrayList(u8) = .empty;
        defer pbuf.deinit(gpa);
        try pbuf.print(gpa, "/{s}/libpod/build?t={s}&dockerfile={s}&networkmode=none&q=0&labels=", .{ self.api, tag, dockerfile });
        try urlEncodeTo(&pbuf, labels_json);
        const p = pbuf.items;

        var resp = http.request(self.ep(), .{
            .method = "POST",
            .path = p,
            .headers = &.{.{ .name = "Content-Type", .value = "application/x-tar" }},
            .body = context_tar,
            .timeout_ms = -1,
            .max_response = 256 * 1024 * 1024,
        }) catch |e| {
            log.err("podman build request failed: {s}", .{@errorName(e)});
            return error.PodmanRequestFailed;
        };
        defer resp.deinit();
        if (resp.status != 200) {
            log.err("podman build failed: HTTP {d}: {s}", .{ resp.status, resp.body });
            return error.PodmanBuildFailed;
        }
        // Response is a stream of JSON objects (one per line).
        var it = std.mem.splitScalar(u8, resp.body, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            const parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            if (parsed.value.object.get("error")) |ev| {
                if (ev == .string) {
                    log.err("podman build error: {s}", .{ev.string});
                    return error.PodmanBuildFailed;
                }
            }
        }
    }

    pub fn createNetwork(self: *const Client, name: []const u8, labels: []const Label) !void {
        var root: std.json.ObjectMap = .empty;
        defer root.deinit(gpa);
        try root.put(gpa, "name", .{ .string = name });
        try root.put(gpa, "driver", .{ .string = "bridge" });
        try root.put(gpa, "internal", .{ .bool = true });
        try root.put(gpa, "dns_enabled", .{ .bool = false });
        var lm: std.json.ObjectMap = .empty;
        defer lm.deinit(gpa);
        for (labels) |l| try lm.put(gpa, l.key, .{ .string = l.value });
        try root.put(gpa, "labels", .{ .object = lm });
        const body = try std.json.Stringify.valueAlloc(gpa, std.json.Value{ .object = root }, .{});
        defer gpa.free(body);
        const p = try self.path(gpa, "/networks/create", .{});
        defer gpa.free(p);
        var resp = try self.postJson(p, body);
        defer resp.deinit();
        if (resp.status != 200 and resp.status != 201) {
            log.err("podman network create failed: HTTP {d}: {s}", .{ resp.status, resp.body });
            return error.PodmanRequestFailed;
        }
    }

    pub fn removeNetwork(self: *const Client, name: []const u8) !void {
        const p = try self.path(gpa, "/networks/{s}?force=true", .{name});
        defer gpa.free(p);
        var resp = self.delete(p) catch |e| {
            log.warn("podman remove network {s}: {s}", .{ name, @errorName(e) });
            return e;
        };
        defer resp.deinit();
        if (resp.status != 200 and resp.status != 204 and resp.status != 404) {
            log.warn("podman remove network {s}: HTTP {d}", .{ name, resp.status });
        }
    }

    pub fn removeImage(self: *const Client, id_or_name: []const u8) !void {
        const p = try self.path(gpa, "/images/{s}?force=true", .{id_or_name});
        defer gpa.free(p);
        var resp = self.delete(p) catch |e| {
            log.warn("podman remove image {s}: {s}", .{ id_or_name, @errorName(e) });
            return e;
        };
        defer resp.deinit();
        if (resp.status != 200 and resp.status != 204 and resp.status != 404) {
            log.warn("podman remove image {s}: HTTP {d}", .{ id_or_name, resp.status });
        }
    }

    pub fn imageExists(self: *const Client, name: []const u8) bool {
        const p = self.path(gpa, "/images/{s}/json", .{name}) catch return false;
        defer gpa.free(p);
        var resp = self.get(p) catch return false;
        defer resp.deinit();
        return resp.status == 200;
    }

    /// Pull an image.  Returns the local reference.  The response is a stream
    /// of JSON progress objects; an `error` field aborts the pull.
    pub fn pullImage(self: *const Client, reference: []const u8) !void {
        var enc: std.ArrayList(u8) = .empty;
        defer enc.deinit(gpa);
        try urlEncodeTo(&enc, reference);
        const p = try std.fmt.allocPrint(gpa, "/{s}/libpod/images/pull?reference={s}&quiet=1", .{ self.api, enc.items });
        defer gpa.free(p);
        var resp = http.request(self.ep(), .{
            .method = "POST",
            .path = p,
            .timeout_ms = -1,
            .max_response = 64 * 1024 * 1024,
        }) catch |e| {
            log.err("podman pull {s} request failed: {s}", .{ reference, @errorName(e) });
            return error.PodmanRequestFailed;
        };
        defer resp.deinit();
        if (resp.status != 200) {
            log.err("podman pull {s} failed: HTTP {d}: {s}", .{ reference, resp.status, resp.body });
            return error.PodmanRequestFailed;
        }
        var it = std.mem.splitScalar(u8, resp.body, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            const parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            if (parsed.value.object.get("error")) |ev| {
                if (ev == .string) {
                    log.err("podman pull {s} error: {s}", .{ reference, ev.string });
                    return error.PodmanRequestFailed;
                }
            }
        }
    }

    pub fn networkExists(self: *const Client, name: []const u8) bool {
        const p = self.path(gpa, "/networks/{s}/json", .{name}) catch return false;
        defer gpa.free(p);
        var resp = self.get(p) catch return false;
        defer resp.deinit();
        return resp.status == 200;
    }

    fn labelFilter(self: *const Client, extra: ?[]const u8) ![]u8 {
        var arr = std.json.Array.init(gpa);
        defer arr.deinit();
        try arr.append(.{ .string = "managed-by=invoker" });
        const inst = try std.fmt.allocPrint(gpa, "invoker.instance={s}", .{self.instance_id});
        defer gpa.free(inst);
        try arr.append(.{ .string = inst });
        if (extra) |e| try arr.append(.{ .string = e });
        var root: std.json.ObjectMap = .empty;
        defer root.deinit(gpa);
        try root.put(gpa, "label", .{ .array = arr });
        const json = try std.json.Stringify.valueAlloc(gpa, std.json.Value{ .object = root }, .{});
        defer gpa.free(json);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try urlEncodeTo(&out, json);
        return out.toOwnedSlice(gpa);
    }

    fn listIds(self: *const Client, kind: []const u8, extra: ?[]const u8, field: []const u8) ![][]u8 {
        const filter = try self.labelFilter(extra);
        defer gpa.free(filter);
        const p = try std.fmt.allocPrint(gpa, "/{s}/libpod/{s}/json?all=true&filters={s}", .{ self.api, kind, filter });
        defer gpa.free(p);
        var resp = try self.get(p);
        defer resp.deinit();
        if (resp.status != 200) return error.PodmanRequestFailed;
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, resp.body, .{}) catch return error.InvalidResponse;
        defer parsed.deinit();
        if (parsed.value != .array) return error.InvalidResponse;
        var out: std.ArrayList([]u8) = .empty;
        errdefer {
            for (out.items) |s| gpa.free(s);
            out.deinit(gpa);
        }
        for (parsed.value.array.items) |item| {
            if (item != .object) continue;
            const v = item.object.get(field) orelse continue;
            if (v != .string) continue;
            try out.append(gpa, try gpa.dupe(u8, v.string));
        }
        return out.toOwnedSlice(gpa);
    }

    pub fn listContainerIds(self: *const Client) ![][]u8 {
        return self.listIds("containers", null, "Id");
    }
    pub fn listImageIds(self: *const Client) ![][]u8 {
        return self.listIds("images", null, "Id");
    }
    pub fn listNetworkNames(self: *const Client) ![][]u8 {
        return self.listIds("networks", null, "name");
    }
};

pub fn freeIdList(list: [][]u8) void {
    for (list) |s| gpa.free(s);
    gpa.free(list);
}

fn urlEncodeTo(out: *std.ArrayList(u8), s: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (s) |c| {
        const unreserved = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.' or c == '~';
        if (unreserved) {
            try out.append(gpa, c);
        } else {
            try out.append(gpa, '%');
            try out.append(gpa, hex[c >> 4]);
            try out.append(gpa, hex[c & 0xf]);
        }
    }
}

// ---------------------------------------------------------------------------
// cgroup helpers
// ---------------------------------------------------------------------------

pub fn readCgroupPath(pid: i64, buf: []u8) ?[]const u8 {
    var pbuf: [64]u8 = undefined;
    const p = std.fmt.bufPrint(&pbuf, "/proc/{d}/cgroup", .{pid}) catch return null;
    const data = @import("../util/fs.zig").readFileAbsolute(p, 64 * 1024) catch return null;
    defer gpa.free(data);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "0::")) {
            const path = line[3..];
            if (path.len == 0 or path.len + 1 > buf.len) return null;
            @memcpy(buf[0..path.len], path);
            buf[path.len] = 0;
            return buf[0..path.len];
        }
    }
    return null;
}

pub const CgroupStats = struct {
    cpu_usage_usec: u64 = 0,
    oom_kill: u64 = 0,
    oom: u64 = 0,
    memory_peak: u64 = 0,
};

pub fn readCgroupStats(cgroup_path: []const u8) CgroupStats {
    const fsmod = @import("../util/fs.zig");
    var stats = CgroupStats{};
    var pbuf: [4096]u8 = undefined;
    const cpu_path = std.fmt.bufPrint(&pbuf, "/sys/fs/cgroup{s}/cpu.stat", .{cgroup_path}) catch return stats;
    if (fsmod.readFileAbsolute(cpu_path, 64 * 1024)) |data| {
        defer gpa.free(data);
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            if (std.mem.startsWith(u8, line, "usage_usec ")) {
                stats.cpu_usage_usec = std.fmt.parseInt(u64, std.mem.trim(u8, line[11..], " \t"), 10) catch 0;
            }
        }
    } else |_| {}
    const mem_path = std.fmt.bufPrint(&pbuf, "/sys/fs/cgroup{s}/memory.events", .{cgroup_path}) catch return stats;
    if (fsmod.readFileAbsolute(mem_path, 64 * 1024)) |data| {
        defer gpa.free(data);
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            if (std.mem.startsWith(u8, line, "oom_kill ")) {
                stats.oom_kill = std.fmt.parseInt(u64, std.mem.trim(u8, line[9..], " \t"), 10) catch 0;
            } else if (std.mem.startsWith(u8, line, "oom ")) {
                stats.oom = std.fmt.parseInt(u64, std.mem.trim(u8, line[4..], " \t"), 10) catch 0;
            }
        }
    } else |_| {}
    const peak_path = std.fmt.bufPrint(&pbuf, "/sys/fs/cgroup{s}/memory.peak", .{cgroup_path}) catch return stats;
    if (fsmod.readFileAbsolute(peak_path, 4096)) |data| {
        defer gpa.free(data);
        stats.memory_peak = std.fmt.parseInt(u64, std.mem.trim(u8, data, " \t\r\n"), 10) catch 0;
    } else |_| {}
    return stats;
}

test "container create JSON keeps nested mounts, networks and limits" {
    const labels = [_]Label{
        .{ .key = "managed-by", .value = "invoker" },
        .{ .key = "invoker.instance", .value = "abc" },
    };
    const command = [_][]const u8{ "sh", "-c", "echo hi" };
    const env = [_][]const u8{"A=1"};
    const networks = [_][]const u8{"net-a"};
    const mounts = [_]Mount{
        .{ .host_abs = "/run/x/solution", .container_path = "/solution", .read_only = true },
        .{ .host_abs = "/run/x/data", .container_path = "/data" },
    };
    const body = try buildCreateBody(std.testing.allocator, .{
        .image = "docker.io/library/node:26-alpine3.23",
        .name = "run-c-1",
        .labels = &labels,
        .stdin = true,
        .stdout = true,
        .stderr = true,
        .command = &command,
        .mounts = &mounts,
        .memory_bytes = 512 * 1024 * 1024,
        .networks = &networks,
        .env = &env,
        .workdir = "/work",
        .hostname = "host",
        .user = "1000:1000",
    });
    defer std.testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    try std.testing.expectEqualStrings("docker.io/library/node:26-alpine3.23", root.get("image").?.string);
    try std.testing.expectEqualStrings("run-c-1", root.get("name").?.string);
    try std.testing.expect(root.get("stdin").?.bool);
    try std.testing.expectEqualStrings("invoker", root.get("labels").?.object.get("managed-by").?.string);

    const netns = root.get("netns").?.object;
    try std.testing.expectEqualStrings("bridge", netns.get("nsmode").?.string);
    try std.testing.expect(root.get("networks").?.object.get("net-a") != null);

    const marr = root.get("mounts").?.array;
    try std.testing.expectEqual(@as(usize, 2), marr.items.len);
    const m0 = marr.items[0].object;
    try std.testing.expectEqualStrings("bind", m0.get("type").?.string);
    try std.testing.expectEqualStrings("/run/x/solution", m0.get("source").?.string);
    try std.testing.expectEqualStrings("/solution", m0.get("destination").?.string);
    try std.testing.expectEqualStrings("ro", m0.get("options").?.array.items[1].string);
    const m1 = marr.items[1].object;
    try std.testing.expectEqualStrings("rw", m1.get("options").?.array.items[1].string);

    try std.testing.expectEqualStrings("sh", root.get("command").?.array.items[0].string);
    try std.testing.expectEqualStrings("A=1", root.get("env").?.array.items[0].string);
    try std.testing.expectEqualStrings("/work", root.get("workdir").?.string);
    try std.testing.expectEqualStrings("host", root.get("hostname").?.string);
    try std.testing.expectEqualStrings("1000:1000", root.get("user").?.string);

    const mem = root.get("resource_limits").?.object.get("memory").?.object;
    try std.testing.expectEqual(@as(i64, 512 * 1024 * 1024), mem.get("limit").?.integer);
    try std.testing.expectEqual(@as(i64, 512 * 1024 * 1024), mem.get("swap").?.integer);
}

test "container create JSON defaults to no network" {
    const labels = [_]Label{.{ .key = "managed-by", .value = "invoker" }};
    const body = try buildCreateBody(std.testing.allocator, .{
        .image = "img",
        .name = "n",
        .labels = &labels,
        .stdin = false,
        .stdout = false,
        .stderr = false,
    });
    defer std.testing.allocator.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("none", root.get("netns").?.object.get("nsmode").?.string);
    try std.testing.expect(root.get("networks") == null);
    try std.testing.expect(root.get("mounts") == null);
    try std.testing.expect(root.get("resource_limits") == null);
}
