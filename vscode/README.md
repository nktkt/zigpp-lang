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
- "Run current file" command that shells out to `zpp run` and streams output
  to the Zig++ output channel.
- "Show lowered Zig" command that opens the result of `zpp lower` in a new
  untitled `.zig` editor so you can see exactly what the compiler emits.
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

## Known limitations

- The LSP is intentionally MVP. It currently surfaces diagnostics from the
  `zpp` parser/sema and supports `textDocument/formatting`. Hover, go-to-
  definition, completion, and rename are not implemented yet.
- Semantic highlighting falls back to the TextMate grammar — there's no
  semantic-tokens server response yet.
- The grammar uses a heuristic (PascalCase identifier) for type names. In
  rare cases this will mis-classify a constant named with PascalCase.

## Project links

- Top-level project README: [`../README.md`](../README.md)
- Language overview: [`../LANGUAGE.md`](../LANGUAGE.md)
- Roadmap: [`../ROADMAP.md`](../ROADMAP.md)

## License

MIT, matching the parent project.
