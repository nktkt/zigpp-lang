const std = @import("std");

pub const SuggestionKind = enum {
    using_for_defer_deinit,
    impl_trait_for_comptime_t,
    owned_struct_for_init_deinit,
    // New patterns 4..8.
    requires_for_if_panic, // Pattern 4 — auto-applied when fn returns void.
    derive_hash_for_manual_hash, // Pattern 5 — suggestion-only.
    owned_struct_for_alloc_free_deinit, // Pattern 6 — auto-applied: prepends `owned `.
    effects_noio_for_pure_fn, // Pattern 7 — suggestion-only.
    requires_for_if_return_error, // Pattern 8 — suggestion-only (semantics change).
};

pub const Suggestion = struct {
    kind: SuggestionKind,
    line: usize,
    col: usize = 1,
    original: []const u8,
    rewrite: ?[]const u8 = null,
    note: []const u8,
    /// Whether `--write` is allowed to apply this suggestion automatically.
    auto_apply: bool = false,
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

/// Per-line metadata used by detectors that need to look back/around.
const LineInfo = struct {
    text: []const u8, // raw line (no newline)
    start: usize, // byte offset into source
};

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

    // Pass 1: gather line table for two-pass detectors (patterns 4, 5, 6, 7, 8).
    var lines = std.ArrayList(LineInfo){};
    defer lines.deinit(allocator);
    {
        var i: usize = 0;
        while (i < source.len) {
            var eol = i;
            while (eol < source.len and source[eol] != '\n') : (eol += 1) {}
            try lines.append(allocator, .{ .text = source[i..eol], .start = i });
            i = if (eol < source.len) eol + 1 else eol;
        }
    }

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
    var struct_already_owned = false;

    // Pass 2: existing patterns 1-3 + new line-local patterns 4, 6, 8.
    for (lines.items, 0..) |li, idx| {
        const line_no = idx + 1;
        const line = li.text;
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
                        .auto_apply = true,
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
                .auto_apply = false,
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
                        .auto_apply = false,
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
            struct_already_owned = std.mem.indexOf(u8, line, "owned struct") != null;
        }
        if (in_struct) {
            if (std.mem.indexOf(u8, trimmed, "fn init(") != null or std.mem.indexOf(u8, trimmed, "pub fn init(") != null) has_init = true;
            if (std.mem.indexOf(u8, trimmed, "fn deinit(") != null or std.mem.indexOf(u8, trimmed, "pub fn deinit(") != null) has_deinit = true;
        }

        // Pattern 4: `if (cond) @panic("msg");`  →  `zpp.contract.requires(cond, "msg")`
        // Detect on a single physical line. The function-return-type guard is applied
        // by walking backwards to find the enclosing `fn ... <ret>` header. Skip if
        // ret type is anything other than `void` (caller may have meant `return error.X`).
        if (detectIfPanic(trimmed)) |info| {
            const fn_void = enclosingFnReturnsVoid(lines.items, idx);
            const rewrite_str = try std.fmt.allocPrint(
                allocator,
                "{s}zpp.contract.requires({s}, \"{s}\");",
                .{ leadingIndent(line), info.cond, info.msg },
            );
            const note_str = if (fn_void)
                try allocator.dupe(u8, "if (cond) @panic(\"...\") → zpp.contract.requires(cond, \"...\") [stripped in ReleaseFast]")
            else
                try allocator.dupe(u8, "if (cond) @panic(\"...\") in fn with non-void return — consider `return error.X` or `zpp.contract.requires`");
            try items.append(allocator, .{
                .kind = .requires_for_if_panic,
                .line = line_no,
                .col = leadingIndent(line).len + 1,
                .original = try allocator.dupe(u8, line),
                .rewrite = rewrite_str,
                .note = note_str,
                .auto_apply = fn_void, // SAFE iff void return.
            });
        }

        // Pattern 6: `pub fn deinit(self: *Self) void { self.<alloc>.free(...) | .destroy(...) }`
        // Triggered while inside a `struct` decl that is NOT already `owned struct`.
        if (in_struct and !struct_already_owned and detectAllocFreeDeinit(lines.items, idx)) {
            try items.append(allocator, .{
                .kind = .owned_struct_for_alloc_free_deinit,
                .line = struct_line,
                .col = 1,
                .original = try std.fmt.allocPrint(allocator, "struct {s}", .{struct_name_buf[0..struct_name_len]}),
                .rewrite = try std.fmt.allocPrint(allocator, "owned struct {s}", .{struct_name_buf[0..struct_name_len]}),
                .note = try allocator.dupe(u8, "deinit calls self.<allocator>.free/.destroy → `owned struct` (Zig++ enforces deinit shape)"),
                .auto_apply = true,
            });
            // Mark so we don't fire repeatedly within the same struct.
            struct_already_owned = true;
        }

        // Pattern 8: `if (!cond) return error.X;` followed by precondition comment OR
        // preceded by a docstring. Suggestion-only.
        if (detectIfReturnError(trimmed)) |info| {
            if (hasPreconditionContext(lines.items, idx)) {
                const rewrite_str = try std.fmt.allocPrint(
                    allocator,
                    "{s}zpp.contract.requires({s}, \"precondition: {s}\");",
                    .{ leadingIndent(line), info.cond, info.error_name },
                );
                try items.append(allocator, .{
                    .kind = .requires_for_if_return_error,
                    .line = line_no,
                    .col = leadingIndent(line).len + 1,
                    .original = try allocator.dupe(u8, line),
                    .rewrite = rewrite_str,
                    .note = try allocator.dupe(u8, "precondition-style `if (!cond) return error.X` → `zpp.contract.requires` (manual review: error→panic semantics change)"),
                    .auto_apply = false,
                });
            }
        }
    }

    if (in_struct and has_init and has_deinit) {
        try items.append(allocator, .{
            .kind = .owned_struct_for_init_deinit,
            .line = struct_line,
            .original = try std.fmt.allocPrint(allocator, "// struct {s}", .{struct_name_buf[0..struct_name_len]}),
            .rewrite = null,
            .note = try allocator.dupe(u8, "struct has init+deinit → consider `owned struct`"),
            .auto_apply = false,
        });
    }

    // Pass 3: function-block-aware detectors — patterns 5 and 7.
    try detectManualHash(allocator, &items, lines.items);
    try detectPureFn(allocator, &items, lines.items);

    return .{ .items = items };
}

