const std = @import("std");
const ast = @import("ast.zig");
const diag = @import("diagnostics.zig");

/// Per-fn effect set produced by the inference passes. Each flag is true
/// iff sema's heuristic concluded the fn (transitively) exhibits that
/// effect. Used by `@effectsOf(f)` lowering and by the Z0030/Z0060
/// violation emitters.
pub const InferredEffects = packed struct {
    alloc: bool = false,
    io: bool = false,
    panic: bool = false,
    @"async": bool = false,
};

/// Per-fn list of `.custom("X")` effect names (the `X` slices, deduplicated).
/// Sibling to the `InferredEffects` packed struct above — kept separate
/// because the set is open-ended (each fn can carry an arbitrary number of
/// custom names) and packing it into the struct would force a fixed cap.
/// Slices point into the original source / AST arena and are not freed.
pub const CustomEffectList = std.ArrayList([]const u8);
pub const CustomEffectMap = std.StringHashMap(CustomEffectList);

/// Result of semantic analysis. The maps are owned by `deinit`.
pub const SemaResult = struct {
    allocator: std.mem.Allocator,
    /// Set of trait names declared in the file.
    traits: std.StringHashMap(void),
    /// Method-name lists per trait so impl checks can cross-verify.
    /// Slices reference the original AST arena and are not freed here.
    trait_methods: std.StringHashMap([]const ast.TraitMethod),
    /// Map of owned-struct names → whether they have a deinit method.
    owned_structs: std.StringHashMap(bool),
    /// Inferred effect set per same-file fn name. Populated by the four
    /// `check*EffectInference` passes (each tees its result into this
    /// table at the end of the fixed-point loop). When two fns share a
    /// name (e.g. `init` on multiple structs) the first one wins — the
    /// MVP does not resolve overloads.
    inferred_effects: std.StringHashMap(InferredEffects),
    /// Inferred `.custom("X")` effect names per same-file fn. Populated
    /// by `checkCustomEffectInference`. Same fn-name sharing rule as
    /// `inferred_effects`.
    inferred_custom_effects: CustomEffectMap,

    pub fn deinit(self: *SemaResult) void {
        self.traits.deinit();
        self.trait_methods.deinit();
        self.owned_structs.deinit();
        self.inferred_effects.deinit();
        var it = self.inferred_custom_effects.valueIterator();
        while (it.next()) |list| list.deinit(self.allocator);
        self.inferred_custom_effects.deinit();
    }
};

