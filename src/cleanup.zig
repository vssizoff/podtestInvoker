//! Startup cleanup: remove resources owned by this invoker instance and stale
//! run directories left behind by a previous process.
const std = @import("std");
const podman = @import("podman/client.zig");
const log = @import("util/log.zig");
const sys = @import("util/sys.zig");
const fs = @import("util/fs.zig");
const gpa = @import("util/mem.zig").gpa;

pub const Report = struct {
    containers: usize = 0,
    images: usize = 0,
    networks: usize = 0,
    run_dirs: usize = 0,
};

fn removeContainers(client: *podman.Client, report: *Report) void {
    const ids = client.listContainerIds() catch |e| {
        log.warn("cleanup: cannot list containers: {s}", .{@errorName(e)});
        return;
    };
    defer podman.freeIdList(ids);
    for (ids) |id| {
        client.removeContainer(id) catch |e| {
            log.debug("cleanup: remove container {s}: {s}", .{ id, @errorName(e) });
            continue;
        };
        report.containers += 1;
    }
}

fn removeImages(client: *podman.Client, report: *Report) void {
    const ids = client.listImageIds() catch |e| {
        log.warn("cleanup: cannot list images: {s}", .{@errorName(e)});
        return;
    };
    defer podman.freeIdList(ids);
    for (ids) |id| {
        client.removeImage(id) catch |e| {
            log.debug("cleanup: remove image {s}: {s}", .{ id, @errorName(e) });
            continue;
        };
        report.images += 1;
    }
}

fn removeNetworks(client: *podman.Client, report: *Report) void {
    const names = client.listNetworkNames() catch |e| {
        log.warn("cleanup: cannot list networks: {s}", .{@errorName(e)});
        return;
    };
    defer podman.freeIdList(names);
    for (names) |name| {
        client.removeNetwork(name) catch |e| {
            log.debug("cleanup: remove network {s}: {s}", .{ name, @errorName(e) });
            continue;
        };
        report.networks += 1;
    }
}

const DirCtx = struct {
    fd: sys.fd_t,
    report: *Report,
    fn onEntry(self: *@This(), ent: sys.DirEntry) anyerror!void {
        if (ent.kind != .dir and ent.kind != .symlink) return;
        fs.removeTreeBeneath(self.fd, ent.name) catch |e| {
            log.warn("cleanup: cannot remove stale run dir {s}: {s}", .{ ent.name, @errorName(e) });
            return;
        };
        self.report.run_dirs += 1;
    }
};

/// Remove stale run directories below `work_root`.  All runs of a previous
/// process are stale because the invoker has not accepted any work yet.
pub fn removeRunDirs(work_root: []const u8, report: *Report) void {
    fs.makeDirAllAbsolute(work_root) catch |e| {
        log.warn("cleanup: cannot create work root {s}: {s}", .{ work_root, @errorName(e) });
        return;
    };
    var pbuf: [fs.max_path + 1]u8 = undefined;
    if (work_root.len + 1 > pbuf.len) return;
    @memcpy(pbuf[0..work_root.len], work_root);
    pbuf[work_root.len] = 0;
    const fd = sys.openat(std.os.linux.AT.FDCWD, pbuf[0..work_root.len :0], .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .CLOEXEC = true,
    }, 0) catch |e| {
        log.warn("cleanup: cannot open work root {s}: {s}", .{ work_root, @errorName(e) });
        return;
    };
    defer sys.close(fd);
    // The incoming archive directory is ours too; remove partial uploads.
    var ctx = DirCtx{ .fd = fd, .report = report };
    sys.listDir(fd, &ctx, DirCtx.onEntry) catch |e| {
        log.warn("cleanup: cannot list work root: {s}", .{@errorName(e)});
    };
}

/// Clean all resources labelled with this instance id, then stale run dirs.
/// Failures are logged but never fatal: a broken resource must not prevent the
/// invoker from starting.
pub fn cleanupAll(client: *podman.Client, work_root: []const u8) Report {
    var report = Report{};
    removeContainers(client, &report);
    removeImages(client, &report);
    removeNetworks(client, &report);
    removeRunDirs(work_root, &report);
    if (report.containers + report.images + report.networks + report.run_dirs > 0) {
        log.info("cleanup: removed {d} containers, {d} images, {d} networks, {d} run dirs", .{
            report.containers,
            report.images,
            report.networks,
            report.run_dirs,
        });
    }
    return report;
}
