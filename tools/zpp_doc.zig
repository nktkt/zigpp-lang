const std = @import("std");

const ItemKind = enum { trait_decl, fn_decl, owned_struct, struct_decl, extern_interface };

const Item = struct {
    kind: ItemKind,
    name: []const u8,
    signature: []const u8,
    docs: []const u8,
};

const ParsedFile = struct {
    items: std.ArrayList(Item),

    fn deinit(self: *ParsedFile, allocator: std.mem.Allocator) void {
        for (self.items.items) |it| {
            allocator.free(it.name);
            allocator.free(it.signature);
            allocator.free(it.docs);
        }
        self.items.deinit(allocator);
    }
};

pub fn runDoc(allocator: std.mem.Allocator, args: [][:0]u8) !@import("zpp.zig").ExitCode {
    var out_dir: []const u8 = "docs";
    var inputs = std.ArrayList([]const u8){};
    defer inputs.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "--out")) {
            i += 1;
            if (i >= args.len) {
                try emitErr("zpp doc: -o requires a path\n", .{});
                return .usage_error;
            }
            out_dir = args[i];
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            try emitErr("zpp doc [paths...] [-o docs/]\n", .{});
            return .ok;
        } else {
            try inputs.append(allocator, a);
        }
    }
    if (inputs.items.len == 0) try inputs.append(allocator, ".");

    std.fs.cwd().makePath(out_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };

    var written: usize = 0;
    for (inputs.items) |root| {
        try walkAndDoc(allocator, root, out_dir, &written);
    }
    var msg_buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&msg_buf, "zpp doc: wrote {d} markdown file(s) under {s}/\n", .{ written, out_dir });
    try std.fs.File.stdout().writeAll(msg);
    return .ok;
}

fn walkAndDoc(
    allocator: std.mem.Allocator,
    root: []const u8,
    out_dir: []const u8,
    written: *usize,
) !void {
    const stat = std.fs.cwd().statFile(root) catch |e| {
        try emitErr("zpp doc: cannot stat '{s}': {s}\n", .{ root, @errorName(e) });
        return;
    };
    if (stat.kind == .directory) {
        var dir = try std.fs.cwd().openDir(root, .{ .iterate = true });
        defer dir.close();
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".zpp")) continue;
            const full = try std.fs.path.join(allocator, &.{ root, entry.path });
            defer allocator.free(full);
            try docOne(allocator, full, entry.path, out_dir, written);
        }
    } else {
        const base = std.fs.path.basename(root);
        try docOne(allocator, root, base, out_dir, written);
    }
}

fn docOne(
    allocator: std.mem.Allocator,
    full_path: []const u8,
    rel_path: []const u8,
    out_dir: []const u8,
    written: *usize,
) !void {
    const source = std.fs.cwd().readFileAlloc(allocator, full_path, 16 * 1024 * 1024) catch |e| {
        try emitErr("zpp doc: cannot read '{s}': {s}\n", .{ full_path, @errorName(e) });
        return;
    };
    defer allocator.free(source);

    var parsed = try parseDocItems(allocator, source);
    defer parsed.deinit(allocator);

    if (parsed.items.items.len == 0) return;

    const md = try renderMarkdown(allocator, rel_path, parsed.items.items);
    defer allocator.free(md);

    const md_rel = try replaceExt(allocator, rel_path, ".md");
    defer allocator.free(md_rel);

    if (std.fs.path.dirname(md_rel)) |sub| {
        const joined = try std.fs.path.join(allocator, &.{ out_dir, sub });
        defer allocator.free(joined);
        std.fs.cwd().makePath(joined) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
    }

    const md_full = try std.fs.path.join(allocator, &.{ out_dir, md_rel });
    defer allocator.free(md_full);
    try std.fs.cwd().writeFile(.{ .sub_path = md_full, .data = md });
    written.* += 1;
}

