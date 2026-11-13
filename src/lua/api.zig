//! Lua-visible API (the runner contract).
const std = @import("std");
const lua = @import("lua.zig");
const runtime = @import("../run/runtime.zig");
const scheduler = @import("../run/scheduler.zig");
const podman = @import("../podman/client.zig");
const events = @import("../events.zig");
const fs = @import("../util/fs.zig");
const sys = @import("../util/sys.zig");
const tar_write = @import("../util/tar_write.zig");
const clock = @import("../util/clock.zig");
const log = @import("../util/log.zig");
const gpa = @import("../util/mem.zig").gpa;

/// The first field MUST remain `current_task`: the scheduler reads it through
/// the light-userdata upvalue stored on every C closure.
pub const Api = struct {
    current_task: ?*scheduler.Task = null,
    rt: *runtime.RunContext,
    sched: *scheduler.Scheduler,
    L: *lua.State,

    pub fn init(rt: *runtime.RunContext, L: *lua.State, sched: *scheduler.Scheduler) !*Api {
        const a = try gpa.create(Api);
        a.* = .{ .rt = rt, .sched = sched, .L = L };
        return a;
    }

    pub fn deinit(self: *Api) void {
        gpa.destroy(self);
    }
};

fn apiOf(L: *lua.State) *Api {
    const p = lua.lua_touserdata(L, lua.lua_upvalueindex(1)).?;
    return @ptrCast(@alignCast(p));
}

fn currentTask(L: *lua.State) ?*scheduler.Task {
    _ = lua.lua_getfield(L, lua.LUA_REGISTRYINDEX, "invoker.current");
    const p = lua.lua_touserdata(L, -1);
    lua.lua_pop(L, 1);
    if (p) |ptr| return @ptrCast(@alignCast(ptr));
    return null;
}

fn setFn(L: *lua.State, a: *Api, name: [*:0]const u8, comptime f: anytype) void {
    lua.lua_pushlightuserdata(L, a);
    lua.lua_pushcclosure(L, lua.wrap(f), 1);
    lua.lua_setfield(L, -2, name);
}

fn setGlobalFn(L: *lua.State, a: *Api, name: [*:0]const u8, comptime f: anytype) void {
    lua.lua_pushlightuserdata(L, a);
    lua.lua_pushcclosure(L, lua.wrap(f), 1);
    lua.lua_setglobal(L, name);
}

fn newTable(L: *lua.State, narr: c_int, nrec: c_int) c_int {
    lua.lua_createtable(L, narr, nrec);
    return lua.lua_gettop(L);
}

// ---------------------------------------------------------------------------
// option helpers
// ---------------------------------------------------------------------------

fn optStr(L: *lua.State, idx: c_int, name: [*:0]const u8, def: []const u8) []const u8 {
    const abs = lua.lua_absindex(L, idx);
    _ = lua.lua_getfield(L, abs, name);
    const v = if (lua.lua_type(L, -1) == lua.LUA_TSTRING) lua.toSlice(L, -1) orelse def else def;
    lua.lua_pop(L, 1);
    return v;
}

fn hasField(L: *lua.State, idx: c_int, name: [*:0]const u8) bool {
    const abs = lua.lua_absindex(L, idx);
    _ = lua.lua_getfield(L, abs, name);
    const t = lua.lua_type(L, -1);
    lua.lua_pop(L, 1);
    return t != lua.LUA_TNIL and t != lua.LUA_TNONE;
}

fn optInt(L: *lua.State, idx: c_int, name: [*:0]const u8, def: i64) i64 {
    const abs = lua.lua_absindex(L, idx);
    _ = lua.lua_getfield(L, abs, name);
    const v = if (lua.lua_type(L, -1) == lua.LUA_TNUMBER) lua.lua_tointeger(L, -1) else def;
    lua.lua_pop(L, 1);
    return v;
}

fn optNum(L: *lua.State, idx: c_int, name: [*:0]const u8, def: f64) f64 {
    const abs = lua.lua_absindex(L, idx);
    _ = lua.lua_getfield(L, abs, name);
    const v = if (lua.lua_type(L, -1) == lua.LUA_TNUMBER) lua.lua_tonumber(L, -1) else def;
    lua.lua_pop(L, 1);
    return v;
}

fn optBool(L: *lua.State, idx: c_int, name: [*:0]const u8, def: bool) bool {
    const abs = lua.lua_absindex(L, idx);
    _ = lua.lua_getfield(L, abs, name);
    const v = if (lua.lua_type(L, -1) == lua.LUA_TBOOLEAN) lua.lua_toboolean(L, -1) != 0 else def;
    lua.lua_pop(L, 1);
    return v;
}

fn argStr(L: *lua.State, idx: c_int) []const u8 {
    return lua.checkSlice(L, idx);
}

fn argOptStr(L: *lua.State, idx: c_int, def: []const u8) []const u8 {
    return lua.optSlice(L, idx, def);
}

fn strOrEmpty(L: *lua.State, idx: c_int) []const u8 {
    const t = lua.lua_type(L, idx);
    if (t == lua.LUA_TNIL or t == lua.LUA_TNONE) return "";
    if (t == lua.LUA_TSTRING or t == lua.LUA_TNUMBER) return lua.toSlice(L, idx) orelse "";
    return "";
}

fn pushError(L: *lua.State, e: anyerror) c_int {
    lua.lua_pushnil(L);
    lua.pushSlice(L, @errorName(e));
    return 2;
}

fn pushBool(L: *lua.State, b: bool) c_int {
    lua.lua_pushboolean(L, @intFromBool(b));
    return 1;
}

fn pushString(L: *lua.State, s: []const u8) c_int {
    lua.pushSlice(L, s);
    return 1;
}

fn parseMemory(L: *lua.State, idx: c_int) ?u64 {
    switch (lua.lua_type(L, idx)) {
        lua.LUA_TNUMBER => {
            const n = lua.lua_tointeger(L, idx);
            if (n <= 0) return null;
            return @intCast(n);
        },
        lua.LUA_TSTRING => {
            const s = std.mem.trim(u8, lua.toSlice(L, idx) orelse return null, " \t");
            if (s.len == 0) return null;
            var mult: u64 = 1;
            var num = s;
            const last = std.ascii.toLower(s[s.len - 1]);
            if (last == 'k' or last == 'm' or last == 'g') {
                mult = switch (last) {
                    'k' => 1024,
                    'm' => 1024 * 1024,
                    'g' => 1024 * 1024 * 1024,
                    else => 1,
                };
                num = s[0 .. s.len - 1];
                if (num.len > 0 and std.ascii.toLower(num[num.len - 1]) == 'b') num = num[0 .. num.len - 1];
            } else if (last == 'b') {
                num = s[0 .. s.len - 1];
            }
            const v = std.fmt.parseInt(u64, std.mem.trim(u8, num, " \t"), 10) catch return null;
            return v * mult;
        },
        else => return null,
    }
}

