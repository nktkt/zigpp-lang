const std = @import("std");

pub const FormatOptions = struct {
    check_only: bool = false,
};

const indent_unit: []const u8 = "    ";

/// Recognised Zig++ keywords that should always be followed by a space.
const zpp_keywords = [_][]const u8{
    "trait",      "impl",     "dyn",       "using",
    "owned",      "own",      "move",      "where",
    "requires",   "ensures",  "effects",   "derive",
    "extern",     "interface",
    "fn",         "pub",      "const",     "var",
    "struct",     "enum",     "union",     "if",
    "else",       "while",    "for",       "switch",
    "return",     "break",    "continue",  "defer",
    "errdefer",   "try",      "catch",     "comptime",
    "inline",     "test",     "and",       "or",
    "orelse",     "anytype",  "anyerror",  "asm",
    "unreachable","nosuspend","threadlocal","import",
};

fn isKeyword(s: []const u8) bool {
    for (zpp_keywords) |kw| {
        if (std.mem.eql(u8, kw, s)) return true;
    }
    return false;
}

fn isIdentStart(c: u8) bool {
    return c == '_' or std.ascii.isAlphabetic(c);
}

fn isIdentCont(c: u8) bool {
    return c == '_' or std.ascii.isAlphanumeric(c);
}

const TokenKind = enum {
    eof,
    word,
    number,
    string,
    char,
    line_comment,
    doc_comment,
    punct,
    newline,
    open_brace,
    close_brace,
    semi,
};

const Token = struct {
    kind: TokenKind,
    text: []const u8,
};

const Lexer = struct {
    src: []const u8,
    i: usize = 0,

    fn peek(self: *Lexer) u8 {
        return if (self.i < self.src.len) self.src[self.i] else 0;
    }

    fn next(self: *Lexer) Token {
        while (self.i < self.src.len) {
            const c = self.src[self.i];
            if (c == ' ' or c == '\t' or c == '\r') {
                self.i += 1;
                continue;
            }
            break;
        }
        if (self.i >= self.src.len) return .{ .kind = .eof, .text = "" };

        const start = self.i;
        const c = self.src[self.i];

        if (c == '\n') {
            self.i += 1;
            return .{ .kind = .newline, .text = self.src[start..self.i] };
        }
        if (c == '{') {
            self.i += 1;
            return .{ .kind = .open_brace, .text = "{" };
        }
        if (c == '}') {
            self.i += 1;
            return .{ .kind = .close_brace, .text = "}" };
        }
        if (c == ';') {
            self.i += 1;
            return .{ .kind = .semi, .text = ";" };
        }
        if (c == '/' and self.i + 1 < self.src.len and self.src[self.i + 1] == '/') {
            const is_doc = self.i + 2 < self.src.len and self.src[self.i + 2] == '/';
            while (self.i < self.src.len and self.src[self.i] != '\n') : (self.i += 1) {}
            return .{
                .kind = if (is_doc) .doc_comment else .line_comment,
                .text = self.src[start..self.i],
            };
        }
        if (c == '"') {
            self.i += 1;
            while (self.i < self.src.len) : (self.i += 1) {
                const ch = self.src[self.i];
                if (ch == '\\' and self.i + 1 < self.src.len) {
                    self.i += 1;
                    continue;
                }
                if (ch == '"') {
                    self.i += 1;
                    break;
                }
                if (ch == '\n') break;
            }
            return .{ .kind = .string, .text = self.src[start..self.i] };
        }
        if (c == '\'') {
            self.i += 1;
            while (self.i < self.src.len) : (self.i += 1) {
                const ch = self.src[self.i];
                if (ch == '\\' and self.i + 1 < self.src.len) {
                    self.i += 1;
                    continue;
                }
                if (ch == '\'') {
                    self.i += 1;
                    break;
                }
                if (ch == '\n') break;
            }
            return .{ .kind = .char, .text = self.src[start..self.i] };
        }
        if (isIdentStart(c) or c == '@') {
            self.i += 1;
            while (self.i < self.src.len and isIdentCont(self.src[self.i])) : (self.i += 1) {}
            return .{ .kind = .word, .text = self.src[start..self.i] };
        }
        if (std.ascii.isDigit(c)) {
            self.i += 1;
            while (self.i < self.src.len and (std.ascii.isAlphanumeric(self.src[self.i]) or self.src[self.i] == '.' or self.src[self.i] == '_')) : (self.i += 1) {}
            return .{ .kind = .number, .text = self.src[start..self.i] };
        }
        // generic punctuation: greedy 1–2 char operators
        const two = if (self.i + 1 < self.src.len) self.src[self.i..self.i + 2] else self.src[self.i..self.i + 1];
        const ops2 = [_][]const u8{ "==", "!=", "<=", ">=", "->", "=>", "++", "+=", "-=", "*=", "/=", "%=", "&&", "||", "::", "..", "<<", ">>", "&=", "|=", "^=" };
        for (ops2) |op| {
            if (std.mem.eql(u8, op, two)) {
                self.i += 2;
                return .{ .kind = .punct, .text = self.src[start..self.i] };
            }
        }
        self.i += 1;
        return .{ .kind = .punct, .text = self.src[start..self.i] };
    }
};

