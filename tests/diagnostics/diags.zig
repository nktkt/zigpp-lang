const std = @import("std");
const compiler = @import("zpp_compiler");

fn analyze(allocator: std.mem.Allocator, source: []const u8) !compiler.AnalysisResult {
    return compiler.parseAndAnalyze(allocator, source);
}

fn hasCode(diags: *const compiler.diagnostics.Diagnostics, code_id: []const u8) bool {
    for (diags.items.items) |d| {
        if (std.mem.eql(u8, d.code.id(), code_id)) return true;
    }
    return false;
}

test "Z0010: owned struct without deinit is rejected" {
    const a = std.testing.allocator;
    const src = "owned struct S { x: u32 }";
    var result = try analyze(a, src);
    defer result.diags.deinit();
    try std.testing.expect(hasCode(&result.diags, "Z0010"));
}

test "Z0001: impl of unknown trait is rejected" {
    const a = std.testing.allocator;
    const src = "fn f(x: impl Unknown) void { _ = x; }";
    var result = try analyze(a, src);
    defer result.diags.deinit();
    try std.testing.expect(hasCode(&result.diags, "Z0001"));
}

test "Z0020: use after move" {
    const a = std.testing.allocator;
    const src =
        \\fn run() void {
        \\    own var a = 1;
        \\    const b = move a;
        \\    const c = a;
        \\    _ = b;
        \\    _ = c;
        \\}
    ;
    var result = try analyze(a, src);
    defer result.diags.deinit();
    try std.testing.expect(hasCode(&result.diags, "Z0020"));
}

test "Z0021: move while borrowed (positive)" {
    const a = std.testing.allocator;
    const src =
        \\fn run() void {
        \\    own var x = Person{ .name = "Ada" };
        \\    const r = &x.name;
        \\    const y = move x;
        \\    _ = r;
        \\    _ = y;
        \\}
    ;
    var result = try analyze(a, src);
    defer result.diags.deinit();
    try std.testing.expect(hasCode(&result.diags, "Z0021"));
}

test "Z0021: same code without borrow does not fire" {
    const a = std.testing.allocator;
    const src =
        \\fn run() void {
        \\    own var x = Person{ .name = "Ada" };
        \\    const r = x.name;
        \\    const y = move x;
        \\    _ = r;
        \\    _ = y;
        \\}
    ;
    var result = try analyze(a, src);
    defer result.diags.deinit();
    try std.testing.expect(!hasCode(&result.diags, "Z0021"));
}

test "Z0021: borrow inside a block does not invalidate move after the block" {
    // Round-2 scope tracking: a `&x` recorded inside `{ ... }` retires
    // when execution leaves the block. The subsequent `move x` therefore
    // must not fire Z0021.
    const a = std.testing.allocator;
    const src =
        \\fn run() void {
        \\    own var x = Person{ .name = "Ada" };
        \\    {
        \\        const r = &x.name;
        \\        _ = r;
        \\    }
        \\    const y = move x;
        \\    _ = y;
        \\}
    ;
    var result = try analyze(a, src);
    defer result.diags.deinit();
    try std.testing.expect(!hasCode(&result.diags, "Z0021"));
}

test "Z0021: two borrows on same name still trigger one Z0021" {
    // Round-2 multi-borrow tracking: appending a second `&x` must not
    // duplicate the diagnostic. We expect exactly one Z0021 for the
    // following `move x`.
    const a = std.testing.allocator;
    const src =
        \\fn run() void {
        \\    own var x = Person{ .name = "Ada" };
        \\    const r1 = &x.name;
        \\    const r2 = &x.name;
        \\    const y = move x;
        \\    _ = r1;
        \\    _ = r2;
        \\    _ = y;
        \\}
    ;
    var result = try analyze(a, src);
    defer result.diags.deinit();
    try std.testing.expect(hasCode(&result.diags, "Z0021"));
    var z0021_count: usize = 0;
    for (result.diags.items.items) |d| {
        if (std.mem.eql(u8, d.code.id(), "Z0021")) z0021_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), z0021_count);
}

