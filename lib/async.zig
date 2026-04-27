//! Structured concurrency scaffolding.
//!
//! MVP serial executor: `spawn` records a closure, `join` runs them in
//! submission order on the calling thread. Will be replaced by Zig 0.17+ I/O
//! interface (Io.async / Io.cancel) once stable.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const CancellationToken = struct {
    flag: std.atomic.Value(bool) = .{ .raw = false },

    pub fn init() CancellationToken {
        return .{};
    }

    pub fn cancel(self: *CancellationToken) void {
        self.flag.store(true, .release);
    }

    pub fn isCancelled(self: *const CancellationToken) bool {
        return @atomicLoad(bool, &self.flag.raw, .acquire);
    }

    pub fn throwIfCancelled(self: *const CancellationToken) error{Cancelled}!void {
        if (self.isCancelled()) return error.Cancelled;
    }
};

pub const TaskState = enum(u8) { pending, running, done, failed, cancelled };

const TaskRunFn = *const fn (*Task) anyerror!void;

pub const Task = struct {
    allocator: Allocator,
    state: TaskState = .pending,
    err: ?anyerror = null,
    run_fn: TaskRunFn,
    closure: *anyopaque,
    closure_drop: *const fn (Allocator, *anyopaque) void,

    pub fn isDone(self: *const Task) bool {
        return switch (self.state) {
            .done, .failed, .cancelled => true,
            else => false,
        };
    }

    pub fn destroy(self: *Task) void {
        self.closure_drop(self.allocator, self.closure);
        self.allocator.destroy(self);
    }
};

pub const TaskGroup = struct {
    allocator: Allocator,
    tasks: std.ArrayList(*Task),
    cancel_token: CancellationToken = .{},
    joined: bool = false,

    pub fn init(a: Allocator) TaskGroup {
        return .{
            .allocator = a,
            .tasks = .{},
        };
    }

    pub fn spawn(self: *TaskGroup, comptime f: anytype, args: anytype) !*Task {
        const Args = @TypeOf(args);
        const Closure = struct {
            args: Args,
            fn run(task: *Task) anyerror!void {
                const c: *@This() = @ptrCast(@alignCast(task.closure));
                const RetT = @typeInfo(@TypeOf(f)).@"fn".return_type orelse void;
                if (@typeInfo(RetT) == .error_union) {
                    _ = try @call(.auto, f, c.args);
                } else {
                    _ = @call(.auto, f, c.args);
                }
            }
            fn drop(a: Allocator, p: *anyopaque) void {
                const c: *@This() = @ptrCast(@alignCast(p));
                a.destroy(c);
            }
        };

        const closure = try self.allocator.create(Closure);
        closure.* = .{ .args = args };

        const task = try self.allocator.create(Task);
        task.* = .{
            .allocator = self.allocator,
            .run_fn = Closure.run,
            .closure = @ptrCast(closure),
            .closure_drop = Closure.drop,
        };
        try self.tasks.append(self.allocator, task);
        return task;
    }

    pub fn cancel(self: *TaskGroup) void {
        self.cancel_token.cancel();
    }

    pub fn token(self: *TaskGroup) *CancellationToken {
        return &self.cancel_token;
    }

    /// Run all spawned tasks to completion in submission order. Returns the
    /// first error encountered; remaining tasks still run so their resources
    /// can be released.
    pub fn join(self: *TaskGroup) !void {
        if (self.joined) return;
        self.joined = true;
        var first_err: ?anyerror = null;
        for (self.tasks.items) |task| {
            if (self.cancel_token.isCancelled()) {
                task.state = .cancelled;
                continue;
            }
            task.state = .running;
            if (task.run_fn(task)) |_| {
                task.state = .done;
            } else |e| {
                task.state = .failed;
                task.err = e;
                if (first_err == null) first_err = e;
            }
        }
        if (first_err) |e| return e;
    }

    pub fn deinit(self: *TaskGroup) void {
        for (self.tasks.items) |task| task.destroy();
        self.tasks.deinit(self.allocator);
        self.* = undefined;
    }
};

/// Sleep stub: real implementation will route through `std.Io` once 0.17 lands.
pub fn yieldNow() void {
    std.Thread.yield() catch {};
}

const TestCtx = struct { counter: *u32, bump_by: u32 };

fn bumpFn(ctx: *TestCtx) void {
    ctx.counter.* += ctx.bump_by;
}

fn boomFn() error{Boom}!void {
    return error.Boom;
}

test "TaskGroup runs spawned tasks in order on join" {
    var group = TaskGroup.init(std.testing.allocator);
    defer group.deinit();

    var counter: u32 = 0;
    var ctx_a = TestCtx{ .counter = &counter, .bump_by = 1 };
    var ctx_b = TestCtx{ .counter = &counter, .bump_by = 10 };
    var ctx_c = TestCtx{ .counter = &counter, .bump_by = 100 };

    _ = try group.spawn(bumpFn, .{&ctx_a});
    _ = try group.spawn(bumpFn, .{&ctx_b});
    _ = try group.spawn(bumpFn, .{&ctx_c});

    try group.join();
    try std.testing.expectEqual(@as(u32, 111), counter);
}

test "TaskGroup propagates first error" {
    var group = TaskGroup.init(std.testing.allocator);
    defer group.deinit();
    _ = try group.spawn(boomFn, .{});
    try std.testing.expectError(error.Boom, group.join());
}

test "CancellationToken is observable across spawn" {
    var tok = CancellationToken.init();
    try std.testing.expect(!tok.isCancelled());
    tok.cancel();
    try std.testing.expect(tok.isCancelled());
    try std.testing.expectError(error.Cancelled, tok.throwIfCancelled());
}
