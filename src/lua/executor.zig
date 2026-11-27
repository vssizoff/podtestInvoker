const std = @import("std");
const podman = @import("podman");
const janitor = @import("janitor");
const Workspace = @import("workspace.zig").Workspace;
const Result = @import("../standard/result.zig");
const phase3 = @import("../phase3.zig");

const Command = [*:null]?[*:0]const u8;
extern "c" fn podtest_lua_supervise_run(argv: Command, script: [*]const u8, len: usize, timeout_ms: u32, read: @TypeOf(&Run.readStdout), workspace: @TypeOf(&Run.readWorkspace), dispatch: @TypeOf(&Run.dispatch), cancel: @TypeOf(&Run.cancelled), context: *anyopaque, log_fd: c_int) c_int;

pub fn sandboxCommand(init: std.process.Init) !Command {
    const runner = init.environ_map.get("PODTEST_LUA_RUNNER") orelse return error.MissingLuaRunner;
    const libraries = init.environ_map.get("PODTEST_LUA_LIBRARIES") orelse return error.MissingLuaLibraries;
    const a = init.arena.allocator();
    var command: std.ArrayList(?[*:0]const u8) = .empty;
    try command.appendSlice(a, &.{ "/usr/bin/bwrap", "--die-with-parent", "--unshare-all", "--unshare-user", "--uid", "65534", "--gid", "65534", "--clearenv", "--disable-userns", "--chdir", "/" });
    var paths = std.mem.splitScalar(u8, libraries, ':');
    while (paths.next()) |path| {
        if (!std.fs.path.isAbsolute(path)) return error.InvalidLuaLibraryPath;
        const file = try std.Io.Dir.openFileAbsolute(init.io, path, .{ .allow_directory = false });
        defer file.close(init.io);
        if ((try file.stat(init.io)).kind != .file) return error.InvalidLuaLibraryPath;
        const value = try a.dupeSentinel(u8, path, 0);
        try command.appendSlice(a, &.{ "--ro-bind", value, value });
    }
    if (!std.fs.path.isAbsolute(runner)) return error.InvalidLuaRunnerPath;
    try command.appendSlice(a, &.{ "--ro-bind", try a.dupeSentinel(u8, runner, 0), "/runner", "--", "/runner", "--rpc" });
    return (try command.toOwnedSliceSentinel(a, null)).ptr;
}

