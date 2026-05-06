//! VTable construction helpers used by lowered `trait` / `dyn` declarations.

const std = @import("std");
const builtin = @import("builtin");

/// Build a vtable struct type from a tuple of `.{ "name", FnType }` entries.
/// Each FnType must be a function-pointer type whose first argument is `*anyopaque`.
pub fn VTableOf(comptime methods: anytype) type {
    const info = @typeInfo(@TypeOf(methods));
    if (info != .@"struct" or !info.@"struct".is_tuple) {
        @compileError("VTableOf expects a tuple of .{ name, FnType } pairs");
    }
    const entries = info.@"struct".fields;
    var fields: [entries.len]std.builtin.Type.StructField = undefined;
    for (entries, 0..) |_, i| {
        const pair = methods[i];
        const name: []const u8 = pair[0];
        const FnT: type = pair[1];
        validateMethodPointer(FnT, name);
        fields[i] = .{
            .name = name ++ "",
            .type = FnT,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(FnT),
        };
    }
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}

fn validateMethodPointer(comptime FnT: type, comptime name: []const u8) void {
    const info = @typeInfo(FnT);
    if (info != .pointer) {
        @compileError("trait method '" ++ name ++ "' must be a function pointer");
    }
    const child = info.pointer.child;
    const child_info = @typeInfo(child);
    if (child_info != .@"fn") {
        @compileError("trait method '" ++ name ++ "' must point to a function");
    }
    const params = child_info.@"fn".params;
    if (params.len == 0 or params[0].type != *anyopaque) {
        @compileError("trait method '" ++ name ++ "' must take *anyopaque as first arg");
    }
}

/// Construct a `VT` instance whose entries forward to `T`'s concrete methods.
/// `methods` is a tuple of `.{ "vtable_field_name", T_method_function }`.
pub fn implFor(comptime VT: type, comptime T: type, comptime methods: anytype) VT {
    const tuple_info = @typeInfo(@TypeOf(methods));
    if (tuple_info != .@"struct" or !tuple_info.@"struct".is_tuple) {
        @compileError("implFor expects a tuple of .{ name, fn } pairs");
    }
    var vt: VT = undefined;
    inline for (tuple_info.@"struct".fields, 0..) |_, i| {
        const pair = methods[i];
        const name: []const u8 = pair[0];
        const concrete = pair[1];
        if (!@hasField(VT, name)) {
            @compileError("vtable " ++ @typeName(VT) ++ " has no field '" ++ name ++ "'");
        }
        @field(vt, name) = comptime makeThunk(VT, T, name, concrete);
    }
    return vt;
}

/// Single generic forwarding path used by every thunk arity. Casts the type-erased
/// receiver to `*T`, splices it into a `std.meta.ArgsTuple` along with the extra
/// arguments captured by the thunk, and forwards via `@call`.
inline fn forwardCall(
    comptime T: type,
    comptime concrete: anytype,
    p: *anyopaque,
    extra: anytype,
) @typeInfo(@TypeOf(concrete)).@"fn".return_type.? {
    const self: *T = @ptrCast(@alignCast(p));
    var args: std.meta.ArgsTuple(@TypeOf(concrete)) = undefined;
    args[0] = self;
    inline for (0..extra.len) |i| {
        args[i + 1] = extra[i];
    }
    return @call(.always_inline, concrete, args);
}

