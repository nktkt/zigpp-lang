# Contributing to Zig++

🌐 English | [日本語](CONTRIBUTING.ja.md)


Thanks for your interest. Zig++ is a research project; the focus is on
keeping the language surface small and the implementation honest about
costs. This guide covers the basics for contributing code, bug reports,
and proposals.

## Quick start

```sh
git clone https://github.com/nktkt/zigpp-lang
cd zigpp-lang

zig build              # build runtime, compiler, and 5 CLIs
zig build test         # run unit + integration tests (~140 tests)
zig build e2e          # lower, build, and RUN every example
ZPP_FUZZ_ITERS=1000 zig build fuzz   # run the fuzzer (opt-in)
```

Required: **Zig 0.15.x** (see CI for the exact pinned version).

## Project layout

| Directory       | Purpose                                                  |
| --------------- | -------------------------------------------------------- |
| `compiler/`     | `.zpp` → `.zig` frontend (token, ast, parser, sema, lower, diagnostics) |
| `lib/`          | `zpp` runtime: `Dyn`, `Owned`, contracts, derive, async  |
| `tools/`        | `zpp` CLI plus `fmt`, `lsp`, `doc`, `migrate`            |
| `examples/`     | 8 `.zpp` programs covering each construct                |
| `tests/`        | compile, diagnostic, snapshot, behavior, no-hidden-alloc, fuzz |
| `vscode/`       | VS Code extension (TextMate grammar + LSP client)        |

## Doctrine — what changes get accepted

Zig++ exists to add **visible** abstractions on top of Zig. Before
proposing a feature, check the rejections list in
[MANIFESTO.md](MANIFESTO.md). The doctrine in one line:

> **No hidden allocations, no hidden control flow, no implicit
> destructors, no exceptions, no operator overloading in MVP.**

Features that introduce hidden costs are unlikely to be accepted, even
if they ship in other languages.

## Workflow

1. **Open an issue first** for non-trivial changes. Bug reports are
   always welcome without prior discussion.
2. **Branch from `main`**; keep the branch focused on one concern.
3. **Run the full local suite** before pushing:
   ```sh
   zig build test
   zig build check
   zig build e2e
   ```
4. **CI must be green.** Push triggers ubuntu + macos + windows builds
   plus a 2,000-iter fuzz smoke run.
5. **Open a PR** from your branch to `main`. Reference the issue if
   there is one.

## Bug reports

Use the [Bug report](.github/ISSUE_TEMPLATE/bug_report.md) template.
For compiler crashes, the fuzz harness already shrinks inputs — if you
have a small `.zpp` that crashes the compiler, copy it into the issue.

If `zig build fuzz` produces files under `tests/fuzz/crashes/`,
attaching one is the gold standard repro.

## Coding standards

- **Zig style**: `snake_case` for vars/fns, `PascalCase` for types,
  4-space indent. Run `zig fmt` before committing.
- **Allocator-first**: any function that may allocate takes an explicit
  `Allocator` parameter. No `std.heap.page_allocator` in non-main code.
- **No comments** except where explaining a non-obvious invariant or a
  workaround. Identifier names should self-document.
- **Tests** for new code: add at minimum one test alongside the change
  (`compiler/` has inline `test "..."` blocks; `tests/` is for
  integration tests).
- **Generated `.zig` must stay readable**. The lowering rule is:
  whatever a programmer reads in `.zpp` should be obvious in the
  emitted `.zig`. No clever trickery.

## Diagnostic codes

If you add a new sema check, allocate a code in
`compiler/diagnostics.zig` (`Z<NNNN>_<short_name>`), and include a
`hint:` line in the `hint(code)` table. The hint is what users see when
their code triggers the diagnostic; spend a minute on it.

## Fuzzing

The fuzz harness (`tests/fuzz/`) generates synthetic `.zpp` plus
mutates the existing examples. Run it before submitting changes that
touch the parser, sema, or lowerer:

```sh
ZPP_FUZZ_ITERS=10000 zig build fuzz
```

If you find a crash, leave the input under `tests/fuzz/crashes/`
(gitignored) and open an issue.

## Commit messages

This repo uses [Conventional Commits](https://www.conventionalcommits.org/)
so that [release-please](https://github.com/googleapis/release-please)
can compute the next version and assemble the changelog automatically.
Use one of these prefixes:

| Prefix      | Meaning                                       | Bumps     |
| ----------- | --------------------------------------------- | --------- |
| `feat:`     | new user-visible feature                      | minor     |
| `fix:`      | bug fix                                       | patch     |
| `perf:`     | performance improvement                       | patch     |
| `refactor:` | internal refactor, no behaviour change        | none      |
| `docs:`     | docs only                                     | none      |
| `ci:`       | CI / workflow change                          | none      |
| `build:`    | build script change                           | none      |
| `test:`     | test-only change                              | none      |
| `chore:`    | repo housekeeping                             | none      |

Add `!` after the prefix or a `BREAKING CHANGE:` footer to signal a
major bump (e.g. `feat!: drop using` or `feat: ...` plus
`BREAKING CHANGE: removed using`).

## Releases

Releases are managed by [release-please](https://github.com/googleapis/release-please).
On every push to `main`, the bot opens or updates a "release PR" that
collects the conventional-commit titles into a `CHANGELOG.md` entry
and bumps the version in `.github/.release-please-manifest.json`.
Merging the release PR cuts a new tag (`vX.Y.Z`) and publishes a
GitHub release. Maintainers should not push tags by hand.

## License

By contributing, you agree your contribution is licensed under MIT (see
[LICENSE](LICENSE)). Include a `Co-Authored-By:` trailer in commits if
you used assistance.
