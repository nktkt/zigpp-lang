const std = @import("std");

const ItemKind = enum { trait_decl, fn_decl, owned_struct, struct_decl, extern_interface };

const Item = struct {
    kind: ItemKind,
    name: []const u8,
    signature: []const u8,
    docs: []const u8,
};

const Format = enum { markdown, html };

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

const IndexEntry = struct {
    rel_path: []u8, // owned: path relative to out_dir, with rendered extension (e.g. "foo/bar.html")
};

pub fn runDoc(allocator: std.mem.Allocator, args: [][:0]u8) !@import("zpp.zig").ExitCode {
    var out_dir: []const u8 = "docs";
    var format: Format = .markdown;
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
        } else if (std.mem.eql(u8, a, "--html")) {
            format = .html;
        } else if (std.mem.eql(u8, a, "--markdown") or std.mem.eql(u8, a, "--md")) {
            format = .markdown;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            try emitErr("zpp doc [paths...] [-o docs/] [--html]\n", .{});
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

    var index_entries = std.ArrayList(IndexEntry){};
    defer {
        for (index_entries.items) |e| allocator.free(e.rel_path);
        index_entries.deinit(allocator);
    }

    var written: usize = 0;
    for (inputs.items) |root| {
        try walkAndDoc(allocator, root, out_dir, format, &written, &index_entries);
    }

    if (format == .html) {
        try writeIndexHtml(allocator, out_dir, index_entries.items);
    }

    var msg_buf: [256]u8 = undefined;
    const fmt_label: []const u8 = switch (format) {
        .markdown => "markdown",
        .html => "html",
    };
    const msg = try std.fmt.bufPrint(&msg_buf, "zpp doc: wrote {d} {s} file(s) under {s}/\n", .{ written, fmt_label, out_dir });
    try std.fs.File.stdout().writeAll(msg);
    return .ok;
}

fn walkAndDoc(
    allocator: std.mem.Allocator,
    root: []const u8,
    out_dir: []const u8,
    format: Format,
    written: *usize,
    index_entries: *std.ArrayList(IndexEntry),
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
            try docOne(allocator, full, entry.path, out_dir, format, written, index_entries);
        }
    } else {
        const base = std.fs.path.basename(root);
        try docOne(allocator, root, base, out_dir, format, written, index_entries);
    }
}

