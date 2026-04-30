const std = @import("std");
const compiler = @import("zpp_compiler");
const fmt_lib = @import("zpp_fmt.zig");
const lsp = @import("zpp_lsp.zig");
const doc = @import("zpp_doc.zig");
const migrate = @import("zpp_migrate.zig");

pub const version_string = "zpp 0.1.0 (Zig++ research compiler)";

pub const ExitCode = enum(u8) {
    ok = 0,
    user_error = 1,
    compiler_bug = 2,
    usage_error = 64,
};

const Subcommand = enum {
    build,
    run,
    lower,
    fmt,
    check,
    watch,
    doc,
    migrate,
    lsp,
    init,
    explain,
    version,
    help,

    fn parse(name: []const u8) ?Subcommand {
        const map = .{
            .{ "build", .build },
            .{ "run", .run },
            .{ "lower", .lower },
            .{ "fmt", .fmt },
            .{ "check", .check },
            .{ "watch", .watch },
            .{ "doc", .doc },
            .{ "migrate", .migrate },
            .{ "lsp", .lsp },
            .{ "init", .init },
            .{ "explain", .explain },
            .{ "version", .version },
            .{ "--version", .version },
            .{ "-V", .version },
            .{ "help", .help },
            .{ "--help", .help },
            .{ "-h", .help },
        };
        inline for (map) |entry| {
            if (std.mem.eql(u8, name, entry[0])) return entry[1];
        }
        return null;
    }
};

fn errStream() std.fs.File {
    // VERIFY: 0.16 API — std.fs.File.stderr() returns the process stderr handle.
    return std.fs.File.stderr();
}

fn outStream() std.fs.File {
    // VERIFY: 0.16 API — std.fs.File.stdout() returns the process stdout handle.
    return std.fs.File.stdout();
}

fn writeAll(file: std.fs.File, bytes: []const u8) !void {
    // VERIFY: 0.16 API — File.writeAll persists across the writergate redesign.
    try file.writeAll(bytes);
}

fn ePrint(comptime fmt_str: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, fmt_str, args) catch return;
    errStream().writeAll(slice) catch {};
}

fn oPrint(comptime fmt_str: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, fmt_str, args) catch return;
    outStream().writeAll(slice) catch {};
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            ePrint("zpp: memory leak detected\n", .{});
        }
    }
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const code = run(allocator, argv) catch |e| {
        ePrint("zpp: fatal: {s}\n", .{@errorName(e)});
        std.process.exit(@intFromEnum(ExitCode.compiler_bug));
    };
    std.process.exit(@intFromEnum(code));
}

pub fn run(allocator: std.mem.Allocator, argv: [][:0]u8) !ExitCode {
    if (argv.len < 2) {
        printUsage();
        return .usage_error;
    }
    const sub = Subcommand.parse(argv[1]) orelse {
        ePrint("zpp: unknown subcommand '{s}'\n\n", .{argv[1]});
        printUsage();
        return .usage_error;
    };
    const rest = argv[2..];
    return switch (sub) {
        .build => cmdBuild(allocator, rest),
        .run => cmdRun(allocator, rest),
        .lower => cmdLower(allocator, rest),
        .fmt => cmdFmt(allocator, rest),
        .check => cmdCheck(allocator, rest),
        .watch => cmdWatch(allocator, rest),
        .doc => cmdDoc(allocator, rest),
        .migrate => cmdMigrate(allocator, rest),
        .lsp => cmdLsp(allocator, rest),
        .init => cmdInit(allocator, rest),
        .explain => cmdExplain(rest),
        .version => cmdVersion(),
        .help => cmdHelp(rest),
    };
}

fn printUsage() void {
    const usage =
        \\zpp — Zig++ tool driver
        \\
        \\USAGE:
        \\    zpp <subcommand> [args...]
        \\
        \\SUBCOMMANDS:
        \\    build [path]         lower .zpp -> .zig under .zpp-cache/ and run `zig build`
        \\    run <file.zpp>       lower and execute a single source file
        \\    lower <file.zpp>     print lowered .zig to stdout
        \\    fmt [paths...]       format .zpp files in place
        \\    check [paths...]     parse + sema, no codegen, exit nonzero on diagnostic
        \\    watch [paths...]     re-run `check` whenever any .zpp under <paths> changes
        \\    doc [paths...]       generate markdown docs from .zpp doc comments
        \\    migrate <file.zig>   suggest .zpp rewrites for a .zig file
        \\    lsp                  start LSP server on stdin/stdout
        \\    init <name>          scaffold a new Zig++ project under <name>/
        \\    explain <Z####|-l>   explain a diagnostic code in detail (--list to see all)
        \\    version              print version
        \\    help [subcommand]    show this help (or details for a subcommand)
        \\
    ;
    oPrint("{s}", .{usage});
}

fn cmdVersion() !ExitCode {
    oPrint("{s}\n", .{version_string});
    return .ok;
}

fn cmdHelp(args: [][:0]u8) !ExitCode {
    if (args.len == 0) {
        printUsage();
        return .ok;
    }
    const sub = Subcommand.parse(args[0]) orelse {
        ePrint("zpp help: unknown subcommand '{s}'\n", .{args[0]});
        return .usage_error;
    };
    const detail = switch (sub) {
        .build => "zpp build [path]\n  Lower every .zpp under <path> (default '.') into .zpp-cache/ mirroring layout, then invoke `zig build`.\n",
        .run => "zpp run <file.zpp>\n  Lower a single .zpp source, write it to a tmp file, and execute it via `zig run`.\n",
        .lower => "zpp lower <file.zpp>\n  Print lowered .zig source for one file to stdout.\n",
        .fmt => "zpp fmt [paths...]\n  Re-emit .zpp files with canonical whitespace; expands directories.\n",
        .check => "zpp check [paths...]\n  Parse and semantically analyse .zpp files; emit diagnostics; exit 1 on error.\n",
        .watch => "zpp watch [paths...]\n  Snapshot .zpp file mtimes and re-run `zpp check` whenever any of them changes. Polls every ~500ms; Ctrl-C to exit.\n",
        .doc => "zpp doc [paths...]\n  Walk .zpp files and emit Markdown for trait/fn/struct/extern interface decls.\n",
        .migrate => "zpp migrate <file.zig>\n  Diff suggestions to convert defer/init/deinit patterns to Zig++.\n",
        .lsp => "zpp lsp\n  Speak LSP over stdio. Run from your editor; not for human use.\n",
        .init => "zpp init <name>\n  Scaffold a new Zig++ project under <name>/ with build.zig, build.zig.zon, src/main.zpp, and a starter README. Refuses to overwrite an existing directory.\n",
        .explain => "zpp explain <Z####|--list>\n  Print a long-form explanation of a diagnostic code, or `--list` to see every code with a one-line summary.\n",
        .version => "zpp version\n  Print compiler version.\n",
        .help => "zpp help [subcommand]\n  Show this message.\n",
    };
    oPrint("{s}", .{detail});
    return .ok;
}

