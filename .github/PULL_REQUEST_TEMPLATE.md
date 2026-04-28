<!--
Thanks for the PR. A few quick checks before merging:
-->

## Summary

<!-- One paragraph: what changed and why. -->

## Linked issue

<!-- `Fixes #N` or `Refs #N`. Delete if N/A. -->

## Changes

<!-- Bulleted list of the actual changes. -->

-

## Test plan

<!-- How you verified the change. The default suite is:
     `zig build test && zig build check && zig build e2e` -->

- [ ] `zig build test` passes
- [ ] `zig build check` passes (no new sema errors on examples)
- [ ] `zig build e2e` passes (lowered Zig still compiles + runs)
- [ ] If touching the parser/sema/lowerer: `ZPP_FUZZ_ITERS=2000 zig build fuzz` passes
- [ ] If adding a new diagnostic code: a `hint:` line is included

## Doctrine check

Zig++ doctrine ([MANIFESTO.md](../MANIFESTO.md)): no hidden allocations,
no hidden control flow, no implicit destructors, no exceptions.

- [ ] My change preserves the doctrine, OR
- [ ] My change deliberately deviates from the doctrine and the PR
      description explains why.
