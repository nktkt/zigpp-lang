//! zpp_init_templates.zig — file-set definitions for `zpp init --template <name>`.
//!
//! Each template is a static slice of (relative path, file body) pairs.
//! Both the path and the body run through the same `{project_name}` /
//! `{project_fingerprint}` placeholder substitution at scaffold time, so a
//! template can put the project name into a filename (e.g. `src/{project_name}.zpp`)
//! and into the file's contents.
//!
//! The driver (`tools/zpp.zig::cmdInit`) is the only consumer; tests in this
//! file cover lookup + invariants without doing any disk I/O.

const std = @import("std");

pub const TemplateFile = struct {
    /// Path relative to the new project root. May contain `{project_name}`.
    path: []const u8,
    /// File body text. May contain `{project_name}` and/or
    /// `{project_fingerprint}` placeholders.
    content: []const u8,
};

pub const Template = struct {
    name: []const u8,
    description: []const u8,
    files: []const TemplateFile,
};

// ---------------------------------------------------------------------------
// exe — minimal executable starter (the historical default).
// ---------------------------------------------------------------------------

const exe_main_zpp =
    \\const std = @import("std");
    \\const zpp = @import("zpp");
    \\
    \\pub fn main() !void {
    \\    std.debug.print("hello from {project_name}\n", .{});
    \\}
    \\
;

const exe_build_zig =
    \\const std = @import("std");
    \\
    \\pub fn build(b: *std.Build) void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const optimize = b.standardOptimizeOption(.{});
    \\
    \\    const zpp_dep = b.dependency("zigpp", .{
    \\        .target = target,
    \\        .optimize = optimize,
    \\    });
    \\
    \\    // Lower src/main.zpp -> src/main.zig at build time using the
    \\    // zpp executable from the dependency.
    \\    const lower = b.addRunArtifact(zpp_dep.artifact("zpp"));
    \\    lower.addArg("lower");
    \\    lower.addArg("src/main.zpp");
    \\    const lowered = lower.captureStdOut();
    \\
    \\    const wf = b.addWriteFiles();
    \\    const main_zig = wf.addCopyFile(lowered, "main.zig");
    \\
    \\    const exe_mod = b.createModule(.{
    \\        .root_source_file = main_zig,
    \\        .target = target,
    \\        .optimize = optimize,
    \\    });
    \\    exe_mod.addImport("zpp", zpp_dep.module("zpp"));
    \\
    \\    const exe = b.addExecutable(.{
    \\        .name = "{project_name}",
    \\        .root_module = exe_mod,
    \\    });
    \\    b.installArtifact(exe);
    \\
    \\    const run_cmd = b.addRunArtifact(exe);
    \\    run_cmd.step.dependOn(b.getInstallStep());
    \\    if (b.args) |args| run_cmd.addArgs(args);
    \\    const run_step = b.step("run", "Run the project");
    \\    run_step.dependOn(&run_cmd.step);
    \\}
    \\
;

const exe_build_zon =
    \\.{
    \\    .name = .{project_name},
    \\    .version = "0.1.0",
    \\    .fingerprint = 0x{project_fingerprint},
    \\    .minimum_zig_version = "0.15.0",
    \\    .paths = .{
    \\        "build.zig",
    \\        "build.zig.zon",
    \\        "src",
    \\        "README.md",
    \\    },
    \\    .dependencies = .{
    \\        .zigpp = .{
    \\            .url = "git+https://github.com/nktkt/zigpp-lang",
    \\            // Run `zig fetch --save git+https://github.com/nktkt/zigpp-lang`
    \\            // to populate the hash. The first build will tell you what to
    \\            // paste here.
    \\        },
    \\    },
    \\}
    \\
;

const common_gitignore =
    \\zig-out/
    \\.zig-cache/
    \\.zpp-cache/
    \\
    \\*.o
    \\*.a
    \\*.dylib
    \\*.so
    \\*.dll
    \\
    \\.DS_Store
    \\
;

