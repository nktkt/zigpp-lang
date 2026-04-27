const std = @import("std");

pub const SuggestionKind = enum {
    using_for_defer_deinit,
    impl_trait_for_comptime_t,
    owned_struct_for_init_deinit,
};

pub const Suggestion = struct {
    kind: SuggestionKind,
    line: usize,
    original: []const u8,
    rewrite: ?[]const u8 = null,
    note: []const u8,
};

pub const Plan = struct {
    items: std.ArrayList(Suggestion),

    fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        for (self.items.items) |s| {
            allocator.free(s.original);
            if (s.rewrite) |r| allocator.free(r);
            allocator.free(s.note);
        }
        self.items.deinit(allocator);
    }
};

pub fn runMigrate(allocator: std.mem.Allocator, args: [][:0]u8) !@import("zpp.zig").ExitCode {
    var write_mode = false;
    var path: ?[]const u8 = null;

    for (args) |a| {
        if (std.mem.eql(u8, a, "--write")) write_mode = true
        else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            try emitErr("zpp migrate <file.zig> [--write]\n", .{});
            return .ok;
        } else path = a;
    }

    const p = path orelse {
        try emitErr("zpp migrate: expected <file.zig>\n", .{});
        return .usage_error;
    };

    const source = std.fs.cwd().readFileAlloc(allocator, p, 16 * 1024 * 1024) catch |e| {
        try emitErr("zpp migrate: cannot read '{s}': {s}\n", .{ p, @errorName(e) });
        return .user_error;
    };
    defer allocator.free(source);

    var plan = try analyse(allocator, source);
    defer plan.deinit(allocator);

    if (write_mode) {
        const new_src = try applySafeRewrites(allocator, source, plan.items.items);
        defer allocator.free(new_src);
        try std.fs.cwd().writeFile(.{ .sub_path = p, .data = new_src });
        var msg_buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&msg_buf, "zpp migrate: applied safe rewrites to {s}\n", .{p});
        try std.fs.File.stdout().writeAll(msg);
    } else {
        try renderDiff(allocator, p, source, plan.items.items);
    }
    return .ok;
}

pub fn analyse(allocator: std.mem.Allocator, source: []const u8) !Plan {
    var items = std.ArrayList(Suggestion){};
    errdefer {
        for (items.items) |s| {
            allocator.free(s.original);
            if (s.rewrite) |r| allocator.free(r);
            allocator.free(s.note);
        }
        items.deinit(allocator);
    }

    var line_no: usize = 0;
    var i: usize = 0;
    var var_lines = std.StringHashMap(struct { line: usize, original: []const u8 }).init(allocator);
    defer {
        var it = var_lines.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*.original);
        }
        var_lines.deinit();
    }

    var has_init = false;
    var has_deinit = false;
    var struct_line: usize = 0;
    var struct_name_buf: [128]u8 = undefined;
    var struct_name_len: usize = 0;
    var in_struct = false;

    while (i < source.len) {
        line_no += 1;
        var eol = i;
        while (eol < source.len and source[eol] != '\n') : (eol += 1) {}
        const line = source[i..eol];
        const trimmed = std.mem.trimLeft(u8, line, " \t");

        // Pattern 1: `var x = try X.init(...);`
        if (std.mem.startsWith(u8, trimmed, "var ")) {
            if (extractVarInit(trimmed)) |name| {
                const owned_name = try allocator.dupe(u8, name);
                const owned_orig = try allocator.dupe(u8, line);
                if (var_lines.fetchRemove(owned_name)) |kv| {
                    allocator.free(kv.key);
                    allocator.free(kv.value.original);
                }
                try var_lines.put(owned_name, .{ .line = line_no, .original = owned_orig });
            }
        }

        // Pattern 1 cont.: `defer x.deinit();`
        if (std.mem.startsWith(u8, trimmed, "defer ")) {
            if (extractDeferDeinit(trimmed)) |name| {
                if (var_lines.fetchRemove(name)) |kv| {
                    defer {
                        allocator.free(kv.key);
                        allocator.free(kv.value.original);
                    }
                    const rewrite = try rewriteVarToUsing(allocator, kv.value.original);
                    try items.append(allocator, .{
                        .kind = .using_for_defer_deinit,
                        .line = kv.value.line,
                        .original = try allocator.dupe(u8, kv.value.original),
                        .rewrite = rewrite,
                        .note = try allocator.dupe(u8, "var+defer.deinit pair → `using` binding"),
                    });
                }
            }
        }

        // Pattern 2: `fn name(comptime T: type, x: *T, ...)`
        if (std.mem.indexOf(u8, trimmed, "comptime T: type") != null and std.mem.startsWith(u8, trimmed, "fn ")) {
            try items.append(allocator, .{
                .kind = .impl_trait_for_comptime_t,
                .line = line_no,
                .original = try allocator.dupe(u8, line),
                .rewrite = null,
                .note = try allocator.dupe(u8, "consider replacing `comptime T: type` with `impl SomeTrait` parameter"),
            });
        }

        // Pattern 3: track struct decls and init/deinit method presence
        if (extractStructName(trimmed)) |name| {
            if (in_struct) {
                if (has_init and has_deinit) {
                    try items.append(allocator, .{
                        .kind = .owned_struct_for_init_deinit,
                        .line = struct_line,
                        .original = try std.fmt.allocPrint(allocator, "// struct {s}", .{struct_name_buf[0..struct_name_len]}),
                        .rewrite = null,
                        .note = try allocator.dupe(u8, "struct has init+deinit → consider `owned struct`"),
                    });
                }
            }
            in_struct = true;
            has_init = false;
            has_deinit = false;
            struct_line = line_no;
            const copy_len = @min(name.len, struct_name_buf.len);
            @memcpy(struct_name_buf[0..copy_len], name[0..copy_len]);
            struct_name_len = copy_len;
        }
        if (in_struct) {
            if (std.mem.indexOf(u8, trimmed, "fn init(") != null or std.mem.indexOf(u8, trimmed, "pub fn init(") != null) has_init = true;
            if (std.mem.indexOf(u8, trimmed, "fn deinit(") != null or std.mem.indexOf(u8, trimmed, "pub fn deinit(") != null) has_deinit = true;
        }

        i = if (eol < source.len) eol + 1 else eol;
    }

    if (in_struct and has_init and has_deinit) {
        try items.append(allocator, .{
            .kind = .owned_struct_for_init_deinit,
            .line = struct_line,
            .original = try std.fmt.allocPrint(allocator, "// struct {s}", .{struct_name_buf[0..struct_name_len]}),
            .rewrite = null,
            .note = try allocator.dupe(u8, "struct has init+deinit → consider `owned struct`"),
        });
    }

    return .{ .items = items };
}

