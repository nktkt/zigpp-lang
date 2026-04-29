//! Structured concurrency built on `std.Thread`.
//!
//! `TaskGroup` owns a set of concurrent worker threads. `spawn` launches a
//! task immediately on its own OS thread and returns a typed
//! `*JoinHandle(T)`; the caller can `join()` that handle to retrieve the
//! result, or ignore it and rely on `TaskGroup.join()` to wait on every
//! task. If any task fails, the group's `CancellationToken` is set so
//! cooperative tasks can short-circuit, and the first error is returned
//! after every task has been joined.
//!
//! When Zig 0.17+ `Io.async` / `Io.cancel` stabilise we will swap the
//! `std.Thread` implementation for cooperative tasks behind the same
//! surface — `JoinHandle(T)` is the public seam that lets that happen
//! without churning callers.

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

/// Typed handle to a single spawned task. Callers can:
///   * poll `isDone()` without blocking,
///   * block with `wait()` (no result), or
///   * block + retrieve the typed result with `join()`.
///
/// Lifetime: the handle is owned by the `TaskGroup` that produced it.
/// `TaskGroup.deinit()` joins and destroys every still-live handle.
pub fn JoinHandle(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Result = T;

        allocator: Allocator,
        thread: std.Thread,
        // Written by the worker before the .release store of `state`, read
        // by the joiner after the matching .acquire load (or after
        // `thread.join()` returns). No locking required.
        result: ResultSlot = if (T == void) {} else undefined,
        err: ?anyerror = null,
        state: std.atomic.Value(u8) = .{ .raw = @intFromEnum(TaskState.pending) },
        joined: bool = false,
        closure: *anyopaque,
        closure_drop: *const fn (Allocator, *anyopaque) void,

        const ResultSlot = if (T == void) void else T;

        pub fn currentState(self: *const Self) TaskState {
            return @enumFromInt(self.state.load(.acquire));
        }

        pub fn isDone(self: *const Self) bool {
            return switch (self.currentState()) {
                .done, .failed, .cancelled => true,
                else => false,
            };
        }

        /// Block until the task finishes. Idempotent.
        pub fn wait(self: *Self) void {
            if (self.joined) return;
            self.thread.join();
            self.joined = true;
        }

        /// Block until the task finishes and return its typed result.
        /// Errors raised inside the task are propagated. Calling `join`
        /// twice returns the same outcome.
        pub fn join(self: *Self) !T {
            self.wait();
            return switch (self.currentState()) {
                .done => if (T == void) {} else self.result,
                .failed => self.err orelse error.TaskFailed,
                .cancelled => error.Cancelled,
                .pending, .running => unreachable,
            };
        }

        /// Tear down the handle. Joins the worker first so the closure
        /// storage is never freed under a live thread.
        pub fn destroy(self: *Self) void {
            self.wait();
            self.closure_drop(self.allocator, self.closure);
            self.allocator.destroy(self);
        }
    };
}

/// Backwards-compat alias: a `Task` is a `JoinHandle(void)`. Code that
/// discards the spawn result (`_ = try group.spawn(f, args)`) keeps
/// compiling for `void`-returning `f`.
pub const Task = JoinHandle(void);

/// Type-erased entry stored in `TaskGroup.tasks`. Each entry remembers
/// just enough to wait on, query, and destroy its concrete
/// `*JoinHandle(T)` without the group caring what `T` is.
const TrackedTask = struct {
    handle: *anyopaque,
    wait_fn: *const fn (*anyopaque) void,
    err_fn: *const fn (*anyopaque) ?anyerror,
    destroy_fn: *const fn (*anyopaque) void,
};