fn leadingIndent(line: []const u8) []const u8 {
    var k: usize = 0;
    while (k < line.len and (line[k] == ' ' or line[k] == '\t')) : (k += 1) {}
    return line[0..k];
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
            // Match `= struct {` or `= owned struct {` — both anchor a struct decl.
            const has_struct = std.mem.indexOf(u8, rest, "= struct {") != null
                or std.mem.indexOf(u8, rest, "= owned struct {") != null;
            if (!has_struct) continue;
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

// ---------- Pattern 4: if (cond) @panic("msg") ---------------------------

const IfPanicInfo = struct {
    cond: []const u8,
    msg: []const u8,
};

fn detectIfPanic(trimmed: []const u8) ?IfPanicInfo {
    if (!std.mem.startsWith(u8, trimmed, "if (")) return null;
    // Find matching close paren of the `if (...)`.
    const close = matchParenAfter(trimmed, 3) orelse return null;
    const cond = std.mem.trim(u8, trimmed[4..close], " \t");
    if (cond.len == 0) return null;

    var rest = std.mem.trimLeft(u8, trimmed[close + 1 ..], " \t");
    if (!std.mem.startsWith(u8, rest, "@panic(")) return null;
    rest = rest[7..];
    rest = std.mem.trimLeft(u8, rest, " \t");
    if (rest.len == 0 or rest[0] != '"') return null;
    // Walk the string literal; require it ends and is followed by `);`.
    var k: usize = 1;
    while (k < rest.len) : (k += 1) {
        if (rest[k] == '\\') {
            k += 1;
            continue;
        }
        if (rest[k] == '"') break;
    }
    if (k >= rest.len) return null;
    const msg = rest[1..k];
    var tail = std.mem.trimLeft(u8, rest[k + 1 ..], " \t");
    if (!std.mem.startsWith(u8, tail, ")")) return null;
    tail = std.mem.trimLeft(u8, tail[1..], " \t");
    // Allow trailing `;` and optional comment. Don't accept extra code.
    if (tail.len > 0 and tail[0] == ';') tail = std.mem.trimLeft(u8, tail[1..], " \t");
    if (tail.len > 0 and !std.mem.startsWith(u8, tail, "//")) return null;
    return IfPanicInfo{ .cond = cond, .msg = msg };
}

/// Find the byte index of the `)` that closes the `(` at `open`. Returns null
/// on unbalanced input. Naive paren counter; fine for one-line conditions.
fn matchParenAfter(s: []const u8, open: usize) ?usize {
    if (open >= s.len or s[open] != '(') return null;
    var depth: usize = 1;
    var k: usize = open + 1;
    while (k < s.len) : (k += 1) {
        switch (s[k]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return k;
            },
            else => {},
        }
    }
    return null;
}

