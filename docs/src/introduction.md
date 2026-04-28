# Introduction

**Zig++** is a research language layered on top of Zig 0.15+. It adds
named traits, explicit RAII via `using`, an ownership/move checker,
`dyn` dispatch, contracts, effect annotations, and `derive` — every
construct lowers to plain Zig with **no hidden allocations, no hidden
control flow, no implicit destructors, and no exceptions**.

`.zpp` source compiles to `.zig` source, which then builds with the
standard `zig` toolchain.

## Why another language

Most "C++ for X" projects add features by accretion. Zig++ takes the
opposite path: every construct must be _visible_ at the call site,
including the things C++ went out of its way to hide.

| You want                         | Zig++ syntax                          |
| -------------------------------- | ------------------------------------- |
| Static dispatch (template-style) | `fn f(x: impl Trait)`                 |
| Dynamic dispatch (virtual)       | `fn f(x: dyn Trait)`                  |
| Stable ABI (extern "C")          | `extern interface Foo { ... }`        |
| RAII                             | `using x = expr;`                     |
| Owned value with destructor      | `owned struct S { ... }`              |
| Move semantics                   | `own var x` / `move x`                |
| Pre/post-conditions              | `requires(cond) ensures(cond)`        |
| Pure-function lint               | `effects(.noalloc)`                   |
| Auto-derive Hash/Eq/Debug/Json   | `} derive(.{ Hash, Eq, Debug, Json });` |

If a feature breaks the visibility doctrine, it doesn't ship. See the
[Manifesto](./manifesto.md) for the full rejection list.

## Quick start

```sh
git clone https://github.com/nktkt/zigpp-lang
cd zigpp-lang
zig build
./zig-out/bin/zpp run examples/hello_trait.zpp
# Hello, Ada!
```

## What this site contains

- [Manifesto](./manifesto.md) — the design philosophy and what we
  refuse to add.
- [Roadmap](./roadmap.md) — phased development plan.
- [Language spec](./language.md) — syntax, semantics, lowering rules.
- [Examples](./examples.md) — annotated walkthroughs of the in-tree
  programs.
- [Contributing](./contributing.md) — how to file bugs, propose
  features, and submit PRs.
- [Changelog](./changelog.md) — what changed when.

## Status

Pre-alpha (v0.1). The compiler is small (~3K lines) and intentionally
textual — the lowered Zig stays readable. Use it for experiments, not
production.

The CI matrix runs on Linux, macOS, and Windows; a 2,000-iteration
fuzz smoke test runs on every push.