test "Z0021: borrow and move in different fns do not collide" {
    const a = std.testing.allocator;
    const src =
        \\fn borrowOnly() void {
        \\    var x = Person{ .name = "Ada" };
        \\    const r = &x.name;
        \\    _ = r;
        \\}
        \\fn moveOnly() void {
        \\    own var x = Person{ .name = "Ada" };
        \\    const y = move x;
        \\    _ = y;
        \\}
    ;
    var result = try analyze(a, src);
    defer result.diags.deinit();
    try std.testing.expect(!hasCode(&result.diags, "Z0021"));
}

test "Z0030: noalloc effect violated by allocator call" {
    const a = std.testing.allocator;
    const src =
        \\effects(.noalloc) fn f(allocator: std.mem.Allocator) !void {
        \\    const xs = try allocator.alloc(u8, 16);
        \\    _ = xs;
        \\}
    ;
    var result = try analyze(a, src);
    defer result.diags.deinit();
    try std.testing.expect(hasCode(&result.diags, "Z0030"));
}

test "Z0040: impl missing trait method" {
    const a = std.testing.allocator;
    const src =
        \\trait Greeter {
        \\    fn greet(self) void;
        \\    fn farewell(self) void;
        \\}
        \\const Friendly = struct { name: []const u8 };
        \\impl Greeter for Friendly {
        \\    fn greet(self) void { _ = self; }
        \\}
    ;
    var result = try analyze(a, src);
    defer result.diags.deinit();
    try std.testing.expect(hasCode(&result.diags, "Z0040"));
}

test "Z0002: structural trait impl missing methods on target type" {
    // `Greeter` is structural, so the `impl` block is allowed to omit the
    // `farewell` method (no Z0040). However the `greet` method LISTED in
    // the impl does not exist on `Friendly` — Z0002 must fire.
    const a = std.testing.allocator;
    const src =
        \\trait Greeter : structural {
        \\    fn greet(self) void;
        \\    fn farewell(self) void;
        \\}
        \\const Friendly = struct { name: []const u8 };
        \\impl Greeter for Friendly {
        \\    fn greet(self) void { _ = self; }
        \\}
    ;
    var result = try analyze(a, src);
    defer result.diags.deinit();
    try std.testing.expect(hasCode(&result.diags, "Z0002"));
    // Structural relaxation: Z0040 (missing trait method) must NOT fire.
    try std.testing.expect(!hasCode(&result.diags, "Z0040"));
}

test "Z0002: structural impl with matching method on type does not fire" {
    // Same shape but the struct now declares `greet` directly. The impl
    // block re-exports a method that exists, and the trait is structural,
    // so neither Z0002 nor Z0040 should fire.
    const a = std.testing.allocator;
    const src =
        \\trait Greeter : structural {
        \\    fn greet(self) void;
        \\    fn farewell(self) void;
        \\}
        \\const Friendly = struct {
        \\    name: []const u8,
        \\    pub fn greet(self: *@This()) void { _ = self; }
        \\};
        \\impl Greeter for Friendly {
        \\    fn greet(self) void { _ = self; }
        \\}
    ;
    var result = try analyze(a, src);
    defer result.diags.deinit();
    try std.testing.expect(!hasCode(&result.diags, "Z0002"));
    try std.testing.expect(!hasCode(&result.diags, "Z0040"));
}

test "Z0002: structural trait without an impl block is fine" {
    // Structural traits can be satisfied with no `impl` at all. The
    // analyzer must not emit anything in that case.
    const a = std.testing.allocator;
    const src =
        \\trait Greeter : structural {
        \\    fn greet(self) void;
        \\}
        \\const Friendly = struct {
        \\    name: []const u8,
        \\    pub fn greet(self: *@This()) void { _ = self; }
        \\};
    ;
    var result = try analyze(a, src);
    defer result.diags.deinit();
    try std.testing.expect(!hasCode(&result.diags, "Z0002"));
    try std.testing.expect(!hasCode(&result.diags, "Z0040"));
}

