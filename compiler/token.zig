const std = @import("std");
const diag = @import("diagnostics.zig");

pub const TokenKind = enum {
    // Literals & identifiers
    ident,
    int_literal,
    float_literal,
    string_literal,
    char_literal,
    builtin_ident, // @foo
    doc_comment,
    line_comment,

    // Punctuation
    l_paren,
    r_paren,
    l_brace,
    r_brace,
    l_bracket,
    r_bracket,
    semicolon,
    colon,
    comma,
    dot,
    dot_dot,
    dot_dot_dot,
    dot_star,
    dot_question,
    dot_brace, // .{
    arrow, // ->
    fat_arrow, // =>
    question,
    bang,
    ampersand,
    pipe,
    caret,
    tilde,
    plus,
    minus,
    star,
    slash,
    percent,
    eq,
    eq_eq,
    bang_eq,
    lt,
    gt,
    lt_eq,
    gt_eq,
    lt_lt,
    gt_gt,
    plus_eq,
    minus_eq,
    star_eq,
    slash_eq,
    pipe_pipe,
    amp_amp,
    at,

    // Existing Zig keywords (subset we may care about)
    kw_const,
    kw_var,
    kw_fn,
    kw_pub,
    kw_struct,
    kw_enum,
    kw_union,
    kw_return,
    kw_if,
    kw_else,
    kw_while,
    kw_for,
    kw_switch,
    kw_break,
    kw_continue,
    kw_defer,
    kw_errdefer,
    kw_try,
    kw_catch,
    kw_orelse,
    kw_test,
    kw_comptime,
    kw_inline,
    kw_extern,
    kw_export,
    kw_unreachable,
    kw_null,
    kw_true,
    kw_false,
    kw_and,
    kw_or,
    kw_anytype,

    // New Zig++ keywords
    kw_trait,
    kw_impl,
    kw_for_kw, // intentionally unused; alias of kw_for
    kw_dyn,
    kw_using,
    kw_owned,
    kw_own,
    kw_move,
    kw_where,
    kw_requires,
    kw_ensures,
    kw_invariant,
    kw_effects,
    kw_derive,
    kw_interface,

    eof,
    invalid,
};

pub const Token = struct {
    kind: TokenKind,
    span: diag.Span,

    pub fn slice(self: Token, source: []const u8) []const u8 {
        return source[self.span.start..self.span.end];
    }
};

pub const Keyword = struct { name: []const u8, kind: TokenKind };

pub const keywords = [_]Keyword{
    .{ .name = "const", .kind = .kw_const },
    .{ .name = "var", .kind = .kw_var },
    .{ .name = "fn", .kind = .kw_fn },
    .{ .name = "pub", .kind = .kw_pub },
    .{ .name = "struct", .kind = .kw_struct },
    .{ .name = "enum", .kind = .kw_enum },
    .{ .name = "union", .kind = .kw_union },
    .{ .name = "return", .kind = .kw_return },
    .{ .name = "if", .kind = .kw_if },
    .{ .name = "else", .kind = .kw_else },
    .{ .name = "while", .kind = .kw_while },
    .{ .name = "for", .kind = .kw_for },
    .{ .name = "switch", .kind = .kw_switch },
    .{ .name = "break", .kind = .kw_break },
    .{ .name = "continue", .kind = .kw_continue },
    .{ .name = "defer", .kind = .kw_defer },
    .{ .name = "errdefer", .kind = .kw_errdefer },
    .{ .name = "try", .kind = .kw_try },
    .{ .name = "catch", .kind = .kw_catch },
    .{ .name = "orelse", .kind = .kw_orelse },
    .{ .name = "test", .kind = .kw_test },
    .{ .name = "comptime", .kind = .kw_comptime },
    .{ .name = "inline", .kind = .kw_inline },
    .{ .name = "extern", .kind = .kw_extern },
    .{ .name = "export", .kind = .kw_export },
    .{ .name = "unreachable", .kind = .kw_unreachable },
    .{ .name = "null", .kind = .kw_null },
    .{ .name = "true", .kind = .kw_true },
    .{ .name = "false", .kind = .kw_false },
    .{ .name = "and", .kind = .kw_and },
    .{ .name = "or", .kind = .kw_or },
    .{ .name = "anytype", .kind = .kw_anytype },

    .{ .name = "trait", .kind = .kw_trait },
    .{ .name = "impl", .kind = .kw_impl },
    .{ .name = "dyn", .kind = .kw_dyn },
    .{ .name = "using", .kind = .kw_using },
    .{ .name = "owned", .kind = .kw_owned },
    .{ .name = "own", .kind = .kw_own },
    .{ .name = "move", .kind = .kw_move },
    .{ .name = "where", .kind = .kw_where },
    .{ .name = "requires", .kind = .kw_requires },
    .{ .name = "ensures", .kind = .kw_ensures },
    .{ .name = "invariant", .kind = .kw_invariant },
    .{ .name = "effects", .kind = .kw_effects },
    .{ .name = "derive", .kind = .kw_derive },
    .{ .name = "interface", .kind = .kw_interface },
};

