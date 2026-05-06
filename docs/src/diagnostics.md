# Diagnostics

Every Zig++ compile-time issue carries a stable code of the form
`Z####`. The compiler prints the code alongside the message, the LSP
attaches it to every diagnostic it surfaces, and the CLI exposes a
long-form description for each one:

```sh
zpp explain Z0010              # human-readable explanation + trigger + fix
zpp explain Z0010 --json       # same data as a JSON object (for IDE clients)
zpp explain --list             # one-line summary of every code
zpp help explain               # CLI help for the subcommand
```

Codes are stable. New codes are appended; numbers are never reused.
The IDE / LSP integration ships a "Explain Z####" code action on
every diagnostic, and a couple of codes additionally ship an
auto-applicable quick-fix (called out below).

## Quick reference

| Code  | Name                                                 | Axis                  |
| ----- | ---------------------------------------------------- | --------------------- |
| Z0001 | unknown trait                                        | Traits & `impl`       |
| Z0002 | structural trait method missing on type              | Traits & `impl`       |
| Z0010 | owned struct missing deinit                          | Ownership             |
| Z0011 | `using` target lacks deinit                         | Ownership             |
| Z0020 | use after move                                       | Move / borrow         |
| Z0021 | borrow invalidated by move                           | Move / borrow         |
| Z0030 | function violates declared effect                    | Effects               |
| Z0040 | impl is missing trait method(s)                      | Traits & `impl`       |
| Z0050 | `@effectsOf(f)` — fn not declared in this file       | Effects               |
| Z0060 | `.nocustom("X")` declared but inferred `.custom("X")` | Effects              |
| Z0100 | unexpected token                                     | Parsing (reserved)    |
| Z0101 | expected identifier                                  | Parsing (reserved)    |
| Z0102 | expected a specific token                            | Parsing               |
| Z0103 | unterminated block                                   | Parsing (reserved)    |
| Z0200 | invalid character in source                          | Lexing                |
| Z0201 | unterminated string literal                          | Lexing                |
| Z0300 | internal lowering error                              | Internal (reserved)   |

"Reserved" means the code is allocated and `zpp explain Z####`
already returns the canonical description, but the compiler does
not yet emit it from any call site — the parser/lexer currently
falls through to the more general `Z0102` / `Z0200` / `Z0201` for
those cases. The codes are kept reserved so future, more specific
diagnostics can land without renumbering.

## Traits and `impl`

### Z0001 — unknown trait

A trait name is referenced (`impl T for ...`, `dyn T`, `impl T`
parameter, `where U: T`) but no `trait T { ... }` declaration is in
scope. Traits must be declared before they are used.

```zig
fn dispatch(g: dyn Greeter) void { g.greet(); }   // Greeter undefined
```

Fix — declare the trait first:

```zig
trait Greeter { fn greet(self) void; }
fn dispatch(g: dyn Greeter) void { g.vtable.greet(g.ptr); }
```

Test: `tests/diagnostics/diags.zig`.

### Z0002 — structural trait method missing on type

Traits declared with `: structural` are satisfied by *matching method
shapes* on the target type — no explicit `impl` block is required.
When you do write `impl T for X { ... }` for a structural `T`, every
method named in the impl block must correspond to an existing method
on `X` (the impl block re-exports those methods through the trait's
vtable). Missing-from-the-trait methods are allowed (that's the whole
point of structural), but missing-from-the-type methods are not.

This is the dual of Z0040 — Z0040 fires when a *nominal* impl is
missing methods the trait requires; Z0002 fires when a *structural*
impl is missing methods on the type the impl wants to re-export.

```zig
trait Greeter : structural { fn greet(self) void; }
const Friendly = struct { name: []const u8 };
impl Greeter for Friendly {
    fn greet(self) void { _ = self; }   // Friendly has no greet → Z0002
}
```

