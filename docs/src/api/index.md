# API reference (auto-generated)

The pages in this section are generated from the in-tree `examples/`
directory by running `zpp doc examples -o docs/src/api`. Each page
extracts the trait, owned struct, extern interface, and top-level fn
declarations from one `.zpp` file.

To regenerate after editing examples:

```sh
zig build
./zig-out/bin/zpp-doc examples -o docs/src/api
```

## Index

- [hello_trait](./hello_trait.md) — `trait Greeter` + impl + static dispatch
- [owned_file](./owned_file.md) — `owned struct LogFile` + `using` RAII
- [dyn_plugin](./dyn_plugin.md) — `trait AudioEffect` + `dyn` slice
- [extern_plugin](./extern_plugin.md) — `extern interface AudioPlugin`
- [contracts_sort](./contracts_sort.md) — `requires` / `ensures` + `where`
- [derive_user](./derive_user.md) — `derive(.{ Hash, Eq, Debug })`
- [effects_pure](./effects_pure.md) — `effects(.noalloc, .noio)` annotations
- [async_group](./async_group.md) — `zpp.async_mod.TaskGroup`
