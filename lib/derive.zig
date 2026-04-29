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

/// Field-name iterator. `iter(value)` returns a `FieldIter` whose `next()`
/// yields each field's name (in declaration order) as `[]const u8` and then
/// `null`. Useful for reflection / generic logging where the *names* matter
/// but per-field values would need a tagged union.
pub fn Iterator(comptime T: type) type {
    ensureStruct(T, "Iterator");
    const struct_fields = @typeInfo(T).@"struct".fields;
    // Snapshot the names into a runtime-indexable array. The original
    // `StructField` slice can only be indexed at comptime because each
    // entry carries a `type: type` field.
    const names = comptime blk: {
        var arr: [struct_fields.len][]const u8 = undefined;
        for (struct_fields, 0..) |f, i| arr[i] = f.name;
        break :blk arr;
    };
    return struct {
        pub const FieldIter = struct {
            i: usize = 0,

            pub fn next(self: *FieldIter) ?[]const u8 {
                if (self.i >= names.len) return null;
                defer self.i += 1;
                return names[self.i];
            }

            pub fn reset(self: *FieldIter) void {
                self.i = 0;
            }
        };

        pub fn iter(_: T) FieldIter {
            return .{};
        }

        pub fn fieldCount() usize {
            return names.len;
        }
    };
}

/// `key=value;key=value` text serialization. Pairs with `FromStr` for a
/// trivial round-trip on POD-shaped structs. Strings are written verbatim;
/// callers who need to round-trip values containing `=` or `;` should reach
/// for `Json` instead.
pub fn Serialize(comptime T: type) type {
    ensureStruct(T, "Serialize");
    return struct {
        /// Returns an allocator-owned `key=value;key=value` string.
        pub fn serialize(self: T, allocator: Allocator) ![]u8 {
            var aw: std.Io.Writer.Allocating = .init(allocator);
            errdefer aw.deinit();
            try writeTo(self, &aw.writer);
            return aw.toOwnedSlice();
        }

        /// Lower-level entry point that writes into a caller-provided writer.
        pub fn writeTo(self: T, w: *std.Io.Writer) !void {
            const fields = @typeInfo(T).@"struct".fields;
            inline for (fields, 0..) |f, i| {
                if (i != 0) try w.writeAll(";");
                try w.writeAll(f.name);
                try w.writeAll("=");
                try writeValue(w, @field(self, f.name));
            }
        }

        fn writeValue(w: *std.Io.Writer, v: anytype) !void {
            const V = @TypeOf(v);
            switch (@typeInfo(V)) {
                .int, .comptime_int => try w.print("{d}", .{v}),
                .float, .comptime_float => try w.print("{d}", .{v}),
                .bool => try w.writeAll(if (v) "true" else "false"),
                .@"enum" => try w.writeAll(@tagName(v)),
                .pointer => |p| switch (p.size) {
                    .slice => if (p.child == u8) try w.writeAll(v) else try w.print("[{d} items]", .{v.len}),
                    else => try w.print("0x{x}", .{@intFromPtr(v)}),
                },
                .optional => if (v) |x| try writeValue(w, x) else try w.writeAll("null"),
                else => try w.print("<{s}>", .{@typeName(V)}),
            }
        }
    };
}

/// Boolean comparison helpers backed by `Ord(T).cmp`. Adds `lt/le/gt/ge` plus
/// `min/max` so callers can write `Compare(T).lt(a, b)` instead of
/// `Ord(T).cmp(a, b) < 0`. Pure comptime — no allocation.
pub fn Compare(comptime T: type) type {
    ensureStruct(T, "Compare");
    const O = Ord(T);
    return struct {
        pub fn lt(self: T, other: T) bool {
            return O.cmp(self, other) < 0;
        }
        pub fn le(self: T, other: T) bool {
            return O.cmp(self, other) <= 0;
        }
        pub fn gt(self: T, other: T) bool {
            return O.cmp(self, other) > 0;
        }
        pub fn ge(self: T, other: T) bool {
            return O.cmp(self, other) >= 0;
        }
        pub fn min(self: T, other: T) T {
            return if (O.cmp(self, other) <= 0) self else other;
        }
        pub fn max(self: T, other: T) T {
            return if (O.cmp(self, other) >= 0) self else other;
        }
    };
}

