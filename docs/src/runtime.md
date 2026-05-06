# Runtime library reference

The Zig++ runtime — `lib/zpp.zig` and the modules it re-exports —
ships every helper that lowered `.zpp` source can call into:
fat-pointer construction for `dyn Trait`, ownership and arena
helpers, runtime contracts, the eleven `derive` traits, structured
concurrency via `TaskGroup`, the `Writer` trait stack, and a handful
of testing utilities. Lowered source imports the whole thing as
`@import("zpp")`.

This page is the single index to every public symbol the runtime
exposes. It complements the [Language spec](./language.md) (which
describes the surface syntax) and the [CLI reference](./cli.md)
(which describes how the compiler turns that syntax into Zig).

## Module map

`@import("zpp")` resolves to `lib/zpp.zig`, which is a pure barrel:

| Symbol                | Kind              | Backed by         |
| --------------------- | ----------------- | ----------------- |
| `zpp.trait`           | module            | `lib/traits.zig`  |
| `zpp.owned`           | module            | `lib/owned.zig`   |
| `zpp.contract`        | module            | `lib/contracts.zig` |
| `zpp.dyn_mod`         | module            | `lib/dyn.zig`     |
| `zpp.async_mod`       | module            | `lib/async.zig`   |
| `zpp.testing_`        | module            | `lib/testing.zig` |
| `zpp.derive`          | module            | `lib/derive.zig`  |
| `zpp.writer`          | module            | `lib/writer.zig`  |
| `zpp.Dyn`             | type constructor  | `dyn_mod.Dyn`     |
| `zpp.VTableOf`        | type constructor  | `trait.VTableOf`  |
| `zpp.implFor`         | function          | `trait.implFor`   |
| `zpp.Owned`           | type constructor  | `owned.Owned`     |
| `zpp.ArenaScope`      | struct            | `owned.ArenaScope`|
| `zpp.DeinitGuard`     | struct            | `owned.DeinitGuard` |
| `zpp.requires`        | function          | `contract.requires` |
| `zpp.ensures`         | function          | `contract.ensures`  |
| `zpp.invariant`       | function          | `contract.invariant` |

The trailing-underscore on `testing_` and the `_mod` suffixes on
`dyn_mod` / `async_mod` exist so the field names don't shadow Zig
standard-library namespaces a user might have imported in the same
file.

## Use as a Zig dependency

To consume the runtime from your own Zig project:

```sh
zig fetch --save git+https://github.com/nktkt/zigpp-lang
```

Then in `build.zig.zon`:

```zig
.dependencies = .{
    .zigpp = .{
        .url  = "git+https://github.com/nktkt/zigpp-lang",
        .hash = "...", // populated by `zig fetch --save`
    },
},
```

And in `build.zig`, lower each `.zpp` file via the bundled `zpp`
artifact and wire the `zpp` runtime module into the resulting
module:

```zig
const zpp_dep = b.dependency("zigpp", .{
    .target   = target,
    .optimize = optimize,
});

const lower = b.addRunArtifact(zpp_dep.artifact("zpp"));
lower.addArg("lower");
lower.addFileArg(b.path("src/main.zpp"));
const lowered = lower.captureStdOut();

const wf       = b.addWriteFiles();
const main_zig = wf.addCopyFile(lowered, "main.zig");

const exe_mod = b.createModule(.{
    .root_source_file = main_zig,
    .target           = target,
    .optimize         = optimize,
});
exe_mod.addImport("zpp", zpp_dep.module("zpp"));
```

