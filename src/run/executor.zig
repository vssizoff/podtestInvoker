//! Executes one runner.lua inside a prepared run directory.
const std = @import("std");
const lua = @import("../lua/lua.zig");
const api = @import("../lua/api.zig");
const runtime = @import("runtime.zig");
const scheduler = @import("scheduler.zig");
const fs = @import("../util/fs.zig");
const log = @import("../util/log.zig");
const events = @import("../events.zig");
const gpa = @import("../util/mem.zig").gpa;

pub const Options = struct {
    runner: []const u8 = "runner.lua",
    solution_dir: []const u8 = "solution",
};

fn dup(s: []const u8) []u8 {
    return gpa.dupe(u8, s) catch gpa.alloc(u8, 0) catch unreachable;
}

fn emitError(rt: *runtime.RunContext, msg: []const u8, tb: []const u8) void {
    rt.emit(.{ .runner_error = .{ .message = dup(msg), .traceback = dup(tb) } });
}

fn finish(rt: *runtime.RunContext, ok: bool, status: []const u8) void {
    rt.emit(.{ .run_finished = .{ .ok = ok, .status = dup(status) } });
}

fn cleanupContainers(rt: *runtime.RunContext) void {
    rt.containers_mutex.lock();
    const list = rt.containers.toOwnedSlice(gpa) catch &[_]*runtime.Container{};
    rt.containers_mutex.unlock();
    for (list) |c| {
        // deinit performs kill/remove and joins both worker threads
        c.deinit();
    }
    if (list.len > 0) gpa.free(list);
}

/// Run the task.  Consumes `rt` (including its run directory handle) and emits
/// the final `run_finished` event before returning.
pub fn execute(rt: *runtime.RunContext, opts: Options) void {
    defer rt.deinit();

    // The solution directory is part of the public contract even if the
    // archive did not contain it.
    fs.makeDirBeneath(rt.rootfd, opts.solution_dir) catch {};

    const state = api.createState(rt) catch |e| {
        emitError(rt, "cannot initialise Lua state", @errorName(e));
        finish(rt, false, "runner_error");
        return;
    };
    const L = state.L;
    const sched = state.sched;

    const src = fs.readFileBeneath(rt.rootfd, opts.runner, 64 * 1024 * 1024) catch |e| {
        const msg = std.fmt.allocPrint(gpa, "cannot read runner script '{s}': {s}", .{ opts.runner, @errorName(e) }) catch "cannot read runner script";
        defer gpa.free(msg);
        emitError(rt, msg, "");
        cleanupContainers(rt);
        finish(rt, false, "runner_error");
        sched.deinit();
        state.api.deinit();
        lua.lua_close(L);
        return;
    };
    defer gpa.free(src);

    var name_buf: [512]u8 = undefined;
    const chunk_name = std.fmt.bufPrint(&name_buf, "@{s}", .{opts.runner}) catch "@runner.lua";
    name_buf[chunk_name.len] = 0;
    const rc = lua.luaL_loadbufferx(L, src.ptr, src.len, name_buf[0..chunk_name.len :0], "t");
    if (rc != lua.LUA_OK) {
        var len: usize = 0;
        var msg: []const u8 = "cannot load runner script";
        if (lua.lua_tolstring(L, -1, &len)) |p| msg = p[0..len];
        var tb_buf: [4096]u8 = undefined;
        const tb = std.fmt.bufPrint(&tb_buf, "{s}", .{msg}) catch "";
        emitError(rt, tb, "");
        cleanupContainers(rt);
        finish(rt, false, "runner_error");
        sched.deinit();
        state.api.deinit();
        lua.lua_close(L);
        return;
    }

    sched.createMainTask(L) catch |e| {
        emitError(rt, "cannot create main coroutine", @errorName(e));
        cleanupContainers(rt);
        finish(rt, false, "runner_error");
        sched.deinit();
        state.api.deinit();
        lua.lua_close(L);
        return;
    };

    log.info("run {s}: executing {s}", .{ rt.run_id, opts.runner });
    sched.run();

    cleanupContainers(rt);

    if (sched.timed_out) {
        rt.emit(.{ .run_timeout = .{} });
        finish(rt, false, "timeout");
    } else if (sched.stopped) {
        finish(rt, false, "stopped");
    } else if (sched.fatal) {
        finish(rt, false, "runner_error");
    } else {
        finish(rt, true, "ok");
    }

    sched.deinit();
    state.api.deinit();
    lua.lua_close(L);
}

