//! Smart generator for fuzz inputs. Produces (mostly) plausible Zig++
//! source covering trait/impl/owned-struct/const-struct/fn-decl/raw-zig
//! productions, with random injections of attributes, derive blocks,
//! odd identifiers (including keyword-collisions), and whitespace.
//!
//! The generator is depth-bounded so individual inputs stay small enough
//! to be useful as crash repros.

const std = @import("std");

const Random = std.Random;

const Ctx = struct {
    types: std.ArrayList([]const u8) = .{},
    traits: std.ArrayList([]const u8) = .{},

    fn deinit(self: *Ctx, a: std.mem.Allocator) void {
        self.types.deinit(a);
        self.traits.deinit(a);
    }
};

const Buf = struct {
    bytes: std.ArrayList(u8) = .{},
    a: std.mem.Allocator,

    fn write(self: *Buf, s: []const u8) !void {
        try self.bytes.appendSlice(self.a, s);
    }

    fn writeFmt(self: *Buf, comptime fmt: []const u8, args: anytype) !void {
        const tmp = try std.fmt.allocPrint(self.a, fmt, args);
        defer self.a.free(tmp);
        try self.bytes.appendSlice(self.a, tmp);
    }
};

const ident_pool = [_][]const u8{
    "a", "x", "y", "z", "n", "Foo", "Bar", "Baz", "Self", "T", "U", "V",
    "Writer", "Reader", "Iter", "Greeter", "Plugin", "Inner", "Acc",
    // intentional keyword collisions to stress the parser
    "for", "move", "using", "trait", "impl", "dyn", "own", "owned",
};

const type_pool_basic = [_][]const u8{
    "i32", "u64", "f32", "bool", "void", "[]const u8", "usize", "isize",
    "?i32", "[]i32", "*i32", "*const u8", "anyerror!void", "[*]u8",
};

const effect_pool = [_][]const u8{ "alloc", "noalloc", "io", "noio", "panic", "nopanic", "custom" };
const derive_pool = [_][]const u8{ "Hash", "Eq", "Debug", "Json", "Clone" };

fn pickIdent(rng: *Random) []const u8 {
    return ident_pool[rng.intRangeLessThan(usize, 0, ident_pool.len)];
}

fn pickEffect(rng: *Random) []const u8 {
    return effect_pool[rng.intRangeLessThan(usize, 0, effect_pool.len)];
}

fn pickDerive(rng: *Random) []const u8 {
    return derive_pool[rng.intRangeLessThan(usize, 0, derive_pool.len)];
}

fn maybeWs(buf: *Buf, rng: *Random) !void {
    const r = rng.intRangeLessThan(u8, 0, 10);
    switch (r) {
        0 => try buf.write("  "),
        1 => try buf.write("\n"),
        2 => try buf.write("\t"),
        3 => try buf.write("/// doc\n"),
        4 => try buf.write("// c\n"),
        else => try buf.write(" "),
    }
}

fn writeType(buf: *Buf, rng: *Random, ctx: *Ctx, depth: u8) !void {
    if (depth >= 3) {
        try buf.write(type_pool_basic[rng.intRangeLessThan(usize, 0, type_pool_basic.len)]);
        return;
    }
    const r = rng.intRangeLessThan(u8, 0, 10);
    switch (r) {
        0 => {
            try buf.write("*");
            try writeType(buf, rng, ctx, depth + 1);
        },
        1 => {
            try buf.write("?");
            try writeType(buf, rng, ctx, depth + 1);
        },
        2 => {
            try buf.write("[]");
            try writeType(buf, rng, ctx, depth + 1);
        },
        3 => {
            // recently-declared type/trait if available
            if (ctx.types.items.len > 0 and rng.boolean()) {
                try buf.write(ctx.types.items[rng.intRangeLessThan(usize, 0, ctx.types.items.len)]);
                return;
            }
            if (ctx.traits.items.len > 0) {
                try buf.write(ctx.traits.items[rng.intRangeLessThan(usize, 0, ctx.traits.items.len)]);
                return;
            }
            try buf.write(type_pool_basic[rng.intRangeLessThan(usize, 0, type_pool_basic.len)]);
        },
        else => try buf.write(type_pool_basic[rng.intRangeLessThan(usize, 0, type_pool_basic.len)]),
    }
}

fn writeParam(buf: *Buf, rng: *Random, ctx: *Ctx) !void {
    const name = pickIdent(rng);
    try buf.writeFmt("{s}: ", .{name});
    const r = rng.intRangeLessThan(u8, 0, 10);
    switch (r) {
        0 => {
            const tn = if (ctx.traits.items.len > 0)
                ctx.traits.items[rng.intRangeLessThan(usize, 0, ctx.traits.items.len)]
            else
                pickIdent(rng);
            try buf.writeFmt("impl {s}", .{tn});
        },
        1 => {
            const tn = if (ctx.traits.items.len > 0)
                ctx.traits.items[rng.intRangeLessThan(usize, 0, ctx.traits.items.len)]
            else
                pickIdent(rng);
            try buf.writeFmt("dyn {s}", .{tn});
        },
        2 => try buf.write("anytype"),
        else => try writeType(buf, rng, ctx, 0),
    }
}