const exe_readme =
    \\# {project_name}
    \\
    \\A new Zig++ executable project, scaffolded with `zpp init --template exe`.
    \\
    \\## Build
    \\
    \\```sh
    \\# First time only: pin the zigpp dependency hash.
    \\zig fetch --save git+https://github.com/nktkt/zigpp-lang
    \\
    \\# Build and run.
    \\zig build run
    \\```
    \\
    \\## Layout
    \\
    \\```
    \\{project_name}/
    \\  build.zig            build script (lowers .zpp -> .zig at build time)
    \\  build.zig.zon        package manifest (zigpp dependency)
    \\  src/
    \\    main.zpp           your program
    \\  README.md            this file
    \\```
    \\
;

pub const exe_template: Template = .{
    .name = "exe",
    .description = "Minimal executable: src/main.zpp + build.zig (the default).",
    .files = &.{
        .{ .path = "src/main.zpp", .content = exe_main_zpp },
        .{ .path = "build.zig", .content = exe_build_zig },
        .{ .path = "build.zig.zon", .content = exe_build_zon },
        .{ .path = ".gitignore", .content = common_gitignore },
        .{ .path = "README.md", .content = exe_readme },
    },
};

// ---------------------------------------------------------------------------
// lib — public-API library starter (no main).
// ---------------------------------------------------------------------------

const lib_main_zpp =
    \\//! {project_name} — public API surface.
    \\//!
    \\//! Anything `pub` in this file is part of your library's contract.
    \\//! Add new APIs here; downstream users `@import("{project_name}")`
    \\//! and call them.
    \\
    \\const std = @import("std");
    \\const zpp = @import("zpp");
    \\
    \\/// A small public trait. Implementors must report a stable name.
    \\pub trait Named {
    \\    fn name(self) []const u8;
    \\}
    \\
    \\/// A public derive(.Hash) struct — values are hashable so callers can
    \\/// drop them straight into a HashMap.
    \\pub struct Greeting {
    \\    who: []const u8,
    \\    excited: bool,
    \\} derive(.{ Hash });
    \\
    \\/// Build a greeting for a named subject.
    \\pub fn greet(who: []const u8) Greeting {
    \\    return .{ .who = who, .excited = false };
    \\}
    \\
    \\/// Same, but with an exclamation mark in spirit.
    \\pub fn shout(who: []const u8) Greeting {
    \\    return .{ .who = who, .excited = true };
    \\}
    \\
    \\/// Render a greeting into a fresh allocation. Caller frees.
    \\pub fn render(allocator: std.mem.Allocator, g: Greeting) ![]u8 {
    \\    const tail: []const u8 = if (g.excited) "!" else ".";
    \\    return std.fmt.allocPrint(allocator, "hello, {s}{s}", .{ g.who, tail });
    \\}
    \\
;

const lib_test_zpp =
    \\// Tests for the {project_name} public API. Run with `zig build test`.
    \\
    \\const std = @import("std");
    \\const lib = @import("{project_name}");
    \\
    \\test "greet returns a non-excited greeting" {
    \\    const g = lib.greet("world");
    \\    try std.testing.expectEqualStrings("world", g.who);
    \\    try std.testing.expect(!g.excited);
    \\}
    \\
    \\test "shout returns an excited greeting" {
    \\    const g = lib.shout("world");
    \\    try std.testing.expect(g.excited);
    \\}
    \\
    \\test "render produces the expected text" {
    \\    const a = std.testing.allocator;
    \\    const s = try lib.render(a, lib.greet("ada"));
    \\    defer a.free(s);
    \\    try std.testing.expectEqualStrings("hello, ada.", s);
    \\}
    \\
;

