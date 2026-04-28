---
name: Bug report
about: Report a compiler crash, wrong lowering, or unexpected diagnostic
title: "[bug] "
labels: bug
---

## What happened

<!-- One paragraph: what you ran, what you expected, what you got. -->

## Minimal reproduction

A `.zpp` snippet that triggers the bug. Smaller is better — try to
reduce to the smallest input that still reproduces. The fuzz harness
already shrinks; if you have a crash file from `tests/fuzz/crashes/`,
attach it.

```zigpp
// your snippet here
```

## Steps

```sh
# what you ran, exactly
zpp lower bug.zpp
```

## Output

```
# the actual stdout/stderr, including any diagnostic + hint
```

## Environment

- Zig++ commit / tag: `vX.Y.Z` or `git rev-parse HEAD`
- Zig version: `zig version`
- OS / arch: ubuntu-22.04 x86_64 / macos-14 aarch64 / etc.

## Notes

<!-- Anything else: what you tried, what you suspect, related issues. -->
