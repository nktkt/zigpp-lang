# Zig++ への貢献

🌐 [English CONTRIBUTING](CONTRIBUTING.md) | 日本語

ご関心ありがとうございます。Zig++ はリサーチプロジェクトで、言語表面を
小さく保ち、コストに対して正直な実装であることに焦点を置いています。
このガイドはコード貢献、バグ報告、機能提案の基本をカバーします。

## クイックスタート

```sh
git clone https://github.com/nktkt/zigpp-lang
cd zigpp-lang

zig build              # ランタイム / コンパイラ / 5 CLI をビルド
zig build test         # 全ユニットテスト + 統合テスト (~140 件)
zig build e2e          # 全 example を低下・ビルド・実行
ZPP_FUZZ_ITERS=1000 zig build fuzz   # ファザー実行 (opt-in)
```

必須: **Zig 0.15.x** (CI で固定バージョンを確認)。

## プロジェクト構造

| ディレクトリ    | 役割                                                    |
| -------------- | ------------------------------------------------------- |
| `compiler/`    | `.zpp` → `.zig` フロントエンド (token, ast, parser, sema, lower, diagnostics) |
| `lib/`         | `zpp` ランタイム: `Dyn`, `Owned`, contracts, derive    |
| `tools/`       | `zpp` CLI + `fmt`, `lsp`, `doc`, `migrate`             |
| `examples/`    | 8 個の `.zpp` プログラム (各構文要素を網羅)            |
| `tests/`       | compile / diagnostic / snapshot / behavior / no-hidden-alloc / fuzz |
| `vscode/`      | VS Code 拡張 (TextMate grammar + LSP client)           |

## ドクトリン — 受け入れる変更

Zig++ は Zig の上に **可視な** 抽象を追加するために存在します。新機能を
提案する前に、[MANIFESTO.md](MANIFESTO.md) のリジェクトリストを確認して
ください。一行で言うと:

> **隠れたメモリ確保なし、隠れた制御フローなし、暗黙のデストラクタなし、
> 例外なし、MVP では演算子オーバーロードもなし。**

他言語に既にあっても、隠れたコストを導入する機能は受け入れない可能性が
高いです。

## ワークフロー

1. **非自明な変更はまず issue を立てる**。バグ報告は事前議論なしで歓迎。
2. **`main` から branch を切る**。1 PR は 1 トピックに絞る。
3. **push 前にローカル全テスト**:
   ```sh
   zig build test
   zig build check
   zig build e2e
   ```
4. **CI が green であること**。push 時に ubuntu / macos / windows の build
   と 2,000 イテレーションのファズスモーク (3 OS) が走る。
5. **PR を `main` 向けに開く**。issue があれば参照。

## バグ報告

[Bug report テンプレート](.github/ISSUE_TEMPLATE/bug_report.md) を使用。
コンパイラクラッシュは、ファズハーネスが既に入力を縮小しています。
`.zpp` の小さな再現があれば issue にコピーしてください。

`zig build fuzz` が `tests/fuzz/crashes/` 配下にファイルを生成したら、
それを添付するのが最良です。

## コーディング規約

- **Zig style**: var/fn は `snake_case`、型は `PascalCase`、4-space インデント。
  commit 前に `zig fmt` を実行。
- **アロケータファースト**: メモリ確保し得る関数は明示的に `Allocator` を
  受け取る。non-main コードに `std.heap.page_allocator` を使わない。
- **コメントなし** (非自明な不変条件や workaround を説明する場合を除く)。
  識別子で自己記述する。
- **テスト** を新規コードに追加。最低 1 件 (compiler/ には inline `test "..."`
  ブロック、tests/ は統合テスト)。
- **生成された `.zig` は読みやすさを保つ**。lowering ルール: `.zpp` で読む
  ものは emit された `.zig` でも明白であるべき。

## 診断コード

新しい sema チェックを追加する場合、`compiler/diagnostics.zig` にコードを
割り当て (`Z<NNNN>_<short_name>`)、`hint(code)` テーブルに `hint:` 行を
含めてください。hint はユーザがコードを引っかけたときに見るもの。
1 分かけて書く価値があります。

## ファジング

ファズハーネス (`tests/fuzz/`) は合成 `.zpp` を生成 + 既存 example を変異。
parser / sema / lowerer に触れる変更を出す前に実行を:

```sh
ZPP_FUZZ_ITERS=10000 zig build fuzz
```

クラッシュを見つけたら、入力を `tests/fuzz/crashes/` 配下に残し
(gitignore 済)、issue を立ててください。

## コミットメッセージ

このリポジトリは [Conventional Commits](https://www.conventionalcommits.org/)
を採用しています ([release-please](https://github.com/googleapis/release-please)
が次バージョンと CHANGELOG を自動算出するため)。以下の prefix を使用:

| Prefix      | 意味                                          | バンプ    |
| ----------- | --------------------------------------------- | --------- |
| `feat:`     | 新しいユーザ可視機能                          | minor     |
| `fix:`      | バグ修正                                      | patch     |
| `perf:`     | パフォーマンス改善                            | patch     |
| `refactor:` | 内部リファクタリング (動作変更なし)           | none      |
| `docs:`     | ドキュメントのみ                              | none      |
| `ci:`       | CI / workflow 変更                            | none      |
| `build:`    | ビルドスクリプト変更                          | none      |
| `test:`     | テストのみ                                    | none      |
| `chore:`    | リポジトリ管理                                | none      |

major バンプは prefix の後に `!` を付けるか `BREAKING CHANGE:` フッター
(例: `feat!: drop using` または `feat: ...` + `BREAKING CHANGE: ...`)。

## リリース

リリースは [release-please](https://github.com/googleapis/release-please)
が管理します。`main` への push のたびに、bot が "release PR" を開閉し、
Conventional Commit のタイトルを `CHANGELOG.md` 項目に集約、
`.github/.release-please-manifest.json` のバージョンを bump します。
release PR を merge すると新しい tag (`vX.Y.Z`) が打たれ、GitHub
release が公開されます。メンテナは手動で tag を push しないでください。

## ライセンス

貢献によって、貢献内容が MIT ([LICENSE](LICENSE)) 下でライセンスされる
ことに同意したものとみなします。アシスタントを使った場合は commit に
`Co-Authored-By:` トレーラーを含めてください。