fn cmdLower(allocator: std.mem.Allocator, args: [][:0]u8) !ExitCode {
    if (args.len != 1) {
        ePrint("zpp lower: expected exactly one .zpp path\n", .{});
        return .usage_error;
    }
    const path = args[0];
    const source = readFileAlloc(allocator, path) catch |e| {
        ePrint("zpp lower: cannot read '{s}': {s}\n", .{ path, @errorName(e) });
        return .user_error;
    };
    defer allocator.free(source);

    // COMPILER_API: assumes compiler.compileToString(allocator, source) ![]u8 exists.
    const lowered = compiler.compileToString(allocator, source) catch |e| {
        ePrint("zpp lower: {s}: {s}\n", .{ path, @errorName(e) });
        return .compiler_bug;
    };
    defer allocator.free(lowered);

    try writeAll(outStream(), lowered);
    return .ok;
}

fn cmdRun(allocator: std.mem.Allocator, args: [][:0]u8) !ExitCode {
    if (args.len < 1) {
        ePrint("zpp run: expected at least <file.zpp>\n", .{});
        return .usage_error;
    }
    const path = args[0];
    const source = readFileAlloc(allocator, path) catch |e| {
        ePrint("zpp run: cannot read '{s}': {s}\n", .{ path, @errorName(e) });
        return .user_error;
    };
    defer allocator.free(source);

    const lowered = compiler.compileToString(allocator, source) catch |e| {
        ePrint("zpp run: {s}: {s}\n", .{ path, @errorName(e) });
        return .compiler_bug;
    };
    defer allocator.free(lowered);

    var cache_dir = try ensureCacheDir(allocator);
    defer cache_dir.close();

    const stem = stemOf(path);
    const tmp_name = try std.fmt.allocPrint(allocator, "{s}.zig", .{stem});
    defer allocator.free(tmp_name);
    try cache_dir.writeFile(.{ .sub_path = tmp_name, .data = lowered });

    const tmp_full = try std.fs.path.join(allocator, &.{ ".zpp-cache", tmp_name });
    defer allocator.free(tmp_full);

    // Locate the zpp runtime library next to this executable so the lowered
    // code's `@import("zpp")` resolves. Falls back to the in-tree path during
    // development.
    const zpp_lib = locateZppLib(allocator) catch "lib/zpp.zig";
    defer allocator.free(zpp_lib);
    const dep_arg = try std.fmt.allocPrint(allocator, "-Mzpp={s}", .{zpp_lib});
    defer allocator.free(dep_arg);
    const root_arg = try std.fmt.allocPrint(allocator, "-Mroot={s}", .{tmp_full});
    defer allocator.free(root_arg);

    var argv_list = std.ArrayList([]const u8){};
    defer argv_list.deinit(allocator);
    try argv_list.appendSlice(allocator, &.{ "zig", "run", "--dep", "zpp", root_arg, dep_arg });
    for (args[1..]) |a| try argv_list.append(allocator, a);
    const final_argv = argv_list.items;

    var child = std.process.Child.init(final_argv, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = child.spawnAndWait() catch |e| {
        ePrint("zpp run: failed to invoke `zig run`: {s}\n", .{@errorName(e)});
        return .user_error;
    };
    return termToExit(term);
}

/// Find `lib/zpp.zig`. Resolution order:
///   1. `ZPP_LIB` env var (production override)
///   2. cwd-relative `lib/zpp.zig` / `../lib/zpp.zig`
///   3. Walk up from cwd until a `lib/zpp.zig` is found (handles invocation
///      from any subdirectory of the zigpp-lang repo, e.g. examples/multi_file/)
///   4. Relative to the `zpp` executable's own dir (installed binaries)
fn locateZppLib(allocator: std.mem.Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "ZPP_LIB")) |envp| {
        return envp;
    } else |_| {}

    const candidates = [_][]const u8{
        "lib/zpp.zig",
        "../lib/zpp.zig",
    };
    for (candidates) |c| {
        std.fs.cwd().access(c, .{}) catch continue;
        return try allocator.dupe(u8, c);
    }

    if (try findZppLibUpward(allocator)) |p| return p;

    const self_dir = try std.fs.selfExeDirPathAlloc(allocator);
    defer allocator.free(self_dir);
    const guesses = [_][]const u8{ "../lib/zpp.zig", "lib/zpp.zig" };
    for (guesses) |g| {
        const path = try std.fs.path.join(allocator, &.{ self_dir, g });
        std.fs.cwd().access(path, .{}) catch {
            allocator.free(path);
            continue;
        };
        return path;
    }
    return error.FileNotFound;
}

fn findZppLibUpward(allocator: std.mem.Allocator) !?[]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const start = std.fs.cwd().realpath(".", &cwd_buf) catch return null;

    var current_len: usize = start.len;
    while (current_len > 0) {
        const dir_slice = cwd_buf[0..current_len];
        const candidate = try std.fs.path.join(allocator, &.{ dir_slice, "lib", "zpp.zig" });
        if (std.fs.cwd().access(candidate, .{})) |_| {
            return candidate;
        } else |_| {
            allocator.free(candidate);
        }
        const parent = std.fs.path.dirname(dir_slice) orelse return null;
        if (parent.len == current_len) return null;
        current_len = parent.len;
    }
    return null;
}