const lib_build_zig =
    \\const std = @import("std");
    \\
    \\pub fn build(b: *std.Build) void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const optimize = b.standardOptimizeOption(.{});
    \\
    \\    const zpp_dep = b.dependency("zigpp", .{
    \\        .target = target,
    \\        .optimize = optimize,
    \\    });
    \\
    \\    // Lower src/{project_name}.zpp -> {project_name}.zig at build time.
    \\    const lower_lib = b.addRunArtifact(zpp_dep.artifact("zpp"));
    \\    lower_lib.addArg("lower");
    \\    lower_lib.addArg("src/{project_name}.zpp");
    \\    const lib_zig = lower_lib.captureStdOut();
    \\
    \\    const wf = b.addWriteFiles();
    \\    const lib_root = wf.addCopyFile(lib_zig, "{project_name}.zig");
    \\
    \\    const lib_mod = b.createModule(.{
    \\        .root_source_file = lib_root,
    \\        .target = target,
    \\        .optimize = optimize,
    \\    });
    \\    lib_mod.addImport("zpp", zpp_dep.module("zpp"));
    \\
    \\    const lib = b.addLibrary(.{
    \\        .name = "{project_name}",
    \\        .linkage = .static,
    \\        .root_module = lib_mod,
    \\    });
    \\    b.installArtifact(lib);
    \\
    \\    // Lower the test file too, then build it as a test that imports
    \\    // the library module under its public name.
    \\    const lower_tests = b.addRunArtifact(zpp_dep.artifact("zpp"));
    \\    lower_tests.addArg("lower");
    \\    lower_tests.addArg("src/test_{project_name}.zpp");
    \\    const tests_zig = lower_tests.captureStdOut();
    \\
    \\    const tests_wf = b.addWriteFiles();
    \\    const tests_root = tests_wf.addCopyFile(tests_zig, "test_{project_name}.zig");
    \\
    \\    const test_mod = b.createModule(.{
    \\        .root_source_file = tests_root,
    \\        .target = target,
    \\        .optimize = optimize,
    \\    });
    \\    test_mod.addImport("zpp", zpp_dep.module("zpp"));
    \\    test_mod.addImport("{project_name}", lib_mod);
    \\
    \\    const t = b.addTest(.{
    \\        .name = "test-{project_name}",
    \\        .root_module = test_mod,
    \\    });
    \\    const run_t = b.addRunArtifact(t);
    \\    const test_step = b.step("test", "Run unit tests");
    \\    test_step.dependOn(&run_t.step);
    \\}
    \\
;

const lib_readme =
    \\# {project_name}
    \\
    \\A new Zig++ library project, scaffolded with `zpp init --template lib`.
    \\
    \\## Build
    \\
    \\```sh
    \\# First time only: pin the zigpp dependency hash.
    \\zig fetch --save git+https://github.com/nktkt/zigpp-lang
    \\
    \\# Build the library and run its tests.
    \\zig build
    \\zig build test
    \\```
    \\
    \\## Layout
    \\
    \\```
    \\{project_name}/
    \\  build.zig                  build script (library + tests)
    \\  build.zig.zon              package manifest (zigpp dependency)
    \\  src/
    \\    {project_name}.zpp       your public API (everything `pub` is exported)
    \\    test_{project_name}.zpp  unit tests
    \\  README.md                  this file
    \\```
    \\
    \\## Using as a dependency
    \\
    \\Downstream users add this library to their own `build.zig.zon` and then:
    \\
    \\```zig
    \\const {project_name} = @import("{project_name}");
    \\const g = {project_name}.greet("world");
    \\```
    \\
;

pub const lib_template: Template = .{
    .name = "lib",
    .description = "Library: public-API surface in src/{project_name}.zpp + tests, no main.",
    .files = &.{
        .{ .path = "src/{project_name}.zpp", .content = lib_main_zpp },
        .{ .path = "src/test_{project_name}.zpp", .content = lib_test_zpp },
        .{ .path = "build.zig", .content = lib_build_zig },
        .{ .path = "build.zig.zon", .content = exe_build_zon },
        .{ .path = ".gitignore", .content = common_gitignore },
        .{ .path = "README.md", .content = lib_readme },
    },
};

// ---------------------------------------------------------------------------
// plugin — extern-interface plugin starter (host + plugin shared lib).
// ---------------------------------------------------------------------------

