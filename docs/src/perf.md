# Performance baseline

These numbers come from `zig build bench` (ReleaseFast). The harness
generates synthetic `.zpp` files of increasing size, each declaration
combining a `trait`, a `struct`, an `impl`, and a `dyn`-using
function — so the parser, sema, and lowerer all do meaningful work.

## Latest baseline

Recorded on the maintainer's laptop (Apple Silicon, Zig 0.15.2).
Numbers vary across machines but the shape (flat throughput from 100
decls upward) is the load-bearing claim — the compiler does not
quadratically degrade with input size.

| decls | input bytes | output bytes | iters | total ms | µs / iter | bytes/sec |
|------:|------------:|-------------:|------:|---------:|----------:|----------:|
|    10 |        2687 |         7051 |   200 |   229.21 |    1146.0 |   2344626 |
|   100 |       27257 |        72481 |    50 |   773.49 |   15469.7 |   1761956 |
|  1000 |      281957 |       755581 |    10 |  1755.51 |  175551.1 |   1606125 |
|  5000 |     1453957 |      3919581 |     5 |  4607.87 |  921574.8 |   1577687 |
| 10000 |     2918957 |      7874581 |     3 |  5393.99 | 1797995.3 |   1623451 |

## Reading the table

- **bytes/sec** is throughput against *input* size. Output is ~2.6x
  larger than input because every `trait` emits a vtable struct + a
  Dyn alias, every `impl` emits a body fn + a thunk + a vtable
  instance, and every `dyn`-using fn references the vtable on each
  call.
- The 10-decl row pays fixed overhead (allocator setup, header
  emission). Above 100 decls, throughput is flat — the lowering
  pipeline is essentially linear.
- These are not microsecond-level numbers because the lowerer is
  still textual: `compileToString` allocates a fresh `ArrayList(u8)`,
  copies each token's slice, and reformats. A future pass that emits
  directly into a writer (no intermediate copies) should reduce
  per-iter time by 2-3x.

## How to reproduce

```sh
zig build bench
```

The bench step runs in `ReleaseFast` regardless of the top-level
optimize mode. To compare a change:

```sh
git stash
zig build bench > /tmp/before.txt
git stash pop
zig build bench > /tmp/after.txt
diff /tmp/before.txt /tmp/after.txt
```

## What is *not* measured

- `zig build` itself (Zig's own compilation of the lowered output).
- LSP latency. The LSP scaffold uses the same pipeline but adds
  JSON-RPC framing and doc-store overhead; expect ~5x for round-trip.
- Memory peak. The arena allocator inside the lowerer is reset per
  `compileToString` call, so peak RSS scales with the largest file.

## Regression tracking

There is no automated perf regression check yet. If a change touches
`compiler/parser.zig`, `compiler/sema.zig`, or
`compiler/lower_to_zig.zig`, run `zig build bench` before and after
and call out the delta in the PR description.
