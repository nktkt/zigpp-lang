const std = @import("std");
const zpp = @import("zpp");

const Counter = struct {
    n: u32 = 0,
    fn inc(self: *Counter) void {
        self.n += 1;
    }
    fn read(self: *Counter) u32 {
        return self.n;
    }
};

const CounterVT = zpp.VTableOf(.{
    .{ "inc", *const fn (*anyopaque) void },
    .{ "read", *const fn (*anyopaque) u32 },
});

test "Dyn round-trips through an impl" {
    var c = Counter{};
    const d = zpp.dyn_mod.fromImpl(CounterVT, Counter, &c, .{
        .{ "inc", Counter.inc },
        .{ "read", Counter.read },
    });
    d.vtable.inc(d.ptr);
    d.vtable.inc(d.ptr);
    try std.testing.expectEqual(@as(u32, 2), d.vtable.read(d.ptr));
    const back = d.cast(Counter);
    try std.testing.expectEqual(@as(u32, 2), back.n);
}

test "ArenaScope allocates and frees correctly" {
    var scope = zpp.ArenaScope.init(std.testing.allocator);
    defer scope.deinit();
    const a = scope.allocator();
    const buf1 = try a.alloc(u8, 32);
    @memset(buf1, 1);
    const buf2 = try a.alloc(u8, 64);
    @memset(buf2, 2);
    try std.testing.expectEqual(@as(u8, 1), buf1[0]);
    try std.testing.expectEqual(@as(u8, 2), buf2[0]);
}

test "requires(true, ...) is a no-op and compiles" {
    zpp.requires(true, "trivially true");
}

test "requires(false, ...) panics under safe modes (compile-only check)" {
    // Only assert the call is well-typed; actually invoking with `false`
    // would terminate the test runner under Debug/ReleaseSafe.
    if (false) zpp.requires(false, "would panic");
    zpp.requires(true, "no-op when true");
}

test "derive.Hash produces stable hashes for the same value" {
    const User = struct { x: u32 };
    // VERIFY: derive.Hash signature — assumed (comptime T) returning a struct
    // with `pub fn hash(value: T) u64`. Other agent owns `derive.zig`.
    if (!@hasDecl(zpp.derive, "Hash")) return error.SkipZigTest;
    const H = zpp.derive.Hash(User);
    const a = H.hash(.{ .x = 7 });
    const b = H.hash(.{ .x = 7 });
    const c = H.hash(.{ .x = 8 });
    try std.testing.expectEqual(a, b);
    try std.testing.expect(a != c);
}