const plugin_plugin_zpp =
    \\// {project_name} — extern-interface plugin starter.
    \\//
    \\// Demonstrates the C-ABI shape that survives across compilation units:
    \\//   * `extern interface` lowers to an `extern struct` vtable of
    \\//     `callconv(.c)` function pointers; each method takes its `self`
    \\//     as a leading `*anyopaque` parameter.
    \\//   * The plugin exports a single `loadPlugin` symbol returning a
    \\//     pointer to the vtable.
    \\//   * The host is built separately, opens this artifact via
    \\//     `std.DynLib`, and dispatches through that vtable.
    \\
    \\const std = @import("std");
    \\const zpp = @import("zpp");
    \\
    \\// Stable C-ABI interface. Lowers to:
    \\//     pub const Plugin_ABI = extern struct {
    \\//         name: *const fn (ctx: *anyopaque) callconv(.c) [*:0]const u8,
    \\//         run:  *const fn (ctx: *anyopaque, x: i32) callconv(.c) i32,
    \\//     };
    \\extern interface Plugin {
    \\    fn name(self) [*:0]const u8;
    \\    fn run(self, x: i32) i32;
    \\}
    \\
    \\// Sample implementation. Doubles every input value.
    \\const Doubler = struct {};
    \\
    \\impl Plugin for Doubler {
    \\    fn name(self) [*:0]const u8 {
    \\        _ = self;
    \\        return "doubler";
    \\    }
    \\    fn run(self, x: i32) i32 {
    \\        _ = self;
    \\        return x *% 2;
    \\    }
    \\}
    \\
    \\// Singleton context paired with the vtable. The host receives the
    \\// vtable pointer plus a context pointer (here, `&plugin_ctx`).
    \\pub var plugin_ctx: Doubler = .{};
    \\
    \\// Host entry point. The host calls `dlsym(handle, "loadPlugin")` and
    \\// receives this pointer back. Stable across plugin rebuilds because
    \\// the layout is `extern struct`.
    \\pub fn loadPlugin() callconv(.c) *const Plugin_ABI {
    \\    return &Plugin_impl_for_Doubler;
    \\}
    \\
    \\// Companion: exposes the context pointer matching the vtable above.
    \\pub fn loadPluginCtx() callconv(.c) *anyopaque {
    \\    return @ptrCast(&plugin_ctx);
    \\}
    \\
;

const plugin_host_zpp =
    \\// Host for the {project_name} plugin.
    \\//
    \\// In a real host you would resolve the plugin via std.DynLib:
    \\//
    \\//     var lib = try std.DynLib.open("zig-out/lib/lib{project_name}.dylib");
    \\//     defer lib.close();
    \\//     const load_fn = lib.lookup(
    \\//         *const fn () callconv(.c) *const Plugin_ABI,
    \\//         "loadPlugin",
    \\//     ) orelse return error.MissingSymbol;
    \\//     const ctx_fn = lib.lookup(
    \\//         *const fn () callconv(.c) *anyopaque,
    \\//         "loadPluginCtx",
    \\//     ) orelse return error.MissingSymbol;
    \\//     const vt = load_fn();
    \\//     const ctx = ctx_fn();
    \\//
    \\// That path depends on the plugin shared library being built and
    \\// installed first, so this scaffold instead links the plugin module
    \\// directly and exercises the same vtable path. Swap to std.DynLib
    \\// once you ship the shared lib.
    \\
    \\const std = @import("std");
    \\const zpp = @import("zpp");
    \\const plugin = @import("plugin");
    \\
    \\pub fn main() !void {
    \\    const vt = plugin.loadPlugin();
    \\    const ctx = plugin.loadPluginCtx();
    \\    const name_ptr = vt.name(ctx);
    \\    const name_slice = std.mem.span(name_ptr);
    \\    std.debug.print("loaded plugin: {s}\n", .{name_slice});
    \\
    \\    var i: i32 = 0;
    \\    while (i < 4) : (i += 1) {
    \\        std.debug.print("  run({d}) = {d}\n", .{ i, vt.run(ctx, i) });
    \\    }
    \\}
    \\
;