// ---------------------------------------------------------------------------
// state setup
// ---------------------------------------------------------------------------

pub fn createState(rt: *runtime.RunContext) !struct { L: *lua.State, api: *Api, sched: *scheduler.Scheduler } {
    const L = lua.luaL_newstate() orelse return error.OutOfMemory;
    errdefer lua.lua_close(L);
    _ = lua.luaL_requiref(L, "_G", lua.luaopen_base, 1);
    lua.lua_pop(L, 1);
    _ = lua.luaL_requiref(L, "coroutine", lua.luaopen_coroutine, 1);
    lua.lua_pop(L, 1);
    _ = lua.luaL_requiref(L, "string", lua.luaopen_string, 1);
    lua.lua_pop(L, 1);
    _ = lua.luaL_requiref(L, "table", lua.luaopen_table, 1);
    lua.lua_pop(L, 1);
    _ = lua.luaL_requiref(L, "math", lua.luaopen_math, 1);
    lua.lua_pop(L, 1);
    _ = lua.luaL_requiref(L, "utf8", lua.luaopen_utf8, 1);
    lua.lua_pop(L, 1);

    // The scheduler needs the state; the API needs the scheduler.
    const sched = try scheduler.Scheduler.init(L, rt);
    const api = try Api.init(rt, L, sched);
    errdefer api.deinit();
    try registerSandbox(L, api);
    return .{ .L = L, .api = api, .sched = sched };
}

fn removeGlobal(L: *lua.State, name: [*:0]const u8) void {
    lua.lua_pushnil(L);
    lua.lua_setglobal(L, name);
}

fn registerSandbox(L: *lua.State, a: *Api) !void {
    removeGlobal(L, "os");
    removeGlobal(L, "io");
    removeGlobal(L, "package");
    removeGlobal(L, "require");
    removeGlobal(L, "debug");
    removeGlobal(L, "dofile");
    removeGlobal(L, "loadfile");
    removeGlobal(L, "load");
    removeGlobal(L, "loadstring");

    setGlobalFn(L, a, "print", l_print);
    setGlobalFn(L, a, "log", l_log);
    setGlobalFn(L, a, "spawn", l_spawn);
    setGlobalFn(L, a, "sleep", l_sleep);
    setGlobalFn(L, a, "now", l_now);
    setGlobalFn(L, a, "monotonic", l_now);

    // fs
    _ = newTable(L, 0, 12);
    setFn(L, a, "read", l_fs_read);
    setFn(L, a, "write", l_fs_write);
    setFn(L, a, "append", l_fs_append);
    setFn(L, a, "mkdir", l_fs_mkdir);
    setFn(L, a, "remove", l_fs_remove);
    setFn(L, a, "exists", l_fs_exists);
    setFn(L, a, "stat", l_fs_stat);
    setFn(L, a, "list", l_fs_list);
    setFn(L, a, "readdir", l_fs_list);
    setFn(L, a, "copy", l_fs_copy);
    setFn(L, a, "read_file", l_fs_read);
    setFn(L, a, "write_file", l_fs_write);
    lua.lua_setglobal(L, "fs");

    // image
    _ = newTable(L, 0, 8);
    setFn(L, a, "build", l_image_build);
    setFn(L, a, "pull", l_image_pull);
    setFn(L, a, "remove", l_image_remove);
    setFn(L, a, "exists", l_image_exists);
    setFn(L, a, "build_from_files", l_image_build);
    lua.lua_setglobal(L, "image");

    // network
    _ = newTable(L, 0, 6);
    setFn(L, a, "create", l_network_create);
    setFn(L, a, "remove", l_network_remove);
    setFn(L, a, "exists", l_network_exists);
    lua.lua_setglobal(L, "network");

    // container
    _ = newTable(L, 0, 8);
    setFn(L, a, "create", l_container_create);
    setFn(L, a, "new", l_container_create);
    setFn(L, a, "run", l_container_run);
    lua.lua_setglobal(L, "container");

    // report
    _ = newTable(L, 0, 12);
    setFn(L, a, "test_started", l_report_test_started);
    setFn(L, a, "test_verdict", l_report_test_verdict);
    setFn(L, a, "verdict", l_report_test_verdict);
    setFn(L, a, "subgroup_score", l_report_subgroup_score);
    setFn(L, a, "subgroup", l_report_subgroup_score);
    setFn(L, a, "problem_score", l_report_problem_score);
    setFn(L, a, "problem", l_report_problem_score);
    setFn(L, a, "build_log", l_report_build_log);
    setFn(L, a, "test_stdio", l_report_test_stdio);
    setFn(L, a, "stdio", l_report_test_stdio);
    setFn(L, a, "runner_error", l_report_runner_error);
    lua.lua_setglobal(L, "report");

    // run metadata
    _ = newTable(L, 0, 8);
    lua.pushSlice(L, a.rt.run_id);
    lua.lua_setfield(L, -2, "id");
    lua.pushSlice(L, a.rt.dir_abs);
    lua.lua_setfield(L, -2, "dir");
    var sol_buf: [fs.max_path + 1]u8 = undefined;
    const sol = std.fmt.bufPrint(&sol_buf, "{s}/solution", .{a.rt.dir_abs}) catch a.rt.dir_abs;
    lua.pushSlice(L, sol);
    lua.lua_setfield(L, -2, "solution_dir");
    lua.lua_pushinteger(L, @intCast(a.rt.timeout_ms));
    lua.lua_setfield(L, -2, "timeout_ms");
    setFn(L, a, "elapsed", l_run_elapsed);
    setFn(L, a, "cancel", l_run_cancel);
    lua.lua_setglobal(L, "run");

    try registerContainerMeta(L, a);
    try runPrelude(L);
}

fn runPrelude(L: *lua.State) !void {
    const src =
        \\local _spawn, _sleep = spawn, sleep
        \\timer = {}
        \\function timer.after(ms, fn, ...)
        \\  local args = table.pack(...)
        \\  return _spawn(function()
        \\    _sleep(ms / 1000)
        \\    return fn(table.unpack(args, 1, args.n))
        \\  end)
        \\end
        \\function timer.every(ms, fn, ...)
        \\  local args = table.pack(...)
        \\  local h
        \\  h = _spawn(function()
        \\    while not h:cancelled() do
        \\      _sleep(ms / 1000)
        \\      if h:cancelled() then break end
        \\      if fn(table.unpack(args, 1, args.n)) == false then break end
        \\    end
        \\  end)
        \\  return h
        \\end
        \\function timer.cancel(h) if h then h:cancel() end end
        \\timer.sleep = sleep
        \\timer.now = now
        \\
    ;
    const rc = lua.luaL_loadbufferx(L, src.ptr, src.len, "=invoker-prelude", "t");
    if (rc != lua.LUA_OK) return error.PreludeFailed;
    if (lua.lua_pcall(L, 0, 0, 0) != lua.LUA_OK) return error.PreludeFailed;
}