test "Z0040: complete impl produces no diagnostic" {
    const a = std.testing.allocator;
    const src =
        \\trait Greeter {
        \\    fn greet(self) void;
        \\}
        \\const Friendly = struct { name: []const u8 };
        \\impl Greeter for Friendly {
        \\    fn greet(self) void { _ = self; }
        \\}
    ;
    var result = try analyze(a, src);
    defer result.diags.deinit();
    try std.testing.expect(!hasCode(&result.diags, "Z0040"));
}

test "Z0040: omitting a default-bodied method does not fire" {
    // The trait supplies a default body for `farewell`, so the impl is
    // free to skip it. Only `greet` is required and the impl provides it,
    // so Z0040 must stay silent.
    const a = std.testing.allocator;
    const src =
        \\trait Greeter {
        \\    fn greet(self) void;
        \\    fn farewell(self) void {
        \\        // default body — fine to omit in impls
        \\    }
        \\}
        \\const Friendly = struct { name: []const u8 };
        \\impl Greeter for Friendly {
        \\    fn greet(self) void { _ = self; }
        \\}
    ;
    var result = try analyze(a, src);
    defer result.diags.deinit();
    try std.testing.expect(!hasCode(&result.diags, "Z0040"));
}

test "Z0040: missing a non-default method still fires when defaults exist" {
    // Mixing: `farewell` has a default and may be skipped, but `greet`
    // is required and the impl drops it — Z0040 must still fire.
    const a = std.testing.allocator;
    const src =
        \\trait Greeter {
        \\    fn greet(self) void;
        \\    fn farewell(self) void {}
        \\}
        \\const Friendly = struct { name: []const u8 };
        \\impl Greeter for Friendly {
        \\    fn farewell(self) void { _ = self; }
        \\}
    ;
    var result = try analyze(a, src);
    defer result.diags.deinit();
    try std.testing.expect(hasCode(&result.diags, "Z0040"));
}

// --- Z0030 effect inference (MVP) ---

test "Z0030: noalloc annotation matches inference does not fire" {
    // `pure` declares .noalloc and never calls .alloc/.create/.realloc/.dupe,
    // and its only callee `add` is itself .noalloc. Inference agrees with
    // the annotation, so Z0030 must not fire.
    const a = std.testing.allocator;
    const src =
        \\fn add(x: i32, y: i32) i32 { return x + y; }
        \\effects(.noalloc) fn pure(x: i32, y: i32) i32 {
        \\    const z = add(x, y);
        \\    return z * 2;
        \\}
    ;
    var result = try analyze(a, src);
    defer result.diags.deinit();
    try std.testing.expect(!hasCode(&result.diags, "Z0030"));
}

test "Z0030: noalloc fn that transitively allocates fires once" {
    // `wrapper` declares .noalloc but calls `inner`, whose body literally
    // contains `.alloc(`. Inference propagates `.alloc` from `inner` up to
    // `wrapper`, so Z0030 must fire on `wrapper` (transitive case). It must
    // NOT fire on `inner` itself because `inner` does not declare .noalloc.
    // We further check that the diagnostic appears exactly once.
    const a = std.testing.allocator;
    const src =
        \\fn inner(allocator: std.mem.Allocator) ![]u8 {
        \\    const xs = try allocator.alloc(u8, 4);
        \\    return xs;
        \\}
        \\effects(.noalloc) fn wrapper(allocator: std.mem.Allocator) ![]u8 {
        \\    return try inner(allocator);
        \\}
    ;
    var result = try analyze(a, src);
    defer result.diags.deinit();
    try std.testing.expect(hasCode(&result.diags, "Z0030"));
    var z0030_count: usize = 0;
    for (result.diags.items.items) |d| {
        if (std.mem.eql(u8, d.code.id(), "Z0030")) z0030_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), z0030_count);
}

