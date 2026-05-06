# Zig++

[![CI](https://github.com/nktkt/zigpp-lang/actions/workflows/ci.yml/badge.svg)](https://github.com/nktkt/zigpp-lang/actions/workflows/ci.yml)
[![docs](https://github.com/nktkt/zigpp-lang/actions/workflows/docs.yml/badge.svg)](https://nktkt.github.io/zigpp-lang/)
[![CodeQL](https://github.com/nktkt/zigpp-lang/actions/workflows/codeql.yml/badge.svg)](https://github.com/nktkt/zigpp-lang/actions/workflows/codeql.yml)
[![Scorecard](https://github.com/nktkt/zigpp-lang/actions/workflows/scorecard.yml/badge.svg)](https://github.com/nktkt/zigpp-lang/actions/workflows/scorecard.yml)
[![Zig 0.15+](https://img.shields.io/badge/zig-0.15%2B-orange)](https://ziglang.org/)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

📖 **ドキュメントサイト**: https://nktkt.github.io/zigpp-lang/

🌐 [English README](README.md) | 日本語

Zig 上に乗せた、可視な高水準抽象。

Zig++ は Zig 0.15+ をベースにしたリサーチ言語です。名前付きトレイト、`using`
による明示的 RAII、所有権/move チェッカー、`dyn` ディスパッチ、コントラクト、
エフェクト注釈、`derive` を追加します。すべての構文要素はプレーンな Zig へ
低下 (lowering) され、**隠れたメモリ確保なし、隠れた制御フローなし、暗黙の
デストラクタなし、例外なし** を保ちます。`.zpp` のソースは `.zig` ソースに
変換され、標準の `zig` ツールチェーンでビルドされます。

## ステータス

Pre-alpha (v0.2)。v0.2 で構造的トレイト、トレイトメソッドのデフォルト本体、
`.noasync` エフェクト軸、`Writer` 標準ライブラリトレイト、TaskGroup の
キャンセル伝播、`zpp explain --json` / `zpp init --template`
サブコマンド、`build.zpp`、フル機能の LSP が揃いました。言語表面は引き
続き意図的に小さいまま、エンドツーエンドの守備範囲だけ広がっています。

## クイック例

```zig
const std = @import("std");
const zpp = @import("zpp");

trait Greeter {
    fn greet(self) void;
    fn shout(self) void { self.greet(); }   // デフォルト本体
}

derive(.{ Hash, Eq, Debug })
const English = struct {
    name: []const u8,
};

impl Greeter for English {
    fn greet(self) void {
        std.debug.print("Hello, {s}!\n", .{self.name});
    }
}

fn welcome(who: impl Greeter) void effects(.noalloc) {
    who.greet();
}

pub fn main() !void {
    var en = English{ .name = "Ada" };
    welcome(&en);
}
```

直接実行:

```sh
zpp run examples/hello_trait.zpp
# Hello, Ada!
```

低下後の Zig を確認:

```sh
zpp lower examples/hello_trait.zpp
```

## 今動くもの

- **1 つの `impl` 宣言から 3 種類のディスパッチ**:
  - `fn f(x: impl Trait)` → 静的 (Zig の `anytype`、モノモーフ化)
  - `fn f(x: dyn Trait)` → 動的 (可視な `zpp.Dyn(VTable)` ファットポインタ)
  - `extern interface Foo { ... }` → C ABI (`extern struct Foo_ABI` + `callconv(.c)`)
- **構造的トレイト** — `trait Foo : structural { ... }` は名前ではなく形で照合します。
  全メソッドが揃っていれば nominal な `impl` 不要。形不一致は Z0002 で検知。
- **トレイトメソッドのデフォルト本体** — `trait` 内の `fn name(self) T { body }`
  はフォールバック実装を提供します。`impl` 側はデフォルトのあるメソッドを
  省略可能 (抽象メソッドの欠落は引き続き Z0040)。
- **トレイト引数 0..16** — トレイトメソッドの引数は最大 16 個 (旧 5)。VTable
  バリデータも合わせて拡張済み。
- **`using x = expr;`** — 明示的 RAII バインダー (`var x = expr; defer x.deinit();` に低下)
- **`owned struct`** — must-deinit を sema が検査。`deinit` 不在は Z0010
- **`own var x`** + **`move x`** — affine な所有権、use-after-move (Z0020) と
  マルチボロー + ブロックスコープ対応のボローチェッカ (Z0021)
- **`requires(cond)` / `ensures(cond)`** — `zpp.contract.*` 経由のランタイム
  契約。`ensures` は `defer` で全 scope-exit に対し評価
- **5 軸の `effects(...)`** — `.noalloc` / `.noio` / `.nopanic` / `.noasync` /
  `.nocustom("X")`。bottom-up の効果推論で、`a.alloc(...)` を呼ぶ関数は
  `.alloc` が推論され、`.noalloc` 宣言と衝突すれば Z0030。`.async` 軸 (round 6)
  は suspend する呼び先を同様に追跡。`.custom("X")` はファイル内 1 ホップ伝播
  (Z0060)、`@effectsOf(f)` は推論結果を `[]const u8` で取り出します。
- **`derive(.{ Hash, Eq, Ord, Default, Clone, Debug, Json, Iterator, Serialize, Compare, FromStr })`**
  — 11 個の comptime ヘルパが構造体メソッドとして注入され、`a.hash()` /
  `User.eq(a, b)` / `a.iter()` / `a.serialize(arena)` / `User.fromStr(s, arena)` /
  `User.lt(a, b)` がそのまま使えます
- **`Writer` トレイト** — Phase 2 の標準ライブラリ収束。`lib/` で `std.Io.Writer`
  をラップする `Writer` トレイトを提供し、`derive(.Debug)` / `derive(.Serialize)`
  とユーザコードが同じ「名前付きシンク」を共有できます
- **キャンセル可能な `TaskGroup`** — `cancel()`, `spawnWithToken(tok, fn)`,
  デッドラインで auto-cancel する watchdog がインフライトタスクへキャンセル
  伝播。`JoinHandle(T)` は join 側にキャンセル状態を返します
- **`where T: Trait`** — ジェネリック制約構文 (lowering 時はドロップ)
- **`\\` プレフィクス複数行文字列** — 低下後の Zig へそのまま透過
- **エンドツーエンド**: 10+ の example が `zpp run` / `zig build e2e` で完走確認済
- **fuzz-clean**: parser/sema/lowerer に 83,000+ 入力、panic / leak / timeout ゼロ
- **`zpp-lsp` 経由のフル IDE 機能**: hover-with-explain、go-to-definition、
  find references、ワークスペースシンボル検索、rename、document symbol
  (Outline)、補完、コードアクション (Explain Z####)、セマンティックトークン
  (`/full`、`/range`、`/full/delta`)、`inlayHint`、`foldingRange`、
  `implementation`、`callHierarchy`、`codeLens`
- **CLI サブコマンド**: `zpp build / run / lower / fmt / check / watch / doc /
  migrate / test / lsp / init / explain` に加え、v0.2 で追加された
  `zpp test` (各 `.zpp` を lower し `zig test` で実行)、
  `zpp explain --json` (IDE 向け機械可読 diagnostic explainer)、
  `zpp init --template lib | exe | plugin` (3 種のプロジェクトひな形)
- **`build.zpp`** — `build.zig` の薄いエイリアス。ソース横に `build.zpp` を
  置けばドライバが lowering してから `zig build` を呼びます
- **Migrate +5 パターン** — `zpp-migrate` が新たに 5 種の `.zig` イディオム
  (arena スコープの `defer`、手書き vtable struct、`errdefer` ペアの `init`、
  ほか) を認識し、`.zpp` への書き換えを提案します

## ディレクトリ構造

```
zigpp/
  build.zig            ビルドスクリプト (artifact / test / example / e2e / fuzz)
  build.zig.zon        パッケージマニフェスト
  compiler/            .zpp -> .zig フロントエンド (token, ast, parser, sema, lower, diagnostics)
  lib/                 zpp ランタイム (Dyn, Owned, contracts, derive, async, traits, Writer, testing)
  tools/               zpp CLI + fmt / lsp / doc / migrate (init --template 用 templates/ を含む)
  examples/            各構文要素を網羅した .zpp プログラム (build_zpp/, multi_file/, cli/ を含む)
  examples-consumer/   `zig fetch` で `zpp` ランタイムを取り込む下流の Zig プロジェクト例
  bench/               マイクロベンチ (compileToString: parse + sema + lower)
  tests/               compile / diagnostic / snapshot / behavior / no-hidden-alloc / fuzz
  vscode/              VS Code 拡張 (TextMate grammar + LSP client + snippets)
  docs/                mdBook ドキュメントソース (GitHub Pages へデプロイ)
  README.md            English README
  README.ja.md         このファイル
  MANIFESTO.md         設計哲学 (やらないリスト)
  LANGUAGE.md          言語仕様スケッチと lowering ルール
  ROADMAP.md           段階的ロードマップ
  CHANGELOG.md         release-please 管理の changelog
  LICENSE              MIT
```

## ビルド

```sh
zig build                    # ランタイム / コンパイラライブラリ / 5 CLI をビルド
zig build test               # 全ユニットテスト + 統合テスト
zig build check              # 全 example を parse + sema (codegen なし)
zig build examples           # 全 .zpp example を .zig に低下 (実行はしない)
zig build e2e                # 全 example を低下・ビルド・**実行**
zig build fuzz               # opt-in ファザー (ZPP_FUZZ_ITERS=N --seed=N で調整)
zig build run -- help        # zpp CLI を呼ぶ
```

`zig-out/bin/` 配下にインストールされる CLI:

```
zpp            メインドライバ: build / run / lower / fmt / check / watch / doc /
               migrate / test / lsp / init / explain
zpp-fmt        フォーマッタ
zpp-lsp        LSP サーバ (stdio JSON-RPC、VS Code 拡張から使用)
zpp-doc        Markdown ドキュメント生成
zpp-migrate    .zig -> .zpp 移行ヘルパー
```

`zpp test [paths...]` は各 `.zpp` を `.zpp-cache/<rel>.zig` に lower し、それぞれに `zig test` を走らせます (`--filter <p>` / `--release` / `-v`)。
`zpp explain Z0030 --json` は IDE 向けの構造化ペイロードを出力します。
`zpp init --template lib | exe | plugin` でひな形の形を選べます。

## Zig 依存として使う

別の Zig プロジェクトから `zpp` ランタイムライブラリを取り込む:

```sh
zig fetch --save git+https://github.com/nktkt/zigpp-lang
```

`build.zig` で:

```zig
const zpp_dep = b.dependency("zigpp", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zpp", zpp_dep.module("zpp"));
```

ランタイムは `Dyn`、`Owned`、`ArenaScope`、`contract.requires`、
`derive.Hash/Eq/Ord/Default/Clone/Debug/Json/Iterator/Serialize/Compare/FromStr`、
`Writer` トレイト、`std.Thread` ベースの並行 `TaskGroup`
(型付き `JoinHandle(T)` + 協調的キャンセル: `cancel()` / `spawnWithToken()` /
watchdog) を公開しています。コンパイラフロントエンドも `zpp_compiler` として
import 可能で、lowering パイプラインをプログラムに組み込めます。

## エディタサポート

`vscode/` ディレクトリから VS Code 拡張をインストール:

```sh
cd vscode && npm install && npm run compile
# F5 で開発ホスト起動、または vsce package で .vsix 化
```

拡張は構文ハイライト (TextMate + LSP セマンティックトークン)、`zpp-lsp` 経由
の診断、補完、hover-with-explain、go-to-definition、find references、
ワークスペースシンボル検索、rename、Outline、inlay hint、folding range、
go-to-implementation、call hierarchy、code lens、code action、
`Zig++: Run File` / `Zig++: Show Lowered Zig` コマンドを提供します。

Vim/Neovim、Emacs、Helix などその他の LSP クライアントは、`zpp-lsp`
バイナリに stdio で直接接続できます。上記の IDE 側機能はすべて言語
サーバ側から提供されているため、VS Code 以外でも同じ機能が使えます。

## 哲学

- **隠れたメモリ確保なし。** すべてのアロケータは引数。
- **隠れた制御フローなし。** 例外、暗黙のデストラクタ、MVP では演算子オーバーロードもなし。
- **隠れたディスパッチなし。** 静的呼び出しは静的、動的ディスパッチは可視な `dyn Trait` を経由。
- **隠れたライフタイムなし。** RAII バインダーは `using`、所有権は `own` / `move`。
- **隠れたコストなし。** エフェクトは注釈で、コンパイラが検査または lint。

詳細版は [MANIFESTO.md](MANIFESTO.md)、構文と lowering ルールは
[LANGUAGE.md](LANGUAGE.md) を参照してください。

## ロードマップ

段階的に進めています。[ROADMAP.md](ROADMAP.md) と
[docs/src/v0.2-plan.md](docs/src/v0.2-plan.md) 参照。コア機能 (Phase 0–4) は
エンドツーエンドで動作し、Phase 5 (エフェクト推論) は **6 ラウンド** 投入済:
`.alloc`、`.io`、`.panic`、`@effectsOf(f)` クエリ、`.custom("X")`、新たに
`.async` 軸。Phase 7 (本格的な並行実行) は協調的キャンセル
(`cancel()` / `spawnWithToken()` / watchdog) を備えた TaskGroup ランタイムが
動いています。

## コントリビュート

リサーチプロジェクトです。フィードバック、issue、PR を歓迎します。
ファズハーネス (`zig build fuzz`) はリグレッション検出に有効です。
クラッシュを見つけたら、入力が縮小され `tests/fuzz/crashes/` 配下に保存されます。

詳細は [CONTRIBUTING.ja.md](CONTRIBUTING.ja.md) (日本語) または
[CONTRIBUTING.md](CONTRIBUTING.md) (英語) を参照してください。

## ライセンス

MIT。[LICENSE](LICENSE) 参照。
