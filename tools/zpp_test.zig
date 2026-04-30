//! `zpp test` — lower every `.zpp` under the given paths into
//! `.zpp-cache/<rel>.zig` and run `zig test` against each lowered file.
//!
//! Each .zpp file is invoked as its own `zig test` process so all `test "..."`
//! blocks declared in that file run. The runtime library (`lib/zpp.zig`) is
//! wired in as a module dependency exactly like `zpp run` does, so lowered
//! `@import("zpp")` resolves.
//!
//! Stdout/stderr are inherited from the child so users see the standard
//! `zig test` output verbatim. Exit code is 0 when every file passes; if any
//! file fails the command exits with `.user_error` (1).
//!
//! IMPORTANT: do NOT attempt to drive `cmdTest` itself from a unit test — the
//! child `zig test --listen=-` IPC channel will collide with the test runner's
//! stdout and stall (we hit this exact bug previously in `tools/zpp_doc.zig`).
//! Cover the helpers below instead.

const std = @import("std");
const compiler = @import("zpp_compiler");
const zpp_main = @import("zpp.zig");

const ExitCode = zpp_main.ExitCode;

const Options = struct {
    paths: std.ArrayList([]const u8) = .{},
    filter: ?[]const u8 = null,
    release: bool = false,
    verbose: bool = false,

    fn deinit(self: *Options, allocator: std.mem.Allocator) void {
        self.paths.deinit(allocator);
    }
};

pub fn runTest(allocator: std.mem.Allocator, args: [][:0]u8) !ExitCode {
    var opts = Options{};
    defer opts.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            printHelp();
            return .ok;
        } else if (std.mem.eql(u8, a, "--filter")) {
            i += 1;
            if (i >= args.len) {
                ePrint("zpp test: --filter requires a pattern\n", .{});
                return .usage_error;
            }
            opts.filter = args[i];
        } else if (std.mem.startsWith(u8, a, "--filter=")) {
            opts.filter = a["--filter=".len..];
        } else if (std.mem.eql(u8, a, "--release")) {
            opts.release = true;
        } else if (std.mem.eql(u8, a, "-v") or std.mem.eql(u8, a, "--verbose")) {
            opts.verbose = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            ePrint("zpp test: unknown flag '{s}'\n", .{a});
            return .usage_error;
        } else {
            try opts.paths.append(allocator, a);
        }
    }
    if (opts.paths.items.len == 0) try opts.paths.append(allocator, ".");

    // Step 1: collect every .zpp file under the requested roots.
    var sources: std.ArrayList([]u8) = .{};
    defer {
        for (sources.items) |s| allocator.free(s);
        sources.deinit(allocator);
    }
    for (opts.paths.items) |root| {
        try collectZppFiles(allocator, root, &sources);
    }

    if (sources.items.len == 0) {
        oPrint("zpp test: no .zpp files found under given paths\n", .{});
        return .ok;
    }

    // Step 2: lower every file into .zpp-cache/<rel>.zig.
    var cache = try ensureCacheDir();
    defer cache.close();

    var lowered_paths: std.ArrayList([]u8) = .{};
    defer {
        for (lowered_paths.items) |p| allocator.free(p);
        lowered_paths.deinit(allocator);
    }

    var lower_errors: usize = 0;
    for (sources.items) |src_path| {
        const lowered_rel = lowerOne(allocator, &cache, src_path) catch |e| {
            ePrint("zpp test: {s}: lowering failed: {s}\n", .{ src_path, @errorName(e) });
            lower_errors += 1;
            continue;
        };
        try lowered_paths.append(allocator, lowered_rel);
    }
    if (lower_errors > 0) {
        ePrint("zpp test: {d} file(s) failed to lower\n", .{lower_errors});
        return .user_error;
    }

    // Step 3: run `zig test` on each lowered file.
    const zpp_lib = locateZppLib(allocator) catch |e| {
        ePrint("zpp test: could not locate the zpp runtime (lib/zpp.zig): {s}\n", .{@errorName(e)});
        return .user_error;
    };
    defer allocator.free(zpp_lib);

    var passed: usize = 0;
    var failed: usize = 0;
    for (lowered_paths.items, 0..) |zig_rel, idx| {
        const src_path = sources.items[idx];
        if (opts.verbose) {
            oPrint("zpp test: running {s}\n", .{src_path});
        }
        const cache_full = try std.fs.path.join(allocator, &.{ ".zpp-cache", zig_rel });
        defer allocator.free(cache_full);

        const code = try invokeZigTest(allocator, cache_full, zpp_lib, opts);
        if (code == 0) passed += 1 else failed += 1;
    }

    oPrint("zpp test: {d} file(s) passed, {d} failed\n", .{ passed, failed });
    if (failed > 0) return .user_error;
    return .ok;
}

