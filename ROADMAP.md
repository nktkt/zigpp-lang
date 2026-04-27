# Zig++ Roadmap

Phased delivery. Each phase has an entry criterion (what must be true to
start) and an exit criterion (what must be true to call the phase done).
Estimates are calendar weeks of focused work, not staffed schedules.

## Phase 0 — Philosophy and Compatibility

- Manifesto and language sketch checked in.
- Lowering rules documented for every Phase 1 construct.
- `tests/no_hidden_alloc/audit.zig` passes against current `lib/`, `compiler/`, `tools/`.
- Build script produces all artifacts; `zig build test` runs.

Entry: nothing. This is the start. Exit: `zig build test` is green and
MANIFESTO + LANGUAGE are reviewed.

Estimate: 1 week.

## Phase 1 — MVP Frontend

- Lexer covers all of Zig's tokens plus the new keywords.
- Parser produces an AST with explicit nodes for `trait`, `impl`, `using`, `dyn`, `own`, `move`, `effects`, `derive`, `extern interface`.
- Lowering pass turns each new node into the Zig-text form documented in LANGUAGE.md.
- CLI subcommands `lower`, `check`, `build`, `run` work end-to-end.

Entry: Phase 0 done. Exit: every `examples/*.zpp` lowers to compilable
Zig and `zig build examples` succeeds.

Estimate: 4 weeks.

## Phase 2 — Trait System

- Named, nominal traits with explicit `impl ... for ...` blocks.
- `where` clauses on generic functions and impls.
- `impl Trait` parameter form (monomorphic).
- Structural-vs-nominal decision: nominal by default, opt-in structural via `trait Foo : structural`.
- Diagnostics: Z0001, Z0002.

Entry: Phase 1 done. Exit: a generic `Iterator` trait, a `Hash` trait,
and a `Writer` trait are usable from `lib/`, with concrete impls.

Estimate: 3 weeks.

## Phase 3 — Explicit RAII and Ownership

- `using` lowering with deinit-shape check.
- `owned struct` with deinit requirement (Z0010, Z0011).
- `own var` + `move` with intra-procedural use-after-move checker (Z0020).
- Doc note on what we do *not* check (cross-function ownership).

Entry: Phase 2 done. Exit: `examples/owned_file.zpp` builds, runs, leaks
zero bytes under `std.testing.allocator`, and Z0020 fires on a hand-written
counter-example.

Estimate: 3 weeks.

## Phase 4 — `dyn Trait` and Plugin ABI

- `dyn Trait` fat pointer construction at call sites.
- `dyn x` expression form for explicit boxing.
- `extern interface` for C-ABI vtables.
- A worked example loading a `.so` / `.dylib` / `.dll` plugin.

Entry: Phase 3 done. Exit: `examples/dyn_plugin.zpp` and a separate
plugin crate compile, link, and exchange a `Plugin` vtable across a
dynamic-library boundary.

Estimate: 3 weeks.

## Phase 5 — Effect System

- `effects(...)` parsing.
- Lint pass that flags allocator calls under `.noalloc`, `@panic` under `.nopanic`, etc.
- Inference: a function with no body annotation gets the intersection of its callees' effects.
- Diagnostic Z0030 with named-source citation.

Entry: Phase 4 done. Exit: at least three `lib/` functions carry explicit
`effects` annotations and the audit test extends to forbidden-call detection.

Estimate: 3 weeks.

## Phase 6 — Package, Build, Docs

- `build.zpp` (a thin alias over `build.zig`) for projects that want it.
- Package manifest extensions for `zpp` dependency resolution (semver via `build.zig.zon`).
- `zpp doc` produces browsable HTML in addition to Markdown.
- Stable lowering snapshots; CI runs `ZPP_UPDATE_SNAPSHOTS=0` and refuses drift.

Entry: Phase 5 done. Exit: a small external project depends on Zig++ via
the manifest and builds with one command.

Estimate: 2 weeks.

## Phase 7 — Concurrency

- `TaskGroup` API on top of Zig 0.16+ I/O.
- Structured-concurrency rules: no task outlives its group.
- `.noasync` effect interacts with the I/O model.
- Cancellation propagation through groups.

Entry: Phase 6 done and Zig 0.16 I/O API is stable enough to depend on.
Exit: `examples/async_group.zpp` runs N concurrent tasks, joins, and
propagates the first error cleanly.

Estimate: 4 weeks.

## Phase 8 — Stabilization (1.0)

- Freeze syntax for every construct in LANGUAGE.md.
- Bump `build.zig.zon` to `1.0.0`.
- Publish a migration guide from the last 0.x to 1.0.
- Promise lowering stability for Zig 0.16.x; future Zig versions get a new branch.

Entry: All earlier phases done; no open Z00xx triage. Exit: 1.0 tag and a
30-day quiet period during which only doc fixes land on `main`.

Estimate: 2 weeks plus the 30-day quiet period.

---

Total estimate to 1.0: roughly 25 weeks of focused work, plus the
stabilization quiet period. Phases overlap in practice; Phase 5 (effects)
and Phase 7 (concurrency) can run partly in parallel once Phase 4 lands.
