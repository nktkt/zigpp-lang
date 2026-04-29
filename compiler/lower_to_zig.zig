const std = @import("std");
const ast = @import("ast.zig");
const diag = @import("diagnostics.zig");
const sema = @import("sema.zig");

/// Convenience alias so signatures don't have to spell out the long
/// generic type. Owned by the caller (typically a `SemaResult`).
pub const InferredEffectsMap = std.StringHashMap(sema.InferredEffects);

/// Sibling alias for the per-fn `.custom("X")` name table that the
/// `@effectsOf(<ident>)` lowering also consults. Owned by the caller
/// (typically a `SemaResult`); each value is a list of name slices that
/// reference the original source / AST arena and must outlive lowering.
pub const InferredCustomEffectsMap = sema.CustomEffectMap;

/// Lowering pass: walks an `ast.File` and produces a Zig source string.
///
/// The lowering is intentionally textual: identifiers and types are kept as
/// the original source slices so the generated Zig stays readable. Only the
/// Zig++-specific syntax is rewritten.
pub const Lowerer = struct {
    allocator: std.mem.Allocator,
    out: std.ArrayList(u8),
    diags: *diag.Diagnostics,
    /// Set of trait names so that fn-param lowering knows what's a trait.
    trait_set: std.StringHashMap(void),
    extern_traits: std.StringHashMap(void),
    /// Maps target type name -> list of impl blocks against it. Used to inject
    /// method bodies into parsed `const X = struct {...}` decls so that static
    /// dispatch (`who.greet()`) resolves through normal Zig method lookup.
    impls_by_target: std.StringHashMap(std.ArrayList(*const ast.ImplBlock)),
    /// Per-fn inferred effect set, supplied by sema. Optional because
    /// some lowering callers (snapshot tests, raw smoke tests) skip
    /// sema entirely. When null, `@effectsOf(<ident>)` lowers to `""`
    /// and Z0050 is suppressed (we have no table to check against).
    inferred_effects: ?*const InferredEffectsMap = null,
    /// Per-fn inferred `.custom("X")` name set, supplied by sema.
    /// Sibling to `inferred_effects`; appended after the alloc/io/panic
    /// axes so the lowered string keeps backwards compatibility (a fn
    /// with no custom effects produces the exact same shape as before).
    /// Optional for the same reasons as `inferred_effects`.
    inferred_custom: ?*const InferredCustomEffectsMap = null,

    pub fn init(allocator: std.mem.Allocator, diags: *diag.Diagnostics) Lowerer {
        return .{
            .allocator = allocator,
            .out = .{},
            .diags = diags,
            .trait_set = std.StringHashMap(void).init(allocator),
            .extern_traits = std.StringHashMap(void).init(allocator),
            .impls_by_target = std.StringHashMap(std.ArrayList(*const ast.ImplBlock)).init(allocator),
            .inferred_effects = null,
            .inferred_custom = null,
        };
    }

    /// Same as `init` but also wires the per-fn inferred-effect table so
    /// `@effectsOf(<ident>)` substitutions resolve. Pass the map straight
    /// from `sema.SemaResult.inferred_effects`.
    pub fn initWithEffects(
        allocator: std.mem.Allocator,
        diags: *diag.Diagnostics,
        effects: *const InferredEffectsMap,
    ) Lowerer {
        var lw = init(allocator, diags);
        lw.inferred_effects = effects;
        return lw;
    }

    /// Same as `initWithEffects` but also wires the per-fn `.custom("X")`
    /// table so the `@effectsOf(<ident>)` substitution can append the
    /// `custom("X")` entries after the alloc/io/panic axes. Pass the map
    /// straight from `sema.SemaResult.inferred_custom_effects`.
    pub fn initWithEffectsAndCustom(
        allocator: std.mem.Allocator,
        diags: *diag.Diagnostics,
        effects: *const InferredEffectsMap,
        custom: *const InferredCustomEffectsMap,
    ) Lowerer {
        var lw = initWithEffects(allocator, diags, effects);
        lw.inferred_custom = custom;
        return lw;
    }

    pub fn deinit(self: *Lowerer) void {
        self.out.deinit(self.allocator);
        self.trait_set.deinit();
        self.extern_traits.deinit();
        var it = self.impls_by_target.valueIterator();
        while (it.next()) |list| list.deinit(self.allocator);
        self.impls_by_target.deinit();
    }

    fn write(self: *Lowerer, s: []const u8) !void {
        try self.out.appendSlice(self.allocator, s);
    }

    fn writeFmt(self: *Lowerer, comptime fmt: []const u8, args: anytype) !void {
        const tmp = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(tmp);
        try self.out.appendSlice(self.allocator, tmp);
    }

    fn writeIndent(self: *Lowerer, n: u32) !void {
        var i: u32 = 0;
        while (i < n) : (i += 1) try self.out.append(self.allocator, ' ');
    }

    pub fn lowerFile(self: *Lowerer, file: *const ast.File) ![]u8 {
        // Collect trait names first so dyn/impl param lowering works regardless of order.
        for (file.decls) |d| {
            switch (d) {
                .trait => |t| try self.trait_set.put(t.name, {}),
                .extern_interface => |e| {
                    try self.trait_set.put(e.name, {});
                    try self.extern_traits.put(e.name, {});
                },
                else => {},
            }
        }
        // Build impl index keyed by target type so struct-decl lowering can
        // splice methods into the matching `const Name = struct { ... }`.
        for (file.decls) |*d| {
            if (d.* == .impl_block) {
                const ib = &d.impl_block;
                const gop = try self.impls_by_target.getOrPut(ib.target_type);
                if (!gop.found_existing) gop.value_ptr.* = .{};
                try gop.value_ptr.append(self.allocator, ib);
            }
        }

        try self.write("// Generated by zig++ frontend. DO NOT EDIT.\n");
        if (std.mem.indexOf(u8, file.source, "@import(\"zpp\")") == null) {
            try self.write("const zpp = @import(\"zpp\");\n\n");
        }

        for (file.decls) |d| {
            try self.lowerDecl(d);
            try self.write("\n");
        }
        return self.out.toOwnedSlice(self.allocator);
    }

    fn lowerDecl(self: *Lowerer, d: ast.TopDecl) !void {
        switch (d) {
            .raw => |r| try self.writeRewrittenCode(r.text),
            .trait => |t| try self.lowerTrait(t),
            .impl_block => |i| try self.lowerImpl(i),
            .owned_struct => |o| try self.lowerOwnedStruct(o),
            .struct_decl => |s| try self.lowerStructDecl(s),
            .fn_decl => |f| try self.lowerFnDecl(f, 0),
            .extern_interface => |e| try self.lowerExternInterface(e),
        }
    }

    fn lowerTrait(self: *Lowerer, t: ast.TraitDecl) !void {
        try self.writeFmt("// trait {s}\n", .{t.name});
        const vis = if (t.is_pub) "pub " else "";
        try self.writeFmt("{s}const {s}_VTable = struct {{\n", .{ vis, t.name });
        for (t.methods) |m| {
            try self.writeIndent(4);
            try self.writeFmt("{s}: *const fn (ptr: *anyopaque", .{m.name});
            for (m.params) |p| {
                if (std.mem.eql(u8, p.name, "self")) continue;
                try self.writeFmt(", {s}: ", .{p.name});
                try self.writeRewrittenType(p.type_text);
            }
            try self.write(") ");
            try self.writeRewrittenType(normalizeReturn(m.return_type));
            try self.write(",\n");
        }
        try self.write("};\n");

        // Convenience type alias for dyn objects.
        try self.writeFmt("{s}const {s} = zpp.Dyn({s}_VTable);\n", .{ vis, t.name, t.name });
    }

    fn lowerImpl(self: *Lowerer, i: ast.ImplBlock) !void {
        try self.writeFmt("// impl {s} for {s}\n", .{ i.trait_name, i.target_type });
        for (i.fns) |fd| {
            try self.lowerImplBody(i.trait_name, i.target_type, fd);
            try self.lowerImplThunk(i.trait_name, i.target_type, fd);
        }
        try self.writeFmt("pub const {s}_impl_for_{s}: {s}_VTable = .{{\n", .{ i.trait_name, i.target_type, i.trait_name });
        for (i.fns) |fd| {
            try self.writeIndent(4);
            try self.writeFmt(".{s} = {s}_{s}_for_{s},\n", .{ fd.sig.name, i.trait_name, fd.sig.name, i.target_type });
        }
        try self.write("};\n");
    }

    /// Emit `fn <Trait>_method_<Method>_<Type>(self: *Type, args...) ret { body }`
    /// — the actual method body as a free fn the thunk can delegate to.
    fn lowerImplBody(self: *Lowerer, trait: []const u8, target: []const u8, fd: ast.FnDecl) !void {
        try self.writeFmt("fn {s}_method_{s}_{s}(self: *{s}", .{ trait, fd.sig.name, target, target });
        for (fd.sig.params) |p| {
            if (std.mem.eql(u8, p.name, "self")) continue;
            try self.writeFmt(", {s}: ", .{p.name});
            try self.writeRewrittenType(p.type_text);
        }
        try self.write(") ");
        try self.writeRewrittenType(normalizeReturn(fd.sig.return_type));
        if (fd.body) |b| {
            try self.write(" {\n");
            for (b.stmts) |s| try self.lowerStmt(s, 4);
            try self.write("}\n");
        } else {
            try self.write(";\n");
        }
    }

    fn lowerImplThunk(self: *Lowerer, trait: []const u8, target: []const u8, fd: ast.FnDecl) !void {
        try self.writeFmt("fn {s}_{s}_for_{s}(ptr: *anyopaque", .{ trait, fd.sig.name, target });
        for (fd.sig.params) |p| {
            if (std.mem.eql(u8, p.name, "self")) continue;
            try self.writeFmt(", {s}: ", .{p.name});
            try self.writeRewrittenType(p.type_text);
        }
        try self.write(") ");
        if (self.extern_traits.contains(trait)) try self.write("callconv(.c) ");
        try self.writeRewrittenType(normalizeReturn(fd.sig.return_type));
        try self.write(" {\n");
        try self.writeIndent(4);
        try self.writeFmt("const self: *{s} = @ptrCast(@alignCast(ptr));\n", .{target});
        try self.writeIndent(4);
        try self.writeFmt("return {s}_method_{s}_{s}(self", .{ trait, fd.sig.name, target });
        for (fd.sig.params) |p| {
            if (std.mem.eql(u8, p.name, "self")) continue;
            try self.writeFmt(", {s}", .{p.name});
        }
        try self.write(");\n}\n");
    }

    fn lowerOwnedStruct(self: *Lowerer, o: ast.OwnedStructDecl) !void {
        const vis = if (o.is_pub) "pub " else "";
        try self.writeFmt("// owned struct {s} (must-deinit checked by sema)\n", .{o.name});
        try self.writeFmt("{s}const {s} = struct {{\n", .{ vis, o.name });
        // Field text — emit as-is, indented if it isn't already.
        const fields = std.mem.trim(u8, o.fields_text, " \t\r\n");
        if (fields.len > 0) {
            try self.writeIndent(4);
            try self.write(fields);
            if (fields[fields.len - 1] != ',' and fields[fields.len - 1] != ';') try self.write(",");
            try self.write("\n");
        }
        for (o.fns) |fd| {
            try self.lowerFnDecl(fd, 4);
            try self.write("\n");
        }
        if (o.derive) |d| try self.lowerDeriveDecls(o.name, d);
        try self.write("};\n");
    }

    fn lowerStructDecl(self: *Lowerer, s: ast.StructDecl) !void {
        const vis = if (s.is_pub) "pub " else "";
        try self.writeFmt("{s}const {s} = struct {{\n", .{ vis, s.name });
        const fields = std.mem.trim(u8, s.fields_text, " \t\r\n");
        if (fields.len > 0) {
            try self.writeIndent(4);
            try self.write(fields);
            if (fields[fields.len - 1] != ',' and fields[fields.len - 1] != ';' and fields[fields.len - 1] != '}') try self.write(",");
            try self.write("\n");
        }
        for (s.fns) |fd| {
            try self.lowerFnDecl(fd, 4);
            try self.write("\n");
        }
        if (s.derive) |d| try self.lowerDeriveDecls(s.name, d);
        try self.injectImplMethods(s.name);
        try self.write("};\n");
    }

    /// For each impl block whose target is `type_name`, emit one
    /// `pub fn <method>(self: *@This(), ...) ret { body }` inside the struct
    /// body so static dispatch (`x.method()`) resolves through Zig's normal
    /// method lookup. Free-fn thunks for vtable use are emitted separately by
    /// `lowerImpl`.
    fn injectImplMethods(self: *Lowerer, type_name: []const u8) !void {
        const list = self.impls_by_target.get(type_name) orelse return;
        for (list.items) |ib| {
            for (ib.fns) |fd| {
                try self.writeIndent(4);
                try self.writeFmt("pub fn {s}(self: *@This()", .{fd.sig.name});
                for (fd.sig.params) |p| {
                    if (std.mem.eql(u8, p.name, "self")) continue;
                    try self.writeFmt(", {s}: ", .{p.name});
                    try self.writeRewrittenType(p.type_text);
                }
                try self.write(") ");
                try self.writeRewrittenType(normalizeReturn(fd.sig.return_type));
                if (fd.body) |b| {
                    try self.write(" {\n");
                    for (b.stmts) |st| try self.lowerStmt(st, 8);
                    try self.writeIndent(4);
                    try self.write("}\n");
                } else {
                    try self.write(";\n");
                }
            }
        }
    }

    /// Emit derived helpers as actual method-shaped decls so the user can write
    /// `a.hash()`, `a.eq(b)`, `User.debug.format(a, w)` etc. naturally.
    fn lowerDeriveDecls(self: *Lowerer, type_name: []const u8, d: ast.DeriveAttr) !void {
        _ = type_name;
        try self.writeIndent(4);
        try self.write("// derive(.{ ");
        for (d.names, 0..) |n, idx| {
            if (idx > 0) try self.write(", ");
            try self.write(n);
        }
        try self.write(" })\n");
        for (d.names) |n| {
            if (std.mem.eql(u8, n, "Hash")) {
                try self.writeIndent(4);
                try self.write("pub fn hash(self: @This()) u64 { return zpp.derive.Hash(@This()).hash(self); }\n");
            } else if (std.mem.eql(u8, n, "Eq")) {
                try self.writeIndent(4);
                try self.write("pub fn eq(self: @This(), other: @This()) bool { return zpp.derive.Eq(@This()).eq(self, other); }\n");
            } else if (std.mem.eql(u8, n, "Ord")) {
                try self.writeIndent(4);
                try self.write("pub fn cmp(self: @This(), other: @This()) i32 { return zpp.derive.Ord(@This()).cmp(self, other); }\n");
            } else if (std.mem.eql(u8, n, "Default")) {
                try self.writeIndent(4);
                try self.write("pub fn default() @This() { return zpp.derive.Default(@This()).default(); }\n");
            } else if (std.mem.eql(u8, n, "Clone")) {
                try self.writeIndent(4);
                try self.write("pub fn clone(self: @This(), allocator: std.mem.Allocator) !@This() { return zpp.derive.Clone(@This()).clone(self, allocator); }\n");
            } else if (std.mem.eql(u8, n, "Debug")) {
                try self.writeIndent(4);
                try self.write("pub const debug = zpp.derive.Debug(@This());\n");
            } else if (std.mem.eql(u8, n, "Json")) {
                try self.writeIndent(4);
                try self.write("pub const json = zpp.derive.Json(@This());\n");
            } else if (std.mem.eql(u8, n, "Iterator")) {
                try self.writeIndent(4);
                try self.write("pub fn iter(self: @This()) zpp.derive.Iterator(@This()).FieldIter { return zpp.derive.Iterator(@This()).iter(self); }\n");
            } else if (std.mem.eql(u8, n, "Serialize")) {
                try self.writeIndent(4);
                try self.write("pub fn serialize(self: @This(), allocator: std.mem.Allocator) ![]u8 { return zpp.derive.Serialize(@This()).serialize(self, allocator); }\n");
            } else if (std.mem.eql(u8, n, "Compare")) {
                try self.writeIndent(4);
                try self.write("pub fn lt(self: @This(), other: @This()) bool { return zpp.derive.Compare(@This()).lt(self, other); }\n");
                try self.writeIndent(4);
                try self.write("pub fn le(self: @This(), other: @This()) bool { return zpp.derive.Compare(@This()).le(self, other); }\n");
                try self.writeIndent(4);
                try self.write("pub fn gt(self: @This(), other: @This()) bool { return zpp.derive.Compare(@This()).gt(self, other); }\n");
                try self.writeIndent(4);
                try self.write("pub fn ge(self: @This(), other: @This()) bool { return zpp.derive.Compare(@This()).ge(self, other); }\n");
            } else if (std.mem.eql(u8, n, "FromStr")) {
                try self.writeIndent(4);
                try self.write("pub fn fromStr(s: []const u8, allocator: std.mem.Allocator) !@This() { return zpp.derive.FromStr(@This()).parse(s, allocator); }\n");
            } else {
                try self.writeIndent(4);
                try self.writeFmt("pub const {s} = zpp.derive.{s}(@This());\n", .{ deriveFieldName(n), n });
            }
        }
    }

    fn lowerExternInterface(self: *Lowerer, e: ast.ExternInterfaceDecl) !void {
        const vis = if (e.is_pub) "pub " else "";
        try self.writeFmt("// extern interface {s}\n", .{e.name});
        try self.writeFmt("{s}const {s}_ABI = extern struct {{\n", .{ vis, e.name });
        for (e.methods) |m| {
            try self.writeIndent(4);
            try self.writeFmt("{s}: *const fn (ctx: *anyopaque", .{m.name});
            for (m.params) |p| {
                if (std.mem.eql(u8, p.name, "self")) continue;
                try self.writeFmt(", {s}: {s}", .{ p.name, normalizeType(p.type_text) });
            }
            try self.writeFmt(") callconv(.c) {s},\n", .{normalizeReturn(m.return_type)});
        }
        try self.write("};\n");
        try self.writeFmt("{s}const {s}_VTable = {s}_ABI;\n", .{ vis, e.name, e.name });
    }

    fn lowerFnDecl(self: *Lowerer, fd: ast.FnDecl, indent: u32) !void {
        // Attribute comments + runtime calls.
        if (fd.sig.effects) |ef| {
            try self.writeIndent(indent);
            try self.write("// effects(");
            for (ef.effects, 0..) |e, idx| {
                if (idx != 0) try self.write(", ");
                try self.writeFmt(".{s}", .{e.text});
            }
            try self.write(")\n");
        }
        if (fd.sig.requires) |rq| {
            try self.writeIndent(indent);
            try self.writeFmt("// requires({s})\n", .{rq.expr_text});
        }
        if (fd.sig.ensures) |en| {
            try self.writeIndent(indent);
            try self.writeFmt("// ensures({s})\n", .{en.expr_text});
        }

        try self.writeIndent(indent);
        if (fd.sig.is_pub) try self.write("pub ");
        try self.writeFmt("fn {s}(", .{fd.sig.name});

        var first = true;
        for (fd.sig.params) |p| {
            if (!first) try self.write(", ");
            first = false;
            try self.lowerParam(p);
        }
        try self.write(") ");
        try self.writeRewrittenType(normalizeReturn(fd.sig.return_type));

        if (fd.body) |body| {
            try self.write(" {\n");
            if (fd.sig.requires) |rq| {
                try self.writeIndent(indent + 4);
                try self.write("zpp.contract.requires(");
                try self.write(rq.expr_text);
                try self.write(", \"requires: ");
                try self.writeEscaped(rq.expr_text);
                try self.writeFmt("\" ++ \" in {s}\");\n", .{fd.sig.name});
            }
            // `ensures` runs on every scope-exit (including early returns) via
            // defer. The condition is evaluated at exit-time so it reflects
            // the final state of local variables.
            if (fd.sig.ensures) |en| {
                try self.writeIndent(indent + 4);
                try self.write("defer zpp.contract.ensures(");
                try self.write(en.expr_text);
                try self.write(", \"ensures: ");
                try self.writeEscaped(en.expr_text);
                try self.writeFmt("\" ++ \" in {s}\");\n", .{fd.sig.name});
            }
            for (body.stmts) |s| {
                try self.lowerStmt(s, indent + 4);
            }
            try self.writeIndent(indent);
            try self.write("}\n");
        } else {
            try self.write(";\n");
        }
    }

    /// Look up `ident` in the per-fn inferred-effect table and write a
    /// double-quoted comma-separated literal (e.g. `"alloc,io"`, `""` for
    /// pure). Order is fixed (alloc, io, panic) so the produced string is
    /// stable and trivially comparable in user comptime. Unknown idents
    /// emit `""` and a Z0050 diagnostic; a missing table (e.g. snapshot
    /// tests that bypass sema) silently emits `""`.
    fn writeEffectsOfFor(self: *Lowerer, ident: []const u8) !void {
        const map = self.inferred_effects orelse {
            try self.write("\"\"");
            return;
        };
        const entry = map.get(ident) orelse {
            try self.diags.emit(
                .err,
                .z0050_unknown_fn_in_effects_of,
                .{ .start = 0, .end = 0 },
                "@effectsOf: unknown same-file fn '{s}'",
                .{ident},
            );
            try self.write("\"\"");
            return;
        };
        try self.write("\"");
        var first = true;
        if (entry.alloc) {
            try self.write("alloc");
            first = false;
        }
        if (entry.io) {
            if (!first) try self.write(",");
            try self.write("io");
            first = false;
        }
        if (entry.panic) {
            if (!first) try self.write(",");
            try self.write("panic");
            first = false;
        }
        // Append `custom("X")` entries (if any) after the alloc/io/panic
        // axes. The order matches the sibling map's insertion order so
        // the lowered string stays stable across runs. The leading axes
        // are unchanged when no custom effects are present, which keeps
        // the output backwards-compatible with round-4 lowering.
        if (self.inferred_custom) |cmap| {
            if (cmap.get(ident)) |list| {
                for (list.items) |name| {
                    if (!first) try self.write(",");
                    try self.write("custom(\\\"");
                    try self.write(name);
                    try self.write("\\\")");
                    first = false;
                }
            }
        }
        try self.write("\"");
    }

    /// Emit `text` with `"` and `\` backslash-escaped so it is safe inside a
    /// Zig double-quoted string literal.
    fn writeEscaped(self: *Lowerer, text: []const u8) !void {
        for (text) |c| {
            switch (c) {
                '\\' => try self.write("\\\\"),
                '"' => try self.write("\\\""),
                '\n' => try self.write("\\n"),
                else => try self.out.append(self.allocator, c),
            }
        }
    }

    fn lowerParam(self: *Lowerer, p: ast.Param) !void {
        switch (p.mode) {
            .plain => {
                try self.writeFmt("{s}: ", .{p.name});
                try self.writeRewrittenType(p.type_text);
            },
            .comptime_plain => {
                try self.writeFmt("comptime {s}: ", .{p.name});
                try self.writeRewrittenType(p.type_text);
            },
            .any_type => try self.writeFmt("{s}: anytype", .{p.name}),
            .impl_trait => try self.writeFmt("{s}: anytype", .{p.name}),
            .dyn_trait => try self.writeFmt("{s}: zpp.Dyn({s}_VTable)", .{ p.name, p.type_text }),
            .nullable_dyn_trait => try self.writeFmt("{s}: ?zpp.Dyn({s}_VTable)", .{ p.name, p.type_text }),
        }
    }

    /// Emit a parameter/return type with Zig++ keywords substituted into Zig:
    ///   `dyn Trait`  -> `zpp.Dyn(Trait_VTable)`
    ///   `own T`      -> `T`         (sema enforces affinity, lowering drops it)
    fn writeRewrittenType(self: *Lowerer, text: []const u8) !void {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        var i: usize = 0;
        while (i < trimmed.len) {
            // dyn <Ident>
            if (matchKeywordAt(trimmed, i, "dyn")) {
                const after = i + 3;
                var j = after;
                while (j < trimmed.len and trimmed[j] == ' ') j += 1;
                const name_start = j;
                while (j < trimmed.len and (std.ascii.isAlphanumeric(trimmed[j]) or trimmed[j] == '_')) j += 1;
                if (j > name_start) {
                    try self.writeFmt("zpp.Dyn({s}_VTable)", .{trimmed[name_start..j]});
                    i = j;
                    continue;
                }
            }
            // own <Ident or rest-of-type>
            if (matchKeywordAt(trimmed, i, "own")) {
                const after = i + 3;
                var j = after;
                while (j < trimmed.len and trimmed[j] == ' ') j += 1;
                i = j;
                continue;
            }
            // Self -> *anyopaque (in trait method signatures the implementing
            // type is erased; downstream impl thunks cast back to *T)
            if (matchKeywordAt(trimmed, i, "Self")) {
                try self.write("*anyopaque");
                i += 4;
                continue;
            }
            try self.out.append(self.allocator, trimmed[i]);
            i += 1;
        }
    }

    /// Rewrite a chunk of raw user code, applying the same Zig++ -> Zig
    /// substitutions as `writeRewrittenType` plus statement-level forms:
    ///   `move x` -> `x`
    ///   `@effectsOf(<ident>)` -> `"alloc,io,panic"` literal (effects sema
    ///                            inferred for the same-file fn `<ident>`)
    /// String literals and comments are passed through unchanged.
    fn writeRewrittenCode(self: *Lowerer, text: []const u8) !void {
        var i: usize = 0;
        while (i < text.len) {
            const c = text[i];
            // `@effectsOf(<ident>)` -> `"<comma-separated-effects>"`. The
            // identifier must name a fn declared in the same .zpp file;
            // unknown names lower to `""` and emit Z0050. We try this
            // before the `@import` branch so an `@effectsOf(...)` token
            // never falls through into other `@`-handling.
            if (c == '@' and substrAt(text, i, "@effectsOf(")) {
                const start = i;
                const name_start = i + "@effectsOf(".len;
                var j = name_start;
                while (j < text.len and (text[j] == ' ' or text[j] == '\t')) j += 1;
                const ident_start = j;
                while (j < text.len and (std.ascii.isAlphanumeric(text[j]) or text[j] == '_')) j += 1;
                const ident_end = j;
                while (j < text.len and (text[j] == ' ' or text[j] == '\t')) j += 1;
                if (ident_end > ident_start and j < text.len and text[j] == ')') {
                    const ident = text[ident_start..ident_end];
                    try self.writeEffectsOfFor(ident);
                    i = j + 1; // consume `)`
                    continue;
                }
                // Malformed (e.g. `@effectsOf()` or no closing paren) —
                // fall through and let the verbatim path emit it; sema
                // will likely flag the call separately if it matters.
                _ = start;
            }
            // `@import("...zpp")` -> `@import("...zig")` so .zpp files can
            // reference each other directly. Done before the string-literal
            // pass-through so we can edit the path inside the quotes.
            if (c == '@' and substrAt(text, i, "@import(\"")) {
                const start = i;
                i += "@import(\"".len;
                const path_start = i;
                while (i < text.len and text[i] != '"') : (i += 1) {}
                const path_end = i;
                if (i < text.len and i + 1 < text.len and text[i + 1] == ')') {
                    const path = text[path_start..path_end];
                    if (std.mem.endsWith(u8, path, ".zpp")) {
                        try self.write("@import(\"");
                        try self.write(path[0 .. path.len - 4]);
                        try self.write(".zig\")");
                        i += 2; // consume `")`
                        continue;
                    }
                }
                // Not a .zpp import — write what we already consumed verbatim.
                try self.write(text[start..i]);
                continue;
            }
            // Pass-through string literals.
            if (c == '"') {
                const start = i;
                i += 1;
                while (i < text.len) : (i += 1) {
                    if (text[i] == '\\' and i + 1 < text.len) { i += 1; continue; }
                    if (text[i] == '"') { i += 1; break; }
                }
                try self.write(text[start..i]);
                continue;
            }
            // Pass-through char literals.
            if (c == '\'') {
                const start = i;
                i += 1;
                while (i < text.len and text[i] != '\'') : (i += 1) {
                    if (text[i] == '\\' and i + 1 < text.len) i += 1;
                }
                if (i < text.len) i += 1;
                try self.write(text[start..i]);
                continue;
            }
            // Pass-through // comments.
            if (c == '/' and i + 1 < text.len and text[i + 1] == '/') {
                const start = i;
                while (i < text.len and text[i] != '\n') i += 1;
                try self.write(text[start..i]);
                continue;
            }
            // dyn <Ident>
            if (matchKeywordAt(text, i, "dyn")) {
                var j = i + 3;
                while (j < text.len and text[j] == ' ') j += 1;
                const ns = j;
                while (j < text.len and (std.ascii.isAlphanumeric(text[j]) or text[j] == '_')) j += 1;
                if (j > ns) {
                    try self.writeFmt("zpp.Dyn({s}_VTable)", .{text[ns..j]});
                    i = j;
                    continue;
                }
            }
            // move <Ident>  (also handles `move foo.bar` — only the keyword is dropped)
            if (matchKeywordAt(text, i, "move")) {
                i += 4;
                while (i < text.len and text[i] == ' ') i += 1;
                continue;
            }
            // own <Type-token-prefix> (rare in stmt position but harmless)
            if (matchKeywordAt(text, i, "own")) {
                i += 3;
                while (i < text.len and text[i] == ' ') i += 1;
                continue;
            }
            try self.out.append(self.allocator, c);
            i += 1;
        }
    }

    fn lowerStmt(self: *Lowerer, s: ast.Stmt, indent: u32) !void {
        switch (s) {
            .raw => |r| {
                try self.writeIndent(indent);
                try self.writeRewrittenCode(std.mem.trim(u8, r.text, " \t\r\n"));
                try self.write("\n");
            },
            .using_stmt => |u| {
                try self.writeIndent(indent);
                try self.writeFmt("var {s} = ", .{u.name});
                try self.writeRewrittenCode(u.init_text);
                try self.write(";\n");
                try self.writeIndent(indent);
                try self.writeFmt("defer {s}.deinit();\n", .{u.name});
            },
            .own_decl => |o| {
                const kw = if (o.is_const) "const" else "var";
                try self.writeIndent(indent);
                if (o.type_text) |tt| {
                    try self.writeFmt("{s} {s}: ", .{ kw, o.name });
                    try self.writeRewrittenType(tt);
                    try self.write(" = ");
                    try self.writeRewrittenCode(o.init_text);
                    try self.write(";\n");
                } else {
                    try self.writeFmt("{s} {s} = ", .{ kw, o.name });
                    try self.writeRewrittenCode(o.init_text);
                    try self.write(";\n");
                }
            },
            .move_expr_stmt => |m| {
                // After sema, a `move x;` standalone statement degenerates to a no-op.
                try self.writeIndent(indent);
                try self.writeFmt("// move {s}\n", .{m.target});
            },
        }
    }
};

