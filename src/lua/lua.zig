//! Minimal hand-written bindings for the vendored Lua 5.5.1.
const std = @import("std");

pub const State = opaque {};
pub const CFunction = *const fn (*State) callconv(.c) c_int;

/// Adapt a normal Zig function to the C callback ABI used by Lua.
pub fn wrap(comptime f: anytype) CFunction {
    return struct {
        fn call(L: *State) callconv(.c) c_int {
            return f(L);
        }
    }.call;
}
pub const KFunction = *const fn (?*State, c_int, isize) callconv(.c) c_int;
pub const Hook = *const fn (?*State, ?*Debug) callconv(.c) void;
pub const Integer = i64;
pub const Number = f64;

pub const Debug = opaque {};

pub const Reg = extern struct {
    name: ?[*:0]const u8 = null,
    func: ?CFunction = null,
};

pub const LUA_OK: c_int = 0;
pub const LUA_YIELD: c_int = 1;
pub const LUA_ERRRUN: c_int = 2;
pub const LUA_ERRSYNTAX: c_int = 3;
pub const LUA_ERRMEM: c_int = 4;
pub const LUA_ERRERR: c_int = 5;
pub const LUA_MULTRET: c_int = -1;

pub const LUA_REGISTRYINDEX: c_int = -(std.math.maxInt(c_int) / 2 + 1000);

pub const LUA_TNONE: c_int = -1;
pub const LUA_TNIL: c_int = 0;
pub const LUA_TBOOLEAN: c_int = 1;
pub const LUA_TLIGHTUSERDATA: c_int = 2;
pub const LUA_TNUMBER: c_int = 3;
pub const LUA_TSTRING: c_int = 4;
pub const LUA_TTABLE: c_int = 5;
pub const LUA_TFUNCTION: c_int = 6;
pub const LUA_TUSERDATA: c_int = 7;
pub const LUA_TTHREAD: c_int = 8;

pub const LUA_MASKCALL: c_int = 1 << 0;
pub const LUA_MASKRET: c_int = 1 << 1;
pub const LUA_MASKLINE: c_int = 1 << 2;
pub const LUA_MASKCOUNT: c_int = 1 << 3;

pub const LUA_GCCOLLECT: c_int = 2;

pub extern fn luaL_newstate() ?*State;
pub extern fn lua_close(L: ?*State) void;
pub extern fn luaopen_base(L: *State) callconv(.c) c_int;
pub extern fn luaopen_coroutine(L: *State) callconv(.c) c_int;
pub extern fn luaopen_string(L: *State) callconv(.c) c_int;
pub extern fn luaopen_table(L: *State) callconv(.c) c_int;
pub extern fn luaopen_math(L: *State) callconv(.c) c_int;
pub extern fn luaopen_utf8(L: *State) callconv(.c) c_int;
pub extern fn luaL_requiref(L: ?*State, modname: [*:0]const u8, openf: CFunction, glb: c_int) void;

pub extern fn lua_gettop(L: ?*State) c_int;
pub extern fn lua_settop(L: ?*State, idx: c_int) void;
pub extern fn lua_absindex(L: ?*State, idx: c_int) c_int;
pub extern fn lua_pushvalue(L: ?*State, idx: c_int) void;
pub extern fn lua_rotate(L: ?*State, idx: c_int, n: c_int) void;
pub extern fn lua_copy(L: ?*State, from: c_int, to: c_int) void;

pub extern fn lua_type(L: ?*State, idx: c_int) c_int;
pub extern fn lua_typename(L: ?*State, tp: c_int) [*:0]const u8;
pub extern fn lua_tolstring(L: ?*State, idx: c_int, len: ?*usize) ?[*]const u8;
pub extern fn luaL_tolstring(L: ?*State, idx: c_int, len: ?*usize) ?[*]const u8;
pub extern fn lua_tonumberx(L: ?*State, idx: c_int, isnum: ?*c_int) Number;
pub extern fn lua_tointegerx(L: ?*State, idx: c_int, isnum: ?*c_int) Integer;
pub extern fn lua_toboolean(L: ?*State, idx: c_int) c_int;
pub extern fn lua_touserdata(L: ?*State, idx: c_int) ?*anyopaque;
pub extern fn lua_tothread(L: ?*State, idx: c_int) ?*State;
pub extern fn lua_rawequal(L: ?*State, a: c_int, b: c_int) c_int;