fn registerContainerMeta(L: *lua.State, a: *Api) !void {
    _ = lua.luaL_newmetatable(L, "invoker.container");
    _ = newTable(L, 0, 24);
    setFn(L, a, "start", l_c_start);
    setFn(L, a, "stop", l_c_stop);
    setFn(L, a, "kill", l_c_kill);
    setFn(L, a, "remove", l_c_remove);
    setFn(L, a, "wait", l_c_wait);
    setFn(L, a, "write", l_c_write);
    setFn(L, a, "close_stdin", l_c_close_stdin);
    setFn(L, a, "read", l_c_read);
    setFn(L, a, "stdout", l_c_stdout);
    setFn(L, a, "stderr", l_c_stderr);
    setFn(L, a, "output", l_c_stdout);
    setFn(L, a, "history", l_c_history);
    setFn(L, a, "pipe_to", l_c_pipe_to);
    setFn(L, a, "pipe_from", l_c_pipe_to);
    setFn(L, a, "cpu_time", l_c_cpu_time);
    setFn(L, a, "raw_cpu_time", l_c_raw_cpu_time);
    setFn(L, a, "memory_peak", l_c_memory_peak);
    setFn(L, a, "exit_code", l_c_exit_code);
    setFn(L, a, "status", l_c_status);
    setFn(L, a, "oom_killed", l_c_oom);
    setFn(L, a, "id", l_c_id);
    setFn(L, a, "name", l_c_name);
    setFn(L, a, "inspect", l_c_inspect);
    setFn(L, a, "set_test", l_c_set_test);
    setFn(L, a, "is_done", l_c_is_done);
    setFn(L, a, "__tostring", l_c_tostring);
    lua.lua_setfield(L, -2, "__index");
    lua.lua_pop(L, 1);
}

const ContainerBox = extern struct { c: *runtime.Container };

fn getContainer(L: *lua.State, idx: c_int) ?*runtime.Container {
    const p = lua.luaL_checkudata(L, idx, "invoker.container") orelse return null;
    const box: *ContainerBox = @ptrCast(@alignCast(p));
    return box.c;
}

fn pushContainer(L: *lua.State, c: *runtime.Container) void {
    const mem = lua.lua_newuserdatauv(L, @sizeOf(ContainerBox), 0) orelse return;
    const box: *ContainerBox = @ptrCast(@alignCast(mem));
    box.c = c;
    lua.luaL_setmetatable(L, "invoker.container");
}

// ---------------------------------------------------------------------------
// globals
// ---------------------------------------------------------------------------

fn l_print(L: *lua.State) c_int {
    const a = apiOf(L);
    const n = lua.lua_gettop(L);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var i: c_int = 1;
    while (i <= n) : (i += 1) {
        if (i > 1) buf.append(gpa, '\t') catch {};
        var len: usize = 0;
        const p = lua.luaL_tolstring(L, i, &len) orelse continue;
        buf.appendSlice(gpa, p[0..len]) catch {};
        lua.lua_pop(L, 1);
    }
    log.runnerPrint(a.rt.run_id, buf.items);
    return 0;
}

fn l_log(L: *lua.State) c_int {
    return l_print(L);
}

fn l_spawn(L: *lua.State) c_int {
    const a = apiOf(L);
    return a.sched.spawnFromStack(L);
}

fn l_sleep(L: *lua.State) c_int {
    const a = apiOf(L);
    const secs = lua.lua_tonumber(L, 1);
    if (secs <= 0) return 0;
    const t = currentTask(L) orelse return 0;
    const deadline = clock.nowNs() + @as(i128, @intFromFloat(secs * @as(f64, @floatFromInt(clock.ns_per_sec))));
    a.sched.setWait(t, .{ .sleep = deadline });
    return lua.lua_yield(L, 0);
}

fn l_now(L: *lua.State) c_int {
    lua.lua_pushnumber(L, @as(f64, @floatFromInt(clock.nowNs())) / @as(f64, @floatFromInt(clock.ns_per_sec)));
    return 1;
}

// ---------------------------------------------------------------------------
// fs
// ---------------------------------------------------------------------------

fn l_fs_read(L: *lua.State) c_int {
    const a = apiOf(L);
    const path = argStr(L, 1);
    const limit: usize = if (lua.lua_type(L, 2) == lua.LUA_TNUMBER)
        @intCast(@max(lua.lua_tointeger(L, 2), 1))
    else
        512 * 1024 * 1024;
    const data = fs.readFileBeneath(a.rt.rootfd, path, limit) catch |e| return pushError(L, e);
    defer gpa.free(data);
    lua.pushSlice(L, data);
    return 1;
}

fn l_fs_write(L: *lua.State) c_int {
    const a = apiOf(L);
    const path = argStr(L, 1);
    const data = argStr(L, 2);
    fs.writeFileBeneath(a.rt.rootfd, path, data) catch |e| return pushError(L, e);
    return pushBool(L, true);
}

fn l_fs_append(L: *lua.State) c_int {
    const a = apiOf(L);
    const path = argStr(L, 1);
    const data = argStr(L, 2);
    fs.appendFileBeneath(a.rt.rootfd, path, data) catch |e| return pushError(L, e);
    return pushBool(L, true);
}

fn l_fs_mkdir(L: *lua.State) c_int {
    const a = apiOf(L);
    const path = argStr(L, 1);
    fs.makeDirBeneath(a.rt.rootfd, path) catch |e| return pushError(L, e);
    return pushBool(L, true);
}

fn l_fs_remove(L: *lua.State) c_int {
    const a = apiOf(L);
    const path = argStr(L, 1);
    fs.removeTreeBeneath(a.rt.rootfd, path) catch |e| return pushError(L, e);
    return pushBool(L, true);
}

fn l_fs_exists(L: *lua.State) c_int {
    const a = apiOf(L);
    const path = argStr(L, 1);
    _ = fs.statBeneath(a.rt.rootfd, path, true) catch return pushBool(L, false);
    return pushBool(L, true);
}

fn l_fs_stat(L: *lua.State) c_int {
    const a = apiOf(L);
    const path = argStr(L, 1);
    const st = fs.statBeneath(a.rt.rootfd, path, true) catch |e| return pushError(L, e);
    _ = newTable(L, 0, 3);
    lua.lua_pushinteger(L, @intCast(st.size));
    lua.lua_setfield(L, -2, "size");
    lua.lua_pushboolean(L, @intFromBool(st.is_dir));
    lua.lua_setfield(L, -2, "is_dir");
    lua.lua_pushinteger(L, @intCast(st.mode));
    lua.lua_setfield(L, -2, "mode");
    return 1;
}

