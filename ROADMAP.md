# Zig++ Roadmap

Phased delivery. Each phase has an entry criterion (what must be true to
start) and an exit criterion (what must be true to call the phase done).
Estimates are calendar weeks of focused work, not staffed schedules.

## Status as of v0.2

Phases 0-7 are substantially complete. The remaining Phase 6 item (`zpp` dependency resolution via build.zig.zon semver) and Zig 0.17 async I/O integration in Phase 7 are tracked separately.

| Phase | Status | Notes |
|-------|--------|-------|
| Phase 0 — Philosophy & Compatibility   | ✅ done    | exit criteria met |
| Phase 1 — MVP Frontend                  | ✅ done    | every example lowers |
| Phase 2 — Trait System                  | ✅ done    | structural opt-in, Writer trait, default methods |
| Phase 3 — Explicit RAII & Ownership     | ✅ done    | Z0010/Z0011/Z0020/Z0021 firing |
| Phase 4 — dyn Trait & Plugin ABI        | ✅ done    | extern_plugin example loads |
| Phase 5 — Effect System                 | ✅ done    | 5 axes (alloc, io, panic, async, custom) with paired `no*` denials |
| Phase 6 — Package, Build, Docs          | ⚠️ partial | build.zpp + HTML + snapshot gate done; semver dep resolution open |
| Phase 7 — Concurrency                   | ✅ done    | TaskGroup + cancellation; Zig 0.17 I/O migration pending upstream |
| Phase 8 — Stabilization (1.0)           | ⏳ not started | next milestone after Phase 6 closure |

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

**Exit criteria met (v0.2):**
- [x] Named, nominal traits via `trait Foo { ... }`
- [x] `where T: Trait` clauses on generic functions
- [x] `impl Trait` parameter form (monomorphic)
- [x] Structural opt-in via `trait Foo : structural`
- [x] Generic Iterator (via `derive(.Iterator)`), Hash (via `derive(.Hash)`), Writer (in `lib/writer.zig`)
- [x] Trait method default bodies (bonus, not in original Phase 2 spec)
- [x] Diagnostics: Z0001, Z0002, Z0040

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

**Exit criteria met (v0.2):**
- [x] `effects(...)` parsing
- [x] Lint pass for `.noalloc`, `.noio`, `.nopanic`, `.nocustom`
- [x] Effect inference (intersection of callees' effects)
- [x] Diagnostic Z0030 with named-source citation
- [x] `.noasync` axis (bonus, added in round 6)

## Phase 6 — Package, Build, Docs

- `build.zpp` (a thin alias over `build.zig`) for projects that want it.
- Package manifest extensions for `zpp` dependency resolution (semver via `build.zig.zon`).
- `zpp doc` produces browsable HTML in addition to Markdown.
- Stable lowering snapshots; CI runs `ZPP_UPDATE_SNAPSHOTS=0` and refuses drift.

Entry: Phase 5 done. Exit: a small external project depends on Zig++ via
the manifest and builds with one command.

Estimate: 2 weeks.

**Exit criteria met (v0.2):**
- [x] `build.zpp` thin alias over `build.zig`
- [x] `zpp doc` produces browsable HTML in addition to Markdown
- [x] Stable lowering snapshots; CI runs `ZPP_UPDATE_SNAPSHOTS=0` and refuses drift

**Open:**
- [ ] Package manifest extensions for `zpp` dependency resolution (semver via `build.zig.zon`)

## Phase 7 — Concurrency

- `TaskGroup` API on top of Zig 0.16+ I/O.
- Structured-concurrency rules: no task outlives its group.
- `.noasync` effect interacts with the I/O model.
- Cancellation propagation through groups.

Entry: Phase 6 done and Zig 0.16 I/O API is stable enough to depend on.
Exit: `examples/async_group.zpp` runs N concurrent tasks, joins, and
propagates the first error cleanly.

Estimate: 4 weeks.

**Exit criteria met (v0.2):**
- [x] `TaskGroup` API
- [x] Structured-concurrency rules (no task outlives its group)
- [x] `.noasync` effect interacts with the I/O model (round 6 inference)
- [x] Cancellation propagation through groups
- [x] Note: full Zig 0.17 async I/O integration pending upstream

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