fn extractVarInit(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "var ")) return null;
    var rest = line[4..];
    var name_end: usize = 0;
    while (name_end < rest.len and (std.ascii.isAlphanumeric(rest[name_end]) or rest[name_end] == '_')) : (name_end += 1) {}
    if (name_end == 0) return null;
    const name = rest[0..name_end];
    const tail = rest[name_end..];
    if (std.mem.indexOf(u8, tail, "= try ") == null and std.mem.indexOf(u8, tail, "=try ") == null) return null;
    if (std.mem.indexOf(u8, tail, ".init(") == null) return null;
    return name;
}

fn extractDeferDeinit(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "defer ")) return null;
    var rest = line[6..];
    var name_end: usize = 0;
    while (name_end < rest.len and (std.ascii.isAlphanumeric(rest[name_end]) or rest[name_end] == '_')) : (name_end += 1) {}
    if (name_end == 0) return null;
    const name = rest[0..name_end];
    const tail = rest[name_end..];
    if (!std.mem.startsWith(u8, tail, ".deinit(")) return null;
    return name;
}

fn extractStructName(line: []const u8) ?[]const u8 {
    const anchors = [_][]const u8{ "const ", "pub const " };
    for (anchors) |a| {
        if (std.mem.startsWith(u8, line, a)) {
            const rest = line[a.len..];
            if (std.mem.indexOf(u8, rest, "= struct {") == null) continue;
            var end: usize = 0;
            while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_')) : (end += 1) {}
            if (end == 0) return null;
            return rest[0..end];
        }
    }
    return null;
}

fn rewriteVarToUsing(allocator: std.mem.Allocator, line: []const u8) ![]u8 {
    // Replace leading `var ` with `using `, preserving leading whitespace.
    const indent_end = blk: {
        var k: usize = 0;
        while (k < line.len and (line[k] == ' ' or line[k] == '\t')) : (k += 1) {}
        break :blk k;
    };
    if (!std.mem.startsWith(u8, line[indent_end..], "var ")) {
        return allocator.dupe(u8, line);
    }
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);
    try out.appendSlice(allocator, line[0..indent_end]);
    try out.appendSlice(allocator, "using ");
    try out.appendSlice(allocator, line[indent_end + 4 ..]);
    return out.toOwnedSlice(allocator);
}

