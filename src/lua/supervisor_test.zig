const std = @import("std");
const podman = @import("podman");
const Workspace = @import("workspace.zig").Workspace;
const Command = [*:null]?[*:0]const u8;
const Read = *const fn (?*anyopaque, c_uint, [*]u8, *usize) callconv(.c) c_int;
const Cancel = *const fn (?*anyopaque) callconv(.c) c_int;
extern "c" fn podtest_lua_supervise(argv: Command, script: [*]const u8, len: usize, timeout_ms: u32, read: ?Read, cancel: ?Cancel, context: ?*anyopaque) c_int;
extern "c" fn podtest_lua_supervise_workspace(argv: Command, script: [*]const u8, len: usize, timeout_ms: u32, read: ?Read, workspace: @TypeOf(&Workspace.readRpc), cancel: ?Cancel, context: ?*anyopaque) c_int;

pub fn main(init: std.process.Init) u8 {
    run(init) catch |err| {
        std.log.err("Lua supervisor acceptance failed: {s}", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn run(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const require_podman = init.environ_map.get("PODTEST_REQUIRE_PODMAN") != null;
    if (args.len < 3) return error.InvalidArguments;
    const runner = args[1];
    const bwrap = args[2];
    const a = init.arena.allocator();
    var command_list: std.ArrayList(?[*:0]const u8) = .empty;
    try command_list.appendSlice(a, &.{
        bwrap,
        "--die-with-parent",
        "--unshare-user",
        "--unshare-pid",
        "--unshare-net",
        "--unshare-ipc",
        "--unshare-uts",
        "--uid",
        "65534",
        "--gid",
        "65534",
        "--clearenv",
        "--disable-userns",
        "--chdir",
        "/",
    });
    for (args[3..]) |library| {
        if (!std.fs.path.isAbsolute(library)) return error.InvalidLibraryPath;
        try command_list.appendSlice(a, &.{ "--ro-bind", library, library });
    }
    try command_list.appendSlice(a, &.{
        "--ro-bind",
        runner,
        "/runner",
        "--",
        "/runner",
        "--rpc",
    });
    const command = try command_list.toOwnedSliceSentinel(a, null);
    const script = "local j=require('judge.runtime'); local a=j.spawn(function() assert(j.fixture_echo('alpha')=='alpha'); print('rpc alpha') end); local b=j.spawn(function() assert(j.fixture_echo('beta')=='beta'); print('rpc beta') end); j.join(a); j.join(b)";
    const rc = podtest_lua_supervise(command, script.ptr, script.len, 5000, null, null, null);
    if (rc != 0) return error.RunnerFailed;
    try checkWorkspace(init, command);
    const sleeper = "local j=require('judge.runtime'); while true do j.sleep(100) end";
    if (podtest_lua_supervise(command, sleeper.ptr, sleeper.len, 1000, null, null, null) != -2) return error.WatchdogFailed;
    const Cancellation = struct {
        fn check(ctx: ?*anyopaque) callconv(.c) c_int {
            const checks: *usize = @ptrCast(@alignCast(ctx.?));
            checks.* += 1;
            return @intFromBool(checks.* >= 8);
        }
    };
    var checks: usize = 0;
    if (podtest_lua_supervise(command, sleeper.ptr, sleeper.len, 5000, null, Cancellation.check, &checks) != -3) return error.CancellationFailed;
    if (init.environ_map.get("PODTEST_PODMAN_SOCKET")) |socket| try checkContainers(init, command, socket) else if (require_podman) return error.ExpectedPodmanSocket;
}

fn checkWorkspace(init: std.process.Init, command: Command) !void {
    const io = init.io;
    const temp = try std.Io.Dir.openDirAbsolute(io, "/tmp", .{});
    defer temp.close(io);
    var random: [16]u8 = undefined;
    try io.randomSecure(&random);
    const name = try std.fmt.allocPrint(init.arena.allocator(), "podtest-lua-{x}", .{&random});
    try temp.createDir(io, name, .fromMode(0o700));
    defer temp.deleteTree(io, name) catch {};
    const dir = try temp.openDir(io, name, .{ .follow_symlinks = false });
    defer dir.close(io);
    try dir.createDir(io, "tests", .fromMode(0o700));
    try dir.writeFile(io, .{ .sub_path = "tests/input", .data = "abcdef" });
    try dir.symLink(io, "tests/input", "link", .{});
    try dir.symLink(io, "tests", "linked-dir", .{ .is_directory = true });
    var workspace: Workspace = .{ .io = io, .dir = dir };
    const script =
        \\local j = require('judge.runtime')
        \\assert(j.workspace_read('tests/input', 2) == 'cdef')
        \\assert(j.workspace_read('tests/input', 6) == nil)
        \\for _, path in ipairs({'../tests/input', '/tests/input', 'tests//input', 'link', 'linked-dir/input'}) do
        \\  assert(not pcall(j.workspace_read, path), path)
        \\end
    ;
    if (podtest_lua_supervise_workspace(command, script.ptr, script.len, 5000, null, &Workspace.readRpc, null, &workspace) != 0)
        return error.WorkspaceRpcFailed;
}

const Streams = struct {
    attach: [2]podman.Attach,

    fn read(ctx: ?*anyopaque, handle: c_uint, out: [*]u8, len: *usize) callconv(.c) c_int {
        const self: *Streams = @ptrCast(@alignCast(ctx.?));
        if (handle < 1 or handle > self.attach.len) return -1;
        const chunk = self.attach[handle - 1].read(out[0..len.*]) catch |err| return if (err == error.WouldBlock) 0 else -1;
        if (chunk) |data| {
            if (data.stream != .stdout) return -1;
            len.* = data.len;
            return 1;
        }
        return 2;
    }
};

fn checkContainers(init: std.process.Init, command: Command, socket: []const u8) !void {
    const a = init.arena.allocator();
    const image = init.environ_map.get("PODTEST_TEST_IMAGE_ID") orelse return error.ExpectedLocalImage;
    if (image.len != 64) return error.ExpectedLocalImage;
    const client: podman.Client = .{ .socket = try a.dupeSentinel(u8, socket, 0), .api_version = "6.2.0" };
    var info_buf: [128 << 10]u8 = undefined;
    const Info = struct { host: struct { security: struct { rootless: bool } } };
    const info = try std.json.parseFromSliceLeaky(Info, a, try client.info(&info_buf), .{ .ignore_unknown_fields = true });
    if (!info.host.security.rootless) return error.RootlessRequired;
    var nonce: [8]u8 = undefined;
    try init.io.randomSecure(&nonce);
    var ids: [2]?podman.Id = @splat(null);
    defer for (ids) |id| if (id) |owned| client.remove(owned) catch |err| std.log.err("fixture cleanup failed: {s}", .{@errorName(err)});
    var streams: Streams = undefined;
    var attached: usize = 0;
    defer for (streams.attach[0..attached]) |*stream| stream.close();
    const commands = [_][]const []const u8{
        &.{ "/bin/sh", "-c", "read -r line && printf alpha" },
        &.{ "/bin/sh", "-c", "printf beta" },
    };
    for (commands, &ids, 0..) |cmd, *id, i| {
        id.* = try client.create(a, .{
            .name = try std.fmt.allocPrint(a, "podtest-phase6-{x}-{d}", .{ &nonce, i }),
            .image = image[0..64].*,
            .command = cmd,
            .live_io = true,
            .stdin = i == 0,
        });
        try client.initContainer(id.*.?);
        streams.attach[i] = try client.attach(id.*.?, i == 0, 3000);
        attached += 1;
    }
    for (ids) |id| try client.start(id.?);
    const script =
        \\local j=require('judge.runtime')
        \\local order={}
        \\local function read(handle)
        \\  local s=''; while true do local part=j.stdout_read(handle); if part==nil then return s end; s=s..part end
        \\end
        \\local first=j.spawn(function() assert(read(1)=='alpha'); order[#order+1]='a' end)
        \\local second=j.spawn(function() assert(read(2)=='beta'); order[#order+1]='b' end)
        \\j.join(second); j.join(first); assert(table.concat(order)=='ba')
    ;
    const Fixture = struct {
        streams: *Streams,
        released: bool = false,
        first_waited: bool = false,
        fn read(ctx: ?*anyopaque, handle: c_uint, out: [*]u8, len: *usize) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const status = Streams.read(self.streams, handle, out, len);
            if (handle == 1 and status == 0 and !self.released) self.first_waited = true;
            if (handle == 2 and status == 2 and !self.released) {
                if (!self.first_waited) return -1;
                const n = self.streams.attach[0].write("\n") catch |err| return if (err == error.WouldBlock) 0 else -1;
                if (n != 1) return -1;
                self.streams.attach[0].closeInput() catch return -1;
                self.released = true;
            }
            return status;
        }
    };
    var fixture: Fixture = .{ .streams = &streams };
    if (podtest_lua_supervise(command, script.ptr, script.len, 5000, Fixture.read, null, &fixture) != 0) return error.ContainerRpcFailed;
    for (&ids) |*id| {
        if (try client.wait(id.*.?, 3000) != 0) return error.ContainerFailed;
        try client.remove(id.*.?);
        id.* = null;
    }
    std.log.info("Two rootless Podman containers passed concurrent Lua stdout RPC", .{});
}
