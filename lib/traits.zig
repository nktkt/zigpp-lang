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
    return switch (fn_info.params.len) {
        1 => &struct {
            fn thunk(p: *anyopaque) fn_info.return_type.? {
                const self: *T = @ptrCast(@alignCast(p));
                return @call(.always_inline, concrete, .{self});
            }
        }.thunk,
        2 => &struct {
            fn thunk(p: *anyopaque, a0: fn_info.params[1].type.?) fn_info.return_type.? {
                const self: *T = @ptrCast(@alignCast(p));
                return @call(.always_inline, concrete, .{ self, a0 });
            }
        }.thunk,
        3 => &struct {
            fn thunk(
                p: *anyopaque,
                a0: fn_info.params[1].type.?,
                a1: fn_info.params[2].type.?,
            ) fn_info.return_type.? {
                const self: *T = @ptrCast(@alignCast(p));
                return @call(.always_inline, concrete, .{ self, a0, a1 });
            }
        }.thunk,
        4 => &struct {
            fn thunk(
                p: *anyopaque,
                a0: fn_info.params[1].type.?,
                a1: fn_info.params[2].type.?,
                a2: fn_info.params[3].type.?,
            ) fn_info.return_type.? {
                const self: *T = @ptrCast(@alignCast(p));
                return @call(.always_inline, concrete, .{ self, a0, a1, a2 });
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
                const self: *T = @ptrCast(@alignCast(p));
                return @call(.always_inline, concrete, .{ self, a0, a1, a2, a3 });
            }
        }.thunk,
        else => @compileError("trait method arity > 5 not supported"),
    };
}

fn FieldType(comptime S: type, comptime name: []const u8) type {
    inline for (@typeInfo(S).@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return f.type;
    }
    @compileError("no such field: " ++ name);
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
