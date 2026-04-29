const std = @import("std");
const zpp = @import("zpp");

const async_mod = zpp.async_mod;

fn incFn(slot: *std.atomic.Value(u32)) void {
    _ = slot.fetchAdd(1, .monotonic);
}

const SumCtx = struct {
    total: *std.atomic.Value(u64),
    delta: u64,
};

fn addFn(ctx: *SumCtx) void {
    _ = ctx.total.fetchAdd(ctx.delta, .monotonic);
}

fn squareFn(x: u32) u32 {
    return x *% x;
}

fn failingFn(id: u32) error{Boom}!void {
    if (id == 42) return error.Boom;
}

const TASK_COUNT: u32 = 100;

test "TaskGroup stress: 100 concurrent tasks all run to completion" {
    var group = async_mod.TaskGroup.init(std.testing.allocator);
    defer group.deinit();

    var counter = std.atomic.Value(u32).init(0);
    var i: u32 = 0;
    while (i < TASK_COUNT) : (i += 1) {
        _ = try group.spawn(incFn, .{&counter});
    }

    try group.join();
    try std.testing.expectEqual(TASK_COUNT, counter.load(.acquire));
}

test "TaskGroup stress: 100 tasks with distinct payloads sum correctly" {
    var group = async_mod.TaskGroup.init(std.testing.allocator);
    defer group.deinit();

    var total = std.atomic.Value(u64).init(0);

    // Stack-allocated context array shared across spawns. Each entry
    // carries a unique delta so a successful concurrent run produces a
    // deterministic sum (sum 1..=100 = 5050).
    var contexts: [TASK_COUNT]SumCtx = undefined;
    var i: u32 = 0;
    while (i < TASK_COUNT) : (i += 1) {
        contexts[i] = .{ .total = &total, .delta = i + 1 };
        _ = try group.spawn(addFn, .{&contexts[i]});
    }

    try group.join();
    try std.testing.expectEqual(@as(u64, 5050), total.load(.acquire));
}

test "TaskGroup stress: typed JoinHandle results across 100 tasks" {
    var group = async_mod.TaskGroup.init(std.testing.allocator);
    defer group.deinit();

    var handles: [TASK_COUNT]*async_mod.JoinHandle(u32) = undefined;
    var i: u32 = 0;
    while (i < TASK_COUNT) : (i += 1) {
        handles[i] = try group.spawn(squareFn, .{i});
    }

    // Drain results in submission order; concurrent execution is fine
    // because each handle has its own slot.
    var seen: u64 = 0;
    i = 0;
    while (i < TASK_COUNT) : (i += 1) {
        const got = try handles[i].join();
        try std.testing.expectEqual(i *% i, got);
        seen += got;
    }
    try group.join();

    // Sanity: sum_{i=0..99} i*i = 99*100*199/6 = 328350.
    try std.testing.expectEqual(@as(u64, 328350), seen);
}

test "TaskGroup stress: one failure among 100 propagates as first error" {
    var group = async_mod.TaskGroup.init(std.testing.allocator);
    defer group.deinit();

    var i: u32 = 0;
    while (i < TASK_COUNT) : (i += 1) {
        _ = try group.spawn(failingFn, .{i});
    }
    try std.testing.expectError(error.Boom, group.join());
}
