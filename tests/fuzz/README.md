# zpp fuzz harness

Stress-tests the zpp compiler frontend
(`compiler.compileToString` + `compiler.parseAndAnalyze`)
with three input strategies, chosen at random per iteration:

- **60% smart generator** (`grammar.zig`) — synthesizes plausible Zig++
  source from a tiny grammar (traits, impls, owned/const structs, fns,
  with random `effects` / `requires` / `ensures` / `derive` attributes
  and intentional keyword-collision identifiers).
- **30% mutator** (`mutator.zig`) — applies one of `byte_flip` /
  `splice` / `delete_chunk` / `duplicate_chunk` / `insert_keyword` to
  each of `examples/*.zpp` plus a hand-rolled adversarial corpus of
  truncated decls.
- **10% random bytes** — biased toward ascii-printable plus structural
  characters.

Each input is fed to both pipeline entry points; any returned `error`
is fine. A panic, a memory leak (caught by the GPA's safety mode), or
a wall-clock budget overrun (>1s after the call returns) is written
to `tests/fuzz/crashes/crash_<label>_<seed>_<iter>.zpp` and the run
continues.

## Run

```bash
# default 1000 iterations, random seed
zig build fuzz

# fixed seed for reproducibility
zig build fuzz -- --seed=42

# more iterations
ZPP_FUZZ_ITERS=10000 zig build fuzz
```

Crashes land under `tests/fuzz/crashes/` (gitignore-worthy).
Reproduce a crash by running the saved input through the CLI:

```bash
./zig-out/bin/zpp lower tests/fuzz/crashes/crash_timeout_42_137.zpp
```

The fuzz step is opt-in and is **not** wired into `zig build test`.
