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

pub fn Default(comptime T: type) type {
    ensureStruct(T, "Default");
    return struct {
        /// Returns the zero value of T (all fields set to their type's zero).
        /// Matches `std.mem.zeroes(T)` semantics; for fields with explicit
        /// default values in the struct decl, those defaults win.
        pub fn default() T {
            return std.mem.zeroInit(T, .{});
        }
    };
}

pub fn Ord(comptime T: type) type {
    ensureStruct(T, "Ord");
    return struct {
        /// Lexicographic field-by-field comparison. Returns -1 / 0 / +1.
        /// Strings (`[]const u8`) compare via std.mem.order; pointers compare
        /// by address; nested structs recurse.
        pub fn cmp(self: T, other: T) i32 {
            return cmpValue(self, other);
        }

        fn cmpValue(a: anytype, b: anytype) i32 {
            const V = @TypeOf(a);
            const info = @typeInfo(V);
            switch (info) {
                .int, .comptime_int => {
                    if (a < b) return -1;
                    if (a > b) return 1;
                    return 0;
                },
                .float, .comptime_float => {
                    if (a < b) return -1;
                    if (a > b) return 1;
                    return 0;
                },
                .bool => {
                    if (@intFromBool(a) < @intFromBool(b)) return -1;
                    if (@intFromBool(a) > @intFromBool(b)) return 1;
                    return 0;
                },
                .@"enum" => return cmpValue(@intFromEnum(a), @intFromEnum(b)),
                .pointer => |p| switch (p.size) {
                    .slice => if (p.child == u8) {
                        return switch (std.mem.order(u8, a, b)) {
                            .lt => -1,
                            .eq => 0,
                            .gt => 1,
                        };
                    } else {
                        const min_len = @min(a.len, b.len);
                        var i: usize = 0;
                        while (i < min_len) : (i += 1) {
                            const c = cmpValue(a[i], b[i]);
                            if (c != 0) return c;
                        }
                        if (a.len < b.len) return -1;
                        if (a.len > b.len) return 1;
                        return 0;
                    },
                    else => return cmpValue(@intFromPtr(a), @intFromPtr(b)),
                },
                .@"struct" => |s| {
                    inline for (s.fields) |f| {
                        const c = cmpValue(@field(a, f.name), @field(b, f.name));
                        if (c != 0) return c;
                    }
                    return 0;
                },
                else => return 0,
            }
        }
    };
}

pub fn Clone(comptime T: type) type {
    ensureStruct(T, "Clone");
    return struct {
        /// Deep clone using `allocator`. Slices and arrays are duplicated;
        /// scalar fields are bit-copied. Use an arena to free everything in
        /// one shot.
        pub fn clone(self: T, allocator: Allocator) Allocator.Error!T {
            return cloneValue(T, self, allocator);
        }

        fn cloneValue(comptime V: type, value: V, allocator: Allocator) Allocator.Error!V {
            const info = @typeInfo(V);
            return switch (info) {
                .int, .float, .bool, .@"enum", .void => value,
                .optional => |opt| if (value) |v| (try cloneValue(opt.child, v, allocator)) else null,
                .pointer => |p| switch (p.size) {
                    .slice => blk: {
                        const dup = try allocator.alloc(p.child, value.len);
                        errdefer allocator.free(dup);
                        for (value, 0..) |x, i| dup[i] = try cloneValue(p.child, x, allocator);
                        break :blk dup;
                    },
                    else => value,
                },
                .array => |arr| blk: {
                    var out: [arr.len]arr.child = undefined;
                    for (value, 0..) |x, i| out[i] = try cloneValue(arr.child, x, allocator);
                    break :blk out;
                },
                .@"struct" => |s| blk: {
                    var out: V = undefined;
                    inline for (s.fields) |f| {
                        @field(out, f.name) = try cloneValue(f.type, @field(value, f.name), allocator);
                    }
                    break :blk out;
                },
                else => value,
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

test "Default returns the zero value" {
    const a = Default(Point).default();
    try std.testing.expectEqual(@as(i32, 0), a.x);
    try std.testing.expectEqual(@as(i32, 0), a.y);
}

test "Ord lexicographic field comparison" {
    const a = Point{ .x = 1, .y = 2 };
    const b = Point{ .x = 1, .y = 3 };
    const c = Point{ .x = 2, .y = 0 };
    try std.testing.expectEqual(@as(i32, 0), Ord(Point).cmp(a, a));
    try std.testing.expectEqual(@as(i32, -1), Ord(Point).cmp(a, b));
    try std.testing.expectEqual(@as(i32, 1), Ord(Point).cmp(b, a));
    try std.testing.expectEqual(@as(i32, -1), Ord(Point).cmp(a, c));
}

test "Clone duplicates struct with slice field" {
    const Owned = struct {
        id: u32,
        name: []const u8,
    };
    const a = std.testing.allocator;
    const v = Owned{ .id = 7, .name = "ada" };
    const c = try Clone(Owned).clone(v, a);
    defer a.free(c.name);
    try std.testing.expectEqual(v.id, c.id);
    try std.testing.expectEqualStrings(v.name, c.name);
    // The clone owns its own copy of `name`.
    try std.testing.expect(v.name.ptr != c.name.ptr);
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
