const std = @import("std");
const compiler = @import("zpp_compiler");

test "@import(\"x.zpp\") rewrites to @import(\"x.zig\")" {
    const a = std.testing.allocator;
    const src =
        \\const std = @import("std");
        \\const lib = @import("lib.zpp");
        \\pub fn main() !void {
        \\    lib.shout("hi");
        \\}
    ;
    const out = try compiler.compileToString(a, src);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "@import(\"lib.zig\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "@import(\"lib.zpp\")") == null);
}

test "string-literal contents are not rewritten" {
    const a = std.testing.allocator;
    const src =
        \\const std = @import("std");
        \\pub fn main() !void {
        \\    std.debug.print("a path: hello.zpp\n", .{});
        \\}
    ;
    const out = try compiler.compileToString(a, src);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "hello.zpp") != null);
}

test "non-zpp imports are unchanged" {
    const a = std.testing.allocator;
    const src =
        \\const std = @import("std");
        \\const x = @import("foo.zig");
        \\const y = @import("bar.json");
    ;
    const out = try compiler.compileToString(a, src);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "@import(\"foo.zig\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "@import(\"bar.json\")") != null);
}