pub const Sema = struct {
    allocator: std.mem.Allocator,
    diags: *diag.Diagnostics,

    pub fn init(allocator: std.mem.Allocator, diags: *diag.Diagnostics) Sema {
        return .{ .allocator = allocator, .diags = diags };
    }

    pub fn analyze(self: *Sema, file: *const ast.File) !SemaResult {
        var result: SemaResult = .{
            .allocator = self.allocator,
            .traits = std.StringHashMap(void).init(self.allocator),
            .trait_methods = std.StringHashMap([]const ast.TraitMethod).init(self.allocator),
            .owned_structs = std.StringHashMap(bool).init(self.allocator),
            .inferred_effects = std.StringHashMap(InferredEffects).init(self.allocator),
            .inferred_custom_effects = CustomEffectMap.init(self.allocator),
        };
        errdefer result.deinit();

        try self.collectDecls(file, &result);
        try self.checkOwnedStructs(file, &result);
        try self.checkImpls(file, &result);
        try self.checkParams(file, &result);
        try self.checkFunctions(file, &result);
        try self.checkEffectInference(file, &result);
        try self.checkIoEffectInference(file, &result);
        try self.checkPanicEffectInference(file, &result);
        try self.checkAsyncEffectInference(file, &result);
        try self.checkCustomEffectInference(file, &result);

        return result;
    }

    fn collectDecls(self: *Sema, file: *const ast.File, r: *SemaResult) !void {
        _ = self;
        for (file.decls) |d| {
            switch (d) {
                .trait => |t| {
                    try r.traits.put(t.name, {});
                    try r.trait_methods.put(t.name, t.methods);
                },
                .extern_interface => |e| {
                    try r.traits.put(e.name, {});
                    try r.trait_methods.put(e.name, e.methods);
                },
                .owned_struct => |o| {
                    var has_deinit = false;
                    for (o.fns) |f| {
                        if (std.mem.eql(u8, f.sig.name, "deinit")) {
                            has_deinit = true;
                            break;
                        }
                    }
                    try r.owned_structs.put(o.name, has_deinit);
                },
                else => {},
            }
        }
    }

    fn checkOwnedStructs(self: *Sema, file: *const ast.File, r: *SemaResult) !void {
        _ = r;
        for (file.decls) |d| {
            switch (d) {
                .owned_struct => |o| {
                    var has_deinit = false;
                    for (o.fns) |f| {
                        if (std.mem.eql(u8, f.sig.name, "deinit")) {
                            has_deinit = true;
                            break;
                        }
                    }
                    if (!has_deinit) {
                        try self.diags.emit(
                            .err,
                            .z0010_missing_deinit_on_owned,
                            o.span,
                            "owned struct '{s}' is missing required 'deinit' method",
                            .{o.name},
                        );
                    }
                },
                else => {},
            }
        }
    }

    fn checkImpls(self: *Sema, file: *const ast.File, r: *SemaResult) !void {
        for (file.decls) |d| {
            switch (d) {
                .impl_block => |i| {
                    if (!r.traits.contains(i.trait_name)) {
                        try self.diags.emit(
                            .warning,
                            .z0001_unknown_trait,
                            i.span,
                            "impl references unknown trait '{s}'",
                            .{i.trait_name},
                        );
                        continue;
                    }
                    // Cross-check that every method declared by the trait is
                    // present in this impl. Missing methods → Z0040.
                    const methods = r.trait_methods.get(i.trait_name) orelse continue;
                    var missing: std.ArrayList([]const u8) = .{};
                    defer missing.deinit(self.allocator);
                    for (methods) |m| {
                        var found = false;
                        for (i.fns) |fd| {
                            if (std.mem.eql(u8, fd.sig.name, m.name)) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) try missing.append(self.allocator, m.name);
                    }
                    if (missing.items.len > 0) {
                        const list = try joinNames(self.allocator, missing.items);
                        defer self.allocator.free(list);
                        try self.diags.emit(
                            .err,
                            .z0040_impl_missing_method,
                            i.span,
                            "impl {s} for {s} is missing method(s): {s}",
                            .{ i.trait_name, i.target_type, list },
                        );
                    }
                },
                else => {},
            }
        }
    }

    fn checkParams(self: *Sema, file: *const ast.File, r: *SemaResult) !void {
        for (file.decls) |d| {
            switch (d) {
                .fn_decl => |fd| try self.checkFnParams(&fd, r),
                .impl_block => |ib| {
                    for (ib.fns) |fd| try self.checkFnParams(&fd, r);
                },
                .owned_struct => |os| {
                    for (os.fns) |fd| try self.checkFnParams(&fd, r);
                },
                .struct_decl => |sd| {
                    for (sd.fns) |fd| try self.checkFnParams(&fd, r);
                },
                else => {},
            }
        }
    }

    fn checkFnParams(self: *Sema, fd: *const ast.FnDecl, r: *SemaResult) !void {
        for (fd.sig.params) |p| {
            switch (p.mode) {
                .impl_trait, .dyn_trait => {
                    if (!r.traits.contains(p.type_text)) {
                        try self.diags.emit(
                            .warning,
                            .z0001_unknown_trait,
                            p.span,
                            "param '{s}' references unknown trait '{s}'",
                            .{ p.name, p.type_text },
                        );
                    }
                },
                else => {},
            }
        }
    }

    fn checkFunctions(self: *Sema, file: *const ast.File, r: *SemaResult) !void {
        for (file.decls) |d| {
            switch (d) {
                .fn_decl => |fd| try self.checkFnBody(&fd, r),
                .impl_block => |ib| for (ib.fns) |fd| try self.checkFnBody(&fd, r),
                .owned_struct => |os| for (os.fns) |fd| try self.checkFnBody(&fd, r),
                else => {},
            }
        }
    }

    fn checkFnBody(self: *Sema, fd: *const ast.FnDecl, r: *SemaResult) !void {
        const body = fd.body orelse return;
        try self.checkUsing(body, r);
        try self.checkMoves(body);
        // Z0030 (effect inference) is no longer per-fn — it's a whole-file
        // pass run from `analyze()` after the call graph has been built.
    }

    fn checkUsing(self: *Sema, body: ast.FnBody, r: *SemaResult) !void {
        for (body.stmts) |s| {
            switch (s) {
                .using_stmt => |u| {
                    // Heuristic: extract type name from init_text by walking back to find
                    // an identifier on the left side of `.init(` or constructor call.
                    const guess = guessTypeName(u.init_text);
                    if (guess) |name| {
                        if (r.owned_structs.get(name)) |has_deinit| {
                            if (!has_deinit) {
                                try self.diags.emit(
                                    .err,
                                    .z0011_using_type_lacks_deinit,
                                    u.span,
                                    "type '{s}' bound by 'using' has no deinit method",
                                    .{name},
                                );
                            }
                        }
                        // If the type isn't in our table we can't verify; emit a note only
                        // when it looks ambiguous. For MVP we stay quiet.
                    }
                },
                else => {},
            }
        }
    }

    /// One outstanding `&x` borrow recorded by `checkMoves`. `span` is the
    /// span of the surrounding statement (used for Z0021 messages).
    /// `scope_depth` is the lexical block depth at which the borrow was
    /// recorded — when execution later leaves a block (the brace counter
    /// drops below this depth) the record is retired.
    const BorrowRecord = struct {
        span: diag.Span,
        scope_depth: u32,
    };

    /// Per-name list of live borrows. We hand out and own the inner
    /// ArrayLists, so `deinitBorrows` releases each one.
    const BorrowMap = std.StringHashMap(std.ArrayList(BorrowRecord));

    fn deinitBorrows(self: *Sema, borrows: *BorrowMap) void {
        var it = borrows.valueIterator();
        while (it.next()) |list| list.deinit(self.allocator);
        borrows.deinit();
    }

    /// Drop every borrow record whose `scope_depth` is strictly greater
    /// than `new_depth`. Called after a `}` lowers the brace counter so
    /// that a `&x` inside `{ ... }` retires when the block closes.
    fn retireBorrowsBelow(self: *Sema, borrows: *BorrowMap, new_depth: u32) void {
        var it = borrows.iterator();
        while (it.next()) |entry| {
            const list = entry.value_ptr;
            var write: usize = 0;
            for (list.items) |rec| {
                if (rec.scope_depth <= new_depth) {
                    list.items[write] = rec;
                    write += 1;
                }
            }
            list.shrinkRetainingCapacity(write);
        }
        _ = self;
    }

    fn checkMoves(self: *Sema, body: ast.FnBody) !void {
        var moved = std.StringHashMap(diag.Span).init(self.allocator);
        defer moved.deinit();
        // Track names declared as `own var/const` so we know which identifiers
        // are subject to affine checking.
        var own_names = std.StringHashMap(void).init(self.allocator);
        defer own_names.deinit();
        // Borrow tracking (Z0021). Round 2 records ALL `&x` sites per name
        // and tags each with the lexical block depth at which it occurred.
        // When a `}` drops the depth past a recorded borrow, that borrow
        // retires. A subsequent `move x` therefore only fires Z0021 if at
        // least one record is still live in an enclosing scope.
        var borrows = BorrowMap.init(self.allocator);
        defer self.deinitBorrows(&borrows);
        // Lexical block depth tracked across raw stmts. Depth 0 == fn body
        // top level; nested `{ ... }` inside a single raw stmt push/pop.
        var depth: u32 = 0;

        for (body.stmts) |s| {
            switch (s) {
                .own_decl => |o| {
                    try own_names.put(o.name, {});
                    // re-binding rescinds prior moved status
                    _ = moved.remove(o.name);
                    // Re-bind also rescinds any outstanding borrow record:
                    // the new value is a fresh binding.
                    if (borrows.getPtr(o.name)) |list| list.clearRetainingCapacity();
                    // The init expression itself may borrow another name.
                    try self.scanRawText(o.init_text, o.span, null, &borrows, &moved, &own_names, &depth);
                },
                .move_expr_stmt => |m| {
                    try self.fireBorrowInvalidationIfLive(&borrows, m.target, m.span);
                    if (own_names.contains(m.target)) {
                        try moved.put(m.target, m.span);
                    }
                },
                .using_stmt => |u| {
                    if (moved.get(u.name)) |prev| {
                        try self.diags.emit(
                            .err,
                            .z0020_use_after_move,
                            u.span,
                            "use of '{s}' after move (moved at offset {d})",
                            .{ u.name, prev.start },
                        );
                    }
                    try self.scanRawText(u.init_text, u.span, null, &borrows, &moved, &own_names, &depth);
                },
                .raw => |raw| {
                    // First check uses against the moved set as it stands BEFORE
                    // this statement runs (so `move x` itself doesn't fire).
                    var it = moved.iterator();
                    while (it.next()) |entry| {
                        if (mentionsIdent(raw.text, entry.key_ptr.*)) {
                            try self.diags.emit(
                                .err,
                                .z0020_use_after_move,
                                raw.span,
                                "use of '{s}' after move",
                                .{entry.key_ptr.*},
                            );
                            _ = moved.remove(entry.key_ptr.*);
                        }
                    }
                    // Then walk the raw text once, in order, handling brace
                    // depth changes, `&ident` borrow sites and `move ident`
                    // sites together. This keeps the relative ordering
                    // correct when a single raw stmt opens a block, borrows
                    // inside it, closes the block (retiring the borrow) and
                    // then moves the same name — that case must NOT fire
                    // Z0021.
                    try self.scanRawText(raw.text, raw.span, raw.span, &borrows, &moved, &own_names, &depth);
                },
            }
        }
        // Defensive: at end-of-fn, clear anything left at depth > 0. The
        // body span itself counts as depth 0 in our model (matches the MVP
        // behaviour of borrows recorded at top level outliving the whole
        // body). Anything deeper would indicate an unbalanced raw stmt and
        // we just drop those records.
        self.retireBorrowsBelow(&borrows, 0);
    }

    /// Fire Z0021 once if `name` has at least one live borrow recorded.
    /// Includes the first live borrow's offset in the message so users can
    /// jump to the offending `&x`.
    fn fireBorrowInvalidationIfLive(
        self: *Sema,
        borrows: *BorrowMap,
        name: []const u8,
        move_span: diag.Span,
    ) !void {
        const list = borrows.getPtr(name) orelse return;
        if (list.items.len == 0) return;
        try self.diags.emit(
            .err,
            .z0021_borrow_invalidated_by_move,
            move_span,
            "cannot move '{s}' while borrowed (first borrow at offset {d})",
            .{ name, list.items[0].span.start },
        );
    }

    /// Walk `text` once, simultaneously handling:
    ///   - string / char / `//` comment skipping
    ///   - `{` / `}` depth tracking (mutating `*depth`; retiring borrows
    ///     whose `scope_depth` exceeds the new depth on each block `}`).
    ///     Struct / array literals (`.{...}`, `Foo{...}`) push a non-scope
    ///     frame so depth balance is preserved without retiring borrows
    ///     on their closing brace.
    ///   - `&ident` borrow recording (appended to `borrows[name]` at the
    ///     CURRENT depth)
    ///   - `move ident` sites (firing Z0021 if a live borrow exists, then
    ///     adding the name to `moved`)
    ///
    /// `stmt_span` is the span of the surrounding statement for diagnostic
    /// emission. `move_span` is the span used for Z0020/Z0021 reports — for
    /// raw stmts we want the whole stmt span so the squiggle covers the
    /// `move` site; for own_decl/using inits we pass `null` to suppress
    /// move scanning (those statement kinds don't carry inline `move`s).
    fn scanRawText(
        self: *Sema,
        text: []const u8,
        stmt_span: diag.Span,
        move_span: ?diag.Span,
        borrows: *BorrowMap,
        moved: *std.StringHashMap(diag.Span),
        own_names: *std.StringHashMap(void),
        depth: *u32,
    ) !void {
        // Local stack tagging each open `{` as a lexical scope (true) or
        // a value literal (false). A scope brace bumps `*depth`; a
        // literal brace doesn't, so the matching `}` pops without
        // retiring borrows. We can't use `*depth` alone because struct
        // literals (`.{ ... }`, `Foo{ ... }`) syntactically use `{` /
        // `}` but don't open a lexical scope.
        var brace_stack: std.ArrayList(bool) = .{};
        defer brace_stack.deinit(self.allocator);

        var i: usize = 0;
        while (i < text.len) {
            const c = text[i];
            // Skip over double-quoted string literals so braces / `&x` /
            // `move x` inside strings don't fool us.
            if (c == '"') {
                i += 1;
                while (i < text.len) : (i += 1) {
                    if (text[i] == '\\' and i + 1 < text.len) { i += 1; continue; }
                    if (text[i] == '"') { i += 1; break; }
                }
                continue;
            }
            // Skip over char literals.
            if (c == '\'') {
                i += 1;
                while (i < text.len and text[i] != '\'') : (i += 1) {
                    if (text[i] == '\\' and i + 1 < text.len) i += 1;
                }
                if (i < text.len) i += 1;
                continue;
            }
            // Skip over `//` line comments.
            if (c == '/' and i + 1 < text.len and text[i + 1] == '/') {
                while (i < text.len and text[i] != '\n') i += 1;
                continue;
            }
            // Brace depth tracking with kind classification.
            if (c == '{') {
                const is_scope = isScopeOpenBrace(text, i);
                try brace_stack.append(self.allocator, is_scope);
                if (is_scope) depth.* += 1;
                i += 1;
                continue;
            }
            if (c == '}') {
                const is_scope = if (brace_stack.items.len > 0)
                    brace_stack.pop().?
                else
                    true;
                if (is_scope and depth.* > 0) {
                    depth.* -= 1;
                    self.retireBorrowsBelow(borrows, depth.*);
                }
                i += 1;
                continue;
            }
            // `move <ident>` — only if move_span is non-null (i.e. caller
            // wants in-text move scanning).
            if (move_span) |ms| {
                if (c == 'm' and i + 4 < text.len and std.mem.startsWith(u8, text[i..], "move")) {
                    const prev_ok = i == 0 or !isIdent(text[i - 1]);
                    const after = i + 4;
                    const sep = if (after < text.len) text[after] else 0;
                    if (prev_ok and (sep == ' ' or sep == '\t')) {
                        var j = after + 1;
                        while (j < text.len and (text[j] == ' ' or text[j] == '\t')) j += 1;
                        const name_start = j;
                        while (j < text.len and isIdent(text[j])) j += 1;
                        if (j > name_start) {
                            const name = text[name_start..j];
                            try self.fireBorrowInvalidationIfLive(borrows, name, ms);
                            if (own_names.contains(name)) {
                                try moved.put(name, ms);
                            }
                            i = j;
                            continue;
                        }
                    }
                }
            }
            // `&ident` borrow recording.
            if (c == '&') {
                // `&&` is short-circuit AND (defensive — Zig uses `and`).
                if (i + 1 < text.len and text[i + 1] == '&') { i += 2; continue; }
                // `&` must not follow an identifier char (that would be
                // bitwise-and: `a & b`).
                if (i > 0 and isIdent(text[i - 1])) { i += 1; continue; }
                var j = i + 1;
                while (j < text.len and (text[j] == ' ' or text[j] == '\t')) j += 1;
                const name_start = j;
                while (j < text.len and isIdent(text[j])) j += 1;
                if (j > name_start) {
                    const name = text[name_start..j];
                    const first = name[0];
                    const is_value_ident = (first >= 'a' and first <= 'z') or first == '_';
                    if (is_value_ident) {
                        const gop = try borrows.getOrPut(name);
                        if (!gop.found_existing) {
                            gop.value_ptr.* = .{};
                        }
                        try gop.value_ptr.append(self.allocator, .{
                            .span = stmt_span,
                            .scope_depth = depth.*,
                        });
                    }
                    i = j;
                    continue;
                }
            }
            i += 1;
        }
    }

    /// Effect inference (Z0030). For each top-level fn we compute whether its
    /// body — directly or transitively through one round of fixed-point — has
    /// the `.alloc` effect. Then for every fn that *declares* `effects(.noalloc)`
    /// we emit Z0030 if the inferred set contains `.alloc`.
    ///
    /// Heuristic for "direct allocation": the body text contains a method call
    /// matching `.alloc(`, `.create(`, `.realloc(`, or `.dupe(` (after skipping
    /// strings / chars / line comments). This intentionally re-uses the same
    /// shape the previous Z0030 lint relied on.
    ///
    /// Heuristic for "calls into another fn": the body text contains `<name>(`
    /// for any `<name>` that appears in our local fn-name table. This captures
    /// both `try f(...)` and bare `f(...)` calls. Cross-file calls are not
    /// inferred (out of scope for the MVP).
    ///
    /// Fixed point: iterate until no fn flips from "no .alloc" to ".alloc".
    /// In the worst case this runs N rounds for N fns; in practice it
    /// terminates after one or two passes.
    fn checkEffectInference(self: *Sema, file: *const ast.File, result: *SemaResult) !void {
        // Collect all top-level fns (plain, owned-struct, struct, impl-block
        // members) into a flat list with stable indices.
        var fns: std.ArrayList(*const ast.FnDecl) = .{};
        defer fns.deinit(self.allocator);
        for (file.decls) |*d| {
            switch (d.*) {
                .fn_decl => |*fd| try fns.append(self.allocator, fd),
                .impl_block => |ib| for (ib.fns) |*fd| try fns.append(self.allocator, fd),
                .owned_struct => |os| for (os.fns) |*fd| try fns.append(self.allocator, fd),
                .struct_decl => |sd| for (sd.fns) |*fd| try fns.append(self.allocator, fd),
                else => {},
            }
        }
        if (fns.items.len == 0) return;

        // Map fn name → index. When two fns share a name (e.g. `init` on
        // multiple structs) the first wins; the heuristic doesn't try to
        // resolve overloads.
        var name_to_idx = std.StringHashMap(usize).init(self.allocator);
        defer name_to_idx.deinit();
        for (fns.items, 0..) |fd, i| {
            const gop = try name_to_idx.getOrPut(fd.sig.name);
            if (!gop.found_existing) gop.value_ptr.* = i;
        }

        // direct[i] = true if fn i's body has a literal `.alloc(`/`.create(`/
        //             `.realloc(`/`.dupe(` call (after skipping strings/chars/
        //             comments). Also used as the seed for the fixed point.
        // direct_span[i] = the first stmt span where the local allocation was
        //                  observed (used to anchor Z0030 at the offending
        //                  statement when possible).
        const N = fns.items.len;
        const direct = try self.allocator.alloc(bool, N);
        defer self.allocator.free(direct);
        const direct_span = try self.allocator.alloc(diag.Span, N);
        defer self.allocator.free(direct_span);
        const inferred = try self.allocator.alloc(bool, N);
        defer self.allocator.free(inferred);

        // calls[i] = list of callee indices that fn i references in its body
        // text. Only names present in `name_to_idx` are recorded.
        const calls = try self.allocator.alloc(std.ArrayList(usize), N);
        defer {
            for (calls) |*c| c.deinit(self.allocator);
            self.allocator.free(calls);
        }
        for (calls) |*c| c.* = .{};

        for (fns.items, 0..) |fd, i| {
            direct[i] = false;
            direct_span[i] = fd.sig.span;
            inferred[i] = false;
            const body = fd.body orelse continue;
            for (body.stmts) |s| {
                const text = switch (s) {
                    .raw => |r| r.text,
                    .using_stmt => |u| u.init_text,
                    .own_decl => |o| o.init_text,
                    else => continue,
                };
                if (!direct[i] and bodyAllocates(text)) {
                    direct[i] = true;
                    direct_span[i] = switch (s) {
                        .raw => |r| r.span,
                        .using_stmt => |u| u.span,
                        .own_decl => |o| o.span,
                        else => unreachable,
                    };
                }
                // Record local-fn calls. We scan once per stmt and dedupe via
                // the calls list (cheap for typical body sizes).
                try collectLocalCalls(text, &name_to_idx, &calls[i], self.allocator);
            }
            inferred[i] = direct[i];
        }

        // Fixed-point propagation: a fn inherits `.alloc` from any callee.
        // Capped at N+1 rounds to guard against pathological inputs (each
        // round flips at least one fn or terminates).
        var changed = true;
        var rounds: usize = 0;
        while (changed and rounds < N + 1) : (rounds += 1) {
            changed = false;
            for (fns.items, 0..) |_, i| {
                if (inferred[i]) continue;
                for (calls[i].items) |cid| {
                    if (inferred[cid]) {
                        inferred[i] = true;
                        changed = true;
                        break;
                    }
                }
            }
        }

        // Tee the inferred .alloc bit into result.inferred_effects so
        // callers (notably `@effectsOf(f)` lowering) can query the same
        // per-fn result the violation pass uses below. We OR into any
        // existing entry so the IO/panic passes can write the same
        // record without clobbering each other.
        for (fns.items, 0..) |fd, i| {
            const gop = try result.inferred_effects.getOrPut(fd.sig.name);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            gop.value_ptr.alloc = gop.value_ptr.alloc or inferred[i];
        }

        // Emit Z0030 for any fn that declares `.noalloc` and has inferred
        // `.alloc`. We prefer the direct-allocation span when available (the
        // local body itself allocates) and otherwise fall back to the fn's
        // signature span (purely transitive case).
        for (fns.items, 0..) |fd, i| {
            const ef = fd.sig.effects orelse continue;
            var declared_noalloc = false;
            for (ef.effects) |e| {
                if (e.kind == .noalloc) declared_noalloc = true;
            }
            if (!declared_noalloc) continue;
            if (!inferred[i]) continue;

            const span = if (direct[i]) direct_span[i] else fd.sig.span;
            if (direct[i]) {
                try self.diags.emit(
                    .err,
                    .z0030_effect_violation,
                    span,
                    "fn '{s}' declared .noalloc but inferred .alloc effect",
                    .{fd.sig.name},
                );
            } else {
                try self.diags.emit(
                    .err,
                    .z0030_effect_violation,
                    span,
                    "fn '{s}' declared .noalloc but inferred .alloc effect (transitively via a callee)",
                    .{fd.sig.name},
                );
            }
        }
    }

    /// Round 2 of the effect-inference MVP: same shape as
    /// `checkEffectInference` but for the `.io` / `.noio` pair instead of
    /// `.alloc` / `.noalloc`. Kept as a parallel pass (rather than fused with
    /// the `.alloc` pass) so the existing wiring is unchanged.
    ///
    /// Heuristic for "direct IO": the body text contains any of these
    /// substrings (after stripping strings / chars / `//` comments):
    ///   `std.debug.print`, `std.fs.`, `std.io.`, `std.process.`,
    ///   `std.net.`, `std.os.`, `std.posix.`, `try writer.`, `.writeAll(`,
    ///   `.writeLine(`, `.print(`, `.read(`, `.openFile(`, `.createFile(`.
    /// The set is intentionally narrow — broaden in a follow-up PR, not
    /// here.
    fn checkIoEffectInference(self: *Sema, file: *const ast.File, result: *SemaResult) !void {
        var fns: std.ArrayList(*const ast.FnDecl) = .{};
        defer fns.deinit(self.allocator);
        for (file.decls) |*d| {
            switch (d.*) {
                .fn_decl => |*fd| try fns.append(self.allocator, fd),
                .impl_block => |ib| for (ib.fns) |*fd| try fns.append(self.allocator, fd),
                .owned_struct => |os| for (os.fns) |*fd| try fns.append(self.allocator, fd),
                .struct_decl => |sd| for (sd.fns) |*fd| try fns.append(self.allocator, fd),
                else => {},
            }
        }
        if (fns.items.len == 0) return;

        var name_to_idx = std.StringHashMap(usize).init(self.allocator);
        defer name_to_idx.deinit();
        for (fns.items, 0..) |fd, i| {
            const gop = try name_to_idx.getOrPut(fd.sig.name);
            if (!gop.found_existing) gop.value_ptr.* = i;
        }

        const N = fns.items.len;
        const direct = try self.allocator.alloc(bool, N);
        defer self.allocator.free(direct);
        const direct_span = try self.allocator.alloc(diag.Span, N);
        defer self.allocator.free(direct_span);
        const inferred = try self.allocator.alloc(bool, N);
        defer self.allocator.free(inferred);

        const calls = try self.allocator.alloc(std.ArrayList(usize), N);
        defer {
            for (calls) |*c| c.deinit(self.allocator);
            self.allocator.free(calls);
        }
        for (calls) |*c| c.* = .{};

        for (fns.items, 0..) |fd, i| {
            direct[i] = false;
            direct_span[i] = fd.sig.span;
            inferred[i] = false;
            const body = fd.body orelse continue;
            for (body.stmts) |s| {
                const text = switch (s) {
                    .raw => |r| r.text,
                    .using_stmt => |u| u.init_text,
                    .own_decl => |o| o.init_text,
                    else => continue,
                };
                if (!direct[i] and bodyDoesIO(text)) {
                    direct[i] = true;
                    direct_span[i] = switch (s) {
                        .raw => |r| r.span,
                        .using_stmt => |u| u.span,
                        .own_decl => |o| o.span,
                        else => unreachable,
                    };
                }
                try collectLocalCalls(text, &name_to_idx, &calls[i], self.allocator);
            }
            inferred[i] = direct[i];
        }

        var changed = true;
        var rounds: usize = 0;
        while (changed and rounds < N + 1) : (rounds += 1) {
            changed = false;
            for (fns.items, 0..) |_, i| {
                if (inferred[i]) continue;
                for (calls[i].items) |cid| {
                    if (inferred[cid]) {
                        inferred[i] = true;
                        changed = true;
                        break;
                    }
                }
            }
        }

        // Tee the inferred .io bit into result.inferred_effects (see
        // `checkEffectInference` for the rationale). Other passes
        // populate other fields, so we OR into the existing record.
        for (fns.items, 0..) |fd, i| {
            const gop = try result.inferred_effects.getOrPut(fd.sig.name);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            gop.value_ptr.io = gop.value_ptr.io or inferred[i];
        }

        for (fns.items, 0..) |fd, i| {
            const ef = fd.sig.effects orelse continue;
            var declared_noio = false;
            for (ef.effects) |e| {
                if (e.kind == .noio) declared_noio = true;
            }
            if (!declared_noio) continue;
            if (!inferred[i]) continue;

            const span = if (direct[i]) direct_span[i] else fd.sig.span;
            if (direct[i]) {
                try self.diags.emit(
                    .err,
                    .z0030_effect_violation,
                    span,
                    "fn '{s}' declared .noio but inferred .io effect",
                    .{fd.sig.name},
                );
            } else {
                try self.diags.emit(
                    .err,
                    .z0030_effect_violation,
                    span,
                    "fn '{s}' declared .noio but inferred .io effect (transitively via a callee)",
                    .{fd.sig.name},
                );
            }
        }
    }

    /// Round 3 of the effect-inference MVP: same shape as
    /// `checkEffectInference` but for the `.panic` / `.nopanic` pair. Run as
    /// a parallel pass after `.alloc` and `.io` so existing wiring stays
    /// untouched.
    ///
    /// Heuristic for "direct panic": the body text contains any of these
    /// substrings (after stripping strings / chars / `//` line comments):
    ///   `@panic(`, `std.debug.assert(`, `std.debug.panic(`,
    ///   `std.process.exit(`, plus a NARROWED check for `unreachable` —
    ///   the bare keyword must follow either a newline or `=>` (so a
    ///   switch arm `else => unreachable` counts but `a or unreachable`
    ///   inside a long boolean chain does not). The narrowing keeps
    ///   examples that mention `unreachable` only inside doc comments or
    ///   quoted strings safe; the harness already strips strings so the
    ///   primary risk was idiomatic boolean chains.
    fn checkPanicEffectInference(self: *Sema, file: *const ast.File, result: *SemaResult) !void {
        var fns: std.ArrayList(*const ast.FnDecl) = .{};
        defer fns.deinit(self.allocator);
        for (file.decls) |*d| {
            switch (d.*) {
                .fn_decl => |*fd| try fns.append(self.allocator, fd),
                .impl_block => |ib| for (ib.fns) |*fd| try fns.append(self.allocator, fd),
                .owned_struct => |os| for (os.fns) |*fd| try fns.append(self.allocator, fd),
                .struct_decl => |sd| for (sd.fns) |*fd| try fns.append(self.allocator, fd),
                else => {},
            }
        }
        if (fns.items.len == 0) return;

        var name_to_idx = std.StringHashMap(usize).init(self.allocator);
        defer name_to_idx.deinit();
        for (fns.items, 0..) |fd, i| {
            const gop = try name_to_idx.getOrPut(fd.sig.name);
            if (!gop.found_existing) gop.value_ptr.* = i;
        }

        const N = fns.items.len;
        const direct = try self.allocator.alloc(bool, N);
        defer self.allocator.free(direct);
        const direct_span = try self.allocator.alloc(diag.Span, N);
        defer self.allocator.free(direct_span);
        const inferred = try self.allocator.alloc(bool, N);
        defer self.allocator.free(inferred);

        const calls = try self.allocator.alloc(std.ArrayList(usize), N);
        defer {
            for (calls) |*c| c.deinit(self.allocator);
            self.allocator.free(calls);
        }
        for (calls) |*c| c.* = .{};

        for (fns.items, 0..) |fd, i| {
            direct[i] = false;
            direct_span[i] = fd.sig.span;
            inferred[i] = false;
            const body = fd.body orelse continue;
            for (body.stmts) |s| {
                const text = switch (s) {
                    .raw => |r| r.text,
                    .using_stmt => |u| u.init_text,
                    .own_decl => |o| o.init_text,
                    else => continue,
                };
                if (!direct[i] and bodyMayPanic(text)) {
                    direct[i] = true;
                    direct_span[i] = switch (s) {
                        .raw => |r| r.span,
                        .using_stmt => |u| u.span,
                        .own_decl => |o| o.span,
                        else => unreachable,
                    };
                }
                try collectLocalCalls(text, &name_to_idx, &calls[i], self.allocator);
            }
            inferred[i] = direct[i];
        }

        var changed = true;
        var rounds: usize = 0;
        while (changed and rounds < N + 1) : (rounds += 1) {
            changed = false;
            for (fns.items, 0..) |_, i| {
                if (inferred[i]) continue;
                for (calls[i].items) |cid| {
                    if (inferred[cid]) {
                        inferred[i] = true;
                        changed = true;
                        break;
                    }
                }
            }
        }

        // Tee the inferred .panic bit into result.inferred_effects (see
        // `checkEffectInference` for the rationale).
        for (fns.items, 0..) |fd, i| {
            const gop = try result.inferred_effects.getOrPut(fd.sig.name);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            gop.value_ptr.panic = gop.value_ptr.panic or inferred[i];
        }

        for (fns.items, 0..) |fd, i| {
            const ef = fd.sig.effects orelse continue;
            var declared_nopanic = false;
            for (ef.effects) |e| {
                if (e.kind == .nopanic) declared_nopanic = true;
            }
            if (!declared_nopanic) continue;
            if (!inferred[i]) continue;

            const span = if (direct[i]) direct_span[i] else fd.sig.span;
            if (direct[i]) {
                try self.diags.emit(
                    .err,
                    .z0030_effect_violation,
                    span,
                    "fn '{s}' declared .nopanic but inferred .panic effect",
                    .{fd.sig.name},
                );
            } else {
                try self.diags.emit(
                    .err,
                    .z0030_effect_violation,
                    span,
                    "fn '{s}' declared .nopanic but inferred .panic effect (transitively via a callee)",
                    .{fd.sig.name},
                );
            }
        }
    }

    /// Round 6 of the effect-inference MVP: same shape as
    /// `checkPanicEffectInference` but for the `.async` / `.noasync` pair.
    /// Run as a parallel pass after `.panic` so existing wiring stays
    /// untouched.
    ///
    /// Heuristic for "direct async": the body text contains any of these
    /// substrings (after stripping strings / chars / `//` line comments):
    ///   `std.Thread.spawn`, `std.Thread.yield`, `TaskGroup`, `JoinHandle`,
    ///   `spawnWithToken`, `CancellationToken`, `zpp.async`, `async.spawn`,
    ///   `.spawn(`, `std.Io.` (forward-compat for Zig 0.17+ I/O), plus a
    ///   word-boundary check for the Zig keywords `await ` and `suspend `
    ///   (reserved for future use).
    ///
    /// `.noasync` is the corresponding denial. A fn that ends up with
    /// `.async` in its inferred set after the fixed-point loop and that
    /// declares `effects(.noasync)` triggers Z0030. The diagnostic is
    /// anchored at the offending body stmt when the direct heuristic
    /// matched in the same fn, otherwise at the fn's signature span
    /// (purely transitive case).
    fn checkAsyncEffectInference(self: *Sema, file: *const ast.File, result: *SemaResult) !void {
        var fns: std.ArrayList(*const ast.FnDecl) = .{};
        defer fns.deinit(self.allocator);
        for (file.decls) |*d| {
            switch (d.*) {
                .fn_decl => |*fd| try fns.append(self.allocator, fd),
                .impl_block => |ib| for (ib.fns) |*fd| try fns.append(self.allocator, fd),
                .owned_struct => |os| for (os.fns) |*fd| try fns.append(self.allocator, fd),
                .struct_decl => |sd| for (sd.fns) |*fd| try fns.append(self.allocator, fd),
                else => {},
            }
        }
        if (fns.items.len == 0) return;

        var name_to_idx = std.StringHashMap(usize).init(self.allocator);
        defer name_to_idx.deinit();
        for (fns.items, 0..) |fd, i| {
            const gop = try name_to_idx.getOrPut(fd.sig.name);
            if (!gop.found_existing) gop.value_ptr.* = i;
        }

        const N = fns.items.len;
        const direct = try self.allocator.alloc(bool, N);
        defer self.allocator.free(direct);
        const direct_span = try self.allocator.alloc(diag.Span, N);
        defer self.allocator.free(direct_span);
        const inferred = try self.allocator.alloc(bool, N);
        defer self.allocator.free(inferred);

        const calls = try self.allocator.alloc(std.ArrayList(usize), N);
        defer {
            for (calls) |*c| c.deinit(self.allocator);
            self.allocator.free(calls);
        }
        for (calls) |*c| c.* = .{};

        for (fns.items, 0..) |fd, i| {
            direct[i] = false;
            direct_span[i] = fd.sig.span;
            inferred[i] = false;
            const body = fd.body orelse continue;
            for (body.stmts) |s| {
                const text = switch (s) {
                    .raw => |r| r.text,
                    .using_stmt => |u| u.init_text,
                    .own_decl => |o| o.init_text,
                    else => continue,
                };
                if (!direct[i] and bodyDoesAsync(text)) {
                    direct[i] = true;
                    direct_span[i] = switch (s) {
                        .raw => |r| r.span,
                        .using_stmt => |u| u.span,
                        .own_decl => |o| o.span,
                        else => unreachable,
                    };
                }
                try collectLocalCalls(text, &name_to_idx, &calls[i], self.allocator);
            }
            inferred[i] = direct[i];
        }

        var changed = true;
        var rounds: usize = 0;
        while (changed and rounds < N + 1) : (rounds += 1) {
            changed = false;
            for (fns.items, 0..) |_, i| {
                if (inferred[i]) continue;
                for (calls[i].items) |cid| {
                    if (inferred[cid]) {
                        inferred[i] = true;
                        changed = true;
                        break;
                    }
                }
            }
        }

        // Tee the inferred .async bit into result.inferred_effects (see
        // `checkEffectInference` for the rationale).
        for (fns.items, 0..) |fd, i| {
            const gop = try result.inferred_effects.getOrPut(fd.sig.name);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            gop.value_ptr.@"async" = gop.value_ptr.@"async" or inferred[i];
        }

        for (fns.items, 0..) |fd, i| {
            const ef = fd.sig.effects orelse continue;
            var declared_noasync = false;
            for (ef.effects) |e| {
                if (e.kind == .noasync) declared_noasync = true;
            }
            if (!declared_noasync) continue;
            if (!inferred[i]) continue;

            const span = if (direct[i]) direct_span[i] else fd.sig.span;
            if (direct[i]) {
                try self.diags.emit(
                    .err,
                    .z0030_effect_violation,
                    span,
                    "fn '{s}' declared .noasync but inferred .async effect",
                    .{fd.sig.name},
                );
            } else {
                try self.diags.emit(
                    .err,
                    .z0030_effect_violation,
                    span,
                    "fn '{s}' declared .noasync but inferred .async effect (transitively via a callee)",
                    .{fd.sig.name},
                );
            }
        }
    }

    /// Round 5 of the effect-inference MVP: user-defined `.custom("X")`
    /// effects with `.nocustom("X")` as the matching denial.
    ///
    /// Unlike the alloc/io/panic passes (which infer effects from body
    /// substrings), `.custom("X")` is propagated **only** from explicit
    /// declarations. A fn carries `.custom("X")` iff
    ///
    ///   1. its own `effects(...)` annotation declares `.custom("X")`, OR
    ///   2. it calls (via `<name>(`) a same-file fn whose declared
    ///      `effects(...)` includes `.custom("X")` — propagated through
    ///      one fixed-point loop so transitive chains are caught.
    ///
    /// A fn that declares `effects(.nocustom("X"))` and ends up with
    /// `.custom("X")` in its inferred set triggers Z0060. The diagnostic
    /// is anchored at the fn's signature span (we don't try to localise
    /// to a body stmt — the call graph is name-only and we'd be guessing).
    fn checkCustomEffectInference(self: *Sema, file: *const ast.File, result: *SemaResult) !void {
        var fns: std.ArrayList(*const ast.FnDecl) = .{};
        defer fns.deinit(self.allocator);
        for (file.decls) |*d| {
            switch (d.*) {
                .fn_decl => |*fd| try fns.append(self.allocator, fd),
                .impl_block => |ib| for (ib.fns) |*fd| try fns.append(self.allocator, fd),
                .owned_struct => |os| for (os.fns) |*fd| try fns.append(self.allocator, fd),
                .struct_decl => |sd| for (sd.fns) |*fd| try fns.append(self.allocator, fd),
                else => {},
            }
        }
        if (fns.items.len == 0) return;

        var name_to_idx = std.StringHashMap(usize).init(self.allocator);
        defer name_to_idx.deinit();
        for (fns.items, 0..) |fd, i| {
            const gop = try name_to_idx.getOrPut(fd.sig.name);
            if (!gop.found_existing) gop.value_ptr.* = i;
        }

        const N = fns.items.len;

        // Per-fn declared-custom set (the seed) and inferred-custom set
        // (post fixed-point). Both are arrays of name slices, deduplicated.
        const declared = try self.allocator.alloc(std.ArrayList([]const u8), N);
        defer {
            for (declared) |*l| l.deinit(self.allocator);
            self.allocator.free(declared);
        }
        for (declared) |*l| l.* = .{};
        const inferred = try self.allocator.alloc(std.ArrayList([]const u8), N);
        defer {
            for (inferred) |*l| l.deinit(self.allocator);
            self.allocator.free(inferred);
        }
        for (inferred) |*l| l.* = .{};

        // Per-fn local-call edges (same shape as the other passes).
        const calls = try self.allocator.alloc(std.ArrayList(usize), N);
        defer {
            for (calls) |*c| c.deinit(self.allocator);
            self.allocator.free(calls);
        }
        for (calls) |*c| c.* = .{};

        // Seed: collect each fn's declared `.custom("X")` names and record
        // the body's local-fn callee edges. `.nocustom(...)` is NOT seeded
        // — it's purely a denial (checked at the end against the inferred
        // set).
        for (fns.items, 0..) |fd, i| {
            if (fd.sig.effects) |ef| {
                for (ef.effects) |e| {
                    if (e.kind == .custom and e.name.len > 0) {
                        _ = try addUniqueName(&declared[i], self.allocator, e.name);
                        _ = try addUniqueName(&inferred[i], self.allocator, e.name);
                    }
                }
            }
            const body = fd.body orelse continue;
            for (body.stmts) |s| {
                const text = switch (s) {
                    .raw => |r| r.text,
                    .using_stmt => |u| u.init_text,
                    .own_decl => |o| o.init_text,
                    else => continue,
                };
                try collectLocalCalls(text, &name_to_idx, &calls[i], self.allocator);
            }
        }

        // Fixed-point: a fn inherits every `.custom("X")` declared by any
        // fn it calls. Propagation reads from `declared` (the explicit
        // annotation set) so a chain A→B→C with C declaring `.custom("X")`
        // still flows up to A. Cap at N+1 rounds; in practice converges in
        // one or two passes.
        var changed = true;
        var rounds: usize = 0;
        while (changed and rounds < N + 1) : (rounds += 1) {
            changed = false;
            for (fns.items, 0..) |_, i| {
                for (calls[i].items) |cid| {
                    for (declared[cid].items) |name| {
                        if (try addUniqueName(&inferred[i], self.allocator, name)) {
                            changed = true;
                        }
                    }
                    // Also propagate already-inferred names from the callee
                    // so transitive chains converge in fewer rounds.
                    for (inferred[cid].items) |name| {
                        if (try addUniqueName(&inferred[i], self.allocator, name)) {
                            changed = true;
                        }
                    }
                }
            }
        }

        // Tee inferred custom-effect names into the result table so
        // `@effectsOf(<ident>)` lowering can render them.
        for (fns.items, 0..) |fd, i| {
            if (inferred[i].items.len == 0) continue;
            const gop = try result.inferred_custom_effects.getOrPut(fd.sig.name);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            for (inferred[i].items) |name| {
                _ = try addUniqueName(gop.value_ptr, self.allocator, name);
            }
        }

        // Z0060: emit on every (fn, X) pair where the fn declares
        // `.nocustom("X")` and the inferred set contains `.custom("X")`.
        for (fns.items, 0..) |fd, i| {
            const ef = fd.sig.effects orelse continue;
            for (ef.effects) |e| {
                if (e.kind != .nocustom) continue;
                if (e.name.len == 0) continue;
                var present = false;
                for (inferred[i].items) |n| {
                    if (std.mem.eql(u8, n, e.name)) { present = true; break; }
                }
                if (!present) continue;
                try self.diags.emit(
                    .err,
                    .z0060_custom_effect_violation,
                    fd.sig.span,
                    "fn '{s}' declared .nocustom(\"{s}\") but inferred .custom(\"{s}\") effect",
                    .{ fd.sig.name, e.name, e.name },
                );
            }
        }
    }
};

