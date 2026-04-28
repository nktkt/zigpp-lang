# Examples

The `examples/` directory contains 8 small `.zpp` programs that
exercise each Zig++ construct. All of them lower to readable Zig and
run end-to-end (`zig build e2e` runs the lot).

## hello_trait.zpp — static dispatch

```zig
{{#include ../../examples/hello_trait.zpp}}
```

`fn welcome(who: impl Greeter)` lowers to `fn welcome(who: anytype)`.
The impl method is also injected directly into the `English` and
`Japanese` struct bodies as `pub fn greet(self: *@This()) void { ... }`,
so `who.greet()` resolves through Zig's normal method lookup.

## owned_file.zpp — explicit RAII

```zig
{{#include ../../examples/owned_file.zpp}}
```

`using log = LogFile.init(...)` lowers to `var log = ...; defer log.deinit();`.
`owned struct LogFile` is sema-checked for a `deinit` method.

## dyn_plugin.zpp — dynamic dispatch

```zig
{{#include ../../examples/dyn_plugin.zpp}}
```

`fn applyAll(chain: []const dyn AudioEffect, ...)` lowers to a slice
of `zpp.Dyn(AudioEffect_VTable)` fat pointers. Every `dyn` is visible
at the call site — there is no implicit virtual dispatch.

## extern_plugin.zpp — C-ABI plugin interface

```zig
{{#include ../../examples/extern_plugin.zpp}}
```

`extern interface AudioPlugin { ... }` lowers to
`extern struct AudioPlugin_ABI { ... }` with `callconv(.c)` function
pointers, suitable for dlopen/dlsym plugins.

## owned + move

```zig
{{#include ../../examples/owned_file.zpp:38:64}}
```

`own var transferable = ...` declares an affine binding;
`move transferable` consumes it. Subsequent uses produce diagnostic
Z0020 with a fix hint.

## contracts_sort.zpp — requires/ensures + where

```zig
{{#include ../../examples/contracts_sort.zpp}}
```

`requires(isSorted(T, xs))` is checked at function entry.
`ensures(...)` would be checked on every scope exit via `defer`.
`where T: Ord` is informational at lowering but documents the
constraint.

## derive_user.zpp — comptime derive

```zig
{{#include ../../examples/derive_user.zpp}}
```

`} derive(.{ Hash, Eq, Debug });` injects member methods directly:
`a.hash()`, `User.eq(a, b)`, `User.debug.format(a, w)`.

## effects_pure.zpp — effect annotations

```zig
{{#include ../../examples/effects_pure.zpp}}
```

`effects(.noalloc, .noio) fn fnv1a(...)` is sema-linted (Z0030 if it
calls anything that allocates).

## async_group.zpp — structured concurrency

```zig
{{#include ../../examples/async_group.zpp}}
```

`zpp.async_mod.TaskGroup` is the MVP serial executor — `spawn`
schedules, `join` runs to completion. Every primitive is explicit;
there is no implicit await.
