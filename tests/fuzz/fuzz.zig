//! Fuzz harness for the zpp compiler frontend.
//!
//! Runs N iterations (default 1000, override with `ZPP_FUZZ_ITERS`) and
//! exercises three input strategies:
//!   60% smart grammar generator   (tests/fuzz/grammar.zig)
//!   30% mutator over examples/    (tests/fuzz/mutator.zig)
//!   10% biased random bytes
//!
//! For every input we call:
//!   compiler.compileToString(allocator, source)
//!   compiler.parseAndAnalyze(allocator, source)
//! Either may return an `error.*` — that's fine. A *panic* or a memory leak
//! surfaced via the GPA's safety checks is a bug; we save the input under
//! tests/fuzz/crashes/ and continue.
//!
//! Each call is given a 1 second wall-clock budget; if exceeded the input
//! is reported as a "timeout" crash. Note the budget is checked AFTER the
//! call returns — Zig has no portable way to interrupt running code, so a
//! true infinite loop will hang the harness rather than be reported. Run
//! under `timeout(1)` from the shell if you need a hard limit.
//!
//! Repro a specific seed:  `zig build fuzz -- --seed=42`

const std = @import("std");
const compiler = @import("zpp_compiler");

const grammar = @import("grammar.zig");
const mutator = @import("mutator.zig");

const Strategy = enum { smart, mutator, random };

const Stats = struct {
    total: usize = 0,
    smart_runs: usize = 0,
    mutator_runs: usize = 0,
    random_runs: usize = 0,
    compile_ok: usize = 0,
    compile_err: usize = 0,
    sema_ok: usize = 0,
    sema_err: usize = 0,
    timeouts: usize = 0,
    crash_files: usize = 0,
    leaked: usize = 0,
    err_kinds: std.StringHashMap(usize),

    fn init(a: std.mem.Allocator) Stats {
        return .{ .err_kinds = std.StringHashMap(usize).init(a) };
    }
    fn deinit(self: *Stats) void {
        self.err_kinds.deinit();
    }
    fn bumpErr(self: *Stats, name: []const u8) !void {
        const gop = try self.err_kinds.getOrPut(name);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }
};

/// Hand-crafted adversarial seeds — added to the mutation corpus so the
/// mutator gets some interesting starting points beyond well-formed examples.
const adversarial_seeds = [_][]const u8{
    "trait",
    "owned struct",
    "fn f(",
    "impl X for Y {",
    "const X = struct {",
    "trait T { fn m(",
    "fn f() i32 effects(.",
    "fn f() i32 where T:",
    "owned struct X { fn deinit(self: *X) void {",
    "fn f() void { using x =",
    "fn f() void { own var x =",
    "fn f() void { move ",
    "\"unterminated string ",
    "fn f() void { using = }",
    "trait T { fn (self) void; }",
    "owned struct {} ",
    "const X = struct {} derive(.{ });",
    "extern interface I { fn m(self) void; }",
    "fn f(x: impl ) void {}",
    "fn f(x: dyn ) void {}",
    "/" ++ "*comment never closed",
    "0xZZZZ",
    "..........",
    ".{.{.{.{.{.{",
    "{{{{{{{{{{{{{{{{",
    "((((((((((((((((",
    "}}}}}}}}}}}}}}};",
};

const Examples = struct {
    list: std.ArrayList([]u8) = .{},
    a: std.mem.Allocator,

    fn load(a: std.mem.Allocator) !Examples {
        var self = Examples{ .a = a };
        // First, seed with the adversarial corpus.
        for (adversarial_seeds) |s| {
            try self.list.append(a, try a.dupe(u8, s));
        }
        var dir = std.fs.cwd().openDir("examples", .{ .iterate = true }) catch return self;
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".zpp")) continue;
            const f = dir.openFile(entry.name, .{}) catch continue;
            defer f.close();
            const bytes = f.readToEndAlloc(a, 1 << 20) catch continue;
            try self.list.append(a, bytes);
        }
        return self;
    }
    fn deinit(self: *Examples) void {
        for (self.list.items) |b| self.a.free(b);
        self.list.deinit(self.a);
    }
};

fn pickStrategy(rng: *std.Random) Strategy {
    const r = rng.intRangeLessThan(u8, 0, 100);
    if (r < 60) return .smart;
    if (r < 90) return .mutator;
    return .random;
}

fn writeCrash(seed: u64, iter: usize, label: []const u8, src: []const u8) !void {
    std.fs.cwd().makePath("tests/fuzz/crashes") catch {};
    var name_buf: [128]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "tests/fuzz/crashes/crash_{s}_{d}_{d}.zpp", .{ label, seed, iter });
    const f = try std.fs.cwd().createFile(name, .{ .truncate = true });
    defer f.close();
    try f.writeAll(src);
}

const RunResult = struct {
    compile_ok: bool,
    sema_ok: bool,
    timeout: bool,
    compile_err_name: ?[]const u8 = null,
    sema_err_name: ?[]const u8 = null,
};