/// Append `name` to `list` if it isn't already present (string comparison).
/// Returns true when an insertion occurred. Slices stored verbatim — they
/// reference source / AST arena memory that outlives this pass.
fn addUniqueName(
    list: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    name: []const u8,
) !bool {
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, name)) return false;
    }
    try list.append(allocator, name);
    return true;
}

/// Heuristic: does `text` look like an allocator-using call? We check for
/// identifiers containing "alloc"/"init"/"create" near a token that resembles
/// an allocator argument. For MVP we keep this loose.
/// Join name slices into a single comma-separated string. Caller frees.
fn joinNames(allocator: std.mem.Allocator, names: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);
    for (names, 0..) |n, i| {
        if (i > 0) try out.appendSlice(allocator, ", ");
        try out.append(allocator, '\'');
        try out.appendSlice(allocator, n);
        try out.append(allocator, '\'');
    }
    return out.toOwnedSlice(allocator);
}

/// Heuristic for "this body directly allocates": look for a method-call
/// shape `.alloc(`, `.create(`, `.realloc(`, or `.dupe(` anywhere in `text`,
/// after stripping string / char literals and `//` comments so allocator
/// names mentioned in error messages don't trip the check.
fn bodyAllocates(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        // Skip over double-quoted string literals.
        if (c == '"') {
            i += 1;
            while (i < text.len) : (i += 1) {
                if (text[i] == '\\' and i + 1 < text.len) { i += 1; continue; }
                if (text[i] == '"') { i += 1; break; }
            }
            continue;
        }
        // Skip over char literals.
        if (c == '\'') {
            i += 1;
            while (i < text.len and text[i] != '\'') : (i += 1) {
                if (text[i] == '\\' and i + 1 < text.len) i += 1;
            }
            if (i < text.len) i += 1;
            continue;
        }
        // Skip over `//` line comments.
        if (c == '/' and i + 1 < text.len and text[i + 1] == '/') {
            while (i < text.len and text[i] != '\n') i += 1;
            continue;
        }
        // Look for `.<name>(` where <name> ∈ {alloc, create, realloc, dupe}.
        // The trailing `(` doubles as a token-boundary check — `.allocator(`
        // won't match because text after `alloc` would be `a`, not `(`.
        if (c == '.') {
            const after_dot = i + 1;
            inline for (.{ "alloc", "create", "realloc", "dupe" }) |needle| {
                if (after_dot + needle.len < text.len and
                    std.mem.eql(u8, text[after_dot .. after_dot + needle.len], needle) and
                    text[after_dot + needle.len] == '(')
                {
                    return true;
                }
            }
        }
        i += 1;
    }
    return false;
}