pub extern fn lua_pushnil(L: ?*State) void;
pub extern fn lua_pushnumber(L: ?*State, n: Number) void;
pub extern fn lua_pushinteger(L: ?*State, n: Integer) void;
pub extern fn lua_pushlstring(L: ?*State, s: [*]const u8, len: usize) ?[*]const u8;
pub extern fn lua_pushstring(L: ?*State, s: [*:0]const u8) ?[*]const u8;
pub extern fn lua_pushcclosure(L: ?*State, fn_ptr: CFunction, n: c_int) void;
pub extern fn lua_pushboolean(L: ?*State, b: c_int) void;
pub extern fn lua_pushlightuserdata(L: ?*State, p: ?*anyopaque) void;

pub extern fn lua_getglobal(L: ?*State, name: [*:0]const u8) c_int;
pub extern fn lua_setglobal(L: ?*State, name: [*:0]const u8) void;
pub extern fn lua_getfield(L: ?*State, idx: c_int, k: [*:0]const u8) c_int;
pub extern fn lua_setfield(L: ?*State, idx: c_int, k: [*:0]const u8) void;
pub extern fn lua_gettable(L: ?*State, idx: c_int) c_int;
pub extern fn lua_settable(L: ?*State, idx: c_int) void;
pub extern fn lua_geti(L: ?*State, idx: c_int, n: Integer) c_int;
pub extern fn lua_seti(L: ?*State, idx: c_int, n: Integer) void;
pub extern fn lua_createtable(L: ?*State, narr: c_int, nrec: c_int) void;
pub extern fn lua_rawset(L: ?*State, idx: c_int) void;
pub extern fn lua_rawget(L: ?*State, idx: c_int) c_int;
pub extern fn lua_rawseti(L: ?*State, idx: c_int, n: Integer) void;
pub extern fn lua_rawgeti(L: ?*State, idx: c_int, n: Integer) c_int;
pub extern fn lua_rawlen(L: ?*State, idx: c_int) usize;
pub extern fn lua_next(L: ?*State, idx: c_int) c_int;

pub extern fn lua_getmetatable(L: ?*State, objindex: c_int) c_int;
pub extern fn lua_setmetatable(L: ?*State, objindex: c_int) c_int;
pub extern fn luaL_newmetatable(L: ?*State, tname: [*:0]const u8) c_int;
pub extern fn luaL_setmetatable(L: ?*State, tname: [*:0]const u8) void;
pub extern fn luaL_checkudata(L: ?*State, ud: c_int, tname: [*:0]const u8) ?*anyopaque;
pub extern fn luaL_testudata(L: ?*State, ud: c_int, tname: [*:0]const u8) ?*anyopaque;
pub extern fn lua_newuserdatauv(L: ?*State, sz: usize, nuvalue: c_int) ?*anyopaque;

pub extern fn lua_newthread(L: ?*State) ?*State;
pub extern fn lua_xmove(from: ?*State, to: ?*State, n: c_int) void;
pub extern fn lua_resume(L: ?*State, from: ?*State, narg: c_int, nresults: *c_int) c_int;
pub extern fn lua_yieldk(L: ?*State, nresults: c_int, ctx: isize, k: ?KFunction) c_int;
pub extern fn lua_status(L: ?*State) c_int;
pub extern fn lua_isyieldable(L: ?*State) c_int;
pub extern fn lua_pushthread(L: ?*State) c_int;
pub extern fn lua_sethook(L: ?*State, func: ?Hook, mask: c_int, count: c_int) void;

pub extern fn lua_callk(L: ?*State, nargs: c_int, nresults: c_int, ctx: isize, k: ?KFunction) void;
pub extern fn lua_pcallk(L: ?*State, nargs: c_int, nresults: c_int, errfunc: c_int, ctx: isize, k: ?KFunction) c_int;
pub extern fn lua_checkstack(L: ?*State, n: c_int) c_int;
pub extern fn lua_len(L: ?*State, idx: c_int) void;
pub extern fn lua_concat(L: ?*State, n: c_int) void;
pub extern fn lua_gc(L: ?*State, what: c_int, ...) c_int;
pub extern fn lua_tocfunction(L: ?*State, idx: c_int) ?CFunction;

