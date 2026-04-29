//! Public entry-point for the zig++ compiler frontend.
//!
//! Pipeline:
//!   bytes -> token.Lexer -> []Token -> parser.Parser -> ast.File
//!         -> sema.Sema (in-place diagnostics)  -> lower_to_zig.Lowerer -> []u8
//!
//! All errors flow through `diagnostics.Diagnostics` so callers can render or
//! consume them programmatically.

const std = @import("std");

pub const diagnostics = @import("diagnostics.zig");
pub const token = @import("token.zig");
pub const ast = @import("ast.zig");
pub const parser = @import("parser.zig");
pub const sema = @import("sema.zig");
pub const lower_to_zig = @import("lower_to_zig.zig");

pub const Diagnostics = diagnostics.Diagnostics;
pub const Diagnostic = diagnostics.Diagnostic;
pub const Severity = diagnostics.Severity;
pub const Span = diagnostics.Span;
pub const Code = diagnostics.Code;

pub const Lexer = token.Lexer;
pub const Token = token.Token;
pub const TokenKind = token.TokenKind;

pub const Parser = parser.Parser;
pub const parseSource = parser.parseSource;

pub const Sema = sema.Sema;
pub const SemaResult = sema.SemaResult;

pub const Lowerer = lower_to_zig.Lowerer;
pub const lower = lower_to_zig.lower;
pub const lowerWithEffects = lower_to_zig.lowerWithEffects;
pub const InferredEffects = sema.InferredEffects;
pub const InferredEffectsMap = lower_to_zig.InferredEffectsMap;

pub const locate = diagnostics.locate;

/// Tool-facing one-shot: source bytes -> lowered Zig string.
/// Discards diagnostics; intended for paths where the caller only wants the
/// lowered output (e.g. `zpp lower`, `zpp run`). Use `parseAndAnalyze` for
/// surfaces that need to inspect diagnostics.
pub fn compileToString(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var diags = Diagnostics.init(allocator);
    defer diags.deinit();
    return compileToZig(allocator, source, &diags);
}

pub const AnalysisResult = struct {
    diags: Diagnostics,

    pub fn deinit(self: *AnalysisResult) void {
        self.diags.deinit();
    }
};

/// Tool-facing parse+sema: returns an owned `Diagnostics` collector populated
/// with any messages produced during parsing and semantic analysis. Lowering
/// is not performed. Caller deinits the returned struct.
pub fn parseAndAnalyze(allocator: std.mem.Allocator, source: []const u8) !AnalysisResult {
    var diags = Diagnostics.init(allocator);
    errdefer diags.deinit();

    var arena = ast.Arena.init(allocator);
    defer arena.deinit();

    const file = try parser.parseSource(allocator, source, &arena, &diags);
    var s = sema.Sema.init(allocator, &diags);
    var res = try s.analyze(&file);
    res.deinit();

    return .{ .diags = diags };
}

/// One-shot compile: source bytes -> lowered Zig string.
///
/// On any sema/parse error we still return the best-effort lowered output so
/// callers (LSPs, build steps) can report diagnostics without aborting.
/// The returned slice is owned by the caller.
pub fn compileToZig(
    allocator: std.mem.Allocator,
    source: []const u8,
    diags: *Diagnostics,
) ![]u8 {
    var arena = ast.Arena.init(allocator);
    defer arena.deinit();

    const file = try parser.parseSource(allocator, source, &arena, diags);
    var s = sema.Sema.init(allocator, diags);
    var res = try s.analyze(&file);
    defer res.deinit();
    // Pass the per-fn inferred-effect table into the lowerer so
    // `@effectsOf(<ident>)` substitutions can resolve. Z0050 is emitted
    // for unknown names on the lowering side via this table.
    return lower_to_zig.lowerWithEffects(allocator, &file, diags, &res.inferred_effects);
}

test "end-to-end compile sample" {
    const a = std.testing.allocator;
    var diags = Diagnostics.init(a);
    defer diags.deinit();

    const src =
        \\trait Writer { fn write(self, bytes: []const u8) !usize; }
        \\owned struct FW {
        \\    n: usize,
        \\    pub fn deinit(self: *FW) void { _ = self; }
        \\    pub fn write(self: *FW, bytes: []const u8) !usize {
        \\        _ = self; return bytes.len;
        \\    }
        \\}
        \\fn emit(w: impl Writer, msg: []const u8) !void {
        \\    _ = try w.write(msg);
        \\}
        \\pub fn main() !void {
        \\    using w = FW{ .n = 0 };
        \\    try emit(&w, "hi");
        \\}
    ;
    const out = try compileToZig(a, src, &diags);
    defer a.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "Writer_VTable") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "const FW = struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "defer w.deinit();") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "w: anytype") != null);
}

test "modules accessible" {
    _ = diagnostics;
    _ = token;
    _ = ast;
    _ = parser;
    _ = sema;
    _ = lower_to_zig;
}