fn makeThunk(
    comptime VT: type,
    comptime T: type,
    comptime field_name: []const u8,
    comptime concrete: anytype,
) FieldType(VT, field_name) {
    const FieldPtr = FieldType(VT, field_name);
    const fn_info = @typeInfo(@typeInfo(FieldPtr).pointer.child).@"fn";
    const ConcreteFn = @TypeOf(concrete);
    const concrete_info = @typeInfo(ConcreteFn).@"fn";
    if (concrete_info.params.len != fn_info.params.len) {
        @compileError("arity mismatch for vtable field '" ++ field_name ++ "'");
    }
    // Zig has no syntax to declare a function whose arity depends on a comptime
    // value, so each arity is hand-rolled below. Every arm shares the same body
    // via `forwardCall`, which uses `std.meta.ArgsTuple` + `@call` to forward
    // the receiver and the captured parameters to the concrete method.
    return switch (fn_info.params.len) {
        1 => &struct {
            fn thunk(p: *anyopaque) fn_info.return_type.? {
                return forwardCall(T, concrete, p, .{});
            }
        }.thunk,
        2 => &struct {
            fn thunk(
                p: *anyopaque,
                a0: fn_info.params[1].type.?,
            ) fn_info.return_type.? {
                return forwardCall(T, concrete, p, .{a0});
            }
        }.thunk,
        3 => &struct {
            fn thunk(
                p: *anyopaque,
                a0: fn_info.params[1].type.?,
                a1: fn_info.params[2].type.?,
            ) fn_info.return_type.? {
                return forwardCall(T, concrete, p, .{ a0, a1 });
            }
        }.thunk,
        4 => &struct {
            fn thunk(
                p: *anyopaque,
                a0: fn_info.params[1].type.?,
                a1: fn_info.params[2].type.?,
                a2: fn_info.params[3].type.?,
            ) fn_info.return_type.? {
                return forwardCall(T, concrete, p, .{ a0, a1, a2 });
            }
        }.thunk,
        5 => &struct {
            fn thunk(
                p: *anyopaque,
                a0: fn_info.params[1].type.?,
                a1: fn_info.params[2].type.?,
                a2: fn_info.params[3].type.?,
                a3: fn_info.params[4].type.?,
            ) fn_info.return_type.? {
                return forwardCall(T, concrete, p, .{ a0, a1, a2, a3 });
            }
        }.thunk,
        6 => &struct {
            fn thunk(
                p: *anyopaque,
                a0: fn_info.params[1].type.?,
                a1: fn_info.params[2].type.?,
                a2: fn_info.params[3].type.?,
                a3: fn_info.params[4].type.?,
                a4: fn_info.params[5].type.?,
            ) fn_info.return_type.? {
                return forwardCall(T, concrete, p, .{ a0, a1, a2, a3, a4 });
            }
        }.thunk,
        7 => &struct {
            fn thunk(
                p: *anyopaque,
                a0: fn_info.params[1].type.?,
                a1: fn_info.params[2].type.?,
                a2: fn_info.params[3].type.?,
                a3: fn_info.params[4].type.?,
                a4: fn_info.params[5].type.?,
                a5: fn_info.params[6].type.?,
            ) fn_info.return_type.? {
                return forwardCall(T, concrete, p, .{ a0, a1, a2, a3, a4, a5 });
            }
        }.thunk,
        8 => &struct {
            fn thunk(
                p: *anyopaque,
                a0: fn_info.params[1].type.?,
                a1: fn_info.params[2].type.?,
                a2: fn_info.params[3].type.?,
                a3: fn_info.params[4].type.?,
                a4: fn_info.params[5].type.?,
                a5: fn_info.params[6].type.?,
                a6: fn_info.params[7].type.?,
            ) fn_info.return_type.? {
                return forwardCall(T, concrete, p, .{ a0, a1, a2, a3, a4, a5, a6 });
            }
        }.thunk,
        9 => &struct {
            fn thunk(
                p: *anyopaque,
                a0: fn_info.params[1].type.?,
                a1: fn_info.params[2].type.?,
                a2: fn_info.params[3].type.?,
                a3: fn_info.params[4].type.?,
                a4: fn_info.params[5].type.?,
                a5: fn_info.params[6].type.?,
                a6: fn_info.params[7].type.?,
                a7: fn_info.params[8].type.?,
            ) fn_info.return_type.? {
                return forwardCall(T, concrete, p, .{ a0, a1, a2, a3, a4, a5, a6, a7 });
            }
        }.thunk,
        10 => &struct {
            fn thunk(
                p: *anyopaque,
                a0: fn_info.params[1].type.?,
                a1: fn_info.params[2].type.?,
                a2: fn_info.params[3].type.?,
                a3: fn_info.params[4].type.?,
                a4: fn_info.params[5].type.?,
                a5: fn_info.params[6].type.?,
                a6: fn_info.params[7].type.?,
                a7: fn_info.params[8].type.?,
                a8: fn_info.params[9].type.?,
            ) fn_info.return_type.? {
                return forwardCall(T, concrete, p, .{ a0, a1, a2, a3, a4, a5, a6, a7, a8 });
            }
        }.thunk,
        11 => &struct {
            fn thunk(
                p: *anyopaque,
                a0: fn_info.params[1].type.?,
                a1: fn_info.params[2].type.?,
                a2: fn_info.params[3].type.?,
                a3: fn_info.params[4].type.?,
                a4: fn_info.params[5].type.?,
                a5: fn_info.params[6].type.?,
                a6: fn_info.params[7].type.?,
                a7: fn_info.params[8].type.?,
                a8: fn_info.params[9].type.?,
                a9: fn_info.params[10].type.?,
            ) fn_info.return_type.? {
                return forwardCall(T, concrete, p, .{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9 });
            }
        }.thunk,
        12 => &struct {
            fn thunk(
                p: *anyopaque,
                a0: fn_info.params[1].type.?,
                a1: fn_info.params[2].type.?,
                a2: fn_info.params[3].type.?,
                a3: fn_info.params[4].type.?,
                a4: fn_info.params[5].type.?,
                a5: fn_info.params[6].type.?,
                a6: fn_info.params[7].type.?,
                a7: fn_info.params[8].type.?,
                a8: fn_info.params[9].type.?,
                a9: fn_info.params[10].type.?,
                a10: fn_info.params[11].type.?,
            ) fn_info.return_type.? {
                return forwardCall(T, concrete, p, .{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10 });
            }
        }.thunk,
        13 => &struct {
            fn thunk(
                p: *anyopaque,
                a0: fn_info.params[1].type.?,
                a1: fn_info.params[2].type.?,
                a2: fn_info.params[3].type.?,
                a3: fn_info.params[4].type.?,
                a4: fn_info.params[5].type.?,
                a5: fn_info.params[6].type.?,
                a6: fn_info.params[7].type.?,
                a7: fn_info.params[8].type.?,
                a8: fn_info.params[9].type.?,
                a9: fn_info.params[10].type.?,
                a10: fn_info.params[11].type.?,
                a11: fn_info.params[12].type.?,
            ) fn_info.return_type.? {
                return forwardCall(T, concrete, p, .{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11 });
            }
        }.thunk,
        14 => &struct {
            fn thunk(
                p: *anyopaque,
                a0: fn_info.params[1].type.?,
                a1: fn_info.params[2].type.?,
                a2: fn_info.params[3].type.?,
                a3: fn_info.params[4].type.?,
                a4: fn_info.params[5].type.?,
                a5: fn_info.params[6].type.?,
                a6: fn_info.params[7].type.?,
                a7: fn_info.params[8].type.?,
                a8: fn_info.params[9].type.?,
                a9: fn_info.params[10].type.?,
                a10: fn_info.params[11].type.?,
                a11: fn_info.params[12].type.?,
                a12: fn_info.params[13].type.?,
            ) fn_info.return_type.? {
                return forwardCall(T, concrete, p, .{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12 });
            }
        }.thunk,
        15 => &struct {
            fn thunk(
                p: *anyopaque,
                a0: fn_info.params[1].type.?,
                a1: fn_info.params[2].type.?,
                a2: fn_info.params[3].type.?,
                a3: fn_info.params[4].type.?,
                a4: fn_info.params[5].type.?,
                a5: fn_info.params[6].type.?,
                a6: fn_info.params[7].type.?,
                a7: fn_info.params[8].type.?,
                a8: fn_info.params[9].type.?,
                a9: fn_info.params[10].type.?,
                a10: fn_info.params[11].type.?,
                a11: fn_info.params[12].type.?,
                a12: fn_info.params[13].type.?,
                a13: fn_info.params[14].type.?,
            ) fn_info.return_type.? {
                return forwardCall(T, concrete, p, .{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13 });
            }
        }.thunk,
        16 => &struct {
            fn thunk(
                p: *anyopaque,
                a0: fn_info.params[1].type.?,
                a1: fn_info.params[2].type.?,
                a2: fn_info.params[3].type.?,
                a3: fn_info.params[4].type.?,
                a4: fn_info.params[5].type.?,
                a5: fn_info.params[6].type.?,
                a6: fn_info.params[7].type.?,
                a7: fn_info.params[8].type.?,
                a8: fn_info.params[9].type.?,
                a9: fn_info.params[10].type.?,
                a10: fn_info.params[11].type.?,
                a11: fn_info.params[12].type.?,
                a12: fn_info.params[13].type.?,
                a13: fn_info.params[14].type.?,
                a14: fn_info.params[15].type.?,
            ) fn_info.return_type.? {
                return forwardCall(T, concrete, p, .{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14 });
            }
        }.thunk,
        else => @compileError("trait method arity > 16 not supported (raise the limit in lib/traits.zig)"),
    };
}

