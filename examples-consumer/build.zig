const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zpp_dep = b.dependency("zigpp", .{
        .target = target,
        .optimize = optimize,
    });

    const lower = b.addRunArtifact(zpp_dep.artifact("zpp"));
    lower.addArg("lower");
    lower.addFileArg(b.path("src/main.zpp"));
    const lowered = lower.captureStdOut();

    const wf = b.addWriteFiles();
    const main_zig = wf.addCopyFile(lowered, "main.zig");

    const exe_mod = b.createModule(.{
        .root_source_file = main_zig,
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("zpp", zpp_dep.module("zpp"));

    const exe = b.addExecutable(.{
        .name = "examples-consumer",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the downstream consumer demo");
    run_step.dependOn(&run_cmd.step);
}