/// Lightweight scanner: walks the source, accumulates `///` doc lines, then
/// when it sees a top-level keyword starting a decl, captures the signature
/// (everything up to `{` or `;`) and pairs it with the buffered docs.
pub fn parseDocItems(allocator: std.mem.Allocator, source: []const u8) !ParsedFile {
    var items = std.ArrayList(Item){};
    errdefer {
        for (items.items) |it| {
            allocator.free(it.name);
            allocator.free(it.signature);
            allocator.free(it.docs);
        }
        items.deinit(allocator);
    }

    var pending_docs = std.ArrayList(u8){};
    defer pending_docs.deinit(allocator);

    var i: usize = 0;
    while (i < source.len) {
        // Skip leading whitespace per logical line.
        const line_start = i;
        while (i < source.len and (source[i] == ' ' or source[i] == '\t')) : (i += 1) {}
        const indent_end = i;
        if (i >= source.len) break;

        // Collect up to end of line.
        var eol = i;
        while (eol < source.len and source[eol] != '\n') : (eol += 1) {}
        const line = source[i..eol];

        if (std.mem.startsWith(u8, line, "///")) {
            const doc_body = std.mem.trimLeft(u8, line[3..], " ");
            try pending_docs.appendSlice(allocator, doc_body);
            try pending_docs.append(allocator, '\n');
        } else if (line.len == 0) {
            // blank line discards pending docs (matches zig std behaviour for unattached docs)
            // keep them — they may attach to next decl
        } else if (isDeclStart(line)) {
            const decl_kind = classifyDecl(line);
            if (decl_kind != null and indent_end == line_start) {
                // Capture full signature: walk forward until `{` or `;` (top-level only).
                const sig_start = i;
                var j = i;
                var depth: i32 = 0;
                var in_str = false;
                var sig_end: usize = j;
                while (j < source.len) : (j += 1) {
                    const c = source[j];
                    if (in_str) {
                        if (c == '\\' and j + 1 < source.len) { j += 1; continue; }
                        if (c == '"') in_str = false;
                        continue;
                    }
                    if (c == '"') { in_str = true; continue; }
                    if (c == '(' or c == '[' or c == '<') depth += 1;
                    if (c == ')' or c == ']' or c == '>') depth -= 1;
                    if (depth <= 0 and (c == '{' or c == ';')) {
                        sig_end = j;
                        break;
                    }
                }
                const sig_raw = source[sig_start..sig_end];
                const sig_trimmed = std.mem.trim(u8, sig_raw, " \t\r\n");
                const name = extractName(decl_kind.?, sig_trimmed) orelse "";
                try items.append(allocator, .{
                    .kind = decl_kind.?,
                    .name = try allocator.dupe(u8, name),
                    .signature = try allocator.dupe(u8, sig_trimmed),
                    .docs = try pending_docs.toOwnedSlice(allocator),
                });
                pending_docs = std.ArrayList(u8){};
                // Skip ahead to either after `;` or the matching `}` on multi-line decls.
                if (j < source.len and source[j] == '{') {
                    j = skipBlock(source, j);
                }
                eol = j;
            } else if (indent_end != line_start) {
                pending_docs.clearRetainingCapacity();
            }
        } else {
            // some other top-level statement: drop pending
            pending_docs.clearRetainingCapacity();
        }
        i = if (eol < source.len) eol + 1 else eol;
    }

    return .{ .items = items };
}

fn isDeclStart(line: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, line, " \t");
    const keywords = [_][]const u8{
        "pub fn ", "fn ",
        "pub trait ", "trait ",
        "pub owned struct ", "owned struct ",
        "pub struct ", "struct ",
        "pub extern interface ", "extern interface ",
    };
    for (keywords) |kw| {
        if (std.mem.startsWith(u8, trimmed, kw)) return true;
    }
    return false;
}

fn classifyDecl(line: []const u8) ?ItemKind {
    const trimmed = std.mem.trimLeft(u8, line, " \t");
    if (std.mem.indexOf(u8, trimmed, "extern interface ") != null) return .extern_interface;
    if (std.mem.indexOf(u8, trimmed, "trait ") != null and !std.mem.startsWith(u8, trimmed, "//")) return .trait_decl;
    if (std.mem.indexOf(u8, trimmed, "owned struct ") != null) return .owned_struct;
    if (std.mem.indexOf(u8, trimmed, "fn ") != null) return .fn_decl;
    if (std.mem.indexOf(u8, trimmed, "struct ") != null) return .struct_decl;
    return null;
}