fn FieldType(comptime S: type, comptime name: []const u8) type {
    inline for (@typeInfo(S).@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return f.type;
    }
    @compileError("struct " ++ @typeName(S) ++ " has no field '" ++ name ++ "'");
}

const TestCounter = struct {
    n: u32,
    fn bump(self: *TestCounter) void {
        self.n += 1;
    }
    fn add(self: *TestCounter, x: u32) u32 {
        self.n += x;
        return self.n;
    }
    fn six(
        self: *TestCounter,
        a: u32,
        b: u32,
        c: u32,
        d: u32,
        e: u32,
        f: u32,
    ) u32 {
        self.n += a + b + c + d + e + f;
        return self.n;
    }
    fn seven(
        self: *TestCounter,
        a: u32,
        b: u32,
        c: u32,
        d: u32,
        e: u32,
        f: u32,
        g: u32,
    ) u32 {
        self.n += a + b + c + d + e + f + g;
        return self.n;
    }
};

test "VTableOf builds a struct with the named fn pointer fields" {
    const VT = VTableOf(.{
        .{ "bump", *const fn (*anyopaque) void },
        .{ "add", *const fn (*anyopaque, u32) u32 },
    });
    try std.testing.expect(@hasField(VT, "bump"));
    try std.testing.expect(@hasField(VT, "add"));
}