fn lookupKeyword(s: []const u8) ?TokenKind {
    inline for (keywords) |kw| {
        if (std.mem.eql(u8, kw.name, s)) return kw.kind;
    }
    return null;
}

/// Public identifier-byte predicates so tools (LSP, formatters) can locate
/// identifiers in source text without re-tokenizing the whole file.
pub fn identStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

pub fn identCont(c: u8) bool {
    return identStart(c) or (c >= '0' and c <= '9');
}

pub const Lexer = struct {
    source: []const u8,
    pos: u32 = 0,
    diags: *diag.Diagnostics,

    pub fn init(source: []const u8, diags: *diag.Diagnostics) Lexer {
        return .{ .source = source, .diags = diags };
    }

    fn peek(self: *Lexer) u8 {
        if (self.pos >= self.source.len) return 0;
        return self.source[self.pos];
    }

    fn peekAt(self: *Lexer, off: u32) u8 {
        const p = self.pos + off;
        if (p >= self.source.len) return 0;
        return self.source[p];
    }

    fn advance(self: *Lexer) u8 {
        const c = self.peek();
        self.pos += 1;
        return c;
    }

    fn matchByte(self: *Lexer, c: u8) bool {
        if (self.peek() == c) {
            self.pos += 1;
            return true;
        }
        return false;
    }

    fn skipTrivia(self: *Lexer) void {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            switch (c) {
                ' ', '\t', '\r', '\n' => self.pos += 1,
                else => return,
            }
        }
    }

    fn isIdentStart(c: u8) bool {
        return identStart(c);
    }

    fn isIdentCont(c: u8) bool {
        return identCont(c);
    }

    fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    fn lexIdent(self: *Lexer, start: u32) Token {
        while (self.pos < self.source.len and isIdentCont(self.source[self.pos])) self.pos += 1;
        const text = self.source[start..self.pos];
        const kind: TokenKind = lookupKeyword(text) orelse .ident;
        return .{ .kind = kind, .span = .{ .start = start, .end = self.pos } };
    }

    fn lexNumber(self: *Lexer, start: u32) Token {
        var is_float = false;
        // hex / bin / oct prefix
        if (self.source[start] == '0' and self.pos < self.source.len) {
            const p = self.source[self.pos];
            if (p == 'x' or p == 'X' or p == 'b' or p == 'B' or p == 'o' or p == 'O') {
                self.pos += 1;
                while (self.pos < self.source.len) {
                    const c = self.source[self.pos];
                    if (isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F') or c == '_') {
                        self.pos += 1;
                    } else break;
                }
                return .{ .kind = .int_literal, .span = .{ .start = start, .end = self.pos } };
            }
        }
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (isDigit(c) or c == '_') {
                self.pos += 1;
            } else if (c == '.' and self.pos + 1 < self.source.len and isDigit(self.source[self.pos + 1]) and !is_float) {
                is_float = true;
                self.pos += 1;
            } else if ((c == 'e' or c == 'E') and !is_float) {
                is_float = true;
                self.pos += 1;
                if (self.pos < self.source.len and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) {
                    self.pos += 1;
                }
            } else break;
        }
        return .{
            .kind = if (is_float) .float_literal else .int_literal,
            .span = .{ .start = start, .end = self.pos },
        };
    }

    fn lexString(self: *Lexer, start: u32) !Token {
        // assumes opening " already consumed
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == '\\' and self.pos + 1 < self.source.len) {
                self.pos += 2;
                continue;
            }
            if (c == '"') {
                self.pos += 1;
                return Token{ .kind = .string_literal, .span = .{ .start = start, .end = self.pos } };
            }
            if (c == '\n') break;
            self.pos += 1;
        }
        try self.diags.emit(
            .err,
            .z0201_unterminated_string,
            .{ .start = start, .end = self.pos },
            "unterminated string literal",
            .{},
        );
        return Token{ .kind = .invalid, .span = .{ .start = start, .end = self.pos } };
    }

    /// Caller has already advanced past the first backslash; pos points at
    /// the second one. Consume until end-of-line, then peek the next
    /// non-whitespace start-of-line: if it begins with `\\`, fold it in.
    fn lexMultilineString(self: *Lexer, start: u32) Token {
        // Consume the second '\' of the opening pair.
        self.pos += 1;
        // First line's content: skip until '\n'.
        while (self.pos < self.source.len and self.source[self.pos] != '\n') {
            self.pos += 1;
        }
        // Greedy fold: while the next line (after leading whitespace) also
        // starts with `\\`, include it.
        while (self.pos < self.source.len and self.source[self.pos] == '\n') {
            const save = self.pos;
            self.pos += 1; // consume \n
            // Skip spaces / tabs.
            while (self.pos < self.source.len and (self.source[self.pos] == ' ' or self.source[self.pos] == '\t')) {
                self.pos += 1;
            }
            if (self.pos + 1 < self.source.len and self.source[self.pos] == '\\' and self.source[self.pos + 1] == '\\') {
                self.pos += 2;
                while (self.pos < self.source.len and self.source[self.pos] != '\n') {
                    self.pos += 1;
                }
                continue;
            }
            // Not a continuation — restore pos to before the newline.
            self.pos = save;
            break;
        }
        return Token{ .kind = .string_literal, .span = .{ .start = start, .end = self.pos } };
    }

    fn lexChar(self: *Lexer, start: u32) Token {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == '\\' and self.pos + 1 < self.source.len) {
                self.pos += 2;
                continue;
            }
            if (c == '\'') {
                self.pos += 1;
                return .{ .kind = .char_literal, .span = .{ .start = start, .end = self.pos } };
            }
            if (c == '\n') break;
            self.pos += 1;
        }
        return .{ .kind = .invalid, .span = .{ .start = start, .end = self.pos } };
    }

    fn lexLineComment(self: *Lexer, start: u32) Token {
        var kind: TokenKind = .line_comment;
        if (self.pos < self.source.len and self.source[self.pos] == '/') {
            kind = .doc_comment;
            self.pos += 1;
        }
        while (self.pos < self.source.len and self.source[self.pos] != '\n') self.pos += 1;
        return .{ .kind = kind, .span = .{ .start = start, .end = self.pos } };
    }

    /// Yield the next token. EOF is sticky.
    pub fn next(self: *Lexer) !Token {
        self.skipTrivia();
        const start = self.pos;
        if (self.pos >= self.source.len) {
            return .{ .kind = .eof, .span = .{ .start = start, .end = start } };
        }
        const c = self.advance();
        switch (c) {
            '(' => return tok(.l_paren, start, self.pos),
            ')' => return tok(.r_paren, start, self.pos),
            '{' => return tok(.l_brace, start, self.pos),
            '}' => return tok(.r_brace, start, self.pos),
            '[' => return tok(.l_bracket, start, self.pos),
            ']' => return tok(.r_bracket, start, self.pos),
            ';' => return tok(.semicolon, start, self.pos),
            ':' => return tok(.colon, start, self.pos),
            ',' => return tok(.comma, start, self.pos),
            '?' => return tok(.question, start, self.pos),
            '~' => return tok(.tilde, start, self.pos),
            '^' => return tok(.caret, start, self.pos),
            '@' => {
                if (self.pos < self.source.len and isIdentStart(self.source[self.pos])) {
                    while (self.pos < self.source.len and isIdentCont(self.source[self.pos])) self.pos += 1;
                    return tok(.builtin_ident, start, self.pos);
                }
                return tok(.at, start, self.pos);
            },
            '.' => {
                if (self.matchByte('.')) {
                    if (self.matchByte('.')) return tok(.dot_dot_dot, start, self.pos);
                    return tok(.dot_dot, start, self.pos);
                }
                if (self.matchByte('*')) return tok(.dot_star, start, self.pos);
                if (self.matchByte('?')) return tok(.dot_question, start, self.pos);
                if (self.matchByte('{')) return tok(.dot_brace, start, self.pos);
                return tok(.dot, start, self.pos);
            },
            '=' => {
                if (self.matchByte('=')) return tok(.eq_eq, start, self.pos);
                if (self.matchByte('>')) return tok(.fat_arrow, start, self.pos);
                return tok(.eq, start, self.pos);
            },
            '!' => {
                if (self.matchByte('=')) return tok(.bang_eq, start, self.pos);
                return tok(.bang, start, self.pos);
            },
            '<' => {
                if (self.matchByte('=')) return tok(.lt_eq, start, self.pos);
                if (self.matchByte('<')) return tok(.lt_lt, start, self.pos);
                return tok(.lt, start, self.pos);
            },
            '>' => {
                if (self.matchByte('=')) return tok(.gt_eq, start, self.pos);
                if (self.matchByte('>')) return tok(.gt_gt, start, self.pos);
                return tok(.gt, start, self.pos);
            },
            '+' => {
                if (self.matchByte('=')) return tok(.plus_eq, start, self.pos);
                return tok(.plus, start, self.pos);
            },
            '-' => {
                if (self.matchByte('=')) return tok(.minus_eq, start, self.pos);
                if (self.matchByte('>')) return tok(.arrow, start, self.pos);
                return tok(.minus, start, self.pos);
            },
            '*' => {
                if (self.matchByte('=')) return tok(.star_eq, start, self.pos);
                return tok(.star, start, self.pos);
            },
            '/' => {
                if (self.matchByte('/')) return self.lexLineComment(start);
                if (self.matchByte('=')) return tok(.slash_eq, start, self.pos);
                return tok(.slash, start, self.pos);
            },
            '%' => return tok(.percent, start, self.pos),
            '|' => {
                if (self.matchByte('|')) return tok(.pipe_pipe, start, self.pos);
                return tok(.pipe, start, self.pos);
            },
            '&' => {
                if (self.matchByte('&')) return tok(.amp_amp, start, self.pos);
                return tok(.ampersand, start, self.pos);
            },
            '"' => return try self.lexString(start),
            '\'' => return self.lexChar(start),
            '\\' => {
                // `\\...\n` (Zig's multi-line string form). Consecutive
                // `\\`-prefixed lines fold into one string_literal token so
                // the parser sees them as a single string and lowering
                // passes them through verbatim.
                if (self.pos < self.source.len and self.source[self.pos] == '\\') {
                    return self.lexMultilineString(start);
                }
                // Stray single backslash falls through to the invalid-char
                // diagnostic below.
                try self.diags.emit(
                    .err,
                    .z0200_invalid_char,
                    .{ .start = start, .end = self.pos },
                    "invalid character: 0x{x:0>2}",
                    .{c},
                );
                return tok(.invalid, start, self.pos);
            },
            else => {
                if (isIdentStart(c)) return self.lexIdent(start);
                if (isDigit(c)) return self.lexNumber(start);
                try self.diags.emit(
                    .err,
                    .z0200_invalid_char,
                    .{ .start = start, .end = self.pos },
                    "invalid character: 0x{x:0>2}",
                    .{c},
                );
                return tok(.invalid, start, self.pos);
            },
        }
    }

    /// Consume the entire source into an owned token list.
    pub fn tokenizeAll(self: *Lexer, allocator: std.mem.Allocator) !std.ArrayList(Token) {
        var list: std.ArrayList(Token) = .{};
        while (true) {
            const t = try self.next();
            try list.append(allocator, t);
            if (t.kind == .eof) return list;
        }
    }
};