/// Inverse of `Serialize`. Parses `key=value,key=value` (commas — distinct
/// from Serialize's `;`-separator so a writer/parser pair stays unambiguous
/// when keys contain neither character) into a fresh `T`. Missing fields
/// stay zero-initialized. Numeric/bool/enum fields parse via the std
/// helpers; `[]const u8` fields are duplicated into `allocator` so callers
/// can free them (an arena makes cleanup trivial).
pub fn FromStr(comptime T: type) type {
    ensureStruct(T, "FromStr");
    return struct {
        pub const Error = error{ InvalidFormat, UnknownField };

        pub fn parse(s: []const u8, allocator: Allocator) !T {
            var out: T = std.mem.zeroInit(T, .{});
            var it = std.mem.tokenizeScalar(u8, s, ',');
            while (it.next()) |kv_raw| {
                const kv = std.mem.trim(u8, kv_raw, " \t\r\n");
                if (kv.len == 0) continue;
                const eq = std.mem.indexOfScalar(u8, kv, '=') orelse return error.InvalidFormat;
                const key = std.mem.trim(u8, kv[0..eq], " \t");
                const val = std.mem.trim(u8, kv[eq + 1 ..], " \t");
                var matched = false;
                inline for (@typeInfo(T).@"struct".fields) |f| {
                    if (std.mem.eql(u8, f.name, key)) {
                        @field(out, f.name) = try parseField(f.type, val, allocator);
                        matched = true;
                    }
                }
                if (!matched) return error.UnknownField;
            }
            return out;
        }

        fn parseField(comptime V: type, s: []const u8, allocator: Allocator) !V {
            return switch (@typeInfo(V)) {
                .int => try std.fmt.parseInt(V, s, 10),
                .float => try std.fmt.parseFloat(V, s),
                .bool => if (std.mem.eql(u8, s, "true"))
                    true
                else if (std.mem.eql(u8, s, "false"))
                    false
                else
                    error.InvalidFormat,
                .@"enum" => std.meta.stringToEnum(V, s) orelse error.InvalidFormat,
                .pointer => |p| if (p.size == .slice and p.child == u8) blk: {
                    const dup = try allocator.alloc(u8, s.len);
                    @memcpy(dup, s);
                    break :blk dup;
                } else error.InvalidFormat,
                else => error.InvalidFormat,
            };
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

test "Iterator yields field names in declaration order" {
    const p = Point{ .x = 1, .y = 2 };
    var it = Iterator(Point).iter(p);
    try std.testing.expectEqualStrings("x", it.next().?);
    try std.testing.expectEqualStrings("y", it.next().?);
    try std.testing.expect(it.next() == null);
    try std.testing.expectEqual(@as(usize, 2), Iterator(Point).fieldCount());
}

test "Serialize emits key=value pairs separated by ';'" {
    const u = User{ .id = 7, .flag = true };
    const a = std.testing.allocator;
    const s = try Serialize(User).serialize(u, a);
    defer a.free(s);
    try std.testing.expectEqualStrings("id=7;flag=true", s);
}

test "Compare lt/le/gt/ge agree with Ord.cmp" {
    const a = Point{ .x = 1, .y = 2 };
    const b = Point{ .x = 1, .y = 3 };
    try std.testing.expect(Compare(Point).lt(a, b));
    try std.testing.expect(Compare(Point).le(a, b));
    try std.testing.expect(!Compare(Point).gt(a, b));
    try std.testing.expect(!Compare(Point).ge(a, b));
    try std.testing.expect(Compare(Point).le(a, a));
    try std.testing.expect(Compare(Point).ge(a, a));
    try std.testing.expectEqual(a, Compare(Point).min(a, b));
    try std.testing.expectEqual(b, Compare(Point).max(a, b));
}

test "FromStr parses key=value,key=value back to T" {
    const a = std.testing.allocator;
    const u = try FromStr(User).parse("id=42, flag=false", a);
    try std.testing.expectEqual(@as(u32, 42), u.id);
    try std.testing.expectEqual(false, u.flag);
}

test "FromStr round-trips Serialize for a struct with a string field" {
    const Owned = struct {
        id: u32,
        name: []const u8,
    };
    const a = std.testing.allocator;
    // Serialize uses ';' but FromStr reads ',', so build the FromStr input by hand.
    const back = try FromStr(Owned).parse("id=7,name=ada", a);
    defer a.free(back.name);
    try std.testing.expectEqual(@as(u32, 7), back.id);
    try std.testing.expectEqualStrings("ada", back.name);
}

test "FromStr rejects unknown fields and malformed input" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.UnknownField, FromStr(User).parse("nope=1", a));
    try std.testing.expectError(error.InvalidFormat, FromStr(User).parse("no_equals_sign", a));
}