pub fn lua_yield(L: ?*State, nresults: c_int) c_int {
    return lua_yieldk(L, nresults, 0, null);
}
pub fn lua_call(L: ?*State, nargs: c_int, nresults: c_int) void {
    lua_callk(L, nargs, nresults, 0, null);
}
pub fn lua_pcall(L: ?*State, nargs: c_int, nresults: c_int, errfunc: c_int) c_int {
    return lua_pcallk(L, nargs, nresults, errfunc, 0, null);
}
pub fn lua_tonumber(L: ?*State, idx: c_int) Number {
    return lua_tonumberx(L, idx, null);
}
pub fn lua_tointeger(L: ?*State, idx: c_int) Integer {
    return lua_tointegerx(L, idx, null);
}
pub fn lua_isnil(L: ?*State, idx: c_int) bool {
    return lua_type(L, idx) == LUA_TNIL;
}
pub fn lua_isstring(L: ?*State, idx: c_int) bool {
    return lua_type(L, idx) == LUA_TSTRING or lua_type(L, idx) == LUA_TNUMBER;
}
pub fn lua_istable(L: ?*State, idx: c_int) bool {
    return lua_type(L, idx) == LUA_TTABLE;
}
pub fn lua_isfunction(L: ?*State, idx: c_int) bool {
    return lua_type(L, idx) == LUA_TFUNCTION;
}

pub extern fn lua_error(L: ?*State) c_int;
pub extern fn luaL_error(L: ?*State, fmt: [*:0]const u8, ...) c_int;
pub extern fn luaL_argerror(L: ?*State, arg: c_int, extramsg: [*:0]const u8) c_int;
pub extern fn luaL_where(L: ?*State, lvl: c_int) void;
pub extern fn luaL_traceback(L: ?*State, L1: ?*State, msg: ?[*:0]const u8, level: c_int) void;

pub extern fn luaL_checklstring(L: ?*State, arg: c_int, len: ?*usize) ?[*]const u8;
pub extern fn luaL_optlstring(L: ?*State, arg: c_int, def: ?[*]const u8, len: ?*usize) ?[*]const u8;
pub extern fn luaL_checkinteger(L: ?*State, arg: c_int) Integer;
pub extern fn luaL_optinteger(L: ?*State, arg: c_int, def: Integer) Integer;
pub extern fn luaL_checknumber(L: ?*State, arg: c_int) Number;
pub extern fn luaL_optnumber(L: ?*State, arg: c_int, def: Number) Number;
pub extern fn luaL_checktype(L: ?*State, arg: c_int, t: c_int) void;
pub extern fn luaL_checkany(L: ?*State, arg: c_int) void;
pub extern fn luaL_setfuncs(L: ?*State, l: [*]const Reg, nup: c_int) void;
pub extern fn luaL_loadbufferx(L: ?*State, buff: [*]const u8, sz: usize, name: [*:0]const u8, mode: ?[*:0]const u8) c_int;
pub extern fn luaL_loadstring(L: ?*State, s: [*:0]const u8) c_int;
pub extern fn luaL_checkstack(L: ?*State, sz: c_int, msg: ?[*:0]const u8) void;
pub extern fn luaL_len(L: ?*State, idx: c_int) Integer;
pub extern fn luaL_ref(L: ?*State, t: c_int) c_int;
pub extern fn luaL_unref(L: ?*State, t: c_int, ref: c_int) void;

pub const LUA_NOREF: c_int = -2;
pub const LUA_REFNIL: c_int = -1;

pub fn lua_upvalueindex(i: c_int) c_int {
    return LUA_REGISTRYINDEX - i;
}

// ---------------------------------------------------------------------------
// small helpers
// ---------------------------------------------------------------------------

pub fn pushSlice(L: ?*State, s: []const u8) void {
    _ = lua_pushlstring(L, s.ptr, s.len);
}

pub fn toSlice(L: ?*State, idx: c_int) ?[]const u8 {
    var len: usize = 0;
    const p = lua_tolstring(L, idx, &len) orelse return null;
    return p[0..len];
}

pub fn checkSlice(L: ?*State, arg: c_int) []const u8 {
    var len: usize = 0;
    const p = luaL_checklstring(L, arg, &len) orelse return "";
    return p[0..len];
}

pub fn optSlice(L: ?*State, arg: c_int, def: []const u8) []const u8 {
    if (lua_type(L, arg) == LUA_TNONE or lua_type(L, arg) == LUA_TNIL) return def;
    return checkSlice(L, arg);
}

pub fn pushC(L: ?*State, f: CFunction) void {
    lua_pushcclosure(L, f, 0);
}

pub fn throw(L: ?*State, msg: []const u8) c_int {
    _ = lua_pushlstring(L, msg.ptr, msg.len);
    return lua_error(L);
}

pub fn throwFmt(L: ?*State, comptime fmt: []const u8, args: anytype) c_int {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch "error";
    return throw(L, msg);
}

pub fn pop(L: ?*State, n: c_int) void {
    lua_settop(L, -n - 1);
}

pub fn lua_pop(L: ?*State, n: c_int) void {
    lua_settop(L, -n - 1);
}
