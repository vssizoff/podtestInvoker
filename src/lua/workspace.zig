const std = @import("std");

pub const Workspace = struct {
    io: std.Io,
    dir: std.Io.Dir,

    pub fn read(self: Workspace, path: []const u8, offset: u32, out: []u8) !usize {
        if (path.len == 0 or path.len > 256 or std.mem.indexOfAny(u8, path, "\\\x00") != null)
            return error.InvalidWorkspacePath;
        var components = std.mem.splitScalar(u8, path, '/');
        var directories: [31]std.Io.Dir = undefined;
        var depth: usize = 0;
        defer for (directories[0..depth]) |dir| dir.close(self.io);
        var parent = self.dir;
        while (components.next()) |component| {
            if (component.len == 0 or component.len > 255 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, ".."))
                return error.InvalidWorkspacePath;
            if (components.index == null) {
                const file = try parent.openFile(self.io, component, .{ .follow_symlinks = false, .resolve_beneath = true });
                defer file.close(self.io);
                if ((try file.stat(self.io)).kind != .file) return error.InvalidWorkspaceFile;
                return file.readPositionalAll(self.io, out[0..@min(out.len, 16 * 1024)], offset);
            }
            if (depth == directories.len) return error.InvalidWorkspacePath;
            parent = try parent.openDir(self.io, component, .{ .follow_symlinks = false });
            directories[depth] = parent;
            depth += 1;
        }
        return error.InvalidWorkspacePath;
    }

    pub fn readRpc(context: ?*anyopaque, path: [*]const u8, path_len: usize, offset: u32, out: [*]u8, size: *usize) callconv(.c) c_int {
        const self: *const Workspace = @ptrCast(@alignCast(context orelse return -1));
        size.* = self.read(path[0..path_len], offset, out[0..size.*]) catch return -1;
        return if (size.* == 0) 2 else 1;
    }
};
