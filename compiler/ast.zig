const std = @import("std");
const diag = @import("diagnostics.zig");

pub const StringSlice = []const u8;

/// Stored param-passing mode for a fn argument.
pub const ParamMode = enum {
    /// Plain Zig-style param: `name: Type`.
    plain,
    /// `name: impl Trait` — lowers to comptime type + pointer.
    impl_trait,
    /// `name: dyn Trait` — lowers to fat pointer + vtable.
    dyn_trait,
    /// `name: ?dyn Trait` — optional fat pointer; lowers to `?zpp.Dyn(...)`.
    nullable_dyn_trait,
    /// `name: anytype`.
    any_type,
    /// `comptime name: Type`.
    comptime_plain,
};

pub const Param = struct {
    name: StringSlice,
    /// For .plain / .comptime_plain: full raw type text (e.g. "*FileWriter").
    /// For .impl_trait / .dyn_trait: just the trait name.
    /// For .any_type: empty.
    type_text: StringSlice,
    mode: ParamMode,
    span: diag.Span,
};

pub const WhereBound = struct {
    type_param: StringSlice,
    /// Trait names joined with '+', kept as raw text for lowering passthrough.
    trait_text: StringSlice,
};

pub const WhereClause = struct {
    bounds: []WhereBound,
    span: diag.Span,
};

pub const EffectKind = enum { alloc, noalloc, io, noio, panic, nopanic, custom, nocustom };

pub const Effect = struct {
    kind: EffectKind,
    /// For .custom / .nocustom, the keyword token text without leading dot
    /// ("custom" or "nocustom"). For other kinds, the keyword text matching
    /// `kind` (e.g. "noalloc"). Useful for diagnostic messages.
    text: StringSlice,
    /// For .custom("X") / .nocustom("X"), the raw user name "X" (without
    /// surrounding quotes). Empty slice for the bare-keyword variants.
    name: StringSlice = "",
};

pub const EffectsAttr = struct {
    effects: []Effect,
    span: diag.Span,
};

pub const RequiresAttr = struct {
    /// Raw expression text (verbatim source between the parens).
    expr_text: StringSlice,
    span: diag.Span,
};

pub const EnsuresAttr = struct {
    expr_text: StringSlice,
    span: diag.Span,
};

pub const DeriveAttr = struct {
    /// Identifiers inside `.{ ... }`.
    names: []StringSlice,
    span: diag.Span,
};

pub const FnSig = struct {
    name: StringSlice,
    params: []Param,
    /// Raw return-type text including any leading `!`.
    return_type: StringSlice,
    is_pub: bool,
    is_extern: bool,
    where: ?WhereClause,
    effects: ?EffectsAttr,
    requires: ?RequiresAttr,
    ensures: ?EnsuresAttr,
    span: diag.Span,
};

/// Statements appearing inside a function body that we recognize and rewrite.
/// Anything else stays as a RawZig stmt.
pub const Stmt = union(enum) {
    using_stmt: UsingStmt,
    own_decl: OwnDecl,
    move_expr_stmt: MoveExpr,
    raw: RawZig,
};

pub const UsingStmt = struct {
    name: StringSlice,
    /// Raw RHS expression text (including any `try`, parens, etc.).
    init_text: StringSlice,
    span: diag.Span,
};

pub const OwnDecl = struct {
    name: StringSlice,
    /// Optional type annotation text (between `:` and `=`).
    type_text: ?StringSlice,
    init_text: StringSlice,
    is_const: bool,
    span: diag.Span,
};

pub const MoveExpr = struct {
    target: StringSlice,
    span: diag.Span,
};

pub const FnBody = struct {
    /// Recognized statements parsed out of the brace body.
    stmts: []Stmt,
    /// Span of the surrounding `{ ... }` (inclusive of braces).
    span: diag.Span,
};

pub const FnDecl = struct {
    sig: FnSig,
    body: ?FnBody,
};

pub const TraitMethod = struct {
    name: StringSlice,
    params: []Param,
    return_type: StringSlice,
    span: diag.Span,
};

pub const TraitDecl = struct {
    name: StringSlice,
    methods: []TraitMethod,
    is_pub: bool,
    /// Set when the trait is declared with `: structural` after the name
    /// (e.g. `trait Foo : structural { ... }`). Structural traits relax the
    /// Z0040 check: an `impl T for X` for a structural T may omit methods,
    /// because the type is allowed to satisfy them via its own definition.
    /// Methods that *are* listed in the impl block must still match an
    /// existing method on X — otherwise sema emits Z0002.
    is_structural: bool = false,
    span: diag.Span,
};

