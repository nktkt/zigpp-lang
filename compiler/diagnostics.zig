const std = @import("std");

pub const Severity = enum {
    err,
    warning,
    note,

    pub fn label(self: Severity) []const u8 {
        return switch (self) {
            .err => "error",
            .warning => "warning",
            .note => "note",
        };
    }
};

pub const Span = struct {
    start: u32,
    end: u32,

    pub fn empty() Span {
        return .{ .start = 0, .end = 0 };
    }

    pub fn merge(a: Span, b: Span) Span {
        return .{
            .start = @min(a.start, b.start),
            .end = @max(a.end, b.end),
        };
    }
};

/// Diagnostic codes. The numeric ranges map to phase:
///   Z00xx — sema (trait/owned/move/effect)
///   Z01xx — parser
///   Z02xx — lexer
///   Z03xx — lower
pub const Code = enum {
    z0001_unknown_trait,
    z0010_missing_deinit_on_owned,
    z0011_using_type_lacks_deinit,
    z0020_use_after_move,
    z0030_effect_violation,
    z0040_unknown_derive,
    z0100_unexpected_token,
    z0101_expected_identifier,
    z0102_expected_token,
    z0103_unterminated_block,
    z0200_invalid_char,
    z0201_unterminated_string,
    z0300_lower_internal,

    pub fn id(self: Code) []const u8 {
        return switch (self) {
            .z0001_unknown_trait => "Z0001",
            .z0010_missing_deinit_on_owned => "Z0010",
            .z0011_using_type_lacks_deinit => "Z0011",
            .z0020_use_after_move => "Z0020",
            .z0030_effect_violation => "Z0030",
            .z0040_unknown_derive => "Z0040",
            .z0100_unexpected_token => "Z0100",
            .z0101_expected_identifier => "Z0101",
            .z0102_expected_token => "Z0102",
            .z0103_unterminated_block => "Z0103",
            .z0200_invalid_char => "Z0200",
            .z0201_unterminated_string => "Z0201",
            .z0300_lower_internal => "Z0300",
        };
    }
};

/// One-shot fix-it hint shown beneath the caret. Returns null when no
/// generic suggestion applies. Multi-line hints use `\n` and are re-indented
/// by the renderer so every continuation aligns under the leading text.
pub fn hint(code: Code) ?[]const u8 {
    return switch (code) {
        .z0001_unknown_trait => "declare the trait before any `impl` or `dyn` reference:\n  trait Name { fn method(self) void; }",
        .z0010_missing_deinit_on_owned => "owned structs must release their resources explicitly. Add:\n  pub fn deinit(self: *@This()) void {\n      // free anything held by `self`, then leave it in a moved-from state.\n  }",
        .z0011_using_type_lacks_deinit => "give the type a `deinit` method, or drop the `using` binding so the compiler does not try to auto-release it.",
        .z0020_use_after_move => "the value was consumed by `move`. Rebind it (`own var x = ...`) or restructure the code to keep a single owner.",
        .z0030_effect_violation => "the function declared an effect it then violated. Remove the `effects(...)` annotation or eliminate the disallowed operation (allocation, IO, etc.).",
        .z0040_unknown_derive => "the derive name does not match any helper in `zpp.derive`. Known helpers: Hash, Eq, Ord, Default, Clone, Debug, Json, Iterator, Serialize, Compare, FromStr.",
        .z0100_unexpected_token => "remove or replace the highlighted token. The parser was in the middle of a declaration or expression and could not continue.",
        .z0101_expected_identifier => "supply a name here, e.g. `fn name(...)`, `struct Name { ... }`, or `const name = ...`.",
        .z0102_expected_token => "insert the expected token. Most often a missing `;`, `,`, `)`, or `}` in the surrounding scope.",
        .z0103_unterminated_block => "close the open block with a matching `}`. Check earlier braces in this scope for an extra opener.",
        .z0200_invalid_char => "remove the offending byte. Source files must be UTF-8 and only printable characters or whitespace are allowed outside string literals.",
        .z0201_unterminated_string => "close the string literal with a matching `\"`. Multi-line strings must use the `\\\\` line-prefix form.",
        .z0300_lower_internal => "this is an internal lowering bug. File an issue with the offending source so the compiler can be fixed.",
    };
}