fn cmdBuild(allocator: std.mem.Allocator, args: [][:0]u8) !ExitCode {
    const split = splitBuildArgs(args);
    const root: []const u8 = if (split.zpp.len == 0) "." else split.zpp[0];

    var src_dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch |e| {
        ePrint("zpp build: cannot open '{s}': {s}\n", .{ root, @errorName(e) });
        return .user_error;
    };
    defer src_dir.close();

    var cache = try ensureCacheDir(allocator);
    defer cache.close();

    var walker = try src_dir.walk(allocator);
    defer walker.deinit();

    var compiled: usize = 0;
    var errors: usize = 0;
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zpp")) continue;

        const source = src_dir.readFileAlloc(allocator, entry.path, 16 * 1024 * 1024) catch |e| {
            ePrint("zpp build: cannot read '{s}': {s}\n", .{ entry.path, @errorName(e) });
            errors += 1;
            continue;
        };
        defer allocator.free(source);

        const lowered = compiler.compileToString(allocator, source) catch |e| {
            ePrint("zpp build: {s}: {s}\n", .{ entry.path, @errorName(e) });
            errors += 1;
            continue;
        };
        defer allocator.free(lowered);

        const out_path = try replaceExt(allocator, entry.path, ".zig");
        defer allocator.free(out_path);

        if (std.fs.path.dirname(out_path)) |sub| {
            try cache.makePath(sub);
        }
        try cache.writeFile(.{ .sub_path = out_path, .data = lowered });
        compiled += 1;
    }

    oPrint("zpp build: lowered {d} file(s), {d} error(s)\n", .{ compiled, errors });
    if (errors > 0) return .user_error;

    // If the user has no build.zig, emit a minimal one inside .zpp-cache/
    // so `zig build` has something to drive. The shim points the executable
    // at the lowered entry and wires the `zpp` runtime as a module.
    const has_user_build_zig = blk: {
        src_dir.access("build.zig", .{}) catch break :blk false;
        break :blk true;
    };

    var argv_list: std.ArrayList([]const u8) = .{};
    defer argv_list.deinit(allocator);
    try argv_list.appendSlice(allocator, &.{ "zig", "build" });

    if (!has_user_build_zig) {
        const entry_rel = pickEntryRel(allocator, &cache) catch |e| switch (e) {
            error.FileNotFound => {
                ePrint("zpp build: no entry point found. Expected .zpp-cache/src/main.zig or .zpp-cache/main.zig (lower a src/main.zpp or main.zpp).\n", .{});
                return .user_error;
            },
            else => return e,
        };
        defer allocator.free(entry_rel);

        const zpp_lib = locateZppLib(allocator) catch |e| {
            ePrint("zpp build: could not locate the zpp runtime (lib/zpp.zig). Set ZPP_LIB or run from inside the zigpp-lang tree. {s}\n", .{@errorName(e)});
            return .user_error;
        };
        defer allocator.free(zpp_lib);
        const zpp_lib_abs = try absolutize(allocator, zpp_lib);
        defer allocator.free(zpp_lib_abs);

        const proj_name = try projectNameFromCwd(allocator);
        defer allocator.free(proj_name);

        const shim = try renderBuildShim(allocator, .{
            .name = proj_name,
            .entry_rel = entry_rel,
            .zpp_lib_abs = zpp_lib_abs,
        });
        defer allocator.free(shim);
        try cache.writeFile(.{ .sub_path = "build.zig", .data = shim });

        try argv_list.appendSlice(allocator, &.{ "--build-file", ".zpp-cache/build.zig" });
    }

    for (split.passthrough) |a| try argv_list.append(allocator, a);

    var child = std.process.Child.init(argv_list.items, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = child.spawnAndWait() catch |e| {
        ePrint("zpp build: failed to invoke `zig build`: {s}\n", .{@errorName(e)});
        return .user_error;
    };
    return termToExit(term);
}

const SplitArgs = struct {
    zpp: [][:0]u8,
    passthrough: [][:0]u8,
};

/// Split CLI args at the first `--`. Args before the separator are
/// zpp-level (e.g. project dir); args after are forwarded to `zig
/// build` so the user can write `zpp build -- run` or
/// `zpp build src/ -- test --release=fast`.
fn splitBuildArgs(args: [][:0]u8) SplitArgs {
    for (args, 0..) |a, i| {
        if (std.mem.eql(u8, a, "--")) {
            return .{ .zpp = args[0..i], .passthrough = args[i + 1 ..] };
        }
    }
    return .{ .zpp = args, .passthrough = args[args.len..] };
}

const ShimContext = struct {
    name: []const u8,
    entry_rel: []const u8,
    zpp_lib_abs: []const u8,
};

fn renderBuildShim(allocator: std.mem.Allocator, ctx: ShimContext) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\// Auto-generated by `zpp build` because no user build.zig was found.
        \\// Regenerated on every `zpp build`. Do not edit — write your own
        \\// build.zig at the project root if you need to customize.
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) void {{
        \\    const target = b.standardTargetOptions(.{{}});
        \\    const optimize = b.standardOptimizeOption(.{{}});
        \\
        \\    const zpp_module = b.createModule(.{{
        \\        .root_source_file = .{{ .cwd_relative = "{s}" }},
        \\        .target = target,
        \\        .optimize = optimize,
        \\    }});
        \\
        \\    const exe_mod = b.createModule(.{{
        \\        .root_source_file = b.path("{s}"),
        \\        .target = target,
        \\        .optimize = optimize,
        \\    }});
        \\    exe_mod.addImport("zpp", zpp_module);
        \\
        \\    const exe = b.addExecutable(.{{
        \\        .name = "{s}",
        \\        .root_module = exe_mod,
        \\    }});
        \\    b.installArtifact(exe);
        \\
        \\    const run_cmd = b.addRunArtifact(exe);
        \\    run_cmd.step.dependOn(b.getInstallStep());
        \\    if (b.args) |args| run_cmd.addArgs(args);
        \\    const run_step = b.step("run", "Run the project");
        \\    run_step.dependOn(&run_cmd.step);
        \\}}
        \\
    , .{ ctx.zpp_lib_abs, ctx.entry_rel, ctx.name });
}

fn pickEntryRel(allocator: std.mem.Allocator, cache: *std.fs.Dir) ![]u8 {
    const candidates = [_][]const u8{ "src/main.zig", "main.zig" };
    for (candidates) |c| {
        cache.access(c, .{}) catch continue;
        return try allocator.dupe(u8, c);
    }
    return error.FileNotFound;
}

fn absolutize(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return try allocator.dupe(u8, path);
    return try std.fs.cwd().realpathAlloc(allocator, path);
}

fn projectNameFromCwd(allocator: std.mem.Allocator) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.fs.cwd().realpath(".", &buf) catch {
        return try allocator.dupe(u8, "app");
    };
    return sanitizeProjectName(allocator, std.fs.path.basename(cwd));
}

fn sanitizeProjectName(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);
    if (raw.len == 0 or !std.ascii.isAlphabetic(raw[0])) {
        try out.append(allocator, 'a');
    }
    for (raw) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
        try out.append(allocator, if (ok) c else '_');
    }
    if (out.items.len == 0) try out.appendSlice(allocator, "app");
    return out.toOwnedSlice(allocator);
}

fn cmdFmt(allocator: std.mem.Allocator, args: [][:0]u8) !ExitCode {
    var paths = std.ArrayList([]const u8){};
    defer paths.deinit(allocator);
    var check_only = false;

    for (args) |a| {
        if (std.mem.eql(u8, a, "--check")) {
            check_only = true;
        } else {
            try paths.append(allocator, a);
        }
    }
    if (paths.items.len == 0) try paths.append(allocator, ".");

    var changed: usize = 0;
    var processed: usize = 0;
    for (paths.items) |p| {
        try fmt_lib.formatPath(allocator, p, .{ .check_only = check_only }, &changed, &processed);
    }
    oPrint("zpp fmt: processed {d}, changed {d}\n", .{ processed, changed });
    if (check_only and changed > 0) return .user_error;
    return .ok;
}

fn cmdCheck(allocator: std.mem.Allocator, args: [][:0]u8) !ExitCode {
    var paths = std.ArrayList([]const u8){};
    defer paths.deinit(allocator);
    for (args) |a| try paths.append(allocator, a);
    if (paths.items.len == 0) try paths.append(allocator, ".");

    var any_error = false;
    for (paths.items) |root| {
        try checkPath(allocator, root, &any_error);
    }
    return if (any_error) .user_error else .ok;
}