pub const TaskGroup = struct {
    allocator: Allocator,
    tasks: std.ArrayList(TrackedTask),
    cancel_token: CancellationToken = .{},
    joined: bool = false,

    pub fn init(a: Allocator) TaskGroup {
        return .{
            .allocator = a,
            .tasks = .{},
        };
    }

    pub fn spawn(self: *TaskGroup, comptime f: anytype, args: anytype) !*JoinHandle(ReturnPayload(@TypeOf(f))) {
        if (self.joined) return error.GroupAlreadyJoined;

        const F = @TypeOf(f);
        const Payload = ReturnPayload(F);
        const Handle = JoinHandle(Payload);
        const Args = @TypeOf(args);
        const ret_is_error_union = @typeInfo(@typeInfo(F).@"fn".return_type orelse void) == .error_union;

        const Closure = struct {
            args: Args,
            handle: *Handle,

            fn entry(c: *@This()) void {
                c.handle.state.store(@intFromEnum(TaskState.running), .release);
                if (ret_is_error_union) {
                    if (@call(.auto, f, c.args)) |val| {
                        if (Payload != void) c.handle.result = val;
                        c.handle.state.store(@intFromEnum(TaskState.done), .release);
                    } else |e| {
                        c.handle.err = e;
                        c.handle.state.store(@intFromEnum(TaskState.failed), .release);
                    }
                } else {
                    const v = @call(.auto, f, c.args);
                    if (Payload != void) c.handle.result = v;
                    c.handle.state.store(@intFromEnum(TaskState.done), .release);
                }
            }

            fn drop(allocator: Allocator, p: *anyopaque) void {
                const c: *@This() = @ptrCast(@alignCast(p));
                allocator.destroy(c);
            }
        };

        // Erased vtable methods bound to this concrete `Handle` type.
        const Erased = struct {
            fn waitFn(p: *anyopaque) void {
                const h: *Handle = @ptrCast(@alignCast(p));
                h.wait();
            }
            fn errFn(p: *anyopaque) ?anyerror {
                const h: *Handle = @ptrCast(@alignCast(p));
                return switch (h.currentState()) {
                    .failed => h.err orelse error.TaskFailed,
                    .cancelled => error.Cancelled,
                    else => null,
                };
            }
            fn destroyFn(p: *anyopaque) void {
                const h: *Handle = @ptrCast(@alignCast(p));
                h.destroy();
            }
        };

        const handle = try self.allocator.create(Handle);
        errdefer self.allocator.destroy(handle);

        const closure = try self.allocator.create(Closure);
        errdefer self.allocator.destroy(closure);

        // Initialize handle/closure BEFORE spawning the thread: the worker
        // touches `state`, `result`, `err`, and `closure.handle`, so they
        // must be valid when `std.Thread.spawn` returns. `handle.thread`
        // is left undefined here and filled in below; the worker never
        // reads it.
        handle.* = .{
            .allocator = self.allocator,
            .thread = undefined,
            .closure = @ptrCast(closure),
            .closure_drop = Closure.drop,
        };
        closure.* = .{ .args = args, .handle = handle };

        // Reserve the slot before spawning so that the post-spawn append
        // cannot fail and leak a live thread.
        try self.tasks.ensureUnusedCapacity(self.allocator, 1);

        const thread = try std.Thread.spawn(.{}, Closure.entry, .{closure});
        handle.thread = thread;

        self.tasks.appendAssumeCapacity(.{
            .handle = @ptrCast(handle),
            .wait_fn = Erased.waitFn,
            .err_fn = Erased.errFn,
            .destroy_fn = Erased.destroyFn,
        });
        return handle;
    }

    pub fn cancel(self: *TaskGroup) void {
        self.cancel_token.cancel();
    }

    pub fn token(self: *TaskGroup) *CancellationToken {
        return &self.cancel_token;
    }

    /// Wait for every spawned task to finish. If any task fails, the
    /// group's `CancellationToken` is set so cooperative tasks can
    /// short-circuit, and the first error is returned after every task
    /// has been joined (so all worker threads are reaped before return).
    pub fn join(self: *TaskGroup) !void {
        if (self.joined) return;
        self.joined = true;

        var first_err: ?anyerror = null;
        for (self.tasks.items) |t| {
            t.wait_fn(t.handle);
            if (first_err == null) {
                if (t.err_fn(t.handle)) |e| {
                    first_err = e;
                    self.cancel_token.cancel();
                }
            }
        }
        if (first_err) |e| return e;
    }

    pub fn deinit(self: *TaskGroup) void {
        for (self.tasks.items) |t| t.destroy_fn(t.handle);
        self.tasks.deinit(self.allocator);
        self.* = undefined;
    }
};

