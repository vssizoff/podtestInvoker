const std = @import("std");

test {
    std.testing.refAllDecls(@import("main.zig"));
    std.testing.refAllDecls(@import("util/log.zig"));
    std.testing.refAllDecls(@import("util/clock.zig"));
    std.testing.refAllDecls(@import("util/sys.zig"));
    std.testing.refAllDecls(@import("util/fs.zig"));
    std.testing.refAllDecls(@import("util/http.zig"));
    std.testing.refAllDecls(@import("util/tar.zig"));
    std.testing.refAllDecls(@import("config.zig"));
    std.testing.refAllDecls(@import("state.zig"));
    std.testing.refAllDecls(@import("podman/client.zig"));
    std.testing.refAllDecls(@import("lua/lua.zig"));
    std.testing.refAllDecls(@import("util/tar_write.zig"));
    std.testing.refAllDecls(@import("run/runtime.zig"));
    std.testing.refAllDecls(@import("run/scheduler.zig"));
    std.testing.refAllDecls(@import("lua/api.zig"));
    std.testing.refAllDecls(@import("run/executor.zig"));
    std.testing.refAllDecls(@import("calibration.zig"));
    std.testing.refAllDecls(@import("cleanup.zig"));
    std.testing.refAllDecls(@import("run/manager.zig"));
    std.testing.refAllDecls(@import("grpc/messages.zig"));
    std.testing.refAllDecls(@import("grpc/server.zig"));
}
// All unit tests are discovered through refAllDecls above.
