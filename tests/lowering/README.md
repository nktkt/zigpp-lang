# Lowering snapshots

Each `.zpp` under `inputs/` is lowered through `compiler.compileToString` and
compared against the matching `.zig` under `snapshots/`. Drift between the
lowerer and the checked-in snapshot is a test failure — see
`snapshots.zig` for the runner.

## Add a new case

1. Drop your fixture at `tests/lowering/inputs/<name>.zpp`.
2. Add `"<name>"` to the `cases` array and a matching `test "snapshot: <name>"`
   block in `snapshots.zig`.
3. Generate the snapshot:

   ```sh
   ZPP_UPDATE_SNAPSHOTS=1 zig build test
   ```

4. Inspect `tests/lowering/snapshots/<name>.zig`. If it looks correct, commit
   both the input and the snapshot together.

## Update an existing snapshot

Only do this when the change in lowered output is **intentional** (a lowerer
fix or a deliberate codegen change). Run:

```sh
ZPP_UPDATE_SNAPSHOTS=1 zig build test
```

Then `git diff tests/lowering/snapshots/` to review every byte that moved
before committing. Treat any diff you cannot explain as a regression.

## CI behavior

`.github/workflows/ci.yml` runs `zig build test` without setting
`ZPP_UPDATE_SNAPSHOTS`. The runner defaults to compare-and-fail mode, so any
drift between the lowerer and the checked-in snapshots fails CI on every
supported platform (Linux, macOS, Windows). On failure the runner prints a
capped unified-style diff naming the offending snapshot file and the env
var to use for an intentional refresh.

## Why drift matters

Lowering stability is part of the v1.0 promise (see ROADMAP Phase 8:
"Promise lowering stability for Zig 0.16.x"). Once a snapshot is checked
in, downstream consumers — formatters, doc tools, third-party build steps
that diff lowered output — depend on it. Silent drift erodes that promise,
so the gate is intentionally strict: every byte of the lowered output is
load-bearing until we explicitly say otherwise.