For a complete worked example (build script, `.zon`, `.zpp` source,
all under ~50 LOC) see `examples-consumer/` in this repository.
`zpp init <name>` scaffolds the same shape — see the
[CLI reference](./cli.md#zpp-init) for the templates.

---

## `zpp.trait` — vtable construction

The trait module is the low-level mechanism that backs the
language-level `dyn Trait` keyword. Two functions:

```zig
// Build a vtable struct type from a tuple of (name, fn-type) pairs.
// Each function-type's first parameter must be `*anyopaque`.
pub fn VTableOf(comptime methods: anytype) type;

// Construct a vtable instance forwarding to a concrete type's
// methods. Methods up to arity 16 are supported.
pub fn implFor(comptime VT: type, comptime T: type, comptime methods: anytype) VT;
```

In practice you rarely call these directly — the compiler generates
the vtable type as `Trait_VTable` and the instance as
`Trait_impl_for_T`. Direct use is most common when wiring a `dyn`
across an FFI boundary.

## `zpp.Dyn(VTable)` — visible fat pointer

A `Dyn(VTable)` pairs an erased instance pointer with its vtable.
Dynamic dispatch is *visible*: every method call goes through
`d.vtable.method(d.ptr, ...)` in the lowered Zig, no implicit
indirection.

```zig
pub fn Dyn(comptime VT: type) type {
    return struct {
        const Table = VT;
        ptr:    *anyopaque,
        vtable: *const VT,

        pub fn init(comptime T: type, value: *T, vt: *const VT) Self;
        pub fn from(comptime T: type, value: *T, comptime methods: anytype) Self;
        pub fn cast(self: Self, comptime T: type) *T;
        pub fn vtableField(self: Self, comptime name: []const u8) FieldType(VT, name);
    };
}
```

`from` is a convenience that builds the vtable at comptime from a
method tuple — equivalent to `init(T, ptr, &implFor(VT, T, methods))`.
`cast` is unsafe; the caller must know the original concrete type.

```zig
var gain = Gain{ .factor = 0.5 };
const d = zpp.Dyn(AudioEffect_VTable).from(Gain, &gain, .{
    .{ "process", Gain.process },
});
```

When the compiler lowers `fn f(x: dyn AudioEffect)` it becomes
`fn f(x: zpp.Dyn(AudioEffect_VTable))`.

See: `examples/dyn_plugin.zpp`, `examples/event_bus.zpp`.

---

## `zpp.owned` — ownership helpers

The language-level `using x = expr;` and `own var x` keywords are
**pure compiler-level lowerings** — neither one calls into the
runtime. The helpers below are stand-alone utilities that user code
can reach for; they're particularly useful when interfacing
hand-written Zig with `.zpp` callers.

### `Owned(T)`

A runtime affine wrapper. Panics in safe builds (`Debug`,
`ReleaseSafe`) if the value is taken twice or dropped without being
taken.

```zig
pub fn Owned(comptime T: type) type {
    pub fn wrap(value: T) Self;
    pub fn take(self: *Self) T;
    pub fn borrow(self: *Self) *T;
    pub fn isLive(self: *const Self) bool;
    pub fn deinit(self: *Self) void;
}
```

### `ArenaScope`

A thin wrapper around `std.heap.ArenaAllocator` whose `init` /
`deinit` shape matches the `using` lowering, so
`using arena = ArenaScope.init(parent)` does the right thing.

```zig
pub const ArenaScope = struct {
    arena: std.heap.ArenaAllocator,
    pub fn init(parent: std.mem.Allocator) ArenaScope;
    pub fn allocator(self: *ArenaScope) std.mem.Allocator;
    pub fn reset(self: *ArenaScope) void;
    pub fn deinit(self: *ArenaScope) void;
};
```

### `DeinitGuard`

Generic ad-hoc RAII helper. Runs an arbitrary cleanup once, with
explicit dismissal:

```zig
pub const DeinitGuard = struct {
    pub fn init(ctx: anytype, comptime f: anytype) DeinitGuard;
    pub fn dismiss(self: *DeinitGuard) void;
    pub fn run(self: *DeinitGuard) void;
    pub fn deinit(self: *DeinitGuard) void;
};
```

### `takeOwnership`

```zig
pub fn takeOwnership(ptr: anytype) @TypeOf(ptr.*);
```

Moves a value out of a pointer, overwriting the source with
`undefined` in safe builds — the runtime equivalent of the
language-level `move x`.

---

## `zpp.contract` — runtime contracts

`requires(...)` and `ensures(...)` in `.zpp` source lower to calls
into this module. The functions are inline-conditional on a
comptime `checks_on` flag (`true` in `Debug`/`ReleaseSafe`, `false`
in `ReleaseFast`/`ReleaseSmall`), so contracts compile to zero
runtime cost in release builds — the panic branch and message
strings are statically eliminated.

### Core checks

```zig
pub inline fn requires(cond: bool, comptime msg: []const u8) void;
pub inline fn ensures (cond: bool, comptime msg: []const u8) void;
pub inline fn invariant(cond: bool, comptime msg: []const u8) void;
pub inline fn unreachableContract(comptime msg: []const u8) noreturn;
```

`ensures` is lowered as a `defer` so the condition evaluates at
scope-exit time and reflects final state. `unreachableContract`
panics in safe builds and compiles to `unreachable` in release
modes (so the optimizer can prune the branch).

### Relational helpers

```zig
pub inline fn requiresEq      (comptime T: type, a: T, b: T,    comptime msg: []const u8) void;
pub inline fn requiresLt      (comptime T: type, a: T, b: T,    comptime msg: []const u8) void;
pub inline fn requiresLe      (comptime T: type, a: T, b: T,    comptime msg: []const u8) void;
pub inline fn requiresInRange (comptime T: type, v: T, lo: T, hi: T, comptime msg: []const u8) void;
pub inline fn requiresNonNull (p: anytype,                      comptime msg: []const u8) void;
pub inline fn requiresType    (comptime cond: bool,             comptime msg: []const u8) void;
```

`requiresType` fails with `@compileError` rather than at runtime — useful
in generic code.

### Combined wrapper

```zig
pub inline fn checked(
    comptime R: type,
    pre: bool,
    comptime pre_msg: []const u8,
    body: anytype,
    post: *const fn (R) bool,
    comptime post_msg: []const u8,
) R;
```

Runs `requires(pre, pre_msg)`, evaluates `body()`, then runs
`ensures(post(out), post_msg)` — useful when wrapping a foreign call
from outside the lowering.

See: `examples/contracts_sort.zpp`.

---

## `zpp.derive` — comptime trait synthesis

Eleven derives, all comptime — no vtable dispatch, no runtime
allocation at synthesis time. They integrate with the language-level
`derive(.{ ... })` keyword, which expands to attaching their public
methods directly to the target struct.

| Derive       | Methods injected                                                              | Allocator? |
| ------------ | ----------------------------------------------------------------------------- | ---------- |
| `Hash`       | `hash(self) u64`, `hashWithSeed(self, seed) u64`                              | no         |
| `Eq`         | `eq(a, b) bool`, `ne(a, b) bool`                                              | no         |
| `Default`    | `default() T`                                                                 | no         |
| `Ord`        | `cmp(self, other) i32`                                                        | no         |
| `Clone`      | `clone(self, allocator) Allocator.Error!T`                                    | yes        |
| `Debug`      | `format(self, w: *std.Io.Writer) !void` (+ `Debug` wrapper struct)            | no         |
| `Json`       | `toJson(self, a) ![]u8`, `fromJson(s, a) !T`                                  | yes        |
| `Iterator`   | `iter(_) FieldIter`, `fieldCount() usize`                                     | no         |
| `Serialize`  | `serialize(self, a) ![]u8`, `writeTo(self, w) !void` — `key=value;` format    | yes        |
| `Compare`    | `lt`, `le`, `gt`, `ge`, `min`, `max`                                          | no         |
| `FromStr`    | `parse(s, a) !T` — `key=value,` format (errors `InvalidFormat`/`UnknownField`) | yes        |

A few notes worth lifting out of the table:

- **`Hash`** uses Wyhash recursively over fields. Pointers hash by
  address; `[]const u8` slices hash byte-wise.
- **`Eq`** does a deep field comparison. `[]const u8` slices use
  `std.mem.eql`, other slices compare element-wise.
- **`Json`** round-trips via `std.json`. `fromJson` returns a leaky
  parse — slice and pointer fields borrow from the supplied
  allocator, which should be an arena.
- **`Serialize`** and **`FromStr`** are intentionally a *different*
  format from `Json`. `Serialize` uses `;`-separated `key=value`
  pairs; `FromStr` parses `,`-separated pairs back. There is no
  escaping; if your data contains `;`, `,`, or `=`, use `Json`.
- **`Iterator`** yields *field names*, not values — designed for
  reflection-style code, not data iteration.
- **`Compare`** is sugar over `Ord(T).cmp` — `lt(a, b)` is just
  `Ord(T).cmp(a, b) < 0`.

See: `examples/derive_user.zpp`, `examples/event_bus.zpp`.

---

## `zpp.async_mod` — structured concurrency

`std.Thread`-backed structured concurrency with cooperative
cancellation. Every `spawn` launches a real OS thread immediately
and returns a typed `*JoinHandle(T)`. No `async`/`await`, no
implicit suspension.

### `TaskGroup`

```zig
pub const TaskGroup = struct {
    pub fn init(a: std.mem.Allocator) TaskGroup;
    pub fn spawn         (self: *TaskGroup, comptime f: anytype, args: anytype) !*JoinHandle(R);
    pub fn spawnWithToken(self: *TaskGroup, comptime f: anytype, args: anytype) !*JoinHandle(R);
    pub fn join  (self: *TaskGroup) !void;
    pub fn cancel(self: *TaskGroup) void;
    pub fn token (self: *TaskGroup) *CancellationToken;
    pub fn deinit(self: *TaskGroup) void;
};
```

- `spawn(f, args)` — starts an OS thread immediately; returns
  `*JoinHandle(R)` where `R` is `f`'s return-type payload (errors
  stripped). After `join()` returns, `spawn` fails with
  `error.GroupAlreadyJoined`.