// --- Z0030 .io effect inference (round 2) ---

test "Z0030: noio annotation matches inference does not fire" {
    // `helper` is a pure arithmetic fn and `quiet` only calls it. Neither
    // touches the IO heuristic substrings, so inference agrees with the
    // `.noio` annotation and Z0030 must not fire.
    const a = std.testing.allocator;
    const src =
        \\fn helper(x: i32) i32 { return x + 1; }
        \\effects(.noio) fn quiet(x: i32) i32 {
        \\    return helper(x) * 2;
        \\}
    ;
    var result = try analyze(a, src);
    defer result.diags.deinit();
    try std.testing.expect(!hasCode(&result.diags, "Z0030"));
}

test "Z0030: noio fn that does IO fires" {
    // `noisy` declares .noio but the body literally contains
    // `std.debug.print`, which is in the IO heuristic. Z0030 must fire.
    const a = std.testing.allocator;
    const src =
        \\effects(.noio) fn noisy() void {
        \\    std.debug.print("hi\n", .{});
        \\}
    ;
    var result = try analyze(a, src);
    defer result.diags.deinit();
    try std.testing.expect(hasCode(&result.diags, "Z0030"));
}

test "Z0030: nopanic annotation matches inference does not fire" {
    // `helper` is a pure arithmetic fn and `safe` only calls it. Neither
    // body contains any of the panic heuristic substrings, so inference
    // agrees with the `.nopanic` annotation and Z0030 must not fire.
    const a = std.testing.allocator;
    const src =
        \\fn helper(x: i32) i32 { return x + 1; }
        \\effects(.nopanic) fn safe(x: i32) i32 {
        \\    return helper(x) * 2;
        \\}
    ;
    var result = try analyze(a, src);
    defer result.diags.deinit();
    try std.testing.expect(!hasCode(&result.diags, "Z0030"));
}

test "Z0030: nopanic fn that panics fires" {
    // `boom` declares .nopanic but the body literally contains
    // `@panic(`, which is in the panic heuristic. Z0030 must fire.
    const a = std.testing.allocator;
    const src =
        \\effects(.nopanic) fn boom() void {
        \\    @panic("nope");
        \\}
    ;
    var result = try analyze(a, src);
    defer result.diags.deinit();
    try std.testing.expect(hasCode(&result.diags, "Z0030"));
}

test "Z0030: noasync annotation matches inference does not fire" {
    // `arith` is pure arithmetic and `quiet` only calls it. Neither body
    // contains any of the async heuristic substrings, so inference agrees
    // with the `.noasync` annotation and Z0030 must not fire.
    const a = std.testing.allocator;
    const src =
        \\fn arith(x: i32) i32 { return x + 1; }
        \\effects(.noasync) fn quiet(x: i32) i32 {
        \\    return arith(x) * 2;
        \\}
    ;
    var result = try analyze(a, src);
    defer result.diags.deinit();
    try std.testing.expect(!hasCode(&result.diags, "Z0030"));
}

test "Z0030: noasync fn that spawns a thread fires" {
    // `racy` declares .noasync but the body literally contains
    // `std.Thread.spawn`, which is in the async heuristic. Z0030 must fire.
    const a = std.testing.allocator;
    const src =
        \\const std = @import("std");
        \\effects(.noasync) fn racy() !void {
        \\    const t = try std.Thread.spawn(.{}, work, .{});
        \\    t.join();
        \\}
        \\fn work() void {}
    ;
    var result = try analyze(a, src);
    defer result.diags.deinit();
    try std.testing.expect(hasCode(&result.diags, "Z0030"));
}