test "lua smoke: sandbox, spawn/join, sleep and reports" {
    const linux = std.os.linux;
    const configmod = @import("../config.zig");
    const podman = @import("../podman/client.zig");
    const sys = @import("../util/sys.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dup_rc = linux.dup(tmp.dir.handle);
    if (linux.errno(dup_rc) != .SUCCESS) return error.DupFailed;
    const rootfd: sys.fd_t = @intCast(dup_rc);

    const src =
        \\assert(os == nil, "os must be removed")
        \\assert(io == nil, "io must be removed")
        \\assert(package == nil, "package must be removed")
        \\assert(debug == nil, "debug must be removed")
        \\assert(require == nil, "require must be removed")
        \\assert(dofile == nil, "dofile must be removed")
        \\assert(loadfile == nil, "loadfile must be removed")
        \\assert(type(string.format) == "function")
        \\assert(type(table.pack) == "function")
        \\assert(type(coroutine.create) == "function")
        \\report.build_log("smoke start")
        \\report.test_started(1)
        \\local h = spawn(function(a)
        \\  sleep(0.01)
        \\  return a + 1
        \\end, 41)
        \\local v = h:join()
        \\assert(v == 42, "join returned " .. tostring(v))
        \\assert(h:done(), "handle should be done")
        \\local waited = 0
        \\local t = timer.after(5, function() waited = 1 end)
        \\t:join()
        \\assert(waited == 1, "timer.after did not fire")
        \\fs.write("out.txt", "hello")
        \\assert(fs.read("out.txt") == "hello")
        \\assert(fs.exists("out.txt"))
        \\fs.append("out.txt", " world")
        \\assert(fs.read("out.txt") == "hello world")
        \\local data, ferr = fs.read("../escape")
        \\assert(data == nil and ferr ~= nil, "fs must reject ..")
        \\report.test_verdict(1, "OK", 1.0)
        \\report.subgroup_score("g", 0.5)
        \\report.problem_score(0.75)
    ;
    try fs.writeFileBeneath(rootfd, "runner.lua", src);

    var cfg = try configmod.Config.initDefaults();
    defer cfg.deinit();
    cfg.stdio_history_limit = 1 << 20;

    var client = podman.Client.init("", "v4.0.0", "test-instance");
    var collector = events.Collector{};

    const rt = try runtime.RunContext.init(
        "smoke",
        "/tmp/podtest-smoke",
        rootfd,
        collector.sink(),
        &cfg,
        &client,
        5000,
        1.0,
    );
    execute(rt, .{});

    var saw_started = false;
    var saw_verdict = false;
    var saw_subgroup = false;
    var saw_problem = false;
    var saw_finished = false;
    var finished_ok = false;
    for (collector.events.items) |ev| switch (ev) {
        .test_started => saw_started = true,
        .test_verdict => |v| {
            saw_verdict = std.mem.eql(u8, v.verdict, "OK");
            try std.testing.expectEqual(@as(u32, 1), v.n);
        },
        .subgroup_score => |v| saw_subgroup = std.mem.eql(u8, v.id, "g"),
        .problem_score => saw_problem = true,
        .run_finished => |v| {
            saw_finished = true;
            finished_ok = v.ok;
        },
        .runner_error => |v| {
            std.debug.print("runner error: {s}\n{s}\n", .{ v.message, v.traceback });
        },
        else => {},
    };
    try std.testing.expect(saw_started);
    try std.testing.expect(saw_verdict);
    try std.testing.expect(saw_subgroup);
    try std.testing.expect(saw_problem);
    try std.testing.expect(saw_finished);
    try std.testing.expect(finished_ok);
    collector.deinit();
}