/// Walk lines backwards from `idx` until we find an `fn ... {` header. If we
/// can extract a return type, return whether it equals `void`. If we cannot
/// find a fn header, conservatively return false (treat as non-void: do not
/// auto-apply).
fn enclosingFnReturnsVoid(lines: []const LineInfo, idx: usize) bool {
    var i = idx;
    while (true) : (i -%= 1) {
        const line = lines[i].text;
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "fn ") or
            std.mem.startsWith(u8, trimmed, "pub fn ") or
            std.mem.indexOf(u8, trimmed, " fn ") != null)
        {
            // Locate the `)` that closes the parameter list, then read the return
            // type that follows up to `{` or end.
            // Find `fn ` token in trimmed.
            const fn_at = std.mem.indexOf(u8, trimmed, "fn ") orelse return false;
            // After fn name, find `(`; then match the closing `)`.
            const open_paren = std.mem.indexOfScalarPos(u8, trimmed, fn_at, '(') orelse return false;
            const close_paren = matchParenAfter(trimmed, open_paren) orelse return false;
            var ret = std.mem.trim(u8, trimmed[close_paren + 1 ..], " \t");
            // Strip trailing `{` and anything after.
            if (std.mem.indexOfScalar(u8, ret, '{')) |bi| ret = std.mem.trim(u8, ret[0..bi], " \t");
            // A leading `!` denotes error union — treat as non-void.
            if (ret.len > 0 and ret[0] == '!') return false;
            return std.mem.eql(u8, ret, "void");
        }
        if (i == 0) return false;
    }
}

// ---------- Pattern 6: alloc-free deinit → owned struct ------------------

/// Conservative single-line check: the line declares `pub fn deinit(self: *Self) void`
/// (or `pub fn deinit(self: *<Name>) void`) and the next non-blank line within
/// the body calls `self.<ident>.free(` or `self.<ident>.destroy(`.
fn detectAllocFreeDeinit(lines: []const LineInfo, idx: usize) bool {
    const line = lines[idx].text;
    const trimmed = std.mem.trimLeft(u8, line, " \t");
    const head = "pub fn deinit(self: *";
    if (!std.mem.startsWith(u8, trimmed, head)) return false;
    // Must end the signature on this line: `) void {` (allow body inline).
    if (std.mem.indexOf(u8, trimmed, ") void") == null) return false;

    // Inspect this line first (single-line body) then up to ~10 lines forward.
    if (lineHasAllocFreeOrDestroy(trimmed)) return true;
    var k: usize = idx + 1;
    var seen: usize = 0;
    while (k < lines.len and seen < 10) : ({
        k += 1;
        seen += 1;
    }) {
        const t2 = std.mem.trimLeft(u8, lines[k].text, " \t");
        if (t2.len == 0) continue;
        if (std.mem.startsWith(u8, t2, "}")) return false;
        if (lineHasAllocFreeOrDestroy(t2)) return true;
    }
    return false;
}

fn lineHasAllocFreeOrDestroy(line: []const u8) bool {
    // Look for `self.<ident>.free(` or `self.<ident>.destroy(`.
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, line, i, "self.")) |at| {
        var k = at + 5;
        while (k < line.len and (std.ascii.isAlphanumeric(line[k]) or line[k] == '_')) : (k += 1) {}
        if (k < line.len and line[k] == '.') {
            const tail = line[k + 1 ..];
            if (std.mem.startsWith(u8, tail, "free(") or std.mem.startsWith(u8, tail, "destroy(")) return true;
        }
        i = at + 5;
    }
    return false;
}

// ---------- Pattern 8: precondition-style if return error ----------------

const IfReturnErrorInfo = struct {
    cond: []const u8,
    error_name: []const u8,
};

fn detectIfReturnError(trimmed: []const u8) ?IfReturnErrorInfo {
    if (!std.mem.startsWith(u8, trimmed, "if (")) return null;
    const close = matchParenAfter(trimmed, 3) orelse return null;
    const inner = std.mem.trim(u8, trimmed[4..close], " \t");
    if (inner.len == 0) return null;

    var rest = std.mem.trimLeft(u8, trimmed[close + 1 ..], " \t");
    if (!std.mem.startsWith(u8, rest, "return error.")) return null;
    rest = rest["return error.".len..];
    var k: usize = 0;
    while (k < rest.len and (std.ascii.isAlphanumeric(rest[k]) or rest[k] == '_')) : (k += 1) {}
    if (k == 0) return null;
    const ename = rest[0..k];
    var tail = std.mem.trimLeft(u8, rest[k..], " \t");
    if (tail.len > 0 and tail[0] == ';') tail = std.mem.trimLeft(u8, tail[1..], " \t");
    if (tail.len > 0 and !std.mem.startsWith(u8, tail, "//")) return null;

    // We expect `cond` to be of the form `!something` per the spec — flip it for
    // the suggested `requires`. If the user wrote `cond` without negation we still
    // emit a suggestion using the raw condition (manual review will catch it).
    const cond_for_requires = if (inner.len > 0 and inner[0] == '!')
        std.mem.trimLeft(u8, inner[1..], " \t")
    else
        inner;

    return IfReturnErrorInfo{ .cond = cond_for_requires, .error_name = ename };
}

