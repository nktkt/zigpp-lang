# ZPP_PROJECT_NAME

A new Zig++ project, scaffolded with `zpp init`.

## Build

```sh
# First time only: pin the zigpp dependency hash.
zig fetch --save git+https://github.com/nktkt/zigpp-lang

# Build and run.
zig build run
```

## Layout

```
ZPP_PROJECT_NAME/
  build.zig            build script (lowers .zpp -> .zig at build time)
  build.zig.zon        package manifest (zigpp dependency)
  src/
    main.zpp          your program
  README.md           this file
```

## Next steps

- Edit `src/main.zpp` — it's a tiny `trait` + `impl` example.
- Read the [Zig++ docs](https://nktkt.github.io/zigpp-lang/).
- File issues at https://github.com/nktkt/zigpp-lang/issues if anything
  breaks.