const plugin_build_zig =
    \\const std = @import("std");
    \\
    \\pub fn build(b: *std.Build) void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const optimize = b.standardOptimizeOption(.{});
    \\
    \\    const zpp_dep = b.dependency("zigpp", .{
    \\        .target = target,
    \\        .optimize = optimize,
    \\    });
    \\
    \\    // Lower the two .zpp sources via the zpp tool.
    \\    const lower_plugin = b.addRunArtifact(zpp_dep.artifact("zpp"));
    \\    lower_plugin.addArg("lower");
    \\    lower_plugin.addArg("src/plugin.zpp");
    \\    const plugin_zig = lower_plugin.captureStdOut();
    \\
    \\    const lower_host = b.addRunArtifact(zpp_dep.artifact("zpp"));
    \\    lower_host.addArg("lower");
    \\    lower_host.addArg("src/host.zpp");
    \\    const host_zig = lower_host.captureStdOut();
    \\
    \\    const wf = b.addWriteFiles();
    \\    const plugin_src = wf.addCopyFile(plugin_zig, "plugin.zig");
    \\    const host_src = wf.addCopyFile(host_zig, "host.zig");
    \\
    \\    const plugin_mod = b.createModule(.{
    \\        .root_source_file = plugin_src,
    \\        .target = target,
    \\        .optimize = optimize,
    \\    });
    \\    plugin_mod.addImport("zpp", zpp_dep.module("zpp"));
    \\
    \\    // Plugin: shared library. Zig picks .dylib on macOS, .so on Linux,
    \\    // .dll on Windows.
    \\    const plugin_lib = b.addLibrary(.{
    \\        .name = "{project_name}",
    \\        .linkage = .dynamic,
    \\        .root_module = plugin_mod,
    \\    });
    \\    b.installArtifact(plugin_lib);
    \\
    \\    const host_mod = b.createModule(.{
    \\        .root_source_file = host_src,
    \\        .target = target,
    \\        .optimize = optimize,
    \\    });
    \\    host_mod.addImport("zpp", zpp_dep.module("zpp"));
    \\    host_mod.addImport("plugin", plugin_mod);
    \\
    \\    const host_exe = b.addExecutable(.{
    \\        .name = "{project_name}-host",
    \\        .root_module = host_mod,
    \\    });
    \\    b.installArtifact(host_exe);
    \\
    \\    const run_cmd = b.addRunArtifact(host_exe);
    \\    run_cmd.step.dependOn(b.getInstallStep());
    \\    if (b.args) |args| run_cmd.addArgs(args);
    \\    const run_step = b.step("run", "Run the host");
    \\    run_step.dependOn(&run_cmd.step);
    \\}
    \\
;

const plugin_readme =
    \\# {project_name}
    \\
    \\A new Zig++ plugin project, scaffolded with `zpp init --template plugin`.
    \\Demonstrates the `extern interface` C-ABI shape: a host program
    \\dispatches into a plugin through a fixed-layout vtable.
    \\
    \\## Build
    \\
    \\```sh
    \\zig fetch --save git+https://github.com/nktkt/zigpp-lang
    \\zig build              # builds plugin shared lib + host exe
    \\zig build run          # runs the host
    \\```
    \\
    \\## Layout
    \\
    \\```
    \\{project_name}/
    \\  build.zig            builds plugin (.dylib/.so/.dll) and host (exe)
    \\  build.zig.zon        package manifest
    \\  src/
    \\    plugin.zpp         declares `extern interface Plugin` and exports
    \\                       `loadPlugin()` from a shared library.
    \\    host.zpp           tiny host that calls into the plugin vtable.
    \\  README.md            this file
    \\```
    \\
    \\## Going further
    \\
    \\The scaffold links the host directly against the plugin module so
    \\everything compiles cleanly without needing the shared library on disk.
    \\To go fully dynamic, swap the `@import("plugin")` in `src/host.zpp`
    \\for a `std.DynLib.open` call against the installed `.dylib`/`.so`/`.dll`
    \\and dlsym `loadPlugin`.
    \\
;

pub const plugin_template: Template = .{
    .name = "plugin",
    .description = "Plugin: extern interface + host + plugin shared lib (C-ABI).",
    .files = &.{
        .{ .path = "src/plugin.zpp", .content = plugin_plugin_zpp },
        .{ .path = "src/host.zpp", .content = plugin_host_zpp },
        .{ .path = "build.zig", .content = plugin_build_zig },
        .{ .path = "build.zig.zon", .content = exe_build_zon },
        .{ .path = ".gitignore", .content = common_gitignore },
        .{ .path = "README.md", .content = plugin_readme },
    },
};

// ---------------------------------------------------------------------------
// Registry.
// ---------------------------------------------------------------------------

pub const all_templates = [_]Template{ exe_template, lib_template, plugin_template };

