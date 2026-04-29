# Zig++

[![CI](https://github.com/nktkt/zigpp-lang/actions/workflows/ci.yml/badge.svg)](https://github.com/nktkt/zigpp-lang/actions/workflows/ci.yml)
[![docs](https://github.com/nktkt/zigpp-lang/actions/workflows/docs.yml/badge.svg)](https://nktkt.github.io/zigpp-lang/)
[![CodeQL](https://github.com/nktkt/zigpp-lang/actions/workflows/codeql.yml/badge.svg)](https://github.com/nktkt/zigpp-lang/actions/workflows/codeql.yml)
[![Scorecard](https://github.com/nktkt/zigpp-lang/actions/workflows/scorecard.yml/badge.svg)](https://github.com/nktkt/zigpp-lang/actions/workflows/scorecard.yml)
[![Zig 0.15+](https://img.shields.io/badge/zig-0.15%2B-orange)](https://ziglang.org/)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

📖 **Docs site**: https://nktkt.github.io/zigpp-lang/

🌐 English | [日本語](README.ja.md)

Visible high-level abstractions on top of Zig.

Zig++ is a research language layered on top of Zig 0.15+. It adds named
traits, explicit RAII via `using`, an ownership/move checker, `dyn`
dispatch, contracts, effect annotations, and `derive` — every construct
lowers to plain Zig with **no hidden allocations, no hidden control flow,
no implicit destructors, and no exceptions**. `.zpp` source compiles to
`.zig` source, which then builds with the standard `zig` toolchain.

## Status

Pre-alpha (v0.1). Compiler frontend, runtime library, CLI tools, VS Code
extension, fuzz harness, and end-to-end test rig are all in place. The
language surface is intentionally small and stable enough to write
working programs against. Expect breakage at the syntax-edge cases.

## Quick example

```zig
const std = @import("std");
const zpp = @import("zpp");

trait Greeter {
    fn greet(self) void;
}

const English = struct {
    name: []const u8,
};

impl Greeter for English {
    fn greet(self) void {
        std.debug.print("Hello, {s}!\n", .{self.name});
    }
}

fn welcome(who: impl Greeter) void {
    who.greet();
}

pub fn main() !void {
    var en = English{ .name = "Ada" };
    welcome(&en);
}
```

Run it directly:

```sh
zpp run examples/hello_trait.zpp
# Hello, Ada!
```

Or inspect the lowered Zig:

```sh
zpp lower examples/hello_trait.zpp
```

## What works today

- **3 dispatch modes** from one `impl` declaration:
  - `fn f(x: impl Trait)` → static (Zig `anytype`, monomorphized)
  - `fn f(x: dyn Trait)` → dynamic (visible `zpp.Dyn(VTable)` fat pointer)
  - `extern interface Foo { ... }` → C-ABI (`extern struct Foo_ABI` with `callconv(.c)`)
- **`using x = expr;`** — explicit RAII binder, lowers to `var x = expr; defer x.deinit();`
- **`owned struct`** — must-deinit checked by sema; missing `deinit` → diagnostic Z0010
- **`own var x`** + **`move x`** — affine ownership with use-after-move detection (Z0020)
- **`requires(cond)` / `ensures(cond)`** — runtime contracts via `zpp.contract.*`; `ensures` runs on every scope exit via `defer`
- **`effects(.noalloc)`** — sema lint that flags allocator usage in pure functions (Z0030)
- **`derive(.{ Hash, Eq, Ord, Default, Clone, Debug, Json, Iterator, Serialize, Compare, FromStr })`** — comptime helpers injected as struct methods so `a.hash()`, `User.eq(a, b)`, `a.iter()`, `a.serialize(arena)`, `User.fromStr(s, arena)`, and `User.lt(a, b)` work directly
- **`where T: Trait`** — generic constraint syntax (informational, drops at lowering)
- **End-to-end pipeline** verified: 8 example programs compile and run through `zpp run` AND `zig build e2e`
- **Fuzz-clean**: 83,000 generated/mutated inputs through the parser/sema/lowerer with zero panics, leaks, or timeouts

## Layout

```
zigpp/
  build.zig            build script (artifacts, tests, examples, e2e, fuzz)
  build.zig.zon        package manifest
  compiler/            .zpp -> .zig frontend (token, ast, parser, sema, lower, diagnostics)
  lib/                 zpp runtime library (Dyn, Owned, contracts, derive, async, traits, testing)
  tools/               zpp CLI plus fmt, lsp, doc, migrate
  examples/            8 .zpp programs covering each construct
  tests/               compile, diagnostic, snapshot, behavior, no-hidden-alloc, fuzz
  vscode/              VS Code extension (TextMate grammar + LSP client)
  README.md            this file
  MANIFESTO.md         design philosophy and rejections
  LANGUAGE.md          language spec sketch with lowering rules
  ROADMAP.md           phased roadmap
  LICENSE              MIT
```

## Build

```sh
zig build                    # build the runtime library, compiler library, and 5 CLIs
zig build test               # run all unit + integration tests
zig build check              # parse + sema every example without codegen
zig build examples           # lower every .zpp example to .zig (no execution)
zig build e2e                # lower, build, and RUN every .zpp example
zig build fuzz               # opt-in fuzzer; ZPP_FUZZ_ITERS=N --seed=N for tuning
zig build run -- help        # invoke the zpp CLI
```

The CLIs install under `zig-out/bin/`:

```
zpp            main driver: build, run, lower, fmt, check, doc, migrate, lsp
zpp-fmt        formatter
zpp-lsp        LSP server (stdin/stdout JSON-RPC; used by the VS Code extension)
zpp-doc        markdown doc generator
zpp-migrate    .zig -> .zpp migration helper
```

## Start a new project

The CLI ships a template generator:

```sh
zpp init my-project
cd my-project
zig fetch --save git+https://github.com/nktkt/zigpp-lang
zig build run
```

This scaffolds `build.zig`, `build.zig.zon`, `src/main.zpp`, a
`.gitignore`, and a starter README — enough to lower, build, and run
without copy-pasting the boilerplate.

## Use as a Zig dependency

To consume the `zpp` runtime library from your own Zig project:

```sh
zig fetch --save git+https://github.com/nktkt/zigpp-lang
```

Then in your `build.zig`:

```zig
const zpp_dep = b.dependency("zigpp", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zpp", zpp_dep.module("zpp"));
```

The runtime exposes `Dyn`, `Owned`, `ArenaScope`, `contract.requires`,
`derive.Hash/Eq/Debug/Json`, and a `std.Thread`-backed concurrent
`TaskGroup` with typed `JoinHandle(T)`. The compiler frontend is also
importable as `zpp_compiler` if you need to embed the lowering pipeline
programmatically.

## Editor support

Install the VS Code extension from the `vscode/` directory:

```sh
cd vscode && npm install && npm run compile
# Then F5 in VS Code, or package with `vsce package` and install the .vsix
```

The extension provides syntax highlighting (TextMate grammar), diagnostics
via `zpp-lsp`, and `Zig++: Run File` / `Zig++: Show Lowered Zig` commands.

## Philosophy

- **No hidden allocations.** Every allocator is a parameter.
- **No hidden control flow.** No exceptions, no implicit destructors, no operator overloading in MVP.
- **No hidden dispatch.** Static calls are static; dynamic dispatch goes through a visible `dyn Trait`.
- **No hidden lifetime.** RAII binders are spelled `using`; ownership is spelled `own`/`move`.
- **No hidden cost.** Effects are annotations the compiler can check or lint.

See [MANIFESTO.md](MANIFESTO.md) for the long form and [LANGUAGE.md](LANGUAGE.md)
for syntax and lowering rules.

## Roadmap

Phased. See [ROADMAP.md](ROADMAP.md). Today the core (Phases 0–4) is
working end-to-end; Phase 5 (effect inference) and Phase 7 (real
concurrency) remain.

## Contributing

This is a research project — feedback, issues, and PRs are welcome. The
fuzz harness (`zig build fuzz`) is a good way to find regressions; if
you find a crash, the input gets shrunk and saved under
`tests/fuzz/crashes/`.

## License

MIT. See [LICENSE](LICENSE).
