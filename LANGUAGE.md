# Zig++ Language Sketch (v0.1 draft)

This document is a working sketch, not a normative specification. It defines
the new constructs Zig++ adds on top of Zig 0.16 and how each lowers to Zig.
A `.zpp` file that uses none of these constructs is a `.zig` file.

Each section gives:

1. A BNF-ish syntax box.
2. A short semantics paragraph.
3. A small example.
4. A lowering rule, before-and-after Zig.

The runtime support module is named `zpp` (see `lib/zpp.zig`). Lowered files
implicitly `@import("zpp")` if any new construct is used.

---

## `trait`

```
trait_decl   ::= "trait" Ident "{" trait_member* "}"
trait_member ::= "fn" Ident "(" "self" ("," param)* ")" return_type ";"
```

A `trait` declares a named, nominal interface: a set of method signatures.
A trait alone has no runtime representation. Lowering produces a `_VTable`
struct type whose fields are function pointers taking `*anyopaque` as the
first argument.

```zigpp
trait Writer {
    fn write(self, b: []const u8) !usize;
    fn flush(self) !void;
}
```

Lowering:

```zig
pub const Writer_VTable = zpp.VTableOf(.{
    .{ "write", *const fn (*anyopaque, []const u8) anyerror!usize },
    .{ "flush", *const fn (*anyopaque) anyerror!void },
});
```

---

## `impl`

```
impl_decl   ::= "impl" Ident "for" Ident "{" impl_member* "}"
impl_member ::= "fn" Ident "(" param_list ")" return_type block
impl_param  ::= "impl" Ident         /* parameter form */
```

Block form attaches a trait to a concrete type. Parameter form
`fn f(x: impl Trait)` is sugar for a comptime-monomorphised call where the
type is inferred at the call site (no boxing, no vtable).

```zigpp
impl Writer for FileSink {
    fn write(self, b: []const u8) !usize { ... }
    fn flush(self) !void { ... }
}

fn copy(w: impl Writer, src: []const u8) !void {
    _ = try w.write(src);
}
```

Lowering of `impl` block: emit one `Type_Trait_method` free function per
member, plus a comptime-built static vtable instance:

```zig
fn FileSink_Writer_write(self: *FileSink, b: []const u8) anyerror!usize { ... }
fn FileSink_Writer_flush(self: *FileSink) anyerror!void { ... }

pub const FileSink_Writer_vtable: Writer_VTable = zpp.trait.implFor(
    Writer_VTable, FileSink, .{
        .{ "write", FileSink_Writer_write },
        .{ "flush", FileSink_Writer_flush },
    },
);
```

Lowering of `impl` parameter form: a generic comptime parameter plus a
`@hasDecl` check; no vtable is created.

---

## `dyn Trait`

```
dyn_type ::= "dyn" Ident
```

`dyn Trait` is a fat pointer: instance pointer plus vtable pointer.
Constructing one requires an explicit `dyn` expression: `dyn x` builds the
fat pointer for `x` against `Trait`'s vtable.

```zigpp
fn shout(g: dyn Greeter) []const u8 {
    return g.greet();
}
```

Lowering:

```zig
fn shout(g: zpp.Dyn(Greeter_VTable)) []const u8 {
    return g.vtable.greet(g.ptr);
}
```

`dyn x` at a call site lowers to `zpp.dyn_mod.fromImpl(VT, T, &x, .{...})`.

---

## `using` — explicit RAII

```
using_decl ::= "using" Ident "=" expr ";"
```

Binds a value and inserts a `defer x.deinit()` immediately after the binding.
Compile error if the value's type has no `deinit` method (Z0011).

```zigpp
fn run(allocator: std.mem.Allocator) !void {
    using arena = zpp.ArenaScope.init(allocator);
    const a = arena.allocator();
    _ = a;
}
```

Lowering:

```zig
fn run(allocator: std.mem.Allocator) !void {
    var arena = zpp.ArenaScope.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = a;
}
```

`using` is the *only* way Zig++ introduces a `defer`-style cleanup the user
did not type. The keyword makes that visible.

---

## `owned struct`

```
owned_struct ::= "owned" "struct" Ident "{" struct_body "}"
```

Marks a type whose values **must** be consumed by either a `using` binding,
a `move` into another `own var`, or an explicit `.deinit()` call. A type
declared `owned` must also declare `deinit`. Missing deinit emits Z0010.

```zigpp
owned struct File {
    handle: i32,
    fn open(path: []const u8) !File { ... }
    fn deinit(self: *File) void { ... }
}
```

Lowering: identical Zig struct; the owned-ness is a sema-only marker that
constrains uses of the type elsewhere.

---

## `own var` and `move`

```
own_var ::= "own" "var" Ident ("=" expr)? ";"
move_expr ::= "move" Ident
```

`own var x = ...` declares a variable subject to the move checker. `move x`
consumes it: subsequent reads of `x` produce Z0020 (use-after-move). The
move checker is intra-function only in MVP; it does not track values across
function boundaries.