/// Some lightweight type cleanups so the produced source is more idiomatic.
fn normalizeType(t: []const u8) []const u8 {
    return std.mem.trim(u8, t, " \t\r\n");
}

/// True iff `text[i..]` starts with `kw` and the next char (if any) is not an
/// identifier continuation. Used by `writeRewrittenType` to recognize the
/// `dyn` and `own` keywords without matching e.g. `dynamic`.
/// True iff `text[at..]` starts with `needle`.
fn substrAt(text: []const u8, at: usize, needle: []const u8) bool {
    if (at + needle.len > text.len) return false;
    return std.mem.eql(u8, text[at .. at + needle.len], needle);
}

fn matchKeywordAt(text: []const u8, i: usize, kw: []const u8) bool {
    if (i + kw.len > text.len) return false;
    if (!std.mem.eql(u8, text[i .. i + kw.len], kw)) return false;
    if (i > 0) {
        const prev = text[i - 1];
        if (std.ascii.isAlphanumeric(prev) or prev == '_') return false;
    }
    if (i + kw.len < text.len) {
        const next = text[i + kw.len];
        if (std.ascii.isAlphanumeric(next) or next == '_') return false;
    }
    return true;
}

fn normalizeReturn(t: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, t, " \t\r\n");
    if (trimmed.len == 0) return "void";
    return trimmed;
}