/// Look a template up by name. Returns null on unknown name.
pub fn findByName(name: []const u8) ?Template {
    for (all_templates) |t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

/// Render `src` with `{project_name}` and `{project_fingerprint}` placeholders
/// substituted. Caller owns returned slice.
pub fn render(
    allocator: std.mem.Allocator,
    src: []const u8,
    project_name: []const u8,
    fingerprint_hex: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < src.len) {
        if (matchAt(src, i, "{project_name}")) {
            try out.appendSlice(allocator, project_name);
            i += "{project_name}".len;
            continue;
        }
        if (matchAt(src, i, "{project_fingerprint}")) {
            try out.appendSlice(allocator, fingerprint_hex);
            i += "{project_fingerprint}".len;
            continue;
        }
        try out.append(allocator, src[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn matchAt(haystack: []const u8, at: usize, needle: []const u8) bool {
    if (at + needle.len > haystack.len) return false;
    return std.mem.eql(u8, haystack[at .. at + needle.len], needle);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "every template has a non-empty file list, a build.zig, and a .zpp file" {
    for (all_templates) |t| {
        try std.testing.expect(t.files.len > 0);
        try std.testing.expect(t.name.len > 0);
        try std.testing.expect(t.description.len > 0);

        var has_build_zig = false;
        var has_zpp = false;
        for (t.files) |f| {
            try std.testing.expect(f.path.len > 0);
            try std.testing.expect(f.content.len > 0);
            if (std.mem.eql(u8, f.path, "build.zig")) has_build_zig = true;
            if (std.mem.endsWith(u8, f.path, ".zpp")) has_zpp = true;
        }
        try std.testing.expect(has_build_zig);
        try std.testing.expect(has_zpp);
    }
}

test "every template has a {project_name} placeholder somewhere" {
    for (all_templates) |t| {
        var saw_placeholder = false;
        for (t.files) |f| {
            if (std.mem.indexOf(u8, f.path, "{project_name}") != null or
                std.mem.indexOf(u8, f.content, "{project_name}") != null)
            {
                saw_placeholder = true;
                break;
            }
        }
        try std.testing.expect(saw_placeholder);
    }
}

test "findByName resolves known templates and rejects unknown ones" {
    try std.testing.expectEqualStrings("exe", findByName("exe").?.name);
    try std.testing.expectEqualStrings("lib", findByName("lib").?.name);
    try std.testing.expectEqualStrings("plugin", findByName("plugin").?.name);
    try std.testing.expect(findByName("nope") == null);
    try std.testing.expect(findByName("") == null);
    try std.testing.expect(findByName("EXE") == null); // case-sensitive
}

test "render substitutes both placeholders" {
    const a = std.testing.allocator;
    const src = "name={project_name}, fp=0x{project_fingerprint}, again={project_name}";
    const out = try render(a, src, "demo", "deadbeef");
    defer a.free(out);
    try std.testing.expectEqualStrings("name=demo, fp=0xdeadbeef, again=demo", out);
}

test "render leaves unrelated braces alone" {
    const a = std.testing.allocator;
    const src = "{}{x}{ project_name }";
    const out = try render(a, src, "demo", "ff");
    defer a.free(out);
    try std.testing.expectEqualStrings("{}{x}{ project_name }", out);
}

test "render works on an empty source" {
    const a = std.testing.allocator;
    const out = try render(a, "", "demo", "ff");
    defer a.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "all_templates is exactly the three documented templates" {
    try std.testing.expectEqual(@as(usize, 3), all_templates.len);
    try std.testing.expectEqualStrings("exe", all_templates[0].name);
    try std.testing.expectEqualStrings("lib", all_templates[1].name);
    try std.testing.expectEqualStrings("plugin", all_templates[2].name);
}

test "lib template's path placeholder expands correctly" {
    const a = std.testing.allocator;
    const t = findByName("lib").?;
    var saw_lib_root = false;
    for (t.files) |f| {
        const rendered_path = try render(a, f.path, "mylib", "ff");
        defer a.free(rendered_path);
        if (std.mem.eql(u8, rendered_path, "src/mylib.zpp")) saw_lib_root = true;
    }
    try std.testing.expect(saw_lib_root);
}
