//! One-shot acceptance harness; never part of the installed worker path.
const std = @import("std");
const nats = @import("nats");
const core = @import("core.zig");
const Service = @import("phase3.zig").Service;
const Consumer = @import("control/jetstream.zig").Consumer;
const delivery = @import("control/delivery.zig");
const Job = @import("control/job.zig").Job;

pub fn run(init: std.process.Init, config: core.Config, args: []const [:0]const u8) !void {
    const port = try std.fmt.parseInt(u16, args[0], 10);
    const a = init.arena.allocator();
    const url = try std.fmt.allocPrint(a, "nats://127.0.0.1:{d}", .{port});
    const client = try nats.Client.connect(init.gpa, init.io, url, .{});
    defer client.deinit();
    var js = try nats.jetstream.JetStream.init(client, .{});
    var consumer = try Consumer.bind(&js, args[1], args[2], args[3]);
    const service = try Service.open(init, config.state_dir, config.invoker_id);
    defer service.close();
    var random: [16]u8 = undefined;
    try init.io.randomSecure(&random);
    const id = core.ProcessIdentity.init(config.invoker_id, random);
    var handler: Handler = .{ .service = service, .epoch = &id.process_epoch };
    const result = (try consumer.step(init.gpa, init.io, .{ .free_slots = 1, .podman_available = true, .disk_available = true }, &handler)) orelse return error.NoFixtureDelivery;
    if (result != .started) return error.FixtureClaimNotAccepted;
}

const Handler = struct {
    service: Service,
    epoch: []const u8,
    token: [32]u8 = undefined,

    pub fn claim(self: *Handler, assignment: Job) !delivery.Claim {
        // pinAssigned is a combined Claim + durable reservation. Failure at
        // either boundary leaves the delivery retryable, never acknowledged.
        const grant = self.service.pinAssigned(assignment, self.epoch) catch |err| switch (err) {
            error.ControlRetry => return .retry,
            else => return err,
        };
        self.token = grant.token;
        return .{ .granted = .{ .fencing_token = &self.token, .expires_unix = grant.expires } };
    }

    pub fn persist(_: *Handler, _: Job, _: delivery.Lease) !void {} // Already fsynced by pinAssigned.
    pub fn start(_: *Handler, _: Job, _: delivery.Lease) !void {} // This fixture cannot launch workloads.
};