fn printHelp() void {
    const usage =
        \\zpp test [paths...] [flags]
        \\
        \\  Lower every .zpp under <paths> (default '.') into .zpp-cache/<rel>.zig and
        \\  run `zig test` against each lowered file. Exits 0 when every file passes.
        \\
        \\FLAGS:
        \\    --filter <pattern>   forward to `zig test --test-filter` (run a subset)
        \\    --release            build with --release=safe
        \\    -v, --verbose        print each file as it is tested
        \\    -h, --help           show this message
        \\
    ;
    oPrint("{s}", .{usage});
}

/// Walk `root` (file or directory) and append every `.zpp` path we find. Each
/// returned slice is freshly allocated and owned by `out`.
fn collectZppFiles(
    allocator: std.mem.Allocator,
    root: []const u8,
    out: *std.ArrayList([]u8),
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
            try out.append(allocator, full);
        }
        return;
    } else |_| {}

    // Treat `root` as a single file.
    if (!std.mem.endsWith(u8, root, ".zpp")) {
        ePrint("zpp test: '{s}' is not a directory or .zpp file\n", .{root});
        return;
    }
    const dup = try allocator.dupe(u8, root);
    try out.append(allocator, dup);
}

/// Lower one .zpp file and write the lowered .zig under `.zpp-cache/`,
/// mirroring its directory layout. Returns the cache-relative .zig path
/// (e.g. `src/main.zig` for input `src/main.zpp`).
fn lowerOne(
    allocator: std.mem.Allocator,
    cache: *std.fs.Dir,
    src_path: []const u8,
) ![]u8 {
    const source = try std.fs.cwd().readFileAlloc(allocator, src_path, 16 * 1024 * 1024);
    defer allocator.free(source);

    const lowered = try compiler.compileToString(allocator, source);
    defer allocator.free(lowered);

    const rel = try mirrorPathToZig(allocator, src_path);
    errdefer allocator.free(rel);

    if (std.fs.path.dirname(rel)) |sub| {
        try cache.makePath(sub);
    }
    try cache.writeFile(.{ .sub_path = rel, .data = lowered });
    return rel;
}

/// Map an input `.zpp` source path to the relative path inside `.zpp-cache/`
/// where its lowered `.zig` should live. Strips a single leading "./" and
/// any leading "../" segments so the cache layout always nests below the
/// cache directory and never escapes it.
pub fn mirrorPathToZig(allocator: std.mem.Allocator, src_path: []const u8) ![]u8 {
    var trimmed = src_path;
    // Strip leading ./ and ../ so the mirrored path stays inside .zpp-cache/.
    while (true) {
        if (std.mem.startsWith(u8, trimmed, "./")) {
            trimmed = trimmed[2..];
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "../")) {
            trimmed = trimmed[3..];
            continue;
        }
        break;
    }
    // Absolute paths: drop the leading slash so they become relative.
    if (trimmed.len > 0 and trimmed[0] == '/') trimmed = trimmed[1..];

    const dot = std.mem.lastIndexOfScalar(u8, trimmed, '.') orelse trimmed.len;
    return std.mem.concat(allocator, u8, &.{ trimmed[0..dot], ".zig" });
}

fn invokeZigTest(
    allocator: std.mem.Allocator,
    zig_path: []const u8,
    zpp_lib: []const u8,
    opts: Options,
) !u8 {
    const dep_arg = try std.fmt.allocPrint(allocator, "-Mzpp={s}", .{zpp_lib});
    defer allocator.free(dep_arg);
    const root_arg = try std.fmt.allocPrint(allocator, "-Mroot={s}", .{zig_path});
    defer allocator.free(root_arg);

    var argv: std.ArrayList([]const u8) = .{};
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "zig", "test", "--dep", "zpp", root_arg, dep_arg });
    if (opts.filter) |f| {
        try argv.appendSlice(allocator, &.{ "--test-filter", f });
    }
    if (opts.release) {
        try argv.append(allocator, "--release=safe");
    }

    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = child.spawnAndWait() catch |e| {
        ePrint("zpp test: failed to invoke `zig test`: {s}\n", .{@errorName(e)});
        return 1;
    };
    return switch (term) {
        .Exited => |c| c,
        else => 1,
    };
}

fn ensureCacheDir() !std.fs.Dir {
    std.fs.cwd().makePath(".zpp-cache") catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    return std.fs.cwd().openDir(".zpp-cache", .{ .iterate = true });
}

