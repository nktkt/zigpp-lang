import * as vscode from 'vscode';
import * as cp from 'child_process';
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
  TransportKind,
} from 'vscode-languageclient/node';

const DOCS_URL = 'https://nktkt.github.io/zigpp-lang/';

let client: LanguageClient | undefined;
let outputChannel: vscode.OutputChannel | undefined;
let statusBarItem: vscode.StatusBarItem | undefined;
let zppVersion: string | undefined;
let zppVersionResolved = false;

function getOutputChannel(): vscode.OutputChannel {
  if (!outputChannel) {
    outputChannel = vscode.window.createOutputChannel('Zig++');
  }
  return outputChannel;
}

function readLspPath(): string {
  const config = vscode.workspace.getConfiguration('zigpp');
  const path = config.get<string>('lsp.path');
  return path && path.length > 0 ? path : 'zpp-lsp';
}

async function startLanguageClient(context: vscode.ExtensionContext): Promise<void> {
  const command = readLspPath();

  const serverOptions: ServerOptions = {
    run: {
      command,
      args: [],
      transport: TransportKind.stdio,
    },
    debug: {
      command,
      args: [],
      transport: TransportKind.stdio,
    },
  };

  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: 'file', language: 'zigpp' }],
    synchronize: {
      fileEvents: vscode.workspace.createFileSystemWatcher('**/*.zpp'),
      configurationSection: 'zigpp',
    },
    outputChannel: getOutputChannel(),
  };

  client = new LanguageClient(
    'zigpp',
    'Zig++ Language Server',
    serverOptions,
    clientOptions
  );

  try {
    await client.start();
    context.subscriptions.push({
      dispose: () => {
        if (client) {
          void client.stop();
        }
      },
    });
  } catch (err) {
    const message =
      err instanceof Error ? err.message : String(err);
    void vscode.window.showErrorMessage(
      `Zig++: failed to start '${command}'. ${message} ` +
        `Make sure 'zpp-lsp' is on your PATH or set 'zigpp.lsp.path'. ` +
        `See the extension README for setup instructions.`
    );
  }
}

function runZppCommand(
  subcommand: 'run' | 'lower' | 'explain',
  arg: string,
  onStdout: (chunk: string) => void,
  onStderr: (chunk: string) => void,
  onExit: (code: number | null) => void
): void {
  const proc = cp.spawn('zpp', [subcommand, arg], {
    cwd: vscode.workspace.workspaceFolders?.[0]?.uri.fsPath,
  });

  proc.stdout.setEncoding('utf8');
  proc.stderr.setEncoding('utf8');
  proc.stdout.on('data', (data: string) => onStdout(data));
  proc.stderr.on('data', (data: string) => onStderr(data));
  proc.on('error', (err: Error) => {
    void vscode.window.showErrorMessage(
      `Zig++: failed to spawn 'zpp'. ${err.message} ` +
        `Make sure 'zpp' is on your PATH. See the extension README.`
    );
  });
  proc.on('exit', (code) => onExit(code));
}