/// Heuristic for "this body performs IO": scan `text` for any of the
/// substrings below, after stripping string / char literals and `//` line
/// comments. The set is intentionally narrow — keep it documented next to
/// the docs/src/v0.2-plan.md "Effect inference" section before adding more.
///
///   `std.debug.print`, `std.fs.`, `std.io.`, `std.process.`, `std.net.`,
///   `std.os.`, `std.posix.`, `try writer.`, `.writeAll(`, `.writeLine(`,
///   `.print(`, `.read(`, `.openFile(`, `.createFile(`.
fn bodyDoesIO(text: []const u8) bool {
    const needles = [_][]const u8{
        "std.debug.print",
        "std.fs.",
        "std.io.",
        "std.process.",
        "std.net.",
        "std.os.",
        "std.posix.",
        "try writer.",
        ".writeAll(",
        ".writeLine(",
        ".print(",
        ".read(",
        ".openFile(",
        ".createFile(",
    };
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        // Skip over double-quoted string literals.
        if (c == '"') {
            i += 1;
            while (i < text.len) : (i += 1) {
                if (text[i] == '\\' and i + 1 < text.len) { i += 1; continue; }
                if (text[i] == '"') { i += 1; break; }
            }
            continue;
        }
        // Skip over char literals.
        if (c == '\'') {
            i += 1;
            while (i < text.len and text[i] != '\'') : (i += 1) {
                if (text[i] == '\\' and i + 1 < text.len) i += 1;
            }
            if (i < text.len) i += 1;
            continue;
        }
        // Skip over `//` line comments.
        if (c == '/' and i + 1 < text.len and text[i + 1] == '/') {
            while (i < text.len and text[i] != '\n') i += 1;
            continue;
        }
        // Try every substring at this position.
        inline for (needles) |needle| {
            if (i + needle.len <= text.len and
                std.mem.eql(u8, text[i .. i + needle.len], needle))
            {
                return true;
            }
        }
        i += 1;
    }
    return false;
}