pub const ImplBlock = struct {
    trait_name: StringSlice,
    target_type: StringSlice,
    fns: []FnDecl,
    span: diag.Span,
};

pub const OwnedStructDecl = struct {
    name: StringSlice,
    is_pub: bool,
    /// Raw field text up to the first member fn (we treat fields as opaque).
    fields_text: StringSlice,
    fns: []FnDecl,
    derive: ?DeriveAttr,
    invariant: ?StringSlice,
    span: diag.Span,
};

pub const StructDecl = struct {
    name: StringSlice,
    is_pub: bool,
    fields_text: StringSlice,
    fns: []FnDecl,
    derive: ?DeriveAttr,
    span: diag.Span,
};

pub const ExternInterfaceDecl = struct {
    name: StringSlice,
    methods: []TraitMethod,
    is_pub: bool,
    span: diag.Span,
};

/// Untransformed Zig source — the parser slurps anything it doesn't understand
/// at the top level into one of these so that a `.zpp` containing only Zig
/// still round-trips.
pub const RawZig = struct {
    text: StringSlice,
    span: diag.Span,
};

pub const TopDecl = union(enum) {
    trait: TraitDecl,
    impl_block: ImplBlock,
    owned_struct: OwnedStructDecl,
    struct_decl: StructDecl,
    fn_decl: FnDecl,
    extern_interface: ExternInterfaceDecl,
    raw: RawZig,

    pub fn span(self: TopDecl) diag.Span {
        return switch (self) {
            .trait => |t| t.span,
            .impl_block => |i| i.span,
            .owned_struct => |o| o.span,
            .struct_decl => |s| s.span,
            .fn_decl => |f| f.sig.span,
            .extern_interface => |e| e.span,
            .raw => |r| r.span,
        };
    }
};

pub const File = struct {
    decls: []TopDecl,
    /// Reference to the original source for slice-backed identifiers.
    source: []const u8,
};

/// Slab-style arena that owns AST node arrays. Identifier text is borrowed
/// from the source buffer and is not freed here.
///
/// We delegate to `std.heap.ArenaAllocator` so freeing is one-shot and we
/// don't have to track per-allocation alignment.
pub const Arena = struct {
    backing: std.heap.ArenaAllocator,

    pub fn init(child_allocator: std.mem.Allocator) Arena {
        return .{ .backing = std.heap.ArenaAllocator.init(child_allocator) };
    }

    pub fn deinit(self: *Arena) void {
        self.backing.deinit();
    }

    pub fn arenaAllocator(self: *Arena) std.mem.Allocator {
        return self.backing.allocator();
    }

    pub fn alloc(self: *Arena, comptime T: type, n: usize) ![]T {
        if (n == 0) return &[_]T{};
        return self.backing.allocator().alloc(T, n);
    }

    pub fn dupe(self: *Arena, comptime T: type, src: []const T) ![]T {
        if (src.len == 0) return &[_]T{};
        return self.backing.allocator().dupe(T, src);
    }
};

test "ast arena alloc" {
    const a = std.testing.allocator;
    var arena = Arena.init(a);
    defer arena.deinit();
    const xs = try arena.alloc(u32, 4);
    try std.testing.expectEqual(@as(usize, 4), xs.len);
    xs[0] = 1;
    xs[3] = 9;
    try std.testing.expectEqual(@as(u32, 1), xs[0]);
    try std.testing.expectEqual(@as(u32, 9), xs[3]);
}

test "ast tagged unions construct" {
    const a = std.testing.allocator;
    var arena = Arena.init(a);
    defer arena.deinit();
    const params = try arena.alloc(Param, 1);
    params[0] = .{
        .name = "self",
        .type_text = "",
        .mode = .plain,
        .span = .empty(),
    };
    const methods = try arena.alloc(TraitMethod, 1);
    methods[0] = .{
        .name = "write",
        .params = params,
        .return_type = "!usize",
        .span = .empty(),
    };
    const td = TraitDecl{
        .name = "Writer",
        .methods = methods,
        .is_pub = false,
        .is_structural = false,
        .span = .empty(),
    };
    const decl: TopDecl = .{ .trait = td };
    try std.testing.expectEqualStrings("Writer", decl.trait.name);
}