inline fn tok(kind: TokenKind, start: u32, end: u32) Token {
    return .{ .kind = kind, .span = .{ .start = start, .end = end } };
}

test "lex trait declaration" {
    const a = std.testing.allocator;
    var diags = diag.Diagnostics.init(a);
    defer diags.deinit();
    const src = "trait Writer { fn write(self) !usize; }";
    var lx = Lexer.init(src, &diags);
    var list = try lx.tokenizeAll(a);
    defer list.deinit(a);

    try std.testing.expectEqual(TokenKind.kw_trait, list.items[0].kind);
    try std.testing.expectEqual(TokenKind.ident, list.items[1].kind);
    try std.testing.expectEqualStrings("Writer", list.items[1].slice(src));
    try std.testing.expectEqual(TokenKind.l_brace, list.items[2].kind);
    try std.testing.expectEqual(TokenKind.kw_fn, list.items[3].kind);
}

test "lex new keywords" {
    const a = std.testing.allocator;
    var diags = diag.Diagnostics.init(a);
    defer diags.deinit();
    const src = "owned own move using impl dyn where requires ensures effects derive";
    var lx = Lexer.init(src, &diags);
    var list = try lx.tokenizeAll(a);
    defer list.deinit(a);
    const expected = [_]TokenKind{
        .kw_owned, .kw_own, .kw_move, .kw_using, .kw_impl, .kw_dyn,
        .kw_where, .kw_requires, .kw_ensures, .kw_effects, .kw_derive, .eof,
    };
    try std.testing.expectEqual(expected.len, list.items.len);
    for (expected, 0..) |e, i| try std.testing.expectEqual(e, list.items[i].kind);
}