test "Z0030: noasync fn that transitively spawns fires" {
    // `outer` declares .noasync but calls `inner`, whose body uses
    // `TaskGroup` from the async heuristic. Z0030 must fire on `outer`.
    // It must NOT fire on `inner` itself because `inner` does not
    // declare .noasync.
    const a = std.testing.allocator;
    const src =
        \\const std = @import("std");
        \\const zpp = @import("zpp");
        \\fn inner(allocator: std.mem.Allocator) !void {
        \\    var group = zpp.async_mod.TaskGroup.init(allocator);
        \\    defer group.deinit();
        \\    try group.join();
        \\}
        \\effects(.noasync) fn outer(allocator: std.mem.Allocator) !void {
        \\    try inner(allocator);
        \\}
    ;
    var result = try analyze(a, src);
    defer result.diags.deinit();
    try std.testing.expect(hasCode(&result.diags, "Z0030"));
    var z0030_count: usize = 0;
    for (result.diags.items.items) |d| {
        if (std.mem.eql(u8, d.code.id(), "Z0030")) z0030_count += 1;
    }
    // Only the `.noasync` violation on `outer` — `inner` does not
    // declare any denial so its inferred `.async` is fine.
    try std.testing.expectEqual(@as(usize, 1), z0030_count);
}

test "@effectsOf(spawner) surfaces async after panic" {
    // A fn that uses `TaskGroup` (the async heuristic) lowers to
    // `"async"`. The join order is alloc/io/panic/async — async sits
    // after the three classic axes and before any `custom("X")` trailers.
    const a = std.testing.allocator;
    var diags = compiler.Diagnostics.init(a);
    defer diags.deinit();
    const src =
        \\const std = @import("std");
        \\const zpp = @import("zpp");
        \\fn spawner(allocator: std.mem.Allocator) !void {
        \\    var g = zpp.async_mod.TaskGroup.init(allocator);
        \\    defer g.deinit();
        \\    try g.join();
        \\}
        \\fn ask() []const u8 { return @effectsOf(spawner); }
    ;
    const out = try compiler.compileToZig(a, src, &diags);
    defer a.free(out);
    try std.testing.expect(!hasCode(&diags, "Z0050"));
    try std.testing.expect(std.mem.indexOf(u8, out, "return \"async\";") != null);
}

test "@effectsOf joins async after alloc/io/panic" {
    // A fn that allocates, prints (io), and spawns a thread (async)
    // produces `"alloc,io,async"` — async appears after panic in the
    // fixed join order and before any `custom("X")` trailers.
    const a = std.testing.allocator;
    var diags = compiler.Diagnostics.init(a);
    defer diags.deinit();
    const src =
        \\const std = @import("std");
        \\fn busy(al: std.mem.Allocator) !void {
        \\    const xs = try al.alloc(u8, 1);
        \\    _ = xs;
        \\    std.debug.print("hi\n", .{});
        \\    const t = try std.Thread.spawn(.{}, work, .{});
        \\    t.join();
        \\}
        \\fn work() void {}
        \\fn ask() []const u8 { return @effectsOf(busy); }
    ;
    const out = try compiler.compileToZig(a, src, &diags);
    defer a.free(out);
    try std.testing.expect(!hasCode(&diags, "Z0050"));
    try std.testing.expect(std.mem.indexOf(u8, out, "return \"alloc,io,async\";") != null);
}

test "@effectsOf(pure) lowers to empty string" {
    // Pure fn → @effectsOf(pure) substitutes to the literal `""`.
    // Driving `compileToZig` exercises the end-to-end lowering path
    // (sema → table → lowerer rewrite) the way real callers see it.
    const a = std.testing.allocator;
    var diags = compiler.Diagnostics.init(a);
    defer diags.deinit();
    const src =
        \\fn pure() void {}
        \\fn ask() []const u8 { return @effectsOf(pure); }
    ;
    const out = try compiler.compileToZig(a, src, &diags);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "return \"\";") != null);
    try std.testing.expect(!hasCode(&diags, "Z0050"));
}

