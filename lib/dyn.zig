//! Explicit dynamic dispatch fat pointer used by lowered `dyn Trait` types.
//!
//! There is no global "registry" of impls; every `Dyn(VT)` is constructed at
//! the call site (typically through `fromImpl`, which builds the vtable at
//! comptime and stashes it in a `static const`). This keeps dispatch zero-
//! overhead beyond the indirect call and lets the compiler inline the vtable
//! pointer when the type is known.

const std = @import("std");
const trait = @import("traits.zig");

/// Fat pointer pairing an erased instance with its vtable.
pub fn Dyn(comptime VT: type) type {
    return struct {
        const Self = @This();
        pub const Table = VT;

        ptr: *anyopaque,
        vtable: *const VT,

        pub fn init(comptime T: type, value: *T, vt: *const VT) Self {
            return .{ .ptr = @ptrCast(value), .vtable = vt };
        }

        /// Recover a typed pointer. UB if `T` is not the original concrete type.
        pub fn cast(self: Self, comptime T: type) *T {
            return @ptrCast(@alignCast(self.ptr));
        }

        pub fn vtableField(self: Self, comptime name: []const u8) FieldType(VT, name) {
            return @field(self.vtable, name);
        }

        /// Build a `Dyn` from a concrete value. The vtable is materialized
        /// once at comptime per `(VT, T, methods)` triple.
        pub fn from(comptime T: type, value: *T, comptime methods: anytype) Self {
            return fromImpl(VT, T, value, methods);
        }
    };
}

/// Convenience for the common "I have a `*T` and want a `Dyn(VT)` filled from
/// T's methods" path. The vtable is built once at comptime and stored as a
/// `static const`.
pub fn fromImpl(
    comptime VT: type,
    comptime T: type,
    value: *T,
    comptime methods: anytype,
) Dyn(VT) {
    const vt = comptime trait.implFor(VT, T, methods);
    const Static = struct {
        const table: VT = vt;
    };
    return Dyn(VT).init(T, value, &Static.table);
}

/// `into(VT, &impl_struct, &my_value)` for cases where the trait impl is a
/// pre-existing struct of fn pointers (e.g. produced by another module).
pub fn into(
    comptime VT: type,
    vt: *const VT,
    value: anytype,
) Dyn(VT) {
    const T = @typeInfo(@TypeOf(value)).pointer.child;
    return Dyn(VT).init(T, value, vt);
}

fn FieldType(comptime S: type, comptime name: []const u8) type {
    inline for (@typeInfo(S).@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return f.type;
    }
    @compileError("no such field: " ++ name);
}

const Counter = struct {
    n: u32 = 0,
    fn inc(self: *Counter) void {
        self.n += 1;
    }
    fn read(self: *Counter) u32 {
        return self.n;
    }
    fn addN(self: *Counter, by: u32) u32 {
        self.n += by;
        return self.n;
    }
};

const CounterVT = trait.VTableOf(.{
    .{ "inc", *const fn (*anyopaque) void },
    .{ "read", *const fn (*anyopaque) u32 },
    .{ "addN", *const fn (*anyopaque, u32) u32 },
});

fn makeCounterDyn(c: *Counter) Dyn(CounterVT) {
    return Dyn(CounterVT).from(Counter, c, .{
        .{ "inc", Counter.inc },
        .{ "read", Counter.read },
        .{ "addN", Counter.addN },
    });
}

test "Dyn forwards calls through the vtable" {
    var c = Counter{};
    const d = makeCounterDyn(&c);
    d.vtable.inc(d.ptr);
    d.vtable.inc(d.ptr);
    d.vtable.inc(d.ptr);
    try std.testing.expectEqual(@as(u32, 3), d.vtable.read(d.ptr));
    const r = d.vtable.addN(d.ptr, 7);
    try std.testing.expectEqual(@as(u32, 10), r);
}

test "Dyn.cast recovers the concrete pointer" {
    var c = Counter{ .n = 7 };
    const d = makeCounterDyn(&c);
    const back = d.cast(Counter);
    try std.testing.expectEqual(@as(u32, 7), back.n);
    back.n = 99;
    try std.testing.expectEqual(@as(u32, 99), d.vtable.read(d.ptr));
}

test "Dyn.into wires a pre-built vtable" {
    const StaticVT = struct {
        const inc_thunk = struct {
            fn f(p: *anyopaque) void {
                const c: *Counter = @ptrCast(@alignCast(p));
                c.n +%= 2;
            }
        }.f;
        const read_thunk = struct {
            fn f(p: *anyopaque) u32 {
                const c: *Counter = @ptrCast(@alignCast(p));
                return c.n;
            }
        }.f;
        const add_thunk = struct {
            fn f(p: *anyopaque, by: u32) u32 {
                const c: *Counter = @ptrCast(@alignCast(p));
                c.n += by;
                return c.n;
            }
        }.f;
        const table: CounterVT = .{
            .inc = &inc_thunk,
            .read = &read_thunk,
            .addN = &add_thunk,
        };
    };
    var c = Counter{ .n = 0 };
    const d = into(CounterVT, &StaticVT.table, &c);
    d.vtable.inc(d.ptr);
    try std.testing.expectEqual(@as(u32, 2), d.vtable.read(d.ptr));
}

test "vtableField returns the requested method pointer" {
    var c = Counter{};
    const d = makeCounterDyn(&c);
    const inc_fn = d.vtableField("inc");
    inc_fn(d.ptr);
    inc_fn(d.ptr);
    try std.testing.expectEqual(@as(u32, 2), c.n);
}
