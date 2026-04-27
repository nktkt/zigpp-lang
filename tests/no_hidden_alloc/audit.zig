const std = @import("std");

const banned_needle = "std.heap.page_allocator";

const allowed_main_entries = [_][]const u8{
    "tools/zpp.zig",
    "tools/zpp_fmt.zig",
    "tools/zpp_lsp.zig",
    "tools/zpp_doc.zig",
    "tools/zpp_migrate.zig",
};

const trees = [_][]const u8{ "lib", "compiler", "tools" };

const max_file_bytes: usize = 4 * 1024 * 1024;

fn isAllowed(rel: []const u8) bool {
    for (allowed_main_entries) |allow| {
        if (std.mem.eql(u8, rel, allow)) return true;
    }
    return false;
}

fn auditTree(allocator: std.mem.Allocator, root: []const u8, offenders: *std.ArrayList([]u8)) !void {
    var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        const rel = try std.fs.path.join(allocator, &.{ root, entry.path });
        defer allocator.free(rel);

        if (isAllowed(rel)) continue;

        const source = dir.readFileAlloc(allocator, entry.path, max_file_bytes) catch continue;
        defer allocator.free(source);

        if (std.mem.indexOf(u8, source, banned_needle)) |_| {
            const owned = try allocator.dupe(u8, rel);
            try offenders.append(allocator, owned);
        }
    }
}

test "no module under lib/, compiler/, tools/ uses std.heap.page_allocator (except CLI mains)" {
    const a = std.testing.allocator;
    var offenders = std.ArrayList([]u8){};
    defer {
        for (offenders.items) |s| a.free(s);
        offenders.deinit(a);
    }

    for (trees) |t| {
        try auditTree(a, t, &offenders);
    }

    if (offenders.items.len != 0) {
        std.debug.print("\nno_hidden_alloc audit found offenders:\n", .{});
        for (offenders.items) |o| std.debug.print("  - {s}\n", .{o});
    }
    try std.testing.expectEqual(@as(usize, 0), offenders.items.len);
}

test "isAllowed recognises CLI entry points" {
    try std.testing.expect(isAllowed("tools/zpp.zig"));
    try std.testing.expect(!isAllowed("lib/zpp.zig"));
}