test "lex string and number" {
    const a = std.testing.allocator;
    var diags = diag.Diagnostics.init(a);
    defer diags.deinit();
    const src = "\"hello\" 42 0xFF 3.14";
    var lx = Lexer.init(src, &diags);
    var list = try lx.tokenizeAll(a);
    defer list.deinit(a);
    try std.testing.expectEqual(TokenKind.string_literal, list.items[0].kind);
    try std.testing.expectEqual(TokenKind.int_literal, list.items[1].kind);
    try std.testing.expectEqual(TokenKind.int_literal, list.items[2].kind);
    try std.testing.expectEqual(TokenKind.float_literal, list.items[3].kind);
}

test "lex multi-line string folds consecutive lines" {
    const a = std.testing.allocator;
    var diags = diag.Diagnostics.init(a);
    defer diags.deinit();
    const src = "\\\\hello — world\n    \\\\second line\nconst x = 1;";
    var lx = Lexer.init(src, &diags);
    var list = try lx.tokenizeAll(a);
    defer list.deinit(a);
    try std.testing.expectEqual(TokenKind.string_literal, list.items[0].kind);
    // The token must span both `\\`-prefixed lines, ending just before `const`.
    const span = list.items[0].span;
    try std.testing.expect(span.end > span.start);
    try std.testing.expect(std.mem.indexOf(u8, src[span.start..span.end], "second line") != null);
    try std.testing.expectEqual(@as(usize, 0), diags.count());
}

test "lex single-line multi-line string ends at first non-folding line" {
    const a = std.testing.allocator;
    var diags = diag.Diagnostics.init(a);
    defer diags.deinit();
    const src = "\\\\only one\nconst y = 2;";
    var lx = Lexer.init(src, &diags);
    var list = try lx.tokenizeAll(a);
    defer list.deinit(a);
    try std.testing.expectEqual(TokenKind.string_literal, list.items[0].kind);
    try std.testing.expectEqual(TokenKind.kw_const, list.items[1].kind);
    try std.testing.expectEqual(@as(usize, 0), diags.count());
}
