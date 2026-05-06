# Changelog

All notable changes to Zig++ are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.35](https://github.com/nktkt/zigpp-lang/compare/v0.1.34...v0.1.35) (2026-05-06)


### Features

* **vscode:** grammar + snippets for v0.2 features (structural / .noasync / .custom) ([fc416db](https://github.com/nktkt/zigpp-lang/commit/fc416dbd4faa2bb51c63d7b176b3d8a1cd1ded2d))
* **vscode:** grammar + snippets for v0.2 features (structural / .noasync / .custom) ([1d9fa44](https://github.com/nktkt/zigpp-lang/commit/1d9fa44b329431876e580b8749113698d038ed06))


### Fixes

* **cli:** explain --list --json now emits hint as `summary` ([e4c3024](https://github.com/nktkt/zigpp-lang/commit/e4c302493797ccd608ef83645c46700c8b04956b))
* **cli:** explain --list --json now emits hint as `summary` ([e247917](https://github.com/nktkt/zigpp-lang/commit/e2479171b64c00fcefa729ce300d21c47a571bf1))
* harden onHover against malformed JSON, escape `zpp doc` headings, correct Owned.deinit doc ([619b83e](https://github.com/nktkt/zigpp-lang/commit/619b83e5b1770ef7e835647c3b36778b297cf676))
* harden onHover against malformed JSON, escape `zpp doc` headings, correct Owned.deinit doc ([2f1c700](https://github.com/nktkt/zigpp-lang/commit/2f1c7001d2979ae8012cec0845dc4306b635f943))


### Documentation

* add a CLI reference page ([76ffe3e](https://github.com/nktkt/zigpp-lang/commit/76ffe3e968a530b183d78647bc9848af2084618a))
* add a Lowering reference page ([d4b5a52](https://github.com/nktkt/zigpp-lang/commit/d4b5a5226517387d57884e93dddf8a6693362f40))
* add a Runtime library reference page ([5a447cb](https://github.com/nktkt/zigpp-lang/commit/5a447cb9d258cb23093b0cc360177fcc4bbb52cc))
* add CLI reference page (every zpp subcommand) ([cda2b72](https://github.com/nktkt/zigpp-lang/commit/cda2b729dec9ba3be1a7b65fd53d876c5f62b225))
* add Lowering reference page (.zpp ↔ .zig) ([af27e6a](https://github.com/nktkt/zigpp-lang/commit/af27e6abc0c5c6384160b782e9d9fc5b2fd5948e))
* add Runtime library reference page ([a5e1d75](https://github.com/nktkt/zigpp-lang/commit/a5e1d75908edb54c0e11a7b4870eef16552d84a3))
* **diagnostics:** add Z0002 (structural impl missing method) ([7e8250d](https://github.com/nktkt/zigpp-lang/commit/7e8250d319d6747a3d5e5e277ab8161527b2ca05))
* **diagnostics:** add Z0002 (structural impl missing method) ([f92efd7](https://github.com/nktkt/zigpp-lang/commit/f92efd76ad1e6979cf8add8890d5378c14fb447f))
* **examples:** drop stale notes that contradict landed features ([b052c5c](https://github.com/nktkt/zigpp-lang/commit/b052c5c9dd78accc9fae43aa2239d5f114e0edc8))
* **examples:** drop stale notes that contradict landed features ([ffddd87](https://github.com/nktkt/zigpp-lang/commit/ffddd874fa17852784daa01083a1e994a8ecd362))
* **v0.2 follow-up:** add Z0002 page, highlight `invariant`, fix two stale example notes, sync plugin scaffold ([7f0c163](https://github.com/nktkt/zigpp-lang/commit/7f0c1632298900c382a84581210cd7dc96ce0c1d))
* **v0.2 follow-up:** add Z0002 page, highlight `invariant`, fix two stale example notes, sync plugin scaffold ([12b5eb4](https://github.com/nktkt/zigpp-lang/commit/12b5eb41a56cd7bb6b029761580a3e37b07ac374))
* v0.2 release shakeout — re-document `zpp test`, correct bench / Phase 5 / Z0011 claims ([d5e0eef](https://github.com/nktkt/zigpp-lang/commit/d5e0eef452271852c9615df1cfa044200ad6575c))
* v0.2 release shakeout — re-document `zpp test`, correct bench/effects/Z0011 claims ([89e81a0](https://github.com/nktkt/zigpp-lang/commit/89e81a00ed59a57ed7a8c829d02684b3a29c3cc4))

## [0.1.34](https://github.com/nktkt/zigpp-lang/compare/v0.1.33...v0.1.34) (2026-05-06)


### Features

* **cli:** build.zpp thin alias — auto-lower to build.zig ([#93](https://github.com/nktkt/zigpp-lang/issues/93)) ([3a7df98](https://github.com/nktkt/zigpp-lang/commit/3a7df9888faf8674c6f7e4f4ae0e7ecb08654f7b))
* **cli:** zpp explain --json — IDE-consumable diagnostic data ([#100](https://github.com/nktkt/zigpp-lang/issues/100)) ([2296666](https://github.com/nktkt/zigpp-lang/commit/22966669e25f8527f7b53b20e2a2be11e7bee8a1))
* **cli:** zpp init --template lib | exe | plugin ([#105](https://github.com/nktkt/zigpp-lang/issues/105)) ([43facba](https://github.com/nktkt/zigpp-lang/commit/43facba95f2c94991183a99452811e0c2bbf6985))
* **cli:** zpp test — run tests in .zpp files via zig test ([#96](https://github.com/nktkt/zigpp-lang/issues/96)) ([3ebddb3](https://github.com/nktkt/zigpp-lang/commit/3ebddb337253384f307874957c9326639ba50d8b))
* **examples:** writer stack, structural advanced, effects demo ([#101](https://github.com/nktkt/zigpp-lang/issues/101)) ([b57f6cc](https://github.com/nktkt/zigpp-lang/commit/b57f6cc82eff1ee3b39cd023c078dd4c3cdcc148))
* **examples:** writer_stdlib — consume zpp.writer trait from stdlib ([#113](https://github.com/nktkt/zigpp-lang/issues/113)) ([2a78b67](https://github.com/nktkt/zigpp-lang/commit/2a78b6769c096c4e8006c8d44e7b4d5f86dae436))
* **lib:** Writer trait + Stdout/File/Buffered impls (Phase 2 stdlib) ([#97](https://github.com/nktkt/zigpp-lang/issues/97)) ([7ba0381](https://github.com/nktkt/zigpp-lang/commit/7ba0381e9deaf155dc2c7ab598c9215211be7bdf))
* **lsp:** signatureHelp + typeDefinition (same-file) ([824b2b7](https://github.com/nktkt/zigpp-lang/commit/824b2b7d77c2fc77c654b26fedeb83ce743e0040))
* **lsp:** textDocument/codeLens (effect / derive / owned lenses) ([#99](https://github.com/nktkt/zigpp-lang/issues/99)) ([ae58404](https://github.com/nktkt/zigpp-lang/commit/ae58404561d2786e310aca12b216fe1940a7fc7d))
* **lsp:** textDocument/implementation + callHierarchy ([#95](https://github.com/nktkt/zigpp-lang/issues/95)) ([018a956](https://github.com/nktkt/zigpp-lang/commit/018a956de7a0b883897eb3a6c93cd94bc11c2f86))
* **migrate:** 5 more rewrite patterns (panic→requires, deinit→owned, etc.) ([#98](https://github.com/nktkt/zigpp-lang/issues/98)) ([9836999](https://github.com/nktkt/zigpp-lang/commit/98369996a478bc44ffc9049d7fdbb84fc54b3f01))
* **sema:** .noasync effect axis (round 6) ([#92](https://github.com/nktkt/zigpp-lang/issues/92)) ([be4d480](https://github.com/nktkt/zigpp-lang/commit/be4d480f30b2fd721ad4f9fb3a40cd151383c160))
* **sema:** trait method default bodies ([#103](https://github.com/nktkt/zigpp-lang/issues/103)) ([7f75d78](https://github.com/nktkt/zigpp-lang/commit/7f75d78c5ef2ae4d2636093eb05f7d0855c19aed))
* structural traits + HTML docs + LSP folds/hints + async cancel ([#91](https://github.com/nktkt/zigpp-lang/issues/91)) ([8288667](https://github.com/nktkt/zigpp-lang/commit/8288667ff31d9a93477ec65d7535ce98af64f868))
* **traits:** unbounded trait method arity (lift the 5-param ceiling) ([#94](https://github.com/nktkt/zigpp-lang/issues/94)) ([26738b9](https://github.com/nktkt/zigpp-lang/commit/26738b954c625f80bc97d87f443cab66a5e6dca5))
* **vscode:** advertise inlayHint/folding/implementation/callHierarchy/codeLens + 2 commands ([#104](https://github.com/nktkt/zigpp-lang/issues/104)) ([7eecac3](https://github.com/nktkt/zigpp-lang/commit/7eecac3e872a8948febf63973b2410af12580ada))


### Refactors

* **bench:** use writeAll for argument-free print calls ([#115](https://github.com/nktkt/zigpp-lang/issues/115)) ([d79387b](https://github.com/nktkt/zigpp-lang/commit/d79387bbc01bfcb2816348c052904e35dd7e5ffa))


### Documentation

* add a Diagnostics reference page ([#118](https://github.com/nktkt/zigpp-lang/issues/118)) ([23df3f4](https://github.com/nktkt/zigpp-lang/commit/23df3f4757881037ab55fade59b01aa8bcff5c91))
* align LANGUAGE.md / MANIFESTO.md with the effects + derive set the compiler implements ([dda8bf1](https://github.com/nktkt/zigpp-lang/commit/dda8bf1aab2bb5410c238c86d780f2222b11fd5c))
* align spec docs with the effects/derive sets the compiler actually implements ([797340d](https://github.com/nktkt/zigpp-lang/commit/797340d43752f1a8d5904b4a185473efa34c527a))
* **language:** refresh for v0.2 (structural, defaults, .noasync, build.zpp, Writer, LSP) ([#106](https://github.com/nktkt/zigpp-lang/issues/106)) ([ba06295](https://github.com/nktkt/zigpp-lang/commit/ba0629599d2d51ff19a5c7b8026123f647668131))
* **readme:** refresh "What works today" for v0.2 ([#107](https://github.com/nktkt/zigpp-lang/issues/107)) ([a0bb811](https://github.com/nktkt/zigpp-lang/commit/a0bb8115ce12a7330e7933eb4f7c18a9c1d81c07))
* refresh examples index + bring README.ja.md to parity ([49f543c](https://github.com/nktkt/zigpp-lang/commit/49f543cde0bf21c4e8c39419bb642e11a102e594))
* refresh examples index and bring README.ja.md to parity ([729588c](https://github.com/nktkt/zigpp-lang/commit/729588ccccfd965e179de4c567d5596db6a9b3a0))
* remove `zpp test` claims (subcommand not implemented) and fix mangled [@effects](https://github.com/effects)Of links ([#120](https://github.com/nktkt/zigpp-lang/issues/120)) ([a41653a](https://github.com/nktkt/zigpp-lang/commit/a41653a8ca0141e2bae325d10cb2633aaf9ef32f))
* **roadmap:** mark Phase 2/5/7 done and Phase 6 substantially done as of v0.2 ([#108](https://github.com/nktkt/zigpp-lang/issues/108)) ([735feb0](https://github.com/nktkt/zigpp-lang/commit/735feb00aecdcde825e577bade4a08c6ea023f7a))


### CI

* **deps:** Bump github/codeql-action from 4.35.2 to 4.35.3 ([0d3cfc0](https://github.com/nktkt/zigpp-lang/commit/0d3cfc0ac5befd158356d74febb01224a88caf4e))
* **deps:** Bump github/codeql-action from 4.35.2 to 4.35.3 ([ee90461](https://github.com/nktkt/zigpp-lang/commit/ee904616c4ee91d8e3ee5fcab2281f264cd25aa8))

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