function registerCommands(context: vscode.ExtensionContext): void {
  const runCommand = vscode.commands.registerCommand('zigpp.run', () => {
    const editor = vscode.window.activeTextEditor;
    if (!editor || editor.document.languageId !== 'zigpp') {
      void vscode.window.showWarningMessage(
        'Zig++: open a .zpp file before running this command.'
      );
      return;
    }

    const channel = getOutputChannel();
    channel.show(true);
    channel.appendLine(`> zpp run ${editor.document.fileName}`);

    runZppCommand(
      'run',
      editor.document.fileName,
      (chunk) => channel.append(chunk),
      (chunk) => channel.append(chunk),
      (code) => channel.appendLine(`\n[zpp run exited with code ${code ?? 'null'}]`)
    );
  });

  const lowerCommand = vscode.commands.registerCommand('zigpp.lower', () => {
    const editor = vscode.window.activeTextEditor;
    if (!editor || editor.document.languageId !== 'zigpp') {
      void vscode.window.showWarningMessage(
        'Zig++: open a .zpp file before running this command.'
      );
      return;
    }

    const channel = getOutputChannel();
    let stdout = '';
    let stderr = '';

    channel.appendLine(`> zpp lower ${editor.document.fileName}`);

    runZppCommand(
      'lower',
      editor.document.fileName,
      (chunk) => {
        stdout += chunk;
      },
      (chunk) => {
        stderr += chunk;
        channel.append(chunk);
      },
      async (code) => {
        if (code !== 0) {
          channel.show(true);
          channel.appendLine(
            `\n[zpp lower exited with code ${code ?? 'null'}]`
          );
          if (stderr.length === 0) {
            void vscode.window.showErrorMessage(
              `Zig++: 'zpp lower' failed with exit code ${code ?? 'null'}.`
            );
          }
          return;
        }
        try {
          const doc = await vscode.workspace.openTextDocument({
            language: 'zig',
            content: stdout,
          });
          await vscode.window.showTextDocument(doc, { preview: false });
        } catch (err) {
          const message =
            err instanceof Error ? err.message : String(err);
          void vscode.window.showErrorMessage(
            `Zig++: failed to open lowered Zig output: ${message}`
          );
        }
      }
    );
  });

  const openDocsCommand = vscode.commands.registerCommand(
    'zigpp.openDocs',
    () => {
      void vscode.env.openExternal(vscode.Uri.parse(DOCS_URL));
    }
  );

  const explainCommand = vscode.commands.registerCommand(
    'zigpp.explain',
    async (presupplied?: string) => {
      // If invoked with a code already (e.g. from the QuickFix code action),
      // skip the prompt entirely.
      let arg = presupplied;
      if (!arg) {
        // Try to pre-fill from a diagnostic at the active cursor position.
        let initial: string | undefined;
        const editor = vscode.window.activeTextEditor;
        if (editor) {
          const diags = vscode.languages.getDiagnostics(editor.document.uri);
          const pos = editor.selection.active;
          for (const d of diags) {
            if (!d.range.contains(pos)) continue;
            const code =
              typeof d.code === 'string'
                ? d.code
                : typeof d.code === 'object' && d.code !== null
                  ? String((d.code as { value: unknown }).value)
                  : undefined;
            if (code) {
              initial = code;
              break;
            }
          }
        }

        arg = await vscode.window.showInputBox({
          prompt: 'Diagnostic code (e.g. Z0010)',
          value: initial,
          validateInput: (v) =>
            /^[Zz]\d{4}$/.test(v.trim())
              ? null
              : 'Expected a Z#### code (e.g. Z0010)',
        });
      }
      if (!arg) return;

      const channel = getOutputChannel();
      channel.show(true);
      channel.appendLine(`> zpp explain ${arg}`);

      runZppCommand(
        'explain',
        arg.trim(),
        (chunk) => channel.append(chunk),
        (chunk) => channel.append(chunk),
        (code) => {
          if (code !== 0 && code !== null) {
            channel.appendLine(
              `\n[zpp explain exited with code ${code}]`
            );
          }
        }
      );
    }
  );

  // zpp.runActiveFile — spawn `zpp run <activeFilePath>` in a dedicated
  // integrated terminal so the user gets a real TTY (colored output,
  // interactive stdin) rather than a passive output-channel stream.
  const runActiveFileCommand = vscode.commands.registerCommand(
    'zpp.runActiveFile',
    () => {
      const editor = vscode.window.activeTextEditor;
      if (!editor) {
        void vscode.window.showWarningMessage(
          'Zig++: no active editor — open a .zpp file first.'
        );
        return;
      }
      const filePath = editor.document.uri.fsPath;
      if (!filePath) {
        void vscode.window.showWarningMessage(
          'Zig++: the active editor has no file path on disk yet.'
        );
        return;
      }
      const terminalName = 'Zig++ Run';
      const existing = vscode.window.terminals.find(
        (t) => t.name === terminalName
      );
      const terminal = existing ?? vscode.window.createTerminal(terminalName);
      terminal.show(true);
      // Quote the path so spaces/special chars survive the shell.
      terminal.sendText(`zpp run "${filePath}"`);
    }
  );

  // zpp.explainAtCursor — find the diagnostic whose range contains the
  // cursor, extract its Z#### code, run `zpp explain <code>`, and surface
  // the rendered explanation to the user. Unlike the existing
  // `zigpp.explain` command this one is non-interactive: if there is no
  // diagnostic under the cursor we just show a friendly information
  // message instead of prompting for a code.
  const explainAtCursorCommand = vscode.commands.registerCommand(
    'zpp.explainAtCursor',
    () => {
      const editor = vscode.window.activeTextEditor;
      if (!editor) {
        void vscode.window.showInformationMessage(
          'Zig++: no active editor.'
        );
        return;
      }
      const cursor = editor.selection.active;
      const diags = vscode.languages.getDiagnostics(editor.document.uri);
      const hit = diags.find((d) => d.range.contains(cursor));
      if (!hit) {
        void vscode.window.showInformationMessage(
          'Zig++: no diagnostic at the cursor.'
        );
        return;
      }
      const code =
        typeof hit.code === 'string'
          ? hit.code
          : typeof hit.code === 'object' && hit.code !== null
            ? String((hit.code as { value: unknown }).value)
            : undefined;
      if (!code || !/^Z\d{4}$/i.test(code)) {
        void vscode.window.showInformationMessage(
          'Zig++: the diagnostic at the cursor has no Z#### code.'
        );
        return;
      }

      const channel = getOutputChannel();
      channel.show(true);
      channel.appendLine(`> zpp explain ${code}`);

      let stdout = '';
      runZppCommand(
        'explain',
        code,
        (chunk) => {
          stdout += chunk;
          channel.append(chunk);
        },
        (chunk) => channel.append(chunk),
        (exitCode) => {
          if (exitCode !== 0 && exitCode !== null) {
            channel.appendLine(
              `\n[zpp explain exited with code ${exitCode}]`
            );
            return;
          }
          // Show a compact one-shot toast with the first line of the
          // explanation so the user sees something even if they don't
          // glance at the output channel.
          const firstLine = stdout.split(/\r?\n/)[0]?.trim();
          if (firstLine && firstLine.length > 0) {
            void vscode.window.showInformationMessage(
              `Zig++ ${code}: ${firstLine}`
            );
          }
        }
      );
    }
  );

  context.subscriptions.push(
    runCommand,
    lowerCommand,
    explainCommand,
    openDocsCommand,
    runActiveFileCommand,
    explainAtCursorCommand
  );
}