pub const Run = struct {
    a: std.mem.Allocator,
    workspace: Workspace,
    journal: janitor.Journal,
    client: podman.Client,
    image: podman.Id,
    run_id: []const u8,
    cancellation: podman.Cancellation,
    containers: [8]?Container = @splat(null),
    launches: usize = 0,
    tests: std.ArrayList(Result.TestResult) = .empty,
    groups: std.ArrayList(Result.GroupResult) = .empty,
    score: ?u64 = null,
    failure: ?anyerror = null,

    const Container = struct {
        record: janitor.Record,
        id: podman.Id,
        attach: ?podman.Attach = null,
        remaining: usize = 1 << 20,
    };

    pub fn execute(self: *Run, output: std.Io.Dir, command: Command, timeout_ms: u32) !void {
        const io = self.workspace.io;
        const script = try self.workspace.dir.readFileAlloc(io, "runner.lua", self.a, .limited(256 << 10));
        const log = try output.createFile(io, "runner.log", .{ .permissions = .fromMode(0o600) });
        defer log.close(io);
        const rc = podtest_lua_supervise_run(command, script.ptr, script.len, timeout_ms, readStdout, readWorkspace, dispatch, cancelled, self, log.handle);
        for (&self.containers) |*slot| if (slot.* != null) try self.close(slot);
        if (rc == -3) return error.LuaInterrupted;
        if (self.failure) |err| return err;
        const failed = rc != 0 or self.score == null or self.tests.items.len == 0 or self.groups.items.len > self.tests.items.len;
        const result: Result.Result = .{
            .version = 1,
            .tests = if (failed) &.{} else self.tests.items,
            .groups = if (failed) &.{} else self.groups.items,
            .problem_score_milli = if (failed) 0 else self.score.?,
            .infrastructure_error = failed,
        };
        {
            // Child and host share the file description and its write offset.
            var message: [128]u8 = undefined;
            try log.writeStreamingAll(io, try std.fmt.bufPrint(&message, "\nLua exit status {d}, {d} test verdicts, problem score supplied: {}\n", .{ rc, self.tests.items.len, self.score != null }));
        }
        try log.sync(io);
        var file = try output.createFileAtomic(io, "result.json", .{ .permissions = .fromMode(0o600) });
        defer file.deinit(io);
        try file.file.writeStreamingAll(io, try std.json.Stringify.valueAlloc(self.a, result, .{}));
        try file.file.sync(io);
        try file.link(io);
        try phase3.sync(output);
    }

    fn context(ptr: ?*anyopaque) *Run {
        return @ptrCast(@alignCast(ptr.?));
    }

    fn cancelled(ptr: ?*anyopaque) callconv(.c) c_int {
        const self = context(ptr);
        return @intFromBool(self.failure != null or self.cancellation.check(self.cancellation.context));
    }

    fn readWorkspace(ptr: ?*anyopaque, path: [*]const u8, len: usize, offset: u32, out: [*]u8, size: *usize) callconv(.c) c_int {
        return Workspace.readRpc(&context(ptr).workspace, path, len, offset, out, size);
    }

    fn readStdout(ptr: ?*anyopaque, handle: c_uint, out: [*]u8, size: *usize) callconv(.c) c_int {
        const self = context(ptr);
        const slot = self.slotAt(handle) catch return -1;
        const item = if (slot.*) |*item| item else return -1;
        const stream = if (item.attach) |*stream| stream else return -1;
        const chunk = stream.read(out[0..size.*]) catch |err| return if (err == error.WouldBlock) 0 else -1;
        const data = chunk orelse return 2;
        if (data.len > item.remaining) return -1;
        item.remaining -= data.len;
        if (data.stream != .stdout) return 0;
        size.* = data.len;
        return 1;
    }

    fn dispatch(ptr: ?*anyopaque, method: c_uint, input: [*]const u8, len: usize, output: [*]u8, size: *usize) callconv(.c) c_int {
        const self = context(ptr);
        size.* = self.call(method, input[0..len], output[0..size.*]) catch return -1;
        return if (size.* > 0) 1 else 2;
    }

    fn call(self: *Run, method: c_uint, input: []const u8, output: []u8) !usize {
        switch (method) {
            4 => {
                const handle = try self.open(input);
                return (try std.fmt.bufPrint(output, "{d}", .{handle})).len;
            },
            5 => {
                const slot = try self.slotAt(input[0]);
                if (slot.* == null) return error.InvalidContainerHandle;
                try self.close(slot);
            },
            6 => {
                const slot = try self.slotAt(input[0]);
                const item = slot.* orelse return error.InvalidContainerHandle;
                const code = self.client.wait(item.id, 100) catch |err| switch (err) {
                    error.PodmanTimeout => return 0,
                    else => return err,
                };
                return (try std.fmt.bufPrint(output, "{d}", .{code})).len;
            },
            7...9 => try self.recordResult(method, input),
            else => return error.UnsupportedLuaMethod,
        }
        return 0;
    }

    fn recordResult(self: *Run, method: c_uint, input: []const u8) !void {
        const score = std.mem.readInt(u64, input[0..8], .little);
        if (score >= 1_000_000_000_000_000) return error.InvalidLuaScore;
        switch (method) {
            7 => {
                const sep = std.mem.indexOfScalarPos(u8, input, 8, 0) orelse return error.InvalidLuaResult;
                const id = input[8..sep];
                const verdict = std.meta.stringToEnum(Result.Verdict, input[sep + 1 ..]) orelse return error.InvalidLuaResult;
                if (!validId(id) or self.tests.items.len == 64 or score > std.math.maxInt(u32)) return error.InvalidLuaResult;
                for (self.tests.items) |item| if (std.mem.eql(u8, item.id, id)) return error.DuplicateLuaResult;
                try self.tests.append(self.a, .{ .id = try self.a.dupe(u8, id), .verdict = verdict, .score_milli = @intCast(score), .exit_code = 0, .metrics = null });
            },
            8 => {
                const id = input[8..];
                if (!validId(id) or self.groups.items.len == 64) return error.InvalidLuaResult;
                for (self.groups.items) |item| if (std.mem.eql(u8, item.id, id)) return error.DuplicateLuaResult;
                try self.groups.append(self.a, .{ .id = try self.a.dupe(u8, id), .score_milli = score });
            },
            9 => {
                if (self.score != null) return error.DuplicateLuaResult;
                self.score = score;
            },
            else => unreachable,
        }
    }

    fn slotAt(self: *Run, handle: usize) !*?Container {
        if (handle == 0 or handle > self.containers.len) return error.InvalidContainerHandle;
        return &self.containers[handle - 1];
    }

    fn open(self: *Run, path: []const u8) !usize {
        // The only exposed container profile is a provisioned local shell
        // image, with no host mounts, networking or caller-supplied options.
        if (self.launches == 8) return error.LuaContainerLimit;
        var program: [16 << 10]u8 = undefined;
        const len = try self.workspace.read(path, 0, &program);
        var tail: [1]u8 = undefined;
        if (len == 0 or try self.workspace.read(path, @intCast(len), &tail) != 0 or std.mem.indexOfScalar(u8, program[0..len], 0) != null)
            return error.InvalidLuaContainerProgram;
        self.launches += 1;
        const slot = try self.slotAt(self.launches);
        const record = try self.journal.reserve(self.a, self.run_id);
        const id = self.client.create(self.a, .{
            .name = &record.name(),
            .image = self.image,
            .command = &.{ "/bin/sh", "-c", program[0..len], "podtest-solution" },
            .live_io = true,
            .labels = record.labels(),
        }) catch |err| {
            // The remote create may still have happened. Keep its intent.
            self.failure = err;
            return err;
        };
        slot.* = .{ .record = record, .id = id };
        try self.client.initContainer(id);
        slot.*.?.attach = try self.client.attach(id, false, 3000);
        try self.client.start(id);
        return self.launches;
    }

    fn close(self: *Run, slot: *?Container) !void {
        const item = &slot.*.?;
        if (item.attach) |*stream| stream.close();
        item.attach = null;
        self.client.kill(item.id) catch |err| switch (err) {
            error.PodmanNotFound, error.PodmanConflict, error.PodmanHttpRejected => {},
            else => return err,
        };
        self.client.remove(item.id) catch |err| if (err != error.PodmanNotFound) return err;
        try self.journal.finish(item.record);
        slot.* = null;
    }
};

fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    return true;
}
