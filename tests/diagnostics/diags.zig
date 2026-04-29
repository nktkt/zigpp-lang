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