/// Heuristic for "this body may panic": scan `text` for any of the
/// substrings below, after stripping string / char literals and `//` line
/// comments. The set is intentionally small — keep it documented next to
/// the docs/src/v0.2-plan.md "Effect inference" section before adding more.
///
///   `@panic(`, `std.debug.assert(`, `std.debug.panic(`,
///   `std.process.exit(`, plus a NARROWED `unreachable` check (must
///   appear at a stmt-like position — preceded by `\n` or `=>`).
///
/// The `unreachable` narrowing avoids firing on idiomatic Zig boolean
/// chains like `cond or unreachable` inside expressions; it still
/// catches the common switch-arm form `else => unreachable` and
/// stand-alone `unreachable;` statements.
fn bodyMayPanic(text: []const u8) bool {
    const needles = [_][]const u8{
        "@panic(",
        "std.debug.assert(",
        "std.debug.panic(",
        "std.process.exit(",
    };
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        // Skip over double-quoted string literals.
        if (c == '"') {
            i += 1;
            while (i < text.len) : (i += 1) {
                if (text[i] == '\\' and i + 1 < text.len) { i += 1; continue; }
                if (text[i] == '"') { i += 1; break; }
            }
            continue;
        }
        // Skip over char literals.
        if (c == '\'') {
            i += 1;
            while (i < text.len and text[i] != '\'') : (i += 1) {
                if (text[i] == '\\' and i + 1 < text.len) i += 1;
            }
            if (i < text.len) i += 1;
            continue;
        }
        // Skip over `//` line comments.
        if (c == '/' and i + 1 < text.len and text[i + 1] == '/') {
            while (i < text.len and text[i] != '\n') i += 1;
            continue;
        }
        // Try every fixed-string substring at this position.
        inline for (needles) |needle| {
            if (i + needle.len <= text.len and
                std.mem.eql(u8, text[i .. i + needle.len], needle))
            {
                return true;
            }
        }
        // Narrowed `unreachable` check: bare keyword at a stmt-like
        // position. Must be preceded by either start-of-text, `\n`, `;`,
        // `{`, `}`, or follow a `=>` (after optional whitespace) so that
        // switch arms like `else => unreachable` count, but a chain like
        // `(cond or unreachable)` does not.
        if (c == 'u' and i + "unreachable".len <= text.len and
            std.mem.eql(u8, text[i .. i + "unreachable".len], "unreachable"))
        {
            // It must be a whole token (not a prefix of `unreachableX`).
            const after_idx = i + "unreachable".len;
            const is_word_boundary_after = after_idx >= text.len or !isIdent(text[after_idx]);
            // It must not be part of a longer identifier on the left.
            const is_word_boundary_before = i == 0 or !isIdent(text[i - 1]);
            if (is_word_boundary_after and is_word_boundary_before) {
                // Walk backwards over spaces / tabs to find the previous
                // non-space byte and decide whether the position looks
                // statement-like.
                var k: usize = i;
                while (k > 0) {
                    k -= 1;
                    const pc = text[k];
                    if (pc == ' ' or pc == '\t') continue;
                    // `=>` arm form.
                    if (pc == '>' and k > 0 and text[k - 1] == '=') return true;
                    // Stmt boundaries.
                    if (pc == '\n' or pc == ';' or pc == '{' or pc == '}') return true;
                    break;
                }
                // If we walked all the way to the start of text it's also a
                // statement-like position (bare body of a fn).
                if (k == 0) {
                    const pc = text[0];
                    if (pc == ' ' or pc == '\t' or pc == '\n') return true;
                }
            }
        }
        i += 1;
    }
    return false;
}

