# Changelog

All notable changes to Zig++ are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.33](https://github.com/nktkt/zigpp-lang/compare/v0.1.32...v0.1.33) (2026-04-29)


### Fixes

* **tests:** audit handles Windows path separators ([1d4fc11](https://github.com/nktkt/zigpp-lang/commit/1d4fc1178952e0f69b087a54dab289381ffe656d))

## [0.1.32](https://github.com/nktkt/zigpp-lang/compare/v0.1.31...v0.1.32) (2026-04-29)


### Features

* **lsp:** code-action auto-fix (Z0010 deinit stub, Z0040 method stubs) ([fb9fca1](https://github.com/nktkt/zigpp-lang/commit/fb9fca1179ffd408df74324e3e9e2b0cb64f2248))
* **lsp:** WorkspaceEdit auto-fix for Z0010 + Z0040 ([8138606](https://github.com/nktkt/zigpp-lang/commit/81386062a85b5f22e05d11779c9d3dae02e23aa7))
* **sema:** `@effectsOf` surfaces .custom("name") effects ([7a8ab83](https://github.com/nktkt/zigpp-lang/commit/7a8ab83d5fb26bbb39b5f479974b04bea15865e1))
* **sema:** `@effectsOf` surfaces .custom("name") in lowered output ([37fc1d5](https://github.com/nktkt/zigpp-lang/commit/37fc1d5507eca3f4a32ff7c36ed8aac575045704))

## [0.1.31](https://github.com/nktkt/zigpp-lang/compare/v0.1.30...v0.1.31) (2026-04-29)


### Features

* **sema:** .custom("name") effects + Z0060 (round 5) ([d3596df](https://github.com/nktkt/zigpp-lang/commit/d3596dfbccf624a7105ec8431cb167e3e76ea878))

## [0.1.30](https://github.com/nktkt/zigpp-lang/compare/v0.1.29...v0.1.30) (2026-04-29)


### Features

* **sema:** borrow check round 2 — multi-borrow + block-scope tracking ([82a6137](https://github.com/nktkt/zigpp-lang/commit/82a613775e539a026138120062c60ff78002401e))

## [0.1.29](https://github.com/nktkt/zigpp-lang/compare/v0.1.28...v0.1.29) (2026-04-29)


### Features

* **lsp:** semanticTokens/full (replaces TextMate fallback) ([6eae63e](https://github.com/nktkt/zigpp-lang/commit/6eae63e60bc5150a13175fd2fe88926a7fed6763))

## [0.1.28](https://github.com/nktkt/zigpp-lang/compare/v0.1.27...v0.1.28) (2026-04-29)


### Features

* **lsp:** code-action quick-fix (server-side Explain) ([97fba0a](https://github.com/nktkt/zigpp-lang/commit/97fba0a4890b5871b8ab7aa331535573401f4e52))

## [0.1.27](https://github.com/nktkt/zigpp-lang/compare/v0.1.26...v0.1.27) (2026-04-29)


### Features

* **sema:** `@effectsOf`(f) queryable (round 4) ([9182e06](https://github.com/nktkt/zigpp-lang/commit/9182e06a778f15b24191a30379d4658ea98027a7))

## [0.1.26](https://github.com/nktkt/zigpp-lang/compare/v0.1.25...v0.1.26) (2026-04-29)


### Features

* **lsp:** rename + prepareRename (top-level decl names) ([419302a](https://github.com/nktkt/zigpp-lang/commit/419302a56ee601cbb15cbb8c48d0bda5ac611098))

## [0.1.25](https://github.com/nktkt/zigpp-lang/compare/v0.1.24...v0.1.25) (2026-04-29)


### Features

* **lsp:** textDocument/references + workspace/symbol ([a75d35c](https://github.com/nktkt/zigpp-lang/commit/a75d35cc2aa77215fca5d2de412c4494717f948b))

## [0.1.24](https://github.com/nktkt/zigpp-lang/compare/v0.1.23...v0.1.24) (2026-04-29)


### Features

* **lsp:** same-file go-to-definition ([de90eaf](https://github.com/nktkt/zigpp-lang/commit/de90eafbb15fb50b8af51c817a1eae27a8c99b11))

## [0.1.23](https://github.com/nktkt/zigpp-lang/compare/v0.1.22...v0.1.23) (2026-04-29)


### Features

* **sema:** Z0030 .panic effect inference (round 3) ([c5f0c3f](https://github.com/nktkt/zigpp-lang/commit/c5f0c3f38b57958347e9cd71e917853650c07ebd))

## [0.1.22](https://github.com/nktkt/zigpp-lang/compare/v0.1.21...v0.1.22) (2026-04-29)


### Features

* **lsp:** completion support (keywords + top-level idents) ([aee3ab7](https://github.com/nktkt/zigpp-lang/commit/aee3ab766fd64ef84b9342dfe0a48137d5bb5a3c))
* **sema:** Z0030 .io effect inference (round 2) ([9d24e3e](https://github.com/nktkt/zigpp-lang/commit/9d24e3e08449832238329be6e6e9452ff5607001))
* **sema:** Z0030 effect inference for .io annotation ([43fd026](https://github.com/nktkt/zigpp-lang/commit/43fd0267fe429f2d39f8d6ecfc46b6480b2cc578))

## [0.1.21](https://github.com/nktkt/zigpp-lang/compare/v0.1.20...v0.1.21) (2026-04-29)


### Documentation

* **examples:** effects_pure — comment Z0030 demo block ([26ec796](https://github.com/nktkt/zigpp-lang/commit/26ec7964b2ef8a20a222733f55d01f17e3c1b998))
* **examples:** effects_pure — comment Z0030 demo block ([184d524](https://github.com/nktkt/zigpp-lang/commit/184d5242cd47ac451d6f8191da83f0998d3985d1))

## [0.1.20](https://github.com/nktkt/zigpp-lang/compare/v0.1.19...v0.1.20) (2026-04-29)


### Features

* **sema:** Z0030 effect inference (MVP) ([68fc4e1](https://github.com/nktkt/zigpp-lang/commit/68fc4e1fe1f2f195ea49126823f0470719da0e1d))
* **sema:** Z0030 effect inference for .noalloc annotation ([e0e6593](https://github.com/nktkt/zigpp-lang/commit/e0e65936dbb020267360c31405dd161972b77cc4))


### Documentation

* **examples:** borrow_check — demonstrates Z0021 ([85eb854](https://github.com/nktkt/zigpp-lang/commit/85eb85439b2f2b7b239a7841fe0cf2aefaf4aa82))
* **examples:** borrow_check — demonstrates Z0021 ([9d1ac7a](https://github.com/nktkt/zigpp-lang/commit/9d1ac7a1f30e26c00568d10d873f7d21728f8b47))

## [0.1.19](https://github.com/nktkt/zigpp-lang/compare/v0.1.18...v0.1.19) (2026-04-29)


### Features

* **lexer:** support `\\`-prefixed multi-line strings ([27e8daa](https://github.com/nktkt/zigpp-lang/commit/27e8daaaea31f1fe565db779961443879a652c93))
* **lexer:** support `\\`-prefixed multi-line strings ([b2d06d4](https://github.com/nktkt/zigpp-lang/commit/b2d06d4bbfc16a6d3ffd0f6022ba1192b84da7da))
* **sema:** Z0021 borrow invalidated by move (MVP) ([da8b3f4](https://github.com/nktkt/zigpp-lang/commit/da8b3f42d577b612542789f7418c67540c4978e7))
* **sema:** Z0021 borrow invalidated by move (MVP) ([769f6f2](https://github.com/nktkt/zigpp-lang/commit/769f6f2800946f149d2c734bc56b8ff1f5db3e54))
* **vscode:** status bar + openDocs + more snippets ([3eaadfc](https://github.com/nktkt/zigpp-lang/commit/3eaadfca84b242546ceb6f07fe67286c5b5c1552))
* **vscode:** status bar version + openDocs command + 5 more snippets ([11e2d8e](https://github.com/nktkt/zigpp-lang/commit/11e2d8e7f72c82905f48fa4c5c5f63284cf440c3))

## [0.1.18](https://github.com/nktkt/zigpp-lang/compare/v0.1.17...v0.1.18) (2026-04-29)


### Features

* **examples:** cli/greet — multi-locale greeter ([#44](https://github.com/nktkt/zigpp-lang/issues/44)) ([#45](https://github.com/nktkt/zigpp-lang/issues/45)) ([e573203](https://github.com/nktkt/zigpp-lang/commit/e57320378e483579637849071ec47e2d78a5adf1))
* **tools:** \`zpp watch\` polls .zpp files and re-runs check on change ([#47](https://github.com/nktkt/zigpp-lang/issues/47)) ([b9e5e8c](https://github.com/nktkt/zigpp-lang/commit/b9e5e8ccf6a9439fac57300b087df5d7176856b6))

## [0.1.17](https://github.com/nktkt/zigpp-lang/compare/v0.1.16...v0.1.17) (2026-04-29)


### Features

* **tools:** \`zpp explain --list\` shows every diagnostic code ([#40](https://github.com/nktkt/zigpp-lang/issues/40)) ([4ad5b22](https://github.com/nktkt/zigpp-lang/commit/4ad5b227887f303d0973c59c2c48477bad121ee2))

## [0.1.16](https://github.com/nktkt/zigpp-lang/compare/v0.1.15...v0.1.16) (2026-04-29)


### Features

* **tools:** forward args after `--` from `zpp build` to `zig build` ([#35](https://github.com/nktkt/zigpp-lang/issues/35)) ([bb5cc4e](https://github.com/nktkt/zigpp-lang/commit/bb5cc4ee604eb36c531e660b52acd2dd263e5333))

## [0.1.15](https://github.com/nktkt/zigpp-lang/compare/v0.1.14...v0.1.15) (2026-04-29)


### Features

* **async:** real concurrent TaskGroup with JoinHandle(T) ([#30](https://github.com/nktkt/zigpp-lang/issues/30)) ([26cae90](https://github.com/nktkt/zigpp-lang/commit/26cae9074c85bb76032d31ab866f6ef352d5b867))
* **derive:** add Iterator, Serialize, Compare, FromStr helpers ([#29](https://github.com/nktkt/zigpp-lang/issues/29)) ([bf348f4](https://github.com/nktkt/zigpp-lang/commit/bf348f4442833ac1cf437522774a2c5481f949b9))
* **sema:** Z0040 — impl missing trait method ([#33](https://github.com/nktkt/zigpp-lang/issues/33)) ([dacb08f](https://github.com/nktkt/zigpp-lang/commit/dacb08f724b3ecf376ae6b7242e3d6a80e8c6f4f))
* **tools:** generate build.zig shim when project has none ([#31](https://github.com/nktkt/zigpp-lang/issues/31)) ([be8dfcd](https://github.com/nktkt/zigpp-lang/commit/be8dfcdf65ad7050e5d0557d0f56106803a2e1e6)), closes [#23](https://github.com/nktkt/zigpp-lang/issues/23)

## [0.1.14](https://github.com/nktkt/zigpp-lang/compare/v0.1.13...v0.1.14) (2026-04-29)


### Features

* **vscode:** snippets, hover docs link, explain quick-fix ([#28](https://github.com/nktkt/zigpp-lang/issues/28)) ([e683631](https://github.com/nktkt/zigpp-lang/commit/e6836318919c7a9f77043a1508dd79503f2aadd3))


### Documentation

* **contributing:** add multi-tab / multi-worktree workflow section ([e8e59f1](https://github.com/nktkt/zigpp-lang/commit/e8e59f185c01dc010d4a5991099eaa81c45bcbe1))

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

* bump actions/configure-pages 5 -> 6 ([719029d](https://github.com/nktkt/zigpp-lang/commit/719029df83e80b27f449818c8c4eb9747ee888bb))
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