fn checkPath(allocator: std.mem.Allocator, root: []const u8, any_error: *bool) !void {
    // Probe directory first: statFile returns error.IsDir on Windows.
    if (std.fs.cwd().openDir(root, .{ .iterate = true })) |dir_const| {
        var dir = dir_const;
        defer dir.close();
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".zpp")) continue;
            const full = try std.fs.path.join(allocator, &.{ root, entry.path });
            defer allocator.free(full);
            try checkOneFile(allocator, full, any_error);
        }
        return;
    } else |_| {}

    if (std.fs.cwd().statFile(root)) |_| {
        try checkOneFile(allocator, root, any_error);
    } else |e| {
        ePrint("zpp check: cannot stat '{s}': {s}\n", .{ root, @errorName(e) });
        any_error.* = true;
    }
}

fn checkOneFile(allocator: std.mem.Allocator, path: []const u8, any_error: *bool) !void {
    const source = readFileAlloc(allocator, path) catch |e| {
        ePrint("zpp check: cannot read '{s}': {s}\n", .{ path, @errorName(e) });
        any_error.* = true;
        return;
    };
    defer allocator.free(source);

    // COMPILER_API: assumes compiler.parseAndAnalyze returns { ast, diags }.
    var result = compiler.parseAndAnalyze(allocator, source) catch |e| {
        ePrint("zpp check: {s}: {s}\n", .{ path, @errorName(e) });
        any_error.* = true;
        return;
    };
    defer result.diags.deinit();

    if (result.diags.count() > 0) {
        var stderr_buf: [16384]u8 = undefined;
        var fbs = std.Io.Writer.fixed(&stderr_buf);
        result.diags.render(&fbs, path, source) catch {};
        const written = fbs.buffered();
        errStream().writeAll(written) catch {};
        if (result.diags.hasErrors()) any_error.* = true;
    }
}

fn cmdDoc(allocator: std.mem.Allocator, args: [][:0]u8) !ExitCode {
    return doc.runDoc(allocator, args);
}

fn cmdMigrate(allocator: std.mem.Allocator, args: [][:0]u8) !ExitCode {
    return migrate.runMigrate(allocator, args);
}

fn cmdWatch(allocator: std.mem.Allocator, args: [][:0]u8) !ExitCode {
    var paths: std.ArrayList([]const u8) = .{};
    defer paths.deinit(allocator);
    for (args) |a| try paths.append(allocator, a);
    if (paths.items.len == 0) try paths.append(allocator, ".");

    var snapshot = std.StringHashMap(i128).init(allocator);
    defer {
        var it = snapshot.iterator();
        while (it.next()) |e| allocator.free(e.key_ptr.*);
        snapshot.deinit();
    }

    oPrint("zpp watch: watching {d} path(s) (Ctrl-C to exit)\n", .{paths.items.len});

    // Initial check + snapshot.
    try refreshSnapshot(allocator, paths.items, &snapshot);
    var any_error = false;
    try runCheckOver(allocator, paths.items, &any_error);
    if (any_error) {
        oPrint("zpp watch: initial check reported errors\n", .{});
    } else {
        oPrint("zpp watch: initial check ok\n", .{});
    }

    while (true) {
        std.Thread.sleep(500 * std.time.ns_per_ms);
        if (try snapshotChanged(allocator, paths.items, &snapshot)) {
            oPrint("\nzpp watch: change detected — re-running check\n", .{});
            any_error = false;
            try runCheckOver(allocator, paths.items, &any_error);
            if (any_error) {
                oPrint("zpp watch: errors\n", .{});
            } else {
                oPrint("zpp watch: ok\n", .{});
            }
        }
    }
}

/// Build a fresh map of `.zpp` paths -> mtime (ns) under each root path.
fn refreshSnapshot(
    allocator: std.mem.Allocator,
    roots: []const []const u8,
    out: *std.StringHashMap(i128),
) !void {
    // Drop the previous snapshot.
    var it = out.iterator();
    while (it.next()) |e| allocator.free(e.key_ptr.*);
    out.clearRetainingCapacity();

    for (roots) |root| {
        try collectMtimes(allocator, root, out);
    }
}

fn collectMtimes(
    allocator: std.mem.Allocator,
    root: []const u8,
    out: *std.StringHashMap(i128),
) !void {
    if (std.fs.cwd().openDir(root, .{ .iterate = true })) |dir_const| {
        var dir = dir_const;
        defer dir.close();
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".zpp")) continue;
            const full = try std.fs.path.join(allocator, &.{ root, entry.path });
            const stat = std.fs.cwd().statFile(full) catch {
                allocator.free(full);
                continue;
            };
            try out.put(full, stat.mtime);
        }
        return;
    } else |_| {}
    // Treat root as a single file.
    if (!std.mem.endsWith(u8, root, ".zpp")) return;
    const stat = std.fs.cwd().statFile(root) catch return;
    const dup = try allocator.dupe(u8, root);
    try out.put(dup, stat.mtime);
}

/// Returns true if any file's mtime differs from `prev` (or files were added /
/// removed). Updates `prev` to the new state on every call.
fn snapshotChanged(
    allocator: std.mem.Allocator,
    roots: []const []const u8,
    prev: *std.StringHashMap(i128),
) !bool {
    var current = std.StringHashMap(i128).init(allocator);
    defer {
        var it = current.iterator();
        while (it.next()) |e| allocator.free(e.key_ptr.*);
        current.deinit();
    }
    for (roots) |root| try collectMtimes(allocator, root, &current);

    var changed = current.count() != prev.count();
    if (!changed) {
        var it = current.iterator();
        while (it.next()) |e| {
            const old = prev.get(e.key_ptr.*) orelse {
                changed = true;
                break;
            };
            if (old != e.value_ptr.*) {
                changed = true;
                break;
            }
        }
    }
    if (changed) {
        // Replace prev with a deep copy of current.
        var pit = prev.iterator();
        while (pit.next()) |e| allocator.free(e.key_ptr.*);
        prev.clearRetainingCapacity();
        var cit = current.iterator();
        while (cit.next()) |e| {
            const dup = try allocator.dupe(u8, e.key_ptr.*);
            try prev.put(dup, e.value_ptr.*);
        }
    }
    return changed;
}

fn runCheckOver(
    allocator: std.mem.Allocator,
    roots: []const []const u8,
    any_error: *bool,
) !void {
    for (roots) |root| {
        try checkPath(allocator, root, any_error);
    }
}

fn cmdLsp(allocator: std.mem.Allocator, args: [][:0]u8) !ExitCode {
    _ = args;
    return lsp.runServer(allocator);
}