/// Pick a member-decl name for a derived helper.
/// "Hash" -> "hash", "Debug" -> "debug", etc.  Mirrors `lib/derive.zig`'s
/// public namespace functions.
fn deriveFieldName(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "Hash")) return "hash";
    if (std.mem.eql(u8, name, "Eq")) return "eq";
    if (std.mem.eql(u8, name, "Debug")) return "debug";
    if (std.mem.eql(u8, name, "Json")) return "json";
    if (std.mem.eql(u8, name, "Iterator")) return "iterator";
    if (std.mem.eql(u8, name, "Serialize")) return "serialize_ns";
    if (std.mem.eql(u8, name, "Compare")) return "compare";
    if (std.mem.eql(u8, name, "FromStr")) return "from_str";
    return name;
}

/// Convenience: lower a parsed file into a freshly-allocated string.
/// `@effectsOf(<ident>)` substitutions resolve to `""` when called this
/// way — pass an effect table via `lowerWithEffects` to enable real
/// inferred-effect lookups.
pub fn lower(
    allocator: std.mem.Allocator,
    file: *const ast.File,
    diags: *diag.Diagnostics,
) ![]u8 {
    var lw = Lowerer.init(allocator, diags);
    defer lw.deinit();
    return lw.lowerFile(file);
}

