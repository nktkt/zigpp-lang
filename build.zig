const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zpp_module = b.addModule("zpp", .{
        .root_source_file = b.path("lib/zpp.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zpp_compiler_module = b.addModule("zpp_compiler", .{
        .root_source_file = b.path("compiler/mod.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zpp_lib = b.addLibrary(.{
        .name = "zpp",
        .linkage = .static,
        .root_module = zpp_module,
    });
    b.installArtifact(zpp_lib);

    const zpp_compiler_lib = b.addLibrary(.{
        .name = "zpp_compiler",
        .linkage = .static,
        .root_module = zpp_compiler_module,
    });
    b.installArtifact(zpp_compiler_lib);

    const exe_specs = [_]struct {
        name: []const u8,
        src: []const u8,
    }{
        .{ .name = "zpp", .src = "tools/zpp.zig" },
        .{ .name = "zpp-fmt", .src = "tools/zpp_fmt.zig" },
        .{ .name = "zpp-lsp", .src = "tools/zpp_lsp.zig" },
        .{ .name = "zpp-doc", .src = "tools/zpp_doc.zig" },
        .{ .name = "zpp-migrate", .src = "tools/zpp_migrate.zig" },
    };

    var main_exe: ?*std.Build.Step.Compile = null;

    for (exe_specs) |spec| {
        const mod = b.createModule(.{
            .root_source_file = b.path(spec.src),
            .target = target,
            .optimize = optimize,
        });
        mod.addImport("zpp", zpp_module);
        mod.addImport("zpp_compiler", zpp_compiler_module);
        const exe = b.addExecutable(.{
            .name = spec.name,
            .root_module = mod,
        });
        b.installArtifact(exe);
        if (std.mem.eql(u8, spec.name, "zpp")) main_exe = exe;
    }

    const run_step = b.step("run", "Run the zpp CLI: zig build run -- <args>");
    if (main_exe) |exe| {
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_cmd.addArgs(args);
        run_step.dependOn(&run_cmd.step);
    }

    const test_step = b.step("test", "Run unit tests for compiler/, lib/, tools/");
    addTestsForTree(b, target, optimize, zpp_module, zpp_compiler_module, "compiler", test_step);
    addTestsForTree(b, target, optimize, zpp_module, zpp_compiler_module, "lib", test_step);
    addTestsForTree(b, target, optimize, zpp_module, zpp_compiler_module, "tools", test_step);
    addTestsForTree(b, target, optimize, zpp_module, zpp_compiler_module, "tests", test_step);

    const check_step = b.step("check", "Run `zpp check` over examples/");
    if (main_exe) |exe| {
        const check_cmd = b.addRunArtifact(exe);
        check_cmd.addArg("check");
        check_cmd.addArg("examples");
        check_step.dependOn(&check_cmd.step);
    }

    const examples_step = b.step("examples", "Lower and build every .zpp under examples/");
    if (main_exe) |exe| {
        addExampleSteps(b, exe, examples_step);
    }

    const e2e_step = b.step("e2e", "Lower each example to .zig and run it");
    if (main_exe) |exe| {
        addE2ESteps(b, target, optimize, zpp_module, exe, e2e_step);
    }

    // Opt-in fuzz harness. Not part of `zig build test`.
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("tests/fuzz/fuzz.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_mod.addImport("zpp", zpp_module);
    fuzz_mod.addImport("zpp_compiler", zpp_compiler_module);
    const fuzz_exe = b.addExecutable(.{
        .name = "zpp-fuzz",
        .root_module = fuzz_mod,
    });
    const fuzz_run = b.addRunArtifact(fuzz_exe);
    if (b.args) |args| fuzz_run.addArgs(args);
    const fuzz_step = b.step("fuzz", "Run the zpp fuzz harness (set ZPP_FUZZ_ITERS=N, --seed=N for repro)");
    fuzz_step.dependOn(&fuzz_run.step);

    // Benchmark: compileToString throughput across input sizes.
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_mod.addImport("zpp", zpp_module);
    bench_mod.addImport("zpp_compiler", zpp_compiler_module);
    const bench_exe = b.addExecutable(.{
        .name = "zpp-bench",
        .root_module = bench_mod,
    });
    const bench_run = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run lowering microbenchmarks (ReleaseFast)");
    bench_step.dependOn(&bench_run.step);

    // Umbrella step: run everything that should be green before pushing.
    const all_step = b.step("all", "Run build + test + check + examples + e2e + bench (no fuzz)");
    all_step.dependOn(b.getInstallStep());
    all_step.dependOn(test_step);
    all_step.dependOn(check_step);
    all_step.dependOn(examples_step);
    all_step.dependOn(e2e_step);
    all_step.dependOn(bench_step);
}

fn addTestsForTree(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zpp_module: *std.Build.Module,
    compiler_module: *std.Build.Module,
    sub: []const u8,
    test_step: *std.Build.Step,
) void {
    var dir = std.fs.cwd().openDir(sub, .{ .iterate = true }) catch return;
    defer dir.close();

    var walker = dir.walk(b.allocator) catch return;
    defer walker.deinit();

    while (walker.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        if (std.mem.endsWith(u8, entry.path, "build.zig")) continue;
        // Path separator differs across platforms; check both.
        if (std.mem.indexOf(u8, entry.path, "lowering/snapshots") != null) continue;
        if (std.mem.indexOf(u8, entry.path, "lowering/inputs") != null) continue;
        if (std.mem.indexOf(u8, entry.path, "lowering\\snapshots") != null) continue;
        if (std.mem.indexOf(u8, entry.path, "lowering\\inputs") != null) continue;

        const rel = std.fs.path.join(b.allocator, &.{ sub, entry.path }) catch continue;
        const tmod = b.createModule(.{
            .root_source_file = b.path(rel),
            .target = target,
            .optimize = optimize,
        });
        tmod.addImport("zpp", zpp_module);
        tmod.addImport("zpp_compiler", compiler_module);
        const t = b.addTest(.{
            .name = b.fmt("test-{s}-{s}", .{ sub, entry.basename }),
            .root_module = tmod,
        });
        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
    }
}

fn addExampleSteps(b: *std.Build, exe: *std.Build.Step.Compile, examples_step: *std.Build.Step) void {
    var dir = std.fs.cwd().openDir("examples", .{ .iterate = true }) catch return;
    defer dir.close();

    var walker = dir.walk(b.allocator) catch return;
    defer walker.deinit();

    while (walker.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zpp")) continue;
        const rel = std.fs.path.join(b.allocator, &.{ "examples", entry.path }) catch continue;
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.addArg("lower");
        run_cmd.addArg(rel);
        examples_step.dependOn(&run_cmd.step);
    }
}

/// Lower each examples/*.zpp through zpp into a generated .zig file, then
/// build and run it as a real executable. This is the contract test for
/// "lowered Zig actually compiles and runs end-to-end".
fn addE2ESteps(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zpp_module: *std.Build.Module,
    zpp_exe: *std.Build.Step.Compile,
    e2e_step: *std.Build.Step,
) void {
    var dir = std.fs.cwd().openDir("examples", .{ .iterate = true }) catch return;
    defer dir.close();

    var walker = dir.walk(b.allocator) catch return;
    defer walker.deinit();

    while (walker.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zpp")) continue;

        const src_rel = std.fs.path.join(b.allocator, &.{ "examples", entry.path }) catch continue;
        const stem = entry.basename[0 .. entry.basename.len - 4];
        const out_name = b.fmt("e2e-{s}", .{stem});

        const lower_cmd = b.addRunArtifact(zpp_exe);
        lower_cmd.addArg("lower");
        lower_cmd.addArg(src_rel);
        const lazy_zig = lower_cmd.captureStdOut();

        const wf = b.addWriteFiles();
        const written = wf.addCopyFile(lazy_zig, b.fmt("{s}.zig", .{stem}));

        const exe_mod = b.createModule(.{
            .root_source_file = written,
            .target = target,
            .optimize = optimize,
        });
        exe_mod.addImport("zpp", zpp_module);
        const exe = b.addExecutable(.{
            .name = out_name,
            .root_module = exe_mod,
        });
        const run_exe = b.addRunArtifact(exe);
        e2e_step.dependOn(&run_exe.step);
    }
}