fn extractName(kind: ItemKind, sig: []const u8) ?[]const u8 {
    const anchor = switch (kind) {
        .trait_decl => "trait ",
        .fn_decl => "fn ",
        .owned_struct => "owned struct ",
        .struct_decl => "struct ",
        .extern_interface => "extern interface ",
    };
    const idx = std.mem.indexOf(u8, sig, anchor) orelse return null;
    var s = sig[idx + anchor.len ..];
    s = std.mem.trimLeft(u8, s, " \t");
    var end: usize = 0;
    while (end < s.len) : (end += 1) {
        const c = s[end];
        if (c == '(' or c == '{' or c == ' ' or c == ':' or c == ';' or c == '<') break;
    }
    return s[0..end];
}

fn skipBlock(source: []const u8, brace_open: usize) usize {
    var depth: i32 = 0;
    var i = brace_open;
    var in_str = false;
    while (i < source.len) : (i += 1) {
        const c = source[i];
        if (in_str) {
            if (c == '\\' and i + 1 < source.len) { i += 1; continue; }
            if (c == '"') in_str = false;
            continue;
        }
        if (c == '"') { in_str = true; continue; }
        if (c == '{') depth += 1;
        if (c == '}') {
            depth -= 1;
            if (depth == 0) return i + 1;
        }
    }
    return source.len;
}

fn renderMarkdown(allocator: std.mem.Allocator, module_path: []const u8, items: []const Item) ![]u8 {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);
    var w = out.writer(allocator);

    try w.print("# {s}\n\n", .{module_path});

    try emitSection(allocator, &out, "Traits", items, .trait_decl);
    try emitSection(allocator, &out, "Functions", items, .fn_decl);
    try emitSection(allocator, &out, "Owned Structs", items, .owned_struct);
    try emitSection(allocator, &out, "Structs", items, .struct_decl);
    try emitSection(allocator, &out, "Extern Interfaces", items, .extern_interface);

    return out.toOwnedSlice(allocator);
}

fn emitSection(allocator: std.mem.Allocator, out: *std.ArrayList(u8), title: []const u8, items: []const Item, kind: ItemKind) !void {
    var any = false;
    for (items) |it| {
        if (it.kind != kind) continue;
        if (!any) {
            try out.appendSlice(allocator, "## ");
            try out.appendSlice(allocator, title);
            try out.appendSlice(allocator, "\n\n");
            any = true;
        }
        try out.appendSlice(allocator, "### ");
        try out.appendSlice(allocator, it.name);
        try out.appendSlice(allocator, "\n\n");
        try out.appendSlice(allocator, "```zig\n");
        try out.appendSlice(allocator, it.signature);
        try out.appendSlice(allocator, "\n```\n\n");
        if (it.docs.len > 0) {
            try out.appendSlice(allocator, it.docs);
            if (it.docs[it.docs.len - 1] != '\n') try out.append(allocator, '\n');
            try out.append(allocator, '\n');
        }
    }
}

fn replaceExt(allocator: std.mem.Allocator, path: []const u8, new_ext: []const u8) ![]u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse path.len;
    return std.mem.concat(allocator, u8, &.{ path[0..dot], new_ext });
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

    const exit = try runDoc(allocator, argv[1..]);
    std.process.exit(@intFromEnum(exit));
}

test "parseDocItems extracts trait with docs" {
    const a = std.testing.allocator;
    const src =
        \\/// A reader trait.
        \\/// Two lines.
        \\trait Reader {
        \\    fn read(self: *Self) usize;
        \\}
        \\
        \\/// Top-level free function.
        \\fn helper(x: u32) u32 {
        \\    return x;
        \\}
        \\
    ;
    var parsed = try parseDocItems(a, src);
    defer parsed.deinit(a);
    try std.testing.expect(parsed.items.items.len >= 2);
    try std.testing.expectEqualStrings("Reader", parsed.items.items[0].name);
    try std.testing.expectEqual(ItemKind.trait_decl, parsed.items.items[0].kind);
}

test "renderMarkdown emits sections" {
    const a = std.testing.allocator;
    const items = [_]Item{
        .{ .kind = .fn_decl, .name = try a.dupe(u8, "foo"), .signature = try a.dupe(u8, "fn foo() void"), .docs = try a.dupe(u8, "does foo\n") },
    };
    defer {
        for (items) |it| {
            a.free(it.name);
            a.free(it.signature);
            a.free(it.docs);
        }
    }
    const md = try renderMarkdown(a, "x.zpp", &items);
    defer a.free(md);
    try std.testing.expect(std.mem.indexOf(u8, md, "## Functions") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "### foo") != null);
}