/// Same as `lower` but also wires the per-fn inferred-effect table so
/// `@effectsOf(<ident>)` substitutions can resolve to the real string.
pub fn lowerWithEffects(
    allocator: std.mem.Allocator,
    file: *const ast.File,
    diags: *diag.Diagnostics,
    effects: *const InferredEffectsMap,
) ![]u8 {
    var lw = Lowerer.initWithEffects(allocator, diags, effects);
    defer lw.deinit();
    return lw.lowerFile(file);
}

/// Same as `lowerWithEffects` but also wires the per-fn `.custom("X")`
/// table so `@effectsOf(<ident>)` substitutions can append the
/// `custom("X")` entries after the alloc/io/panic axes.
pub fn lowerWithEffectsAndCustom(
    allocator: std.mem.Allocator,
    file: *const ast.File,
    diags: *diag.Diagnostics,
    effects: *const InferredEffectsMap,
    custom: *const InferredCustomEffectsMap,
) ![]u8 {
    var lw = Lowerer.initWithEffectsAndCustom(allocator, diags, effects, custom);
    defer lw.deinit();
    return lw.lowerFile(file);
}

test "lower using stmt" {
    const a = std.testing.allocator;
    const parser = @import("parser.zig");
    var diags = diag.Diagnostics.init(a);
    defer diags.deinit();
    var arena = ast.Arena.init(a);
    defer arena.deinit();

    const src =
        \\pub fn main() !void {
        \\    using w = try FileWriter.init("log.txt");
        \\}
    ;
    const file = try parser.parseSource(a, src, &arena, &diags);
    const out = try lower(a, &file, &diags);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "var w = try FileWriter.init") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "defer w.deinit();") != null);
}

