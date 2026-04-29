# Changelog

All notable changes to Zig++ are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.13](https://github.com/nktkt/zigpp-lang/compare/v0.1.12...v0.1.13) (2026-04-29)


### Features

* vscode explain command + ci bench job ([cae5bb8](https://github.com/nktkt/zigpp-lang/commit/cae5bb8bd245ec411b5630df2942cde903e3a818))

## [0.1.12](https://github.com/nktkt/zigpp-lang/compare/v0.1.11...v0.1.12) (2026-04-29)


### Features

* multi-file e2e — examples/multi_file/ + zig build multi-e2e ([ac258e4](https://github.com/nktkt/zigpp-lang/commit/ac258e4335c24af99e250b50a112c82046251d37))

## [0.1.11](https://github.com/nktkt/zigpp-lang/compare/v0.1.10...v0.1.11) (2026-04-29)


### Features

* LSP hover for diagnostics + downstream consumer demo ([ef8df62](https://github.com/nktkt/zigpp-lang/commit/ef8df62a43e30ce43ae114bdf67e181163938c5d))


### CI

* fix examples-consumer step to capture stdout cleanly ([4bd651f](https://github.com/nktkt/zigpp-lang/commit/4bd651f287a9eaf6e3e3b51061d03b5f7b769962))
* merge stderr in windows consumer step ([36e8cb5](https://github.com/nktkt/zigpp-lang/commit/36e8cb53a08210ec7e8cc09c85f9982112746443))

## [0.1.10](https://github.com/nktkt/zigpp-lang/compare/v0.1.9...v0.1.10) (2026-04-29)


### Features

* multi-file imports + zpp explain command ([46c2aee](https://github.com/nktkt/zigpp-lang/commit/46c2aee5746ebf396ca1f019a3dfb420189f991a))

## [0.1.9](https://github.com/nktkt/zigpp-lang/compare/v0.1.8...v0.1.9) (2026-04-28)


### Features

* **docs:** 10-minute tutorial; ci tests zpp init end-to-end ([835023d](https://github.com/nktkt/zigpp-lang/commit/835023d28c5189c9600228f0783006c7d54d7459))

## [0.1.8](https://github.com/nktkt/zigpp-lang/compare/v0.1.7...v0.1.8) (2026-04-28)


### Features

* zpp init scaffold + derive Clone/Default/Ord ([d70f22c](https://github.com/nktkt/zigpp-lang/commit/d70f22c622701867ca25649cf58bc909eddf5a30))

## [0.1.7](https://github.com/nktkt/zigpp-lang/compare/v0.1.6...v0.1.7) (2026-04-28)


### Features

* add bench harness, `zig build all`, and v0.2 design notes ([3b8859f](https://github.com/nktkt/zigpp-lang/commit/3b8859fa4203257fccf7650ac2780615363971b9))

## [0.1.6](https://github.com/nktkt/zigpp-lang/compare/v0.1.5...v0.1.6) (2026-04-28)


### Features

* Japanese localization + integration example "event_bus" ([9bdde76](https://github.com/nktkt/zigpp-lang/commit/9bdde76a1707f8ab1b1442feff576252a2eb0b7d))

## [0.1.5](https://github.com/nktkt/zigpp-lang/compare/v0.1.4...v0.1.5) (2026-04-28)


### Documentation

* embed actual example outputs and auto-regenerate in CI ([57786b4](https://github.com/nktkt/zigpp-lang/commit/57786b4e972eef1de87e1174a1ed520dc722d9cc))

## [0.1.4](https://github.com/nktkt/zigpp-lang/compare/v0.1.3...v0.1.4) (2026-04-28)


### Documentation

* auto-generate API reference from examples via zpp doc ([ffc92cb](https://github.com/nktkt/zigpp-lang/commit/ffc92cb1915718b5c4afc4998967c735f85873f4))


### CI

* extend fuzz to macos+windows; add vscode extension build job ([6a35bc8](https://github.com/nktkt/zigpp-lang/commit/6a35bc85ffa6f3194961ce4c4a6d8e8ca7edb4a8))

## [0.1.3](https://github.com/nktkt/zigpp-lang/compare/v0.1.2...v0.1.3) (2026-04-28)


### CI

* pin all GitHub Action versions to commit SHA ([92e9c52](https://github.com/nktkt/zigpp-lang/commit/92e9c526745d9f3c084ad7f6cb3572dc3217b99b))


### Build

* track release-please version and document `zig fetch --save` usage ([e641b89](https://github.com/nktkt/zigpp-lang/commit/e641b897b57f31fb02d3ae759a4980e3321d923c))

## [0.1.2](https://github.com/nktkt/zigpp-lang/compare/v0.1.1...v0.1.2) (2026-04-28)


### Features

* **repo:** add SECURITY policy, OpenSSF Scorecard, CODEOWNERS, FUNDING ([b5fcbdb](https://github.com/nktkt/zigpp-lang/commit/b5fcbdbba4c0329cfac189c24e69be32025221b8))


### CI

* **deps:** Bump github/codeql-action from 3 to 4 ([#8](https://github.com/nktkt/zigpp-lang/issues/8)) ([40a4de7](https://github.com/nktkt/zigpp-lang/commit/40a4de7e1465d0796194cb8ded83b0f6fa3683dd))
* **deps:** Bump googleapis/release-please-action from 4 to 5 ([#9](https://github.com/nktkt/zigpp-lang/issues/9)) ([ff05f0a](https://github.com/nktkt/zigpp-lang/commit/ff05f0acac529713a6adca3812a64c89fd735c09))
* **deps:** Bump ossf/scorecard-action from 2.4.0 to 2.4.3 ([#10](https://github.com/nktkt/zigpp-lang/issues/10)) ([73b8f8b](https://github.com/nktkt/zigpp-lang/commit/73b8f8b0d87dfdc1c725ce840f7721b1ef163dad))
* scope workflow tokens to least privilege ([cf3f4b6](https://github.com/nktkt/zigpp-lang/commit/cf3f4b6a2cf35c59ff7fc4b4be0e320063f02393))

## [0.1.1](https://github.com/nktkt/zigpp-lang/compare/v0.1.0...v0.1.1) (2026-04-28)


### Features

* **ci:** add CodeQL security scan and release-please automation ([bc6a260](https://github.com/nktkt/zigpp-lang/commit/bc6a260a6c9f072b8a66a7138977503925f4d599))


### Documentation

* auto-enable GitHub Pages on first deploy ([5f3ee71](https://github.com/nktkt/zigpp-lang/commit/5f3ee71af721e63080c56b08b3d6101a80b8d4ee))


### CI

* bump actions/configure-pages 5 -&gt; 6 ([719029d](https://github.com/nktkt/zigpp-lang/commit/719029df83e80b27f449818c8c4eb9747ee888bb))
* **deps:** Bump actions/checkout from 4 to 6 ([#1](https://github.com/nktkt/zigpp-lang/issues/1)) ([15b9dc6](https://github.com/nktkt/zigpp-lang/commit/15b9dc669bc5c03941bddcf323435567f328dad5))
* **deps:** Bump actions/deploy-pages from 4 to 5 ([#2](https://github.com/nktkt/zigpp-lang/issues/2)) ([e237cbd](https://github.com/nktkt/zigpp-lang/commit/e237cbde0fcb0c522a7ec2d2b659b6afcb2f6d47))
* **deps:** Bump actions/upload-artifact from 4 to 7 ([#3](https://github.com/nktkt/zigpp-lang/issues/3)) ([4d38520](https://github.com/nktkt/zigpp-lang/commit/4d38520c7986a94261f01d23fad942ece42dfa20))
* **deps:** Bump actions/upload-pages-artifact from 3 to 5 ([#4](https://github.com/nktkt/zigpp-lang/issues/4)) ([8cd3cef](https://github.com/nktkt/zigpp-lang/commit/8cd3cefcc609315c307c0779fb5943126360d49b))
* fix snapshot tests on Windows (CRLF normalization) ([56519b9](https://github.com/nktkt/zigpp-lang/commit/56519b94f5708a3cb810a22eefccc18e640ed5fc))
* handle Windows path separators and refresh stale snapshots ([4107369](https://github.com/nktkt/zigpp-lang/commit/4107369f77a52303d233c9617090bc7f22df72e4))
* install Zig manually from ziglang.org with correct arch-os naming ([f07db58](https://github.com/nktkt/zigpp-lang/commit/f07db585f4ac0b9d51885c8a24275126b22a3751))
* pin Zig to 0.15.1 (0.15.2 is Homebrew-only, not on mirrors) ([07ae56b](https://github.com/nktkt/zigpp-lang/commit/07ae56b20ade1050f2deca7288ee42abf29f60b0))

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

[0.1.0]: https://github.com/nktkt/zigpp-lang/releases/tag/v0.1.0