```zigpp
fn run() void {
    own var a = makeBuffer();
    const b = move a;
    // const c = a;  // Z0020 use-after-move
    consume(b);
}
```

Lowering: `move a` becomes `zpp.owned.takeOwnership(&a)`, which in safe
builds writes `undefined` to the source so accidental reads trip a panic.

---

## `where` clause

```
where_clause ::= "where" "(" where_pred ("," where_pred)* ")"
where_pred   ::= Ident ":" Ident
```

Constrains a comptime parameter to satisfy one or more traits. Used on
generic `fn` and on `impl` blocks. Failure emits Z0001 if the trait is
unknown, or a structural error if the type does not satisfy it.

```zigpp
fn write_all(w: anytype, src: []const u8) !void where(w: Writer) {
    _ = try w.write(src);
}
```

Lowering: the `where` clause becomes a comptime `if (!@hasDecl(...))
@compileError(...)` block at the top of the function body.

---

## `requires` / `ensures` / `invariant`

```
contract ::= ("requires" | "ensures") "(" expr ("," string)? ")" ";"
invariant_decl ::= "invariant" "(" expr ")" ";"
```

Function-level contracts. `requires` is checked on entry, `ensures` on
return. `invariant` inside a struct is checked at the start and end of every
method. Under safe builds, contract failure panics with the message; under
fast builds, contracts compile to no-ops.

```zigpp
fn sqrt(x: f64) f64 {
    requires(x >= 0.0, "sqrt domain");
    ensures(@as(f64, 0.0) <= @result(), "sqrt range");
    return @sqrt(x);
}
```

Lowering: each `requires(c, m)` becomes `zpp.requires(c, m);` at the top of
the function; each `ensures(c, m)` is hoisted into a `defer` block that
captures the result.

---

## `effects(...)` annotations

```
effects_clause ::= "effects" "(" "." Ident ("," "." Ident)* ")"
```

Attached to a function signature. Asserts the function performs no operation
of the listed forbidden classes. Initial classes:

- `.noalloc` — no allocator method calls
- `.noio` — no I/O (`std.debug.print`, `std.fs`, `std.io`, ...)
- `.nopanic` — no `@panic`, no array bounds violation in safe code
- `.noasync` — no I/O suspension
- `.nocustom("X")` — no user-defined `.custom("X")` effect

```zigpp
fn hash_block(b: []const u8) u64 effects(.noalloc, .nopanic) {
    var h: u64 = 0xcbf29ce484222325;
    for (b) |c| h = (h ^ c) *% 0x100000001b3;
    return h;
}
```

Lowering: effects are erased to a comment and recorded in the diagnostics
phase; violations emit Z0030. Effects do not change codegen.

---

## `derive(.{...})`

```
derive_attr ::= "derive" "(" "." "{" "." Ident ("," "." Ident)* "}" ")"
```

Attaches typed, comptime-built helpers to a struct. Initial set:

- `.Hash` — `pub fn hash(value: T) u64`
- `.Eq` — `pub fn eql(a: T, b: T) bool`
- `.Debug` — `pub fn format(value: T, w: *std.Io.Writer) !void`
- `.Clone` — `pub fn clone(value: T, alloc: std.mem.Allocator) !T`

```zigpp
derive(.{ .Hash, .Eq }) struct User {
    id: u64,
    name: []const u8,
}
```

Lowering: each derive expands to a `pub usingnamespace zpp.derive.<Name>(T);`
mixin at the bottom of the struct.

---

## `extern interface` (plugin ABI)

```
extern_iface ::= "extern" "interface" Ident "{" iface_member* "}"
iface_member ::= "fn" Ident "(" param_list ")" return_type ";"
```

Declares a C-ABI vtable layout suitable for crossing dynamic-library
boundaries. Unlike `trait`, an `extern interface` *is* its representation:
it lowers to an `extern struct` of `*const fn(...) callconv(.C)` pointers.

```zigpp
extern interface Plugin {
    fn name(self: *anyopaque) [*:0]const u8;
    fn run(self: *anyopaque, argc: c_int, argv: [*][*:0]const u8) c_int;
}
```

Lowering:

```zig
pub const Plugin = extern struct {
    name: *const fn (*anyopaque) callconv(.C) [*:0]const u8,
    run: *const fn (*anyopaque, c_int, [*][*:0]const u8) callconv(.C) c_int,
};
```

The host loads a plugin by reading a pointer to a `Plugin` instance from a
known exported symbol; no runtime trait machinery is involved.

---

## Lowering invariants

For every construct above:

1. The lowering is a pure, local rewrite. No global state is consulted.
2. The lowering does not introduce hidden allocations.
3. The lowering does not introduce hidden control flow other than `defer`,
   which is itself spelled by the source binder (`using`).
4. The lowered Zig must be self-contained: it imports `zpp` and nothing else
   that was not in scope in the `.zpp` source.
5. Diagnostics are emitted against the original `.zpp` span, never the
   lowered Zig span.

These invariants are tested by `tests/lowering/snapshots.zig` and enforced
in spirit by `tests/no_hidden_alloc/audit.zig`.