test "lower trait to vtable" {
    const a = std.testing.allocator;
    const parser = @import("parser.zig");
    var diags = diag.Diagnostics.init(a);
    defer diags.deinit();
    var arena = ast.Arena.init(a);
    defer arena.deinit();

    const src = "trait Writer { fn write(self, bytes: []const u8) !usize; }";
    const file = try parser.parseSource(a, src, &arena, &diags);
    const out = try lower(a, &file, &diags);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Writer_VTable = struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "write: *const fn (ptr: *anyopaque") != null);
}

test "lower impl-trait fn" {
    const a = std.testing.allocator;
    const parser = @import("parser.zig");
    var diags = diag.Diagnostics.init(a);
    defer diags.deinit();
    var arena = ast.Arena.init(a);
    defer arena.deinit();

    const src =
        \\trait Writer { fn write(self, b: []const u8) !usize; }
        \\fn emit(w: impl Writer, msg: []const u8) !void {
        \\    _ = w; _ = msg;
        \\}
    ;
    const file = try parser.parseSource(a, src, &arena, &diags);
    const out = try lower(a, &file, &diags);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "w: anytype") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "comptime") == null);
}

test "lower @effectsOf substitutes the inferred string" {
    // Direct unit test of the lowerer's `@effectsOf` rewrite given a
    // hand-built effects table. Mirrors the end-to-end coverage in
    // tests/diagnostics/diags.zig but exercises only this file's API
    // so a regression here surfaces without the full pipeline.
    const a = std.testing.allocator;
    const parser = @import("parser.zig");
    var diags = diag.Diagnostics.init(a);
    defer diags.deinit();
    var arena = ast.Arena.init(a);
    defer arena.deinit();

    var effects = InferredEffectsMap.init(a);
    defer effects.deinit();
    try effects.put("pure", .{});
    try effects.put("noisy", .{ .alloc = true, .io = true });

    const src =
        \\fn pure() void {}
        \\fn noisy() void {}
        \\fn ask() []const u8 { return @effectsOf(pure); }
        \\fn ask2() []const u8 { return @effectsOf(noisy); }
    ;
    const file = try parser.parseSource(a, src, &arena, &diags);
    const out = try lowerWithEffects(a, &file, &diags, &effects);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "return \"\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "return \"alloc,io\";") != null);
}

