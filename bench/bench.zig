//! Microbenchmarks for the zpp compiler.
//!
//! Generates synthetic `.zpp` inputs of increasing size and measures the
//! cost of `compileToString` (parse + sema + lower) plus the size of the
//! emitted `.zig`. Prints a table to stdout suitable for pasting into
//! docs/src/perf.md.
//!
//! Usage: `zig build bench` or `zig run bench/bench.zig --dep zpp_compiler ...`.

const std = @import("std");
const compiler = @import("zpp_compiler");

const Sample = struct {
    label: []const u8,
    decls: usize,
    bytes_in: usize,
    bytes_out: usize,
    ns_per_iter: u64,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const sizes = [_]usize{ 10, 100, 1_000, 5_000, 10_000 };
    const iters_for = [_]u32{ 200, 50, 10, 5, 3 };

    var stdout_buf: [16 * 1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const w = &stdout_writer.interface;
    defer w.flush() catch {};

    try w.print("# zpp lowering benchmarks\n\n", .{});
    try w.print("Compiled with mode={s}.\n\n", .{@tagName(@import("builtin").mode)});
    try w.print("| decls | input bytes | output bytes | iters | total ms | µs / iter | bytes/sec |\n", .{});
    try w.print("|------:|------------:|-------------:|------:|---------:|----------:|----------:|\n", .{});

    for (sizes, 0..) |n, i| {
        const iters = iters_for[i];
        const src = try synthesize(allocator, n);
        defer allocator.free(src);

        // Warm-up.
        {
            const out = try compiler.compileToString(allocator, src);
            allocator.free(out);
        }

        var total_ns: u64 = 0;
        var bytes_out: usize = 0;
        var k: u32 = 0;
        while (k < iters) : (k += 1) {
            const t0 = std.time.nanoTimestamp();
            const out = try compiler.compileToString(allocator, src);
            const t1 = std.time.nanoTimestamp();
            total_ns += @intCast(t1 - t0);
            bytes_out = out.len;
            allocator.free(out);
        }
        const ns_per = total_ns / iters;
        const us_per: f64 = @as(f64, @floatFromInt(ns_per)) / 1_000.0;
        const total_ms: f64 = @as(f64, @floatFromInt(total_ns)) / 1_000_000.0;
        const bps: f64 = if (ns_per == 0) 0 else @as(f64, @floatFromInt(src.len)) * 1_000_000_000.0 / @as(f64, @floatFromInt(ns_per));
        try w.print(
            "| {d:>5} | {d:>11} | {d:>12} | {d:>5} | {d:>8.2} | {d:>9.1} | {d:>9.0} |\n",
            .{ n, src.len, bytes_out, iters, total_ms, us_per, bps },
        );
    }

    try w.print("\n_bytes/sec measured against input size, not output. Lowering output is normally 1.5x–3x larger than input due to vtable / thunk emission._\n", .{});
}

/// Build a synthetic source file with `n_decls` top-level declarations.
/// Each block is a small impl + trait + owned struct so the parser, sema, and
/// lowerer all do meaningful work.
fn synthesize(allocator: std.mem.Allocator, n_decls: usize) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator,
        \\const std = @import("std");
        \\const zpp = @import("zpp");
        \\
        \\
    );

    var i: usize = 0;
    while (i < n_decls) : (i += 1) {
        const fmt =
            \\trait Tr_{0d} {{
            \\    fn step_{0d}(self, x: i32) i32;
            \\}}
            \\const S_{0d} = struct {{
            \\    seed: i32,
            \\}};
            \\impl Tr_{0d} for S_{0d} {{
            \\    fn step_{0d}(self, x: i32) i32 {{
            \\        return self.seed + x + {0d};
            \\    }}
            \\}}
            \\fn caller_{0d}(s: dyn Tr_{0d}, n: i32) i32 {{
            \\    return s.vtable.step_{0d}(s.ptr, n);
            \\}}
            \\
            \\
        ;
        const chunk = try std.fmt.allocPrint(allocator, fmt, .{i});
        defer allocator.free(chunk);
        try buf.appendSlice(allocator, chunk);
    }

    return buf.toOwnedSlice(allocator);
}
