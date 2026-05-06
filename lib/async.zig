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
        // When `true`, the handle was synthesised for a `spawn()` call on
        // an already-cancelled group; no OS thread was started, so
        // `wait()` must NOT call `thread.join()`.
        thread_started: bool = true,
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
            if (self.thread_started) self.thread.join();
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

        // Stance: if the group is already cancelled, do NOT start a new
        // thread. Return a synthesised handle whose state is `.cancelled`
        // so callers see a uniform JoinHandle API and `join()` reports
        // `error.Cancelled` for it like any other cancelled task.
        if (self.cancel_token.isCancelled()) {
            return self.makeCancelledHandle(Handle);
        }

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

    /// Flip the group's `CancellationToken` to cancelled. Cooperative
    /// tasks that poll their token observe it on the next check;
    /// subsequent `spawn`/`spawnWithToken` calls return a synthesised
    /// handle in the `.cancelled` state without starting a thread.
    /// Idempotent.
    pub fn cancel(self: *TaskGroup) void {
        self.cancel_token.cancel();
    }

    pub fn token(self: *TaskGroup) *CancellationToken {
        return &self.cancel_token;
    }

    /// Like `spawn`, but the spawned function's signature is
    /// `fn(token: *CancellationToken, ...args) -> R`: the group's shared
    /// token is passed as the first argument so the task body can poll
    /// `token.isCancelled()` / `token.throwIfCancelled()` without the
    /// caller having to thread the token through a context struct.
    /// `args` here is the *tail* of the argument tuple (everything after
    /// the token).
    pub fn spawnWithToken(self: *TaskGroup, comptime f: anytype, args: anytype) !*JoinHandle(ReturnPayload(@TypeOf(f))) {
        // Build a tuple `(token, args...)` at comptime. The fields of
        // `std.builtin.Type.StructField` are comptime-only, so the field
        // array itself has to live in a comptime block.
        const FullArgs = comptime blk: {
            const TailArgs = @TypeOf(args);
            const tail_info = @typeInfo(TailArgs).@"struct";
            var fields: [tail_info.fields.len + 1]std.builtin.Type.StructField = undefined;
            fields[0] = .{
                .name = "0",
                .type = *CancellationToken,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = @alignOf(*CancellationToken),
            };
            for (tail_info.fields, 0..) |field, i| {
                fields[i + 1] = .{
                    .name = std.fmt.comptimePrint("{d}", .{i + 1}),
                    .type = field.type,
                    .default_value_ptr = null,
                    .is_comptime = false,
                    .alignment = @alignOf(field.type),
                };
            }
            break :blk @Type(.{ .@"struct" = .{
                .layout = .auto,
                .fields = &fields,
                .decls = &.{},
                .is_tuple = true,
            } });
        };
        var full: FullArgs = undefined;
        full[0] = self.token();
        const TailArgs = @TypeOf(args);
        const tail_info = @typeInfo(TailArgs).@"struct";
        inline for (tail_info.fields, 0..) |field, i| {
            @field(full, std.fmt.comptimePrint("{d}", .{i + 1})) = @field(args, field.name);
        }
        return self.spawn(f, full);
    }

    /// Build a `*JoinHandle(Payload)` that is already in the
    /// `.cancelled` state. Used when `spawn` is called on an
    /// already-cancelled group: we want the returned handle to behave
    /// like a normal cancelled task without paying for an OS thread.
    fn makeCancelledHandle(self: *TaskGroup, comptime Handle: type) !*Handle {
        // Empty closure satisfies the `closure`/`closure_drop` invariant
        // — `wait()` is gated by `thread_started`, so the worker code
        // path that would touch a real closure never runs.
        const Empty = struct {
            fn drop(allocator: Allocator, p: *anyopaque) void {
                const c: *@This() = @ptrCast(@alignCast(p));
                allocator.destroy(c);
            }
        };
        const empty = try self.allocator.create(Empty);
        errdefer self.allocator.destroy(empty);

        const handle = try self.allocator.create(Handle);
        errdefer self.allocator.destroy(handle);

        handle.* = .{
            .allocator = self.allocator,
            .thread = undefined,
            .thread_started = false,
            .closure = @ptrCast(empty),
            .closure_drop = Empty.drop,
            .joined = true,
        };
        handle.state.store(@intFromEnum(TaskState.cancelled), .release);

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

        try self.tasks.append(self.allocator, .{
            .handle = @ptrCast(handle),
            .wait_fn = Erased.waitFn,
            .err_fn = Erased.errFn,
            .destroy_fn = Erased.destroyFn,
        });
        return handle;
    }

    /// Wait for every spawned task to finish. If any task fails, the
    /// group's `CancellationToken` is set so cooperative tasks can
    /// short-circuit, and the first error is returned after every task
    /// has been joined (so all worker threads are reaped before return).
    pub fn join(self: *TaskGroup) !void {
        if (self.joined) return;
        self.joined = true;

        // First-error auto-cancel: a tiny watchdog thread polls every
        // handle's non-blocking err_fn and flips the group token as soon
        // as ANY task reports an error, regardless of where that task
        // sits in spawn order. Without this, a failing task that comes
        // after a long-running cooperative task in `tasks.items` would
        // not cancel its sibling until after the wait_fn loop reached
        // the failed handle — which never happens if the long-running
        // task waits on cancellation. The main thread still waits on
        // every handle below so every worker thread is reaped before
        // `join` returns.
        var watchdog_done = std.atomic.Value(bool).init(false);
        const Watchdog = struct {
            fn run(g: *TaskGroup, done: *std.atomic.Value(bool)) void {
                while (!done.load(.acquire)) {
                    for (g.tasks.items) |t| {
                        if (t.err_fn(t.handle)) |_| {
                            g.cancel_token.cancel();
                            return;
                        }
                    }
                    std.Thread.yield() catch {};
                }
            }
        };
        const watchdog = std.Thread.spawn(.{}, Watchdog.run, .{ self, &watchdog_done }) catch null;

        // Pick the most informative error: a real failure beats a
        // `Cancelled` (cancellation is usually a *symptom* of another
        // task's failure or an explicit `group.cancel()`, so propagating
        // the underlying error tells the caller more).
        var first_err: ?anyerror = null;
        for (self.tasks.items) |t| {
            t.wait_fn(t.handle);
            if (t.err_fn(t.handle)) |e| {
                if (first_err == null or (first_err.? == error.Cancelled and e != error.Cancelled)) {
                    first_err = e;
                }
                self.cancel_token.cancel();
            }
        }

        if (watchdog) |w| {
            watchdog_done.store(true, .release);
            w.join();
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

// -- cancellation propagation tests -----------------------------------

const CoopCtx = struct {
    tok: *CancellationToken,
    observed_cancel: *std.atomic.Value(bool),
    iters: u32,
};

fn coopWorker(ctx: *CoopCtx) error{Cancelled}!void {
    var i: u32 = 0;
    while (i < ctx.iters) : (i += 1) {
        if (ctx.tok.isCancelled()) {
            ctx.observed_cancel.store(true, .release);
            return error.Cancelled;
        }
        std.Thread.yield() catch {};
    }
}

fn workerWithToken(tok: *CancellationToken, observed: *std.atomic.Value(bool)) error{Cancelled}!void {
    var i: u32 = 0;
    while (i < 1_000_000) : (i += 1) {
        if (tok.isCancelled()) {
            observed.store(true, .release);
            return error.Cancelled;
        }
        std.Thread.yield() catch {};
    }
}

const FailCtx = struct {
    tok: *CancellationToken,
    observed_cancel: *std.atomic.Value(bool),
};

fn failingFn() error{Boom}!void {
    return error.Boom;
}

fn longCoopFn(ctx: *FailCtx) error{Cancelled}!void {
    var i: u32 = 0;
    // Loop until cancellation is observed (or a generous safety cap to
    // keep a buggy implementation from hanging forever).
    while (i < 5_000_000) : (i += 1) {
        if (ctx.tok.isCancelled()) {
            ctx.observed_cancel.store(true, .release);
            return error.Cancelled;
        }
        std.Thread.yield() catch {};
    }
}

test "TaskGroup.cancel from main thread terminates cooperative tasks before join returns" {
    var group = TaskGroup.init(std.testing.allocator);
    defer group.deinit();

    var observed_a = std.atomic.Value(bool).init(false);
    var observed_b = std.atomic.Value(bool).init(false);
    var observed_c = std.atomic.Value(bool).init(false);
    var ctx_a = CoopCtx{ .tok = group.token(), .observed_cancel = &observed_a, .iters = 5_000_000 };
    var ctx_b = CoopCtx{ .tok = group.token(), .observed_cancel = &observed_b, .iters = 5_000_000 };
    var ctx_c = CoopCtx{ .tok = group.token(), .observed_cancel = &observed_c, .iters = 5_000_000 };

    _ = try group.spawn(coopWorker, .{&ctx_a});
    _ = try group.spawn(coopWorker, .{&ctx_b});
    _ = try group.spawn(coopWorker, .{&ctx_c});

    // Give the workers a brief moment to start spinning so we know cancel
    // is what stops them, not a never-started thread.
    std.Thread.yield() catch {};
    group.cancel();

    try std.testing.expectError(error.Cancelled, group.join());
    try std.testing.expect(observed_a.load(.acquire));
    try std.testing.expect(observed_b.load(.acquire));
    try std.testing.expect(observed_c.load(.acquire));
}

test "TaskGroup first-error auto-cancel propagates to siblings via shared token" {
    var group = TaskGroup.init(std.testing.allocator);
    defer group.deinit();

    var observed_a = std.atomic.Value(bool).init(false);
    var observed_b = std.atomic.Value(bool).init(false);
    var ctx_a = FailCtx{ .tok = group.token(), .observed_cancel = &observed_a };
    var ctx_b = FailCtx{ .tok = group.token(), .observed_cancel = &observed_b };

    _ = try group.spawn(longCoopFn, .{&ctx_a});
    _ = try group.spawn(longCoopFn, .{&ctx_b});
    _ = try group.spawn(failingFn, .{});

    // The first failing handle that `join` reaches flips the token; the
    // long-running coop tasks should pick it up on their next iteration.
    try std.testing.expectError(error.Boom, group.join());
    try std.testing.expect(group.token().isCancelled());
    try std.testing.expect(observed_a.load(.acquire));
    try std.testing.expect(observed_b.load(.acquire));
}

test "TaskGroup.spawnWithToken passes the group token as the first arg" {
    var group = TaskGroup.init(std.testing.allocator);
    defer group.deinit();

    var observed = std.atomic.Value(bool).init(false);
    _ = try group.spawnWithToken(workerWithToken, .{&observed});
    std.Thread.yield() catch {};
    group.cancel();
    try std.testing.expectError(error.Cancelled, group.join());
    try std.testing.expect(observed.load(.acquire));
}

test "TaskGroup.spawn on an already-cancelled group returns a cancelled handle without starting a thread" {
    var group = TaskGroup.init(std.testing.allocator);
    defer group.deinit();

    group.cancel();
    var counter = std.atomic.Value(u32).init(0);
    var ctx = TestCtx{ .counter = &counter, .bump_by = 1 };
    const h = try group.spawn(bumpFn, .{&ctx});
    // No thread ran, so the counter is untouched and the handle is in
    // the cancelled state.
    try std.testing.expectEqual(TaskState.cancelled, h.currentState());
    try std.testing.expectEqual(@as(u32, 0), counter.load(.acquire));
    try std.testing.expectError(error.Cancelled, h.join());
    // group.join() reports the first error (which here is Cancelled).
    try std.testing.expectError(error.Cancelled, group.join());
}
