//! Comptime derive helpers backing `derive(.{ Hash, Debug, Json, Eq })`.

const std = @import("std");
const Allocator = std.mem.Allocator;

fn ensureStruct(comptime T: type, comptime who: []const u8) void {
    const info = @typeInfo(T);
    if (info != .@"struct") {
        @compileError(who ++ " can only be derived for structs, got " ++ @typeName(T));
    }
}

pub fn Hash(comptime T: type) type {
    ensureStruct(T, "Hash");
    return struct {
        pub fn hash(self: T) u64 {
            var h = std.hash.Wyhash.init(0x7A_70_70_64_72_76_00_00);
            hashInto(&h, self);
            return h.final();
        }

        pub fn hashWithSeed(self: T, seed: u64) u64 {
            var h = std.hash.Wyhash.init(seed);
            hashInto(&h, self);
            return h.final();
        }

        fn hashInto(h: *std.hash.Wyhash, value: anytype) void {
            const V = @TypeOf(value);
            const vinfo = @typeInfo(V);
            switch (vinfo) {
                .@"struct" => |s| {
                    inline for (s.fields) |f| {
                        hashField(h, @field(value, f.name));
                    }
                },
                else => hashField(h, value),
            }
        }

        fn hashField(h: *std.hash.Wyhash, v: anytype) void {
            const V = @TypeOf(v);
            const vinfo = @typeInfo(V);
            switch (vinfo) {
                .int, .float, .bool, .@"enum" => {
                    var bytes: [@sizeOf(V)]u8 = undefined;
                    @memcpy(&bytes, std.mem.asBytes(&v));
                    h.update(&bytes);
                },
                .pointer => |p| switch (p.size) {
                    .slice => h.update(std.mem.sliceAsBytes(v)),
                    else => {
                        const addr: usize = @intFromPtr(v);
                        h.update(std.mem.asBytes(&addr));
                    },
                },
                .array => h.update(std.mem.sliceAsBytes(v[0..])),
                .@"struct" => |s| inline for (s.fields) |f| hashField(h, @field(v, f.name)),
                .optional => if (v) |inner| hashField(h, inner) else h.update(&[_]u8{0}),
                else => {},
            }
        }
    };
}

pub fn Debug(comptime T: type) type {
    ensureStruct(T, "Debug");
    return struct {
        value: T,

        pub fn wrap(value: T) @This() {
            return .{ .value = value };
        }

        pub fn format(self: T, w: *std.Io.Writer) !void {
            try w.writeAll(@typeName(T));
            try w.writeAll("{ ");
            const fields = @typeInfo(T).@"struct".fields;
            inline for (fields, 0..) |f, i| {
                if (i != 0) try w.writeAll(", ");
                try w.writeAll(f.name);
                try w.writeAll(" = ");
                try formatValue(w, @field(self, f.name));
            }
            try w.writeAll(" }");
        }

        fn formatValue(w: *std.Io.Writer, v: anytype) !void {
            const V = @TypeOf(v);
            const info = @typeInfo(V);
            switch (info) {
                .int, .comptime_int => try w.print("{d}", .{v}),
                .float, .comptime_float => try w.print("{d}", .{v}),
                .bool => try w.writeAll(if (v) "true" else "false"),
                .@"enum" => try w.print(".{s}", .{@tagName(v)}),
                .pointer => |p| switch (p.size) {
                    .slice => if (p.child == u8) {
                        try w.print("\"{s}\"", .{v});
                    } else {
                        try w.print("[{d} items]", .{v.len});
                    },
                    else => try w.print("0x{x}", .{@intFromPtr(v)}),
                },
                .optional => if (v) |x| try formatValue(w, x) else try w.writeAll("null"),
                else => try w.print("<{s}>", .{@typeName(V)}),
            }
        }
    };
}

pub fn Eq(comptime T: type) type {
    ensureStruct(T, "Eq");
    return struct {
        pub fn eq(a: T, b: T) bool {
            return fieldEq(a, b);
        }

        pub fn ne(a: T, b: T) bool {
            return !fieldEq(a, b);
        }

        fn fieldEq(a: anytype, b: anytype) bool {
            const V = @TypeOf(a);
            const info = @typeInfo(V);
            switch (info) {
                .@"struct" => |s| {
                    inline for (s.fields) |f| {
                        if (!valueEq(@field(a, f.name), @field(b, f.name))) return false;
                    }
                    return true;
                },
                else => return valueEq(a, b),
            }
        }

        fn valueEq(a: anytype, b: anytype) bool {
            const V = @TypeOf(a);
            const info = @typeInfo(V);
            return switch (info) {
                .int, .float, .bool, .@"enum", .comptime_int, .comptime_float => a == b,
                .pointer => |p| switch (p.size) {
                    .slice => if (p.child == u8) std.mem.eql(u8, a, b) else blk: {
                        if (a.len != b.len) break :blk false;
                        for (a, b) |x, y| if (!valueEq(x, y)) break :blk false;
                        break :blk true;
                    },
                    else => @intFromPtr(a) == @intFromPtr(b),
                },
                .optional => if (a == null and b == null) true else if (a == null or b == null) false else valueEq(a.?, b.?),
                .@"struct" => fieldEq(a, b),
                .array => blk: {
                    for (a, 0..) |x, i| if (!valueEq(x, b[i])) break :blk false;
                    break :blk true;
                },
                else => false,
            };
        }
    };
}

pub fn Json(comptime T: type) type {
    ensureStruct(T, "Json");
    return struct {
        pub fn toJson(self: T, a: Allocator) ![]u8 {
            var aw: std.Io.Writer.Allocating = .init(a);
            errdefer aw.deinit();
            try std.json.Stringify.value(self, .{}, &aw.writer);
            return aw.toOwnedSlice();
        }

        /// Pass an arena allocator if `T` owns slices or pointers; the
        /// returned value borrows from `a` for those fields.
        pub fn fromJson(s: []const u8, a: Allocator) !T {
            return std.json.parseFromSliceLeaky(T, a, s, .{});
        }
    };
}

const Point = struct {
    x: i32,
    y: i32,

    pub const hash = Hash(@This()).hash;
    pub const eq = Eq(@This()).eq;
};

const User = struct {
    id: u32,
    flag: bool,
};

test "Hash is stable for the same value" {
    const a = Point{ .x = 1, .y = 2 };
    const b = Point{ .x = 1, .y = 2 };
    const c = Point{ .x = 1, .y = 3 };
    try std.testing.expectEqual(Point.hash(a), Point.hash(b));
    try std.testing.expect(Point.hash(a) != Point.hash(c));
}

test "Eq compares all fields" {
    const a = Point{ .x = 1, .y = 2 };
    const b = Point{ .x = 1, .y = 2 };
    const c = Point{ .x = 1, .y = 3 };
    try std.testing.expect(Point.eq(a, b));
    try std.testing.expect(!Point.eq(a, c));
}

test "Json round-trips a flat struct" {
    const u = User{ .id = 7, .flag = true };
    const a = std.testing.allocator;
    const s = try Json(User).toJson(u, a);
    defer a.free(s);
    const back = try Json(User).fromJson(s, a);
    try std.testing.expectEqual(u.id, back.id);
    try std.testing.expectEqual(u.flag, back.flag);
}
