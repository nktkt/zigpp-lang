const std = @import("std");
const ast = @import("ast.zig");
const diag = @import("diagnostics.zig");

/// Result of semantic analysis. The maps are owned by `deinit`.
pub const SemaResult = struct {
    allocator: std.mem.Allocator,
    /// Set of trait names declared in the file.
    traits: std.StringHashMap(void),
    /// Map of owned-struct names → whether they have a deinit method.
    owned_structs: std.StringHashMap(bool),

    pub fn deinit(self: *SemaResult) void {
        self.traits.deinit();
        self.owned_structs.deinit();
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
            .owned_structs = std.StringHashMap(bool).init(self.allocator),
        };
        errdefer result.deinit();

        try self.collectDecls(file, &result);
        try self.checkOwnedStructs(file, &result);
        try self.checkImpls(file, &result);
        try self.checkParams(file, &result);
        try self.checkFunctions(file, &result);

        return result;
    }

    fn collectDecls(self: *Sema, file: *const ast.File, r: *SemaResult) !void {
        _ = self;
        for (file.decls) |d| {
            switch (d) {
                .trait => |t| try r.traits.put(t.name, {}),
                .extern_interface => |e| try r.traits.put(e.name, {}),
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
        try self.checkEffects(fd, body);
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

        for (body.stmts) |s| {
            switch (s) {
                .own_decl => |o| {
                    try own_names.put(o.name, {});
                    // re-binding rescinds prior moved status
                    _ = moved.remove(o.name);
                },
                .move_expr_stmt => |m| {
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
                    var off: usize = 0;
                    while (findMoveTarget(raw.text, off)) |found| {
                        if (own_names.contains(found.name)) {
                            try moved.put(found.name, raw.span);
                        }
                        off = found.end;
                    }
                },
            }
        }
    }

    fn checkEffects(self: *Sema, fd: *const ast.FnDecl, body: ast.FnBody) !void {
        const ef = fd.sig.effects orelse return;
        var noalloc = false;
        for (ef.effects) |e| {
            if (e.kind == .noalloc) noalloc = true;
        }
        if (!noalloc) return;

        for (body.stmts) |s| {
            const text = switch (s) {
                .raw => |r| r.text,
                .using_stmt => |u| u.init_text,
                .own_decl => |o| o.init_text,
                else => continue,
            };
            if (callsAllocator(text)) {
                try self.diags.emit(
                    .err,
                    .z0030_effect_violation,
                    switch (s) {
                        .raw => |r| r.span,
                        .using_stmt => |u| u.span,
                        .own_decl => |o| o.span,
                        else => unreachable,
                    },
                    "fn declared 'noalloc' contains an allocating call",
                    .{},
                );
            }
        }
    }
};

/// Heuristic: does `text` look like an allocator-using call? We check for
/// identifiers containing "alloc"/"init"/"create" near a token that resembles
/// an allocator argument. For MVP we keep this loose.
fn callsAllocator(text: []const u8) bool {
    if (containsToken(text, "alloc")) return true;
    if (containsToken(text, "create")) return true;
    if (containsToken(text, "Allocator")) return true;
    if (containsToken(text, "ArrayList")) return true;
    return false;
}

/// Returns true if any token in `text` contains `needle` as a substring,
/// where token boundaries are non-identifier characters.
fn containsToken(text: []const u8, needle: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) {
        if (isIdent(text[i])) {
            const start = i;
            while (i < text.len and isIdent(text[i])) i += 1;
            const tok = text[start..i];
            if (std.mem.indexOf(u8, tok, needle)) |_| return true;
        } else {
            i += 1;
        }
    }
    return false;
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
