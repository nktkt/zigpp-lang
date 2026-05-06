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
    try std.testing.expectEqualStrings(want_norm, got_norm);
}

fn stripCr(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);
    for (text) |c| if (c != '\r') try out.append(allocator, c);
    return out.toOwnedSlice(allocator);
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
