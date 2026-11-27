const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    if (target.result.os.tag != .linux or target.result.cpu.arch != .x86_64)
        @panic("podtest-invoker requires Linux x86-64");
    const optimize = b.standardOptimizeOption(.{});
    const resource = b.createModule(.{ .root_source_file = b.path("src/resource.zig"), .target = target, .optimize = optimize });
    const podman = b.createModule(.{ .root_source_file = b.path("src/podman/client.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "resource", .module = resource }} });
    const janitor = b.createModule(.{ .root_source_file = b.path("src/janitor.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "podman", .module = podman }} });
    const engine = b.createModule(.{ .root_source_file = b.path("src/podman/engine.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "resource", .module = resource }, .{ .name = "history", .module = b.createModule(.{ .root_source_file = b.path("src/stdio_history.zig"), .target = target, .optimize = optimize }) }, .{ .name = "pipe", .module = b.createModule(.{ .root_source_file = b.path("src/pipe.zig"), .target = target, .optimize = optimize }) } } });
    const standard_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/standard/contract.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "resource", .module = resource }} }) });
    engine.addImport("podman", podman);
    engine.addImport("janitor", janitor);
    const lua_runner = b.option(bool, "lua-runner", "Build the Lua runner and sandbox supervisor") orelse false;
    if (lua_runner) {
        const runner = b.addExecutable(.{ .name = "podtest-lua-runner", .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }) });
        runner.root_module.addCSourceFile(.{ .file = b.path("src/lua/runner.c"), .flags = &.{ "-Wall", "-Wextra", "-Werror" } });
        runner.root_module.linkSystemLibrary("lua5.5", .{ .use_pkg_config = .force });
        b.installArtifact(runner);
        const lua_supervisor = b.addExecutable(.{ .name = "test-lua-supervisor", .root_module = b.createModule(.{
            .root_source_file = b.path("src/lua/supervisor_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }) });
        lua_supervisor.root_module.addCSourceFile(.{ .file = b.path("src/lua/supervisor.c"), .flags = &.{ "-Wall", "-Wextra", "-Werror" } });
        lua_supervisor.root_module.addCSourceFile(.{ .file = b.path("src/lua/rpc_validate.c"), .flags = &.{ "-Wall", "-Wextra", "-Werror" } });
        lua_supervisor.root_module.addImport("podman", b.createModule(.{ .root_source_file = b.path("src/podman/client.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "resource", .module = resource }} }));
        lua_supervisor.root_module.addCSourceFile(.{ .file = b.path("src/podman/client.c"), .flags = &.{ "-Wall", "-Wextra", "-Werror" } });
        lua_supervisor.root_module.linkSystemLibrary("libcurl", .{});
        const check = b.addSystemCommand(&.{"bash"});
        check.addFileArg(b.path("spikes/lua-runner-check.sh"));
        check.addArtifactArg(lua_supervisor);
        check.addFileArg(runner.getEmittedBin());
        b.step("test-lua-runner", "Check sandboxed runner, RPC transport, scheduler and resource caps").dependOn(&check.step);
        const live = b.addSystemCommand(&.{"bash"});
        live.addFileArg(b.path("spikes/lua-runner-check.sh"));
        live.addArtifactArg(lua_supervisor);
        live.addFileArg(runner.getEmittedBin());
        live.addArg("--require-podman");
        b.step("test-lua-podman", "Verify concurrent Lua stdout RPC against two rootless containers").dependOn(&live.step);
    }
    const exe = b.addExecutable(.{
        .name = "podtest-invoker",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.link_libc = true;
    exe.root_module.addCSourceFile(.{ .file = b.path("src/host.c"), .flags = &.{ "-Wall", "-Wextra", "-Werror" } });
    exe.root_module.addCSourceFile(.{ .file = b.path("src/podman/client.c"), .flags = &.{ "-Wall", "-Wextra", "-Werror" } });
    exe.root_module.addImport("podman", podman);
    exe.root_module.addImport("janitor", janitor);
    exe.root_module.linkSystemLibrary("libcurl", .{});
    const grpc_enabled = b.option(bool, "artifact-control", "Build the mTLS artifact-control client") orelse false;
    const options = b.addOptions();
    options.addOption(bool, "artifact_control", grpc_enabled);
    const claim_fixture = b.option(bool, "claim-fixture", "Build the loopback JetStream Claim acceptance command") orelse false;
    options.addOption(bool, "claim_fixture", claim_fixture);
    const standard_worker = b.option(bool, "standard-worker", "Build the opt-in Standard queue worker") orelse false;
    options.addOption(bool, "standard_worker", standard_worker);
    options.addOption(bool, "lua_worker", lua_runner and standard_worker);
    if (lua_runner and standard_worker) {
        exe.root_module.addCSourceFile(.{ .file = b.path("src/lua/supervisor.c"), .flags = &.{ "-Wall", "-Wextra", "-Werror" } });
        exe.root_module.addCSourceFile(.{ .file = b.path("src/lua/rpc_validate.c"), .flags = &.{ "-Wall", "-Wextra", "-Werror" } });
    }
    if (claim_fixture or standard_worker) {
        if (!grpc_enabled) @panic("JetStream commands require artifact-control");
        const nats = b.lazyDependency("nats", .{ .target = target, .optimize = optimize }) orelse return;
        exe.root_module.addImport("nats", nats.module("nats"));
    }
    if (standard_worker) {
        exe.root_module.addImport("engine", engine);
        exe.root_module.addImport("history", engine.import_table.get("history").?);
    }
    exe.root_module.addOptions("build_options", options);
    if (grpc_enabled) {
        exe.root_module.addImport("resource", resource);
        const gen = b.addSystemCommand(&.{ "bash", "spikes/gen-control-c.sh" });
        gen.addFileInput(b.path("spikes/gen-control-c.sh"));
        gen.addFileArg(b.path("proto/control.proto"));
        const generated = gen.addOutputDirectoryArg("control-c");
        exe.root_module.addIncludePath(generated);
        exe.root_module.addCSourceFile(.{ .file = generated.path(b, "control.pb-c.c") });
        exe.root_module.addCSourceFile(.{ .file = b.path("src/control/artifact_rpc.c"), .flags = &.{ "-Wall", "-Wextra", "-Werror" } });
        exe.root_module.addCSourceFile(.{ .file = b.path("src/workspace/download.c"), .flags = &.{ "-Wall", "-Wextra", "-Werror" } });
        if (b.option([]const u8, "grpc-prefix", "Optional gRPC installation prefix")) |prefix| {
            exe.root_module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
            exe.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });
        }
        for ([_][]const u8{ "grpc", "gpr", "protobuf-c" }) |lib| exe.root_module.linkSystemLibrary(lib, .{ .use_pkg_config = .no });
    }
    b.installArtifact(exe);
    const release = b.step("install-diagnostics", "Stage the diagnostics binary, sample config, unit and runbooks");
    release.dependOn(&b.addInstallArtifact(exe, .{}).step);
    release.dependOn(&b.addInstallFile(b.path("config.example.json"), "share/podtest-invoker/config.example.json").step);
    release.dependOn(&b.addInstallFile(b.path("deploy/podtest-invoker.service"), "share/podtest-invoker/podtest-invoker.service").step);
    for ([_][]const u8{ "deployment.md", "phase8.md" }) |name| {
        release.dependOn(&b.addInstallFile(b.path(b.pathJoin(&.{ "docs", name })), b.pathJoin(&.{ "share/podtest-invoker/docs", name })).step);
    }

    const janitor_fixture = b.addExecutable(.{ .name = "test-janitor-fixture", .root_module = b.createModule(.{
        .root_source_file = b.path("src/janitor_fixture.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    janitor_fixture.root_module.addImport("podman", podman);
    janitor_fixture.root_module.addImport("janitor", janitor);
    janitor_fixture.root_module.linkSystemLibrary("libcurl", .{});
    janitor_fixture.root_module.addCSourceFile(.{ .file = b.path("src/host.c"), .flags = &.{ "-Wall", "-Wextra", "-Werror" } });
    janitor_fixture.root_module.addCSourceFile(.{ .file = b.path("src/podman/client.c"), .flags = &.{ "-Wall", "-Wextra", "-Werror" } });
    const janitor_live = b.addSystemCommand(&.{"bash"});
    janitor_live.addFileArg(b.path("spikes/janitor-check.sh"));
    janitor_live.addArtifactArg(exe);
    janitor_live.addArtifactArg(janitor_fixture);
    janitor_live.addFileArg(b.path("config.example.json"));
    b.step("test-janitor", "Verify locked container crash recovery on rootless Libpod").dependOn(&janitor_live.step);
    const janitor_load = b.addSystemCommand(&.{"bash"});
    janitor_load.addFileArg(b.path("spikes/janitor-load.sh"));
    janitor_load.addFileArg(b.path("spikes/janitor-check.sh"));
    janitor_load.addArtifactArg(exe);
    janitor_load.addArtifactArg(janitor_fixture);
    janitor_load.addFileArg(b.path("config.example.json"));
    b.step("test-janitor-load", "Run eight bounded two-owner recovery rounds on rootless Libpod").dependOn(&janitor_load.step);

    const crash_fixture = b.addExecutable(.{ .name = "test-outbox-crash-fixture", .root_module = b.createModule(.{
        .root_source_file = b.path("src/control/outbox_crash.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    crash_fixture.root_module.linkSystemLibrary("libcurl", .{});
    crash_fixture.root_module.addCSourceFile(.{ .file = b.path("src/host.c"), .flags = &.{ "-Wall", "-Wextra", "-Werror" } });
    const crash_check = b.addSystemCommand(&.{"bash"});
    crash_check.addFileArg(b.path("spikes/outbox-crash-check.sh"));
    crash_check.addArtifactArg(crash_fixture);
    b.step("test-outbox-crash", "Verify WAL replay after process SIGKILL before ACK").dependOn(&crash_check.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    if (grpc_enabled) test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = exe.root_module })).step);
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&b.addRunArtifact(standard_tests).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = janitor })).step);
    const calibration = b.createModule(.{ .root_source_file = b.path("src/calibration.zig"), .target = target, .optimize = optimize });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = calibration })).step);
    const rpc_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/lua/wire.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    rpc_tests.root_module.addCSourceFile(.{ .file = b.path("src/lua/rpc_validate.c"), .flags = &.{ "-Wall", "-Wextra", "-Werror" } });
    test_step.dependOn(&b.addRunArtifact(rpc_tests).step);

    const resource_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/resource.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    test_step.dependOn(&b.addRunArtifact(resource_tests).step);

    const history_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/stdio_history.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    test_step.dependOn(&b.addRunArtifact(history_tests).step);

    const pipe_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/pipe.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    test_step.dependOn(&b.addRunArtifact(pipe_tests).step);

    const standard_acceptance = b.addExecutable(.{ .name = "test-standard-executor", .root_module = b.createModule(.{
        .root_source_file = b.path("src/standard/acceptance.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ .{ .name = "engine", .module = engine }, .{ .name = "resource", .module = resource }, .{ .name = "history", .module = engine.import_table.get("history").? } },
    }) });
    standard_acceptance.root_module.addCSourceFile(.{ .file = b.path("src/podman/client.c"), .flags = &.{ "-Wall", "-Wextra", "-Werror" } });
    standard_acceptance.root_module.addImport("extract", b.createModule(.{ .root_source_file = b.path("src/workspace/extract.zig"), .target = target, .optimize = optimize }));
    standard_acceptance.root_module.linkSystemLibrary("libcurl", .{});
    const standard_run = b.addRunArtifact(standard_acceptance);
    const standard_live = b.step("test-standard", "Run the normalized Standard task through rootless Podman");
    standard_live.dependOn(&standard_run.step);

    const podman_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/podman/client.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    podman_tests.root_module.addImport("resource", resource);
    test_step.dependOn(&b.addRunArtifact(podman_tests).step);

    const podman_check = b.addExecutable(.{ .name = "test-invoker-podman", .root_module = b.createModule(.{
        .root_source_file = b.path("src/podman/acceptance.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    podman_check.root_module.addImport("resource", resource);
    podman_check.root_module.addImport("podman", podman);
    podman_check.root_module.addImport("janitor", janitor);
    podman_check.root_module.addImport("history", history_tests.root_module);
    podman_check.root_module.addImport("pipe", pipe_tests.root_module);
    podman_check.root_module.linkSystemLibrary("libcurl", .{});
    podman_check.root_module.addCSourceFile(.{ .file = b.path("src/podman/client.c"), .flags = &.{ "-Wall", "-Wextra", "-Werror" } });
    podman_check.root_module.addCSourceFile(.{ .file = b.path("src/host.c"), .flags = &.{ "-Wall", "-Wextra", "-Werror" } });
    const run_podman_check = b.addRunArtifact(podman_check);
    b.step("test-podman", "Verify Libpod on a rootless socket with a local Alpine image ID").dependOn(&run_podman_check.step);

    const delivery_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/control/delivery.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    test_step.dependOn(&b.addRunArtifact(delivery_tests).step);

    const outbox_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/control/outbox.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    test_step.dependOn(&b.addRunArtifact(outbox_tests).step);
    const result_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/result_outbox.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    result_tests.root_module.link_libc = true;
    result_tests.root_module.linkSystemLibrary("libcurl", .{});
    result_tests.root_module.addCSourceFile(.{ .file = b.path("src/workspace/download.c"), .flags = &.{ "-Wall", "-Wextra", "-Werror" } });
    test_step.dependOn(&b.addRunArtifact(result_tests).step);

    const download_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/workspace/upload.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    download_tests.root_module.link_libc = true;
    download_tests.root_module.linkSystemLibrary("libcurl", .{});
    download_tests.root_module.addCSourceFile(.{ .file = b.path("src/workspace/download.c"), .flags = &.{ "-Wall", "-Wextra", "-Werror" } });
    test_step.dependOn(&b.addRunArtifact(download_tests).step);

    const extraction_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/workspace/inputs.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    extraction_tests.root_module.link_libc = true;
    extraction_tests.root_module.linkSystemLibrary("libcurl", .{});
    extraction_tests.root_module.addCSourceFile(.{ .file = b.path("src/workspace/download.c"), .flags = &.{ "-Wall", "-Wextra", "-Werror" } });
    test_step.dependOn(&b.addRunArtifact(extraction_tests).step);

    if (b.option(bool, "jetstream-tests", "Enable the JetStream integration test executable") orelse false) {
        const nats = b.lazyDependency("nats", .{ .target = target, .optimize = optimize }) orelse return;
        const integration = b.addExecutable(.{
            .name = "test-invoker-jetstream",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/control/jetstream_test.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "nats", .module = nats.module("nats") }},
            }),
        });
        b.installArtifact(integration);
    }
}