/// Heuristic for "this body performs an async / concurrency action": scan
/// `text` for any of the substrings below, after stripping string / char
/// literals and `//` line comments. The set targets the explicit Zig++
/// concurrency surface (`zpp.async_mod.TaskGroup`, `JoinHandle`,
/// `CancellationToken`, `spawnWithToken`) plus the std-lib threading
/// primitives (`std.Thread.spawn`, `std.Thread.yield`) and the forward-
/// compat `std.Io.` prefix from Zig 0.17+. The Zig keywords `await ` and
/// `suspend ` are also matched — they're reserved for future use, but
/// flagging them keeps `.noasync` honest if they reappear.
///
/// The trailing space on `await ` / `suspend ` is intentional: it's a
/// poor-man's word-boundary check that prevents `awaitable` /
/// `suspended` from matching, while still catching the canonical stmt
/// form `await foo(...);` and `suspend { ... }`.
fn bodyDoesAsync(text: []const u8) bool {
    const needles = [_][]const u8{
        "std.Thread.spawn",
        "std.Thread.yield",
        "TaskGroup",
        "JoinHandle",
        "spawnWithToken",
        "CancellationToken",
        "zpp.async",
        "async.spawn",
        ".spawn(",
        "std.Io.",
        "await ",
        "suspend ",
    };
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        // Skip over double-quoted string literals.
        if (c == '"') {
            i += 1;
            while (i < text.len) : (i += 1) {
                if (text[i] == '\\' and i + 1 < text.len) { i += 1; continue; }
                if (text[i] == '"') { i += 1; break; }
            }
            continue;
        }
        // Skip over char literals.
        if (c == '\'') {
            i += 1;
            while (i < text.len and text[i] != '\'') : (i += 1) {
                if (text[i] == '\\' and i + 1 < text.len) i += 1;
            }
            if (i < text.len) i += 1;
            continue;
        }
        // Skip over `//` line comments.
        if (c == '/' and i + 1 < text.len and text[i + 1] == '/') {
            while (i < text.len and text[i] != '\n') i += 1;
            continue;
        }
        // Try every fixed-string substring at this position. For
        // identifier-shaped needles (those starting with an identifier
        // char) require a left word boundary so e.g. `myTaskGroup`
        // does not match `TaskGroup`. Dot/`.spawn(`-style needles
        // always start non-ident so the boundary check is a no-op.
        const left_is_ident = i > 0 and isIdent(text[i - 1]);
        inline for (needles) |needle| {
            const ident_start = comptime isIdent(needle[0]);
            const blocked = ident_start and left_is_ident;
            if (!blocked and i + needle.len <= text.len and
                std.mem.eql(u8, text[i .. i + needle.len], needle))
            {
                return true;
            }
        }
        i += 1;
    }
    return false;
}

