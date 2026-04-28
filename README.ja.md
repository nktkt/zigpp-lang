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

Pre-alpha (v0.1.x)。コンパイラフロントエンド、ランタイムライブラリ、CLI
ツール、VS Code 拡張、ファズハーネス、エンドツーエンドのテスト基盤が
すべて揃っています。言語表面は意図的に小さく保たれ、実用的なプログラムを
書ける程度に安定しています。構文の境界ケースで壊れる可能性はあります。

## クイック例

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
- **`using x = expr;`** — 明示的 RAII バインダー (`var x = expr; defer x.deinit();` に低下)
- **`owned struct`** — must-deinit を sema が検査。`deinit` 不在は Z0010
- **`own var x`** + **`move x`** — affine な所有権、use-after-move 検出 (Z0020)
- **`requires(cond)` / `ensures(cond)`** — `zpp.contract.*` 経由のランタイム
  契約。`ensures` は `defer` で全 scope-exit に対し評価
- **`effects(.noalloc)`** — pure 関数中のアロケータ呼び出しを sema lint (Z0030)
- **`derive(.{ Hash, Eq, Debug, Json })`** — `a.hash()` や `User.eq(a, b)` が
  そのまま動くよう、ターゲット型本体にメソッドを注入
- **`where T: Trait`** — ジェネリック制約構文 (lowering 時はドロップ、ドキュメント目的)
- **エンドツーエンド**: 8 つの example が `zpp run` および `zig build e2e` で完走確認済
- **fuzz-clean**: parser/sema/lowerer に対し 83,000 入力を投入、panic / leak /
  timeout ゼロ

## ディレクトリ構造

```
zigpp/
  build.zig            ビルドスクリプト (artifact / test / example / e2e / fuzz)
  build.zig.zon        パッケージマニフェスト
  compiler/            .zpp -> .zig フロントエンド (token, ast, parser, sema, lower, diagnostics)
  lib/                 zpp ランタイム (Dyn, Owned, contracts, derive, async, traits, testing)
  tools/               zpp CLI + fmt / lsp / doc / migrate
  examples/            8 個の .zpp プログラム (各構文要素を網羅)
  tests/               compile / diagnostic / snapshot / behavior / no-hidden-alloc / fuzz
  vscode/              VS Code 拡張 (TextMate grammar + LSP client)
  docs/                mdBook ドキュメントソース
  README.md            English README
  README.ja.md         このファイル
  MANIFESTO.md         設計哲学 (やらないリスト)
  LANGUAGE.md          言語仕様スケッチと lowering ルール
  ROADMAP.md           段階的ロードマップ
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
zpp            メインドライバ: build / run / lower / fmt / check / doc / migrate / lsp
zpp-fmt        フォーマッタ
zpp-lsp        LSP サーバ (stdio JSON-RPC、VS Code 拡張から使用)
zpp-doc        Markdown ドキュメント生成
zpp-migrate    .zig -> .zpp 移行ヘルパー
```

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
`derive.Hash/Eq/Debug/Json`、async の `TaskGroup` (scaffold) を公開しています。
コンパイラフロントエンドも `zpp_compiler` として import 可能で、lowering
パイプラインをプログラムに組み込めます。

## エディタサポート

`vscode/` ディレクトリから VS Code 拡張をインストール:

```sh
cd vscode && npm install && npm run compile
# F5 で開発ホスト起動、または vsce package で .vsix 化
```

拡張は構文ハイライト (TextMate grammar)、`zpp-lsp` 経由の診断、
`Zig++: Run File` / `Zig++: Show Lowered Zig` コマンドを提供します。

## 哲学

- **隠れたメモリ確保なし。** すべてのアロケータは引数。
- **隠れた制御フローなし。** 例外、暗黙のデストラクタ、MVP では演算子オーバーロードもなし。
- **隠れたディスパッチなし。** 静的呼び出しは静的、動的ディスパッチは可視な `dyn Trait` を経由。
- **隠れたライフタイムなし。** RAII バインダーは `using`、所有権は `own` / `move`。
- **隠れたコストなし。** エフェクトは注釈で、コンパイラが検査または lint。

詳細版は [MANIFESTO.md](MANIFESTO.md)、構文と lowering ルールは
[LANGUAGE.md](LANGUAGE.md) を参照してください。

## ロードマップ

段階的に進めています。[ROADMAP.md](ROADMAP.md) 参照。今日の時点で
コア機能 (Phase 0–4) はエンドツーエンドで動いており、Phase 5
(エフェクト推論) と Phase 7 (本格的な並行実行) が残っています。

## コントリビュート

リサーチプロジェクトです。フィードバック、issue、PR を歓迎します。
ファズハーネス (`zig build fuzz`) はリグレッション検出に有効です。
クラッシュを見つけたら、入力が縮小され `tests/fuzz/crashes/` 配下に保存されます。

詳細は [CONTRIBUTING.ja.md](CONTRIBUTING.ja.md) (日本語) または
[CONTRIBUTING.md](CONTRIBUTING.md) (英語) を参照してください。

## ライセンス

MIT。[LICENSE](LICENSE) 参照。
