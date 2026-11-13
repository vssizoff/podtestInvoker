//! Cooperative coroutine scheduler for one runner.lua execution.
const std = @import("std");
const lua = @import("../lua/lua.zig");
const clock = @import("../util/clock.zig");
const log = @import("../util/log.zig");
const events = @import("../events.zig");
const runtime = @import("runtime.zig");
const gpa = @import("../util/mem.zig").gpa;

pub const Status = enum { ready, suspended, finished, failed };

pub const ReadWait = struct {
    c: *runtime.Container,
    stream: runtime.Stream,
    max: usize,
    deadline: i128,
    any: bool = false,
};

pub const Wait = union(enum) {
    ready,
    sleep: i128,
    wait_container: *runtime.Container,
    read_container: ReadWait,
    join: *Task,
};

pub const Task = struct {
    sched: *Scheduler,
    L: *lua.State,
    ref: c_int,
    initial_nargs: c_int,
    first: bool = true,
    pending_nargs: c_int = 0,
    status: Status = .ready,
    wait: Wait = .ready,
    results_ref: c_int = lua.LUA_NOREF,
    result_count: c_int = 0,
    error_msg: ?[]u8 = null,
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

pub const Handle = extern struct {
    task: *Task,
};

pub const Scheduler = struct {
    main: *lua.State,
    rt: *runtime.RunContext,
    tasks: std.ArrayList(*Task) = .empty,
    main_task: ?*Task = null,
    fatal: bool = false,
    timed_out: bool = false,
    stopped: bool = false,
    fatal_message: ?[]u8 = null,
    fatal_traceback: ?[]u8 = null,

    pub fn init(main: *lua.State, rt: *runtime.RunContext) !*Scheduler {
        const s = try gpa.create(Scheduler);
        s.* = .{ .main = main, .rt = rt };
        try s.registerMetatable();
        return s;
    }

    pub fn deinit(self: *Scheduler) void {
        for (self.tasks.items) |t| {
            if (t.results_ref != lua.LUA_NOREF) lua.luaL_unref(self.main, lua.LUA_REGISTRYINDEX, t.results_ref);
            lua.luaL_unref(self.main, lua.LUA_REGISTRYINDEX, t.ref);
            if (t.error_msg) |m| gpa.free(m);
            gpa.destroy(t);
        }
        self.tasks.deinit(gpa);
        if (self.fatal_message) |m| gpa.free(m);
        if (self.fatal_traceback) |m| gpa.free(m);
        gpa.destroy(self);
    }

    fn registerMetatable(self: *Scheduler) !void {
        const L = self.main;
        _ = lua.luaL_newmetatable(L, "invoker.handle");
        lua.lua_createtable(L, 0, 4);
        lua.pushC(L, lua.wrap(handleJoin));
        lua.lua_setfield(L, -2, "join");
        lua.pushC(L, lua.wrap(handleCancel));
        lua.lua_setfield(L, -2, "cancel");
        lua.pushC(L, lua.wrap(handleDone));
        lua.lua_setfield(L, -2, "done");
        lua.pushC(L, lua.wrap(handleStatus));
        lua.lua_setfield(L, -2, "status");
        lua.pushC(L, lua.wrap(handleCancelled));
        lua.lua_setfield(L, -2, "cancelled");
        lua.lua_setfield(L, -2, "__index");
        lua.lua_pop(L, 1);
    }

    fn newTask(self: *Scheduler, thread: *lua.State, ref: c_int, nargs: c_int) !*Task {
        const t = try gpa.create(Task);
        t.* = .{ .sched = self, .L = thread, .ref = ref, .initial_nargs = nargs };
        errdefer gpa.destroy(t);
        try self.tasks.append(gpa, t);
        return t;
    }

    /// Spawn a coroutine from a function on top of the Lua stack.  Arguments
    /// are the remaining values on the stack.  Returns the number of results
    /// (one handle) to the caller.
    pub fn spawnFromStack(self: *Scheduler, L: *lua.State) c_int {
        const top = lua.lua_gettop(L);
        if (top < 1 or !lua.lua_isfunction(L, 1)) {
            return lua.throw(L, "spawn expects a function");
        }
        const nargs = top - 1;
        const T = lua.lua_newthread(L) orelse return lua.throw(L, "cannot create coroutine");
        const ref = lua.luaL_ref(L, lua.LUA_REGISTRYINDEX);
        // Move function and arguments to the new thread.
        lua.lua_pushvalue(L, 1);
        lua.lua_xmove(L, T, 1);
        var i: c_int = 0;
        while (i < nargs) : (i += 1) {
            lua.lua_pushvalue(L, i + 2);
            lua.lua_xmove(L, T, 1);
        }
        const t = self.newTask(T, ref, nargs) catch return lua.throw(L, "out of memory");
        self.pushHandle(L, t);
        return 1;
    }

    pub fn pushHandle(self: *Scheduler, L: *lua.State, t: *Task) void {
        _ = self;
        const mem = lua.lua_newuserdatauv(L, @sizeOf(Handle), 0) orelse return;
        const h: *Handle = @ptrCast(@alignCast(mem));
        h.task = t;
        lua.luaL_setmetatable(L, "invoker.handle");
    }

    /// Create the task that runs the top-level chunk.
    pub fn createMainTask(self: *Scheduler, L: *lua.State) !void {
        const T = lua.lua_newthread(L) orelse return error.OutOfMemory;
        const ref = lua.luaL_ref(L, lua.LUA_REGISTRYINDEX);
        // The chunk is on the main stack at index 1.
        lua.lua_pushvalue(L, 1);
        lua.lua_xmove(L, T, 1);
        const t = try self.newTask(T, ref, 0);
        self.main_task = t;
    }

    fn setCurrent(self: *Scheduler, t: ?*Task) void {
        if (t) |task| {
            lua.lua_pushlightuserdata(self.main, task);
        } else {
            lua.lua_pushnil(self.main);
        }
        lua.lua_setfield(self.main, lua.LUA_REGISTRYINDEX, "invoker.current");
    }

    pub fn currentTask(self: *Scheduler) ?*Task {
        _ = lua.lua_getfield(self.main, lua.LUA_REGISTRYINDEX, "invoker.current");
        const p = lua.lua_touserdata(self.main, -1);
        lua.lua_pop(self.main, 1);
        if (p) |ptr| return @ptrCast(@alignCast(ptr));
        return null;
    }

    fn resumeTask(self: *Scheduler, t: *Task) void {
        const narg = if (t.first) t.initial_nargs else t.pending_nargs;
        t.first = false;
        t.pending_nargs = 0;
        self.setCurrent(t);
        var nres: c_int = 0;
        const rc = lua.lua_resume(t.L, null, narg, &nres);
        if (rc == lua.LUA_OK) {
            t.status = .finished;
            self.storeResults(t, nres);
        } else if (rc == lua.LUA_YIELD) {
            t.status = .suspended;
        } else {
            t.status = .failed;
            self.captureError(t);
        }
    }

    fn storeResults(self: *Scheduler, t: *Task, nres: c_int) void {
        _ = self;
        if (nres <= 0) {
            t.result_count = 0;
            lua.lua_settop(t.L, 0);
            return;
        }
        lua.lua_createtable(t.L, nres, 0);
        const tidx = lua.lua_gettop(t.L);
        var i: c_int = 1;
        while (i <= nres) : (i += 1) {
            lua.lua_pushvalue(t.L, i);
            lua.lua_rawseti(t.L, tidx, i);
        }
        t.results_ref = lua.luaL_ref(t.L, lua.LUA_REGISTRYINDEX);
        t.result_count = nres;
        lua.lua_settop(t.L, 0);
    }

    fn captureError(self: *Scheduler, t: *Task) void {
        var msg: []const u8 = "lua error";
        var len: usize = 0;
        if (lua.lua_tolstring(t.L, -1, &len)) |p| msg = p[0..len];
        const owned_msg = gpa.dupe(u8, msg) catch null;
        var zbuf: [1024]u8 = undefined;
        const n = @min(msg.len, zbuf.len - 1);
        @memcpy(zbuf[0..n], msg[0..n]);
        zbuf[n] = 0;
        lua.luaL_traceback(t.L, t.L, zbuf[0..n :0], 1);
        var tb: []const u8 = "";
        if (lua.lua_tolstring(t.L, -1, &len)) |p| tb = p[0..len];
        t.error_msg = owned_msg;
        if (!self.fatal) {
            self.fatal = true;
            if (owned_msg) |m| self.fatal_message = gpa.dupe(u8, m) catch null;
            self.fatal_traceback = gpa.dupe(u8, tb) catch null;
            const m = if (owned_msg) |om| gpa.dupe(u8, om) catch null else null;
            const tr = gpa.dupe(u8, tb) catch null;
            if (m != null and tr != null) {
                self.rt.emit(.{ .runner_error = .{ .message = m.?, .traceback = tr.? } });
            } else {
                if (m) |mm| gpa.free(mm);
                if (tr) |tt| gpa.free(tt);
            }
            log.err("runner error: {s}", .{owned_msg orelse "lua error"});
        }
        lua.lua_settop(t.L, 0);
    }

    fn pushResults(self: *Scheduler, dest: *lua.State, target: *Task) void {
        if (target.error_msg) |m| {
            lua.lua_pushnil(dest);
            lua.pushSlice(dest, m);
            return;
        }
        if (target.results_ref == lua.LUA_NOREF or target.result_count == 0) return;
        _ = lua.lua_rawgeti(self.main, lua.LUA_REGISTRYINDEX, target.results_ref);
        const tidx = lua.lua_gettop(self.main);
        var i: c_int = 1;
        while (i <= target.result_count) : (i += 1) {
            _ = lua.lua_rawgeti(self.main, tidx, i);
        }
        lua.lua_xmove(self.main, dest, target.result_count);
        lua.lua_settop(self.main, tidx - 1);
    }

    fn wakeSleep(self: *Scheduler, t: *Task, deadline: i128) void {
        _ = self;
        if (clock.nowNs() >= deadline or t.cancelled.load(.monotonic)) {
            t.pending_nargs = 0;
            t.status = .ready;
        }
    }

    fn wakeContainerWait(self: *Scheduler, t: *Task, c: *runtime.Container) void {
        _ = self;
        if (c.isDone() or t.cancelled.load(.monotonic)) {
            lua.lua_pushinteger(t.L, c.waitExit());
            lua.lua_createtable(t.L, 0, 3);
            lua.lua_pushboolean(t.L, @intFromBool(c.oom_killed));
            lua.lua_setfield(t.L, -2, "oom");
            lua.pushSlice(t.L, c.error_message);
            lua.lua_setfield(t.L, -2, "error");
            lua.lua_pushboolean(t.L, @intFromBool(c.killed));
            lua.lua_setfield(t.L, -2, "killed");
            t.pending_nargs = 2;
            t.status = .ready;
        }
    }

    fn wakeRead(self: *Scheduler, t: *Task, r: ReadWait) void {
        _ = self;
        const now = clock.nowNs();
        if (r.any) {
            if (r.c.readAvailable(.stdout, r.max) catch null) |data| {
                if (data.len > 0) {
                    lua.pushSlice(t.L, data);
                    gpa.free(data);
                    t.pending_nargs = 1;
                    t.status = .ready;
                    return;
                }
                gpa.free(data);
            }
            if (r.c.readAvailable(.stderr, r.max) catch null) |data| {
                if (data.len > 0) {
                    lua.pushSlice(t.L, data);
                    gpa.free(data);
                    t.pending_nargs = 1;
                    t.status = .ready;
                    return;
                }
                gpa.free(data);
            }
        } else if (r.c.readAvailable(r.stream, r.max) catch null) |data| {
            if (data.len > 0) {
                lua.pushSlice(t.L, data);
                gpa.free(data);
                t.pending_nargs = 1;
                t.status = .ready;
                return;
            }
            gpa.free(data);
        }
        // no data: return nil at EOF, on timeout, or when cancelled
        if (r.c.isDone() or (r.deadline != 0 and now >= r.deadline) or t.cancelled.load(.monotonic)) {
            lua.lua_pushnil(t.L);
            t.pending_nargs = 1;
            t.status = .ready;
        }
    }

    fn wakeJoin(self: *Scheduler, t: *Task, target: *Task) void {
        if (target.status == .finished or target.status == .failed) {
            self.pushResults(t.L, target);
            t.pending_nargs = if (target.error_msg != null) 2 else target.result_count;
            t.status = .ready;
        }
    }

    /// Run until the main task and all spawned tasks are finished, or a fatal
    /// condition occurs.  Returns when the run should be finalised.
    pub fn run(self: *Scheduler) void {
        while (true) {
            if (self.rt.isCancelled()) {
                self.stopped = true;
                return;
            }
            if (self.rt.timedOut()) {
                self.timed_out = true;
                return;
            }
            if (self.fatal) return;

            var live = false;
            var progressed = false;
            for (self.tasks.items) |t| {
                switch (t.status) {
                    .ready => {
                        live = true;
                        self.resumeTask(t);
                        progressed = true;
                        if (self.fatal) return;
                    },
                    .suspended => {
                        live = true;
                        switch (t.wait) {
                            .ready => {
                                t.pending_nargs = 0;
                                t.status = .ready;
                                progressed = true;
                            },
                            .sleep => |deadline| {
                                self.wakeSleep(t, deadline);
                                if (t.status == .ready) progressed = true;
                            },
                            .wait_container => |c| {
                                self.wakeContainerWait(t, c);
                                if (t.status == .ready) progressed = true;
                            },
                            .read_container => |r| {
                                self.wakeRead(t, r);
                                if (t.status == .ready) progressed = true;
                            },
                            .join => |target| {
                                self.wakeJoin(t, target);
                                if (t.status == .ready) progressed = true;
                            },
                        }
                    },
                    .finished, .failed => {},
                }
            }
            if (!live) return;
            if (!progressed) clock.sleepMs(2);
        }
    }

    pub fn setWait(self: *Scheduler, t: *Task, w: Wait) void {
        _ = self;
        t.wait = w;
        t.status = .suspended;
    }
};

// ---------------------------------------------------------------------------
// handle methods
// ---------------------------------------------------------------------------

fn getHandle(L: *lua.State) ?*Handle {
    const p = lua.luaL_checkudata(L, 1, "invoker.handle") orelse return null;
    return @ptrCast(@alignCast(p));
}

fn currentTask(L: *lua.State) ?*Task {
    _ = lua.lua_getfield(L, lua.LUA_REGISTRYINDEX, "invoker.current");
    const p = lua.lua_touserdata(L, -1);
    lua.lua_pop(L, 1);
    if (p) |ptr| return @ptrCast(@alignCast(ptr));
    return null;
}

fn handleJoin(L: *lua.State) c_int {
    const h = getHandle(L) orelse return lua.throw(L, "invalid handle");
    const t = currentTask(L) orelse return lua.throw(L, "join outside a coroutine");
    if (h.task == t) return lua.throw(L, "cannot join self");
    if (h.task.status == .finished or h.task.status == .failed) {
        // Fast path: push results directly.
        h.task.sched.pushResults(L, h.task);
        if (h.task.error_msg != null) return 2;
        return h.task.result_count;
    }
    t.wait = .{ .join = h.task };
    t.status = .suspended;
    return lua.lua_yield(L, 0);
}

fn handleCancel(L: *lua.State) c_int {
    const h = getHandle(L) orelse return lua.throw(L, "invalid handle");
    h.task.cancelled.store(true, .monotonic);
    return 0;
}

fn handleDone(L: *lua.State) c_int {
    const h = getHandle(L) orelse return lua.throw(L, "invalid handle");
    lua.lua_pushboolean(L, @intFromBool(h.task.status == .finished or h.task.status == .failed));
    return 1;
}

fn handleCancelled(L: *lua.State) c_int {
    const h = getHandle(L) orelse return lua.throw(L, "invalid handle");
    lua.lua_pushboolean(L, @intFromBool(h.task.cancelled.load(.monotonic)));
    return 1;
}

fn handleStatus(L: *lua.State) c_int {
    const h = getHandle(L) orelse return lua.throw(L, "invalid handle");
    const s = switch (h.task.status) {
        .ready => "ready",
        .suspended => "suspended",
        .finished => "finished",
        .failed => "failed",
    };
    lua.pushSlice(L, s);
    return 1;
}
