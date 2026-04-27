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

| File                  | Teaches                                                      |
| --------------------- | ------------------------------------------------------------ |
| `hello_trait.zpp`     | `trait` / `impl Trait for T` / static `impl Trait` dispatch  |
| `owned_file.zpp`      | `owned struct`, `using v = expr` RAII                        |
| `dyn_plugin.zpp`      | `dyn Trait` visible-vtable dynamic dispatch                  |
| `async_group.zpp`     | `zpp.async_mod.TaskGroup` structured concurrency             |
| `contracts_sort.zpp`  | `where T: Ord`, `requires`, `ensures` on a generic           |
| `derive_user.zpp`     | `derive(.{ Hash, Debug, Eq })` on a struct                   |
| `effects_pure.zpp`    | `effects(.noalloc, .noio)` and `effects(.alloc, .io)`        |
| `extern_plugin.zpp`   | `extern interface` for a stable C-compatible plugin ABI      |

## Reading order

1. `hello_trait.zpp` — the smallest possible trait + impl.
2. `dyn_plugin.zpp` — same idea, but with `dyn` so the vtable is visible.
3. `owned_file.zpp` — explicit RAII via `using` and `owned struct`.
4. `derive_user.zpp` — comptime-derived trait impls.
5. `contracts_sort.zpp` — `where`, `requires`, `ensures`.
6. `effects_pure.zpp` — capability annotations on functions.
7. `async_group.zpp` — explicit `spawn` / `join` over a `TaskGroup`.
8. `extern_plugin.zpp` — long-lived ABI via `extern interface`.