Fix — add the listed method(s) to the struct definition, or drop the
impl block entirely (structural traits don't need one):

```zig
const Friendly = struct {
    name: []const u8,
    pub fn greet(self: *@This()) void { _ = self; }
};
// No impl block required — structural traits pick this up.
```

See: `examples/structural_trait.zpp` (compliant example),
`tests/diagnostics/diags.zig` (3 fixtures covering the trigger,
the matching-method case, and the no-impl case).

### Z0040 — impl is missing trait method(s)

An `impl Trait for Type { ... }` block must implement every method
declared on `trait Trait { ... }`. Sema cross-checks the two and
lists every method that is required by the trait but missing from
the impl.

```zig
trait Greeter { fn greet(self) void; fn farewell(self) void; }
impl Greeter for Friendly {
    fn greet(self) void {}
    // farewell is missing
}
```

Fix — add the missing methods, or remove the impl block if `Type`
does not need to satisfy `Greeter`.

The LSP ships an auto-applicable quick-fix for this code: it stubs
each missing method as
`pub fn <name>(self: *@This()) void { unreachable; }` so the impl
type-checks and you can fill the body in.

Test: `tests/diagnostics/diags.zig`.

## Ownership

### Z0010 — owned struct missing deinit

`owned struct` is a sema-checked promise that the type owns
resources that must be released. Every `owned struct` therefore
requires a `pub fn deinit(self: *@This()) void` method.

```zig
owned struct Buffer { data: []u8 }   // no deinit → Z0010
```

Fix — add a deinit, or drop the `owned` modifier if the type really
does not own anything that needs releasing:

```zig
owned struct Buffer {
    data: []u8,
    allocator: std.mem.Allocator,
    pub fn deinit(self: *Buffer) void {
        self.allocator.free(self.data);
    }
}
```

The LSP ships an auto-applicable quick-fix: it inserts a minimal
`pub fn deinit(self: *@This()) void { _ = self; }` stub before the
struct's closing `}` so the file type-checks while you write the
real cleanup.

See: `examples/owned_file.zpp` (compliant example),
`tests/diagnostics/diags.zig` (negative fixture).

### Z0011 — `using` target lacks deinit

`using x = expr;` lowers to `var x = expr; defer x.deinit();`. The
type of `expr` must therefore have a `deinit` method, otherwise the
generated `defer` would not type-check.

```zig
using s = "literal";   // []const u8 has no deinit → Z0011
```

Fix — use a plain `var` (no auto-cleanup) or give the source type a
`deinit` method.

## Move and borrow

### Z0020 — use after move

A binding declared with `own var` was consumed by `move x` and then
read again in the same scope. After `move`, the original name no
longer holds a valid value.

```zig
own var a = try Buffer.init(alloc);
const b = move a;
use(a);                 // a is moved — Z0020
```

Fix — read the new owner instead, or restructure so each owner is
read exactly once:

```zig
own var a = try Buffer.init(alloc);
const b = move a;
use(b);
```

Test: `tests/diagnostics/diags.zig`.

### Z0021 — borrow invalidated by move

A function-local borrow was taken (`&x` or `&x.field`) and then the
borrowed binding was consumed by `move x` while the borrow was
still in scope. After the move, the reference would dangle, so
sema rejects the move.

```zig
own var person = Person{ .name = "Ada" };
const r = &person.name;
const p = move person;     // r is still alive — Z0021
_ = r;
_ = p;
```

Fix — let the borrow end first:

```zig
own var person = Person{ .name = "Ada" };
{
    const r = &person.name;
    use(r);
}
const p = move person;     // OK, no live borrow
```

See: `examples/borrow_check.zpp`, `tests/diagnostics/diags.zig`.

## Effects

### Z0030 — function violates declared effect

A function annotated with a restrictive effect (`.noalloc`, `.noio`,
`.nopanic`, `.noasync`) calls — directly or transitively through a
same-file callee — something that violates the annotation. Sema
infers the effect set bottom-up and compares it against the
declaration.

```zig
effects(.noalloc) fn pure(a: Allocator) !void {
    const xs = try a.alloc(u8, 16);   // violates .noalloc → Z0030
    _ = xs;
}
```

The four axes use independent substring-based heuristics applied
to the lowered Zig (after stripping strings and comments):

- `.noalloc` flags `.alloc(`, `.create(`, `.realloc(`, `.dupe(`.
- `.noio` flags `std.debug.print`, `std.fs.`, `std.io.`,
  `std.process.`, `std.net.`, writer/reader I/O calls, etc.
- `.nopanic` flags `@panic(`, statement-form `unreachable`,
  `std.debug.assert(`, `std.debug.panic(`, `std.process.exit(`.
- `.noasync` flags I/O suspension points on the async axis.

Each axis additionally propagates one round through local same-file
callees — calling a function whose inferred set contains the
forbidden effect is itself a violation.

Fix — drop the offending operation, drop the annotation, or split
the function so the constrained part is genuinely free of the
effect.

See: `examples/effects_pure.zpp`, `examples/effects_nopanic_demo.zpp`,
`examples/effects_noasync.zpp`, `tests/diagnostics/diags.zig`.

### Z0050 — `@effectsOf(f)` — fn name not declared in this file

`@effectsOf(<ident>)` lowers to a comptime `[]const u8` listing the
effects sema inferred for `<ident>` (e.g. `"alloc,io"` or `""` for
pure). The lookup is restricted to functions declared in the same
`.zpp` file: top-level fns, `owned struct` / `struct` methods, and
`impl Trait for T` methods. Cross-file lookup, methods addressed
via `Type.method`, and indirect calls are out of scope for the MVP.

When the name doesn't match any local fn, the lowering still emits
an empty string `""` so the surrounding code keeps compiling, but
sema reports Z0050 so you know the queryable result is meaningless.

```zig
fn local() void {}
const set = @effectsOf(loccal);     // typo → Z0050
const ext = @effectsOf(std.fs.cwd); // not a same-file fn → Z0050
```

Fix — spell the name correctly, declare the fn in this file, or
drop the `@effectsOf` query until cross-file inference lands.

See: `examples/effects_of.zpp`, `tests/diagnostics/diags.zig`.

### Z0060 — `.nocustom("X")` declared but inferred `.custom("X")`

`effects(.custom("X"))` is a user-defined effect tag. A function
may both *declare* a custom effect (asserting it for sema and
callers) and *inherit* one transitively from a same-file callee
that declares the same name. `effects(.nocustom("X"))` is the
negation: it asserts the function does NOT have effect `X`. When
inference (declaration plus one round of callee propagation)
disagrees with that assertion, sema reports Z0060.

```zig
fn doIt() void effects(.custom("net")) { /* ... */ }
fn run()  void effects(.nocustom("net")) {
    doIt();   // caller forbids "net" but callee declares it → Z0060
}
```

Fix — drop the `.nocustom("X")` declaration on the caller, rename
one of the effects, or refactor the call chain so the custom
effect doesn't reach the caller.

Test: `tests/diagnostics/diags.zig`.

## Parsing

### Z0100 — unexpected token *(reserved)*

The parser was in the middle of a declaration or expression and the
next token did not fit any expected continuation. This code is
reserved for future, more specific parser diagnostics; the active
parser currently surfaces these cases via Z0102 with the expected
token name.

```zig
fn foo() void { 5 + ; }     // operator with no rhs
```

### Z0101 — expected identifier *(reserved)*

A name was required (function, struct, trait, parameter). Like
Z0100, this code is reserved for future specialization; today the
parser falls through to Z0102.

```zig
fn () void {}               // missing fn name
```

### Z0102 — expected a specific token

The parser needed a particular punctuation (`;`, `,`, `)`, `}`,
`=`, `:`, etc.) but found something else. The diagnostic message
includes the expected token.

```zig
fn foo() void { var x = 1 }   // missing `;` after `1` → Z0102
```

Fix — insert the expected token.

### Z0103 — unterminated block *(reserved)*

A `{` was opened but the file ended before the matching `}`.
Reserved for future specialization; today this case typically
surfaces as Z0102 with the expected `}`.

## Lexing

### Z0200 — invalid character in source

The lexer found a byte outside the printable ASCII / whitespace
set and outside any string literal. `.zpp` source must be valid
UTF-8; stray binary bytes are rejected.

Triggers: typically a stray BOM, a control character pasted from a
rich-text editor, or a corrupted file.

Fix — open the file in a hex editor or run `file` on it to see what
is actually inside; re-save as UTF-8.

### Z0201 — unterminated string literal

A `"` was opened but the file ended (or the line ended in a
non-multiline-string context) before the matching `"`.

```zig
const s = "hello world ;       // missing closing quote → Z0201
```

Fix — add the closing `"`. For multi-line content use Zig's `\\`
line-prefix form instead.

## Internal

### Z0300 — internal lowering error *(reserved)*

A compiler-bug guard. The lowering pass tried to emit something it
could not, and the failure has been reported as a diagnostic
rather than crashing. No call site emits this today; it exists so
that future graceful failures in `lower_to_zig.zig` have a stable
code to report.

If you see Z0300 in the wild, please file an issue at
<https://github.com/nktkt/zigpp-lang/issues> with the source that
triggered it. The fuzz harness (`zig build fuzz`) is a good way to
find more inputs in the same shape.

## Querying diagnostics from tooling

The `zpp explain Z#### --json` form returns the same data as a
single-line JSON object suitable for IDE consumption:

```json
{
  "code": "Z0010",
  "title": "owned struct missing deinit",
  "summary": "owned structs must release their resources explicitly. ...",
  "explain": "Z0010: owned struct missing deinit\n\n`owned struct` is ...",
  "examples": [
    { "kind": "trigger", "snippet": "owned struct Buffer { data: []u8 }   // no deinit" },
    { "kind": "fix",     "snippet": "owned struct Buffer {\n    data: []u8,\n    ..." }
  ]
}
```

Both `examples` entries are stable: every code has at least one
`trigger` snippet, and every code with a known fix has at least one
`fix` snippet.

## Adding a new diagnostic code

If you're adding a new sema check, see
[CONTRIBUTING.md → Diagnostic codes](https://github.com/nktkt/zigpp-lang/blob/main/CONTRIBUTING.md#diagnostic-codes)
for the assignment + hint convention. Once the code is allocated
in `compiler/diagnostics.zig` and the explain entry is written,
this page should be updated with the new entry under the
appropriate axis.