fn docOne(
    allocator: std.mem.Allocator,
    full_path: []const u8,
    rel_path: []const u8,
    out_dir: []const u8,
    format: Format,
    written: *usize,
    index_entries: *std.ArrayList(IndexEntry),
) !void {
    const source = std.fs.cwd().readFileAlloc(allocator, full_path, 16 * 1024 * 1024) catch |e| {
        try emitErr("zpp doc: cannot read '{s}': {s}\n", .{ full_path, @errorName(e) });
        return;
    };
    defer allocator.free(source);

    var parsed = try parseDocItems(allocator, source);
    defer parsed.deinit(allocator);

    if (parsed.items.items.len == 0) return;

    const out_ext = switch (format) {
        .markdown => ".md",
        .html => ".html",
    };

    const rendered = switch (format) {
        .markdown => try renderMarkdown(allocator, rel_path, parsed.items.items),
        .html => try renderHtml(allocator, rel_path, parsed.items.items),
    };
    defer allocator.free(rendered);

    const out_rel = try replaceExt(allocator, rel_path, out_ext);
    // out_rel ownership transferred into index_entries on success.
    errdefer allocator.free(out_rel);

    if (std.fs.path.dirname(out_rel)) |sub| {
        const joined = try std.fs.path.join(allocator, &.{ out_dir, sub });
        defer allocator.free(joined);
        std.fs.cwd().makePath(joined) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
    }

    const out_full = try std.fs.path.join(allocator, &.{ out_dir, out_rel });
    defer allocator.free(out_full);
    try std.fs.cwd().writeFile(.{ .sub_path = out_full, .data = rendered });
    written.* += 1;

    try index_entries.append(allocator, .{ .rel_path = out_rel });
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

// ---------- Markdown rendering ----------

fn renderMarkdown(allocator: std.mem.Allocator, module_path: []const u8, items: []const Item) ![]u8 {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    try out.appendSlice(allocator, "# ");
    try out.appendSlice(allocator, module_path);
    try out.appendSlice(allocator, "\n\n");

    try emitMarkdownSection(allocator, &out, "Traits", items, .trait_decl);
    try emitMarkdownSection(allocator, &out, "Functions", items, .fn_decl);
    try emitMarkdownSection(allocator, &out, "Owned Structs", items, .owned_struct);
    try emitMarkdownSection(allocator, &out, "Structs", items, .struct_decl);
    try emitMarkdownSection(allocator, &out, "Extern Interfaces", items, .extern_interface);

    return out.toOwnedSlice(allocator);
}

fn emitMarkdownSection(allocator: std.mem.Allocator, out: *std.ArrayList(u8), title: []const u8, items: []const Item, kind: ItemKind) !void {
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

// ---------- HTML rendering ----------

const html_css =
    \\:root { color-scheme: light dark; }
    \\* { box-sizing: border-box; }
    \\body {
    \\  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
    \\  line-height: 1.55;
    \\  max-width: 80ch;
    \\  margin: 2rem auto;
    \\  padding: 0 1rem;
    \\  color: #222;
    \\  background: #fafafa;
    \\}
    \\@media (prefers-color-scheme: dark) {
    \\  body { color: #ddd; background: #181818; }
    \\  a { color: #6cf; }
    \\  pre { background: #222 !important; border-color: #333 !important; }
    \\  h1, h2, h3 { border-color: #333 !important; }
    \\}
    \\h1 { font-size: 1.8rem; border-bottom: 1px solid #ddd; padding-bottom: 0.3rem; }
    \\h2 { font-size: 1.3rem; margin-top: 2rem; border-bottom: 1px solid #eee; padding-bottom: 0.2rem; }
    \\h3 { font-size: 1.05rem; margin-top: 1.5rem; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
    \\pre {
    \\  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    \\  font-size: 0.92rem;
    \\  background: #f3f3f3;
    \\  border: 1px solid #e0e0e0;
    \\  border-radius: 4px;
    \\  padding: 0.6rem 0.8rem;
    \\  overflow-x: auto;
    \\  white-space: pre-wrap;
    \\  word-break: break-word;
    \\}
    \\nav.toc { background: rgba(127,127,127,0.08); padding: 0.6rem 1rem; border-radius: 4px; margin-bottom: 1.5rem; }
    \\nav.toc ul { margin: 0.3rem 0 0 0; padding-left: 1.2rem; }
    \\nav.toc li { margin: 0.1rem 0; }
    \\nav.toc h2 { font-size: 1rem; margin: 0; border: none; padding: 0; }
    \\a { text-decoration: none; }
    \\a:hover { text-decoration: underline; }
    \\p { margin: 0.4rem 0 1rem 0; }
    \\.kind { color: #888; font-weight: normal; font-size: 0.85em; margin-right: 0.4em; }
    \\
;

fn kindLabel(kind: ItemKind) []const u8 {
    return switch (kind) {
        .trait_decl => "trait",
        .fn_decl => "fn",
        .owned_struct => "owned struct",
        .struct_decl => "struct",
        .extern_interface => "extern interface",
    };
}

fn kindAnchorPrefix(kind: ItemKind) []const u8 {
    return switch (kind) {
        .trait_decl => "trait",
        .fn_decl => "fn",
        .owned_struct => "owned-struct",
        .struct_decl => "struct",
        .extern_interface => "extern-interface",
    };
}

fn writeEscaped(allocator: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '&' => try out.appendSlice(allocator, "&amp;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\'' => try out.appendSlice(allocator, "&#39;"),
            else => try out.append(allocator, c),
        }
    }
}

/// For id="..." attributes: keep alnum, dash, underscore; escape everything else as `_`.
fn writeAnchorSafe(allocator: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
        if (ok) {
            try out.append(allocator, c);
        } else {
            try out.append(allocator, '_');
        }
    }
}

fn renderHtml(allocator: std.mem.Allocator, module_path: []const u8, items: []const Item) ![]u8 {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    try out.appendSlice(allocator, "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n");
    try out.appendSlice(allocator, "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n");
    try out.appendSlice(allocator, "<title>");
    try writeEscaped(allocator, &out, module_path);
    try out.appendSlice(allocator, " — zpp doc</title>\n<style>\n");
    try out.appendSlice(allocator, html_css);
    try out.appendSlice(allocator, "</style>\n</head>\n<body>\n");

    try out.appendSlice(allocator, "<h1>");
    try writeEscaped(allocator, &out, module_path);
    try out.appendSlice(allocator, "</h1>\n");

    // Table of contents.
    if (items.len > 0) {
        try out.appendSlice(allocator, "<nav class=\"toc\"><h2>Contents</h2>\n<ul>\n");
        const sections = [_]struct { title: []const u8, kind: ItemKind }{
            .{ .title = "Traits", .kind = .trait_decl },
            .{ .title = "Functions", .kind = .fn_decl },
            .{ .title = "Owned Structs", .kind = .owned_struct },
            .{ .title = "Structs", .kind = .struct_decl },
            .{ .title = "Extern Interfaces", .kind = .extern_interface },
        };
        for (sections) |s| {
            var any = false;
            for (items) |it| {
                if (it.kind != s.kind) continue;
                if (!any) {
                    try out.appendSlice(allocator, "  <li><strong>");
                    try writeEscaped(allocator, &out, s.title);
                    try out.appendSlice(allocator, "</strong><ul>\n");
                    any = true;
                }
                try out.appendSlice(allocator, "    <li><a href=\"#");
                try writeAnchorSafe(allocator, &out, kindAnchorPrefix(it.kind));
                try out.append(allocator, '-');
                try writeAnchorSafe(allocator, &out, it.name);
                try out.appendSlice(allocator, "\">");
                try writeEscaped(allocator, &out, it.name);
                try out.appendSlice(allocator, "</a></li>\n");
            }
            if (any) try out.appendSlice(allocator, "  </ul></li>\n");
        }
        try out.appendSlice(allocator, "</ul>\n</nav>\n");
    }

    try emitHtmlSection(allocator, &out, "Traits", items, .trait_decl);
    try emitHtmlSection(allocator, &out, "Functions", items, .fn_decl);
    try emitHtmlSection(allocator, &out, "Owned Structs", items, .owned_struct);
    try emitHtmlSection(allocator, &out, "Structs", items, .struct_decl);
    try emitHtmlSection(allocator, &out, "Extern Interfaces", items, .extern_interface);

    try out.appendSlice(allocator, "</body>\n</html>\n");

    return out.toOwnedSlice(allocator);
}

fn emitHtmlSection(allocator: std.mem.Allocator, out: *std.ArrayList(u8), title: []const u8, items: []const Item, kind: ItemKind) !void {
    var any = false;
    for (items) |it| {
        if (it.kind != kind) continue;
        if (!any) {
            try out.appendSlice(allocator, "<section>\n<h2>");
            try writeEscaped(allocator, out, title);
            try out.appendSlice(allocator, "</h2>\n");
            any = true;
        }
        try out.appendSlice(allocator, "<h3 id=\"");
        try writeAnchorSafe(allocator, out, kindAnchorPrefix(it.kind));
        try out.append(allocator, '-');
        try writeAnchorSafe(allocator, out, it.name);
        try out.appendSlice(allocator, "\"><span class=\"kind\">");
        try writeEscaped(allocator, out, kindLabel(it.kind));
        try out.appendSlice(allocator, "</span>");
        try writeEscaped(allocator, out, it.name);
        try out.appendSlice(allocator, "</h3>\n");

        try out.appendSlice(allocator, "<pre>");
        try writeEscaped(allocator, out, it.signature);
        try out.appendSlice(allocator, "</pre>\n");

        if (it.docs.len > 0) {
            // Render each non-empty paragraph (separated by blank lines) as <p>.
            const trimmed = std.mem.trim(u8, it.docs, " \t\r\n");
            var para_iter = std.mem.splitSequence(u8, trimmed, "\n\n");
            while (para_iter.next()) |para| {
                const para_trim = std.mem.trim(u8, para, " \t\r\n");
                if (para_trim.len == 0) continue;
                try out.appendSlice(allocator, "<p>");
                try writeEscaped(allocator, out, para_trim);
                try out.appendSlice(allocator, "</p>\n");
            }
        }
    }
    if (any) try out.appendSlice(allocator, "</section>\n");
}

fn writeIndexHtml(allocator: std.mem.Allocator, out_dir: []const u8, entries: []const IndexEntry) !void {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    try out.appendSlice(allocator, "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n");
    try out.appendSlice(allocator, "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n");
    try out.appendSlice(allocator, "<title>zpp doc — Index</title>\n<style>\n");
    try out.appendSlice(allocator, html_css);
    try out.appendSlice(allocator, "</style>\n</head>\n<body>\n");
    try out.appendSlice(allocator, "<h1>Index</h1>\n");

    if (entries.len == 0) {
        try out.appendSlice(allocator, "<p><em>No documented sources found.</em></p>\n");
    } else {
        try out.appendSlice(allocator, "<ul>\n");
        for (entries) |e| {
            // Normalize backslashes (Windows) to forward slashes for href.
            try out.appendSlice(allocator, "  <li><a href=\"");
            for (e.rel_path) |c| {
                const ch: u8 = if (c == '\\') '/' else c;
                switch (ch) {
                    '<' => try out.appendSlice(allocator, "&lt;"),
                    '>' => try out.appendSlice(allocator, "&gt;"),
                    '&' => try out.appendSlice(allocator, "&amp;"),
                    '"' => try out.appendSlice(allocator, "&quot;"),
                    else => try out.append(allocator, ch),
                }
            }
            try out.appendSlice(allocator, "\">");
            try writeEscaped(allocator, &out, e.rel_path);
            try out.appendSlice(allocator, "</a></li>\n");
        }
        try out.appendSlice(allocator, "</ul>\n");
    }

    try out.appendSlice(allocator, "</body>\n</html>\n");

    const index_full = try std.fs.path.join(allocator, &.{ out_dir, "index.html" });
    defer allocator.free(index_full);
    try std.fs.cwd().writeFile(.{ .sub_path = index_full, .data = out.items });
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

test "renderHtml escapes generics and emits anchors" {
    const a = std.testing.allocator;
    const items = [_]Item{
        .{
            .kind = .trait_decl,
            .name = try a.dupe(u8, "Greeter"),
            .signature = try a.dupe(u8, "trait Greeter(T) { fn say(self: *Self, msg: []const u8) void; }"),
            .docs = try a.dupe(u8, "Greets a T.\n"),
        },
        .{
            .kind = .fn_decl,
            .name = try a.dupe(u8, "make"),
            .signature = try a.dupe(u8, "fn make(x: []const u8) Foo"),
            .docs = try a.dupe(u8, "Builds a Foo & returns it.\n"),
        },
    };
    defer {
        for (items) |it| {
            a.free(it.name);
            a.free(it.signature);
            a.free(it.docs);
        }
    }
    const html = try renderHtml(a, "demo.zpp", &items);
    defer a.free(html);

    // Doctype + body wrappers
    try std.testing.expect(std.mem.indexOf(u8, html, "<!doctype html>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<style>") != null);
    // Section h2s for both kinds present
    try std.testing.expect(std.mem.indexOf(u8, html, "<h2>Traits</h2>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<h2>Functions</h2>") != null);
    // Anchors
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"trait-Greeter\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"fn-make\"") != null);
    // ToC links
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"#trait-Greeter\"") != null);
    // Escaping: `[]const u8` and `&` must be escaped in <pre>
    try std.testing.expect(std.mem.indexOf(u8, html, "[]const u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "&amp;") != null);
    // Raw `<` from a hypothetical generic must NOT survive un-escaped inside an attribute or pre.
    // (Our test signatures don't contain `<`, but make sure no stray `<T>` text appears as element.)
    try std.testing.expect(std.mem.indexOf(u8, html, "<T>") == null);
}

test "html smoke: walk a tmp dir + writeIndexHtml produces demo.html and index.html" {
    // Bypasses runDoc on purpose: runDoc writes a status line to stdout,
    // which corrupts the `zig test --listen=-` IPC channel and stalls the
    // test runner. Drive the file-emitting helpers directly instead.
    const a = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const src =
        \\/// A reader trait.
        \\trait Reader {
        \\    fn read(self: *Self) usize;
        \\}
        \\
        \\/// A free function.
        \\fn helper(x: u32) u32 {
        \\    return x;
        \\}
        \\
    ;
    try tmp.dir.writeFile(.{ .sub_path = "demo.zpp", .data = src });

    const src_abs = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(src_abs);

    const out_abs = try std.fs.path.join(a, &.{ src_abs, "out_html" });
    defer a.free(out_abs);
    try std.fs.cwd().makePath(out_abs);

    var index_entries = std.ArrayList(IndexEntry){};
    defer {
        for (index_entries.items) |e| a.free(e.rel_path);
        index_entries.deinit(a);
    }

    var written: usize = 0;
    try walkAndDoc(a, src_abs, out_abs, .html, &written, &index_entries);
    try std.testing.expect(written >= 1);

    try writeIndexHtml(a, out_abs, index_entries.items);

    var out_dir = try std.fs.cwd().openDir(out_abs, .{});
    defer out_dir.close();

    const html_bytes = try out_dir.readFileAlloc(a, "demo.html", 1 * 1024 * 1024);
    defer a.free(html_bytes);
    try std.testing.expect(std.mem.indexOf(u8, html_bytes, "<!doctype html>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html_bytes, "id=\"trait-Reader\"") != null);

    const index_bytes = try out_dir.readFileAlloc(a, "index.html", 1 * 1024 * 1024);
    defer a.free(index_bytes);
    try std.testing.expect(std.mem.indexOf(u8, index_bytes, "demo.html") != null);
}