fn writeParamList(buf: *Buf, rng: *Random, ctx: *Ctx, max: u8) !void {
    const n = rng.intRangeLessThan(u8, 0, max + 1);
    var i: u8 = 0;
    while (i < n) : (i += 1) {
        if (i > 0) try buf.write(", ");
        try writeParam(buf, rng, ctx);
    }
}

fn writeMaybeAttrs(buf: *Buf, rng: *Random) !void {
    if (rng.boolean()) {
        try buf.write(" effects(.");
        try buf.write(pickEffect(rng));
        if (rng.boolean()) {
            try buf.write(", .");
            try buf.write(pickEffect(rng));
        }
        try buf.write(")");
    }
    if (rng.boolean()) {
        try buf.write(" requires(");
        // very small condition expression
        try buf.write(if (rng.boolean()) "true" else "x > 0");
        try buf.write(")");
    }
    if (rng.boolean()) {
        try buf.write(" ensures(");
        try buf.write(if (rng.boolean()) "true" else "n >= 0");
        try buf.write(")");
    }
}

fn writeMaybeWhere(buf: *Buf, rng: *Random, ctx: *Ctx) !void {
    if (!rng.boolean()) return;
    try buf.write(" where T: ");
    if (ctx.traits.items.len > 0) {
        try buf.write(ctx.traits.items[rng.intRangeLessThan(usize, 0, ctx.traits.items.len)]);
    } else {
        try buf.write(pickIdent(rng));
    }
}

fn writeFnDecl(buf: *Buf, rng: *Random, ctx: *Ctx) !void {
    if (rng.boolean()) try buf.write("pub ");
    const name = pickIdent(rng);
    try buf.writeFmt("fn {s}(", .{name});
    try writeParamList(buf, rng, ctx, 3);
    try buf.write(") ");
    try writeType(buf, rng, ctx, 0);
    try writeMaybeWhere(buf, rng, ctx);
    try writeMaybeAttrs(buf, rng);
    if (rng.intRangeLessThan(u8, 0, 10) < 8) {
        try buf.write(" { return undefined; }");
    } else {
        // forward decl
        try buf.write(";");
    }
}

fn writeTrait(buf: *Buf, rng: *Random, ctx: *Ctx) !void {
    const name = pickIdent(rng);
    try ctx.traits.append(buf.a, name);
    if (rng.boolean()) try buf.write("pub ");
    try buf.writeFmt("trait {s} {{ ", .{name});
    const m_count = rng.intRangeLessThan(u8, 1, 3);
    var i: u8 = 0;
    while (i < m_count) : (i += 1) {
        const mn = pickIdent(rng);
        try buf.writeFmt("fn {s}(self", .{mn});
        if (rng.boolean()) {
            try buf.write(", ");
            try writeParam(buf, rng, ctx);
        }
        try buf.write(") ");
        try writeType(buf, rng, ctx, 0);
        try buf.write("; ");
    }
    try buf.write("}");
}

fn writeImpl(buf: *Buf, rng: *Random, ctx: *Ctx) !void {
    const trait = if (ctx.traits.items.len > 0)
        ctx.traits.items[rng.intRangeLessThan(usize, 0, ctx.traits.items.len)]
    else
        pickIdent(rng);
    const target = if (ctx.types.items.len > 0)
        ctx.types.items[rng.intRangeLessThan(usize, 0, ctx.types.items.len)]
    else
        pickIdent(rng);
    try buf.writeFmt("impl {s} for {s} {{ ", .{ trait, target });
    const fn_count = rng.intRangeLessThan(u8, 1, 3);
    var i: u8 = 0;
    while (i < fn_count) : (i += 1) {
        const mn = pickIdent(rng);
        try buf.writeFmt("fn {s}(self", .{mn});
        if (rng.boolean()) {
            try buf.write(", ");
            try writeParam(buf, rng, ctx);
        }
        try buf.write(") ");
        try writeType(buf, rng, ctx, 0);
        try buf.write(" { _ = self; }");
        try buf.write(" ");
    }
    try buf.write("}");
}