test "implFor wires concrete methods through *anyopaque" {
    const VT = VTableOf(.{
        .{ "bump", *const fn (*anyopaque) void },
        .{ "add", *const fn (*anyopaque, u32) u32 },
    });
    const vt = implFor(VT, TestCounter, .{
        .{ "bump", TestCounter.bump },
        .{ "add", TestCounter.add },
    });
    var c = TestCounter{ .n = 0 };
    vt.bump(&c);
    vt.bump(&c);
    const r = vt.add(&c, 10);
    try std.testing.expectEqual(@as(u32, 12), r);
    try std.testing.expectEqual(@as(u32, 12), c.n);
}

test "implFor dispatches a 6-parameter trait method" {
    const VT = VTableOf(.{
        .{ "six", *const fn (*anyopaque, u32, u32, u32, u32, u32, u32) u32 },
    });
    const vt = implFor(VT, TestCounter, .{
        .{ "six", TestCounter.six },
    });
    var c = TestCounter{ .n = 0 };
    const r = vt.six(&c, 1, 2, 3, 4, 5, 6);
    try std.testing.expectEqual(@as(u32, 21), r);
    try std.testing.expectEqual(@as(u32, 21), c.n);
}

test "implFor dispatches a 7-parameter trait method" {
    const VT = VTableOf(.{
        .{ "seven", *const fn (*anyopaque, u32, u32, u32, u32, u32, u32, u32) u32 },
    });
    const vt = implFor(VT, TestCounter, .{
        .{ "seven", TestCounter.seven },
    });
    var c = TestCounter{ .n = 0 };
    const r = vt.seven(&c, 1, 2, 3, 4, 5, 6, 7);
    try std.testing.expectEqual(@as(u32, 28), r);
    try std.testing.expectEqual(@as(u32, 28), c.n);
}
