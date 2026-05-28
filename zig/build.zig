const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Pure Zig server only (no bridge, no legacy IVF)
    // Target haswell + musl for static binary matching C final build
    const server_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const server = b.addExecutable(.{
        .name = "rinha-server",
        .root_module = server_mod,
    });
    // Static-ish friendly flags (musl target recommended at build time)
    b.installArtifact(server);

    // Run step
    const run_cmd = b.addRunArtifact(server);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the server");
    run_step.dependOn(&run_cmd.step);

    // Accuracy tester binary (critical gate — must report 0 FP + 0 FN on the oracle)
    const accuracy_mod = b.createModule(.{
        .root_source_file = b.path("src/accuracy_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const accuracy = b.addExecutable(.{
        .name = "accuracy_test",
        .root_module = accuracy_mod,
    });
    b.installArtifact(accuracy);
}