/// `if (!cond) return error.X;` is upgraded to a contract suggestion only when
/// either:
///   • the previous non-blank line is a `// preconditions: ...` comment, or
///   • the function's docstring (a run of `///` lines preceding the fn
///     header) mentions "precondition" or "requires".
/// Both checks are intentionally narrow to avoid noisy suggestions.
fn hasPreconditionContext(lines: []const LineInfo, idx: usize) bool {
    // Check immediately-preceding line for `// preconditions:`.
    if (idx > 0) {
        const prev = std.mem.trimLeft(u8, lines[idx - 1].text, " \t");
        if (std.mem.startsWith(u8, prev, "// preconditions") or
            std.mem.startsWith(u8, prev, "// precondition"))
        {
            return true;
        }
    }
    // Walk back to fn header, then scan its docstring.
    var i = idx;
    while (true) : (i -%= 1) {
        const trimmed = std.mem.trimLeft(u8, lines[i].text, " \t");
        if (std.mem.startsWith(u8, trimmed, "fn ") or
            std.mem.startsWith(u8, trimmed, "pub fn "))
        {
            // Look at lines [..i) for /// docstring; bail at first non-doc line.
            if (i == 0) return false;
            var j = i - 1;
            while (true) : (j -%= 1) {
                const tj = std.mem.trimLeft(u8, lines[j].text, " \t");
                if (!std.mem.startsWith(u8, tj, "///")) break;
                if (std.ascii.indexOfIgnoreCase(tj, "precondition") != null or
                    std.ascii.indexOfIgnoreCase(tj, "requires") != null)
                {
                    return true;
                }
                if (j == 0) break;
            }
            return false;
        }
        if (i == 0) return false;
    }
}

// ---------- Pattern 5: manual hash → derive(.{ .Hash }) ------------------

/// Detect a function `pub fn hash(self: *const @This()) u64 { ... }` with a body
/// that looks "obvious" (XOR/sum over fields, or std.hash.Wyhash). Conservative:
/// require exactly that signature and at most ~25 body lines.
fn detectManualHash(
    allocator: std.mem.Allocator,
    items: *std.ArrayList(Suggestion),
    lines: []const LineInfo,
) !void {
    var i: usize = 0;
    while (i < lines.len) : (i += 1) {
        const trimmed = std.mem.trimLeft(u8, lines[i].text, " \t");
        const sig = "pub fn hash(self: *const @This()) u64 {";
        if (!std.mem.startsWith(u8, trimmed, sig)) continue;

        // Find matching closing brace and capture body text. Track brace depth
        // starting at 1 (we already saw the opening `{` on this line).
        var depth: usize = 1;
        // Account for any extra open/close braces on the same line (unlikely
        // but cheap to handle).
        for (trimmed[sig.len..]) |c| {
            if (c == '{') depth += 1;
            if (c == '}') depth -|= 1;
        }
        var j: usize = i + 1;
        var body_buf = std.ArrayList(u8){};
        defer body_buf.deinit(allocator);
        var body_lines: usize = 0;
        var found_end = false;
        while (j < lines.len) : (j += 1) {
            const lt = lines[j].text;
            try body_buf.appendSlice(allocator, lt);
            try body_buf.append(allocator, '\n');
            for (lt) |c| {
                if (c == '{') depth += 1;
                if (c == '}') {
                    if (depth == 0) break;
                    depth -= 1;
                }
            }
            body_lines += 1;
            if (depth == 0) {
                found_end = true;
                break;
            }
            if (body_lines > 25) break;
        }
        if (!found_end) {
            i = j;
            continue;
        }
        const body = body_buf.items;
        const looks_like_xor = std.mem.indexOf(u8, body, " ^ ") != null or std.mem.indexOf(u8, body, "^=") != null;
        const looks_like_sum = std.mem.indexOf(u8, body, " + ") != null or std.mem.indexOf(u8, body, "+=") != null;
        const looks_like_wyhash = std.mem.indexOf(u8, body, "std.hash.Wyhash") != null;
        const obvious = looks_like_xor or looks_like_sum or looks_like_wyhash;
        if (!obvious) {
            i = j;
            continue;
        }

        try items.append(allocator, .{
            .kind = .derive_hash_for_manual_hash,
            .line = i + 1,
            .col = leadingIndent(lines[i].text).len + 1,
            .original = try allocator.dupe(u8, lines[i].text),
            .rewrite = null,
            .note = try allocator.dupe(u8, "manual hash() body looks obvious — consider `derive(.{ .Hash })` (suggestion-only: manual hash may be load-bearing)"),
            .auto_apply = false,
        });
        i = j;
    }
}

