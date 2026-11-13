const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    // --- reference benchmark: static x86_64-linux binary embedded in the invoker ---
    const bench_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .musl,
    });
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("assets/benchmark/bench.zig"),
            .target = bench_target,
            .optimize = .ReleaseFast,
        }),
    });
    bench_exe.root_module.link_libc = true;
    b.installArtifact(bench_exe);

    const wf = b.addWriteFiles();
    const bench_bin = wf.addCopyFile(bench_exe.getEmittedBin(), "bench.bin");
    const bench_asset_src = wf.add("bench_asset.zig",
        \\pub const data = @embedFile("bench.bin");
    );
    const bench_asset = b.createModule(.{ .root_source_file = bench_asset_src });
    _ = bench_bin;

    // --- Lua 5.5.1 (vendored) ---
    const lua_sources: []const []const u8 = &.{
        "third_party/lua/src/lapi.c",     "third_party/lua/src/lauxlib.c", "third_party/lua/src/lbaselib.c", "third_party/lua/src/lcode.c",   "third_party/lua/src/lcorolib.c",
        "third_party/lua/src/lctype.c",   "third_party/lua/src/ldblib.c",  "third_party/lua/src/ldebug.c",   "third_party/lua/src/ldo.c",     "third_party/lua/src/ldump.c",
        "third_party/lua/src/lfunc.c",    "third_party/lua/src/lgc.c",     "third_party/lua/src/linit.c",    "third_party/lua/src/liolib.c",  "third_party/lua/src/llex.c",
        "third_party/lua/src/lmathlib.c", "third_party/lua/src/lmem.c",    "third_party/lua/src/loadlib.c",  "third_party/lua/src/lobject.c", "third_party/lua/src/lopcodes.c",
        "third_party/lua/src/loslib.c",   "third_party/lua/src/lparser.c", "third_party/lua/src/lstate.c",   "third_party/lua/src/lstring.c", "third_party/lua/src/lstrlib.c",
        "third_party/lua/src/ltable.c",   "third_party/lua/src/ltablib.c", "third_party/lua/src/ltm.c",      "third_party/lua/src/lundump.c", "third_party/lua/src/lutf8lib.c",
        "third_party/lua/src/lvm.c",      "third_party/lua/src/lzio.c",
    };

    const nghttp2_c = b.addTranslateC(.{
        .root_source_file = b.path("src/grpc/nghttp2_c.h"),
        .target = target,
        .optimize = optimize,
    });
    const nghttp2_mod = nghttp2_c.createModule();

    const exe = b.addExecutable(.{
        .name = "podtest-invoker",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("bench_asset", bench_asset);
    exe.root_module.addImport("nghttp2_c", nghttp2_mod);
    exe.root_module.link_libc = true;
    exe.root_module.linkSystemLibrary("nghttp2", .{});
    exe.root_module.linkSystemLibrary("z", .{});
    exe.root_module.addIncludePath(b.path("third_party/lua/src"));
    exe.root_module.addCSourceFiles(.{
        .files = lua_sources,
        .flags = &.{ "-std=gnu99", "-DLUA_USE_LINUX", "-fno-strict-aliasing" },
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the invoker");
    run_step.dependOn(&run_cmd.step);

    // --- unit tests ---
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unit_tests.root_module.addImport("bench_asset", bench_asset);
    unit_tests.root_module.addImport("nghttp2_c", nghttp2_mod);
    unit_tests.root_module.link_libc = true;
    unit_tests.root_module.linkSystemLibrary("nghttp2", .{});
    unit_tests.root_module.linkSystemLibrary("z", .{});
    unit_tests.root_module.addIncludePath(b.path("third_party/lua/src"));
    unit_tests.root_module.addCSourceFiles(.{
        .files = lua_sources,
        .flags = &.{ "-std=gnu99", "-DLUA_USE_LINUX", "-fno-strict-aliasing" },
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const bench_step = b.step("bench", "Build the reference benchmark binary");
    bench_step.dependOn(&bench_exe.step);
}