fn l_fs_copy(L: *lua.State) c_int {
    const a = apiOf(L);
    const src = argStr(L, 1);
    const dst = argStr(L, 2);
    const data = fs.readFileBeneath(a.rt.rootfd, src, 512 * 1024 * 1024) catch |e| return pushError(L, e);
    defer gpa.free(data);
    fs.writeFileBeneath(a.rt.rootfd, dst, data) catch |e| return pushError(L, e);
    return pushBool(L, true);
}

const ListCtx = struct {
    L: *lua.State,
    tbl: c_int,
    i: c_int = 0,
    err: ?anyerror = null,
    fn add(self: *@This(), ent: sys.DirEntry) anyerror!void {
        self.i += 1;
        lua.lua_createtable(self.L, 0, 2);
        lua.pushSlice(self.L, ent.name);
        lua.lua_setfield(self.L, -2, "name");
        const ty = switch (ent.kind) {
            .dir => "dir",
            .file => "file",
            .symlink => "symlink",
            else => "other",
        };
        lua.pushSlice(self.L, ty);
        lua.lua_setfield(self.L, -2, "type");
        lua.lua_rawseti(self.L, self.tbl, self.i);
    }
};

fn l_fs_list(L: *lua.State) c_int {
    const a = apiOf(L);
    const path = argOptStr(L, 1, ".");
    const dir = if (std.mem.eql(u8, path, ".") or path.len == 0)
        (sys.openat(a.rt.rootfd, ".", .{
            .ACCMODE = .RDONLY,
            .DIRECTORY = true,
            .CLOEXEC = true,
        }, 0) catch |e| return pushError(L, e))
    else blk: {
        var nb: [fs.max_path + 1]u8 = undefined;
        const norm = fs.normalizeRel(&nb, path) catch |e| return pushError(L, e);
        break :blk fs.openDirBeneath(a.rt.rootfd, norm) catch |e| return pushError(L, e);
    };
    defer sys.close(dir);
    const tbl = newTable(L, 0, 0);
    var ctx = ListCtx{ .L = L, .tbl = tbl };
    sys.listDir(dir, &ctx, ListCtx.add) catch |e| return pushError(L, e);
    return 1;
}

// ---------------------------------------------------------------------------
// report
// ---------------------------------------------------------------------------

fn l_report_test_started(L: *lua.State) c_int {
    const a = apiOf(L);
    const n: u32 = @intCast(@max(lua.lua_tointeger(L, 1), 0));
    a.rt.setCurrentTest(n);
    a.rt.emit(.{ .test_started = .{ .n = n } });
    return 0;
}

fn l_report_test_verdict(L: *lua.State) c_int {
    const a = apiOf(L);
    const n: u32 = @intCast(@max(lua.lua_tointeger(L, 1), 0));
    const verdict = gpa.dupe(u8, strOrEmpty(L, 2)) catch return pushError(L, error.OutOfMemory);
    const has_score = lua.lua_type(L, 3) == lua.LUA_TNUMBER;
    const score: ?f64 = if (has_score) lua.lua_tonumber(L, 3) else null;
    const gd: ?[]u8 = if (lua.lua_type(L, 4) == lua.LUA_TSTRING)
        (gpa.dupe(u8, lua.toSlice(L, 4) orelse "") catch null)
    else
        null;
    a.rt.setCurrentTest(n);
    a.rt.emit(.{ .test_verdict = .{ .n = n, .verdict = verdict, .score = score, .grader_data = gd } });
    return 0;
}

fn l_report_subgroup_score(L: *lua.State) c_int {
    const a = apiOf(L);
    const id = gpa.dupe(u8, strOrEmpty(L, 1)) catch return pushError(L, error.OutOfMemory);
    const score = lua.lua_tonumber(L, 2);
    const gd: ?[]u8 = if (lua.lua_type(L, 3) == lua.LUA_TSTRING)
        (gpa.dupe(u8, lua.toSlice(L, 3) orelse "") catch null)
    else
        null;
    a.rt.emit(.{ .subgroup_score = .{ .id = id, .score = score, .grader_data = gd } });
    return 0;
}

fn l_report_problem_score(L: *lua.State) c_int {
    const a = apiOf(L);
    const score = lua.lua_tonumber(L, 1);
    const gd: ?[]u8 = if (lua.lua_type(L, 2) == lua.LUA_TSTRING)
        (gpa.dupe(u8, lua.toSlice(L, 2) orelse "") catch null)
    else
        null;
    a.rt.emit(.{ .problem_score = .{ .score = score, .grader_data = gd } });
    return 0;
}

fn l_report_build_log(L: *lua.State) c_int {
    const a = apiOf(L);
    const text = gpa.dupe(u8, strOrEmpty(L, 1)) catch return pushError(L, error.OutOfMemory);
    a.rt.emit(.{ .build_log = .{ .text = text } });
    return 0;
}

fn l_report_test_stdio(L: *lua.State) c_int {
    const a = apiOf(L);
    const n: u32 = @intCast(@max(lua.lua_tointeger(L, 1), 0));
    const stdin = gpa.dupe(u8, strOrEmpty(L, 2)) catch return pushError(L, error.OutOfMemory);
    const stdout = gpa.dupe(u8, strOrEmpty(L, 3)) catch {
        gpa.free(stdin);
        return pushError(L, error.OutOfMemory);
    };
    const stderr = gpa.dupe(u8, strOrEmpty(L, 4)) catch {
        gpa.free(stdin);
        gpa.free(stdout);
        return pushError(L, error.OutOfMemory);
    };
    a.rt.emit(.{ .test_stdio = .{ .n = n, .stdin = stdin, .stdout = stdout, .stderr = stderr } });
    return 0;
}

fn l_report_runner_error(L: *lua.State) c_int {
    const a = apiOf(L);
    const msg = gpa.dupe(u8, strOrEmpty(L, 1)) catch return pushError(L, error.OutOfMemory);
    const tb = gpa.dupe(u8, strOrEmpty(L, 2)) catch {
        gpa.free(msg);
        return pushError(L, error.OutOfMemory);
    };
    a.rt.emit(.{ .runner_error = .{ .message = msg, .traceback = tb } });
    return 0;
}

// ---------------------------------------------------------------------------
// image / network
// ---------------------------------------------------------------------------

fn l_image_pull(L: *lua.State) c_int {
    const a = apiOf(L);
    const ref = argStr(L, 1);
    a.rt.podman_client.pullImage(ref) catch |e| return pushError(L, e);
    return pushBool(L, true);
}

fn l_image_exists(L: *lua.State) c_int {
    const a = apiOf(L);
    const ref = argStr(L, 1);
    return pushBool(L, a.rt.podman_client.imageExists(ref));
}

fn l_image_remove(L: *lua.State) c_int {
    const a = apiOf(L);
    const ref = argStr(L, 1);
    a.rt.podman_client.removeImage(ref) catch |e| return pushError(L, e);
    return pushBool(L, true);
}

