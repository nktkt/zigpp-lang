# Zig++ examples

Each `.zpp` file in this directory is a small, runnable program that exercises
one cluster of Zig++ features. Source is lowered to `.zig` by the Zig++
compiler, then handed to the standard `zig` toolchain.

## Run

```sh
zpp run examples/hello_trait.zpp
```

To inspect the lowered Zig without running:

```sh
zpp lower examples/hello_trait.zpp -o /tmp/hello_trait.zig
```

## Index

| File                          | Teaches                                                                |
| ----------------------------- | ---------------------------------------------------------------------- |
| `hello_trait.zpp`             | `trait` / `impl Trait for T` / static `impl Trait` dispatch            |
| `dyn_plugin.zpp`              | `dyn Trait` visible-vtable dynamic dispatch                            |
| `owned_file.zpp`              | `owned struct` and `using v = expr` RAII                               |
| `borrow_check.zpp`            | multi-borrow + block-scope-aware borrow checker (Z0021)                |
| `derive_user.zpp`             | `derive(.{ Hash, Eq, Ord, Default, Iterator, Serialize, ... })`        |
| `contracts_sort.zpp`          | `where T: Ord`, `requires`, `ensures` on a generic                     |
| `effects_pure.zpp`            | `effects(.noalloc, .noio)` capability annotations                      |
| `effects_of.zpp`              | `@effectsOf(f)` exposing an inferred effect set at comptime            |
| `effects_nopanic_demo.zpp`    | `effects(.nopanic)` and panic-site inference                           |
| `effects_noasync.zpp`         | `effects(.noasync)` enforcement on the I/O suspension axis             |
| `async_group.zpp`             | `zpp.async_mod.TaskGroup` structured concurrency (`spawn` / `join`)    |
| `structural_advanced.zpp`     | structural traits and multi-parameter trait dispatch                   |
| `event_bus.zpp`               | integration showcase — traits, `dyn`, `owned`, `derive`, contracts     |
| `writer_buffered.zpp`         | `Writer` trait stack: `FileWriter` + `BufferedWriter`                  |
| `extern_plugin.zpp`           | `extern interface` for a stable C-compatible plugin ABI                |
| `multi_file/`                 | cross-file `.zpp` imports through `@import` + trait dispatch           |
| `multi_file_pub/`             | public traits and `dyn` dispatch across modules                        |
| `build_zpp/`                  | `build.zpp` thin alias auto-lowering to `build.zig`                    |
| `cli/`                        | end-to-end CLI program composing trait / `dyn` / `derive` / `owned`    |

## Reading order

1. `hello_trait.zpp` — the smallest possible trait + impl.
2. `dyn_plugin.zpp` — same idea, but with `dyn` so the vtable is visible.
3. `owned_file.zpp` — explicit RAII via `using` and `owned struct`.
4. `borrow_check.zpp` — borrow / move interactions and Z0021.
5. `derive_user.zpp` — comptime-derived trait impls.
6. `contracts_sort.zpp` — `where`, `requires`, `ensures`.
7. `effects_pure.zpp` → `effects_of.zpp` → `effects_nopanic_demo.zpp` → `effects_noasync.zpp` — the four effect axes and `@effectsOf`.
8. `async_group.zpp` — explicit `spawn` / `join` over a `TaskGroup`.
9. `structural_advanced.zpp` — structural traits and multi-parameter dispatch.
10. `event_bus.zpp` — integration: every construct composing in one program.
11. `writer_buffered.zpp` — the `Writer` trait stack from `lib/`.
12. `extern_plugin.zpp` — long-lived ABI via `extern interface`.
13. `multi_file/` and `multi_file_pub/` — cross-file imports.
14. `build_zpp/` — `build.zpp` thin alias.
15. `cli/` — feature-complete CLI program.