- `spawnWithToken(f, args)` — same, but `f`'s first parameter is
  `*CancellationToken` (the group's shared token). `args` is
  everything after that.
- `join()` — blocks until every worker finishes. A watchdog flips
  the cancellation token on the first failure so cooperative
  siblings short-circuit; the first non-`Cancelled` error wins.
- `cancel()` — sets the shared token; subsequent `spawn` calls
  return synthetic cancelled handles without starting threads.
- `deinit()` — joins and destroys every still-live handle, then
  frees the task list.

### `JoinHandle(T)`

```zig
pub fn JoinHandle(comptime T: type) type {
    pub const Result = T;
    pub fn currentState(self: *const Self) TaskState;
    pub fn isDone     (self: *const Self) bool;
    pub fn wait       (self: *Self) void;
    pub fn join       (self: *Self) !T;
    pub fn destroy    (self: *Self) void;
};
pub const Task = JoinHandle(void);  // alias
```

`TaskState` is `.pending | .running | .done | .failed | .cancelled`.
Both `wait()` and `join()` are idempotent. `destroy()` is what
`TaskGroup.deinit()` calls under the hood.

### `CancellationToken`

```zig
pub const CancellationToken = struct {
    pub fn init() CancellationToken;
    pub fn cancel(self: *CancellationToken) void;
    pub fn isCancelled(self: *const CancellationToken) bool;
    pub fn throwIfCancelled(self: *const CancellationToken) error{Cancelled}!void;
};
```

Atomic flag with acquire/release semantics. `throwIfCancelled` is
the cooperative check sites should use in inner loops.

See: `examples/async_group.zpp`.

---

## `zpp.writer` — Writer trait stack

A type-erased write-bytes sink trait plus three concrete
implementations. All zero-allocation; buffering uses a fixed-size
stack array.

```zig
pub const WriterError = std.fs.File.WriteError;

pub const Writer_VTable = struct {
    write: *const fn (ptr: *anyopaque, bytes: []const u8) WriterError!usize,
    flush: *const fn (ptr: *anyopaque) WriterError!void,
};

pub const Writer = dyn.Dyn(Writer_VTable);

pub fn writeAll(self: Writer, bytes: []const u8) WriterError!void;
pub fn flush   (self: Writer) WriterError!void;
pub fn print   (self: Writer, comptime fmt: []const u8, args: anytype) WriterError!void;
```

`print` streams through a 1024-byte staging buffer so arbitrarily
long format strings work in O(1) stack.

### Concrete impls

```zig
pub const StdoutWriter = struct {
    pub fn init() StdoutWriter;
    pub fn writer(self: *StdoutWriter) Writer;
    // write/flush — flush is a no-op
};
pub fn stdout() StdoutWriter;  // convenience

pub const FileWriter = struct {
    pub fn init(file: std.fs.File) FileWriter;  // does not own the file
    pub fn writer(self: *FileWriter) Writer;
    // write/flush — flush is a no-op (kernel manages page cache;
    //               call file.sync() if you need fsync)
};

pub fn BufferedWriter(comptime BufSize: comptime_int) type {
    return struct {
        inner: Writer,
        buf:   [BufSize]u8 = undefined,
        len:   usize = 0,
        pub fn init(inner: Writer) Self;
        pub fn writer(self: *Self) Writer;
        // write/flush — flush forwards `buf[0..len]` to inner.
    };
}
```

See: `examples/writer_buffered.zpp`.

---

## `zpp.testing_` — test helpers

Augments `std.testing` with four orthogonal helpers, all designed
to be called from inside `test "..." { ... }` blocks.

| Helper                    | Signature                                                                                              | Purpose                                                       |
| ------------------------- | ------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------- |
| `expectDeinitCalled(_, f, args)` | `(comptime _: type, f: anytype, args: anytype) !void`                                            | Run `f(allocator, args...)` against a leak-detecting GPA; assert no leaks. |
| `expectNoAlloc(f, args)`  | `(f: anytype, args: anytype) !void`                                                                    | Run against a `FailingAllocator`. Allocation triggers `error.AllocatedUnderNoAllocContract`. |
| `property(T, gen, prop, n)` | `(comptime T: type, comptime gen: anytype, comptime prop: anytype, iters: usize) !void`              | Property test: `gen(*std.Random) T`, `prop(T) bool`/`!bool`, `iters` rounds. Fails with `error.PropertyFalsified` (prints seed + offending input). |
| `snapshot(actual, path)`  | `(actual: []const u8, comptime path: []const u8) !void`                                                | Compare to file. `ZPP_UPDATE_SNAPSHOTS=1` rewrites the file instead. |

These helpers compose with standard `std.testing.expect*` in the
same `test` block; they don't try to replace it.

---

## Benchmarks

`bench/bench.zig` is a microbenchmark of the **compiler** pipeline:
it synthesizes `.zpp` source ranging from 10 to 10,000 trait + impl
declarations, then times `compileToString()` (parse + sema +
lowering) end-to-end. Run with:

```sh
zig build bench
```

Output is a markdown table of input bytes / output bytes / throughput
suitable for pasting into a perf doc. Lowered output is typically
1.5–3× the input size due to the vtable structs and forwarding
thunks the compiler emits for `dyn` and `impl` blocks.

The benchmark deliberately measures *compile-time* cost, not
runtime — the runtime overhead of traits and dynamic dispatch is
paid once at compile time, not per call.