fn labelsArray(rt: *runtime.RunContext, extra: ?[]const podman.Label) ![]podman.Label {
    var list: std.ArrayList(podman.Label) = .empty;
    errdefer list.deinit(gpa);
    try list.append(gpa, .{ .key = "managed-by", .value = "invoker" });
    try list.append(gpa, .{ .key = "invoker.instance", .value = rt.podman_client.instance_id });
    try list.append(gpa, .{ .key = "run", .value = rt.run_id });
    if (extra) |ex| try list.appendSlice(gpa, ex);
    return list.toOwnedSlice(gpa);
}

fn l_image_build(L: *lua.State) c_int {
    const a = apiOf(L);
    const rt = a.rt;
    const opts = 1;
    var tag_buf: [256]u8 = undefined;
    var tag: []const u8 = optStr(L, opts, "tag", "");
    if (tag.len == 0) {
        const gen = rt.nextName("img") catch return pushError(L, error.OutOfMemory);
        defer gpa.free(gen);
        tag = std.fmt.bufPrint(&tag_buf, "{s}", .{gen}) catch return pushError(L, error.OutOfMemory);
    }
    const dockerfile = optStr(L, opts, "dockerfile", "Dockerfile");

    var tar: []u8 = undefined;
    const ctx_type = blk: {
        _ = lua.lua_getfield(L, opts, "context");
        const t = lua.lua_type(L, -1);
        lua.lua_pop(L, 1);
        break :blk t;
    };
    if (ctx_type == lua.LUA_TTABLE) {
        var b = tar_write.Builder{};
        defer b.deinit();
        const tbl = blk: {
            _ = lua.lua_getfield(L, opts, "context");
            break :blk lua.lua_gettop(L);
        };
        defer lua.lua_pop(L, 1);
        lua.lua_pushnil(L);
        while (lua.lua_next(L, tbl) != 0) {
            if (lua.lua_type(L, -2) == lua.LUA_TSTRING and lua.lua_type(L, -1) == lua.LUA_TSTRING) {
                const name = lua.toSlice(L, -2) orelse "";
                const data = lua.toSlice(L, -1) orelse "";
                b.addFile(name, data, 0o644) catch |e| {
                    lua.lua_pop(L, 2);
                    return pushError(L, e);
                };
            }
            lua.lua_pop(L, 1);
        }
        tar = b.finish() catch |e| return pushError(L, e);
    } else if (hasField(L, opts, "files")) {
        var b = tar_write.Builder{};
        defer b.deinit();
        const tbl = blk: {
            _ = lua.lua_getfield(L, opts, "files");
            break :blk lua.lua_gettop(L);
        };
        defer lua.lua_pop(L, 1);
        lua.lua_pushnil(L);
        while (lua.lua_next(L, tbl) != 0) {
            if (lua.lua_type(L, -2) == lua.LUA_TSTRING and lua.lua_type(L, -1) == lua.LUA_TSTRING) {
                const name = lua.toSlice(L, -2) orelse "";
                const data = lua.toSlice(L, -1) orelse "";
                b.addFile(name, data, 0o644) catch |e| {
                    lua.lua_pop(L, 2);
                    return pushError(L, e);
                };
            }
            lua.lua_pop(L, 1);
        }
        tar = b.finish() catch |e| return pushError(L, e);
    } else {
        const ctx = optStr(L, opts, "context", ".");
        tar = tar_write.contextFromDir(rt.rootfd, ctx) catch |e| return pushError(L, e);
    }
    defer gpa.free(tar);

    const labels = labelsArray(rt, null) catch return pushError(L, error.OutOfMemory);
    defer gpa.free(labels);
    rt.podman_client.buildImage(tar, tag, dockerfile, labels) catch |e| return pushError(L, e);
    rt.addImage(tag) catch {};
    lua.pushSlice(L, tag);
    return 1;
}

fn l_network_create(L: *lua.State) c_int {
    const a = apiOf(L);
    const rt = a.rt;
    var name_buf: [256]u8 = undefined;
    var name: []const u8 = argOptStr(L, 1, "");
    if (name.len == 0) {
        const gen = rt.nextName("net") catch return pushError(L, error.OutOfMemory);
        defer gpa.free(gen);
        name = std.fmt.bufPrint(&name_buf, "{s}", .{gen}) catch return pushError(L, error.OutOfMemory);
    }
    const labels = labelsArray(rt, null) catch return pushError(L, error.OutOfMemory);
    defer gpa.free(labels);
    rt.podman_client.createNetwork(name, labels) catch |e| return pushError(L, e);
    rt.addNetwork(name) catch {};
    lua.pushSlice(L, name);
    return 1;
}

fn l_network_remove(L: *lua.State) c_int {
    const a = apiOf(L);
    const name = argStr(L, 1);
    a.rt.podman_client.removeNetwork(name) catch |e| return pushError(L, e);
    return pushBool(L, true);
}

fn l_network_exists(L: *lua.State) c_int {
    const a = apiOf(L);
    const name = argStr(L, 1);
    return pushBool(L, a.rt.podman_client.networkExists(name));
}

// ---------------------------------------------------------------------------
// container creation
// ---------------------------------------------------------------------------

const MountOwned = struct { host: []u8, target: []const u8, ro: bool };

