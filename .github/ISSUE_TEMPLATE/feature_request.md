---
name: Feature request
about: Propose a new language construct, lowering rule, or tooling addition
title: "[feature] "
labels: enhancement
---

## Proposal

<!-- One paragraph: what construct or behaviour you want. -->

## Visibility check

Zig++ adds **visible** abstractions on top of Zig. Before proposing,
confirm the feature does not introduce:

- [ ] hidden allocations
- [ ] hidden control flow (exceptions, implicit dispatch, hidden coercions)
- [ ] implicit destructors
- [ ] silent type or lifetime conversions

If your proposal does any of these, explain why the trade-off is worth
breaking the doctrine in [MANIFESTO.md](../MANIFESTO.md).

## Syntax sketch

```zigpp
// what the user writes
```

## Lowering rule

```zig
// what the compiler emits
```

## Use cases

<!-- 2-3 concrete situations where this helps. -->

## Alternatives considered

<!-- Other ways to solve the same problem, and why they're worse. -->

## Notes

<!-- Anything else: prior art in other languages, references. -->