/// Long-form explanation shown by `zpp explain <code>`. Each entry is a
/// self-contained markdown-ish block: a one-paragraph summary, a "triggers"
/// example, and a "fix" example.
pub fn explain(code: Code) []const u8 {
    return switch (code) {
        .z0001_unknown_trait =>
        \\Z0001: unknown trait
        \\
        \\You referenced a trait by name (`impl T for ...` or `dyn T`) but no
        \\`trait T` declaration is in scope. The trait must be declared before
        \\it is used.
        \\
        \\Triggers:
        \\    fn dispatch(g: dyn Greeter) void { g.greet(); }   // Greeter undefined
        \\
        \\Fix:
        \\    trait Greeter { fn greet(self) void; }
        \\    fn dispatch(g: dyn Greeter) void { g.vtable.greet(g.ptr); }
        ,
        .z0010_missing_deinit_on_owned =>
        \\Z0010: owned struct missing deinit
        \\
        \\`owned struct` is a sema-checked promise that the type owns
        \\resources that must be released. Every `owned struct` therefore
        \\requires a `pub fn deinit(self: *@This()) void` method.
        \\
        \\Triggers:
        \\    owned struct Buffer { data: []u8 }   // no deinit
        \\
        \\Fix:
        \\    owned struct Buffer {
        \\        data: []u8,
        \\        allocator: std.mem.Allocator,
        \\        pub fn deinit(self: *Buffer) void {
        \\            self.allocator.free(self.data);
        \\        }
        \\    }
        \\
        \\Or: drop the `owned` modifier if the type really does not own
        \\anything that needs releasing.
        ,
        .z0011_using_type_lacks_deinit =>
        \\Z0011: `using` target has no deinit
        \\
        \\`using x = expr;` lowers to `var x = expr; defer x.deinit();`. The
        \\type of `expr` must therefore have a `deinit` method, otherwise the
        \\generated `defer` would not type-check.
        \\
        \\Triggers:
        \\    using s = "literal";   // []const u8 has no deinit
        \\
        \\Fix:
        \\    var s: []const u8 = "literal";   // plain var, no auto-cleanup
        \\
        \\Or: give the source type a `deinit` method.
        ,
        .z0020_use_after_move =>
        \\Z0020: use after move
        \\
        \\A binding declared with `own var` was consumed by `move x` and then
        \\read again in the same scope. After `move`, the original name no
        \\longer holds a valid value.
        \\
        \\Triggers:
        \\    own var a = try Buffer.init(alloc);
        \\    const b = move a;
        \\    use(a);                 // a is moved — invalid
        \\
        \\Fix (rebind the moved value):
        \\    own var a = try Buffer.init(alloc);
        \\    const b = move a;
        \\    use(b);
        \\
        \\Or restructure so each owner is read exactly once.
        ,
        .z0030_effect_violation =>
        \\Z0030: function violates declared effect
        \\
        \\You annotated a function with `effects(.noalloc)` (or another
        \\restrictive effect) and then called something that violates it.
        \\Effect annotations are checked by sema as a heuristic — identifiers
        \\containing `Allocator`, `alloc`, `create`, etc. count as an
        \\allocation site.
        \\
        \\Triggers:
        \\    effects(.noalloc) fn pure(a: Allocator) !void {
        \\        const xs = try a.alloc(u8, 16);   // violates .noalloc
        \\        _ = xs;
        \\    }
        \\
        \\Fix: drop the `effects(.noalloc)` annotation, or eliminate the
        \\allocation (use a fixed buffer / arena owned by the caller).
        ,
        .z0100_unexpected_token =>
        \\Z0100: unexpected token
        \\
        \\The parser was in the middle of a declaration or expression and the
        \\next token did not fit any of the expected continuations.
        \\
        \\Triggers:
        \\    fn foo() void { 5 + ; }     // operator with no rhs
        \\
        \\Fix: remove or correct the highlighted token.
        ,
        .z0101_expected_identifier =>
        \\Z0101: expected identifier
        \\
        \\A name was required here. Function names, struct names, trait
        \\names, parameter names all use this same diagnostic.
        \\
        \\Triggers:
        \\    fn () void {}               // missing fn name
        \\    struct { x: i32 }           // missing struct name (in places that need one)
        \\
        \\Fix: supply a name. Identifiers match `[A-Za-z_][A-Za-z0-9_]*`.
        ,
        .z0102_expected_token =>
        \\Z0102: expected a specific token
        \\
        \\The parser needed a particular punctuation (`;`, `,`, `)`, `}`,
        \\`=`, `:`, etc.) but found something else.
        \\
        \\Triggers:
        \\    fn foo() void { var x = 1 }   // missing `;` after `1`
        \\
        \\Fix: insert the expected token. The diagnostic message tells you
        \\which one was needed.
        ,
        .z0103_unterminated_block =>
        \\Z0103: unterminated block
        \\
        \\A `{` was opened but the file ended before the matching `}`.
        \\
        \\Triggers:
        \\    fn foo() void {
        \\        var x = 1;
        \\    // (no closing brace)
        \\
        \\Fix: add the matching `}`. Check earlier braces in this scope for
        \\an extra opener as well.
        ,
        .z0200_invalid_char =>
        \\Z0200: invalid character in source
        \\
        \\The lexer found a byte outside the printable ASCII / whitespace set
        \\and outside any string literal. `.zpp` source must be valid UTF-8;
        \\stray binary bytes are rejected.
        \\
        \\Triggers: typically a stray BOM, a control character pasted from a
        \\rich-text editor, or a corrupted file.
        \\
        \\Fix: open the file in a hex editor or run `file` on it to see what
        \\is actually inside; re-save as UTF-8.
        ,
        .z0201_unterminated_string =>
        \\Z0201: unterminated string literal
        \\
        \\A `"` was opened but the file ended (or the line ended in a
        \\non-multiline-string context) before the matching `"`.
        \\
        \\Triggers:
        \\    const s = "hello world ;       // missing closing quote
        \\
        \\Fix: add the closing `"`. For multi-line content use the `\\\\` line
        \\prefix form Zig provides.
        ,
        .z0040_unknown_derive =>
        \\Z0040: unknown derive name
        \\
        \\`derive(.{ ... })` only accepts the helper names exported from
        \\`zpp.derive`. Anything else falls through to the lowerer's generic
        \\fallback and then fails at Zig compile time with a less helpful
        \\"no member" error. Sema catches it earlier.
        \\
        \\Known helpers: Hash, Eq, Ord, Default, Clone, Debug, Json,
        \\Iterator, Serialize, Compare, FromStr.
        \\
        \\Triggers:
        \\    struct User { id: u32 } derive(.{ Hashh });   // typo
        \\
        \\Fix:
        \\    struct User { id: u32 } derive(.{ Hash });
        ,
        .z0300_lower_internal =>
        \\Z0300: internal lowering error
        \\
        \\This is a compiler bug. The lowering pass tried to emit something
        \\it could not, and the failure has been reported as a diagnostic
        \\rather than crashing.
        \\
        \\Fix: file an issue at https://github.com/nktkt/zigpp-lang/issues
        \\with the source that triggered it. The fuzz harness
        \\(`zig build fuzz`) is also a good way to find more inputs in the
        \\same shape.
        ,
    };
}

/// Look up a code by its public ID string ("Z0010"). Used by `zpp explain`.
pub fn codeFromId(id_str: []const u8) ?Code {
    inline for (@typeInfo(Code).@"enum".fields) |f| {
        const c: Code = @enumFromInt(f.value);
        if (std.mem.eql(u8, c.id(), id_str)) return c;
    }
    return null;
}

pub const Diagnostic = struct {
    severity: Severity,
    span: Span,
    code: Code,
    message: []const u8,
    /// Owned by the Diagnostics arena when present.
    message_owned: bool = false,
};

pub const LineCol = struct {
    line: u32,
    col: u32,
    line_start: u32,
    line_end: u32,
};

/// Compute line/col (1-based) for an offset into `source`.
pub fn locate(source: []const u8, offset: u32) LineCol {
    var line: u32 = 1;
    var col: u32 = 1;
    var line_start: u32 = 0;
    var i: u32 = 0;
    const off = if (offset > source.len) @as(u32, @intCast(source.len)) else offset;
    while (i < off) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            col = 1;
            line_start = i + 1;
        } else {
            col += 1;
        }
    }
    var line_end: u32 = line_start;
    while (line_end < source.len and source[line_end] != '\n') : (line_end += 1) {}
    return .{
        .line = line,
        .col = col,
        .line_start = line_start,
        .line_end = line_end,
    };
}