test "@effectsOf(allocOnly) lowers to \"alloc\"" {
    // `allocOnly` calls `.alloc(` directly so sema records `.alloc`.
    // The substitution must therefore become the literal `"alloc"`.
    const a = std.testing.allocator;
    var diags = compiler.Diagnostics.init(a);
    defer diags.deinit();
    const src =
        \\const std = @import("std");
        \\fn allocOnly(a: std.mem.Allocator) !void {
        \\    const xs = try a.alloc(u8, 1);
        \\    _ = xs;
        \\}
        \\fn ask() []const u8 { return @effectsOf(allocOnly); }
    ;
    const out = try compiler.compileToZig(a, src, &diags);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "return \"alloc\";") != null);
    try std.testing.expect(!hasCode(&diags, "Z0050"));
}

test "Z0050: @effectsOf of an unknown fn fires and lowers to empty" {
    // `unknown_fn` is not declared in this file. Sema/lowering still
    // produces the empty-string substitution so callers compile, but
    // emits Z0050 so the user knows the answer was synthesised.
    const a = std.testing.allocator;
    var diags = compiler.Diagnostics.init(a);
    defer diags.deinit();
    const src =
        \\fn ask() []const u8 { return @effectsOf(unknown_fn); }
    ;
    const out = try compiler.compileToZig(a, src, &diags);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "return \"\";") != null);
    try std.testing.expect(hasCode(&diags, "Z0050"));
}

// --- Z0060 .custom("name") effect inference (round 5) ---

test "Z0060: nocustom matches declared custom does not fire" {
    // `caller` declares effects(.custom("net")) and calls `worker` which
    // also declares effects(.custom("net")). Inference agrees with the
    // declaration; no Z0060.
    const a = std.testing.allocator;
    const src =
        \\effects(.custom("net")) fn worker() void {}
        \\effects(.custom("net")) fn caller() void { worker(); }
    ;
    var result = try analyze(a, src);
    defer result.diags.deinit();
    try std.testing.expect(!hasCode(&result.diags, "Z0060"));
}

test "Z0060: nocustom violated by transitive custom callee fires" {
    // `caller` declares .nocustom("net") but calls `worker` which declares
    // .custom("net"). Inference propagates .custom("net") up to caller,
    // contradicting the .nocustom annotation, so Z0060 must fire on caller.
    const a = std.testing.allocator;
    const src =
        \\effects(.custom("net")) fn worker() void {}
        \\effects(.nocustom("net")) fn caller() void { worker(); }
    ;
    var result = try analyze(a, src);
    defer result.diags.deinit();
    try std.testing.expect(hasCode(&result.diags, "Z0060"));
}

test "@effectsOf surfaces a custom-effect-only fn as custom(\"net\")" {
    // Round-5 follow-up: `@effectsOf(<ident>)` now appends each
    // inferred `.custom("X")` name after the alloc/io/panic axes.
    // A fn whose only effect is `.custom("net")` therefore lowers to
    // `"custom(\"net\")"` (the inner `"` is escaped because the
    // substitution itself sits inside a Zig double-quoted string
    // literal). No Z0050 fires — sema knows about the fn.
    const a = std.testing.allocator;
    var diags = compiler.Diagnostics.init(a);
    defer diags.deinit();
    const src =
        \\effects(.custom("net")) fn worker() void {}
        \\fn ask() []const u8 { return @effectsOf(worker); }
    ;
    const out = try compiler.compileToZig(a, src, &diags);
    defer a.free(out);
    try std.testing.expect(!hasCode(&diags, "Z0050"));
    try std.testing.expect(std.mem.indexOf(u8, out, "return \"custom(\\\"net\\\")\";") != null);
}