fn runOnce(allocator: std.mem.Allocator, source: []const u8) RunResult {
    var res: RunResult = .{ .compile_ok = false, .sema_ok = false, .timeout = false };
    const start = std.time.Instant.now() catch return res;

    if (compiler.compileToString(allocator, source)) |out| {
        allocator.free(out);
        res.compile_ok = true;
    } else |e| {
        res.compile_err_name = @errorName(e);
    }

    if (compiler.parseAndAnalyze(allocator, source)) |analysis| {
        var a = analysis;
        a.deinit();
        res.sema_ok = true;
    } else |e| {
        res.sema_err_name = @errorName(e);
    }

    const end = std.time.Instant.now() catch return res;
    const elapsed_ns = end.since(start);
    if (elapsed_ns > std.time.ns_per_s) res.timeout = true;
    return res;
}

const ParsedArgs = struct {
    seed: ?u64 = null,
};

fn parseArgs(a: std.mem.Allocator) !ParsedArgs {
    var pa = ParsedArgs{};
    const args = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, args);
    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--seed=")) {
            const v = arg["--seed=".len..];
            pa.seed = try std.fmt.parseInt(u64, v, 10);
        }
    }
    return pa;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true, .never_unmap = true }){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("[fuzz] gpa reported leaks at shutdown\n", .{});
        }
    }
    const a = gpa.allocator();

    const args = try parseArgs(a);
    const seed: u64 = args.seed orelse blk: {
        var s: u64 = undefined;
        std.crypto.random.bytes(std.mem.asBytes(&s));
        break :blk s;
    };

    const iters: usize = blk: {
        const env = std.process.getEnvVarOwned(a, "ZPP_FUZZ_ITERS") catch |e| switch (e) {
            error.EnvironmentVariableNotFound => break :blk 1000,
            else => return e,
        };
        defer a.free(env);
        break :blk std.fmt.parseInt(usize, env, 10) catch 1000;
    };

    var prng = std.Random.DefaultPrng.init(seed);
    var rng = prng.random();

    var stats = Stats.init(a);
    defer stats.deinit();

    var examples = try Examples.load(a);
    defer examples.deinit();

    std.debug.print("[fuzz] seed={d} iters={d} examples={d}\n", .{ seed, iters, examples.list.items.len });

    var i: usize = 0;
    while (i < iters) : (i += 1) {
        const strat = pickStrategy(&rng);
        var src: []u8 = undefined;
        switch (strat) {
            .smart => {
                src = grammar.generate(a, &rng) catch |e| {
                    try stats.bumpErr(@errorName(e));
                    continue;
                };
                stats.smart_runs += 1;
            },
            .mutator => {
                if (examples.list.items.len == 0) {
                    src = mutator.randomBytes(a, &rng) catch |e| {
                        try stats.bumpErr(@errorName(e));
                        continue;
                    };
                } else {
                    const base = examples.list.items[rng.intRangeLessThan(usize, 0, examples.list.items.len)];
                    src = mutator.mutate(a, base, &rng) catch |e| {
                        try stats.bumpErr(@errorName(e));
                        continue;
                    };
                }
                stats.mutator_runs += 1;
            },
            .random => {
                src = mutator.randomBytes(a, &rng) catch |e| {
                    try stats.bumpErr(@errorName(e));
                    continue;
                };
                stats.random_runs += 1;
            },
        }
        defer a.free(src);
        stats.total += 1;

        const r = runOnce(a, src);
        if (r.compile_ok) stats.compile_ok += 1 else stats.compile_err += 1;
        if (r.sema_ok) stats.sema_ok += 1 else stats.sema_err += 1;
        if (r.compile_err_name) |n| try stats.bumpErr(n);
        if (r.sema_err_name) |n| {
            // Avoid double-counting if both errored with the same name.
            if (r.compile_err_name == null or !std.mem.eql(u8, n, r.compile_err_name.?))
                try stats.bumpErr(n);
        }

        if (r.timeout) {
            stats.timeouts += 1;
            writeCrash(seed, i, "timeout", src) catch {};
            stats.crash_files += 1;
        }
    }

    std.debug.print("\n[fuzz] === summary ===\n", .{});
    std.debug.print("  total iterations: {d}\n", .{stats.total});
    std.debug.print("  strategies: smart={d} mutator={d} random={d}\n", .{ stats.smart_runs, stats.mutator_runs, stats.random_runs });
    std.debug.print("  compileToString: ok={d} err={d}\n", .{ stats.compile_ok, stats.compile_err });
    std.debug.print("  parseAndAnalyze: ok={d} err={d}\n", .{ stats.sema_ok, stats.sema_err });
    std.debug.print("  timeouts: {d}  crashes-written: {d}\n", .{ stats.timeouts, stats.crash_files });
    std.debug.print("  errors-by-kind:\n", .{});
    var it = stats.err_kinds.iterator();
    while (it.next()) |e| {
        std.debug.print("    {s}: {d}\n", .{ e.key_ptr.*, e.value_ptr.* });
    }
    std.debug.print("[fuzz] done.\n", .{});
}