/// Scan `text` for any identifier in `name_to_idx` that is followed (after
/// whitespace) by `(`. Append each matched callee's index into `out`,
/// deduplicating against entries already present. Skips strings / chars /
/// `//` comments so source written in messages doesn't count.
fn collectLocalCalls(
    text: []const u8,
    name_to_idx: *const std.StringHashMap(usize),
    out: *std.ArrayList(usize),
    allocator: std.mem.Allocator,
) !void {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '"') {
            i += 1;
            while (i < text.len) : (i += 1) {
                if (text[i] == '\\' and i + 1 < text.len) { i += 1; continue; }
                if (text[i] == '"') { i += 1; break; }
            }
            continue;
        }
        if (c == '\'') {
            i += 1;
            while (i < text.len and text[i] != '\'') : (i += 1) {
                if (text[i] == '\\' and i + 1 < text.len) i += 1;
            }
            if (i < text.len) i += 1;
            continue;
        }
        if (c == '/' and i + 1 < text.len and text[i + 1] == '/') {
            while (i < text.len and text[i] != '\n') i += 1;
            continue;
        }
        if (isIdent(c)) {
            // Identifier-prefix-of-an-identifier (e.g. the `foo` in `foobar`)
            // would pre-emptively match — guard with a "previous char was not
            // an identifier char" check.
            if (i > 0 and isIdent(text[i - 1])) {
                i += 1;
                continue;
            }
            const start = i;
            while (i < text.len and isIdent(text[i])) i += 1;
            const tok = text[start..i];
            // Skip whitespace and look for `(`.
            var j = i;
            while (j < text.len and (text[j] == ' ' or text[j] == '\t')) j += 1;
            if (j < text.len and text[j] == '(') {
                if (name_to_idx.get(tok)) |idx| {
                    var present = false;
                    for (out.items) |existing| {
                        if (existing == idx) { present = true; break; }
                    }
                    if (!present) try out.append(allocator, idx);
                }
            }
            continue;
        }
        i += 1;
    }
}

