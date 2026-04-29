const std = @import("std");
const ast = @import("ast.zig");
const tok = @import("token.zig");
const diag = @import("diagnostics.zig");

const TokenKind = tok.TokenKind;
const Token = tok.Token;

/// Top-level recursive-descent parser. The parser is intentionally
/// permissive: anything it doesn't recognize is captured into a RawZig
/// chunk and emitted verbatim by the lowering pass.
pub const Parser = struct {
    source: []const u8,
    tokens: []const Token,
    pos: usize = 0,
    arena: *ast.Arena,
    diags: *diag.Diagnostics,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        source: []const u8,
        tokens: []const Token,
        arena: *ast.Arena,
        diags: *diag.Diagnostics,
    ) Parser {
        return .{
            .source = source,
            .tokens = tokens,
            .arena = arena,
            .diags = diags,
            .allocator = allocator,
        };
    }

    fn peek(self: *Parser) Token {
        return self.tokens[self.pos];
    }

    fn peekAt(self: *Parser, off: usize) Token {
        const p = self.pos + off;
        if (p >= self.tokens.len) return self.tokens[self.tokens.len - 1];
        return self.tokens[p];
    }

    fn isAtEnd(self: *Parser) bool {
        return self.peek().kind == .eof;
    }

    fn advance(self: *Parser) Token {
        const t = self.peek();
        if (!self.isAtEnd()) self.pos += 1;
        return t;
    }

    fn check(self: *Parser, k: TokenKind) bool {
        return self.peek().kind == k;
    }

    fn match(self: *Parser, k: TokenKind) bool {
        if (self.check(k)) {
            _ = self.advance();
            return true;
        }
        return false;
    }

    fn expect(self: *Parser, k: TokenKind, ctx: []const u8) !Token {
        if (self.check(k)) return self.advance();
        const got = self.peek();
        try self.diags.emit(
            .err,
            .z0102_expected_token,
            got.span,
            "expected {s} ({s}), got '{s}'",
            .{ @tagName(k), ctx, got.slice(self.source) },
        );
        return error.ParseError;
    }

    fn slice(self: *Parser, span: diag.Span) []const u8 {
        return self.source[span.start..span.end];
    }

    /// Skip until the next top-level synchronization point.
    fn synchronizeTopLevel(self: *Parser) void {
        while (!self.isAtEnd()) {
            const k = self.peek().kind;
            switch (k) {
                .kw_pub, .kw_fn, .kw_const, .kw_var, .kw_trait, .kw_impl,
                .kw_owned, .kw_extern, .kw_test, .kw_comptime => return,
                else => _ = self.advance(),
            }
        }
    }

    pub fn parseFile(self: *Parser) !ast.File {
        var decls: std.ArrayList(ast.TopDecl) = .{};
        defer decls.deinit(self.allocator);

        while (!self.isAtEnd()) {
            const start_pos = self.pos;
            const decl = self.parseTopDecl() catch |e| switch (e) {
                error.ParseError => {
                    if (self.pos == start_pos) _ = self.advance();
                    self.synchronizeTopLevel();
                    continue;
                },
                else => return e,
            };
            try decls.append(self.allocator, decl);
        }
        const owned = try self.arena.dupe(ast.TopDecl, decls.items);
        return .{ .decls = owned, .source = self.source };
    }

    fn parseTopDecl(self: *Parser) !ast.TopDecl {
        const start_tok = self.peek();
        const is_pub = self.match(.kw_pub);

        switch (self.peek().kind) {
            .kw_trait => return .{ .trait = try self.parseTrait(is_pub, start_tok.span.start) },
            .kw_impl => return .{ .impl_block = try self.parseImpl(start_tok.span.start) },
            .kw_owned => return .{ .owned_struct = try self.parseOwnedStruct(is_pub, start_tok.span.start) },
            .kw_struct => {
                if (self.peekAt(1).kind == .ident and self.peekAt(2).kind == .l_brace) {
                    return .{ .struct_decl = try self.parseStructDecl(is_pub, start_tok.span.start) };
                }
                if (is_pub) return self.parseRawTopDeclFrom(start_tok.span.start);
                return self.parseRawTopDecl(start_tok.span.start);
            },
            .kw_const => {
                // `(pub)? const Name = struct { ... };` — capture so impl methods
                // for `Name` can be injected into the body during lowering.
                if (self.peekAt(1).kind == .ident and
                    self.peekAt(2).kind == .eq and
                    self.peekAt(3).kind == .kw_struct and
                    self.peekAt(4).kind == .l_brace)
                {
                    return .{ .struct_decl = try self.parseConstStructDecl(is_pub, start_tok.span.start) };
                }
                if (is_pub) return self.parseRawTopDeclFrom(start_tok.span.start);
                return self.parseRawTopDecl(start_tok.span.start);
            },
            .kw_extern => {
                if (self.peekAt(1).kind == .kw_interface) {
                    return .{ .extern_interface = try self.parseExternInterface(is_pub, start_tok.span.start) };
                }
                return self.parseRawTopDecl(start_tok.span.start);
            },
            .kw_fn => {
                const fd = try self.parseFnDecl(is_pub, null, null, null, null, start_tok.span.start);
                return .{ .fn_decl = fd };
            },
            .kw_effects, .kw_requires, .kw_ensures => {
                // Function with leading attributes.
                const fd = try self.parseAttributedFn(is_pub, start_tok.span.start);
                return .{ .fn_decl = fd };
            },
            else => {
                if (is_pub) {
                    // `pub` followed by something we don't transform — fold pub into raw.
                    return self.parseRawTopDeclFrom(start_tok.span.start);
                }
                return self.parseRawTopDecl(start_tok.span.start);
            },
        }
    }

    fn parseRawTopDecl(self: *Parser, start: u32) !ast.TopDecl {
        return self.parseRawTopDeclFrom(start);
    }

    /// Capture from `start` until the next top-level decl boundary as raw text.
    fn parseRawTopDeclFrom(self: *Parser, start: u32) !ast.TopDecl {
        // Walk to the end of this statement / block. For statement-like decls,
        // stop at semicolon at depth 0; for block-like, balance braces.
        var depth: i32 = 0;
        var saw_brace = false;
        var end: u32 = start;
        var consumed_any = false;
        while (!self.isAtEnd()) {
            const t = self.peek();
            const k = t.kind;
            if (k == .l_brace or k == .dot_brace) {
                depth += 1;
                saw_brace = true;
                end = t.span.end;
                _ = self.advance();
                consumed_any = true;
                continue;
            }
            if (k == .r_brace) {
                depth -= 1;
                end = t.span.end;
                _ = self.advance();
                consumed_any = true;
                if (depth <= 0 and saw_brace) break;
                continue;
            }
            if (depth == 0 and k == .semicolon) {
                end = t.span.end;
                _ = self.advance();
                break;
            }
            // Only break on a sibling top-decl start if we've already
            // consumed something for the current decl. Otherwise the dispatch
            // in `parseTopDecl` would have consumed `pub` (or similar) and
            // left us looking AT the next decl-start keyword (`const`, `fn`,
            // etc.) — that keyword belongs to the *current* decl we are
            // about to capture, not to a sibling.
            if (consumed_any and depth == 0 and isTopDeclStart(k)) break;
            end = t.span.end;
            _ = self.advance();
            consumed_any = true;
        }
        return .{ .raw = .{
            .text = self.source[start..end],
            .span = .{ .start = start, .end = end },
        } };
    }

    fn isTopDeclStart(k: TokenKind) bool {
        return switch (k) {
            .kw_pub, .kw_fn, .kw_const, .kw_var, .kw_trait, .kw_impl,
            .kw_owned, .kw_test, .kw_comptime, .kw_extern => true,
            else => false,
        };
    }

    fn parseTrait(self: *Parser, is_pub: bool, start: u32) !ast.TraitDecl {
        _ = try self.expect(.kw_trait, "trait decl");
        const name_tok = try self.expect(.ident, "trait name");
        _ = try self.expect(.l_brace, "trait body");

        var methods: std.ArrayList(ast.TraitMethod) = .{};
        defer methods.deinit(self.allocator);
        while (!self.check(.r_brace) and !self.isAtEnd()) {
            const m = try self.parseTraitMethod();
            try methods.append(self.allocator, m);
        }
        const close = try self.expect(.r_brace, "trait body close");
        const owned = try self.arena.dupe(ast.TraitMethod, methods.items);
        return .{
            .name = name_tok.slice(self.source),
            .methods = owned,
            .is_pub = is_pub,
            .span = .{ .start = start, .end = close.span.end },
        };
    }

    fn parseTraitMethod(self: *Parser) !ast.TraitMethod {
        const start = self.peek().span.start;
        _ = try self.expect(.kw_fn, "trait method");
        const name = try self.expect(.ident, "method name");
        _ = try self.expect(.l_paren, "param list");
        const params = try self.parseParamList();
        const ret_text = try self.parseReturnType();
        const semi = try self.expect(.semicolon, "trait method end");
        return .{
            .name = name.slice(self.source),
            .params = params,
            .return_type = ret_text,
            .span = .{ .start = start, .end = semi.span.end },
        };
    }

    /// Parse `( ... )` already past the `(` token — consumes through `)`.
    fn parseParamList(self: *Parser) ![]ast.Param {
        var params: std.ArrayList(ast.Param) = .{};
        defer params.deinit(self.allocator);

        if (self.match(.r_paren)) {
            return self.arena.dupe(ast.Param, params.items);
        }

        while (true) {
            const p = try self.parseOneParam();
            try params.append(self.allocator, p);
            if (self.match(.comma)) continue;
            break;
        }
        _ = try self.expect(.r_paren, "param list close");
        return self.arena.dupe(ast.Param, params.items);
    }

    fn parseOneParam(self: *Parser) !ast.Param {
        const start = self.peek().span.start;
        var is_comptime = false;
        if (self.match(.kw_comptime)) is_comptime = true;

        // Special case: bare `self` (no colon) as in trait methods.
        var name_text: []const u8 = "";
        if (self.check(.ident) and std.mem.eql(u8, self.peek().slice(self.source), "self")) {
            const t = self.advance();
            if (!self.check(.colon)) {
                return .{
                    .name = "self",
                    .type_text = "",
                    .mode = .plain,
                    .span = .{ .start = start, .end = t.span.end },
                };
            }
            name_text = "self";
        } else {
            const name_tok = try self.expect(.ident, "param name");
            name_text = name_tok.slice(self.source);
        }
        _ = try self.expect(.colon, "param type");

        // impl Trait / dyn Trait?
        if (self.check(.kw_impl)) {
            _ = self.advance();
            const trait_tok = try self.expect(.ident, "impl trait name");
            return .{
                .name = name_text,
                .type_text = trait_tok.slice(self.source),
                .mode = .impl_trait,
                .span = .{ .start = start, .end = trait_tok.span.end },
            };
        }
        if (self.check(.kw_dyn)) {
            _ = self.advance();
            const trait_tok = try self.expect(.ident, "dyn trait name");
            return .{
                .name = name_text,
                .type_text = trait_tok.slice(self.source),
                .mode = .dyn_trait,
                .span = .{ .start = start, .end = trait_tok.span.end },
            };
        }
        // ?dyn Trait — optional fat pointer.
        if (self.check(.question)) {
            // Look ahead: ? dyn Ident
            if (self.peekAt(1).kind == .kw_dyn and self.peekAt(2).kind == .ident) {
                _ = self.advance(); // ?
                _ = self.advance(); // dyn
                const trait_tok = self.advance(); // Ident
                return .{
                    .name = name_text,
                    .type_text = trait_tok.slice(self.source),
                    .mode = .nullable_dyn_trait,
                    .span = .{ .start = start, .end = trait_tok.span.end },
                };
            }
        }
        if (self.check(.kw_anytype)) {
            const t = self.advance();
            return .{
                .name = name_text,
                .type_text = "",
                .mode = .any_type,
                .span = .{ .start = start, .end = t.span.end },
            };
        }

        const type_text = try self.captureTypeUntil(&[_]TokenKind{ .comma, .r_paren });
        return .{
            .name = name_text,
            .type_text = type_text.text,
            .mode = if (is_comptime) .comptime_plain else .plain,
            .span = .{ .start = start, .end = type_text.end },
        };
    }

    const CapturedText = struct { text: []const u8, end: u32 };

    /// Capture a contiguous slice of source until we hit one of `terminators`
    /// at depth zero. Brace/paren/bracket depth is tracked.
    fn captureTypeUntil(self: *Parser, terminators: []const TokenKind) !CapturedText {
        const start = self.peek().span.start;
        var end: u32 = start;
        var depth: i32 = 0;
        while (!self.isAtEnd()) {
            const t = self.peek();
            const k = t.kind;
            if (depth == 0) {
                for (terminators) |term| {
                    if (k == term) return .{ .text = self.source[start..end], .end = end };
                }
            }
            switch (k) {
                .l_paren, .l_brace, .l_bracket, .dot_brace => depth += 1,
                .r_paren, .r_brace, .r_bracket => {
                    if (depth == 0) {
                        return .{ .text = self.source[start..end], .end = end };
                    }
                    depth -= 1;
                },
                else => {},
            }
            end = t.span.end;
            _ = self.advance();
        }
        return .{ .text = self.source[start..end], .end = end };
    }

    fn parseReturnType(self: *Parser) ![]const u8 {
        return (try self.captureTypeUntil(&[_]TokenKind{
            .l_brace, .semicolon,
            .kw_effects, .kw_requires, .kw_ensures, .kw_where,
        })).text;
    }

    fn parseImpl(self: *Parser, start: u32) !ast.ImplBlock {
        _ = try self.expect(.kw_impl, "impl block");
        const trait_tok = try self.expect(.ident, "trait in impl");
        _ = try self.expect(.kw_for, "impl X for Y");
        const target_tok = try self.expect(.ident, "impl target type");
        _ = try self.expect(.l_brace, "impl body");

        var fns: std.ArrayList(ast.FnDecl) = .{};
        defer fns.deinit(self.allocator);
        while (!self.check(.r_brace) and !self.isAtEnd()) {
            const is_pub = self.match(.kw_pub);
            const fd = try self.parseFnDecl(is_pub, null, null, null, null, self.peek().span.start);
            try fns.append(self.allocator, fd);
        }
        const close = try self.expect(.r_brace, "impl body close");
        const owned = try self.arena.dupe(ast.FnDecl, fns.items);
        return .{
            .trait_name = trait_tok.slice(self.source),
            .target_type = target_tok.slice(self.source),
            .fns = owned,
            .span = .{ .start = start, .end = close.span.end },
        };
    }

    fn parseOwnedStruct(self: *Parser, is_pub: bool, start: u32) !ast.OwnedStructDecl {
        _ = try self.expect(.kw_owned, "owned struct");
        _ = try self.expect(.kw_struct, "owned struct");
        const name_tok = try self.expect(.ident, "owned struct name");
        _ = try self.expect(.l_brace, "owned struct body");

        // Fields = everything up to the first `pub fn` / `fn` / `}` at depth 0.
        const fields_start = self.peek().span.start;
        var fields_end = fields_start;
        var depth: i32 = 0;
        while (!self.isAtEnd()) {
            const t = self.peek();
            if (depth == 0) {
                if (t.kind == .r_brace) break;
                if (t.kind == .kw_fn) break;
                if (t.kind == .kw_pub and self.peekAt(1).kind == .kw_fn) break;
            }
            switch (t.kind) {
                .l_paren, .l_brace, .l_bracket, .dot_brace => depth += 1,
                .r_paren, .r_brace, .r_bracket => depth -= 1,
                else => {},
            }
            fields_end = t.span.end;
            _ = self.advance();
        }

        var fns: std.ArrayList(ast.FnDecl) = .{};
        defer fns.deinit(self.allocator);
        while (!self.check(.r_brace) and !self.isAtEnd()) {
            const fn_pub = self.match(.kw_pub);
            const fd = try self.parseFnDecl(fn_pub, null, null, null, null, self.peek().span.start);
            try fns.append(self.allocator, fd);
        }
        const close = try self.expect(.r_brace, "owned struct close");
        const owned = try self.arena.dupe(ast.FnDecl, fns.items);
        const derive_attr = try self.parseTrailingDerive();
        return .{
            .name = name_tok.slice(self.source),
            .is_pub = is_pub,
            .fields_text = self.source[fields_start..fields_end],
            .fns = owned,
            .derive = derive_attr,
            .invariant = null,
            .span = .{ .start = start, .end = close.span.end },
        };
    }

    /// `(pub)? const Name = struct { <body> };` — keep the body verbatim so
    /// the lowerer can inject impl methods before the closing brace.
    fn parseConstStructDecl(self: *Parser, is_pub: bool, start: u32) !ast.StructDecl {
        _ = try self.expect(.kw_const, "const struct decl");
        const name_tok = try self.expect(.ident, "const struct name");
        _ = try self.expect(.eq, "const struct =");
        _ = try self.expect(.kw_struct, "const struct keyword");
        _ = try self.expect(.l_brace, "const struct body");

        const body_start = self.peek().span.start;
        var body_end = body_start;
        var depth: i32 = 1;
        while (!self.isAtEnd()) {
            const t = self.peek();
            switch (t.kind) {
                .l_paren, .l_brace, .l_bracket, .dot_brace => depth += 1,
                .r_paren, .r_brace, .r_bracket => depth -= 1,
                else => {},
            }
            if (depth == 0) break;
            body_end = t.span.end;
            _ = self.advance();
        }
        const close = try self.expect(.r_brace, "const struct close }");
        // Check for `derive(...)` BEFORE the optional trailing semicolon so
        // both `} derive(...);` and `}; derive(...);` are accepted.
        const derive_attr = try self.parseTrailingDerive();
        _ = self.match(.semicolon);
        return .{
            .name = name_tok.slice(self.source),
            .is_pub = is_pub,
            .fields_text = self.source[body_start..body_end],
            .fns = &.{},
            .derive = derive_attr,
            .span = .{ .start = start, .end = close.span.end },
        };
    }

    fn parseStructDecl(self: *Parser, is_pub: bool, start: u32) !ast.StructDecl {
        _ = try self.expect(.kw_struct, "struct");
        const name_tok = try self.expect(.ident, "struct name");
        _ = try self.expect(.l_brace, "struct body");

        const fields_start = self.peek().span.start;
        var fields_end = fields_start;
        var depth: i32 = 0;
        while (!self.isAtEnd()) {
            const t = self.peek();
            if (depth == 0) {
                if (t.kind == .r_brace) break;
                if (t.kind == .kw_fn) break;
                if (t.kind == .kw_pub and self.peekAt(1).kind == .kw_fn) break;
            }
            switch (t.kind) {
                .l_paren, .l_brace, .l_bracket, .dot_brace => depth += 1,
                .r_paren, .r_brace, .r_bracket => depth -= 1,
                else => {},
            }
            fields_end = t.span.end;
            _ = self.advance();
        }

        var fns: std.ArrayList(ast.FnDecl) = .{};
        defer fns.deinit(self.allocator);
        while (!self.check(.r_brace) and !self.isAtEnd()) {
            const fn_pub = self.match(.kw_pub);
            const fd = try self.parseFnDecl(fn_pub, null, null, null, null, self.peek().span.start);
            try fns.append(self.allocator, fd);
        }
        const close = try self.expect(.r_brace, "struct close");
        const owned_fns = try self.arena.dupe(ast.FnDecl, fns.items);
        const derive_attr = try self.parseTrailingDerive();
        return .{
            .name = name_tok.slice(self.source),
            .is_pub = is_pub,
            .fields_text = self.source[fields_start..fields_end],
            .fns = owned_fns,
            .derive = derive_attr,
            .span = .{ .start = start, .end = close.span.end },
        };
    }

    /// Optional `derive(.{ A, B, C });` after a struct's closing brace.
    fn parseTrailingDerive(self: *Parser) !?ast.DeriveAttr {
        if (!self.check(.kw_derive)) return null;
        const start = self.peek().span.start;
        _ = self.advance();
        _ = try self.expect(.l_paren, "derive(");
        if (self.match(.dot_brace)) {
            // .{ tokenized as a single token
        } else {
            _ = try self.expect(.dot, "derive(.");
            _ = try self.expect(.l_brace, "derive(.{");
        }
        var names: std.ArrayList([]const u8) = .{};
        defer names.deinit(self.allocator);
        while (!self.check(.r_brace) and !self.isAtEnd()) {
            const id = try self.expect(.ident, "derive name");
            try names.append(self.allocator, id.slice(self.source));
            if (!self.match(.comma)) break;
        }
        _ = try self.expect(.r_brace, "derive close }");
        const close = try self.expect(.r_paren, "derive close )");
        _ = self.match(.semicolon);
        const owned = try self.arena.dupe([]const u8, names.items);
        return .{ .names = owned, .span = .{ .start = start, .end = close.span.end } };
    }

    fn parseExternInterface(self: *Parser, is_pub: bool, start: u32) !ast.ExternInterfaceDecl {
        _ = try self.expect(.kw_extern, "extern interface");
        _ = try self.expect(.kw_interface, "extern interface");
        const name_tok = try self.expect(.ident, "extern interface name");
        _ = try self.expect(.l_brace, "extern interface body");
        var methods: std.ArrayList(ast.TraitMethod) = .{};
        defer methods.deinit(self.allocator);
        while (!self.check(.r_brace) and !self.isAtEnd()) {
            const m = try self.parseTraitMethod();
            try methods.append(self.allocator, m);
        }
        const close = try self.expect(.r_brace, "extern interface close");
        const owned = try self.arena.dupe(ast.TraitMethod, methods.items);
        return .{
            .name = name_tok.slice(self.source),
            .methods = owned,
            .is_pub = is_pub,
            .span = .{ .start = start, .end = close.span.end },
        };
    }

    fn parseAttributedFn(self: *Parser, is_pub: bool, start: u32) !ast.FnDecl {
        var effects: ?ast.EffectsAttr = null;
        var requires: ?ast.RequiresAttr = null;
        var ensures: ?ast.EnsuresAttr = null;

        while (true) {
            switch (self.peek().kind) {
                .kw_effects => effects = try self.parseEffectsAttr(),
                .kw_requires => requires = try self.parseRequiresAttr(),
                .kw_ensures => ensures = try self.parseEnsuresAttr(),
                else => break,
            }
        }
        return self.parseFnDecl(is_pub, null, effects, requires, ensures, start);
    }

    fn parseEffectsAttr(self: *Parser) !ast.EffectsAttr {
        const start = self.peek().span.start;
        _ = try self.expect(.kw_effects, "effects attr");
        _ = try self.expect(.l_paren, "effects(");
        var list: std.ArrayList(ast.Effect) = .{};
        defer list.deinit(self.allocator);
        while (!self.check(.r_paren) and !self.isAtEnd()) {
            _ = try self.expect(.dot, ".name");
            const id = try self.expect(.ident, "effect name");
            const text = id.slice(self.source);
            const kind: ast.EffectKind = if (std.mem.eql(u8, text, "alloc"))
                .alloc
            else if (std.mem.eql(u8, text, "noalloc"))
                .noalloc
            else if (std.mem.eql(u8, text, "io"))
                .io
            else if (std.mem.eql(u8, text, "noio"))
                .noio
            else if (std.mem.eql(u8, text, "panic"))
                .panic
            else if (std.mem.eql(u8, text, "nopanic"))
                .nopanic
            else if (std.mem.eql(u8, text, "custom"))
                .custom
            else if (std.mem.eql(u8, text, "nocustom"))
                .nocustom
            else
                .custom;
            // `.custom("name")` / `.nocustom("name")`: consume the
            // parenthesised string-literal payload and store the inner
            // name (without quotes) on the effect.
            var name: []const u8 = "";
            if ((kind == .custom or kind == .nocustom) and self.check(.l_paren)) {
                _ = try self.expect(.l_paren, "custom effect (");
                const lit = try self.expect(.string_literal, "custom effect name string");
                const raw = lit.slice(self.source);
                // Strip a single pair of surrounding `"` quotes if present.
                name = if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"')
                    raw[1 .. raw.len - 1]
                else
                    raw;
                _ = try self.expect(.r_paren, "custom effect )");
            }
            try list.append(self.allocator, .{ .kind = kind, .text = text, .name = name });
            if (!self.match(.comma)) break;
        }
        const close = try self.expect(.r_paren, "effects close");
        const owned = try self.arena.dupe(ast.Effect, list.items);
        return .{ .effects = owned, .span = .{ .start = start, .end = close.span.end } };
    }

    fn parseRequiresAttr(self: *Parser) !ast.RequiresAttr {
        const start = self.peek().span.start;
        _ = try self.expect(.kw_requires, "requires");
        _ = try self.expect(.l_paren, "requires(");
        const cap = try self.captureTypeUntil(&[_]TokenKind{.r_paren});
        const close = try self.expect(.r_paren, "requires close");
        return .{ .expr_text = cap.text, .span = .{ .start = start, .end = close.span.end } };
    }

    fn parseEnsuresAttr(self: *Parser) !ast.EnsuresAttr {
        const start = self.peek().span.start;
        _ = try self.expect(.kw_ensures, "ensures");
        _ = try self.expect(.l_paren, "ensures(");
        const cap = try self.captureTypeUntil(&[_]TokenKind{.r_paren});
        const close = try self.expect(.r_paren, "ensures close");
        return .{ .expr_text = cap.text, .span = .{ .start = start, .end = close.span.end } };
    }

    fn parseFnDecl(
        self: *Parser,
        is_pub: bool,
        where_clause: ?ast.WhereClause,
        effects: ?ast.EffectsAttr,
        requires: ?ast.RequiresAttr,
        ensures: ?ast.EnsuresAttr,
        start: u32,
    ) !ast.FnDecl {
        _ = try self.expect(.kw_fn, "fn");
        const name = try self.expect(.ident, "fn name");
        _ = try self.expect(.l_paren, "fn params");
        const params = try self.parseParamList();
        const ret = try self.parseReturnType();

        var where = where_clause;
        if (self.check(.kw_where)) {
            where = try self.parseWhereClause();
        }

        var post_effects = effects;
        var post_requires = requires;
        var post_ensures = ensures;
        while (true) {
            switch (self.peek().kind) {
                .kw_effects => {
                    if (post_effects != null) break;
                    post_effects = try self.parseEffectsAttr();
                },
                .kw_requires => {
                    if (post_requires != null) break;
                    post_requires = try self.parseRequiresAttr();
                },
                .kw_ensures => {
                    if (post_ensures != null) break;
                    post_ensures = try self.parseEnsuresAttr();
                },
                .kw_where => {
                    if (where != null) break;
                    where = try self.parseWhereClause();
                },
                else => break,
            }
        }

        const sig_end: u32 = self.peek().span.start;

        const sig: ast.FnSig = .{
            .name = name.slice(self.source),
            .params = params,
            .return_type = ret,
            .is_pub = is_pub,
            .is_extern = false,
            .where = where,
            .effects = post_effects,
            .requires = post_requires,
            .ensures = post_ensures,
            .span = .{ .start = start, .end = sig_end },
        };

        var body: ?ast.FnBody = null;
        if (self.check(.l_brace)) {
            body = try self.parseFnBody();
        } else {
            _ = try self.expect(.semicolon, "fn forward decl");
        }
        return .{ .sig = sig, .body = body };
    }

    fn parseWhereClause(self: *Parser) !ast.WhereClause {
        const start = self.peek().span.start;
        _ = try self.expect(.kw_where, "where");
        var bounds: std.ArrayList(ast.WhereBound) = .{};
        defer bounds.deinit(self.allocator);
        while (true) {
            const tp = try self.expect(.ident, "type param");
            _ = try self.expect(.colon, "where bound");
            const cap = try self.captureTypeUntil(&[_]TokenKind{ .comma, .l_brace, .semicolon });
            try bounds.append(self.allocator, .{
                .type_param = tp.slice(self.source),
                .trait_text = std.mem.trim(u8, cap.text, " \t\r\n"),
            });
            if (!self.match(.comma)) break;
        }
        const owned = try self.arena.dupe(ast.WhereBound, bounds.items);
        return .{ .bounds = owned, .span = .{ .start = start, .end = self.peek().span.start } };
    }

    fn parseFnBody(self: *Parser) !ast.FnBody {
        const open = try self.expect(.l_brace, "fn body");
        var stmts: std.ArrayList(ast.Stmt) = .{};
        defer stmts.deinit(self.allocator);

        while (!self.check(.r_brace) and !self.isAtEnd()) {
            const stmt_start = self.peek().span.start;
            const before = self.pos;

            if (self.check(.kw_using)) {
                const s = try self.parseUsing();
                try stmts.append(self.allocator, .{ .using_stmt = s });
                continue;
            }
            if (self.check(.kw_own)) {
                const s = try self.parseOwn();
                try stmts.append(self.allocator, .{ .own_decl = s });
                continue;
            }
            if (self.check(.kw_move)) {
                const s = try self.parseMoveStmt();
                try stmts.append(self.allocator, .{ .move_expr_stmt = s });
                continue;
            }

            const raw = try self.captureStmtRaw(stmt_start);
            if (self.pos == before) {
                _ = self.advance();
                continue;
            }
            try stmts.append(self.allocator, .{ .raw = raw });
        }
        const close = try self.expect(.r_brace, "fn body close");
        const owned = try self.arena.dupe(ast.Stmt, stmts.items);
        return .{
            .stmts = owned,
            .span = .{ .start = open.span.start, .end = close.span.end },
        };
    }

    fn captureStmtRaw(self: *Parser, start: u32) !ast.RawZig {
        var depth: i32 = 0;
        var end: u32 = start;
        while (!self.isAtEnd()) {
            const t = self.peek();
            const k = t.kind;
            if (depth == 0 and k == .r_brace) break;
            switch (k) {
                .l_paren, .l_brace, .l_bracket, .dot_brace => depth += 1,
                .r_paren, .r_brace, .r_bracket => depth -= 1,
                else => {},
            }
            end = t.span.end;
            _ = self.advance();
            if (depth == 0 and k == .semicolon) break;
            if (depth < 0) break;
        }
        return .{
            .text = self.source[start..end],
            .span = .{ .start = start, .end = end },
        };
    }

    fn parseUsing(self: *Parser) !ast.UsingStmt {
        const start = self.peek().span.start;
        _ = try self.expect(.kw_using, "using");
        const name = try self.expect(.ident, "using name");
        _ = try self.expect(.eq, "using = ...");
        const init_text = try self.captureTypeUntil(&[_]TokenKind{.semicolon});
        const semi = try self.expect(.semicolon, "using stmt end");
        return .{
            .name = name.slice(self.source),
            .init_text = std.mem.trim(u8, init_text.text, " \t\r\n"),
            .span = .{ .start = start, .end = semi.span.end },
        };
    }

    fn parseOwn(self: *Parser) !ast.OwnDecl {
        const start = self.peek().span.start;
        _ = try self.expect(.kw_own, "own");
        const is_const = self.match(.kw_const);
        const is_var = if (!is_const) self.match(.kw_var) else false;
        if (!is_const and !is_var) {
            try self.diags.emit(
                .err,
                .z0102_expected_token,
                self.peek().span,
                "expected 'var' or 'const' after 'own'",
                .{},
            );
            return error.ParseError;
        }
        const name = try self.expect(.ident, "own var name");
        var type_text: ?[]const u8 = null;
        if (self.match(.colon)) {
            const cap = try self.captureTypeUntil(&[_]TokenKind{.eq});
            type_text = std.mem.trim(u8, cap.text, " \t\r\n");
        }
        _ = try self.expect(.eq, "own var = ...");
        const init_cap = try self.captureTypeUntil(&[_]TokenKind{.semicolon});
        const semi = try self.expect(.semicolon, "own decl end");
        return .{
            .name = name.slice(self.source),
            .type_text = type_text,
            .init_text = std.mem.trim(u8, init_cap.text, " \t\r\n"),
            .is_const = is_const,
            .span = .{ .start = start, .end = semi.span.end },
        };
    }

    fn parseMoveStmt(self: *Parser) !ast.MoveExpr {
        const start = self.peek().span.start;
        _ = try self.expect(.kw_move, "move");
        const name = try self.expect(.ident, "move target");
        _ = self.match(.semicolon);
        return .{
            .target = name.slice(self.source),
            .span = .{ .start = start, .end = name.span.end },
        };
    }
};