// ---------- Pattern 7: `fn doIo() !void` with no I/O calls --------------

fn detectPureFn(
    allocator: std.mem.Allocator,
    items: *std.ArrayList(Suggestion),
    lines: []const LineInfo,
) !void {
    // Collect the names of functions declared at the top level so the body can
    // mention them and we'll bail (transitive analysis is out of scope).
    var local_fns = std.StringHashMap(void).init(allocator);
    defer local_fns.deinit();
    for (lines) |li| {
        const trimmed = std.mem.trimLeft(u8, li.text, " \t");
        const anchor: []const u8 = if (std.mem.startsWith(u8, trimmed, "pub fn "))
            "pub fn "
        else if (std.mem.startsWith(u8, trimmed, "fn "))
            "fn "
        else
            "";
        if (anchor.len == 0) continue;
        const rest = trimmed[anchor.len..];
        var k: usize = 0;
        while (k < rest.len and (std.ascii.isAlphanumeric(rest[k]) or rest[k] == '_')) : (k += 1) {}
        if (k == 0) continue;
        try local_fns.put(rest[0..k], {});
    }

    var i: usize = 0;
    while (i < lines.len) : (i += 1) {
        const line = lines[i].text;
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        const anchor: []const u8 = if (std.mem.startsWith(u8, trimmed, "pub fn "))
            "pub fn "
        else if (std.mem.startsWith(u8, trimmed, "fn "))
            "fn "
        else
            "";
        if (anchor.len == 0) continue;

        // Capture fn name.
        const after_fn = trimmed[anchor.len..];
        var name_end: usize = 0;
        while (name_end < after_fn.len and (std.ascii.isAlphanumeric(after_fn[name_end]) or after_fn[name_end] == '_')) : (name_end += 1) {}
        if (name_end == 0) continue;
        const fn_name = after_fn[0..name_end];

        // Require an error-union return type (i.e. `!void` or `!T`). That's
        // the population we're suggesting `effects(.noio)` for.
        const open_paren = std.mem.indexOfScalarPos(u8, trimmed, anchor.len, '(') orelse continue;
        const close_paren = matchParenAfter(trimmed, open_paren) orelse continue;
        var ret = std.mem.trim(u8, trimmed[close_paren + 1 ..], " \t");
        if (std.mem.indexOfScalar(u8, ret, '{')) |bi| ret = std.mem.trim(u8, ret[0..bi], " \t");
        if (ret.len == 0 or ret[0] != '!') continue;

        // Find body open/close. The current line ends with `{` (or contains it).
        if (std.mem.indexOfScalar(u8, trimmed, '{') == null) continue;
        var depth: usize = 0;
        for (trimmed) |c| {
            if (c == '{') depth += 1;
            if (c == '}') depth -|= 1;
        }
        var j: usize = i + 1;
        var body_buf = std.ArrayList(u8){};
        defer body_buf.deinit(allocator);
        var found_end = false;
        while (j < lines.len) : (j += 1) {
            const lt = lines[j].text;
            try body_buf.appendSlice(allocator, lt);
            try body_buf.append(allocator, '\n');
            for (lt) |c| {
                if (c == '{') depth += 1;
                if (c == '}') {
                    if (depth == 0) break;
                    depth -= 1;
                }
            }
            if (depth == 0) {
                found_end = true;
                break;
            }
        }
        if (!found_end) continue;
        const body = body_buf.items;

        // I/O smell list — any of these disqualifies the fn.
        const io_markers = [_][]const u8{
            "std.fs.",     "std.io.",          "std.os.",         "std.posix.",
            "std.process.", "std.debug.print",  ".readAll(",       ".writeAll(",
            ".read(",      ".write(",          "std.net.",        "std.http.",
        };
        var has_io = false;
        for (io_markers) |m| {
            if (std.mem.indexOf(u8, body, m) != null) {
                has_io = true;
                break;
            }
        }
        if (has_io) {
            i = j;
            continue;
        }

        // If the body calls another locally-declared fn, bail (transitive analysis OOS).
        var calls_local = false;
        var it = local_fns.iterator();
        while (it.next()) |e| {
            const callee = e.key_ptr.*;
            if (std.mem.eql(u8, callee, fn_name)) continue;
            const pat = try std.fmt.allocPrint(allocator, "{s}(", .{callee});
            defer allocator.free(pat);
            if (std.mem.indexOf(u8, body, pat) != null) {
                calls_local = true;
                break;
            }
        }
        if (calls_local) {
            i = j;
            continue;
        }

        try items.append(allocator, .{
            .kind = .effects_noio_for_pure_fn,
            .line = i + 1,
            .col = leadingIndent(line).len + 1,
            .original = try allocator.dupe(u8, line),
            .rewrite = null,
            .note = try allocator.dupe(u8, "fn body shows no I/O calls — consider `effects(.noio)` (manual review only: callbacks may still do I/O)"),
            .auto_apply = false,
        });
        i = j;
    }
}