/// Same resolution strategy as `zpp run`: env override, cwd-relative,
/// upward search, then sibling of the executable.
fn locateZppLib(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "ZPP_LIB")) |envp| {
        return envp;
    } else |_| {}

    const candidates = [_][]const u8{ "lib/zpp.zig", "../lib/zpp.zig" };
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

fn ePrint(comptime fmt_str: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, fmt_str, args) catch return;
    std.fs.File.stderr().writeAll(slice) catch {};
}

fn oPrint(comptime fmt_str: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, fmt_str, args) catch return;
    std.fs.File.stdout().writeAll(slice) catch {};
}

// -----------------------------------------------------------------------------
// Tests — exercise helpers only. NEVER drive runTest from here: writing to
// stdout while `zig test --listen=-` runs corrupts its IPC channel and stalls
// the entire test runner. We learned this the hard way in tools/zpp_doc.zig.
// -----------------------------------------------------------------------------

test "mirrorPathToZig swaps extension and preserves layout" {
    const a = std.testing.allocator;

    {
        const out = try mirrorPathToZig(a, "src/main.zpp");
        defer a.free(out);
        try std.testing.expectEqualStrings("src/main.zig", out);
    }
    {
        const out = try mirrorPathToZig(a, "main.zpp");
        defer a.free(out);
        try std.testing.expectEqualStrings("main.zig", out);
    }
    {
        const out = try mirrorPathToZig(a, "deep/nested/dir/file.zpp");
        defer a.free(out);
        try std.testing.expectEqualStrings("deep/nested/dir/file.zig", out);
    }
}

test "mirrorPathToZig strips ./, ../, and absolute leading slash" {
    const a = std.testing.allocator;
    {
        const out = try mirrorPathToZig(a, "./src/x.zpp");
        defer a.free(out);
        try std.testing.expectEqualStrings("src/x.zig", out);
    }
    {
        const out = try mirrorPathToZig(a, "../sibling/x.zpp");
        defer a.free(out);
        try std.testing.expectEqualStrings("sibling/x.zig", out);
    }
    {
        const out = try mirrorPathToZig(a, "/abs/path/x.zpp");
        defer a.free(out);
        try std.testing.expectEqualStrings("abs/path/x.zig", out);
    }
}

test "lowerOne writes mirrored .zig under cache and survives test blocks" {
    const a = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Fake a project layout: src/sample.zpp containing a test block.
    try tmp.dir.makePath("src");
    const sample =
        \\const std = @import("std");
        \\test "trivially true" {
        \\    try std.testing.expect(true);
        \\}
        \\
    ;
    try tmp.dir.writeFile(.{ .sub_path = "src/sample.zpp", .data = sample });

    // Stage a cache dir inside the tmp tree so we don't pollute cwd.
    try tmp.dir.makePath("cache");
    var cache = try tmp.dir.openDir("cache", .{ .iterate = true });
    defer cache.close();

    // We must hand lowerOne a path readable from cwd — point it at the tmp
    // file via its real path.
    const src_full = try tmp.dir.realpathAlloc(a, "src/sample.zpp");
    defer a.free(src_full);

    const rel = try lowerOne(a, &cache, src_full);
    defer a.free(rel);
    // The mirrored path must end in sample.zig (the absolute prefix is
    // stripped by mirrorPathToZig).
    try std.testing.expect(std.mem.endsWith(u8, rel, "sample.zig"));

    // The lowered file must exist under cache and contain the test block.
    const written = try cache.readFileAlloc(a, rel, 64 * 1024);
    defer a.free(written);
    try std.testing.expect(std.mem.indexOf(u8, written, "test \"trivially true\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "std.testing.expect(true)") != null);
}

test "collectZppFiles walks a directory tree" {
    const a = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("a/b");
    try tmp.dir.writeFile(.{ .sub_path = "top.zpp", .data = "// top\n" });
    try tmp.dir.writeFile(.{ .sub_path = "a/mid.zpp", .data = "// mid\n" });
    try tmp.dir.writeFile(.{ .sub_path = "a/b/leaf.zpp", .data = "// leaf\n" });
    try tmp.dir.writeFile(.{ .sub_path = "a/skip.zig", .data = "// skip\n" });

    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);

    var found: std.ArrayList([]u8) = .{};
    defer {
        for (found.items) |p| a.free(p);
        found.deinit(a);
    }
    try collectZppFiles(a, root, &found);
    try std.testing.expectEqual(@as(usize, 3), found.items.len);
    for (found.items) |p| {
        try std.testing.expect(std.mem.endsWith(u8, p, ".zpp"));
    }
}
