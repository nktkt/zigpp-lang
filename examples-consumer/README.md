# examples-consumer

A standalone Zig project that depends on Zig++ as a regular Zig
package. Demonstrates the **package-manager flow** end-to-end: a
third-party project pulls in Zig++ via `zig fetch --save`, lowers a
single `.zpp` source at build time, and runs the result.

This is the same flow that `zpp init` scaffolds for new users; it
exists in-tree so the repository's own CI can verify the consumer
story doesn't break.

## Layout

```
examples-consumer/
  build.zig            invokes zpp lower at build time
  build.zig.zon        depends on the parent zigpp/ via a relative path
  src/
    main.zpp           a minimal program using the runtime
  README.md
```

## Run it

From this directory:

```sh
zig build run
```

Expected output:

```
hello from a downstream Zig++ consumer
event hash = abc123...
```

## How the dependency is wired

Outside the in-tree case, you would run:

```sh
zig fetch --save git+https://github.com/nktkt/zigpp-lang
```

In this in-tree consumer we use a **relative path** dependency so the
project follows the parent automatically:

```zon
.dependencies = .{
    .zigpp = .{
        .path = "..",
    },
},
```

The `build.zig` then asks for the `zpp` executable from the dependency
and uses it to lower `src/main.zpp` at build time:

```zig
const zpp_dep = b.dependency("zigpp", .{ .target = target, .optimize = optimize });
const lower = b.addRunArtifact(zpp_dep.artifact("zpp"));
lower.addArg("lower");
lower.addArg("src/main.zpp");
const lowered = lower.captureStdOut();
// ...wrap in addWriteFiles to give it a stable name, then build as exe.
```

## When this matters

If you maintain a Zig++ project, your `build.zig` will look essentially
identical to the one here. If `zig build run` ever stops working in
this consumer, that means we broke a downstream-visible API and the CI
will tell us before the next release.