pub const Diagnostics = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Diagnostic),

    pub fn init(allocator: std.mem.Allocator) Diagnostics {
        return .{
            .allocator = allocator,
            .items = .{},
        };
    }

    pub fn deinit(self: *Diagnostics) void {
        for (self.items.items) |d| {
            if (d.message_owned) self.allocator.free(d.message);
        }
        self.items.deinit(self.allocator);
    }

    pub fn add(self: *Diagnostics, d: Diagnostic) !void {
        try self.items.append(self.allocator, d);
    }

    pub fn emit(
        self: *Diagnostics,
        severity: Severity,
        code: Code,
        span: Span,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.items.append(self.allocator, .{
            .severity = severity,
            .span = span,
            .code = code,
            .message = msg,
            .message_owned = true,
        });
    }

    pub fn hasErrors(self: *const Diagnostics) bool {
        for (self.items.items) |d| {
            if (d.severity == .err) return true;
        }
        return false;
    }

    pub fn count(self: *const Diagnostics) usize {
        return self.items.items.len;
    }

    /// Render to a writer using the Zig 0.16 std.Io.Writer interface.
    pub fn render(
        self: *const Diagnostics,
        writer: *std.Io.Writer,
        file_name: []const u8,
        source: []const u8,
    ) !void {
        for (self.items.items) |d| {
            const lc = locate(source, d.span.start);
            try writer.print(
                "{s}:{d}:{d}: {s}[{s}]: {s}\n",
                .{ file_name, lc.line, lc.col, d.severity.label(), d.code.id(), d.message },
            );
            const line_text = source[lc.line_start..lc.line_end];
            try writer.print("    {s}\n    ", .{line_text});
            var i: u32 = 1;
            while (i < lc.col) : (i += 1) try writer.writeByte(' ');
            try writer.writeByte('^');
            const span_len = if (d.span.end > d.span.start) d.span.end - d.span.start else 1;
            var j: u32 = 1;
            while (j < span_len) : (j += 1) try writer.writeByte('~');
            try writer.writeByte('\n');
            if (hint(d.code)) |h| {
                // First line is prefixed with `      hint:`; subsequent
                // lines align under the start of the hint text.
                try writer.writeAll("      hint: ");
                var line_iter = std.mem.splitScalar(u8, h, '\n');
                var first = true;
                while (line_iter.next()) |hl| {
                    if (!first) try writer.writeAll("            ");
                    try writer.writeAll(hl);
                    try writer.writeByte('\n');
                    first = false;
                }
            }
        }
    }
};