fn l_container_create(L: *lua.State) c_int {
    const a = apiOf(L);
    const rt = a.rt;
    const opts = 1;
    if (lua.lua_type(L, opts) != lua.LUA_TTABLE) return lua.throw(L, "container.create expects a table");

    const image = optStr(L, opts, "image", "");
    if (image.len == 0) return lua.throw(L, "container.create: image is required");
    const image_owned = gpa.dupe(u8, image) catch return pushError(L, error.OutOfMemory);
    var image_transferred = false;
    defer if (!image_transferred) gpa.free(image_owned);

    // command
    var cmd_list: std.ArrayList([]const u8) = .empty;
    defer cmd_list.deinit(gpa);
    {
        _ = lua.lua_getfield(L, opts, "command");
        const t = lua.lua_type(L, -1);
        if (t == lua.LUA_TSTRING) {
            cmd_list.append(gpa, lua.toSlice(L, -1) orelse "") catch {};
        } else if (t == lua.LUA_TTABLE) {
            const tidx = lua.lua_gettop(L);
            var i: c_int = 1;
            while (true) : (i += 1) {
                _ = lua.lua_rawgeti(L, tidx, i);
                if (lua.lua_type(L, -1) == lua.LUA_TNIL) {
                    lua.lua_pop(L, 1);
                    break;
                }
                if (lua.lua_type(L, -1) == lua.LUA_TSTRING) {
                    cmd_list.append(gpa, lua.toSlice(L, -1) orelse "") catch {};
                }
                lua.lua_pop(L, 1);
            }
        }
        lua.lua_pop(L, 1);
    }

    // env
    var env_list: std.ArrayList([]const u8) = .empty;
    defer env_list.deinit(gpa);
    var env_owned: std.ArrayList([]u8) = .empty;
    defer {
        for (env_owned.items) |p| gpa.free(p);
        env_owned.deinit(gpa);
    }
    {
        _ = lua.lua_getfield(L, opts, "env");
        if (lua.lua_type(L, -1) == lua.LUA_TTABLE) {
            const tidx = lua.lua_gettop(L);
            // array part
            var i: c_int = 1;
            while (true) : (i += 1) {
                _ = lua.lua_rawgeti(L, tidx, i);
                if (lua.lua_type(L, -1) == lua.LUA_TNIL) {
                    lua.lua_pop(L, 1);
                    break;
                }
                if (lua.lua_type(L, -1) == lua.LUA_TSTRING) env_list.append(gpa, lua.toSlice(L, -1) orelse "") catch {};
                lua.lua_pop(L, 1);
            }
            // map part
            lua.lua_pushnil(L);
            while (lua.lua_next(L, tidx) != 0) {
                if (lua.lua_type(L, -2) == lua.LUA_TSTRING and lua.lua_type(L, -1) == lua.LUA_TSTRING) {
                    const k = lua.toSlice(L, -2) orelse "";
                    const v = lua.toSlice(L, -1) orelse "";
                    const pair = std.fmt.allocPrint(gpa, "{s}={s}", .{ k, v }) catch null;
                    if (pair) |p| {
                        var ok = true;
                        env_owned.append(gpa, p) catch {
                            gpa.free(p);
                            ok = false;
                        };
                        if (ok) env_list.append(gpa, p) catch {};
                    }
                }
                lua.lua_pop(L, 1);
            }
        }
        lua.lua_pop(L, 1);
    }

    // mounts
    var mounts: std.ArrayList(MountOwned) = .empty;
    defer {
        for (mounts.items) |m| gpa.free(m.host);
        mounts.deinit(gpa);
    }
    {
        _ = lua.lua_getfield(L, opts, "mounts");
        if (lua.lua_type(L, -1) == lua.LUA_TTABLE) {
            const tidx = lua.lua_gettop(L);
            var i: c_int = 1;
            while (true) : (i += 1) {
                _ = lua.lua_rawgeti(L, tidx, i);
                if (lua.lua_type(L, -1) == lua.LUA_TNIL) {
                    lua.lua_pop(L, 1);
                    break;
                }
                if (lua.lua_type(L, -1) == lua.LUA_TTABLE) {
                    const m = lua.lua_gettop(L);
                    const source = optStr(L, m, "source", "");
                    const target = optStr(L, m, "target", optStr(L, m, "destination", ""));
                    const ro = optBool(L, m, "read_only", optBool(L, m, "ro", false));
                    if (source.len > 0 and target.len > 0 and target[0] == '/') {
                        const host = fs.resolveWithin(rt.rootfd, rt.dir_abs, source) catch {
                            lua.lua_pop(L, 2);
                            return lua.throwFmt(L, "mount source is outside the run directory: {s}", .{source});
                        };
                        mounts.append(gpa, .{ .host = host, .target = target, .ro = ro }) catch {};
                    }
                }
                lua.lua_pop(L, 1);
            }
        }
        lua.lua_pop(L, 1);
    }

    // networks
    var nets: std.ArrayList([]const u8) = .empty;
    defer nets.deinit(gpa);
    var net_mode: ?[]const u8 = null;
    {
        _ = lua.lua_getfield(L, opts, "network");
        const t = lua.lua_type(L, -1);
        if (t == lua.LUA_TSTRING) {
            const n = lua.toSlice(L, -1) orelse "";
            if (n.len == 0 or std.mem.eql(u8, n, "none")) {
                // no network
            } else if (std.mem.eql(u8, n, "host")) {
                net_mode = "host";
            } else {
                nets.append(gpa, n) catch {};
            }
        } else if (t == lua.LUA_TTABLE) {
            const tidx = lua.lua_gettop(L);
            var i: c_int = 1;
            while (true) : (i += 1) {
                _ = lua.lua_rawgeti(L, tidx, i);
                if (lua.lua_type(L, -1) == lua.LUA_TNIL) {
                    lua.lua_pop(L, 1);
                    break;
                }
                if (lua.lua_type(L, -1) == lua.LUA_TSTRING) nets.append(gpa, lua.toSlice(L, -1) orelse "") catch {};
                lua.lua_pop(L, 1);
            }
        }
        lua.lua_pop(L, 1);
    }

    const stdio_s = optStr(L, opts, "stdio", "capture");
    const stdio = runtime.StdioMode.parse(stdio_s) orelse return lua.throwFmt(L, "unknown stdio mode: {s}", .{stdio_s});
    const test_no: u32 = @intCast(@max(optInt(L, opts, "test", @intCast(rt.currentTest())), 0));

    var mem: ?u64 = null;
    if (hasField(L, opts, "memory")) {
        _ = lua.lua_getfield(L, opts, "memory");
        mem = parseMemory(L, -1);
        lua.lua_pop(L, 1);
    } else if (hasField(L, opts, "memory_mb")) {
        const mb = optInt(L, opts, "memory_mb", 0);
        if (mb > 0) mem = @as(u64, @intCast(mb)) * 1024 * 1024;
    }

    var name_buf: [256]u8 = undefined;
    var name: []const u8 = optStr(L, opts, "name", "");
    if (name.len == 0) {
        const gen = rt.nextName("c") catch return pushError(L, error.OutOfMemory);
        defer gpa.free(gen);
        name = std.fmt.bufPrint(&name_buf, "{s}", .{gen}) catch return pushError(L, error.OutOfMemory);
    }
    const name_owned = gpa.dupe(u8, name) catch return pushError(L, error.OutOfMemory);
    var name_transferred = false;
    defer if (!name_transferred) gpa.free(name_owned);

    const extra_labels = [_]podman.Label{.{ .key = "invoker.name", .value = name }};
    const labels = labelsArray(rt, &extra_labels) catch return pushError(L, error.OutOfMemory);
    defer gpa.free(labels);

    var pmounts: std.ArrayList(podman.Mount) = .empty;
    defer pmounts.deinit(gpa);
    for (mounts.items) |m| pmounts.append(gpa, .{ .host_abs = m.host, .container_path = m.target, .read_only = m.ro }) catch {};

    const has_io = stdio != .none;
    const want_stdin = has_io and optBool(L, opts, "stdin", true);
    const want_stdout = has_io and optBool(L, opts, "stdout", true);
    const want_stderr = has_io and optBool(L, opts, "stderr", true);
    const workdir = optStr(L, opts, "workdir", "");
    const hostname = optStr(L, opts, "hostname", "");
    const user = optStr(L, opts, "user", "");

    const id = rt.podman_client.createContainer(.{
        .image = image_owned,
        .name = name_owned,
        .labels = labels,
        .stdin = want_stdin,
        .stdout = want_stdout,
        .stderr = want_stderr,
        .command = if (cmd_list.items.len > 0) cmd_list.items else null,
        .mounts = pmounts.items,
        .memory_bytes = mem,
        .networks = nets.items,
        .env = env_list.items,
        .workdir = if (workdir.len > 0) workdir else null,
        .hostname = if (hostname.len > 0) hostname else null,
        .user = if (user.len > 0) user else null,
        .network_mode = net_mode,
    }) catch |e| return pushError(L, e);

    const c = runtime.Container.init(rt, id, name_owned, image_owned, stdio, test_no) catch {
        rt.podman_client.removeContainer(id) catch {};
        gpa.free(id);
        return pushError(L, error.OutOfMemory);
    };
    // Container now owns the name and image strings.
    name_transferred = true;
    image_transferred = true;
    rt.addContainer(c) catch {};
    if (hasField(L, opts, "pipe_to")) {
        _ = lua.lua_getfield(L, opts, "pipe_to");
        if (getContainer(L, -1)) |dst| c.pipe_to = dst;
        lua.lua_pop(L, 1);
    }
    pushContainer(L, c);
    return 1;
}

