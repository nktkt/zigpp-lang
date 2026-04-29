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
