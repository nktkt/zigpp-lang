//! Ownership / RAII helpers backing `own`, `using`, and `move` lowering.

const std = @import("std");
const builtin = @import("builtin");

const safety_on = switch (builtin.mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseFast, .ReleaseSmall => false,
};

const State = enum(u8) { live, taken, dead };

/// Runtime-checked wrapper that asserts a value is consumed exactly once.
/// In `ReleaseFast`/`ReleaseSmall` the state byte is still stored but
/// `deinit` does not panic on un-consumed values.
pub fn Owned(comptime T: type) type {
    return struct {
        const Self = @This();

        value: T,
        state: State = .live,

        pub fn wrap(value: T) Self {
            return .{ .value = value, .state = .live };
        }

        pub fn take(self: *Self) T {
            if (safety_on and self.state != .live) {
                @panic("Owned.take on already-consumed value");
            }
            const out = self.value;
            self.state = .taken;
            return out;
        }

        pub fn borrow(self: *Self) *T {
            if (safety_on and self.state != .live) {
                @panic("Owned.borrow on consumed value");
            }
            return &self.value;
        }

        pub fn isLive(self: *const Self) bool {
            return self.state == .live;
        }

        /// Asserts the value was taken. Call from a `defer` site that the
        /// language lowering inserted to enforce single-consumption.
        pub fn deinit(self: *Self) void {
            if (safety_on and self.state == .live) {
                @panic("Owned value dropped without being consumed");
            }
            self.state = .dead;
        }
    };
}

/// Wraps an `ArenaAllocator` so lowered `using arena = ArenaScope.init(a)` can
/// use the `defer arena.deinit()` pattern uniformly.
pub const ArenaScope = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init(parent: std.mem.Allocator) ArenaScope {
        return .{ .arena = std.heap.ArenaAllocator.init(parent) };
    }

    pub fn allocator(self: *ArenaScope) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn reset(self: *ArenaScope) void {
        _ = self.arena.reset(.retain_capacity);
    }

    pub fn deinit(self: *ArenaScope) void {
        self.arena.deinit();
    }
};

/// Ad-hoc RAII: `var g = DeinitGuard.init(&obj, Obj.close); defer g.run();`
pub const DeinitGuard = struct {
    ctx: ?*anyopaque,
    func: *const fn (*anyopaque) void,
    fired: bool = false,

    pub fn init(ctx: anytype, comptime f: anytype) DeinitGuard {
        const Ctx = @TypeOf(ctx);
        const ctx_info = @typeInfo(Ctx);
        if (ctx_info != .pointer) @compileError("DeinitGuard.init expects a pointer");
        const T = ctx_info.pointer.child;
        const thunk = struct {
            fn call(p: *anyopaque) void {
                const self: *T = @ptrCast(@alignCast(p));
                f(self);
            }
        }.call;
        return .{ .ctx = @ptrCast(ctx), .func = thunk };
    }

    pub fn dismiss(self: *DeinitGuard) void {
        self.fired = true;
    }

    pub fn run(self: *DeinitGuard) void {
        if (self.fired) return;
        self.fired = true;
        if (self.ctx) |p| self.func(p);
    }

    pub fn deinit(self: *DeinitGuard) void {
        self.run();
    }
};

/// Move helper. Reads `ptr.*`, returns it, and overwrites the source with
/// `undefined` in safe builds so any subsequent use trips a use-after-move.
pub fn takeOwnership(ptr: anytype) @TypeOf(ptr.*) {
    const out = ptr.*;
    if (safety_on) {
        ptr.* = undefined;
    }
    return out;
}

const Resource = struct {
    closed: *bool,
    fn close(self: *Resource) void {
        self.closed.* = true;
    }
};

test "ArenaScope frees on deinit and serves allocations" {
    var scope = ArenaScope.init(std.testing.allocator);
    defer scope.deinit();
    const a = scope.allocator();
    const buf = try a.alloc(u8, 64);
    @memset(buf, 0xAB);
    try std.testing.expectEqual(@as(u8, 0xAB), buf[0]);
}

test "DeinitGuard fires once and respects dismiss" {
    var closed = false;
    var r = Resource{ .closed = &closed };
    var g = DeinitGuard.init(&r, Resource.close);
    g.run();
    try std.testing.expect(closed);
    closed = false;
    g.run();
    try std.testing.expect(!closed);

    var r2 = Resource{ .closed = &closed };
    var g2 = DeinitGuard.init(&r2, Resource.close);
    g2.dismiss();
    g2.run();
    try std.testing.expect(!closed);
}

test "Owned.take consumes once" {
    var o = Owned(u32).wrap(42);
    const v = o.take();
    try std.testing.expectEqual(@as(u32, 42), v);
    o.deinit();
    try std.testing.expect(!o.isLive());
}

test "takeOwnership returns the value" {
    var x: u32 = 7;
    const moved = takeOwnership(&x);
    try std.testing.expectEqual(@as(u32, 7), moved);
}