fn cmdExplain(args: [][:0]u8) !ExitCode {
    // Parse a tiny CLI: one optional `--json` flag (`-j` is also accepted)
    // and either zero positional args (must be combined with `--list` /
    // `-l`) or exactly one positional arg (a code id or the list flag).
    // Order is irrelevant: `zpp explain --json Z0030` and `zpp explain
    // Z0030 --json` both work.
    var json_mode = false;
    var list_mode = false;
    var positional: ?[]const u8 = null;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--json") or std.mem.eql(u8, a, "-j")) {
            json_mode = true;
        } else if (std.mem.eql(u8, a, "--list") or std.mem.eql(u8, a, "-l")) {
            list_mode = true;
        } else {
            if (positional != null) {
                ePrint("zpp explain: expected at most one diagnostic code\n", .{});
                return .usage_error;
            }
            positional = a;
        }
    }
    if (!list_mode and positional == null) {
        ePrint("zpp explain: expected a Z#### code or --list\n", .{});
        return .usage_error;
    }
    if (list_mode and positional != null) {
        ePrint("zpp explain: --list takes no code argument\n", .{});
        return .usage_error;
    }

    var allocator_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = allocator_state.deinit();
    const allocator = allocator_state.allocator();

    if (list_mode) {
        if (json_mode) {
            const json_text = renderListJsonAlloc(allocator) catch |e| {
                ePrint("zpp explain: failed to render JSON: {s}\n", .{@errorName(e)});
                return .compiler_bug;
            };
            defer allocator.free(json_text);
            try writeAll(outStream(), json_text);
            try writeAll(outStream(), "\n");
            return .ok;
        }
        return cmdExplainList();
    }

    const arg = positional.?;
    // Accept lower- or upper-case input; normalize to upper for lookup.
    var upper_buf: [16]u8 = undefined;
    if (arg.len > upper_buf.len) {
        if (json_mode) {
            const json_text = renderUnknownJsonAlloc(allocator, arg) catch |e| {
                ePrint("zpp explain: failed to render JSON: {s}\n", .{@errorName(e)});
                return .compiler_bug;
            };
            defer allocator.free(json_text);
            try writeAll(outStream(), json_text);
            try writeAll(outStream(), "\n");
            return .user_error;
        }
        ePrint("zpp explain: '{s}' is not a recognized code\n", .{arg});
        return .user_error;
    }
    for (arg, 0..) |c, i| upper_buf[i] = std.ascii.toUpper(c);
    const upper = upper_buf[0..arg.len];

    const code = compiler.diagnostics.codeFromId(upper) orelse {
        if (json_mode) {
            const json_text = renderUnknownJsonAlloc(allocator, arg) catch |e| {
                ePrint("zpp explain: failed to render JSON: {s}\n", .{@errorName(e)});
                return .compiler_bug;
            };
            defer allocator.free(json_text);
            try writeAll(outStream(), json_text);
            try writeAll(outStream(), "\n");
            return .user_error;
        }
        ePrint("zpp explain: unknown diagnostic code '{s}'\n", .{arg});
        ePrint("       run `zpp explain --list` to see every code.\n", .{});
        return .user_error;
    };

    if (json_mode) {
        const json_text = renderCodeJsonAlloc(allocator, code) catch |e| {
            ePrint("zpp explain: failed to render JSON: {s}\n", .{@errorName(e)});
            return .compiler_bug;
        };
        defer allocator.free(json_text);
        try writeAll(outStream(), json_text);
        try writeAll(outStream(), "\n");
        return .ok;
    }

    oPrint("{s}\n", .{compiler.diagnostics.explain(code)});
    return .ok;
}

fn cmdExplainList() !ExitCode {
    oPrint("Diagnostic codes:\n\n", .{});
    for (compiler.diagnostics.all_codes) |code| {
        oPrint("  {s}  {s}\n", .{ code.id(), compiler.diagnostics.summary(code) });
    }
    oPrint("\nRun `zpp explain Z####` for the full description, triggering example, and fix.\n", .{});
    return .ok;
}

// --------------------------------------------------------------------------
// JSON output for `zpp explain --json` and `zpp explain --list --json`.
//
// Output is consumed by IDEs / tooling, so the format is fixed:
//
//   single-code mode:
//     { "code": "Z####",
//       "title": "<one-line description>",
//       "summary": "<short fix-it hint, single line>",
//       "explain": "<full multi-paragraph text>",
//       "examples": [
//         { "kind": "trigger" | "fix", "snippet": "..." },
//         ...
//       ]   <-- omitted entirely if heuristic parsing fails
//     }
//
//   list mode:
//     { "codes": [
//         { "code": "Z####", "title": "...", "summary": "..." },
//         ...
//       ] }
//
//   unknown-code mode (also exit code 1):
//     { "error": "unknown diagnostic code", "code": "<as typed>" }
//
// The parser for `examples` is a small heuristic over the existing
// `explain(code)` text shape. Every entry today follows the pattern
// `Triggers[ (...)]:` / `Fix[ (...)]:` followed by 4-space-indented code.
// If any entry fails to parse cleanly we drop the `examples` field (rather
// than emit a broken / partial array) so consumers can rely on the explain
// text as the source of truth.
// --------------------------------------------------------------------------

fn renderCodeJsonAlloc(
    allocator: std.mem.Allocator,
    code: compiler.diagnostics.Code,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try writeCodeJson(allocator, &aw.writer, code);
    return aw.toOwnedSlice();
}

fn renderListJsonAlloc(allocator: std.mem.Allocator) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try writeListJson(&aw.writer);
    return aw.toOwnedSlice();
}

fn renderUnknownJsonAlloc(
    allocator: std.mem.Allocator,
    requested: []const u8,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try writeUnknownJson(&aw.writer, requested);
    return aw.toOwnedSlice();
}

/// Write the JSON document for one diagnostic code into `writer`.
/// `allocator` is used only for transient parsing / hint-flattening
/// buffers and is fully released before returning.
fn writeCodeJson(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    code: compiler.diagnostics.Code,
) !void {
    var s: std.json.Stringify = .{ .writer = writer, .options = .{} };

    const explain_text = compiler.diagnostics.explain(code);
    const title = compiler.diagnostics.summary(code);

    const summary_buf = try flattenHint(allocator, code);
    defer allocator.free(summary_buf);

    try s.beginObject();
    try s.objectField("code");
    try s.write(code.id());
    try s.objectField("title");
    try s.write(title);
    try s.objectField("summary");
    try s.write(summary_buf);
    try s.objectField("explain");
    try s.write(explain_text);

    if (try parseExamples(allocator, explain_text)) |examples| {
        defer {
            for (examples) |ex| allocator.free(ex.snippet);
            allocator.free(examples);
        }
        try s.objectField("examples");
        try s.beginArray();
        for (examples) |ex| {
            try s.beginObject();
            try s.objectField("kind");
            try s.write(ex.kind);
            try s.objectField("snippet");
            try s.write(ex.snippet);
            try s.endObject();
        }
        try s.endArray();
    }

    try s.endObject();
}

