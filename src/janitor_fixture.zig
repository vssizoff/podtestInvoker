const std = @import("std");
const podman = @import("podman");
const janitor = @import("janitor");
const linux = std.os.linux;
extern fn podtest_lock([*:0]const u8) c_int;

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 3) return error.InvalidArguments;
    const socket = init.environ_map.get("PODTEST_PODMAN_SOCKET") orelse return error.ExpectedRootlessSocket;
    const api = init.environ_map.get("PODTEST_LIBPOD_API_VERSION") orelse return error.ExpectedLibpodVersion;
    const image = init.environ_map.get("PODTEST_TEST_IMAGE_ID") orelse return error.ExpectedLocalImage;
    if (image.len != 64) return error.ExpectedLocalImage;
    const fd = podtest_lock(args[1]);
    if (fd < 0) return error.CannotLockFixtureState;
    defer _ = linux.close(fd);
    const client: podman.Client = .{ .socket = try a.dupeSentinel(u8, socket, 0), .api_version = try a.dupeSentinel(u8, api, 0) };
    var buf: [128 << 10]u8 = undefined;
    const info = try std.json.parseFromSliceLeaky(struct { host: struct { security: struct { rootless: bool } } }, a, try client.info(&buf), .{ .ignore_unknown_fields = true });
    if (!info.host.security.rootless) return error.RootlessRequired;
    const journal: janitor.Journal = .{ .io = io, .state = .{ .handle = fd }, .invoker_id = args[2], .epoch = "00000000-0000-4000-8000-000000000001" };
    const net_record = try journal.reserveKind(a, "phase8-fixture", .network);
    const network = try client.createNetworkWithLabels(a, &net_record.name(), net_record.run_id, net_record.labels(), &buf);
    const image_record = try journal.reserveKind(a, "phase8-fixture", .image);
    const recipe = try std.fmt.allocPrint(a, "FROM {s}\n{s}", .{ image, try janitor.imageLabels(a, image_record) });
    var ignored: u8 = 0;
    const built = try client.buildTrusted(a, &.{.{ .path = "Dockerfile", .contents = recipe }}, &image_record.name(), 30_000, discard, &ignored, .{ .check = neverCancel, .context = &ignored });
    const record = try journal.reserve(a, "phase8-fixture");
    const id = try client.create(a, .{ .name = &record.name(), .image = built, .command = &.{ "/bin/sh", "-c", "exec sleep 120" }, .labels = record.labels() });
    errdefer client.remove(id) catch {};
    try client.start(id);
    const summary = try journal.sweep(a, client, null);
    if (summary.removed != 0 or summary.rejected != 0 or summary.unresolved != 0) return error.UnexpectedActiveEpochSweep;
    var ready = try journal.state.createFileAtomic(io, "ready", .{ .permissions = .fromMode(0o600) });
    defer ready.deinit(io);
    try ready.file.writeStreamingAll(io, &id);
    try ready.link(io);
    try io.sleep(.fromSeconds(120), .awake);
    try client.remove(id);
    try journal.finish(record);
    try client.removeNetwork(network);
    try journal.finish(net_record);
    try client.removeTag(&image_record.name(), &buf);
    try journal.finish(image_record);
}

fn discard(_: *anyopaque, _: []const u8) !void {}
fn neverCancel(_: *anyopaque) bool {
    return false;
}