fn writeOwnedStruct(buf: *Buf, rng: *Random, ctx: *Ctx) !void {
    const name = pickIdent(rng);
    try ctx.types.append(buf.a, name);
    if (rng.boolean()) try buf.write("pub ");
    try buf.writeFmt("owned struct {s} {{ ", .{name});
    // 0-3 fields
    const fc = rng.intRangeLessThan(u8, 0, 3);
    var i: u8 = 0;
    while (i < fc) : (i += 1) {
        try buf.writeFmt("{s}: ", .{pickIdent(rng)});
        try writeType(buf, rng, ctx, 0);
        try buf.write(", ");
    }
    // Maybe a deinit (intentionally sometimes omit to surface Z0010)
    if (rng.intRangeLessThan(u8, 0, 4) != 0) {
        try buf.writeFmt("pub fn deinit(self: *{s}) void {{ _ = self; }} ", .{name});
    }
    try buf.write("}");
    if (rng.boolean()) {
        try buf.write(" derive(.{ ");
        try buf.write(pickDerive(rng));
        if (rng.boolean()) {
            try buf.write(", ");
            try buf.write(pickDerive(rng));
        }
        try buf.write(" });");
    }
}

fn writeConstStruct(buf: *Buf, rng: *Random, ctx: *Ctx) !void {
    const name = pickIdent(rng);
    try ctx.types.append(buf.a, name);
    if (rng.boolean()) try buf.write("pub ");
    try buf.writeFmt("const {s} = struct {{ ", .{name});
    const fc = rng.intRangeLessThan(u8, 0, 3);
    var i: u8 = 0;
    while (i < fc) : (i += 1) {
        try buf.writeFmt("{s}: ", .{pickIdent(rng)});
        try writeType(buf, rng, ctx, 0);
        try buf.write(", ");
    }
    try buf.write("};");
    if (rng.boolean()) {
        try buf.write(" derive(.{ ");
        try buf.write(pickDerive(rng));
        try buf.write(" });");
    }
}

fn writeRawChunk(buf: *Buf, rng: *Random) !void {
    const choices = [_][]const u8{
        "const x = 1;",
        "const std = @import(\"std\");",
        "var counter: i32 = 0;",
        "test \"smoke\" { try std.testing.expect(true); }",
        "comptime { _ = 1; }",
    };
    try buf.write(choices[rng.intRangeLessThan(usize, 0, choices.len)]);
}

fn writeTopDecl(buf: *Buf, rng: *Random, ctx: *Ctx) !void {
    const r = rng.intRangeLessThan(u8, 0, 10);
    switch (r) {
        0, 1 => try writeTrait(buf, rng, ctx),
        2 => try writeImpl(buf, rng, ctx),
        3, 4 => try writeOwnedStruct(buf, rng, ctx),
        5, 6 => try writeConstStruct(buf, rng, ctx),
        7, 8 => try writeFnDecl(buf, rng, ctx),
        else => try writeRawChunk(buf, rng),
    }
}

/// Generate a freshly-allocated Zig++ source string. Caller owns the slice.
pub fn generate(allocator: std.mem.Allocator, rng: *Random) ![]u8 {
    var buf = Buf{ .a = allocator };
    errdefer buf.bytes.deinit(allocator);
    var ctx = Ctx{};
    defer ctx.deinit(allocator);

    const n = rng.intRangeLessThan(u8, 1, 6);
    var i: u8 = 0;
    while (i < n) : (i += 1) {
        try writeTopDecl(&buf, rng, &ctx);
        try maybeWs(&buf, rng);
        try buf.write("\n");
    }
    return buf.bytes.toOwnedSlice(allocator);
}

/// Best-effort delta-debugging shrinker. Tries dropping individual lines
/// and keeps the smallest variant for which `still_crashes` returns true.
/// Caller must dispose the returned slice via `allocator.free`.
pub fn shrink(
    allocator: std.mem.Allocator,
    src: []const u8,
    ctx: anytype,
    still_crashes: *const fn (@TypeOf(ctx), []const u8) bool,
) ![]u8 {
    var current = try allocator.dupe(u8, src);
    var attempts: usize = 0;
    while (attempts < 50) : (attempts += 1) {
        var lines: std.ArrayList([]const u8) = .{};
        defer lines.deinit(allocator);
        var it = std.mem.splitScalar(u8, current, '\n');
        while (it.next()) |line| try lines.append(allocator, line);
        if (lines.items.len <= 1) break;

        var made_progress = false;
        var idx: usize = 0;
        while (idx < lines.items.len) : (idx += 1) {
            // Build candidate with line idx removed.
            var cand: std.ArrayList(u8) = .{};
            defer cand.deinit(allocator);
            for (lines.items, 0..) |l, j| {
                if (j == idx) continue;
                if (cand.items.len > 0) try cand.append(allocator, '\n');
                try cand.appendSlice(allocator, l);
            }
            if (still_crashes(ctx, cand.items)) {
                allocator.free(current);
                current = try allocator.dupe(u8, cand.items);
                made_progress = true;
                break;
            }
        }
        if (!made_progress) break;
    }
    return current;
}