test "diagnostics basic" {
    const a = std.testing.allocator;
    var diags = Diagnostics.init(a);
    defer diags.deinit();

    try diags.emit(.err, .z0001_unknown_trait, .{ .start = 0, .end = 5 }, "unknown trait '{s}'", .{"Foo"});
    try std.testing.expectEqual(@as(usize, 1), diags.count());
    try std.testing.expect(diags.hasErrors());
}

test "locate computes line/col" {
    const src = "abc\ndef\nghi";
    const lc = locate(src, 5); // 'e' on line 2
    try std.testing.expectEqual(@as(u32, 2), lc.line);
    try std.testing.expectEqual(@as(u32, 2), lc.col);
}

test "hint covers every Code variant" {
    inline for (@typeInfo(Code).@"enum".fields) |f| {
        const c: Code = @field(Code, f.name);
        const h = hint(c) orelse return error.MissingHint;
        try std.testing.expect(h.len > 0);
    }
}

test "render emits a hint line beneath the caret for every code" {
    const a = std.testing.allocator;
    inline for (@typeInfo(Code).@"enum".fields) |f| {
        const c: Code = @field(Code, f.name);
        var diags = Diagnostics.init(a);
        defer diags.deinit();
        try diags.emit(.err, c, .{ .start = 0, .end = 1 }, "test message", .{});

        var buf: [4096]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try diags.render(&w, "test.zpp", "x");
        const out = buf[0..w.end];
        try std.testing.expect(std.mem.indexOf(u8, out, "      hint: ") != null);
    }
}

test "render indents multi-line hints under the hint text" {
    const a = std.testing.allocator;
    var diags = Diagnostics.init(a);
    defer diags.deinit();
    try diags.emit(
        .err,
        .z0010_missing_deinit_on_owned,
        .{ .start = 0, .end = 5 },
        "owned struct '{s}' is missing required 'deinit' method",
        .{"X"},
    );

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try diags.render(&w, "f.zpp", "owned struct X { v: u32 }");
    const out = buf[0..w.end];

    // First hint line uses the `      hint: ` prefix.
    try std.testing.expect(std.mem.indexOf(u8, out, "      hint: owned structs must release") != null);
    // Continuation lines are aligned under the hint text (12 leading spaces).
    try std.testing.expect(std.mem.indexOf(u8, out, "            pub fn deinit(self: *@This()) void {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "            }") != null);
}