fn l_container_run(L: *lua.State) c_int {
    const n = l_container_create(L);
    if (n != 1) return n;
    const c = getContainer(L, -1) orelse return lua.throw(L, "invalid container");
    c.start() catch |e| return pushError(L, e);
    return 1;
}

// ---------------------------------------------------------------------------
// container methods
// ---------------------------------------------------------------------------

fn l_c_start(L: *lua.State) c_int {
    const c = getContainer(L, 1) orelse return lua.throw(L, "invalid container");
    c.start() catch |e| return pushError(L, e);
    return pushBool(L, true);
}

fn l_c_stop(L: *lua.State) c_int {
    const c = getContainer(L, 1) orelse return lua.throw(L, "invalid container");
    const grace: u64 = if (lua.lua_type(L, 2) == lua.LUA_TNUMBER)
        @intCast(@max(lua.lua_tointeger(L, 2), 0))
    else
        c.rt.cfg.stop_grace_ms;
    c.stop(grace);
    return pushBool(L, true);
}

fn l_c_kill(L: *lua.State) c_int {
    const c = getContainer(L, 1) orelse return lua.throw(L, "invalid container");
    c.kill();
    return pushBool(L, true);
}

fn l_c_remove(L: *lua.State) c_int {
    const c = getContainer(L, 1) orelse return lua.throw(L, "invalid container");
    c.remove();
    return pushBool(L, true);
}

fn pushWaitInfo(L: *lua.State, c: *runtime.Container) void {
    lua.lua_createtable(L, 0, 3);
    lua.lua_pushboolean(L, @intFromBool(c.oom_killed));
    lua.lua_setfield(L, -2, "oom");
    lua.pushSlice(L, c.error_message);
    lua.lua_setfield(L, -2, "error");
    lua.lua_pushboolean(L, @intFromBool(c.killed));
    lua.lua_setfield(L, -2, "killed");
}

fn l_c_wait(L: *lua.State) c_int {
    const a = apiOf(L);
    const c = getContainer(L, 1) orelse return lua.throw(L, "invalid container");
    if (c.isDone()) {
        lua.lua_pushinteger(L, c.waitExit());
        pushWaitInfo(L, c);
        return 2;
    }
    const t = currentTask(L) orelse return lua.throw(L, "wait outside a coroutine");
    a.sched.setWait(t, .{ .wait_container = c });
    return lua.lua_yield(L, 0);
}

fn l_c_write(L: *lua.State) c_int {
    const c = getContainer(L, 1) orelse return lua.throw(L, "invalid container");
    const data = argStr(L, 2);
    c.writeStdin(data) catch |e| return pushError(L, e);
    lua.lua_pushinteger(L, @intCast(data.len));
    return 1;
}

fn l_c_close_stdin(L: *lua.State) c_int {
    const c = getContainer(L, 1) orelse return lua.throw(L, "invalid container");
    c.closeStdin();
    return pushBool(L, true);
}

fn readOne(c: *runtime.Container, stream: runtime.Stream, max: usize) !?[]u8 {
    return c.readAvailable(stream, max);
}

fn l_c_read(L: *lua.State) c_int {
    const a = apiOf(L);
    const c = getContainer(L, 1) orelse return lua.throw(L, "invalid container");
    const opts = 2;
    const is_opts_table = lua.lua_type(L, opts) == lua.LUA_TTABLE;
    const stream_s = if (is_opts_table) optStr(L, opts, "stream", "stdout") else "stdout";
    const any = std.mem.eql(u8, stream_s, "all") or std.mem.eql(u8, stream_s, "combined");
    const stream: runtime.Stream = if (std.mem.eql(u8, stream_s, "stderr")) .stderr else .stdout;
    const max: usize = if (is_opts_table)
        @intCast(@max(optInt(L, opts, "max", 1024 * 1024), 1))
    else
        1024 * 1024;
    const timeout_present = is_opts_table and hasField(L, opts, "timeout");
    const timeout = if (is_opts_table) optNum(L, opts, "timeout", -1) else -1;

    if (any) {
        if (readOne(c, .stdout, max) catch null) |data| {
            if (data.len > 0) {
                defer gpa.free(data);
                lua.pushSlice(L, data);
                return 1;
            }
            gpa.free(data);
        }
        if (readOne(c, .stderr, max) catch null) |data| {
            if (data.len > 0) {
                defer gpa.free(data);
                lua.pushSlice(L, data);
                return 1;
            }
            gpa.free(data);
        }
    } else {
        if (readOne(c, stream, max) catch null) |data| {
            if (data.len > 0) {
                defer gpa.free(data);
                lua.pushSlice(L, data);
                return 1;
            }
            gpa.free(data);
        }
    }

    if (c.isDone() or (timeout_present and timeout == 0)) {
        lua.lua_pushnil(L);
        return 1;
    }
    const t = currentTask(L) orelse return lua.throw(L, "read outside a coroutine");
    const deadline: i128 = if (timeout > 0)
        clock.nowNs() + @as(i128, @intFromFloat(timeout * @as(f64, @floatFromInt(clock.ns_per_sec))))
    else
        0;
    a.sched.setWait(t, .{ .read_container = .{ .c = c, .stream = stream, .max = max, .deadline = deadline, .any = any } });
    return lua.lua_yield(L, 0);
}

fn l_c_stdout(L: *lua.State) c_int {
    const c = getContainer(L, 1) orelse return lua.throw(L, "invalid container");
    const data = c.snapshot(.stdout) catch return pushError(L, error.OutOfMemory);
    defer gpa.free(data);
    lua.pushSlice(L, data);
    return 1;
}

fn l_c_stderr(L: *lua.State) c_int {
    const c = getContainer(L, 1) orelse return lua.throw(L, "invalid container");
    const data = c.snapshot(.stderr) catch return pushError(L, error.OutOfMemory);
    defer gpa.free(data);
    lua.pushSlice(L, data);
    return 1;
}

