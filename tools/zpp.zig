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
    doc,
    migrate,
    lsp,
    version,
    help,

    fn parse(name: []const u8) ?Subcommand {
        const map = .{
            .{ "build", .build },
            .{ "run", .run },
            .{ "lower", .lower },
            .{ "fmt", .fmt },
            .{ "check", .check },
            .{ "doc", .doc },
            .{ "migrate", .migrate },
            .{ "lsp", .lsp },
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
        .doc => cmdDoc(allocator, rest),
        .migrate => cmdMigrate(allocator, rest),
        .lsp => cmdLsp(allocator, rest),
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
        \\    doc [paths...]       generate markdown docs from .zpp doc comments
        \\    migrate <file.zig>   suggest .zpp rewrites for a .zig file
        \\    lsp                  start LSP server on stdin/stdout
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
        .doc => "zpp doc [paths...]\n  Walk .zpp files and emit Markdown for trait/fn/struct/extern interface decls.\n",
        .migrate => "zpp migrate <file.zig>\n  Diff suggestions to convert defer/init/deinit patterns to Zig++.\n",
        .lsp => "zpp lsp\n  Speak LSP over stdio. Run from your editor; not for human use.\n",
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

/// Find `lib/zpp.zig`. First try the project-relative path (works during
/// development from the repo root), then fall back to a path relative to the
/// `zpp` executable for installed binaries.
fn locateZppLib(allocator: std.mem.Allocator) ![]const u8 {
    const candidates = [_][]const u8{
        "lib/zpp.zig",
        "../lib/zpp.zig",
    };
    for (candidates) |c| {
        std.fs.cwd().access(c, .{}) catch continue;
        return try allocator.dupe(u8, c);
    }
    // Try alongside the executable.
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

fn cmdBuild(allocator: std.mem.Allocator, args: [][:0]u8) !ExitCode {
    const root: []const u8 = if (args.len == 0) "." else args[0];

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

    var child = std.process.Child.init(&.{ "zig", "build" }, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = child.spawnAndWait() catch |e| {
        ePrint("zpp build: failed to invoke `zig build`: {s}\n", .{@errorName(e)});
        return .user_error;
    };
    return termToExit(term);
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

fn cmdLsp(allocator: std.mem.Allocator, args: [][:0]u8) !ExitCode {
    _ = args;
    return lsp.runServer(allocator);
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
