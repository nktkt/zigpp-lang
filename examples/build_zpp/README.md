# build.zpp demo

This directory shows the thin `build.zpp` alias over `build.zig`. Running
`zpp build` here lowers `build.zpp` to a generated `build.zig` (only when
missing or stale) and then invokes `zig build`.

```sh
cd examples/build_zpp
zpp build           # lowers build.zpp -> build.zig and runs `zig build`
zig build run       # run the demo executable
```