/// Strip an optional error union, returning the payload type. For
/// non-error-union return types this is the type itself.
fn ReturnPayload(comptime F: type) type {
    const fn_info = @typeInfo(F).@"fn";
    const ret = fn_info.return_type orelse void;
    const ri = @typeInfo(ret);
    return if (ri == .error_union) ri.error_union.payload else ret;
}

/// Sleep stub: real implementation will route through `std.Io` once 0.17
/// lands.
pub fn yieldNow() void {
    std.Thread.yield() catch {};
}

// -- tests -------------------------------------------------------------

const TestCtx = struct {
    counter: *std.atomic.Value(u32),
    bump_by: u32,
};

fn bumpFn(ctx: *TestCtx) void {
    _ = ctx.counter.fetchAdd(ctx.bump_by, .monotonic);
}

fn boomFn() error{Boom}!void {
    return error.Boom;
}

fn squareFn(x: u32) u32 {
    return x *% x;
}

fn cancellableFn(ctx: *CancellableCtx) error{Cancelled}!u32 {
    var spins: u32 = 0;
    while (spins < 1_000_000) : (spins += 1) {
        try ctx.tok.throwIfCancelled();
        std.Thread.yield() catch {};
    }
    return 0;
}

const CancellableCtx = struct { tok: *CancellationToken };

test "TaskGroup runs spawned tasks concurrently and waits on join" {
    var group = TaskGroup.init(std.testing.allocator);
    defer group.deinit();

    var counter = std.atomic.Value(u32).init(0);
    var ctx_a = TestCtx{ .counter = &counter, .bump_by = 1 };
    var ctx_b = TestCtx{ .counter = &counter, .bump_by = 10 };
    var ctx_c = TestCtx{ .counter = &counter, .bump_by = 100 };

    _ = try group.spawn(bumpFn, .{&ctx_a});
    _ = try group.spawn(bumpFn, .{&ctx_b});
    _ = try group.spawn(bumpFn, .{&ctx_c});

    try group.join();
    try std.testing.expectEqual(@as(u32, 111), counter.load(.acquire));
}

test "TaskGroup propagates first error" {
    var group = TaskGroup.init(std.testing.allocator);
    defer group.deinit();
    _ = try group.spawn(boomFn, .{});
    try std.testing.expectError(error.Boom, group.join());
}

test "JoinHandle(T).join returns the typed result" {
    var group = TaskGroup.init(std.testing.allocator);
    defer group.deinit();
    const h = try group.spawn(squareFn, .{@as(u32, 7)});
    try std.testing.expectEqual(@as(u32, 49), try h.join());
    // group.join() after individual h.join() must be a no-op: the
    // erased wait_fn delegates to JoinHandle.wait() which is idempotent.
    try group.join();
}

test "TaskGroup.cancel signals cooperative tasks via the shared token" {
    var group = TaskGroup.init(std.testing.allocator);
    defer group.deinit();
    var ctx = CancellableCtx{ .tok = group.token() };
    _ = try group.spawn(cancellableFn, .{&ctx});
    group.cancel();
    try std.testing.expectError(error.Cancelled, group.join());
}

test "CancellationToken is observable across spawn" {
    var tok = CancellationToken.init();
    try std.testing.expect(!tok.isCancelled());
    tok.cancel();
    try std.testing.expect(tok.isCancelled());
    try std.testing.expectError(error.Cancelled, tok.throwIfCancelled());
}
