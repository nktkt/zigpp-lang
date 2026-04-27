//! Zig++ testing helpers layered on `std.testing`.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Calls `fn_under_test(allocator, args...)` with a tracking allocator and
/// asserts no leaks survive the call.
pub fn expectDeinitCalled(comptime _: type, fn_under_test: anytype, args: anytype) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    defer {
        const status = gpa.deinit();
        std.debug.assert(status == .ok);
    }
    const a = gpa.allocator();
    try invokeWithAlloc(fn_under_test, a, args);
}

/// Runs `fn_under_test(allocator, args...)` against a `FailingAllocator` set
/// to deny all allocations. The function under test is expected to either
/// not allocate at all or to surface `error.OutOfMemory`.
pub fn expectNoAlloc(fn_under_test: anytype, args: anytype) !void {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const a = failing.allocator();
    invokeWithAlloc(fn_under_test, a, args) catch |e| switch (e) {
        error.OutOfMemory => return,
        else => return e,
    };
    if (failing.alloc_count > 0) return error.AllocatedUnderNoAllocContract;
}

fn invokeWithAlloc(fn_under_test: anytype, a: Allocator, args: anytype) !void {
    const F = @TypeOf(fn_under_test);
    const fn_info = @typeInfo(F).@"fn";
    const ret_info = @typeInfo(fn_info.return_type orelse void);
    const Combined = CombineArgs(@TypeOf(args));
    var combined: Combined = undefined;
    combined[0] = a;
    inline for (@typeInfo(@TypeOf(args)).@"struct".fields, 0..) |f, i| {
        combined[i + 1] = @field(args, f.name);
    }
    if (ret_info == .error_union) {
        try @call(.auto, fn_under_test, combined);
    } else {
        @call(.auto, fn_under_test, combined);
    }
}

fn CombineArgs(comptime ArgsT: type) type {
    const args_info = @typeInfo(ArgsT).@"struct";
    var fields: [args_info.fields.len + 1]std.builtin.Type.StructField = undefined;
    fields[0] = .{
        .name = "0",
        .type = Allocator,
        .default_value_ptr = null,
        .is_comptime = false,
        .alignment = @alignOf(Allocator),
    };
    inline for (args_info.fields, 0..) |f, i| {
        fields[i + 1] = .{
            .name = std.fmt.comptimePrint("{d}", .{i + 1}),
            .type = f.type,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(f.type),
        };
    }
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = true,
    } });
}

/// Property-test runner. `gen` is `fn (*std.Random) T`, `prop` is
/// `fn (T) bool` or `fn (T) !bool`. Failure prints the offending input.
pub fn property(comptime T: type, comptime gen: anytype, comptime prop: anytype, iters: usize) !void {
    var seed_bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&seed_bytes);
    const seed = std.mem.readInt(u64, &seed_bytes, .little);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    var i: usize = 0;
    while (i < iters) : (i += 1) {
        const sample: T = gen(rand);
        const result = prop(sample);
        const RT = @TypeOf(result);
        const r_info = @typeInfo(RT);
        const ok: bool = if (r_info == .error_union) try result else result;
        if (!ok) {
            std.debug.print("property failed at iter {d} seed={x} sample={any}\n", .{ i, seed, sample });
            return error.PropertyFalsified;
        }
    }
}

/// Compare `actual` to the contents of the file at `path`. With env var
/// `ZPP_UPDATE_SNAPSHOTS=1` the file is rewritten instead of failing.
pub fn snapshot(actual: []const u8, comptime path: []const u8) !void {
    const a = std.testing.allocator;
    const update = blk: {
        const v = std.process.getEnvVarOwned(a, "ZPP_UPDATE_SNAPSHOTS") catch break :blk false;
        defer a.free(v);
        break :blk std.mem.eql(u8, v, "1");
    };

    if (update) {
        const dir = std.fs.cwd();
        try dir.writeFile(.{ .sub_path = path, .data = actual });
        return;
    }

    const expected = std.fs.cwd().readFileAlloc(a, path, 1 << 20) catch |e| switch (e) {
        error.FileNotFound => {
            std.debug.print("snapshot file missing: {s}; rerun with ZPP_UPDATE_SNAPSHOTS=1\n", .{path});
            return error.SnapshotMissing;
        },
        else => return e,
    };
    defer a.free(expected);

    if (!std.mem.eql(u8, expected, actual)) {
        std.debug.print(
            "snapshot mismatch at {s}\n--- expected ---\n{s}\n--- actual ---\n{s}\n",
            .{ path, expected, actual },
        );
        return error.SnapshotMismatch;
    }
}

fn allocAndFree(a: Allocator, n: usize) !void {
    const buf = try a.alloc(u8, n);
    a.free(buf);
}

fn pureAdd(x: i32, y: i32) i32 {
    return x + y;
}

fn genU8(r: std.Random) u8 {
    return r.int(u8);
}

fn propAddCommutes(_: u8) bool {
    return pureAdd(1, 2) == pureAdd(2, 1);
}

test "expectDeinitCalled detects clean alloc/free" {
    try expectDeinitCalled(void, allocAndFree, .{@as(usize, 32)});
}

test "property runner runs the requested number of iterations" {
    try property(u8, genU8, propAddCommutes, 16);
}
