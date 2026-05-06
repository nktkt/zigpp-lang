# Zig++ Language Sketch (v0.2 draft)

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

Method arity is `0..16` parameters (counting `self`). Signatures over 16
parameters emit Z0001. The earlier 5-parameter ceiling has been lifted in
v0.2.

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

## Structural traits

```
trait_decl ::= "trait" Ident ":" "structural" "{" trait_member* "}"
```

Adding `: structural` after a trait name opts the trait into duck typing.
A type satisfies a structural trait if it has decls with matching names and
shapes; no `impl` block is required. The standard nominal Z0040 ("type does
not implement Trait") is suppressed for structural traits.

`impl` blocks are still permitted on structural traits as a way to *re-export*
or rename methods, but each method named in the block must already exist on
the target type. If it does not, the compiler emits Z0002 ("structural impl
references missing method"). This makes `: structural` strictly more permissive
than nominal traits: anything that fits the shape works without ceremony, and
anything that *claims* to fit is checked.

```zigpp
trait Sized : structural {
    fn len(self) usize;
}

fn print_len(x: anytype) void where(x: Sized) {
    std.debug.print("{d}\n", .{x.len()});
}
```

Lowering: structural traits produce the same `_VTable` struct as nominal
traits, but `where(x: Sized)` lowers to a `@hasDecl`-based shape check rather
than a registry lookup. See `examples/structural_trait.zpp` and
`examples/structural_advanced.zpp`.

---

## Trait method default bodies

```
trait_member ::= "fn" Ident "(" "self" ("," param)* ")" return_type (";" | block)
```

A trait method may carry a body. The body is the *default*: any `impl` block
may omit the method, in which case calls resolve to the default. Calls go
through the same vtable; the default is installed as the slot's function
pointer when an impl does not supply one.

```zigpp
trait Greeter {
    fn name(self) []const u8;
    fn greet(self) []const u8 {
        return "hello";
    }
}

impl Greeter for World {
    fn name(self) []const u8 { return "world"; }
    // greet omitted -> default used
}
```

Lowering: each defaulted method emits a free function
`<Trait>_default_<method>` that takes `*anyopaque` and forwards to the body.
The vtable construction in `zpp.trait.implFor` falls back to the default
symbol when the impl tuple does not name the method. See
`examples/trait_default.zpp`.

```zig
fn Greeter_default_greet(_: *anyopaque) []const u8 {
    return "hello";
}
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
- `.noasync` — no thread spawn, task group work, or suspension primitives
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

### `.noasync`

The sixth axis of effect inference, added in v0.2. A function annotated
`effects(.noasync)` may not, transitively, perform any of:

- `std.Thread.spawn` / `std.Thread.Pool.spawn`
- `zpp.async.TaskGroup.spawn`, `.spawnWithToken`, `.cancel`
- `@asyncCall`, `suspend`, `resume`
- any function whose own inferred effect set lacks `.noasync`

The check is a syntactic + name-based heuristic walking the call graph; a
violating call site emits Z0030 with a `noasync` axis label. See
`examples/effects_noasync.zpp` and `examples/effects_nopanic_demo.zpp` for
the pattern shared by the panic-free and async-free axes.

---

## `derive(.{...})`

```
derive_attr ::= "derive" "(" "." "{" "." Ident ("," "." Ident)* "}" ")"
```

Attaches typed, comptime-built helpers to a struct. Implemented helpers:

- `.Hash` — `pub fn hash(value: T) u64`
- `.Eq` — `pub fn eql(a: T, b: T) bool`
- `.Debug` — `pub fn format(value: T, w: *std.Io.Writer) !void`
- `.Ord` — `pub fn cmp(self: T, other: T) i32`
- `.Default` — `pub fn default() T`
- `.Clone` — `pub fn clone(value: T, alloc: std.mem.Allocator) !T`
- `.Json` — JSON formatting helper namespace
- `.Iterator` — `pub fn iter(self: T) FieldIter`
- `.Serialize` — `pub fn serialize(self: T, alloc: std.mem.Allocator) ![]u8`
- `.Compare` — `pub fn lt/le/gt/ge(self: T, other: T) bool`
- `.FromStr` — `pub fn fromStr(s: []const u8, alloc: std.mem.Allocator) !T`

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

## Concurrency / `TaskGroup`

`zpp.async.TaskGroup` is the structured concurrency primitive. A group owns
a set of spawned tasks and joins them on `deinit`; failures propagate.

```zigpp
fn run(allocator: std.mem.Allocator) !void {
    using group = zpp.async.TaskGroup.init(allocator);
    try group.spawn(workA, .{});
    try group.spawn(workB, .{});
}
```

v0.2 additions:

- `cancel()` — request cancellation of every still-running task in the
  group. Tasks observe cancellation via their `CancelToken` and are expected
  to return early. `cancel()` is idempotent.
- `spawnWithToken(fn_with_token, args)` — spawn a task that receives a
  `*CancelToken` as its first argument. The token's `isCancelled()` is the
  cooperative check.
- Watchdog auto-cancel — when any task in the group returns an error, the
  group implicitly calls `cancel()` on the remaining tasks before joining.
  This makes "first error wins, rest abort" the default shape.

```zigpp
fn worker(tok: *zpp.async.CancelToken) !void {
    while (!tok.isCancelled()) {
        // ...
    }
}

fn run(allocator: std.mem.Allocator) !void {
    using group = zpp.async.TaskGroup.init(allocator);
    try group.spawnWithToken(worker, .{});
    try group.spawnWithToken(worker, .{});
    // group.cancel() also fires automatically if any task returns an error
}
```

Cancellation is cooperative: a task that ignores its token will run to
completion. See `examples/async_group.zpp` for the extended demo.

---

## `build.zpp`

A project may write its build script in `.zpp`. `zpp build` looks for, in
order:

1. `build.zig` — used as-is, no lowering. Hand-written wins.
2. `build.zpp` — lowered to `build.zig` on demand, then forwarded to the
   Zig toolchain.

The lowering is mtime-based: if `build.zig` exists and is newer than
`build.zpp`, the lowering step is skipped. Otherwise `build.zpp` is lowered
and the resulting `build.zig` is written next to it (and listed in
`.gitignore` by `zpp init`). Subsequent commands detect the freshness and
short-circuit.

```zigpp
// build.zpp
const std = @import("std");

pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "demo",
        .root_source_file = b.path("src/main.zpp"),
    });
    b.installArtifact(exe);
}
```

Precedence rule: a hand-written `build.zig` is never overwritten. If both
files are present, `zpp build` warns once and uses `build.zig`.

---

## Stdlib

### `Writer`

`zpp.writer.Writer` is the canonical output trait. It uses the same vtable
shape as any other `dyn`-capable trait (instance pointer + `Writer_VTable`).

```zigpp
trait Writer {
    fn write(self, b: []const u8) !usize;
    fn flush(self) !void;
}
```

Concrete implementations shipped in `lib/zpp/writer.zig`:

- `StdoutWriter` — wraps `std.io.getStdOut().writer()`.
- `FileWriter` — wraps `std.fs.File`, closes on `deinit` (it is `owned`).
- `BufferedWriter(comptime N: usize)` — fixed-size in-line buffer of N
  bytes; `flush()` drains to the wrapped inner writer. `N = 4096` is the
  recommended default.

All three have a static `*_Writer_vtable` so they can be passed as
`dyn Writer` without boxing. See `examples/writer_buffered.zpp`.

---

## CLI

`zpp` is the project entrypoint. Subcommands:

- `zpp build` — lower `build.zpp` (if present, see above) and forward all
  remaining args to `zig build`.
- `zpp run <file.zpp>` — lower-and-run a single file.
- `zpp test [paths...]` — discover `test "..."` blocks across `.zpp` files
  under the given paths (default `src/` and `tests/`), lower them, and
  invoke `zig test` on the result.
  - `--filter <substring>` — only run tests whose name matches.
  - `--release` — pass `-Doptimize=ReleaseSafe` through.
  - `-v` / `--verbose` — print each test's lowered command line.
- `zpp explain <code>` — print the long-form description of a Z00xx
  diagnostic.
  - `--json` — emit IDE-consumable JSON: `{ "code", "title", "summary",
    "examples": [...], "related": [...] }`. Stable schema.
- `zpp init [name]` — scaffold a new project.
  - `--template lib` — library crate (default if `name` ends in `-lib`).
  - `--template exe` — executable with `src/main.zpp`.
  - `--template plugin` — `extern interface` plugin skeleton with a host
    loader test.
- `zpp fmt [paths...]` — format `.zpp` files in place.

Exit codes follow the Zig convention: 0 success, 1 user error, 2 internal
compiler error.

---

## IDE

The Zig++ language server (`zpp-lsp`) speaks LSP 3.17. As of v0.2 the
following capabilities are advertised:

- `textDocument/hover`
- `textDocument/definition`
- `textDocument/references`
- `textDocument/documentSymbol`
- `textDocument/completion`
- `textDocument/rename`
- `textDocument/formatting`
- `textDocument/inlayHint` — effect axes, derived methods, default-body
  fills.
- `textDocument/foldingRange` — trait/impl/struct/`test "..."` blocks.
- `textDocument/implementation` — jump from a trait method to every
  impl.
- `textDocument/prepareCallHierarchy`,
  `callHierarchy/incomingCalls`,
  `callHierarchy/outgoingCalls` — three methods, full call-graph
  navigation.
- `textDocument/codeLens` — "run test", "show lowered Zig", "explain
  diagnostic".

Diagnostics published via `textDocument/publishDiagnostics` carry the
`Z00xx` code and a `data` field equivalent to the JSON returned by
`zpp explain --json`, so editors can render rich descriptions inline.

---

## Migration helpers

`zpp migrate` rewrites idiomatic Zig into idiomatic Zig++. The patterns it
recognises (v0.2):

- `@panic(...)` guarding an entry condition becomes `requires(...)`.
- A hand-written `pub fn hash` / `pub fn eql` pair becomes
  `derive(.{ .Hash, .Eq })`.
- A struct that takes an allocator and has a `deinit(*Self)` becomes an
  `owned struct`.
- A function whose body provably performs no I/O gains
  `effects(.noio)`.
- An `error.X` thrown immediately on entry becomes
  `requires(..., "X")`.

Each pattern is opt-in via `--patterns=...` and reported with the same
diagnostic codes the compiler would emit had the user written the source
that way.

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
