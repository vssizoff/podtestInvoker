const std = @import("std");
const fs = @import("util/fs.zig");
const sys = @import("util/sys.zig");
const gpa = @import("util/mem.zig").gpa;
const log = @import("util/log.zig");

pub const State = struct {
    instance_id: []u8,

    pub fn deinit(self: *State) void {
        gpa.free(self.instance_id);
        self.* = undefined;
    }
};

fn validInstanceId(s: []const u8) bool {
    if (s.len != 32) return false;
    for (s) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

/// Load the stable instance id from the state file, or generate a new one.
pub fn loadOrCreate(path: []const u8) !State {
    const data = fs.readFileAbsolute(path, 64 * 1024) catch |e| switch (e) {
        error.NotFound => return create(path),
        else => return e,
    };
    defer gpa.free(data);
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, data, .{}) catch return error.InvalidStateFile;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidStateFile;
    const v = parsed.value.object.get("instance_id") orelse return error.InvalidStateFile;
    if (v != .string or !validInstanceId(v.string)) return error.InvalidStateFile;
    return .{ .instance_id = try gpa.dupe(u8, v.string) };
}

fn create(path: []const u8) !State {
    var raw: [16]u8 = undefined;
    try sys.getrandom(&raw);
    const id = try gpa.alloc(u8, 32);
    const hex = "0123456789abcdef";
    for (raw, 0..) |b, i| {
        id[i * 2] = hex[b >> 4];
        id[i * 2 + 1] = hex[b & 0xf];
    }
    // ensure parent directory
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
        if (idx > 0) try fs.makeDirAllAbsolute(path[0..idx]);
    }
    const json = try std.fmt.allocPrint(gpa, "{{\"instance_id\":\"{s}\"}}\n", .{id});
    defer gpa.free(json);
    const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
    defer gpa.free(tmp);
    try fs.writeFileAbsolute(tmp, json);
    var zb: [fs.max_path + 1]u8 = undefined;
    if (tmp.len + 1 > zb.len) return error.PathTooLong;
    @memcpy(zb[0..tmp.len], tmp);
    zb[tmp.len] = 0;
    var zb2: [fs.max_path + 1]u8 = undefined;
    if (path.len + 1 > zb2.len) return error.PathTooLong;
    @memcpy(zb2[0..path.len], path);
    zb2[path.len] = 0;
    const rc = std.os.linux.renameat(std.os.linux.AT.FDCWD, zb[0..tmp.len :0], std.os.linux.AT.FDCWD, zb2[0..path.len :0]);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.RenameFailed;
    log.info("generated instance id {s}", .{id});
    return .{ .instance_id = id };
}
