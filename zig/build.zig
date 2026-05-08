const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Server binary: Zig main + C bridge
    const server_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    server_mod.addIncludePath(b.path("src"));
    server_mod.addCSourceFile(.{
        .file = b.path("src/bridge.c"),
        .flags = &.{ "-O3", "-march=haswell", "-mfma", "-fomit-frame-pointer", "-fno-semantic-interposition", "-fno-trapping-math", "-fno-math-errno", "-ffp-contract=fast", "-DNDEBUG" },
    });
    server_mod.linkSystemLibrary("m", .{});

    const server = b.addExecutable(.{
        .name = "rinha-server",
        .root_module = server_mod,
    });
    b.installArtifact(server);

    // Build-index binary
    const build_index = b.addExecutable(.{
        .name = "build-index",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/build_index.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(build_index);

    // Benchmark binary: C bridge vs pure Zig
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    bench_mod.addIncludePath(b.path("src"));
    bench_mod.addCSourceFile(.{
        .file = b.path("src/bridge.c"),
        .flags = &.{ "-O3", "-march=haswell", "-mfma", "-fomit-frame-pointer", "-fno-semantic-interposition", "-fno-trapping-math", "-fno-math-errno", "-ffp-contract=fast", "-DNDEBUG" },
    });
    bench_mod.linkSystemLibrary("m", .{});

    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = bench_mod,
    });
    _ = bench; // not installed (bench-binary only)
    _ = bench; // not installed (bench-binary only)

    // Run step
    const run_cmd = b.addRunArtifact(server);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the server");
    run_step.dependOn(&run_cmd.step);
}