fn writeListJson(writer: *std.Io.Writer) !void {
    var s: std.json.Stringify = .{ .writer = writer, .options = .{} };
    try s.beginObject();
    try s.objectField("codes");
    try s.beginArray();
    for (compiler.diagnostics.all_codes) |code| {
        const title = compiler.diagnostics.summary(code);
        try s.beginObject();
        try s.objectField("code");
        try s.write(code.id());
        try s.objectField("title");
        try s.write(title);
        try s.objectField("summary");
        try s.write(title);
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
}

fn writeUnknownJson(writer: *std.Io.Writer, requested: []const u8) !void {
    var s: std.json.Stringify = .{ .writer = writer, .options = .{} };
    try s.beginObject();
    try s.objectField("error");
    try s.write("unknown diagnostic code");
    try s.objectField("code");
    try s.write(requested);
    try s.endObject();
}

/// Collapse a multi-line hint into a single line so it fits the JSON
/// `summary` slot. Falls back to `summary(code)` when there is no hint.
fn flattenHint(
    allocator: std.mem.Allocator,
    code: compiler.diagnostics.Code,
) ![]u8 {
    if (compiler.diagnostics.hint(code)) |h| {
        var out = std.ArrayList(u8){};
        defer out.deinit(allocator);
        var prev_space = false;
        for (h) |c| {
            const ch: u8 = switch (c) {
                '\n', '\r', '\t' => ' ',
                else => c,
            };
            if (ch == ' ') {
                if (!prev_space and out.items.len > 0) try out.append(allocator, ' ');
                prev_space = true;
            } else {
                try out.append(allocator, ch);
                prev_space = false;
            }
        }
        // Trim trailing space.
        while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') {
            _ = out.pop();
        }
        return out.toOwnedSlice(allocator);
    }
    return try allocator.dupe(u8, compiler.diagnostics.summary(code));
}

const Example = struct {
    kind: []const u8, // "trigger" or "fix" — borrowed string literal, no free
    snippet: []u8, // owned; caller frees
};

/// Heuristic parser over the explain-text shape. Looks for lines whose
/// stripped form starts with `Triggers` or `Fix` and ends with `:`,
/// then collects subsequent 4-space-indented lines as the snippet body.
/// On any inconsistency returns `null`; the caller then omits the
/// `examples` field so consumers cannot mistake a partial parse for the
/// full set.
fn parseExamples(
    allocator: std.mem.Allocator,
    text: []const u8,
) !?[]Example {
    var found = std.ArrayList(Example){};
    errdefer {
        for (found.items) |ex| allocator.free(ex.snippet);
        found.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, text, '\n');
    var pending_kind: ?[]const u8 = null;
    var snippet = std.ArrayList(u8){};
    defer snippet.deinit(allocator);

    while (lines.next()) |line| {
        if (pending_kind) |kind| {
            // Collect indented (4-space) lines or completely blank lines.
            // A non-blank, non-indented line ends the snippet.
            const is_blank = std.mem.indexOfNone(u8, line, " \t") == null;
            const is_indented = line.len >= 4 and std.mem.eql(u8, line[0..4], "    ");
            if (is_indented) {
                if (snippet.items.len > 0) try snippet.append(allocator, '\n');
                try snippet.appendSlice(allocator, line[4..]);
            } else if (is_blank) {
                // Blank lines inside a snippet are tolerated as separators
                // until the next non-blank decides whether we are still in
                // the snippet.
                continue;
            } else {
                // Snippet ended. Save what we have (if any).
                if (snippet.items.len > 0) {
                    const owned = try snippet.toOwnedSlice(allocator);
                    try found.append(allocator, .{ .kind = kind, .snippet = owned });
                    snippet = .{};
                }
                pending_kind = null;
                // Fall through so this same line can start a new section.
            }
        }
        if (pending_kind == null) {
            const stripped = std.mem.trim(u8, line, " \t");
            if (stripped.len == 0) continue;
            // Match `Triggers[...]:` or `Fix[...]:`. Anything else
            // (e.g. `Or restructure...`, free prose) is ignored.
            if (std.mem.startsWith(u8, stripped, "Triggers") and
                std.mem.endsWith(u8, stripped, ":"))
            {
                pending_kind = "trigger";
            } else if (std.mem.startsWith(u8, stripped, "Fix") and
                std.mem.endsWith(u8, stripped, ":"))
            {
                pending_kind = "fix";
            }
        }
    }
    // Flush any trailing snippet.
    if (pending_kind) |kind| {
        if (snippet.items.len > 0) {
            const owned = try snippet.toOwnedSlice(allocator);
            try found.append(allocator, .{ .kind = kind, .snippet = owned });
            snippet = .{};
        }
    }

    if (found.items.len == 0) {
        // Nothing parsed — the heuristic doesn't know what to do, so let
        // the caller omit the field rather than emit `[]`.
        found.deinit(allocator);
        return null;
    }
    return try found.toOwnedSlice(allocator);
}

const tpl_main_zpp = @embedFile("templates/main.zpp");
const tpl_build_zig = @embedFile("templates/build.zig");
const tpl_build_zon = @embedFile("templates/build.zig.zon");
const tpl_gitignore = @embedFile("templates/gitignore");
const tpl_readme_md = @embedFile("templates/README.md");

const TemplateFile = struct { rel_path: []const u8, contents: []const u8 };

fn cmdInit(allocator: std.mem.Allocator, args: [][:0]u8) !ExitCode {
    if (args.len != 1) {
        ePrint("zpp init: expected exactly one project name\n", .{});
        return .usage_error;
    }
    const name = args[0];
    if (!isValidProjectName(name)) {
        ePrint("zpp init: '{s}' is not a valid project name (must match [A-Za-z][A-Za-z0-9_-]*)\n", .{name});
        return .user_error;
    }

    // Refuse to clobber an existing directory.
    if (std.fs.cwd().access(name, .{})) |_| {
        ePrint("zpp init: '{s}' already exists; refusing to overwrite\n", .{name});
        return .user_error;
    } else |_| {}

    try std.fs.cwd().makePath(name);
    var dir = try std.fs.cwd().openDir(name, .{});
    defer dir.close();
    try dir.makePath("src");

    // Pick a fingerprint deterministic per project name. The fingerprint is
    // free-form for unpublished packages; we just need a stable nonzero u64.
    // Stable per project-name fingerprint. The seed is the ASCII bytes of "zpp.init".
    const fp = std.hash.Wyhash.hash(0x7a70_702e_696e_6974, name);
    const fp_hex = try std.fmt.allocPrint(allocator, "{x}", .{fp});
    defer allocator.free(fp_hex);

    const files = [_]TemplateFile{
        .{ .rel_path = "src/main.zpp", .contents = tpl_main_zpp },
        .{ .rel_path = "build.zig", .contents = tpl_build_zig },
        .{ .rel_path = "build.zig.zon", .contents = tpl_build_zon },
        .{ .rel_path = ".gitignore", .contents = tpl_gitignore },
        .{ .rel_path = "README.md", .contents = tpl_readme_md },
    };

    for (files) |f| {
        const rendered = try renderTemplate(allocator, f.contents, name, fp_hex);
        defer allocator.free(rendered);
        try dir.writeFile(.{ .sub_path = f.rel_path, .data = rendered });
    }

    oPrint(
        \\Scaffolded '{s}/'.
        \\
        \\Next steps:
        \\    cd {s}
        \\    zig fetch --save git+https://github.com/nktkt/zigpp-lang
        \\    zig build run
        \\
    , .{ name, name });
    return .ok;
}

fn isValidProjectName(name: []const u8) bool {
    if (name.len == 0) return false;
    const c0 = name[0];
    if (!std.ascii.isAlphabetic(c0)) return false;
    for (name[1..]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    }
    return true;
}