/// Format a single .zpp source. The result is owned by the caller.
pub fn formatSource(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    var lex = Lexer{ .src = source };
    var indent: usize = 0;
    var at_line_start = true;
    var pending_newlines: usize = 0;
    var prev_kind: TokenKind = .newline;
    var prev_text: []const u8 = "";
    var top_level_decl_just_closed = false;
    var saw_any_token = false;

    while (true) {
        const tok = lex.next();
        if (tok.kind == .eof) break;

        if (tok.kind == .newline) {
            pending_newlines += 1;
            continue;
        }

        if (tok.kind == .close_brace) {
            if (indent > 0) indent -= 1;
        }

        // Decide newline budget when transitioning to a new logical line.
        if (pending_newlines > 0) {
            var n = pending_newlines;
            if (indent == 0 and top_level_decl_just_closed) {
                if (n < 2) n = 2;
            } else if (n > 2) n = 2;
            var k: usize = 0;
            while (k < n) : (k += 1) try out.append(allocator, '\n');
            at_line_start = true;
            pending_newlines = 0;
            top_level_decl_just_closed = false;
        }

        if (at_line_start) {
            var k: usize = 0;
            while (k < indent) : (k += 1) try out.appendSlice(allocator, indent_unit);
            at_line_start = false;
        } else if (saw_any_token) {
            if (needsSpace(prev_kind, prev_text, tok.kind, tok.text)) {
                try out.append(allocator, ' ');
            }
        }

        try out.appendSlice(allocator, tok.text);

        if (tok.kind == .open_brace) indent += 1;
        if (tok.kind == .close_brace and indent == 0) {
            top_level_decl_just_closed = true;
        }
        prev_kind = tok.kind;
        prev_text = tok.text;
        saw_any_token = true;
    }
    if (out.items.len == 0 or out.items[out.items.len - 1] != '\n') {
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

fn needsSpace(prev_kind: TokenKind, prev: []const u8, kind: TokenKind, text: []const u8) bool {
    if (prev_kind == .newline) return false;

    // Never a space immediately before these tokens.
    if (kind == .punct) {
        if (text.len == 1) {
            switch (text[0]) {
                ',', ';', ')', ']', '.', ':' => return false,
                else => {},
            }
        }
        if (std.mem.eql(u8, text, "::")) return false;
        if (std.mem.eql(u8, text, "..")) return false;
    }
    if (kind == .semi) return false;
    if (kind == .close_brace) return true;

    // Never a space immediately after these.
    if (prev_kind == .punct) {
        if (prev.len == 1) {
            switch (prev[0]) {
                '(', '[', '.', '!', '~', '@' => return false,
                else => {},
            }
        }
        if (std.mem.eql(u8, prev, "::")) return false;
    }
    if (prev_kind == .open_brace) return true;
    if (prev_kind == .close_brace) return true;

    if (prev_kind == .word and isKeyword(prev)) return true;
    if (kind == .word and isKeyword(text)) return true;

    if (prev_kind == .word and (kind == .punct and prev.len > 0 and text.len == 1 and (text[0] == '(' or text[0] == '['))) return false;

    return true;
}

/// Expand path (file or directory) and format every .zpp underneath.
pub fn formatPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    opts: FormatOptions,
    changed: *usize,
    processed: *usize,
) !void {
    const stat = std.fs.cwd().statFile(path) catch |e| {
        try emitError("zpp fmt: cannot stat '{s}': {s}\n", .{ path, @errorName(e) });
        return;
    };
    if (stat.kind == .directory) {
        var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
        defer dir.close();
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".zpp")) continue;
            const full = try std.fs.path.join(allocator, &.{ path, entry.path });
            defer allocator.free(full);
            try formatOne(allocator, full, opts, changed, processed);
        }
    } else {
        try formatOne(allocator, path, opts, changed, processed);
    }
}

fn formatOne(
    allocator: std.mem.Allocator,
    path: []const u8,
    opts: FormatOptions,
    changed: *usize,
    processed: *usize,
) !void {
    const source = std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024) catch |e| {
        try emitError("zpp fmt: cannot read '{s}': {s}\n", .{ path, @errorName(e) });
        return;
    };
    defer allocator.free(source);

    const formatted = try formatSource(allocator, source);
    defer allocator.free(formatted);

    processed.* += 1;
    if (!std.mem.eql(u8, source, formatted)) {
        changed.* += 1;
        if (opts.check_only) {
            try emitError("zpp fmt: '{s}' would be reformatted\n", .{path});
            return;
        }
        try std.fs.cwd().writeFile(.{ .sub_path = path, .data = formatted });
    }
}

fn emitError(comptime fmt: []const u8, args: anytype) !void {
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

    var opts = FormatOptions{};
    var paths = std.ArrayList([]const u8){};
    defer paths.deinit(allocator);

    for (argv[1..]) |a| {
        if (std.mem.eql(u8, a, "--check")) {
            opts.check_only = true;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            try emitError("zpp-fmt [--check] [paths...]\n", .{});
            return;
        } else {
            try paths.append(allocator, a);
        }
    }
    if (paths.items.len == 0) try paths.append(allocator, ".");

    var changed: usize = 0;
    var processed: usize = 0;
    for (paths.items) |p| {
        try formatPath(allocator, p, opts, &changed, &processed);
    }
    if (opts.check_only and changed > 0) std.process.exit(1);
}

test "formatSource collapses extra blank lines and indents braces" {
    const a = std.testing.allocator;
    const src = "fn   main()  {\n\n\n    return 1 ;\n}\n";
    const out = try formatSource(a, src);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "return 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "fn main()") != null);
}

test "formatSource preserves doc comments and keywords" {
    const a = std.testing.allocator;
    const src = "/// a docstring\ntrait Foo {\nfn bar() void;\n}\n";
    const out = try formatSource(a, src);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "/// a docstring") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "trait Foo") != null);
}
