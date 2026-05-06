# Examples

The `examples/` directory contains 15+ `.zpp` programs (plus a few
multi-file projects under `multi_file/`, `multi_file_pub/`,
`build_zpp/`, and `cli/`) that exercise each Zig++ construct. All of
them lower to readable Zig and run end-to-end (`zig build e2e` runs
the single-file ones; the multi-file projects are built directly).
The sections below walk through the headline examples; see the
[index in `examples/README.md`](https://github.com/nktkt/zigpp-lang/blob/main/examples/README.md)
for the full list. Each section shows the source plus the actual
stdout produced by `zpp run`.

## hello_trait.zpp — static dispatch

```zig
{{#include ../../examples/hello_trait.zpp}}
```

```text
{{#include ./output/hello_trait.txt}}
```

`fn welcome(who: impl Greeter)` lowers to `fn welcome(who: anytype)`.
The impl method is also injected directly into the `English` and
`Japanese` struct bodies as `pub fn greet(self: *@This()) void { ... }`,
so `who.greet()` resolves through Zig's normal method lookup.

## owned_file.zpp — explicit RAII

```zig
{{#include ../../examples/owned_file.zpp}}
```

```text
{{#include ./output/owned_file.txt}}
```

`using log = LogFile.init(...)` lowers to `var log = ...; defer log.deinit();`.
`owned struct LogFile` is sema-checked for a `deinit` method.

## dyn_plugin.zpp — dynamic dispatch

```zig
{{#include ../../examples/dyn_plugin.zpp}}
```

```text
{{#include ./output/dyn_plugin.txt}}
```

`fn applyAll(chain: []const dyn AudioEffect, ...)` lowers to a slice
of `zpp.Dyn(AudioEffect_VTable)` fat pointers. Every `dyn` is visible
at the call site — there is no implicit virtual dispatch.

## extern_plugin.zpp — C-ABI plugin interface

```zig
{{#include ../../examples/extern_plugin.zpp}}
```

```text
{{#include ./output/extern_plugin.txt}}
```

`extern interface AudioPlugin { ... }` lowers to
`extern struct AudioPlugin_ABI { ... }` with `callconv(.c)` function
pointers, suitable for dlopen/dlsym plugins.

## contracts_sort.zpp — requires/ensures + where

```zig
{{#include ../../examples/contracts_sort.zpp}}
```

```text
{{#include ./output/contracts_sort.txt}}
```

`requires(isSorted(T, xs))` is checked at function entry.
`ensures(...)` would be checked on every scope exit via `defer`.
`where T: Ord` is informational at lowering but documents the
constraint.

## derive_user.zpp — comptime derive

```zig
{{#include ../../examples/derive_user.zpp}}
```

```text
{{#include ./output/derive_user.txt}}
```

`} derive(.{ Hash, Eq, Debug });` injects member methods directly:
`a.hash()`, `User.eq(a, b)`, `User.debug.format(a, w)`.

## effects_pure.zpp — effect annotations

```zig
{{#include ../../examples/effects_pure.zpp}}
```

```text
{{#include ./output/effects_pure.txt}}
```

`effects(.noalloc, .noio) fn fnv1a(...)` is sema-linted (Z0030 if it
calls anything that allocates).

## async_group.zpp — structured concurrency

```zig
{{#include ../../examples/async_group.zpp}}
```

```text
{{#include ./output/async_group.txt}}
```

`zpp.async_mod.TaskGroup` is a real concurrent executor: each
`spawn` launches an OS thread immediately and returns a typed
`*JoinHandle(T)`; `join` waits on every worker and propagates the
first error after setting the group's `CancellationToken`. Every
primitive is explicit; there is no implicit await.

## event_bus.zpp — integration showcase

The other examples each demonstrate one feature in isolation.
`event_bus.zpp` shows them composing: a `trait Handler` with two
`impl`s, a `derive(.{ Hash, Eq })` `Event` payload, an `owned struct
EventBus` scoped with `using`, a `dyn Handler` slice, and a
`requires(...)` contract on `publish`.

```zig
{{#include ../../examples/event_bus.zpp}}
```

```text
{{#include ./output/event_bus.txt}}
```