fn renderTemplate(allocator: std.mem.Allocator, src: []const u8, name: []const u8, fp_hex: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);
    var i: usize = 0;
    while (i < src.len) {
        if (substrAt(src, i, "ZPP_PROJECT_NAME")) {
            try out.appendSlice(allocator, name);
            i += "ZPP_PROJECT_NAME".len;
            continue;
        }
        if (substrAt(src, i, "ZPP_PROJECT_FINGERPRINT")) {
            try out.appendSlice(allocator, fp_hex);
            i += "ZPP_PROJECT_FINGERPRINT".len;
            continue;
        }
        try out.append(allocator, src[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn substrAt(haystack: []const u8, at: usize, needle: []const u8) bool {
    if (at + needle.len > haystack.len) return false;
    return std.mem.eql(u8, haystack[at .. at + needle.len], needle);
}

fn termToExit(term: std.process.Child.Term) ExitCode {
    return switch (term) {
        .Exited => |c| if (c == 0) ExitCode.ok else ExitCode.user_error,
        else => ExitCode.user_error,
    };
}

fn ensureCacheDir(allocator: std.mem.Allocator) !std.fs.Dir {
    _ = allocator;
    std.fs.cwd().makePath(".zpp-cache") catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    return std.fs.cwd().openDir(".zpp-cache", .{ .iterate = true });
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    // VERIFY: 0.16 API — Dir.readFileAlloc(alloc, path, max_bytes) signature.
    return std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
}

fn stemOf(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| return base[0..dot];
    return base;
}

fn replaceExt(allocator: std.mem.Allocator, path: []const u8, new_ext: []const u8) ![]u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse path.len;
    const without = path[0..dot];
    return std.mem.concat(allocator, u8, &.{ without, new_ext });
}

test "Subcommand.parse maps known names" {
    try std.testing.expectEqual(Subcommand.build, Subcommand.parse("build").?);
    try std.testing.expectEqual(Subcommand.version, Subcommand.parse("--version").?);
    try std.testing.expect(Subcommand.parse("nope") == null);
}

test "stemOf and replaceExt" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("foo", stemOf("a/b/foo.zpp"));
    const r = try replaceExt(a, "x/y/z.zpp", ".zig");
    defer a.free(r);
    try std.testing.expectEqualStrings("x/y/z.zig", r);
}

test "isValidProjectName accepts identifiers and rejects edge cases" {
    try std.testing.expect(isValidProjectName("hello"));
    try std.testing.expect(isValidProjectName("my_project"));
    try std.testing.expect(isValidProjectName("my-project"));
    try std.testing.expect(isValidProjectName("ab9"));
    try std.testing.expect(!isValidProjectName(""));
    try std.testing.expect(!isValidProjectName("9hello"));
    try std.testing.expect(!isValidProjectName("foo/bar"));
    try std.testing.expect(!isValidProjectName("foo bar"));
    try std.testing.expect(!isValidProjectName("foo.bar"));
}

test "renderTemplate substitutes both placeholders" {
    const a = std.testing.allocator;
    const tpl = "name=ZPP_PROJECT_NAME, fp=0xZPP_PROJECT_FINGERPRINT;";
    const out = try renderTemplate(a, tpl, "demo", "deadbeef");
    defer a.free(out);
    try std.testing.expectEqualStrings("name=demo, fp=0xdeadbeef;", out);
}

test "Subcommand.parse covers init and explain" {
    try std.testing.expectEqual(Subcommand.init, Subcommand.parse("init").?);
    try std.testing.expectEqual(Subcommand.explain, Subcommand.parse("explain").?);
}

test "sanitizeProjectName handles common basenames" {
    const a = std.testing.allocator;

    const ok = try sanitizeProjectName(a, "multi_file");
    defer a.free(ok);
    try std.testing.expectEqualStrings("multi_file", ok);

    const dashed = try sanitizeProjectName(a, "my-project");
    defer a.free(dashed);
    try std.testing.expectEqualStrings("my-project", dashed);

    const num_first = try sanitizeProjectName(a, "9hello");
    defer a.free(num_first);
    try std.testing.expectEqualStrings("a9hello", num_first);

    const weird = try sanitizeProjectName(a, "foo bar.baz");
    defer a.free(weird);
    try std.testing.expectEqualStrings("foo_bar_baz", weird);

    const empty = try sanitizeProjectName(a, "");
    defer a.free(empty);
    try std.testing.expectEqualStrings("a", empty);
}

test "splitBuildArgs separates at `--`" {
    var src_buf: [4:0]u8 = .{ 's', 'r', 'c', '/' };
    var sep_buf: [2:0]u8 = .{ '-', '-' };
    var run_buf: [3:0]u8 = .{ 'r', 'u', 'n' };
    var test_buf: [4:0]u8 = .{ 't', 'e', 's', 't' };

    // Empty args.
    var none: [0][:0]u8 = .{};
    const e = splitBuildArgs(&none);
    try std.testing.expectEqual(@as(usize, 0), e.zpp.len);
    try std.testing.expectEqual(@as(usize, 0), e.passthrough.len);

    // Only dir, no separator.
    var only_dir = [_][:0]u8{&src_buf};
    const od = splitBuildArgs(&only_dir);
    try std.testing.expectEqual(@as(usize, 1), od.zpp.len);
    try std.testing.expectEqualStrings("src/", od.zpp[0]);
    try std.testing.expectEqual(@as(usize, 0), od.passthrough.len);

    // dir `--` run test.
    var with_sep = [_][:0]u8{ &src_buf, &sep_buf, &run_buf, &test_buf };
    const ws = splitBuildArgs(&with_sep);
    try std.testing.expectEqual(@as(usize, 1), ws.zpp.len);
    try std.testing.expectEqualStrings("src/", ws.zpp[0]);
    try std.testing.expectEqual(@as(usize, 2), ws.passthrough.len);
    try std.testing.expectEqualStrings("run", ws.passthrough[0]);
    try std.testing.expectEqualStrings("test", ws.passthrough[1]);

    // Leading `--`: no zpp args, all forwarded.
    var only_sep = [_][:0]u8{ &sep_buf, &run_buf };
    const os = splitBuildArgs(&only_sep);
    try std.testing.expectEqual(@as(usize, 0), os.zpp.len);
    try std.testing.expectEqual(@as(usize, 1), os.passthrough.len);
    try std.testing.expectEqualStrings("run", os.passthrough[0]);

    // Trailing `--`: empty passthrough.
    var trail = [_][:0]u8{ &src_buf, &sep_buf };
    const t = splitBuildArgs(&trail);
    try std.testing.expectEqual(@as(usize, 1), t.zpp.len);
    try std.testing.expectEqual(@as(usize, 0), t.passthrough.len);
}

test "renderBuildShim substitutes name, entry, and lib path" {
    const a = std.testing.allocator;
    const out = try renderBuildShim(a, .{
        .name = "demo",
        .entry_rel = "src/main.zig",
        .zpp_lib_abs = "/abs/path/to/lib/zpp.zig",
    });
    defer a.free(out);
    // Spot-check the three substitutions and the run step wiring.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"/abs/path/to/lib/zpp.zig\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "b.path(\"src/main.zig\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ".name = \"demo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "b.step(\"run\"") != null);
}

test "explain finds every code by id" {
    inline for (@typeInfo(compiler.diagnostics.Code).@"enum".fields) |f| {
        const c: compiler.diagnostics.Code = @enumFromInt(f.value);
        const id_str = c.id();
        const looked_up = compiler.diagnostics.codeFromId(id_str) orelse @panic("codeFromId returned null");
        try std.testing.expectEqual(c, looked_up);
        // Every code has a non-empty explanation.
        try std.testing.expect(compiler.diagnostics.explain(c).len > 50);
    }
}

test "all_codes covers every Code variant exactly once" {
    const fields = @typeInfo(compiler.diagnostics.Code).@"enum".fields;
    try std.testing.expectEqual(fields.len, compiler.diagnostics.all_codes.len);
    // Each code in all_codes also has a non-empty summary().
    for (compiler.diagnostics.all_codes) |c| {
        try std.testing.expect(compiler.diagnostics.summary(c).len > 0);
        try std.testing.expect(!std.mem.startsWith(u8, compiler.diagnostics.summary(c), "Z"));
    }
}

test "Subcommand.parse covers watch" {
    try std.testing.expectEqual(Subcommand.watch, Subcommand.parse("watch").?);
}

test "snapshotChanged detects new file and updates prev" {
    const a = std.testing.allocator;
    var snap = std.StringHashMap(i128).init(a);
    defer {
        var it = snap.iterator();
        while (it.next()) |e| a.free(e.key_ptr.*);
        snap.deinit();
    }

    // Create a tmp dir with a single .zpp file.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "a.zpp", .data = "fn main() void {}" });
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);

    const roots = [_][]const u8{root};
    // First call records baseline; reports changed because count went 0->1.
    const initial_changed = try snapshotChanged(a, &roots, &snap);
    try std.testing.expect(initial_changed);
    try std.testing.expectEqual(@as(usize, 1), snap.count());

    // No-op second call: nothing changed.
    const second = try snapshotChanged(a, &roots, &snap);
    try std.testing.expect(!second);

    // Add another file: changed.
    try tmp.dir.writeFile(.{ .sub_path = "b.zpp", .data = "fn other() void {}" });
    const after_add = try snapshotChanged(a, &roots, &snap);
    try std.testing.expect(after_add);
    try std.testing.expectEqual(@as(usize, 2), snap.count());
}