test "@effectsOf appends custom(\"net\") after alloc when both are inferred" {
    // A fn that both allocates AND declares `.custom("net")` lowers to
    // `"alloc,custom(\"net\")"` — the custom entries trail the
    // alloc/io/panic axes so existing consumers that only inspect the
    // axes prefix keep working unchanged.
    const a = std.testing.allocator;
    var diags = compiler.Diagnostics.init(a);
    defer diags.deinit();
    const src =
        \\const std = @import("std");
        \\effects(.custom("net")) fn worker(al: std.mem.Allocator) !void {
        \\    const xs = try al.alloc(u8, 1);
        \\    _ = xs;
        \\}
        \\fn ask() []const u8 { return @effectsOf(worker); }
    ;
    const out = try compiler.compileToZig(a, src, &diags);
    defer a.free(out);
    try std.testing.expect(!hasCode(&diags, "Z0050"));
    try std.testing.expect(std.mem.indexOf(u8, out, "return \"alloc,custom(\\\"net\\\")\";") != null);
}

// --- Lexer / parser / using-deinit codes (Z0011, Z0102, Z0200, Z0201) ---
//
// These four codes were defined in `compiler/diagnostics.zig` (with hint
// + explanation text) but had no diagnostic-test coverage. Each test
// below asserts the code fires for a minimal known-bad input. The
// remaining reserved codes Z0100 / Z0101 / Z0103 / Z0300 are enum
// variants with no emit site in the current compiler source — they are
// intentionally not exercised here.

test "Z0011: using over an owned struct lacking deinit" {
    // The type is registered as `owned struct` but has no `deinit`
    // method, so the `using` binding has nothing to auto-release. Z0010
    // fires for the missing-deinit struct itself; Z0011 fires at the
    // `using` site.
    const a = std.testing.allocator;
    const src =
        \\owned struct Plain { x: u32 }
        \\fn run() void {
        \\    using p = Plain{ .x = 1 };
        \\    _ = p;
        \\}
    ;
    var result = try analyze(a, src);
    defer result.diags.deinit();
    try std.testing.expect(hasCode(&result.diags, "Z0011"));
}

test "Z0102: `own` without `var` or `const`" {
    // `own` requires either `var` or `const` after it. Without one the
    // parser emits Z0102 ("expected 'var' or 'const' after 'own'") and
    // synchronizes to the next top-level decl.
    const a = std.testing.allocator;
    const src =
        \\fn run() void {
        \\    own x = 1;
        \\}
    ;
    var result = try analyze(a, src);
    defer result.diags.deinit();
    try std.testing.expect(hasCode(&result.diags, "Z0102"));
}

test "Z0102: well-formed `own var` does not fire" {
    const a = std.testing.allocator;
    const src =
        \\fn run() void {
        \\    own var x = 1;
        \\    _ = x;
        \\}
    ;
    var result = try analyze(a, src);
    defer result.diags.deinit();
    try std.testing.expect(!hasCode(&result.diags, "Z0102"));
}

test "Z0200: stray `$` is rejected as invalid character" {
    // `$` is not punctuation, not whitespace, not an identifier start,
    // and not a digit, so the lexer falls through to the invalid-char
    // diagnostic.
    const a = std.testing.allocator;
    const src =
        \\fn run() void {
        \\    var x = $;
        \\    _ = x;
        \\}
    ;
    var result = try analyze(a, src);
    defer result.diags.deinit();
    try std.testing.expect(hasCode(&result.diags, "Z0200"));
}

test "Z0201: unterminated single-line string literal" {
    // A `"` with no matching closer before end-of-line emits Z0201 and
    // yields an invalid token; the parser continues past it.
    const a = std.testing.allocator;
    const src =
        \\const s = "abc;
        \\
    ;
    var result = try analyze(a, src);
    defer result.diags.deinit();
    try std.testing.expect(hasCode(&result.diags, "Z0201"));
}

test "Z0201: closed single-line string does not fire" {
    const a = std.testing.allocator;
    const src =
        \\const s = "abc";
    ;
    var result = try analyze(a, src);
    defer result.diags.deinit();
    try std.testing.expect(!hasCode(&result.diags, "Z0201"));
}