fn applySafeRewrites(allocator: std.mem.Allocator, source: []const u8, items: []const Suggestion) ![]u8 {
    // Per-line replacements for line-shaped rewrites.
    var line_rewrites = std.AutoHashMap(usize, []const u8).init(allocator);
    defer line_rewrites.deinit();
    // For pattern 6 we instead need a substring rewrite: `struct Foo` → `owned struct Foo`
    // applied at the struct-declaration line.
    var owned_struct_at = std.AutoHashMap(usize, void).init(allocator);
    defer owned_struct_at.deinit();

    for (items) |s| {
        if (!s.auto_apply) continue;
        switch (s.kind) {
            .using_for_defer_deinit => {
                if (s.rewrite) |r| try line_rewrites.put(s.line, r);
            },
            .requires_for_if_panic => {
                if (s.rewrite) |r| try line_rewrites.put(s.line, r);
            },
            .owned_struct_for_alloc_free_deinit => {
                try owned_struct_at.put(s.line, {});
            },
            else => {},
        }
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

        if (line_rewrites.get(line_no)) |r| {
            try out.appendSlice(allocator, r);
            if (eol < source.len) try out.append(allocator, '\n');
            // Note the var name so the matching `defer x.deinit();` can be elided.
            if (extractVarInit(trimmed)) |n| skip_next_defer_for = n;
            i = if (eol < source.len) eol + 1 else eol;
            continue;
        }
        if (owned_struct_at.contains(line_no)) {
            // Replace first occurrence of "= struct {" with "= owned struct {".
            if (std.mem.indexOf(u8, line, "= struct {")) |at| {
                try out.appendSlice(allocator, line[0..at]);
                try out.appendSlice(allocator, "= owned struct {");
                try out.appendSlice(allocator, line[at + "= struct {".len ..]);
            } else {
                try out.appendSlice(allocator, line);
            }
            if (eol < source.len) try out.append(allocator, '\n');
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

fn patternTag(kind: SuggestionKind) []const u8 {
    return switch (kind) {
        .using_for_defer_deinit => "pattern-1",
        .impl_trait_for_comptime_t => "pattern-2",
        .owned_struct_for_init_deinit => "pattern-3",
        .requires_for_if_panic => "pattern-4",
        .derive_hash_for_manual_hash => "pattern-5",
        .owned_struct_for_alloc_free_deinit => "pattern-6",
        .effects_noio_for_pure_fn => "pattern-7",
        .requires_for_if_return_error => "pattern-8",
    };
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
        const head = try std.fmt.allocPrint(
            allocator,
            "{s}:{d}:{d}: migrate-suggestion [{s}]: {s}\n",
            .{ path, s.line, s.col, patternTag(s.kind), s.note },
        );
        defer allocator.free(head);
        try stdout.writeAll(head);
        const before = try std.fmt.allocPrint(allocator, "  before: {s}\n", .{s.original});
        defer allocator.free(before);
        try stdout.writeAll(before);
        if (s.rewrite) |r| {
            const after = try std.fmt.allocPrint(allocator, "  after:  {s}\n", .{r});
            defer allocator.free(after);
            try stdout.writeAll(after);
        } else {
            try stdout.writeAll("  after:  (suggestion only — no automated rewrite)\n");
        }
        const apply_line = if (s.auto_apply)
            "  apply:  --write\n"
        else
            "  apply:  manual review only\n";
        try stdout.writeAll(apply_line);
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

// ---------------- Tests ---------------------------------------------------

fn findKind(plan: Plan, kind: SuggestionKind) ?Suggestion {
    for (plan.items.items) |s| if (s.kind == kind) return s;
    return null;
}

fn countKind(plan: Plan, kind: SuggestionKind) usize {
    var n: usize = 0;
    for (plan.items.items) |s| if (s.kind == kind) {
        n += 1;
    };
    return n;
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

// ---- Pattern 4: if (cond) @panic("msg") --------------------------------

test "pattern 4: if-panic in void fn auto-applies" {
    const a = std.testing.allocator;
    const src =
        \\fn f(x: u32) void {
        \\    if (x == 0) @panic("must be non-zero");
        \\}
        \\
    ;
    var plan = try analyse(a, src);
    defer plan.deinit(a);
    const s = findKind(plan, .requires_for_if_panic) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(s.auto_apply);
    try std.testing.expect(s.rewrite != null);
    try std.testing.expect(std.mem.indexOf(u8, s.rewrite.?, "zpp.contract.requires(x == 0, \"must be non-zero\")") != null);
}

test "pattern 4: if-panic in fn with non-void return suggests but does not auto-apply" {
    const a = std.testing.allocator;
    const src =
        \\fn f(x: u32) !u32 {
        \\    if (x == 0) @panic("must be non-zero");
        \\    return x;
        \\}
        \\
    ;
    var plan = try analyse(a, src);
    defer plan.deinit(a);
    const s = findKind(plan, .requires_for_if_panic) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(!s.auto_apply);
}

test "pattern 4: negative — `if (cond) doSomething()` does not trigger" {
    const a = std.testing.allocator;
    const src =
        \\fn f(x: u32) void {
        \\    if (x == 0) doSomething();
        \\}
        \\
    ;
    var plan = try analyse(a, src);
    defer plan.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), countKind(plan, .requires_for_if_panic));
}

// ---- Pattern 5: manual hash → derive(.{ .Hash }) -----------------------

test "pattern 5: manual XOR-style hash triggers (suggestion-only)" {
    const a = std.testing.allocator;
    const src =
        \\const Foo = struct {
        \\    a: u32,
        \\    b: u32,
        \\    pub fn hash(self: *const @This()) u64 {
        \\        return @as(u64, self.a) ^ @as(u64, self.b);
        \\    }
        \\};
        \\
    ;
    var plan = try analyse(a, src);
    defer plan.deinit(a);
    const s = findKind(plan, .derive_hash_for_manual_hash) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(!s.auto_apply); // never auto-apply
}

test "pattern 5: negative — non-obvious hash body does not trigger" {
    const a = std.testing.allocator;
    const src =
        \\const Foo = struct {
        \\    pub fn hash(self: *const @This()) u64 {
        \\        return computeSpecial(self);
        \\    }
        \\};
        \\
    ;
    var plan = try analyse(a, src);
    defer plan.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), countKind(plan, .derive_hash_for_manual_hash));
}

// ---- Pattern 6: alloc-free deinit → owned struct -----------------------

test "pattern 6: deinit calling self.alloc.free triggers and is auto-applied" {
    const a = std.testing.allocator;
    const src =
        \\const Buf = struct {
        \\    alloc: std.mem.Allocator,
        \\    data: []u8,
        \\    pub fn deinit(self: *Self) void {
        \\        self.alloc.free(self.data);
        \\    }
        \\};
        \\
    ;
    var plan = try analyse(a, src);
    defer plan.deinit(a);
    const s = findKind(plan, .owned_struct_for_alloc_free_deinit) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(s.auto_apply);
    try std.testing.expect(s.rewrite != null);
    try std.testing.expect(std.mem.indexOf(u8, s.rewrite.?, "owned struct Buf") != null);

    // Apply the rewrite and verify it lands.
    const new_src = try applySafeRewrites(a, src, plan.items.items);
    defer a.free(new_src);
    try std.testing.expect(std.mem.indexOf(u8, new_src, "= owned struct {") != null);
}

test "pattern 6: negative — deinit without free/destroy does not trigger" {
    const a = std.testing.allocator;
    const src =
        \\const Foo = struct {
        \\    pub fn deinit(self: *Self) void {
        \\        _ = self;
        \\    }
        \\};
        \\
    ;
    var plan = try analyse(a, src);
    defer plan.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), countKind(plan, .owned_struct_for_alloc_free_deinit));
}