/**
 * Spawn `zpp version` once and cache the trimmed first-line output.
 * Resolves to undefined if the binary is not on PATH or exits non-zero.
 */
function detectZppVersion(): Promise<string | undefined> {
  return new Promise((resolve) => {
    let stdout = '';
    let settled = false;
    const finish = (value: string | undefined): void => {
      if (settled) return;
      settled = true;
      resolve(value);
    };
    try {
      const proc = cp.spawn('zpp', ['version'], {
        cwd: vscode.workspace.workspaceFolders?.[0]?.uri.fsPath,
      });
      proc.stdout.setEncoding('utf8');
      proc.stdout.on('data', (chunk: string) => {
        stdout += chunk;
      });
      proc.on('error', () => finish(undefined));
      proc.on('exit', (code) => {
        if (code !== 0) {
          finish(undefined);
          return;
        }
        const first = stdout.split(/\r?\n/)[0]?.trim();
        finish(first && first.length > 0 ? first : undefined);
      });
    } catch {
      finish(undefined);
    }
  });
}

function updateStatusBarVisibility(): void {
  if (!statusBarItem) return;
  const editor = vscode.window.activeTextEditor;
  if (editor && editor.document.languageId === 'zigpp') {
    statusBarItem.show();
  } else {
    statusBarItem.hide();
  }
}

function applyVersionToStatusBar(): void {
  if (!statusBarItem) return;
  if (zppVersion) {
    statusBarItem.text = `Zig++ ${zppVersion}`;
    statusBarItem.tooltip = `Zig++ ${zppVersion} — click to open the docs site.`;
  } else {
    statusBarItem.text = 'Zig++ (zpp not found)';
    statusBarItem.tooltip =
      "Couldn't run 'zpp version'. Make sure the 'zpp' binary is on your PATH " +
      "(build with 'zig build' and symlink 'zig-out/bin/zpp'). " +
      'Click to open the docs site.';
  }
}

async function setupStatusBar(
  context: vscode.ExtensionContext
): Promise<void> {
  statusBarItem = vscode.window.createStatusBarItem(
    vscode.StatusBarAlignment.Right,
    100
  );
  statusBarItem.command = 'zigpp.openDocs';
  statusBarItem.text = 'Zig++';
  statusBarItem.tooltip = 'Zig++ — detecting zpp version…';
  context.subscriptions.push(statusBarItem);
  context.subscriptions.push(
    vscode.window.onDidChangeActiveTextEditor(() =>
      updateStatusBarVisibility()
    )
  );
  updateStatusBarVisibility();

  if (!zppVersionResolved) {
    zppVersionResolved = true;
    zppVersion = await detectZppVersion();
  }
  applyVersionToStatusBar();
  updateStatusBarVisibility();
}

/**
 * Code action: when the cursor is on a Zig++ diagnostic with a Z####
 * code, offer "Zig++: Explain Z####" as a quick-fix that runs the
 * existing zigpp.explain command.
 */
class ExplainCodeActionProvider implements vscode.CodeActionProvider {
  public static readonly providedKinds = [vscode.CodeActionKind.QuickFix];

  public provideCodeActions(
    document: vscode.TextDocument,
    range: vscode.Range | vscode.Selection,
    context: vscode.CodeActionContext
  ): vscode.CodeAction[] {
    const actions: vscode.CodeAction[] = [];
    for (const d of context.diagnostics) {
      const code =
        typeof d.code === 'string'
          ? d.code
          : typeof d.code === 'object' && d.code !== null
            ? String((d.code as { value: unknown }).value)
            : undefined;
      if (!code || !/^Z\d{4}$/i.test(code)) continue;
      const action = new vscode.CodeAction(
        `Zig++: Explain ${code}`,
        vscode.CodeActionKind.QuickFix
      );
      action.command = {
        title: `Zig++: Explain ${code}`,
        command: 'zigpp.explain',
        arguments: [code],
      };
      action.diagnostics = [d];
      actions.push(action);
    }
    // Suppress unused-parameter warning in strict mode.
    void document;
    void range;
    return actions;
  }
}

export async function activate(
  context: vscode.ExtensionContext
): Promise<void> {
  registerCommands(context);
  context.subscriptions.push(
    vscode.languages.registerCodeActionsProvider(
      { scheme: 'file', language: 'zigpp' },
      new ExplainCodeActionProvider(),
      { providedCodeActionKinds: ExplainCodeActionProvider.providedKinds }
    )
  );
  void setupStatusBar(context);
  await startLanguageClient(context);
}

export async function deactivate(): Promise<void> {
  statusBarItem = undefined;
  if (!client) {
    return;
  }
  try {
    await client.stop();
  } catch {
    // best-effort shutdown
  } finally {
    client = undefined;
  }
}