fn applySafeRewrites(allocator: std.mem.Allocator, source: []const u8, items: []const Suggestion) ![]u8 {
    // Build a map line -> rewrite for using suggestions.
    var rewrites = std.AutoHashMap(usize, []const u8).init(allocator);
    defer rewrites.deinit();
    for (items) |s| {
        if (s.kind != .using_for_defer_deinit) continue;
        const r = s.rewrite orelse continue;
        try rewrites.put(s.line, r);
    }

    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    var line_no: usize = 0;
    var i: usize = 0;
    var skip_next_defer_for: ?[]const u8 = null;

    while (i < source.len) {
        line_no += 1;
        var eol = i;
        while (eol < source.len and source[eol] != '\n') : (eol += 1) {}
        const line = source[i..eol];
        const trimmed = std.mem.trimLeft(u8, line, " \t");

        if (rewrites.get(line_no)) |r| {
            try out.appendSlice(allocator, r);
            if (eol < source.len) try out.append(allocator, '\n');
            // Note the var name so the matching `defer x.deinit();` can be elided.
            if (extractVarInit(trimmed)) |n| skip_next_defer_for = n;
            i = if (eol < source.len) eol + 1 else eol;
            continue;
        }
        if (skip_next_defer_for) |n| {
            if (extractDeferDeinit(trimmed)) |dn| {
                if (std.mem.eql(u8, n, dn)) {
                    skip_next_defer_for = null;
                    i = if (eol < source.len) eol + 1 else eol;
                    continue;
                }
            }
        }
        try out.appendSlice(allocator, line);
        if (eol < source.len) try out.append(allocator, '\n');
        i = if (eol < source.len) eol + 1 else eol;
    }
    return out.toOwnedSlice(allocator);
}

fn renderDiff(allocator: std.mem.Allocator, path: []const u8, source: []const u8, items: []const Suggestion) !void {
    _ = source;
    const stdout = std.fs.File.stdout();
    var hdr_buf: [256]u8 = undefined;
    const hdr = try std.fmt.bufPrint(&hdr_buf, "--- {s}\n+++ {s} (zpp suggestions)\n", .{ path, path });
    try stdout.writeAll(hdr);
    if (items.len == 0) {
        try stdout.writeAll("# (no migration patterns detected)\n");
        return;
    }
    for (items) |s| {
        var line_buf: [4096]u8 = undefined;
        const head = try std.fmt.bufPrint(&line_buf, "@@ line {d}: {s} @@\n", .{ s.line, s.note });
        try stdout.writeAll(head);
        const orig_line = try std.fmt.allocPrint(allocator, "-{s}\n", .{s.original});
        defer allocator.free(orig_line);
        try stdout.writeAll(orig_line);
        if (s.rewrite) |r| {
            const new_line = try std.fmt.allocPrint(allocator, "+{s}\n", .{r});
            defer allocator.free(new_line);
            try stdout.writeAll(new_line);
        } else {
            try stdout.writeAll("# (suggestion only — no automated rewrite)\n");
        }
    }
}

fn emitErr(comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, fmt, args) catch return;
    try std.fs.File.stderr().writeAll(slice);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const exit = try runMigrate(allocator, argv[1..]);
    std.process.exit(@intFromEnum(exit));
}

test "analyse detects var/defer.deinit pair" {
    const a = std.testing.allocator;
    const src =
        \\fn f() !void {
        \\    var arena = try Arena.init(allocator);
        \\    defer arena.deinit();
        \\    _ = arena;
        \\}
        \\
    ;
    var plan = try analyse(a, src);
    defer plan.deinit(a);
    var found = false;
    for (plan.items.items) |s| {
        if (s.kind == .using_for_defer_deinit) {
            found = true;
            try std.testing.expect(s.rewrite != null);
            try std.testing.expect(std.mem.indexOf(u8, s.rewrite.?, "using arena") != null);
        }
    }
    try std.testing.expect(found);
}

test "analyse detects struct with init+deinit" {
    const a = std.testing.allocator;
    const src =
        \\const Foo = struct {
        \\    pub fn init(allocator: Allocator) Foo { return .{}; }
        \\    pub fn deinit(self: *Foo) void { _ = self; }
        \\};
        \\
    ;
    var plan = try analyse(a, src);
    defer plan.deinit(a);
    var found = false;
    for (plan.items.items) |s| {
        if (s.kind == .owned_struct_for_init_deinit) found = true;
    }
    try std.testing.expect(found);
}