test "pattern 6: negative — already-owned struct does not re-trigger" {
    const a = std.testing.allocator;
    const src =
        \\const Buf = owned struct {
        \\    alloc: std.mem.Allocator,
        \\    data: []u8,
        \\    pub fn deinit(self: *Self) void {
        \\        self.alloc.free(self.data);
        \\    }
        \\};
        \\
    ;
    var plan = try analyse(a, src);
    defer plan.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), countKind(plan, .owned_struct_for_alloc_free_deinit));
}

// ---- Pattern 7: pure fn → effects(.noio) -------------------------------

test "pattern 7: pure fn body with no I/O suggests noio" {
    const a = std.testing.allocator;
    const src =
        \\fn add(x: u32, y: u32) !u32 {
        \\    return x + y;
        \\}
        \\
    ;
    var plan = try analyse(a, src);
    defer plan.deinit(a);
    const s = findKind(plan, .effects_noio_for_pure_fn) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(!s.auto_apply); // suggestion-only
}

test "pattern 7: negative — fn that calls std.io is not flagged" {
    const a = std.testing.allocator;
    const src =
        \\fn write(x: u32) !void {
        \\    try std.io.getStdOut().writer().print("{d}\n", .{x});
        \\}
        \\
    ;
    var plan = try analyse(a, src);
    defer plan.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), countKind(plan, .effects_noio_for_pure_fn));
}

