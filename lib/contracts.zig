//! Pre/post/invariant contract checks.
//!
//! These compile to nothing in `ReleaseFast`/`ReleaseSmall`. The `comptime`
//! check on `checks_on` ensures the failing branch is dropped entirely, so
//! release callers do not pay for a runtime test or for the message string.

const std = @import("std");
const builtin = @import("builtin");

const checks_on = switch (builtin.mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseFast, .ReleaseSmall => false,
};

pub inline fn requires(cond: bool, comptime msg: []const u8) void {
    if (comptime !checks_on) return;
    if (!cond) {
        @branchHint(.cold);
        @panic("zpp.contract.requires failed: " ++ msg);
    }
}

pub inline fn ensures(cond: bool, comptime msg: []const u8) void {
    if (comptime !checks_on) return;
    if (!cond) {
        @branchHint(.cold);
        @panic("zpp.contract.ensures failed: " ++ msg);
    }
}

pub inline fn invariant(cond: bool, comptime msg: []const u8) void {
    if (comptime !checks_on) return;
    if (!cond) {
        @branchHint(.cold);
        @panic("zpp.contract.invariant failed: " ++ msg);
    }
}

/// Marks an unreachable contract violation. Stays as `unreachable` in release
/// modes so the optimizer can prune impossible branches.
pub inline fn unreachableContract(comptime msg: []const u8) noreturn {
    if (comptime checks_on) {
        @panic("zpp.contract.unreachable: " ++ msg);
    } else {
        unreachable;
    }
}

pub inline fn requiresEq(comptime T: type, a: T, b: T, comptime msg: []const u8) void {
    requires(a == b, msg);
}

pub inline fn requiresLt(comptime T: type, a: T, b: T, comptime msg: []const u8) void {
    requires(a < b, msg);
}

pub inline fn requiresLe(comptime T: type, a: T, b: T, comptime msg: []const u8) void {
    requires(a <= b, msg);
}

/// `lo <= v < hi`
pub inline fn requiresInRange(comptime T: type, v: T, lo: T, hi: T, comptime msg: []const u8) void {
    requires(v >= lo and v < hi, msg);
}

pub inline fn requiresNonNull(p: anytype, comptime msg: []const u8) void {
    if (comptime !checks_on) return;
    const info = @typeInfo(@TypeOf(p));
    switch (info) {
        .optional => requires(p != null, msg),
        .pointer => |pi| if (pi.is_allowzero) {
            requires(@intFromPtr(p) != 0, msg);
        },
        else => @compileError("requiresNonNull expects an optional or pointer"),
    }
}

/// Comptime validator hook. Use at the entry of a generic function to fail
/// fast with a readable message when a type parameter is wrong.
pub inline fn requiresType(comptime cond: bool, comptime msg: []const u8) void {
    if (!cond) @compileError("zpp.contract.requiresType: " ++ msg);
}

/// Wrap a value with both a pre and post check. The body returns `R` and
/// `post` validates the result.
pub inline fn checked(
    comptime R: type,
    pre: bool,
    comptime pre_msg: []const u8,
    body: anytype,
    post: *const fn (R) bool,
    comptime post_msg: []const u8,
) R {
    requires(pre, pre_msg);
    const out: R = body();
    ensures(post(out), post_msg);
    return out;
}

test "requires passes on true and is a no-op for the value" {
    requires(true, "ok");
    ensures(true, "ok");
    invariant(true, "ok");
}

test "ordering helpers accept correct relations" {
    requiresLt(u32, 1, 2, "1 < 2");
    requiresLe(u32, 5, 5, "5 <= 5");
    requiresEq(u32, 5, 5, "equal");
    requiresInRange(u32, 3, 0, 10, "0 <= 3 < 10");
}

test "requiresNonNull accepts present optional" {
    const x: ?u32 = 7;
    requiresNonNull(x, "expected value");
}

test "checked runs pre, body, post" {
    const inc = struct {
        fn body() u32 {
            return 41 + 1;
        }
        fn post(x: u32) bool {
            return x == 42;
        }
    };
    const r = checked(u32, true, "always", inc.body, inc.post, "is 42");
    try std.testing.expectEqual(@as(u32, 42), r);
}
