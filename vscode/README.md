# Zig++ Language Support for VS Code

Editor support for the [Zig++](../README.md) research language: rich syntax
highlighting for `.zpp` files, language-server-backed diagnostics and
formatting, and one-keystroke commands to run a file or inspect the lowered
Zig output.

Zig++ is a thin research layer on top of Zig 0.16.x that adds traits,
dynamic dispatch (`dyn`), affine ownership (`owned` / `own` / `move`),
contracts, and effect tracking. This extension wires those concepts up to
VS Code so you get the same fluent editing experience you get with the
official Zig extension.

## Features

- Syntax highlighting tuned for the full Zig 0.16 keyword set plus the Zig++
  extensions (`trait`, `impl`, `dyn`, `using`, `owned`, `own`, `move`,
  `where`, `requires`, `ensures`, `effects`, `derive`, `interface`).
- Live diagnostics via the bundled `zpp-lsp` language server (over JSON-RPC
  on stdio).
- Document formatting via `textDocument/formatting` (toggle with
  `zigpp.formatter.enable`; works with `editor.formatOnSave`).
- **Outline view** (`textDocument/documentSymbol`): traits, structs, owned
  structs, impl blocks, extern interfaces, and top-level functions show up
  in the VS Code Outline panel and breadcrumbs, with one level of method
  children for traits/structs/impls.
- **Completion** (`textDocument/completion`): the language server returns
  every Zig++ keyword plus the names of top-level decls in the current
  document (functions, traits, structs, owned structs, extern interfaces,
  impl targets). Trigger characters are `.` and `:`. Context-aware
  completion (after `.`, after `impl`, etc.) is not implemented yet.
- **Go to definition** (`textDocument/definition`): jump from a use of a
  top-level identifier to its declaration in the same file. Cross-file
  resolution and method-on-receiver resolution are not implemented yet.
- **Go to type definition** (`textDocument/typeDefinition`): with the
  cursor on a `fn` parameter binding, jump to the declaration of its
  type. Strips leading `*`, `?`, `[]const `, `[]` prefixes before
  resolving against the same-file decl table. Locals, receivers, and
  cross-file resolution are not implemented yet.
- **Signature help** (`textDocument/signatureHelp`): inside a call
  expression, the server walks back to the open `(` (balancing nested
  parens / brackets / braces and skipping strings, char literals, and
  `//` comments), looks up the callee against the same-file fn table,
  and returns a single SignatureInformation with one
  ParameterInformation per `<name>: <type>` plus a 0-based
  `activeParameter` derived from the unbalanced commas before the
  cursor. Trigger characters are `(` and `,`. Method-on-receiver and
  overloaded signatures are not implemented yet.
- **Find all references** (`textDocument/references`): list every same-file
  occurrence of the identifier under the cursor, skipping string literals,
  char literals, and `//` line comments. Honours `includeDeclaration`.
- **Workspace symbol search** (`workspace/symbol`): case-insensitive
  substring filter over top-level decls (functions, traits, structs, owned
  structs, extern interfaces, impl blocks) across every currently-open
  document. Use VS Code's "Go to Symbol in Workspace" (`Ctrl+T` /
  `Cmd+T`) to invoke it.
- **Rename** (`textDocument/prepareRename` + `textDocument/rename`):
  press `F2` on a top-level decl name (function, trait, struct, owned
  struct, extern interface) to rename every same-file occurrence in one
  edit. Strings, char literals, and `//` comments are skipped. Renaming
  parameters, locals, method names, and cross-file rename are not yet
  supported.
- "Run current file" command that shells out to `zpp run` and streams output
  to the Zig++ output channel.
- "Show lowered Zig" command that opens the result of `zpp lower` in a new
  untitled `.zig` editor so you can see exactly what the compiler emits.
- **Snippets** for `trait`, `impl`, `owned struct`, `using`, `dyn`,
  `derive`, `requires`, `ensures`, `effects`, `extern interface`, `own`,
  `main`, plus `using_arena`, `dyn_init`, `task_group`, `effects_pure`,
  and `pub_trait`. Type the prefix and press `Tab`.
- **Hover with explanations**: hovering over a diagnostic line shows the
  long-form explanation of the diagnostic code plus a link to the docs
  site reference.
- **Quick Fix code actions**: when the cursor is on a Zig++ diagnostic
  (e.g. Z0010), the lightbulb offers `Explain Z####: <summary>` to open
  the long-form text in the output channel. The `zpp-lsp` server now
  implements `textDocument/codeAction` natively, so the same affordance
  is available in any LSP client (Vim, Emacs, Helix, Neovim) — not just
  VS Code. The original client-side provider remains registered as a
  fallback for diagnostics that pre-date the LSP-driven path. Z0010
  (owned struct missing `deinit`) and Z0040 (impl missing trait
  method(s)) additionally ship a `WorkspaceEdit`-based **auto-fix**
  alongside the explain entry: pick "Auto-fix: add `pub fn deinit` stub"
  to insert a `pub fn deinit(self: *@This()) void { _ = self; }` body
  before the struct's closing brace, or "Auto-fix: stub missing trait
  method(s)" to drop a `pub fn <name>(...) void { unreachable; }` per
  missing trait method into the impl block. Auto-fixes are intentionally
  minimal stubs — review and fill in the bodies before saving.
