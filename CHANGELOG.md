# Changelog

All notable changes to Zig++ are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- GitHub Pages site with mdBook for the spec, manifesto, and roadmap.
- Dependabot weekly updates for GitHub Actions.
- CONTRIBUTING.md, issue templates, PR template.
- Windows CI matrix entry (windows-latest x86_64).
- `.gitattributes` enforcing LF line endings repo-wide.

### Fixed
- `mentionsIdent` no longer false-positives on identifiers inside
  string literals, char literals, or `//` comments — fixes Z0020 firing
  when a debug print mentions a moved binding.
- `cmdCheck` probes via `openDir` before `statFile` so directory paths
  work on Windows (where `statFile` returns `error.IsDir`).
- Snapshot tests strip `\r` before comparing so they pass on Windows
  even without `.gitattributes`.
- `addTestsForTree` now excludes `lowering\snapshots` and
  `lowering\inputs` (Windows path separator) in addition to the `/`
  forms.
- Dropped dead pointer-arithmetic computation of `sig_end` in
  `parser.zig` (immediately overwritten — surfaced by fuzz audit).

## [0.1.0] - 2026-04-27

First tagged release. Pre-alpha.

### Added
- **Compiler frontend** (`compiler/`): token, ast, parser, sema,
  lower_to_zig, diagnostics. Lowers `.zpp` to readable `.zig`.
- **Runtime library** (`lib/`): `Dyn(VTable)`, `Owned(T)`, `ArenaScope`,
  `DeinitGuard`, contracts, derive helpers (Hash/Eq/Debug/Json), async
  scaffolding (TaskGroup), testing utilities.
- **CLI tools** (`tools/`): `zpp` driver plus `zpp-fmt`, `zpp-lsp`,
  `zpp-doc`, `zpp-migrate`.
- **Three dispatch modes** from one `impl` declaration:
  - `fn f(x: impl Trait)` → static (Zig `anytype`)
  - `fn f(x: dyn Trait)` → dynamic (visible `zpp.Dyn(VTable)`)
  - `extern interface Foo { ... }` → C-ABI (`extern struct Foo_ABI`
    with `callconv(.c)`)
- **`using x = expr;`** explicit RAII binder.
- **`owned struct`** with sema-checked `deinit` requirement (Z0010).
- **`own var`** + **`move x`** with use-after-move detection (Z0020).
- **`requires(cond)` / `ensures(cond)`** runtime contracts. `ensures`
  runs on every scope exit via `defer`.
- **`effects(.noalloc)`** sema lint (Z0030).
- **`derive(.{ Hash, Eq, Debug, Json })`** comptime helpers injected as
  member methods so `a.hash()` and `User.eq(a, b)` work directly.
- **8 example programs** (`examples/`) covering each construct.
- **End-to-end test harness** (`zig build e2e`) lowers and runs every
  example.
- **Fuzz harness** (`zig build fuzz`) — 83,000 inputs through
  parser/sema/lowerer with zero panics, leaks, or timeouts.
- **VS Code extension** (`vscode/`) with TextMate grammar covering all
  13 Zig++ extension keywords plus an LSP client.
- **Diagnostic hints**: every error code carries a `hint:` line with a
  suggested fix.
- **GitHub Actions CI** for ubuntu-latest and macos-latest.
- **MANIFESTO.md / LANGUAGE.md / ROADMAP.md** design docs.

[Unreleased]: https://github.com/nktkt/zigpp-lang/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/nktkt/zigpp-lang/releases/tag/v0.1.0