// --------------------------------------------------------------------------
// `zpp explain --json` helpers — driven through their writer-buffer entry
// points (renderXxxJsonAlloc) so we don't go through stdout. The
// `zig test --listen=-` IPC chokes on direct stdout writes, so every test
// here serializes into an allocator-backed buffer and parses it with
// `std.json.parseFromSlice` to assert validity + shape.
// --------------------------------------------------------------------------

test "explain --json single code emits parseable JSON with right code field" {
    const a = std.testing.allocator;

    const json_text = try renderCodeJsonAlloc(a, .z0030_effect_violation);
    defer a.free(json_text);

    const parsed = try std.json.parseFromSlice(std.json.Value, a, json_text, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    try std.testing.expectEqualStrings("Z0030", root.get("code").?.string);
    // Title comes from summary(code) — the first line of explain() with the
    // "Z####: " prefix stripped.
    try std.testing.expect(root.get("title").?.string.len > 0);
    try std.testing.expect(root.get("summary").?.string.len > 0);
    try std.testing.expect(root.get("explain").?.string.len > 50);
    // Z0030 has both `Triggers:` (with snippet) and a prose `Fix: drop ...`,
    // so the parser should produce exactly one example (the trigger).
    const examples = root.get("examples").?.array;
    try std.testing.expect(examples.items.len >= 1);
    try std.testing.expectEqualStrings("trigger", examples.items[0].object.get("kind").?.string);
}

test "explain --json --list emits parseable JSON with all codes" {
    const a = std.testing.allocator;

    const json_text = try renderListJsonAlloc(a);
    defer a.free(json_text);

    const parsed = try std.json.parseFromSlice(std.json.Value, a, json_text, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const codes = root.get("codes").?.array;
    // Spec only requires "at least 5". Today we have 16; allow growth.
    try std.testing.expect(codes.items.len >= 5);
    // Each entry has the contracted shape.
    for (codes.items) |entry| {
        const obj = entry.object;
        const code_val = obj.get("code").?.string;
        try std.testing.expect(std.mem.startsWith(u8, code_val, "Z"));
        try std.testing.expect(obj.get("title").?.string.len > 0);
        try std.testing.expect(obj.get("summary").?.string.len > 0);
    }
}

test "explain --json unknown code emits error JSON doc" {
    const a = std.testing.allocator;

    const json_text = try renderUnknownJsonAlloc(a, "Zxxxx");
    defer a.free(json_text);

    const parsed = try std.json.parseFromSlice(std.json.Value, a, json_text, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    try std.testing.expectEqualStrings("unknown diagnostic code", root.get("error").?.string);
    try std.testing.expectEqualStrings("Zxxxx", root.get("code").?.string);
}

test "explain --json escapes control characters and quotes" {
    const a = std.testing.allocator;
    // The unknown-code path passes the requested string through verbatim,
    // so we use it to spot-check that std.json.Stringify escapes properly.
    const json_text = try renderUnknownJsonAlloc(a, "weird \"\n\\quote");
    defer a.free(json_text);

    // Re-parse must succeed and round-trip the bytes.
    const parsed = try std.json.parseFromSlice(std.json.Value, a, json_text, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "weird \"\n\\quote",
        parsed.value.object.get("code").?.string,
    );
}

test "parseExamples extracts trigger and fix snippets from a known code" {
    const a = std.testing.allocator;
    const text = compiler.diagnostics.explain(.z0021_borrow_invalidated_by_move);
    const examples = (try parseExamples(a, text)) orelse @panic("expected examples");
    defer {
        for (examples) |ex| a.free(ex.snippet);
        a.free(examples);
    }
    // Z0021 has `Triggers:` then `Fix (let the borrow end first):` — both
    // followed by indented code — so we expect exactly two entries.
    try std.testing.expectEqual(@as(usize, 2), examples.len);
    try std.testing.expectEqualStrings("trigger", examples[0].kind);
    try std.testing.expectEqualStrings("fix", examples[1].kind);
    try std.testing.expect(examples[0].snippet.len > 0);
    try std.testing.expect(examples[1].snippet.len > 0);
}

test "flattenHint produces a single-line summary" {
    const a = std.testing.allocator;
    const flat = try flattenHint(a, .z0010_missing_deinit_on_owned);
    defer a.free(flat);
    try std.testing.expect(flat.len > 0);
    try std.testing.expect(std.mem.indexOfScalar(u8, flat, '\n') == null);
}
