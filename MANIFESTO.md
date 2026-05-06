# Zig++ Manifesto

## What Zig++ is, in one sentence

Zig++ is a research language that adds **named, visible, lowerable** high-level
abstractions on top of Zig 0.16.x without giving up Zig's "no hidden control
flow, no hidden allocations" doctrine.

## What Zig++ is not

Zig++ deliberately does not add the following. Each rejection is non-negotiable
for the MVP and is paired with its reason in the next section.

- No implicit constructors or destructors. RAII is spelled `using`.
- No exceptions. Errors remain Zig error unions.
- No multiple inheritance. Composition + traits only.
- No operator overloading in MVP. Method calls are calls.
- No implicit allocators. Allocators are explicit parameters or fields.
- No macros, no preprocessor, no `#define`. `comptime` is enough.
- No hidden vtables. Dynamic dispatch goes through a spelled `dyn Trait`.
- No implicit conversions. No coercion ladder beyond what Zig already has.
- No GC, no reference counting in the core language.
- No reflection at runtime beyond what Zig's `@typeInfo` already provides.

## Visibility doctrine

Every cost a program incurs must be visible at the call site or binding site.

| Cost                | Spelled                                       |
|---------------------|-----------------------------------------------|
| Allocation          | An `Allocator` parameter or field             |
| Dynamic dispatch    | `dyn Trait` parameter type                    |
| RAII / cleanup      | `using` binding (lowers to `var` + `defer`)   |
| Ownership move      | `own var` declaration plus `move expr`        |
| Async / suspend     | An async I/O parameter (Zig 0.16+ I/O model)  |
| Unsafe primitive    | `@as`, `@ptrCast`, `extern`, etc., unchanged  |
| Effect class        | `effects(.noalloc, .noio, .nopanic, ...)`     |

If you cannot see one of these in source, it is not happening. The compiler is
not allowed to insert one. Lowerings are pure rewrites; they never introduce a
hidden version of a cost listed above.

## Why these rejections

Zig's most valuable property is that *the source is the lower bound on what the
program does*. You can read a function and know what control flow, what
allocation, and what dispatch will occur. Every rejection above protects that
property.

- **Implicit ctors/dtors** would make scopes do work that is not spelled in the
  scope. RAII is fine; *implicit* RAII is not. We keep RAII but require a
  binder keyword (`using`) so the cleanup is visible at the binding site.
- **Exceptions** would introduce hidden non-local control flow. Error unions
  already give us recoverable failure with a spelled `try`.
- **Multiple inheritance** drags in linearization, vtable layout choices, and
  the diamond problem. Traits compose without inheriting state.
- **Operator overloading** would make `a + b` a function call we cannot grep
  for. Methods solve the same problem and are greppable.
- **Implicit allocators** would re-introduce the pre-Zig world. Explicit
  allocator parameters are the single most important Zig invariant.
- **Macros** would let users defeat every other rule by string-rewriting
  source. `comptime` covers the legitimate use cases.
- **Hidden vtables** are how C++ and Java make dispatch feel free. We require
  `dyn Trait` to mark every dynamic call site.
- **Implicit conversions** are how silent integer truncation and lifetime bugs
  arrive in C++. Zig already refuses; Zig++ refuses harder.
- **GC / refcounting** are pervasive runtime features that turn every store
  into a potential cost. Out of scope for a systems language.
- **Runtime reflection** would force the compiler to emit type metadata for
  values that did not ask for it. `@typeInfo` at comptime is enough.

## When to use Zig vs Zig++

Use Zig when you want the smallest possible toolchain footprint, when you are
writing OS / firmware / kernel code where every keyword needs an audit trail,
or when your team already has Zig fluency.

Use Zig++ when you have a domain that benefits from named abstractions:
plugin hosts that need `dyn Trait`, libraries with many resource types that
benefit from `using`, code that wants contract checks at module boundaries,
or applications where effect annotations would catch real bugs (allocations
in render loops, panics in real-time threads).

Zig++ should always feel like Zig with extra grammar, never like a different
language. Any `.zig` file is a valid `.zpp` file (modulo new keywords).

## What we borrow from C++, Rust, Swift, OCaml

| Idea                          | Source        | Zig++ form                                    |
|-------------------------------|---------------|-----------------------------------------------|
| RAII                          | C++           | `using x = ...;` lowers to `defer x.deinit()` |
| Trait-based polymorphism      | Rust          | `trait T { ... }` + `impl T for S`            |
| Move semantics                | C++ / Rust    | `own var` + `move expr`, sema-checked         |
| Existential dispatch          | Rust / Swift  | `dyn Trait` fat pointer                       |
| Structured concurrency        | Swift         | `TaskGroup` over Zig 0.16 I/O                 |
| Effect annotations            | OCaml / Koka  | `effects(.noalloc, .noio, .nopanic)`          |
| Contracts                     | Eiffel / Ada  | `requires`/`ensures`/`invariant`              |
| Derive macros (typed!)        | Rust          | `derive(.{ .Hash, .Eq })` over comptime       |
| Module / package manifest     | Rust          | Reuses `build.zig.zon`                        |

What we do **not** borrow:

- C++'s implicit copy ctors, conversion operators, exceptions, or templates.
- Rust's borrow checker (we ship a much simpler move checker, no lifetimes).
- Swift's ARC and class hierarchies.
- OCaml's GC, modules-with-types, or functors-as-values.

The principle is: borrow the *idea*, then re-spell it in Zig style — explicit,
allocator-first, no hidden cost.
