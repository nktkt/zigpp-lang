const std = @import("std");
const ast = @import("ast.zig");
const diag = @import("diagnostics.zig");

/// Per-fn effect set produced by the inference passes. Each flag is true
/// iff sema's heuristic concluded the fn (transitively) exhibits that
/// effect. Used by `@effectsOf(f)` lowering and by the Z0030 violation
/// emitter.
pub const InferredEffects = packed struct {
    alloc: bool = false,
    io: bool = false,
    panic: bool = false,
};

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
    /// Inferred effect set per same-file fn name. Populated by the three
    /// `check*EffectInference` passes (each tees its result into this
    /// table at the end of the fixed-point loop). When two fns share a
    /// name (e.g. `init` on multiple structs) the first one wins — the
    /// MVP does not resolve overloads.
    inferred_effects: std.StringHashMap(InferredEffects),

    pub fn deinit(self: *SemaResult) void {
        self.traits.deinit();
        self.trait_methods.deinit();
        self.owned_structs.deinit();
        self.inferred_effects.deinit();
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

    fn checkMoves(self: *Sema, body: ast.FnBody) !void {
        var moved = std.StringHashMap(diag.Span).init(self.allocator);
        defer moved.deinit();
        // Track names declared as `own var/const` so we know which identifiers
        // are subject to affine checking.
        var own_names = std.StringHashMap(void).init(self.allocator);
        defer own_names.deinit();
        // Borrow tracking (Z0021). For the MVP we only remember the FIRST
        // `&x` per fn body (scope-local; the map is reset between fns). When
        // we later see `move x` while `x` is borrowed we fire Z0021. Multi-
        // borrow tracking (vector of spans per name) is a follow-up.
        var borrows = std.StringHashMap(diag.Span).init(self.allocator);
        defer borrows.deinit();

        for (body.stmts) |s| {
            switch (s) {
                .own_decl => |o| {
                    try own_names.put(o.name, {});
                    // re-binding rescinds prior moved status
                    _ = moved.remove(o.name);
                    // Re-bind also rescinds any outstanding borrow record:
                    // the new value is a fresh binding.
                    _ = borrows.remove(o.name);
                    // The init expression itself may borrow another name.
                    try self.recordBorrows(o.init_text, o.span, &borrows);
                },
                .move_expr_stmt => |m| {
                    if (own_names.contains(m.target)) {
                        try moved.put(m.target, m.span);
                    }
                    if (borrows.contains(m.target)) {
                        try self.diags.emit(
                            .err,
                            .z0021_borrow_invalidated_by_move,
                            m.span,
                            "cannot move '{s}' while borrowed",
                            .{m.target},
                        );
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
                    try self.recordBorrows(u.init_text, u.span, &borrows);
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
                    // Then scan THIS statement's text for `move <ident>` patterns
                    // and record them so the next statement sees them as moved.
                    // If the moved name has an outstanding borrow recorded
                    // earlier in this function body, fire Z0021 instead of
                    // (in addition to) Z0020.
                    var off: usize = 0;
                    while (findMoveTarget(raw.text, off)) |found| {
                        if (borrows.contains(found.name)) {
                            try self.diags.emit(
                                .err,
                                .z0021_borrow_invalidated_by_move,
                                raw.span,
                                "cannot move '{s}' while borrowed",
                                .{found.name},
                            );
                        }
                        if (own_names.contains(found.name)) {
                            try moved.put(found.name, raw.span);
                        }
                        off = found.end;
                    }
                    // Finally scan the same statement's text for new borrow
                    // patterns (`&<ident>` / `&<ident>.field`) and record
                    // the FIRST borrow per name. Order vs the move scan
                    // above means a single stmt that borrows then moves is
                    // not flagged — that's an acceptable false-negative
                    // for the MVP (the heuristic is conservative).
                    try self.recordBorrows(raw.text, raw.span, &borrows);
                },
            }
        }
    }

    /// Scan `text` for `&<ident>` (optionally followed by `.<field>`) and
    /// record the FIRST borrow span per identifier into `borrows`. Skips
    /// strings, char literals and `//` comments the same way `mentionsIdent`
    /// does so that an `&x` mentioned in a debug message doesn't count as
    /// a borrow.
    fn recordBorrows(
        self: *Sema,
        text: []const u8,
        span: diag.Span,
        borrows: *std.StringHashMap(diag.Span),
    ) !void {
        _ = self;
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
            if (c == '&') {
                // Skip `&&` (short-circuit AND in patterns we may add later
                // — Zig itself uses `and`, but be defensive).
                if (i + 1 < text.len and text[i + 1] == '&') { i += 2; continue; }
                // The `&` must be a prefix on an identifier — i.e. NOT
                // preceded by an identifier char (which would make it a
                // bitwise-and like `a & b`).
                if (i > 0 and isIdent(text[i - 1])) { i += 1; continue; }
                var j = i + 1;
                // Permit a single leading `*` for `&*ptr` (Zig pointer deref
                // followed by address-of is uncommon but harmless to skip).
                while (j < text.len and (text[j] == ' ' or text[j] == '\t')) j += 1;
                const name_start = j;
                while (j < text.len and isIdent(text[j])) j += 1;
                if (j > name_start) {
                    const name = text[name_start..j];
                    // Don't record borrows of obvious vtable / type names
                    // (anything starting with an uppercase letter). The
                    // heuristic is: lower-case-leading identifiers are
                    // value bindings; capitalised ones are types/vtables.
                    // This keeps existing examples (`&Handler_impl_for_X`)
                    // out of the borrow set.
                    const first = name[0];
                    const is_value_ident = (first >= 'a' and first <= 'z') or first == '_';
                    if (is_value_ident) {
                        const gop = try borrows.getOrPut(name);
                        if (!gop.found_existing) gop.value_ptr.* = span;
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
};

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

/// Find the next occurrence of `move <ident>` starting at `from`. Returns
/// the identifier text and the byte offset just past it, or null.
fn findMoveTarget(text: []const u8, from: usize) ?struct { name: []const u8, end: usize } {
    var i = from;
    while (i + 4 < text.len) : (i += 1) {
        if (!std.mem.startsWith(u8, text[i..], "move")) continue;
        if (i > 0 and isIdent(text[i - 1])) continue;
        const after = i + 4;
        if (after >= text.len) return null;
        const sep = text[after];
        if (sep != ' ' and sep != '\t') continue;
        var j = after + 1;
        while (j < text.len and (text[j] == ' ' or text[j] == '\t')) j += 1;
        const name_start = j;
        while (j < text.len and isIdent(text[j])) j += 1;
        if (j > name_start) {
            return .{ .name = text[name_start..j], .end = j };
        }
    }
    return null;
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