- **Semantic highlighting** (`textDocument/semanticTokens/full`,
  `range`, and `full/delta`): the language server emits per-token
  classifications (keyword, string, number, comment, function,
  interface, struct, variable) plus a `declaration` modifier on the
  names of `fn` / `trait` / `struct` / `owned struct` / `extern
  interface` decls. VS Code layers this on top of the TextMate grammar
  so colours track the parser, not a regex. `range` lets the editor
  highlight only the visible viewport on large files; `full/delta`
  ships only the changed quintuples between edits. Locals/parameters
  fall back to `variable`; method-receiver and type-resolved
  highlighting are out of scope for this MVP.
- "Explain Diagnostic Code" command (`Cmd/Ctrl+Shift+E`) for direct
  lookup by code.
- **Status bar item** that displays the detected `zpp` version (or a
  hint when `zpp` is not on `PATH`) whenever a `.zpp` file is active.
  Click it to jump straight to the docs.
- **"Open Docs" command** (`zigpp.openDocs`, `Cmd/Ctrl+Shift+D`) opens
  the [Zig++ docs site](https://nktkt.github.io/zigpp-lang/) in your
  browser.
- Bracket matching, auto-closing pairs, and word-pattern tuned for Zig
  identifiers.

## Requirements

You need both of these on your `PATH`:

- `zpp` — the Zig++ CLI (built with `zig build` from the project root, then
  symlink `zig-out/bin/zpp` somewhere on `PATH`).
- `zpp-lsp` — the LSP server (also produced by `zig build`, found at
  `zig-out/bin/zpp-lsp`).

If they're installed elsewhere, override `zigpp.lsp.path` in your settings.

## Installation

### From a packaged `.vsix`

```sh
cd vscode
npm install
npm run compile
npx @vscode/vsce package
code --install-extension zigpp-0.1.0.vsix
```

### Development mode (recommended while iterating)

1. `cd vscode && npm install && npm run compile`
2. Open the `vscode/` folder in VS Code.
3. Press `F5` to launch an Extension Development Host with the extension
   loaded. Open any `.zpp` file from `examples/` to verify highlighting and
   LSP startup.

## Settings

| Setting | Default | Description |
| --- | --- | --- |
| `zigpp.lsp.path` | `"zpp-lsp"` | Path to the `zpp-lsp` executable. |
| `zigpp.formatter.enable` | `true` | Enable formatting via the language server. |

## Commands

| Command | Default keybinding | Action |
| --- | --- | --- |
| `Zig++: Run Current File` (`zigpp.run`) | `Ctrl+F5` (`Cmd+F5` on macOS) | Run `zpp run` on the active document and stream output. |
| `Zig++: Show Lowered Zig` (`zigpp.lower`) | `Ctrl+Shift+L` (`Cmd+Shift+L` on macOS) | Run `zpp lower` and open the emitted Zig in a new editor. |
| `Zig++: Explain Diagnostic Code` (`zigpp.explain`) | `Ctrl+Shift+E` (`Cmd+Shift+E` on macOS) | Look up the long-form explanation for a `Z####` diagnostic. |
| `Zig++: Open Docs` (`zigpp.openDocs`) | `Ctrl+Shift+D` (`Cmd+Shift+D` on macOS) | Open the Zig++ docs site in your default browser. |

## Known limitations

- The LSP is intentionally MVP. It currently surfaces diagnostics from the
  `zpp` parser/sema and supports `textDocument/formatting`,
  `textDocument/hover`, `textDocument/documentSymbol` (Outline view), a
  context-free `textDocument/completion` (keywords + top-level decl names),
  same-file `textDocument/definition`, same-file
  `textDocument/typeDefinition` (param-binding -> decl of its type),
  same-file `textDocument/signatureHelp` (single SignatureInformation
  for the enclosing call's callee), same-file `textDocument/references`,
  `workspace/symbol` over open documents, same-file
  `textDocument/rename` (top-level decl names only),
  `textDocument/codeAction` (quick-fix `Explain Z####` per diagnostic
  for every code, plus `WorkspaceEdit` auto-fix entries for Z0010 and
  Z0040), and `textDocument/semanticTokens/{full,range,full/delta}`
  (full, viewport-restricted, and incremental highlighting).
  Cross-file go-to-definition, cross-file references, cross-file
  rename, rename of parameters / locals / method names,
  type-definition for locals / receivers, signature help for
  method-on-receiver calls and overloaded signatures, workspace
  search across un-opened files, context-aware completion,
  method-on-receiver navigation, and auto-fix code actions for the
  remaining diagnostic codes (Z0020, Z0021, Z0030, Z0050, Z0060) are
  not implemented yet.
- Semantic highlighting now ships from the LSP. The TextMate grammar
  remains as a fallback for clients that don't speak semantic tokens, for
  documents the LSP fails to lex, and for the brief window before the
  server connects — VS Code layers the LSP tokens on top automatically.
- The grammar uses a heuristic (PascalCase identifier) for type names. In
  rare cases this will mis-classify a constant named with PascalCase.

## Project links

- Top-level project README: [`../README.md`](../README.md)
- Language overview: [`../LANGUAGE.md`](../LANGUAGE.md)
- Roadmap: [`../ROADMAP.md`](../ROADMAP.md)

## License

MIT, matching the parent project.
