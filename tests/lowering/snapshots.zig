const std = @import("std");
const compiler = @import("zpp_compiler");

const cases = [_][]const u8{
    "hello_using",
    "trait_simple",
    "dyn_call",
    "derive_extras",
    "effects_noasync",
};

const max_file_bytes: usize = 4 * 1024 * 1024;

/// Maximum number of `-`/`+` diff lines we print on a snapshot mismatch.
/// Keeps test output readable when an entire snapshot has rewritten itself
/// (e.g. a header change), instead of dumping thousands of lines.
const max_diff_lines: usize = 20;

fn shouldUpdate() bool {
    const env_value = std.process.getEnvVarOwned(std.heap.page_allocator, "ZPP_UPDATE_SNAPSHOTS") catch return false;
    defer std.heap.page_allocator.free(env_value);
    return env_value.len > 0 and !std.mem.eql(u8, env_value, "0");
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(allocator, path, max_file_bytes);
}

fn writeFile(path: []const u8, data: []const u8) !void {
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = data });
}

fn runOne(allocator: std.mem.Allocator, name: []const u8) !void {
    const input_path = try std.fmt.allocPrint(allocator, "tests/lowering/inputs/{s}.zpp", .{name});
    defer allocator.free(input_path);
    const snap_path = try std.fmt.allocPrint(allocator, "tests/lowering/snapshots/{s}.zig", .{name});
    defer allocator.free(snap_path);

    const source = try readFile(allocator, input_path);
    defer allocator.free(source);

    const lowered = try compiler.compileToString(allocator, source);
    defer allocator.free(lowered);

    if (shouldUpdate()) {
        try writeFile(snap_path, lowered);
        return;
    }

    const expected = try readFile(allocator, snap_path);
    defer allocator.free(expected);

    // Normalize line endings so the test passes on Windows checkouts even
    // if .gitattributes was missed.
    const got_norm = try stripCr(allocator, std.mem.trimRight(u8, lowered, " \t\n\r"));
    defer allocator.free(got_norm);
    const want_norm = try stripCr(allocator, std.mem.trimRight(u8, expected, " \t\n\r"));
    defer allocator.free(want_norm);

    try compareSnapshot(allocator, snap_path, want_norm, got_norm);
}

fn stripCr(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);
    for (text) |c| if (c != '\r') try out.append(allocator, c);
    return out.toOwnedSlice(allocator);
}

/// Compare expected vs. actual lowered output. On mismatch, print a
/// unified-diff-style summary (capped to `max_diff_lines` `-`/`+` lines)
/// and return `error.SnapshotMismatch`. The summary names the snapshot
/// file and reminds the developer how to refresh it intentionally.
///
/// The cap is important: a single header tweak can rewrite an entire
/// snapshot, and dumping the full file twice (once expected, once actual)
/// drowns out anything else in the test log.
fn compareSnapshot(
    allocator: std.mem.Allocator,
    snap_path: []const u8,
    expected: []const u8,
    actual: []const u8,
) !void {
    if (std.mem.eql(u8, expected, actual)) return;

    var exp_lines = std.ArrayList([]const u8){};
    defer exp_lines.deinit(allocator);
    var act_lines = std.ArrayList([]const u8){};
    defer act_lines.deinit(allocator);

    var it_exp = std.mem.splitScalar(u8, expected, '\n');
    while (it_exp.next()) |line| try exp_lines.append(allocator, line);
    var it_act = std.mem.splitScalar(u8, actual, '\n');
    while (it_act.next()) |line| try act_lines.append(allocator, line);

    std.debug.print(
        "\n[snapshot drift] {s}\n" ++
            "  expected lines: {d}\n" ++
            "  actual   lines: {d}\n" ++
            "  to refresh intentionally: ZPP_UPDATE_SNAPSHOTS=1 zig build test\n" ++
            "  diff (capped at {d} non-context lines, '-' expected, '+' actual):\n",
        .{ snap_path, exp_lines.items.len, act_lines.items.len, max_diff_lines },
    );

    const max_idx = @max(exp_lines.items.len, act_lines.items.len);
    var printed: usize = 0;
    var i: usize = 0;
    while (i < max_idx) : (i += 1) {
        const e: ?[]const u8 = if (i < exp_lines.items.len) exp_lines.items[i] else null;
        const a: ?[]const u8 = if (i < act_lines.items.len) act_lines.items[i] else null;

        const same = e != null and a != null and std.mem.eql(u8, e.?, a.?);
        if (same) continue;

        if (printed >= max_diff_lines) {
            std.debug.print("    ... (more diff lines suppressed)\n", .{});
            break;
        }

        if (e) |line| {
            std.debug.print("    -{d:>4}: {s}\n", .{ i + 1, line });
            printed += 1;
            if (printed >= max_diff_lines) {
                if (a != null) std.debug.print("    ... (more diff lines suppressed)\n", .{});
                break;
            }
        }
        if (a) |line| {
            std.debug.print("    +{d:>4}: {s}\n", .{ i + 1, line });
            printed += 1;
        }
    }

    return error.SnapshotMismatch;
}

test "snapshot: hello_using" {
    try runOne(std.testing.allocator, "hello_using");
}

test "snapshot: trait_simple" {
    try runOne(std.testing.allocator, "trait_simple");
}

test "snapshot: dyn_call" {
    try runOne(std.testing.allocator, "dyn_call");
}

test "snapshot: derive_extras" {
    try runOne(std.testing.allocator, "derive_extras");
}

test "snapshot: effects_noasync" {
    try runOne(std.testing.allocator, "effects_noasync");
}

test "snapshot manifest is non-empty" {
    try std.testing.expect(cases.len >= 3);
}

// Failure-path test: feed `compareSnapshot` a deliberately wrong "expected"
// value and verify it returns `error.SnapshotMismatch`. This locks in the
// drift-gate contract without ever touching an on-disk snapshot, so it
// cannot be silenced by a stale or corrupted file under
// `tests/lowering/snapshots/`.
test "snapshot drift gate fires on mismatch" {
    const expected =
        \\const a = 1;
        \\const b = 2;
        \\const c = 3;
    ;
    const actual =
        \\const a = 1;
        \\const b = 999;
        \\const c = 3;
    ;
    try std.testing.expectError(
        error.SnapshotMismatch,
        compareSnapshot(std.testing.allocator, "tests/lowering/snapshots/__synthetic__.zig", expected, actual),
    );
}

test "snapshot drift gate accepts identical input" {
    const same = "// hello\nconst x = 1;\n";
    try compareSnapshot(std.testing.allocator, "tests/lowering/snapshots/__synthetic__.zig", same, same);
}