test "lower @effectsOf appends custom names after alloc/io/panic axes" {
    // Direct unit test of the round-5 follow-up: when a fn has an
    // inferred `.custom("X")` set, the substitution appends
    // `custom("X")` entries after the alloc/io/panic axes (with the
    // `"` doubly-escaped because the rewrite is itself emitted inside
    // a Zig string literal). Mirrors the end-to-end coverage in
    // tests/diagnostics/diags.zig.
    const a = std.testing.allocator;
    const parser = @import("parser.zig");
    var diags = diag.Diagnostics.init(a);
    defer diags.deinit();
    var arena = ast.Arena.init(a);
    defer arena.deinit();

    var effects = InferredEffectsMap.init(a);
    defer effects.deinit();
    try effects.put("net_only", .{});
    try effects.put("alloc_and_net", .{ .alloc = true });

    var custom = InferredCustomEffectsMap.init(a);
    defer {
        var it = custom.valueIterator();
        while (it.next()) |list| list.deinit(a);
        custom.deinit();
    }
    var net_only_list: sema.CustomEffectList = .{};
    try net_only_list.append(a, "net");
    try custom.put("net_only", net_only_list);
    var combo_list: sema.CustomEffectList = .{};
    try combo_list.append(a, "net");
    try custom.put("alloc_and_net", combo_list);

    const src =
        \\fn net_only() void {}
        \\fn alloc_and_net() void {}
        \\fn ask() []const u8 { return @effectsOf(net_only); }
        \\fn ask2() []const u8 { return @effectsOf(alloc_and_net); }
    ;
    const file = try parser.parseSource(a, src, &arena, &diags);
    const out = try lowerWithEffectsAndCustom(a, &file, &diags, &effects, &custom);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "return \"custom(\\\"net\\\")\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "return \"alloc,custom(\\\"net\\\")\";") != null);
}