/// Convenience: lex + parse a source buffer.
pub fn parseSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    arena: *ast.Arena,
    diags: *diag.Diagnostics,
) !ast.File {
    var lx = tok.Lexer.init(source, diags);
    var tokens = try lx.tokenizeAll(allocator);
    defer tokens.deinit(allocator);
    var p = Parser.init(allocator, source, tokens.items, arena, diags);
    return p.parseFile();
}

test "parse trait" {
    const a = std.testing.allocator;
    var diags = diag.Diagnostics.init(a);
    defer diags.deinit();
    var arena = ast.Arena.init(a);
    defer arena.deinit();
    const src = "trait Writer { fn write(self, bytes: []const u8) !usize; }";
    const file = try parseSource(a, src, &arena, &diags);
    try std.testing.expectEqual(@as(usize, 1), file.decls.len);
    try std.testing.expectEqualStrings("Writer", file.decls[0].trait.name);
    try std.testing.expectEqual(@as(usize, 1), file.decls[0].trait.methods.len);
    try std.testing.expectEqualStrings("write", file.decls[0].trait.methods[0].name);
}

test "parse fn with using stmt" {
    const a = std.testing.allocator;
    var diags = diag.Diagnostics.init(a);
    defer diags.deinit();
    var arena = ast.Arena.init(a);
    defer arena.deinit();
    const src =
        \\pub fn main() !void {
        \\    using w = try FileWriter.init("log.txt");
        \\    try emit(&w, "hi");
        \\}
    ;
    const file = try parseSource(a, src, &arena, &diags);
    try std.testing.expectEqual(@as(usize, 1), file.decls.len);
    const fd = file.decls[0].fn_decl;
    try std.testing.expectEqualStrings("main", fd.sig.name);
    try std.testing.expect(fd.sig.is_pub);
    try std.testing.expect(fd.body != null);
    const stmts = fd.body.?.stmts;
    try std.testing.expect(stmts.len >= 1);
    try std.testing.expectEqualStrings("w", stmts[0].using_stmt.name);
}

test "parse owned struct with deinit" {
    const a = std.testing.allocator;
    var diags = diag.Diagnostics.init(a);
    defer diags.deinit();
    var arena = ast.Arena.init(a);
    defer arena.deinit();
    const src =
        \\owned struct FileWriter {
        \\    file: i32,
        \\    pub fn deinit(self: *FileWriter) void { _ = self; }
        \\}
    ;
    const file = try parseSource(a, src, &arena, &diags);
    try std.testing.expectEqual(@as(usize, 1), file.decls.len);
    const od = file.decls[0].owned_struct;
    try std.testing.expectEqualStrings("FileWriter", od.name);
    try std.testing.expectEqual(@as(usize, 1), od.fns.len);
    try std.testing.expectEqualStrings("deinit", od.fns[0].sig.name);
}