fn mentionsIdent(text: []const u8, name: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        // Skip over double-quoted string literals so identifiers mentioned in
        // a debug message don't count as a use.
        if (c == '"') {
            i += 1;
            while (i < text.len) : (i += 1) {
                if (text[i] == '\\' and i + 1 < text.len) { i += 1; continue; }
                if (text[i] == '"') { i += 1; break; }
            }
            continue;
        }
        // Skip over char literals likewise.
        if (c == '\'') {
            i += 1;
            while (i < text.len and text[i] != '\'') : (i += 1) {
                if (text[i] == '\\' and i + 1 < text.len) i += 1;
            }
            if (i < text.len) i += 1;
            continue;
        }
        // Skip over `//` line comments.
        if (c == '/' and i + 1 < text.len and text[i + 1] == '/') {
            while (i < text.len and text[i] != '\n') i += 1;
            continue;
        }
        if (isIdent(c)) {
            const start = i;
            while (i < text.len and isIdent(text[i])) i += 1;
            if (std.mem.eql(u8, text[start..i], name)) return true;
        } else {
            i += 1;
        }
    }
    return false;
}

fn isIdent(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

/// Returns true if the `{` at byte offset `at` opens a lexical scope
/// (fn body, `if (cond) { ... }`, bare block) and false if it opens a
/// value literal (`.{ ... }`, `Foo{ ... }`, `[N]u8{ ... }`). The
/// heuristic walks back over whitespace and inspects the previous
/// significant byte:
///
///   - `.` → `.{` anonymous struct/array literal → literal
///   - identifier char or `]` or `?` → `Foo{...}`, `[N]u8{...}` →
///     literal (unless the identifier is a scope-introducing keyword
///     like `else`, `comptime`, `defer`, ...)
///   - everything else (`)`, `}`, `;`, `=>`, `,`, start of text, ...)
///     → scope
fn isScopeOpenBrace(text: []const u8, at: usize) bool {
    if (at == 0) return true;
    var k: usize = at;
    while (k > 0) {
        k -= 1;
        const c = text[k];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') continue;
        if (c == '.') return false;
        if (c == ']' or c == '?') return false;
        if (isIdent(c)) {
            // Distinguish `Foo{...}` (literal) from `else { ... }` /
            // `comptime { ... }` / etc. (scope). Walk back to the
            // start of the identifier and compare against scope-
            // introducing keywords.
            const end = k + 1;
            var t = k;
            while (t > 0 and isIdent(text[t - 1])) t -= 1;
            const word = text[t..end];
            const scope_kws = [_][]const u8{
                "else", "do", "try", "comptime", "inline", "noinline",
                "defer", "errdefer", "return", "break", "continue", "and",
                "or", "test", "blk",
            };
            for (scope_kws) |kw| {
                if (std.mem.eql(u8, word, kw)) return true;
            }
            return false;
        }
        return true;
    }
    return true;
}

/// Try to extract a constructor type name from an init expression like
/// `try Foo.init(x)` or `Foo{ ... }` → "Foo".
fn guessTypeName(text: []const u8) ?[]const u8 {
    var s = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.startsWith(u8, s, "try ")) s = std.mem.trim(u8, s[4..], " \t\r\n");
    var i: usize = 0;
    while (i < s.len and isIdent(s[i])) i += 1;
    if (i == 0) return null;
    return s[0..i];
}

test "sema flags missing deinit" {
    const a = std.testing.allocator;
    const parser = @import("parser.zig");

    var diags = diag.Diagnostics.init(a);
    defer diags.deinit();
    var arena = ast.Arena.init(a);
    defer arena.deinit();

    const src = "owned struct Foo { x: i32, pub fn other(self: *Foo) void { _ = self; } }";
    const file = try parser.parseSource(a, src, &arena, &diags);
    var sema = Sema.init(a, &diags);
    var res = try sema.analyze(&file);
    defer res.deinit();
    try std.testing.expect(diags.hasErrors());
}

test "sema accepts owned struct with deinit" {
    const a = std.testing.allocator;
    const parser = @import("parser.zig");

    var diags = diag.Diagnostics.init(a);
    defer diags.deinit();
    var arena = ast.Arena.init(a);
    defer arena.deinit();

    const src = "owned struct Foo { x: i32, pub fn deinit(self: *Foo) void { _ = self; } }";
    const file = try parser.parseSource(a, src, &arena, &diags);
    var sema = Sema.init(a, &diags);
    var res = try sema.analyze(&file);
    defer res.deinit();
    try std.testing.expect(!diags.hasErrors());
}

test "sema use after move" {
    const a = std.testing.allocator;
    const parser = @import("parser.zig");

    var diags = diag.Diagnostics.init(a);
    defer diags.deinit();
    var arena = ast.Arena.init(a);
    defer arena.deinit();

    const src =
        \\fn f() void {
        \\    own var x = 1;
        \\    move x;
        \\    _ = x + 1;
        \\}
    ;
    const file = try parser.parseSource(a, src, &arena, &diags);
    var sema = Sema.init(a, &diags);
    var res = try sema.analyze(&file);
    defer res.deinit();
    try std.testing.expect(diags.hasErrors());
}
