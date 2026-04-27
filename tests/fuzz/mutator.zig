//! Source-mutator. Takes an existing input and applies one randomized
//! transformation. Returns a freshly-allocated buffer (caller frees).
//!
//! Mutations are intentionally cheap and ascii-biased so produced inputs
//! often remain partially syntactically meaningful.

const std = @import("std");
const Random = std.Random;

const Mutation = enum {
    byte_flip,
    splice,
    delete_chunk,
    duplicate_chunk,
    insert_keyword,
};

const inserts = [_][]const u8{
    "trait ", "impl ", "for ", "dyn ", "using ", "move ", "own ",
    "owned struct ", "fn ", "pub ", "const ", "var ", "extern ",
    "interface ", "where ", "requires(", "ensures(", "effects(.alloc)",
    "derive(.{ Hash })", "anytype", "self", "Self", ";", "{", "}", "(", ")",
};

fn pickByte(rng: *Random) u8 {
    // Bias toward ascii-printable.
    if (rng.intRangeLessThan(u8, 0, 10) < 8) {
        return rng.intRangeLessThan(u8, 32, 127);
    }
    return rng.int(u8);
}

pub fn mutate(allocator: std.mem.Allocator, src: []const u8, rng: *Random) ![]u8 {
    if (src.len == 0) {
        // Seed empty inputs with at least one byte so other mutations have something to work on.
        var single = try allocator.alloc(u8, 1);
        single[0] = pickByte(rng);
        return single;
    }

    const m: Mutation = @enumFromInt(rng.intRangeLessThan(u8, 0, @typeInfo(Mutation).@"enum".fields.len));
    switch (m) {
        .byte_flip => {
            const out = try allocator.dupe(u8, src);
            const flips = rng.intRangeLessThan(u8, 1, 4);
            var i: u8 = 0;
            while (i < flips) : (i += 1) {
                const idx = rng.intRangeLessThan(usize, 0, out.len);
                out[idx] = pickByte(rng);
            }
            return out;
        },
        .splice => {
            // Cut a span and paste it elsewhere.
            if (src.len < 4) return allocator.dupe(u8, src);
            const a = rng.intRangeLessThan(usize, 0, src.len - 1);
            const max_len = @min(src.len - a, 64);
            const span = rng.intRangeLessThan(usize, 1, max_len + 1);
            const cut = src[a .. a + span];
            const insert_at = rng.intRangeLessThan(usize, 0, src.len);
            var out: std.ArrayList(u8) = .{};
            errdefer out.deinit(allocator);
            try out.appendSlice(allocator, src[0..insert_at]);
            try out.appendSlice(allocator, cut);
            try out.appendSlice(allocator, src[insert_at..]);
            return out.toOwnedSlice(allocator);
        },
        .delete_chunk => {
            if (src.len < 2) return allocator.dupe(u8, src);
            const a = rng.intRangeLessThan(usize, 0, src.len - 1);
            const max_len = @min(src.len - a, 64);
            const span = rng.intRangeLessThan(usize, 1, max_len + 1);
            var out: std.ArrayList(u8) = .{};
            errdefer out.deinit(allocator);
            try out.appendSlice(allocator, src[0..a]);
            try out.appendSlice(allocator, src[a + span ..]);
            return out.toOwnedSlice(allocator);
        },
        .duplicate_chunk => {
            if (src.len < 2) return allocator.dupe(u8, src);
            const a = rng.intRangeLessThan(usize, 0, src.len - 1);
            const max_len = @min(src.len - a, 64);
            const span = rng.intRangeLessThan(usize, 1, max_len + 1);
            const cut = src[a .. a + span];
            var out: std.ArrayList(u8) = .{};
            errdefer out.deinit(allocator);
            try out.appendSlice(allocator, src);
            try out.appendSlice(allocator, cut);
            return out.toOwnedSlice(allocator);
        },
        .insert_keyword => {
            const kw = inserts[rng.intRangeLessThan(usize, 0, inserts.len)];
            const insert_at = rng.intRangeLessThan(usize, 0, src.len + 1);
            var out: std.ArrayList(u8) = .{};
            errdefer out.deinit(allocator);
            try out.appendSlice(allocator, src[0..insert_at]);
            try out.appendSlice(allocator, kw);
            try out.appendSlice(allocator, src[insert_at..]);
            return out.toOwnedSlice(allocator);
        },
    }
}

pub fn randomBytes(allocator: std.mem.Allocator, rng: *Random) ![]u8 {
    const struct_chars = "{}();.,= \n";
    const len = rng.intRangeLessThan(usize, 1, 256);
    const out = try allocator.alloc(u8, len);
    for (out) |*b| {
        const r = rng.intRangeLessThan(u8, 0, 10);
        if (r < 3) {
            b.* = struct_chars[rng.intRangeLessThan(usize, 0, struct_chars.len)];
        } else if (r < 9) {
            b.* = rng.intRangeLessThan(u8, 32, 127);
        } else {
            b.* = rng.int(u8);
        }
    }
    return out;
}