// ---- Pattern 8: precondition-style if return error ---------------------

test "pattern 8: if (!cond) return error.X with precondition comment suggests requires" {
    const a = std.testing.allocator;
    const src =
        \\fn divide(a: u32, b: u32) !u32 {
        \\    // preconditions: b != 0
        \\    if (!(b != 0)) return error.InvalidArg;
        \\    return a / b;
        \\}
        \\
    ;
    var plan = try analyse(a, src);
    defer plan.deinit(a);
    const s = findKind(plan, .requires_for_if_return_error) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(!s.auto_apply); // never auto-apply
    try std.testing.expect(s.rewrite != null);
    try std.testing.expect(std.mem.indexOf(u8, s.rewrite.?, "zpp.contract.requires") != null);
}

test "pattern 8: negative — if return error without precondition context does not trigger" {
    const a = std.testing.allocator;
    const src =
        \\fn divide(a: u32, b: u32) !u32 {
        \\    if (!(b != 0)) return error.InvalidArg;
        \\    return a / b;
        \\}
        \\
    ;
    var plan = try analyse(a, src);
    defer plan.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), countKind(plan, .requires_for_if_return_error));
}

// ---- Pattern 2: `comptime T: type` → `impl Trait` ----------------------

test "pattern 2: fn with `comptime T: type` parameter is flagged" {
    // The detector at zpp_migrate.zig:166-176 was previously uncovered.
    // Any function declaring a `comptime T: type` parameter should fire
    // the suggestion; the rewrite is null (suggestion-only) and the note
    // points the user at `impl SomeTrait` as the visible-dispatch
    // alternative.
    const a = std.testing.allocator;
    const src =
        \\fn applyOp(comptime T: type, x: *T, y: *T) void {
        \\    _ = x; _ = y;
        \\}
        \\
    ;
    var plan = try analyse(a, src);
    defer plan.deinit(a);
    const s = findKind(plan, .impl_trait_for_comptime_t) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(!s.auto_apply);
    try std.testing.expect(s.rewrite == null);
    try std.testing.expect(std.mem.indexOf(u8, s.note, "impl SomeTrait") != null);
}

test "pattern 2: negative — fn without `comptime T: type` does not trigger" {
    const a = std.testing.allocator;
    const src =
        \\fn applyOp(x: u32, y: u32) u32 {
        \\    return x + y;
        \\}
        \\
    ;
    var plan = try analyse(a, src);
    defer plan.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), countKind(plan, .impl_trait_for_comptime_t));
}

// ---- Pattern 5: more body shapes (Wyhash, sum) ------------------------

test "pattern 5: Wyhash-style hash body triggers" {
    // The detector at zpp_migrate.zig:618-621 considers three body
    // shapes "obvious": XOR, sum (`+=` / ` + `), and `std.hash.Wyhash`.
    // The pre-existing tests only covered XOR; this one closes the
    // Wyhash branch.
    const a = std.testing.allocator;
    const src =
        \\const Key = struct {
        \\    data: []const u8,
        \\    pub fn hash(self: *const @This()) u64 {
        \\        var h = std.hash.Wyhash.init(0);
        \\        h.update(self.data);
        \\        return h.final();
        \\    }
        \\};
        \\
    ;
    var plan = try analyse(a, src);
    defer plan.deinit(a);
    const s = findKind(plan, .derive_hash_for_manual_hash) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(!s.auto_apply);
    try std.testing.expect(s.rewrite == null);
}

test "pattern 5: sum-style hash body triggers" {
    // Mirrors the XOR test but exercises the `+=` accumulator branch
    // (the third body-shape recognised by the detector).
    const a = std.testing.allocator;
    const src =
        \\const Counter = struct {
        \\    bytes: []const u8,
        \\    pub fn hash(self: *const @This()) u64 {
        \\        var acc: u64 = 0;
        \\        for (self.bytes) |b| acc += b;
        \\        return acc;
        \\    }
        \\};
        \\
    ;
    var plan = try analyse(a, src);
    defer plan.deinit(a);
    const s = findKind(plan, .derive_hash_for_manual_hash) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(!s.auto_apply);
}