fn l_c_history(L: *lua.State) c_int {
    const c = getContainer(L, 1) orelse return lua.throw(L, "invalid container");
    _ = newTable(L, 0, 3);
    const out = c.snapshot(.stdout) catch return pushError(L, error.OutOfMemory);
    defer gpa.free(out);
    lua.pushSlice(L, out);
    lua.lua_setfield(L, -2, "stdout");
    const err = c.snapshot(.stderr) catch return pushError(L, error.OutOfMemory);
    defer gpa.free(err);
    lua.pushSlice(L, err);
    lua.lua_setfield(L, -2, "stderr");
    lua.lua_pushboolean(L, @intFromBool(c.truncated(.stdout) or c.truncated(.stderr)));
    lua.lua_setfield(L, -2, "truncated");
    return 1;
}

fn l_c_pipe_to(L: *lua.State) c_int {
    const c = getContainer(L, 1) orelse return lua.throw(L, "invalid container");
    const dst = getContainer(L, 2) orelse return lua.throw(L, "pipe_to expects a container");
    c.pipe_to = dst;
    return pushBool(L, true);
}

fn refreshStats(c: *runtime.Container) void {
    if (c.isDone()) return;
    const info = c.rt.podman_client.inspectContainer(c.id) catch return;
    defer {
        var i = info;
        i.deinit();
    }
    if (info.pid <= 0) return;
    var pbuf: [fs.max_path + 1]u8 = undefined;
    const cg = podman.readCgroupPath(info.pid, &pbuf) orelse return;
    const st = podman.readCgroupStats(cg);
    c.mutex.lock();
    if (st.cpu_usage_usec > c.cpu_usage_usec) c.cpu_usage_usec = st.cpu_usage_usec;
    if (st.memory_peak > c.memory_peak) c.memory_peak = st.memory_peak;
    c.mutex.unlock();
}

fn l_c_cpu_time(L: *lua.State) c_int {
    const c = getContainer(L, 1) orelse return lua.throw(L, "invalid container");
    refreshStats(c);
    c.mutex.lock();
    const raw = @as(f64, @floatFromInt(c.cpu_usage_usec)) / 1_000_000.0;
    c.mutex.unlock();
    lua.lua_pushnumber(L, raw * c.rt.cpu_factor);
    return 1;
}

fn l_c_raw_cpu_time(L: *lua.State) c_int {
    const c = getContainer(L, 1) orelse return lua.throw(L, "invalid container");
    refreshStats(c);
    c.mutex.lock();
    const raw = @as(f64, @floatFromInt(c.cpu_usage_usec)) / 1_000_000.0;
    c.mutex.unlock();
    lua.lua_pushnumber(L, raw);
    return 1;
}

fn l_c_memory_peak(L: *lua.State) c_int {
    const c = getContainer(L, 1) orelse return lua.throw(L, "invalid container");
    refreshStats(c);
    c.mutex.lock();
    const v = c.memory_peak;
    c.mutex.unlock();
    lua.lua_pushinteger(L, @intCast(v));
    return 1;
}

fn l_c_exit_code(L: *lua.State) c_int {
    const c = getContainer(L, 1) orelse return lua.throw(L, "invalid container");
    if (!c.isDone()) {
        lua.lua_pushnil(L);
        return 1;
    }
    lua.lua_pushinteger(L, c.waitExit());
    return 1;
}

fn l_c_status(L: *lua.State) c_int {
    const c = getContainer(L, 1) orelse return lua.throw(L, "invalid container");
    const s = switch (c.state) {
        .created => "created",
        .running => "running",
        .exited => "exited",
        .removed => "removed",
        .failed => "failed",
    };
    lua.pushSlice(L, s);
    return 1;
}

fn l_c_oom(L: *lua.State) c_int {
    const c = getContainer(L, 1) orelse return lua.throw(L, "invalid container");
    return pushBool(L, c.oom_killed);
}

fn l_c_id(L: *lua.State) c_int {
    const c = getContainer(L, 1) orelse return lua.throw(L, "invalid container");
    lua.pushSlice(L, c.id);
    return 1;
}

fn l_c_name(L: *lua.State) c_int {
    const c = getContainer(L, 1) orelse return lua.throw(L, "invalid container");
    lua.pushSlice(L, c.name);
    return 1;
}

fn l_c_inspect(L: *lua.State) c_int {
    const c = getContainer(L, 1) orelse return lua.throw(L, "invalid container");
    refreshStats(c);
    _ = newTable(L, 0, 10);
    lua.pushSlice(L, c.id);
    lua.lua_setfield(L, -2, "id");
    lua.pushSlice(L, c.name);
    lua.lua_setfield(L, -2, "name");
    lua.pushSlice(L, c.image);
    lua.lua_setfield(L, -2, "image");
    lua.lua_pushinteger(L, c.waitExit());
    lua.lua_setfield(L, -2, "exit_code");
    lua.lua_pushboolean(L, @intFromBool(c.oom_killed));
    lua.lua_setfield(L, -2, "oom");
    lua.pushSlice(L, c.error_message);
    lua.lua_setfield(L, -2, "error");
    c.mutex.lock();
    const cpu = @as(f64, @floatFromInt(c.cpu_usage_usec)) / 1_000_000.0 * c.rt.cpu_factor;
    const peak = c.memory_peak;
    c.mutex.unlock();
    lua.lua_pushnumber(L, cpu);
    lua.lua_setfield(L, -2, "cpu_time");
    lua.lua_pushinteger(L, @intCast(peak));
    lua.lua_setfield(L, -2, "memory_peak");
    lua.lua_pushboolean(L, @intFromBool(c.isDone()));
    lua.lua_setfield(L, -2, "done");
    return 1;
}

fn l_c_set_test(L: *lua.State) c_int {
    const c = getContainer(L, 1) orelse return lua.throw(L, "invalid container");
    c.test_no = @intCast(@max(lua.lua_tointeger(L, 2), 0));
    return 0;
}

fn l_c_is_done(L: *lua.State) c_int {
    const c = getContainer(L, 1) orelse return lua.throw(L, "invalid container");
    return pushBool(L, c.isDone());
}

fn l_c_tostring(L: *lua.State) c_int {
    const c = getContainer(L, 1) orelse return lua.throw(L, "invalid container");
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "container({s}, {s})", .{ c.name, c.id }) catch "container";
    lua.pushSlice(L, s);
    return 1;
}

// ---------------------------------------------------------------------------
// run helpers
// ---------------------------------------------------------------------------

fn l_run_elapsed(L: *lua.State) c_int {
    const a = apiOf(L);
    lua.lua_pushnumber(L, @as(f64, @floatFromInt(a.rt.elapsedMs())) / 1000.0);
    return 1;
}

fn l_run_cancel(L: *lua.State) c_int {
    const a = apiOf(L);
    a.rt.cancel(strOrEmpty(L, 1));
    return pushBool(L, true);
}
