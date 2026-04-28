# Security policy

## Supported versions

Zig++ is pre-alpha. Only the latest tagged release receives security
fixes. There is no LTS line.

| Version    | Supported          |
| ---------- | ------------------ |
| latest tag | yes                |
| anything else | no              |

## Reporting a vulnerability

**Do not open a public issue for security problems.** Use GitHub's
[private vulnerability reporting](https://github.com/nktkt/zigpp-lang/security/advisories/new)
instead. Reports are read by the maintainers privately and we will
acknowledge within 7 days.

In your report, please include:

- the affected version (`git rev-parse HEAD` or release tag)
- a minimal reproduction (`.zpp` snippet, command, expected vs. actual)
- the impact you believe it has
- any suggested fix or mitigation

## Scope

Zig++ is a research compiler frontend that lowers `.zpp` to `.zig`.
We treat the following as in-scope:

- compiler crashes triggered by malformed input (parser/sema/lowerer)
- generated `.zig` that does not match the documented lowering rules
- runtime behaviour in `lib/zpp.zig` that violates the doctrine
  ([no hidden allocations / control flow / destructors](MANIFESTO.md))
- the LSP server (`zpp-lsp`) accepting malformed JSON-RPC

The following are **out of scope** for security reports (open a regular
issue instead):

- bugs in the upstream Zig compiler
- bugs in third-party VS Code extensions
- the example programs themselves having intentional pre/post-condition
  failures

## Disclosure

Once a fix is shipped in a tagged release, the advisory will be
published with credit to the reporter (unless they request anonymity).

## Cryptographic signing

Releases are not yet GPG-signed. This is tracked in the roadmap.
