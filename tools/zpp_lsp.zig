const std = @import("std");
const compiler = @import("zpp_compiler");
const fmt_lib = @import("zpp_fmt.zig");

const ExitCode = enum(u8) { ok = 0, user_error = 1 };

pub const ServerError = error{
    BadHeader,
    BadJson,
    Eof,
    OutOfMemory,
    Unexpected,
};

const DocStore = std.StringHashMap([]u8);

/// Cached diagnostic span so hover can resolve `(uri, line, col)` -> code
/// without re-running parse + sema.
const HoverDiag = struct {
    line: usize, // 0-indexed
    col_start: usize,
    col_end: usize,
    code: compiler.diagnostics.Code,
};

const HoverStore = std.StringHashMap(std.ArrayList(HoverDiag));

/// Cached `semanticTokens/full` result so a follow-up `semanticTokens/full/delta`
/// request can diff against it. `result_id` is a monotonically increasing
/// counter the client echoes back as `previousResultId`; `data` is the flat
/// LSP `[deltaLine, deltaStart, length, type, mod]` u32 array we last sent.
const SemanticTokensResult = struct {
    result_id: usize,
    data: []u32,
};

const SemanticTokensStore = std.StringHashMap(SemanticTokensResult);

const Server = struct {
    allocator: std.mem.Allocator,
    docs: DocStore,
    diags: HoverStore,
    semantic_tokens: SemanticTokensStore,
    /// Monotonic counter used to mint a fresh `result_id` per cache write.
    /// Starts at 1; `0` is reserved as "no previous id".
    semantic_tokens_next_id: usize = 1,
    initialized: bool = false,
    shutdown_requested: bool = false,

    fn init(allocator: std.mem.Allocator) Server {
        return .{
            .allocator = allocator,
            .docs = DocStore.init(allocator),
            .diags = HoverStore.init(allocator),
            .semantic_tokens = SemanticTokensStore.init(allocator),
        };
    }

    fn deinit(self: *Server) void {
        var it = self.docs.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.docs.deinit();
        var dit = self.diags.iterator();
        while (dit.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            e.value_ptr.deinit(self.allocator);
        }
        self.diags.deinit();
        var sit = self.semantic_tokens.iterator();
        while (sit.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.data);
        }
        self.semantic_tokens.deinit();
    }
};

pub fn runServer(allocator: std.mem.Allocator) !@import("zpp.zig").ExitCode {
    var server = Server.init(allocator);
    defer server.deinit();

    while (!server.shutdown_requested) {
        const msg = readMessage(allocator) catch |e| switch (e) {
            error.Eof => return .ok,
            else => |err| return err,
        };
        defer allocator.free(msg);

        handleMessage(&server, msg) catch |e| {
            try writeNotify(allocator, "window/logMessage", "{\"type\":1,\"message\":\"server error\"}");
            std.log.warn("zpp-lsp: handler error: {s}", .{@errorName(e)});
        };
    }
    return .ok;
}

/// Read one LSP message from stdin and return its JSON body.
pub fn readMessage(allocator: std.mem.Allocator) ![]u8 {
    var content_length: ?usize = null;
    var header_buf = std.ArrayList(u8){};
    defer header_buf.deinit(allocator);

    const stdin = std.fs.File.stdin();
    while (true) {
        header_buf.clearRetainingCapacity();
        // Read one header line into buffer.
        while (true) {
            var ch: [1]u8 = undefined;
            const n = stdin.read(&ch) catch return error.Eof;
            if (n == 0) return error.Eof;
            try header_buf.append(allocator, ch[0]);
            if (ch[0] == '\n') break;
        }
        const line = std.mem.trimRight(u8, header_buf.items, "\r\n");
        if (line.len == 0) break;
        if (std.mem.startsWith(u8, line, "Content-Length:")) {
            const v = std.mem.trim(u8, line["Content-Length:".len..], " \t");
            content_length = std.fmt.parseInt(usize, v, 10) catch return error.BadHeader;
        }
    }
    const len = content_length orelse return error.BadHeader;
    const body = try allocator.alloc(u8, len);
    var read_total: usize = 0;
    while (read_total < len) {
        const n = stdin.read(body[read_total..]) catch return error.Eof;
        if (n == 0) return error.Eof;
        read_total += n;
    }
    return body;
}

fn writeMessage(allocator: std.mem.Allocator, body: []const u8) !void {
    var hdr_buf: [64]u8 = undefined;
    const hdr = try std.fmt.bufPrint(&hdr_buf, "Content-Length: {d}\r\n\r\n", .{body.len});
    const stdout = std.fs.File.stdout();
    try stdout.writeAll(hdr);
    try stdout.writeAll(body);
    _ = allocator;
}

fn writeNotify(allocator: std.mem.Allocator, method: []const u8, params_json: []const u8) !void {
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}",
        .{ method, params_json },
    );
    defer allocator.free(body);
    try writeMessage(allocator, body);
}

fn writeResult(allocator: std.mem.Allocator, id: []const u8, result_json: []const u8) !void {
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}",
        .{ id, result_json },
    );
    defer allocator.free(body);
    try writeMessage(allocator, body);
}

fn writeError(allocator: std.mem.Allocator, id: []const u8, code: i32, msg: []const u8) !void {
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}",
        .{ id, code, msg },
    );
    defer allocator.free(body);
    try writeMessage(allocator, body);
}

fn handleMessage(server: *Server, raw: []const u8) !void {
    // VERIFY: 0.16 API — std.json.parseFromSlice with managed Value tree.
    const parsed = std.json.parseFromSlice(std.json.Value, server.allocator, raw, .{}) catch return error.BadJson;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.BadJson;
    const obj = root.object;

    const method_v = obj.get("method") orelse return;
    if (method_v != .string) return;
    const method = method_v.string;

    var id_buf: [64]u8 = undefined;
    var id_text: []const u8 = "null";
    if (obj.get("id")) |id_val| {
        id_text = switch (id_val) {
            .integer => |n| try std.fmt.bufPrint(&id_buf, "{d}", .{n}),
            .string => |s| blk: {
                if (s.len + 2 > id_buf.len) break :blk "null";
                id_buf[0] = '"';
                @memcpy(id_buf[1 .. 1 + s.len], s);
                id_buf[1 + s.len] = '"';
                break :blk id_buf[0 .. 2 + s.len];
            },
            else => "null",
        };
    }
    const params = obj.get("params");

    if (std.mem.eql(u8, method, "initialize")) {
        const caps =
            \\{"capabilities":{"textDocumentSync":1,"documentFormattingProvider":true,"hoverProvider":true,"documentSymbolProvider":true,"definitionProvider":true,"referencesProvider":true,"workspaceSymbolProvider":true,"renameProvider":{"prepareProvider":true},"completionProvider":{"triggerCharacters":[".",":"]},"diagnosticProvider":{"interFileDependencies":false,"workspaceDiagnostics":false},"codeActionProvider":{"codeActionKinds":["quickfix"]},"semanticTokensProvider":{"legend":{"tokenTypes":["keyword","string","number","comment","function","interface","struct","variable"],"tokenModifiers":["declaration"]},"full":{"delta":true},"range":true}},"serverInfo":{"name":"zpp-lsp","version":"0.10.0"}}
        ;
        try writeResult(server.allocator, id_text, caps);
        return;
    }
    if (std.mem.eql(u8, method, "initialized")) {
        server.initialized = true;
        return;
    }
    if (std.mem.eql(u8, method, "shutdown")) {
        server.shutdown_requested = true;
        try writeResult(server.allocator, id_text, "null");
        return;
    }
    if (std.mem.eql(u8, method, "exit")) {
        server.shutdown_requested = true;
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/didOpen")) {
        try onDidOpen(server, params);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/didChange")) {
        try onDidChange(server, params);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/didClose")) {
        try onDidClose(server, params);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/formatting")) {
        try onFormatting(server, id_text, params);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/hover")) {
        try onHover(server, id_text, params);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/documentSymbol")) {
        try onDocumentSymbol(server, id_text, params);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/completion")) {
        try onCompletion(server, id_text, params);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/definition")) {
        try onDefinition(server, id_text, params);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/references")) {
        try onReferences(server, id_text, params);
        return;
    }
    if (std.mem.eql(u8, method, "workspace/symbol")) {
        try onWorkspaceSymbol(server, id_text, params);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/prepareRename")) {
        try onPrepareRename(server, id_text, params);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/rename")) {
        try onRename(server, id_text, params);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/codeAction")) {
        try onCodeAction(server, id_text, params);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/semanticTokens/full")) {
        try onSemanticTokensFull(server, id_text, params);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/semanticTokens/full/delta")) {
        try onSemanticTokensFullDelta(server, id_text, params);
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/semanticTokens/range")) {
        try onSemanticTokensRange(server, id_text, params);
        return;
    }
    if (obj.get("id") != null) {
        try writeError(server.allocator, id_text, -32601, "method not found");
    }
}

fn onHover(server: *Server, id_text: []const u8, params: ?std.json.Value) !void {
    const p = params orelse {
        try writeResult(server.allocator, id_text, "null");
        return;
    };
    const td = p.object.get("textDocument") orelse {
        try writeResult(server.allocator, id_text, "null");
        return;
    };
    const uri = td.object.get("uri") orelse {
        try writeResult(server.allocator, id_text, "null");
        return;
    };
    const pos = p.object.get("position") orelse {
        try writeResult(server.allocator, id_text, "null");
        return;
    };
    const line: usize = @intCast(pos.object.get("line").?.integer);
    const character: usize = @intCast(pos.object.get("character").?.integer);

    const list = server.diags.getPtr(uri.string) orelse {
        try writeResult(server.allocator, id_text, "null");
        return;
    };
    for (list.items) |hd| {
        if (hd.line != line) continue;
        if (character < hd.col_start or character > hd.col_end) continue;
        const explain_text = compiler.diagnostics.explain(hd.code);
        // Format as a Markdown hover: title, explain block, and a docs link
        // so users can jump to the canonical reference for this code.
        const code_id_lower = try lowerAscii(server.allocator, hd.code.id());
        defer server.allocator.free(code_id_lower);
        const md = try std.fmt.allocPrint(
            server.allocator,
            "**{s}**\n\n```text\n{s}\n```\n\n[See: docs/diagnostics#{s}](https://nktkt.github.io/zigpp-lang/language.html#{s})",
            .{ hd.code.id(), explain_text, code_id_lower, code_id_lower },
        );
        defer server.allocator.free(md);
        const escaped = try jsonStringify(server.allocator, md);
        defer server.allocator.free(escaped);
        const result = try std.fmt.allocPrint(
            server.allocator,
            "{{\"contents\":{{\"kind\":\"markdown\",\"value\":{s}}}}}",
            .{escaped},
        );
        defer server.allocator.free(result);
        try writeResult(server.allocator, id_text, result);
        return;
    }
    try writeResult(server.allocator, id_text, "null");
}

fn extractTextDoc(params: ?std.json.Value) ?struct {
    uri: []const u8,
    text: []const u8,
} {
    const p = params orelse return null;
    if (p != .object) return null;
    const td = p.object.get("textDocument") orelse return null;
    if (td != .object) return null;
    const uri_v = td.object.get("uri") orelse return null;
    if (uri_v != .string) return null;
    var text: []const u8 = "";
    if (td.object.get("text")) |t| {
        if (t == .string) text = t.string;
    }
    return .{ .uri = uri_v.string, .text = text };
}

fn extractContentChange(params: ?std.json.Value) ?struct {
    uri: []const u8,
    text: []const u8,
} {
    const p = params orelse return null;
    if (p != .object) return null;
    const td = p.object.get("textDocument") orelse return null;
    if (td != .object) return null;
    const uri_v = td.object.get("uri") orelse return null;
    if (uri_v != .string) return null;
    const changes = p.object.get("contentChanges") orelse return null;
    if (changes != .array) return null;
    if (changes.array.items.len == 0) return null;
    const last = changes.array.items[changes.array.items.len - 1];
    if (last != .object) return null;
    const text_v = last.object.get("text") orelse return null;
    if (text_v != .string) return null;
    return .{ .uri = uri_v.string, .text = text_v.string };
}

fn onDidOpen(server: *Server, params: ?std.json.Value) !void {
    const info = extractTextDoc(params) orelse return;
    try storeDoc(server, info.uri, info.text);
    try publishDiagnostics(server, info.uri, info.text);
}

fn onDidChange(server: *Server, params: ?std.json.Value) !void {
    const info = extractContentChange(params) orelse return;
    try storeDoc(server, info.uri, info.text);
    try publishDiagnostics(server, info.uri, info.text);
}

fn onDidClose(server: *Server, params: ?std.json.Value) !void {
    const p = params orelse return;
    if (p != .object) return;
    const td = p.object.get("textDocument") orelse return;
    if (td != .object) return;
    const uri_v = td.object.get("uri") orelse return;
    if (uri_v != .string) return;
    if (server.docs.fetchRemove(uri_v.string)) |kv| {
        server.allocator.free(kv.key);
        server.allocator.free(kv.value);
    }
}

fn storeDoc(server: *Server, uri: []const u8, text: []const u8) !void {
    if (server.docs.fetchRemove(uri)) |kv| {
        server.allocator.free(kv.key);
        server.allocator.free(kv.value);
    }
    const key = try server.allocator.dupe(u8, uri);
    const val = try server.allocator.dupe(u8, text);
    try server.docs.put(key, val);
}

fn publishDiagnostics(server: *Server, uri: []const u8, text: []const u8) !void {
    var diags_array = std.ArrayList(u8){};
    defer diags_array.deinit(server.allocator);
    try diags_array.appendSlice(server.allocator, "[");

    // Reset hover cache for this URI.
    if (server.diags.fetchRemove(uri)) |entry| {
        server.allocator.free(entry.key);
        var v = entry.value;
        v.deinit(server.allocator);
    }
    var hover_list: std.ArrayList(HoverDiag) = .{};
    errdefer hover_list.deinit(server.allocator);

    // COMPILER_API: parseAndAnalyze surface; if missing we degrade silently.
    var first = true;
    if (compiler.parseAndAnalyze(server.allocator, text)) |result_const| {
        var result = result_const;
        defer result.diags.deinit();
        for (result.diags.items.items) |d| {
            const lc = compiler.locate(text, d.span.start);
            const sev: u8 = switch (d.severity) {
                .err => 1,
                .warning => 2,
                .note => 3,
            };
            if (!first) try diags_array.appendSlice(server.allocator, ",");
            first = false;
            const lc_end = compiler.locate(text, d.span.end);
            // Cache line-anchored: hover on any column of the diag's start
            // line returns the explanation. Wider matches help users who
            // squint at the underline rather than the exact caret column.
            try hover_list.append(server.allocator, .{
                .line = lc.line - 1,
                .col_start = 0,
                .col_end = if (lc_end.line == lc.line) lc_end.col else std.math.maxInt(usize),
                .code = d.code,
            });
            const entry = try std.fmt.allocPrint(
                server.allocator,
                "{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"severity\":{d},\"code\":\"{s}\",\"message\":{s}}}",
                .{
                    lc.line - 1, lc.col - 1,
                    lc.line - 1, lc.col,
                    sev, d.code.id(),
                    try jsonStringify(server.allocator, d.message),
                },
            );
            defer server.allocator.free(entry);
            try diags_array.appendSlice(server.allocator, entry);
        }
    } else |_| {}

    try diags_array.appendSlice(server.allocator, "]");

    const uri_dup = try server.allocator.dupe(u8, uri);
    try server.diags.put(uri_dup, hover_list);

    const params = try std.fmt.allocPrint(
        server.allocator,
        "{{\"uri\":{s},\"diagnostics\":{s}}}",
        .{ try jsonStringify(server.allocator, uri), diags_array.items },
    );
    defer server.allocator.free(params);
    try writeNotify(server.allocator, "textDocument/publishDiagnostics", params);
}

fn onFormatting(server: *Server, id_text: []const u8, params: ?std.json.Value) !void {
    const p = params orelse return writeResult(server.allocator, id_text, "null");
    if (p != .object) return writeResult(server.allocator, id_text, "null");
    const td = p.object.get("textDocument") orelse return writeResult(server.allocator, id_text, "null");
    if (td != .object) return writeResult(server.allocator, id_text, "null");
    const uri_v = td.object.get("uri") orelse return writeResult(server.allocator, id_text, "null");
    if (uri_v != .string) return writeResult(server.allocator, id_text, "null");

    const text = server.docs.get(uri_v.string) orelse {
        try writeResult(server.allocator, id_text, "[]");
        return;
    };
    const formatted = fmt_lib.formatSource(server.allocator, text) catch {
        try writeResult(server.allocator, id_text, "[]");
        return;
    };
    defer server.allocator.free(formatted);

    const line_count = countLines(text);
    const new_text_json = try jsonStringify(server.allocator, formatted);
    const edit = try std.fmt.allocPrint(
        server.allocator,
        "[{{\"range\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":{d},\"character\":0}}}},\"newText\":{s}}}]",
        .{ line_count, new_text_json },
    );
    defer server.allocator.free(edit);
    try writeResult(server.allocator, id_text, edit);
}

/// LSP SymbolKind integers as defined by the spec
/// (https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#symbolKind).
/// Only the ones we currently emit are listed here.
const SymbolKind = enum(u8) {
    module = 2,
    class = 5,
    method = 6,
    interface = 11,
    function = 12,
    @"struct" = 23,
};

const LspRange = struct {
    start_line: u32,
    start_col: u32,
    end_line: u32,
    end_col: u32,
};

fn rangeFromSpan(source: []const u8, span: compiler.diagnostics.Span) LspRange {
    const start = compiler.locate(source, span.start);
    const end = compiler.locate(source, span.end);
    return .{
        .start_line = start.line - 1,
        .start_col = if (start.col == 0) 0 else start.col - 1,
        .end_line = end.line - 1,
        .end_col = if (end.col == 0) 0 else end.col - 1,
    };
}

fn appendRangeJson(out: *std.ArrayList(u8), allocator: std.mem.Allocator, r: LspRange) !void {
    const buf = try std.fmt.allocPrint(
        allocator,
        "{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ r.start_line, r.start_col, r.end_line, r.end_col },
    );
    defer allocator.free(buf);
    try out.appendSlice(allocator, buf);
}

fn appendSymbol(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    kind: SymbolKind,
    range: LspRange,
    children_json: ?[]const u8,
) !void {
    const name_json = try jsonStringify(allocator, name);
    defer allocator.free(name_json);

    try out.appendSlice(allocator, "{\"name\":");
    try out.appendSlice(allocator, name_json);
    const head = try std.fmt.allocPrint(allocator, ",\"kind\":{d},\"range\":", .{@intFromEnum(kind)});
    defer allocator.free(head);
    try out.appendSlice(allocator, head);
    try appendRangeJson(out, allocator, range);
    try out.appendSlice(allocator, ",\"selectionRange\":");
    try appendRangeJson(out, allocator, range);
    if (children_json) |c| {
        try out.appendSlice(allocator, ",\"children\":");
        try out.appendSlice(allocator, c);
    }
    try out.appendSlice(allocator, "}");
}

fn buildMethodChildren(
    allocator: std.mem.Allocator,
    source: []const u8,
    fn_decls: []const compiler.ast.FnDecl,
) ![]u8 {
    var arr = std.ArrayList(u8){};
    defer arr.deinit(allocator);
    try arr.append(allocator, '[');
    var first = true;
    for (fn_decls) |fd| {
        if (!first) try arr.append(allocator, ',');
        first = false;
        try appendSymbol(&arr, allocator, fd.sig.name, .method, rangeFromSpan(source, fd.sig.span), null);
    }
    try arr.append(allocator, ']');
    return arr.toOwnedSlice(allocator);
}

fn buildTraitMethodChildren(
    allocator: std.mem.Allocator,
    source: []const u8,
    methods: []const compiler.ast.TraitMethod,
) ![]u8 {
    var arr = std.ArrayList(u8){};
    defer arr.deinit(allocator);
    try arr.append(allocator, '[');
    var first = true;
    for (methods) |m| {
        if (!first) try arr.append(allocator, ',');
        first = false;
        try appendSymbol(&arr, allocator, m.name, .method, rangeFromSpan(source, m.span), null);
    }
    try arr.append(allocator, ']');
    return arr.toOwnedSlice(allocator);
}

fn onDocumentSymbol(server: *Server, id_text: []const u8, params: ?std.json.Value) !void {
    const p = params orelse return writeResult(server.allocator, id_text, "[]");
    if (p != .object) return writeResult(server.allocator, id_text, "[]");
    const td = p.object.get("textDocument") orelse return writeResult(server.allocator, id_text, "[]");
    if (td != .object) return writeResult(server.allocator, id_text, "[]");
    const uri_v = td.object.get("uri") orelse return writeResult(server.allocator, id_text, "[]");
    if (uri_v != .string) return writeResult(server.allocator, id_text, "[]");

    const text = server.docs.get(uri_v.string) orelse {
        try writeResult(server.allocator, id_text, "[]");
        return;
    };

    const allocator = server.allocator;
    const symbols = buildDocumentSymbols(allocator, text) catch {
        try writeResult(server.allocator, id_text, "[]");
        return;
    };
    defer allocator.free(symbols);
    try writeResult(server.allocator, id_text, symbols);
}

/// Build the `result` JSON array (as an owned slice) for a documentSymbol
/// response over `source`. Returns "[]" on parse failure rather than
/// erroring — partial syntax mid-edit is the common case in an LSP.
fn buildDocumentSymbols(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var diags = compiler.Diagnostics.init(allocator);
    defer diags.deinit();
    var arena = compiler.ast.Arena.init(allocator);
    defer arena.deinit();

    const file = compiler.parseSource(allocator, source, &arena, &diags) catch {
        return try allocator.dupe(u8, "[]");
    };

    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);
    try out.append(allocator, '[');
    var first = true;

    for (file.decls) |decl| {
        switch (decl) {
            .fn_decl => |fd| {
                if (!first) try out.append(allocator, ',');
                first = false;
                try appendSymbol(&out, allocator, fd.sig.name, .function, rangeFromSpan(source, decl.span()), null);
            },
            .trait => |t| {
                if (!first) try out.append(allocator, ',');
                first = false;
                const children = try buildTraitMethodChildren(allocator, source, t.methods);
                defer allocator.free(children);
                try appendSymbol(&out, allocator, t.name, .interface, rangeFromSpan(source, t.span), children);
            },
            .impl_block => |ib| {
                if (!first) try out.append(allocator, ',');
                first = false;
                const label = try std.fmt.allocPrint(allocator, "impl {s} for {s}", .{ ib.trait_name, ib.target_type });
                defer allocator.free(label);
                const children = try buildMethodChildren(allocator, source, ib.fns);
                defer allocator.free(children);
                try appendSymbol(&out, allocator, label, .class, rangeFromSpan(source, ib.span), children);
            },
            .owned_struct => |os| {
                if (!first) try out.append(allocator, ',');
                first = false;
                const children = try buildMethodChildren(allocator, source, os.fns);
                defer allocator.free(children);
                try appendSymbol(&out, allocator, os.name, .@"struct", rangeFromSpan(source, os.span), children);
            },
            .struct_decl => |sd| {
                if (!first) try out.append(allocator, ',');
                first = false;
                const children = try buildMethodChildren(allocator, source, sd.fns);
                defer allocator.free(children);
                try appendSymbol(&out, allocator, sd.name, .@"struct", rangeFromSpan(source, sd.span), children);
            },
            .extern_interface => |ei| {
                if (!first) try out.append(allocator, ',');
                first = false;
                const children = try buildTraitMethodChildren(allocator, source, ei.methods);
                defer allocator.free(children);
                try appendSymbol(&out, allocator, ei.name, .module, rangeFromSpan(source, ei.span), children);
            },
            .raw => {}, // No useful symbol for raw Zig blobs.
        }
    }

    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

/// LSP CompletionItemKind integers
/// (https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#completionItemKind).
/// Only the few values we emit are listed.
const CompletionItemKind = enum(u8) {
    function = 3,
    class = 7,
    keyword = 14,
};

fn onCompletion(server: *Server, id_text: []const u8, params: ?std.json.Value) !void {
    // We deliberately ignore the position context for the MVP; the result is
    // always (keywords ∪ top-level idents from the cached doc).
    var uri_opt: ?[]const u8 = null;
    if (params) |p| {
        if (p == .object) {
            if (p.object.get("textDocument")) |td| {
                if (td == .object) {
                    if (td.object.get("uri")) |u| {
                        if (u == .string) uri_opt = u.string;
                    }
                }
            }
        }
    }
    const text_opt: ?[]const u8 = if (uri_opt) |uri| server.docs.get(uri) else null;
    const result = try buildCompletionResult(server.allocator, text_opt);
    defer server.allocator.free(result);
    try writeResult(server.allocator, id_text, result);
}

/// Build the `result` JSON object for a completion response. Always emits
/// every Zig++ keyword; if `text` parses, also adds top-level decl names.
/// Falls back to keywords-only on parse failure or missing doc text.
fn buildCompletionResult(allocator: std.mem.Allocator, text: ?[]const u8) ![]u8 {
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    var items = std.ArrayList(u8){};
    defer items.deinit(allocator);
    try items.append(allocator, '[');
    var first = true;

    // Keywords come straight from compiler/token.zig so the LSP can never
    // drift from the lexer's notion of what's reserved.
    inline for (compiler.token.keywords) |kw| {
        if (!seen.contains(kw.name)) {
            try seen.put(kw.name, {});
            if (!first) try items.append(allocator, ',');
            first = false;
            try appendCompletionItem(&items, allocator, kw.name, .keyword);
        }
    }

    // Top-level identifiers from a fresh parse of the cached doc text. Best-
    // effort: any failure (no doc, parse error) leaves us with the keyword-
    // only list.
    if (text) |src| {
        addIdentItems(allocator, &items, &first, &seen, src) catch {};
    }

    try items.append(allocator, ']');

    return try std.fmt.allocPrint(
        allocator,
        "{{\"isIncomplete\":false,\"items\":{s}}}",
        .{items.items},
    );
}

fn addIdentItems(
    allocator: std.mem.Allocator,
    items: *std.ArrayList(u8),
    first: *bool,
    seen: *std.StringHashMap(void),
    source: []const u8,
) !void {
    var diags = compiler.Diagnostics.init(allocator);
    defer diags.deinit();
    var arena = compiler.ast.Arena.init(allocator);
    defer arena.deinit();

    const file = try compiler.parseSource(allocator, source, &arena, &diags);
    for (file.decls) |decl| {
        const entry: ?struct { name: []const u8, kind: CompletionItemKind } = switch (decl) {
            .fn_decl => |fd| .{ .name = fd.sig.name, .kind = .function },
            .trait => |t| .{ .name = t.name, .kind = .class },
            .owned_struct => |os| .{ .name = os.name, .kind = .class },
            .struct_decl => |sd| .{ .name = sd.name, .kind = .class },
            .extern_interface => |ei| .{ .name = ei.name, .kind = .class },
            .impl_block => |ib| .{ .name = ib.target_type, .kind = .class },
            .raw => null,
        };
        if (entry) |e| {
            if (seen.contains(e.name)) continue;
            try seen.put(e.name, {});
            if (!first.*) try items.append(allocator, ',');
            first.* = false;
            try appendCompletionItem(items, allocator, e.name, e.kind);
        }
    }
}

fn appendCompletionItem(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    label: []const u8,
    kind: CompletionItemKind,
) !void {
    const label_json = try jsonStringify(allocator, label);
    defer allocator.free(label_json);
    const buf = try std.fmt.allocPrint(
        allocator,
        "{{\"label\":{s},\"kind\":{d}}}",
        .{ label_json, @intFromEnum(kind) },
    );
    defer allocator.free(buf);
    try out.appendSlice(allocator, buf);
}

/// Convert an LSP (line, character) position to a byte offset in `source`.
/// Both inputs are 0-indexed per LSP spec. Returns null when the position
/// is past EOF; clamps `character` to end-of-line.
fn posToOffset(source: []const u8, line: usize, character: usize) ?u32 {
    var off: u32 = 0;
    var cur_line: usize = 0;
    while (cur_line < line) {
        if (off >= source.len) return null;
        if (source[off] == '\n') cur_line += 1;
        off += 1;
    }
    var col: usize = 0;
    while (col < character) : (col += 1) {
        if (off >= source.len) return off;
        if (source[off] == '\n') return off;
        off += 1;
    }
    return off;
}

/// Return the identifier slice of `source` straddling byte offset `off`,
/// or null if `off` isn't on an identifier byte. Walks backward to the
/// first ident-start byte and forward through ident-cont bytes.
fn identAt(source: []const u8, off: u32) ?[]const u8 {
    if (off >= source.len) return null;
    if (!compiler.token.identCont(source[off])) return null;
    var start: u32 = off;
    while (start > 0 and compiler.token.identCont(source[start - 1])) start -= 1;
    if (!compiler.token.identStart(source[start])) return null;
    var end: u32 = off + 1;
    while (end < source.len and compiler.token.identCont(source[end])) end += 1;
    return source[start..end];
}

fn onDefinition(server: *Server, id_text: []const u8, params: ?std.json.Value) !void {
    const p = params orelse return writeResult(server.allocator, id_text, "null");
    if (p != .object) return writeResult(server.allocator, id_text, "null");
    const td = p.object.get("textDocument") orelse return writeResult(server.allocator, id_text, "null");
    if (td != .object) return writeResult(server.allocator, id_text, "null");
    const uri_v = td.object.get("uri") orelse return writeResult(server.allocator, id_text, "null");
    if (uri_v != .string) return writeResult(server.allocator, id_text, "null");
    const pos_v = p.object.get("position") orelse return writeResult(server.allocator, id_text, "null");
    if (pos_v != .object) return writeResult(server.allocator, id_text, "null");
    const line_v = pos_v.object.get("line") orelse return writeResult(server.allocator, id_text, "null");
    const char_v = pos_v.object.get("character") orelse return writeResult(server.allocator, id_text, "null");
    if (line_v != .integer or char_v != .integer) return writeResult(server.allocator, id_text, "null");
    if (line_v.integer < 0 or char_v.integer < 0) return writeResult(server.allocator, id_text, "null");

    const text = server.docs.get(uri_v.string) orelse {
        try writeResult(server.allocator, id_text, "null");
        return;
    };
    const allocator = server.allocator;
    const result = try buildDefinition(
        allocator,
        text,
        uri_v.string,
        @intCast(line_v.integer),
        @intCast(char_v.integer),
    );
    defer allocator.free(result);
    try writeResult(server.allocator, id_text, result);
}

/// Build the JSON `result` payload (a Location object or "null") for a
/// same-file definition lookup. Returns "null" when:
///   - the position is not on an identifier
///   - the identifier doesn't match any top-level decl name
///   - the document fails to parse
fn buildDefinition(
    allocator: std.mem.Allocator,
    source: []const u8,
    uri: []const u8,
    line: usize,
    character: usize,
) ![]u8 {
    const off = posToOffset(source, line, character) orelse return allocator.dupe(u8, "null");
    const ident = identAt(source, off) orelse return allocator.dupe(u8, "null");

    var diags = compiler.Diagnostics.init(allocator);
    defer diags.deinit();
    var arena = compiler.ast.Arena.init(allocator);
    defer arena.deinit();
    const file = compiler.parseSource(allocator, source, &arena, &diags) catch {
        return allocator.dupe(u8, "null");
    };

    for (file.decls) |decl| {
        const name: ?[]const u8 = switch (decl) {
            .fn_decl => |fd| fd.sig.name,
            .trait => |t| t.name,
            .owned_struct => |os| os.name,
            .struct_decl => |sd| sd.name,
            .extern_interface => |ei| ei.name,
            .impl_block, .raw => null,
        };
        if (name == null) continue;
        if (!std.mem.eql(u8, name.?, ident)) continue;

        var out = std.ArrayList(u8){};
        defer out.deinit(allocator);
        const uri_json = try jsonStringify(allocator, uri);
        defer allocator.free(uri_json);
        try out.appendSlice(allocator, "{\"uri\":");
        try out.appendSlice(allocator, uri_json);
        try out.appendSlice(allocator, ",\"range\":");
        try appendRangeJson(&out, allocator, rangeFromSpan(source, decl.span()));
        try out.append(allocator, '}');
        return out.toOwnedSlice(allocator);
    }
    return allocator.dupe(u8, "null");
}

fn onReferences(server: *Server, id_text: []const u8, params: ?std.json.Value) !void {
    const p = params orelse return writeResult(server.allocator, id_text, "[]");
    if (p != .object) return writeResult(server.allocator, id_text, "[]");
    const td = p.object.get("textDocument") orelse return writeResult(server.allocator, id_text, "[]");
    if (td != .object) return writeResult(server.allocator, id_text, "[]");
    const uri_v = td.object.get("uri") orelse return writeResult(server.allocator, id_text, "[]");
    if (uri_v != .string) return writeResult(server.allocator, id_text, "[]");
    const pos_v = p.object.get("position") orelse return writeResult(server.allocator, id_text, "[]");
    if (pos_v != .object) return writeResult(server.allocator, id_text, "[]");
    const line_v = pos_v.object.get("line") orelse return writeResult(server.allocator, id_text, "[]");
    const char_v = pos_v.object.get("character") orelse return writeResult(server.allocator, id_text, "[]");
    if (line_v != .integer or char_v != .integer) return writeResult(server.allocator, id_text, "[]");
    if (line_v.integer < 0 or char_v.integer < 0) return writeResult(server.allocator, id_text, "[]");

    // Default per LSP spec is `true` when context is absent.
    var include_declaration: bool = true;
    if (p.object.get("context")) |ctx| {
        if (ctx == .object) {
            if (ctx.object.get("includeDeclaration")) |inc| {
                if (inc == .bool) include_declaration = inc.bool;
            }
        }
    }

    const text = server.docs.get(uri_v.string) orelse {
        try writeResult(server.allocator, id_text, "[]");
        return;
    };
    const allocator = server.allocator;
    const result = try buildReferences(
        allocator,
        text,
        uri_v.string,
        @intCast(line_v.integer),
        @intCast(char_v.integer),
        include_declaration,
    );
    defer allocator.free(result);
    try writeResult(server.allocator, id_text, result);
}

/// Build the JSON `result` array for a textDocument/references request.
/// Same-file only: scans `source` for whole-word matches of the identifier
/// under the cursor, skipping string literals, char literals, and `//` line
/// comments. When `include_declaration` is false, drops the occurrence whose
/// span overlaps the matched top-level decl's name span.
///
/// Returns "[]" when:
///   - the position is not on an identifier
///   - the identifier matches no occurrences
fn buildReferences(
    allocator: std.mem.Allocator,
    source: []const u8,
    uri: []const u8,
    line: usize,
    character: usize,
    include_declaration: bool,
) ![]u8 {
    const off = posToOffset(source, line, character) orelse return allocator.dupe(u8, "[]");
    const ident = identAt(source, off) orelse return allocator.dupe(u8, "[]");

    // Locate the matched top-level decl's name span (if any) so we can drop
    // it when `includeDeclaration == false`. We try to parse, but a parse
    // failure just means we treat all hits as references (no decl to skip).
    var decl_name_off: ?u32 = null;
    var decl_name_len: usize = 0;
    var diags = compiler.Diagnostics.init(allocator);
    defer diags.deinit();
    var arena = compiler.ast.Arena.init(allocator);
    defer arena.deinit();
    if (compiler.parseSource(allocator, source, &arena, &diags)) |file| {
        for (file.decls) |decl| {
            const name: ?[]const u8 = switch (decl) {
                .fn_decl => |fd| fd.sig.name,
                .trait => |t| t.name,
                .owned_struct => |os| os.name,
                .struct_decl => |sd| sd.name,
                .extern_interface => |ei| ei.name,
                .impl_block, .raw => null,
            };
            if (name == null) continue;
            if (!std.mem.eql(u8, name.?, ident)) continue;
            // Identifier text is borrowed from the source buffer — its
            // pointer offset is therefore the byte offset of the decl name
            // occurrence we want to skip.
            const name_ptr = @intFromPtr(name.?.ptr);
            const src_ptr = @intFromPtr(source.ptr);
            if (name_ptr >= src_ptr and name_ptr < src_ptr + source.len) {
                decl_name_off = @intCast(name_ptr - src_ptr);
                decl_name_len = name.?.len;
            }
            break;
        }
    } else |_| {}

    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);
    try out.append(allocator, '[');
    var first_hit = true;

    const uri_json = try jsonStringify(allocator, uri);
    defer allocator.free(uri_json);

    var i: usize = 0;
    while (i < source.len) {
        const c = source[i];
        // Skip over double-quoted string literals.
        if (c == '"') {
            i += 1;
            while (i < source.len) : (i += 1) {
                if (source[i] == '\\' and i + 1 < source.len) {
                    i += 1;
                    continue;
                }
                if (source[i] == '"') {
                    i += 1;
                    break;
                }
            }
            continue;
        }
        // Skip over char literals.
        if (c == '\'') {
            i += 1;
            while (i < source.len and source[i] != '\'') : (i += 1) {
                if (source[i] == '\\' and i + 1 < source.len) i += 1;
            }
            if (i < source.len) i += 1;
            continue;
        }
        // Skip over `//` line comments.
        if (c == '/' and i + 1 < source.len and source[i + 1] == '/') {
            while (i < source.len and source[i] != '\n') i += 1;
            continue;
        }
        // Look for an ident-start at i with left-boundary, then match
        // the full word and compare to `ident`.
        if (compiler.token.identStart(c) and (i == 0 or !compiler.token.identCont(source[i - 1]))) {
            var end: usize = i + 1;
            while (end < source.len and compiler.token.identCont(source[end])) end += 1;
            const word = source[i..end];
            if (std.mem.eql(u8, word, ident)) {
                const skip_decl = if (decl_name_off) |dno|
                    !include_declaration and i == dno and word.len == decl_name_len
                else
                    false;
                if (!skip_decl) {
                    if (!first_hit) try out.append(allocator, ',');
                    first_hit = false;
                    try out.appendSlice(allocator, "{\"uri\":");
                    try out.appendSlice(allocator, uri_json);
                    try out.appendSlice(allocator, ",\"range\":");
                    const span: compiler.diagnostics.Span = .{ .start = @intCast(i), .end = @intCast(end) };
                    try appendRangeJson(&out, allocator, rangeFromSpan(source, span));
                    try out.append(allocator, '}');
                }
            }
            i = end;
            continue;
        }
        i += 1;
    }

    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

fn onPrepareRename(server: *Server, id_text: []const u8, params: ?std.json.Value) !void {
    const p = params orelse return writeResult(server.allocator, id_text, "null");
    if (p != .object) return writeResult(server.allocator, id_text, "null");
    const td = p.object.get("textDocument") orelse return writeResult(server.allocator, id_text, "null");
    if (td != .object) return writeResult(server.allocator, id_text, "null");
    const uri_v = td.object.get("uri") orelse return writeResult(server.allocator, id_text, "null");
    if (uri_v != .string) return writeResult(server.allocator, id_text, "null");
    const pos_v = p.object.get("position") orelse return writeResult(server.allocator, id_text, "null");
    if (pos_v != .object) return writeResult(server.allocator, id_text, "null");
    const line_v = pos_v.object.get("line") orelse return writeResult(server.allocator, id_text, "null");
    const char_v = pos_v.object.get("character") orelse return writeResult(server.allocator, id_text, "null");
    if (line_v != .integer or char_v != .integer) return writeResult(server.allocator, id_text, "null");
    if (line_v.integer < 0 or char_v.integer < 0) return writeResult(server.allocator, id_text, "null");

    const text = server.docs.get(uri_v.string) orelse {
        try writeResult(server.allocator, id_text, "null");
        return;
    };
    const allocator = server.allocator;
    const result = try buildPrepareRename(
        allocator,
        text,
        @intCast(line_v.integer),
        @intCast(char_v.integer),
    );
    defer allocator.free(result);
    try writeResult(server.allocator, id_text, result);
}

/// Build the JSON `result` payload (a `{range, placeholder}` object or
/// "null") for a textDocument/prepareRename request. Returns "null" when:
///   - the position is not on an identifier
///   - the identifier doesn't match any top-level decl name in the same file
///   - the document fails to parse
///
/// We deliberately scope rename to top-level decl names: arbitrary identifier
/// rename without symbol resolution is too easy to mis-trigger.
fn buildPrepareRename(
    allocator: std.mem.Allocator,
    source: []const u8,
    line: usize,
    character: usize,
) ![]u8 {
    const off = posToOffset(source, line, character) orelse return allocator.dupe(u8, "null");
    const ident = identAt(source, off) orelse return allocator.dupe(u8, "null");

    var diags = compiler.Diagnostics.init(allocator);
    defer diags.deinit();
    var arena = compiler.ast.Arena.init(allocator);
    defer arena.deinit();
    const file = compiler.parseSource(allocator, source, &arena, &diags) catch {
        return allocator.dupe(u8, "null");
    };

    var matches = false;
    for (file.decls) |decl| {
        const name: ?[]const u8 = switch (decl) {
            .fn_decl => |fd| fd.sig.name,
            .trait => |t| t.name,
            .owned_struct => |os| os.name,
            .struct_decl => |sd| sd.name,
            .extern_interface => |ei| ei.name,
            .impl_block, .raw => null,
        };
        if (name == null) continue;
        if (std.mem.eql(u8, name.?, ident)) {
            matches = true;
            break;
        }
    }
    if (!matches) return allocator.dupe(u8, "null");

    // Compute the LSP range for the identifier under the cursor.
    var start: u32 = off;
    while (start > 0 and compiler.token.identCont(source[start - 1])) start -= 1;
    var end: u32 = off + 1;
    while (end < source.len and compiler.token.identCont(source[end])) end += 1;
    const span: compiler.diagnostics.Span = .{ .start = start, .end = end };

    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"range\":");
    try appendRangeJson(&out, allocator, rangeFromSpan(source, span));
    const placeholder_json = try jsonStringify(allocator, ident);
    defer allocator.free(placeholder_json);
    try out.appendSlice(allocator, ",\"placeholder\":");
    try out.appendSlice(allocator, placeholder_json);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn onRename(server: *Server, id_text: []const u8, params: ?std.json.Value) !void {
    const p = params orelse return writeResult(server.allocator, id_text, "null");
    if (p != .object) return writeResult(server.allocator, id_text, "null");
    const td = p.object.get("textDocument") orelse return writeResult(server.allocator, id_text, "null");
    if (td != .object) return writeResult(server.allocator, id_text, "null");
    const uri_v = td.object.get("uri") orelse return writeResult(server.allocator, id_text, "null");
    if (uri_v != .string) return writeResult(server.allocator, id_text, "null");
    const pos_v = p.object.get("position") orelse return writeResult(server.allocator, id_text, "null");
    if (pos_v != .object) return writeResult(server.allocator, id_text, "null");
    const line_v = pos_v.object.get("line") orelse return writeResult(server.allocator, id_text, "null");
    const char_v = pos_v.object.get("character") orelse return writeResult(server.allocator, id_text, "null");
    if (line_v != .integer or char_v != .integer) return writeResult(server.allocator, id_text, "null");
    if (line_v.integer < 0 or char_v.integer < 0) return writeResult(server.allocator, id_text, "null");
    const new_name_v = p.object.get("newName") orelse return writeResult(server.allocator, id_text, "null");
    if (new_name_v != .string) return writeResult(server.allocator, id_text, "null");

    const text = server.docs.get(uri_v.string) orelse {
        try writeResult(server.allocator, id_text, "null");
        return;
    };
    const allocator = server.allocator;
    const result = try buildRename(
        allocator,
        text,
        uri_v.string,
        @intCast(line_v.integer),
        @intCast(char_v.integer),
        new_name_v.string,
    );
    defer allocator.free(result);
    try writeResult(server.allocator, id_text, result);
}

/// Validate that `s` is a syntactically legal identifier per the lexer's
/// notion of ident-start / ident-cont. Empty strings are rejected.
fn isValidIdent(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!compiler.token.identStart(s[0])) return false;
    for (s[1..]) |c| {
        if (!compiler.token.identCont(c)) return false;
    }
    return true;
}

/// Build the JSON `result` payload (a `WorkspaceEdit` object or "null") for
/// a textDocument/rename request. Same-file only.
///
/// Returns "null" when:
///   - the position is not on an identifier
///   - the identifier doesn't match any top-level decl name in the same file
///   - `new_name` is not a valid identifier
///   - the document fails to parse
///
/// The scan logic (whole-word match, skip strings/chars/`//` comments)
/// mirrors `buildReferences` exactly: every reference becomes a `TextEdit`.
fn buildRename(
    allocator: std.mem.Allocator,
    source: []const u8,
    uri: []const u8,
    line: usize,
    character: usize,
    new_name: []const u8,
) ![]u8 {
    if (!isValidIdent(new_name)) return allocator.dupe(u8, "null");

    const off = posToOffset(source, line, character) orelse return allocator.dupe(u8, "null");
    const ident = identAt(source, off) orelse return allocator.dupe(u8, "null");

    // Same renameability gate as `buildPrepareRename`: only top-level decl
    // names. This keeps rename safe — we never replace an identifier we
    // can't name-resolve.
    var diags = compiler.Diagnostics.init(allocator);
    defer diags.deinit();
    var arena = compiler.ast.Arena.init(allocator);
    defer arena.deinit();
    const file = compiler.parseSource(allocator, source, &arena, &diags) catch {
        return allocator.dupe(u8, "null");
    };
    var matches = false;
    for (file.decls) |decl| {
        const name: ?[]const u8 = switch (decl) {
            .fn_decl => |fd| fd.sig.name,
            .trait => |t| t.name,
            .owned_struct => |os| os.name,
            .struct_decl => |sd| sd.name,
            .extern_interface => |ei| ei.name,
            .impl_block, .raw => null,
        };
        if (name == null) continue;
        if (std.mem.eql(u8, name.?, ident)) {
            matches = true;
            break;
        }
    }
    if (!matches) return allocator.dupe(u8, "null");

    const new_name_json = try jsonStringify(allocator, new_name);
    defer allocator.free(new_name_json);
    const uri_json = try jsonStringify(allocator, uri);
    defer allocator.free(uri_json);

    var edits = std.ArrayList(u8){};
    defer edits.deinit(allocator);
    try edits.append(allocator, '[');
    var first_hit = true;

    var i: usize = 0;
    while (i < source.len) {
        const c = source[i];
        // Skip over double-quoted string literals.
        if (c == '"') {
            i += 1;
            while (i < source.len) : (i += 1) {
                if (source[i] == '\\' and i + 1 < source.len) {
                    i += 1;
                    continue;
                }
                if (source[i] == '"') {
                    i += 1;
                    break;
                }
            }
            continue;
        }
        // Skip over char literals.
        if (c == '\'') {
            i += 1;
            while (i < source.len and source[i] != '\'') : (i += 1) {
                if (source[i] == '\\' and i + 1 < source.len) i += 1;
            }
            if (i < source.len) i += 1;
            continue;
        }
        // Skip over `//` line comments.
        if (c == '/' and i + 1 < source.len and source[i + 1] == '/') {
            while (i < source.len and source[i] != '\n') i += 1;
            continue;
        }
        if (compiler.token.identStart(c) and (i == 0 or !compiler.token.identCont(source[i - 1]))) {
            var end: usize = i + 1;
            while (end < source.len and compiler.token.identCont(source[end])) end += 1;
            const word = source[i..end];
            if (std.mem.eql(u8, word, ident)) {
                if (!first_hit) try edits.append(allocator, ',');
                first_hit = false;
                try edits.appendSlice(allocator, "{\"range\":");
                const span: compiler.diagnostics.Span = .{ .start = @intCast(i), .end = @intCast(end) };
                try appendRangeJson(&edits, allocator, rangeFromSpan(source, span));
                try edits.appendSlice(allocator, ",\"newText\":");
                try edits.appendSlice(allocator, new_name_json);
                try edits.append(allocator, '}');
            }
            i = end;
            continue;
        }
        i += 1;
    }
    try edits.append(allocator, ']');

    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"changes\":{");
    try out.appendSlice(allocator, uri_json);
    try out.append(allocator, ':');
    try out.appendSlice(allocator, edits.items);
    try out.appendSlice(allocator, "}}");
    return out.toOwnedSlice(allocator);
}

/// One diagnostic that may be turned into a quick-fix CodeAction. Either
/// sourced from the request's `context.diagnostics` (preferred — VS Code
/// echoes them back so we can return the exact same object), or synthesised
/// from the per-uri `HoverDiag` cache for clients (Vim/Emacs/Helix) that
/// don't include `context.diagnostics`.
const CodeActionDiag = struct {
    code: compiler.diagnostics.Code,
    /// Pre-rendered JSON for the `diagnostics[0]` echo. Owned by caller.
    /// `null` means "synthesise from cache" — the JSON gets built lazily
    /// using the cached span + summary text.
    diag_json: ?[]const u8,
    /// LSP range (0-indexed) of the diagnostic. Used both for overlap
    /// testing and for synthesising the diagnostic JSON when none was sent.
    start_line: usize,
    start_col: usize,
    end_line: usize,
    end_col: usize,
    /// Optional `WorkspaceEdit`-style auto-fix attached to this diagnostic.
    /// When non-null, `renderCodeActions` emits a SECOND quick-fix entry
    /// (after the "Explain" one) that ships the edit. Both `title` and
    /// `insert_text` are owned by the caller.
    auto_fix: ?AutoFixEdit = null,
};

/// A single-file, single-edit `WorkspaceEdit`. We deliberately keep the
/// shape minimal — start == end (a pure insertion) at (line, col) of the
/// target document's `uri`. Extending to multi-edit fixes only requires
/// turning `insert_text` + `line` + `col` into a `[]TextEdit`; the renderer
/// already emits the surrounding `WorkspaceEdit` envelope.
const AutoFixEdit = struct {
    title: []const u8,
    uri: []const u8,
    line: u32,
    col: u32,
    insert_text: []const u8,
};

fn onCodeAction(server: *Server, id_text: []const u8, params: ?std.json.Value) !void {
    const allocator = server.allocator;
    const p = params orelse return writeResult(allocator, id_text, "[]");
    if (p != .object) return writeResult(allocator, id_text, "[]");
    const td = p.object.get("textDocument") orelse return writeResult(allocator, id_text, "[]");
    if (td != .object) return writeResult(allocator, id_text, "[]");
    const uri_v = td.object.get("uri") orelse return writeResult(allocator, id_text, "[]");
    if (uri_v != .string) return writeResult(allocator, id_text, "[]");

    const range_v = p.object.get("range") orelse return writeResult(allocator, id_text, "[]");
    const range = parseLspRange(range_v) orelse return writeResult(allocator, id_text, "[]");

    const ctx_diags: ?std.json.Value = blk: {
        const ctx = p.object.get("context") orelse break :blk null;
        if (ctx != .object) break :blk null;
        const dv = ctx.object.get("diagnostics") orelse break :blk null;
        if (dv != .array) break :blk null;
        break :blk dv;
    };

    const result = try buildCodeActions(allocator, server, uri_v.string, range, ctx_diags);
    defer allocator.free(result);
    try writeResult(allocator, id_text, result);
}

fn parseLspRange(v: std.json.Value) ?LspRange {
    if (v != .object) return null;
    const start = v.object.get("start") orelse return null;
    const end = v.object.get("end") orelse return null;
    if (start != .object or end != .object) return null;
    const sl = start.object.get("line") orelse return null;
    const sc = start.object.get("character") orelse return null;
    const el = end.object.get("line") orelse return null;
    const ec = end.object.get("character") orelse return null;
    if (sl != .integer or sc != .integer or el != .integer or ec != .integer) return null;
    if (sl.integer < 0 or sc.integer < 0 or el.integer < 0 or ec.integer < 0) return null;
    return .{
        .start_line = @intCast(sl.integer),
        .start_col = @intCast(sc.integer),
        .end_line = @intCast(el.integer),
        .end_col = @intCast(ec.integer),
    };
}

/// Two LSP line ranges overlap if neither fully precedes the other.
fn lineRangesOverlap(
    a_start: usize,
    a_end: usize,
    b_start: usize,
    b_end: usize,
) bool {
    return !(a_end < b_start or b_end < a_start);
}

/// Build the `result` JSON array (a list of CodeAction objects) for a
/// textDocument/codeAction request.
///
/// Algorithm:
///   - If `ctx_diags` is non-null, prefer it: walk every entry, skip those
///     whose `code` field is missing or doesn't match a known Z#### id, and
///     emit one quick-fix per matching diagnostic. The diagnostic itself is
///     echoed back verbatim under the action's `diagnostics` field.
///   - Otherwise, fall back to the cached `HoverDiag` list for `uri` and
///     synthesise a minimal diagnostic for every cache entry whose line
///     overlaps `range`.
///
/// For each diag we always emit an "Explain Z####" action whose `command`
/// invokes `zigpp.explain` (VS Code implements it client-side; other
/// clients can ignore the command). For Z0010 and Z0040 we ALSO attach a
/// `WorkspaceEdit`-based auto-fix when the cached document text + parser
/// give us enough structure to compute a safe insertion (a `pub fn deinit`
/// stub, or one stub per missing trait method). The auto-fix is rendered
/// as a second quick-fix entry after the explain action.
fn buildCodeActions(
    allocator: std.mem.Allocator,
    server: *Server,
    uri: []const u8,
    range: LspRange,
    ctx_diags: ?std.json.Value,
) ![]u8 {
    var actions = std.ArrayList(CodeActionDiag){};
    defer {
        for (actions.items) |a| {
            if (a.diag_json) |s| allocator.free(s);
            if (a.auto_fix) |fx| {
                allocator.free(fx.title);
                allocator.free(fx.insert_text);
            }
        }
        actions.deinit(allocator);
    }

    if (ctx_diags) |dv| {
        for (dv.array.items) |d| {
            if (d != .object) continue;
            const code_v = d.object.get("code") orelse continue;
            if (code_v != .string) continue;
            const code = compiler.diagnostics.codeFromId(code_v.string) orelse continue;
            const dr = d.object.get("range") orelse continue;
            const drange = parseLspRange(dr) orelse continue;
            if (!lineRangesOverlap(range.start_line, range.end_line, drange.start_line, drange.end_line)) continue;
            const echo = try jsonValueToString(allocator, d);
            try actions.append(allocator, .{
                .code = code,
                .diag_json = echo,
                .start_line = drange.start_line,
                .start_col = drange.start_col,
                .end_line = drange.end_line,
                .end_col = drange.end_col,
            });
        }
    } else if (server.diags.getPtr(uri)) |list| {
        for (list.items) |hd| {
            if (!lineRangesOverlap(range.start_line, range.end_line, hd.line, hd.line)) continue;
            try actions.append(allocator, .{
                .code = hd.code,
                .diag_json = null,
                .start_line = hd.line,
                .start_col = hd.col_start,
                .end_line = hd.line,
                .end_col = hd.col_end,
            });
        }
    }

    // Second pass: try to attach an auto-fix to each Z0010 / Z0040 entry.
    // We need the cached document text to parse into an AST; if there's no
    // cached doc (test fixtures, race with didClose, etc.) just skip — the
    // caller still gets the explain action.
    if (server.docs.get(uri)) |source| {
        for (actions.items) |*a| {
            a.auto_fix = computeAutoFix(allocator, a.code, source, uri, a.start_line) catch null;
        }
    }

    return renderCodeActions(allocator, actions.items);
}

/// Compute a `WorkspaceEdit`-style auto-fix for the given diagnostic, or
/// return `null` when no safe fix is available (unsupported code, parser
/// can't recover the relevant decl, trait not in scope, …).
///
/// Caller owns `result.title` and `result.insert_text`; the LSP-level
/// cleanup happens in the `defer` inside `buildCodeActions`.
fn computeAutoFix(
    allocator: std.mem.Allocator,
    code: compiler.diagnostics.Code,
    source: []const u8,
    uri: []const u8,
    diag_line: usize,
) !?AutoFixEdit {
    return switch (code) {
        .z0010_missing_deinit_on_owned => try buildZ0010AutoFix(allocator, source, uri, diag_line),
        .z0040_impl_missing_method => try buildZ0040AutoFix(allocator, source, uri, diag_line),
        else => null,
    };
}

/// Z0010: locate the `owned struct` whose decl span overlaps the diag line
/// and emit a `pub fn deinit(self: *@This()) void { _ = self; }` stub
/// inserted just before the struct's closing `}`.
///
/// The fix is intentionally minimal: we don't try to deinit fields, walk
/// allocator references, etc. Compiles but leaves the body to the user.
fn buildZ0010AutoFix(
    allocator: std.mem.Allocator,
    source: []const u8,
    uri: []const u8,
    diag_line: usize,
) !?AutoFixEdit {
    var diags = compiler.Diagnostics.init(allocator);
    defer diags.deinit();
    var arena = compiler.ast.Arena.init(allocator);
    defer arena.deinit();
    const file = compiler.parseSource(allocator, source, &arena, &diags) catch return null;

    for (file.decls) |decl| {
        const os = switch (decl) {
            .owned_struct => |o| o,
            else => continue,
        };
        const r = rangeFromSpan(source, os.span);
        if (r.start_line > diag_line or r.end_line < diag_line) continue;
        // Skip if the user already wrote a `deinit` (defensive — sema
        // shouldn't fire Z0010 in that case, but a stale parse could).
        for (os.fns) |fd| {
            if (std.mem.eql(u8, fd.sig.name, "deinit")) return null;
        }
        const insert = try allocator.dupe(
            u8,
            "\n    pub fn deinit(self: *@This()) void {\n        _ = self;\n    }\n",
        );
        errdefer allocator.free(insert);
        const close_pos = brace_pos: {
            // span.end is just past the `}`; the byte at end-1 is the `}`.
            const off: u32 = if (os.span.end == 0) 0 else os.span.end - 1;
            const lc = compiler.locate(source, off);
            break :brace_pos .{
                .line = lc.line - 1,
                .col = if (lc.col == 0) 0 else lc.col - 1,
            };
        };
        const title = try allocator.dupe(
            u8,
            "Auto-fix: add `pub fn deinit(self: *@This()) void` stub",
        );
        return .{
            .title = title,
            .uri = uri,
            .line = close_pos.line,
            .col = close_pos.col,
            .insert_text = insert,
        };
    }
    return null;
}

/// Z0040: locate the `impl Trait for Target` block whose span overlaps the
/// diag line, look up `Trait` in the same file, and emit a `pub fn <name>(...)
/// void { unreachable; }` stub for every trait method missing from the impl.
///
/// We deliberately ignore the trait method's parameter list and return type
/// — copying them verbatim would require re-rendering Param slices, and a
/// `void { unreachable; }` stub is safe + compilable for the user to flesh
/// out. Trait methods present in the impl are skipped; if NONE are missing
/// we return `null` (no fix needed).
fn buildZ0040AutoFix(
    allocator: std.mem.Allocator,
    source: []const u8,
    uri: []const u8,
    diag_line: usize,
) !?AutoFixEdit {
    var diags = compiler.Diagnostics.init(allocator);
    defer diags.deinit();
    var arena = compiler.ast.Arena.init(allocator);
    defer arena.deinit();
    const file = compiler.parseSource(allocator, source, &arena, &diags) catch return null;

    // Locate the impl block whose span covers the diag line.
    var impl: ?compiler.ast.ImplBlock = null;
    for (file.decls) |decl| {
        const ib = switch (decl) {
            .impl_block => |i| i,
            else => continue,
        };
        const r = rangeFromSpan(source, ib.span);
        if (r.start_line <= diag_line and r.end_line >= diag_line) {
            impl = ib;
            break;
        }
    }
    const ib = impl orelse return null;

    // Locate the trait by name in the same file. If the trait isn't there
    // we can't compute the diff — bail out (the user may need Z0001 first).
    var trait: ?compiler.ast.TraitDecl = null;
    for (file.decls) |decl| {
        switch (decl) {
            .trait => |t| if (std.mem.eql(u8, t.name, ib.trait_name)) {
                trait = t;
                break;
            },
            else => {},
        }
    }
    const tr = trait orelse return null;

    // Build the body of the WorkspaceEdit insertion: one stub per missing
    // method. Each stub is indented to match the impl block's typical
    // 4-space style and prefixed with a leading newline so it lands cleanly
    // after the last existing fn.
    var body = std.ArrayList(u8){};
    defer body.deinit(allocator);
    var any_missing = false;
    for (tr.methods) |m| {
        var found = false;
        for (ib.fns) |fd| {
            if (std.mem.eql(u8, fd.sig.name, m.name)) {
                found = true;
                break;
            }
        }
        if (found) continue;
        any_missing = true;
        const stub = try std.fmt.allocPrint(
            allocator,
            "\n    pub fn {s}(self: *@This()) void {{\n        _ = self;\n        unreachable;\n    }}\n",
            .{m.name},
        );
        defer allocator.free(stub);
        try body.appendSlice(allocator, stub);
    }
    if (!any_missing) return null;

    const insert = try body.toOwnedSlice(allocator);
    errdefer allocator.free(insert);

    const close_pos = brace_pos: {
        const off: u32 = if (ib.span.end == 0) 0 else ib.span.end - 1;
        const lc = compiler.locate(source, off);
        break :brace_pos .{
            .line = lc.line - 1,
            .col = if (lc.col == 0) 0 else lc.col - 1,
        };
    };
    const title = try allocator.dupe(u8, "Auto-fix: stub missing trait method(s)");
    return .{
        .title = title,
        .uri = uri,
        .line = close_pos.line,
        .col = close_pos.col,
        .insert_text = insert,
    };
}

/// Serialize a `std.json.Value` back to a compact JSON string. Used to echo
/// a diagnostic verbatim inside a CodeAction's `diagnostics` field.
fn jsonValueToString(allocator: std.mem.Allocator, v: std.json.Value) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, v, .{});
}

/// Render the JSON array body for a list of CodeActions. For each
/// `CodeActionDiag` we emit:
///
///   1. An "Explain" entry whose `command` invokes `zigpp.explain`:
///        {
///          "title": "Explain Z####: <summary>",
///          "kind":  "quickfix",
///          "diagnostics": [<echoed diagnostic>],
///          "command": {
///            "title": "Explain",
///            "command": "zigpp.explain",
///            "arguments": ["Z####"]
///          }
///        }
///
///   2. (Optional, when `a.auto_fix != null`) an "Auto-fix" entry with a
///      `WorkspaceEdit` instead of a `command`:
///        {
///          "title": "<auto_fix.title>",
///          "kind":  "quickfix",
///          "diagnostics": [<echoed diagnostic>],
///          "edit": {
///            "changes": {
///              "<uri>": [
///                { "range": { "start": {...}, "end": {...} },
///                  "newText": "..." }
///              ]
///            }
///          }
///        }
fn renderCodeActions(allocator: std.mem.Allocator, actions: []const CodeActionDiag) ![]u8 {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);
    try out.append(allocator, '[');
    var first = true;
    for (actions) |a| {
        const code_id = a.code.id();
        const summary_text = compiler.diagnostics.summary(a.code);
        const code_id_json = try jsonStringify(allocator, code_id);
        defer allocator.free(code_id_json);

        // Pre-render the diagnostic echo once — used by both the explain
        // entry and the auto-fix entry below.
        var echo_buf = std.ArrayList(u8){};
        defer echo_buf.deinit(allocator);
        if (a.diag_json) |echo| {
            try echo_buf.appendSlice(allocator, echo);
        } else {
            const msg_json = try jsonStringify(allocator, summary_text);
            defer allocator.free(msg_json);
            const synthetic = try std.fmt.allocPrint(
                allocator,
                "{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"severity\":1,\"code\":{s},\"message\":{s}}}",
                .{ a.start_line, a.start_col, a.end_line, a.end_col, code_id_json, msg_json },
            );
            defer allocator.free(synthetic);
            try echo_buf.appendSlice(allocator, synthetic);
        }

        // ---- Explain action ----
        if (!first) try out.append(allocator, ',');
        first = false;

        const title = try std.fmt.allocPrint(allocator, "Explain {s}: {s}", .{ code_id, summary_text });
        defer allocator.free(title);
        const title_json = try jsonStringify(allocator, title);
        defer allocator.free(title_json);

        try out.appendSlice(allocator, "{\"title\":");
        try out.appendSlice(allocator, title_json);
        try out.appendSlice(allocator, ",\"kind\":\"quickfix\",\"diagnostics\":[");
        try out.appendSlice(allocator, echo_buf.items);
        try out.appendSlice(allocator, "],\"command\":{\"title\":\"Explain\",\"command\":\"zigpp.explain\",\"arguments\":[");
        try out.appendSlice(allocator, code_id_json);
        try out.appendSlice(allocator, "]}}");

        // ---- Auto-fix action (optional) ----
        if (a.auto_fix) |fx| {
            try out.append(allocator, ',');

            const fx_title_json = try jsonStringify(allocator, fx.title);
            defer allocator.free(fx_title_json);
            const fx_uri_json = try jsonStringify(allocator, fx.uri);
            defer allocator.free(fx_uri_json);
            const fx_text_json = try jsonStringify(allocator, fx.insert_text);
            defer allocator.free(fx_text_json);

            try out.appendSlice(allocator, "{\"title\":");
            try out.appendSlice(allocator, fx_title_json);
            try out.appendSlice(allocator, ",\"kind\":\"quickfix\",\"diagnostics\":[");
            try out.appendSlice(allocator, echo_buf.items);
            try out.appendSlice(allocator, "],\"edit\":{\"changes\":{");
            try out.appendSlice(allocator, fx_uri_json);
            try out.appendSlice(allocator, ":[{\"range\":");
            const r = try std.fmt.allocPrint(
                allocator,
                "{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}",
                .{ fx.line, fx.col, fx.line, fx.col },
            );
            defer allocator.free(r);
            try out.appendSlice(allocator, r);
            try out.appendSlice(allocator, ",\"newText\":");
            try out.appendSlice(allocator, fx_text_json);
            try out.appendSlice(allocator, "}]}}}");
        }
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

/// LSP semantic-tokens type indices. Order MUST match the legend advertised
/// in the `initialize` response — VS Code keys off the legend order, not the
/// names. See SemanticTokenType in
/// https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#semanticTokenTypes.
const SemTokType = enum(u32) {
    keyword = 0,
    string = 1,
    number = 2,
    comment = 3,
    function = 4,
    interface = 5,
    @"struct" = 6,
    variable = 7,
};

/// Bitset of semantic-token modifiers. Only `declaration` is used in this
/// MVP — extending requires bumping the legend order in `initialize`.
const SemTokMod = struct {
    pub const declaration: u32 = 1 << 0;
};

/// Absolute (pre-delta-encoding) semantic-token tuple. We collect these in
/// source order, then convert to LSP's `[deltaLine, deltaStart, length, type,
/// mod]` quintuples just before emitting.
const AbsToken = struct {
    line: u32,
    char: u32,
    length: u32,
    token_type: u32,
    token_mod: u32,
};

fn onSemanticTokensFull(server: *Server, id_text: []const u8, params: ?std.json.Value) !void {
    const allocator = server.allocator;
    const p = params orelse return writeResult(allocator, id_text, "{\"data\":[]}");
    if (p != .object) return writeResult(allocator, id_text, "{\"data\":[]}");
    const td = p.object.get("textDocument") orelse return writeResult(allocator, id_text, "{\"data\":[]}");
    if (td != .object) return writeResult(allocator, id_text, "{\"data\":[]}");
    const uri_v = td.object.get("uri") orelse return writeResult(allocator, id_text, "{\"data\":[]}");
    if (uri_v != .string) return writeResult(allocator, id_text, "{\"data\":[]}");

    const text = server.docs.get(uri_v.string) orelse {
        try writeResult(allocator, id_text, "{\"data\":[]}");
        return;
    };

    // Compute the u32 token array, then both (a) cache it for subsequent
    // `full/delta` requests and (b) stringify it for the response. A scratch
    // copy of the JSON is freed inline; the cache owns its u32 slice.
    const u32_data = buildSemanticTokensU32(allocator, text) catch {
        try writeResult(allocator, id_text, "{\"data\":[]}");
        return;
    };
    const result_id = try cacheSemanticTokens(server, uri_v.string, u32_data);

    const json_data = try u32ArrayToJson(allocator, u32_data);
    defer allocator.free(json_data);

    const result = try std.fmt.allocPrint(
        allocator,
        "{{\"resultId\":\"{d}\",\"data\":{s}}}",
        .{ result_id, json_data },
    );
    defer allocator.free(result);
    try writeResult(allocator, id_text, result);
}

/// Handle `textDocument/semanticTokens/range`: tokenise the whole document
/// (so identifier classification still sees out-of-range top-level decls) but
/// emit only those tokens whose line falls within `[range.start.line,
/// range.end.line]`. The first emitted token's `deltaLine` is rebased to be
/// relative to the start of the document (line 0), exactly like the full
/// response — VS Code applies the deltas as-is. See LSP 3.17 spec
/// `textDocument/semanticTokens/range`.
fn onSemanticTokensRange(server: *Server, id_text: []const u8, params: ?std.json.Value) !void {
    const allocator = server.allocator;
    const p = params orelse return writeResult(allocator, id_text, "{\"data\":[]}");
    if (p != .object) return writeResult(allocator, id_text, "{\"data\":[]}");
    const td = p.object.get("textDocument") orelse return writeResult(allocator, id_text, "{\"data\":[]}");
    if (td != .object) return writeResult(allocator, id_text, "{\"data\":[]}");
    const uri_v = td.object.get("uri") orelse return writeResult(allocator, id_text, "{\"data\":[]}");
    if (uri_v != .string) return writeResult(allocator, id_text, "{\"data\":[]}");

    const range_v = p.object.get("range") orelse return writeResult(allocator, id_text, "{\"data\":[]}");
    const range = parseLspRange(range_v) orelse return writeResult(allocator, id_text, "{\"data\":[]}");

    const text = server.docs.get(uri_v.string) orelse {
        try writeResult(allocator, id_text, "{\"data\":[]}");
        return;
    };

    const data = buildSemanticTokensRange(allocator, text, range.start_line, range.end_line) catch {
        try writeResult(allocator, id_text, "{\"data\":[]}");
        return;
    };
    defer allocator.free(data);

    const result = try std.fmt.allocPrint(allocator, "{{\"data\":{s}}}", .{data});
    defer allocator.free(result);
    try writeResult(allocator, id_text, result);
}

/// Handle `textDocument/semanticTokens/full/delta`. If the cached `result_id`
/// matches `previousResultId`, compute new tokens and emit a single
/// `{start, deleteCount, data}` edit covering the suffix that differs from
/// the cached array. Otherwise (no cache, mismatched id, parse failure) fall
/// back to the full `{resultId, data}` response — this is explicitly allowed
/// by the LSP spec. See LSP 3.17 spec
/// `textDocument/semanticTokens/full/delta`.
fn onSemanticTokensFullDelta(server: *Server, id_text: []const u8, params: ?std.json.Value) !void {
    const allocator = server.allocator;
    const p = params orelse return writeResult(allocator, id_text, "{\"data\":[]}");
    if (p != .object) return writeResult(allocator, id_text, "{\"data\":[]}");
    const td = p.object.get("textDocument") orelse return writeResult(allocator, id_text, "{\"data\":[]}");
    if (td != .object) return writeResult(allocator, id_text, "{\"data\":[]}");
    const uri_v = td.object.get("uri") orelse return writeResult(allocator, id_text, "{\"data\":[]}");
    if (uri_v != .string) return writeResult(allocator, id_text, "{\"data\":[]}");

    const prev_v = p.object.get("previousResultId") orelse return writeResult(allocator, id_text, "{\"data\":[]}");
    if (prev_v != .string) return writeResult(allocator, id_text, "{\"data\":[]}");
    const prev_id = std.fmt.parseInt(usize, prev_v.string, 10) catch 0;

    const text = server.docs.get(uri_v.string) orelse {
        try writeResult(allocator, id_text, "{\"data\":[]}");
        return;
    };

    const result_json = buildSemanticTokensDelta(allocator, server, uri_v.string, text, prev_id) catch {
        try writeResult(allocator, id_text, "{\"data\":[]}");
        return;
    };
    defer allocator.free(result_json);
    try writeResult(allocator, id_text, result_json);
}

/// Classify a top-level decl name for semantic-tokens highlighting. We only
/// distinguish the four buckets the legend exposes; everything else (locals,
/// parameters, unknown idents) falls through to `variable` at the call site.
fn declTokenType(decl: compiler.ast.TopDecl) ?SemTokType {
    return switch (decl) {
        .fn_decl => .function,
        .trait, .extern_interface => .interface,
        .owned_struct, .struct_decl => .@"struct",
        .impl_block, .raw => null,
    };
}

/// Step 1+2 of the semantic-tokens pipeline: collect absolute (line, char,
/// length, type, mod) tuples in source order. Caller owns the returned slice.
/// Returns an empty slice when the lexer fails — we'd rather drop highlighting
/// than drop the LSP connection mid-edit.
///
/// Algorithm:
///  1. Build a name -> token-type map from the parsed top-level decls so each
///     identifier reference can be classified the same way as its declaration.
///     Local variables, parameters, and unknown idents all fall through to
///     `variable`.
///  2. Lex the source. For every token, emit one `AbsToken` whose type is:
///       - `keyword` for any `kw_*` kind
///       - `string` for `string_literal`
///       - `number` for `int_literal` / `float_literal`
///       - `comment` for `line_comment` / `doc_comment`
///       - the map-classified type for `ident` (or `variable` when missing)
///       - skipped otherwise
///     Identifiers immediately following `fn`, `trait`, `struct`, `owned`, or
///     `extern interface` are flagged with the `declaration` modifier.
fn collectSemanticTokens(allocator: std.mem.Allocator, source: []const u8) ![]AbsToken {
    // Step 1: classify top-level decl names. The map borrows identifier slices
    // straight from `source` — same lifetime as the caller-owned text.
    var name_kind = std.StringHashMap(SemTokType).init(allocator);
    defer name_kind.deinit();

    {
        var diags = compiler.Diagnostics.init(allocator);
        defer diags.deinit();
        var arena = compiler.ast.Arena.init(allocator);
        defer arena.deinit();
        if (compiler.parseSource(allocator, source, &arena, &diags)) |file| {
            for (file.decls) |decl| {
                const t = declTokenType(decl) orelse continue;
                const name: []const u8 = switch (decl) {
                    .fn_decl => |fd| fd.sig.name,
                    .trait => |tr| tr.name,
                    .owned_struct => |os| os.name,
                    .struct_decl => |sd| sd.name,
                    .extern_interface => |ei| ei.name,
                    .impl_block, .raw => unreachable,
                };
                _ = try name_kind.put(name, t);
            }
        } else |_| {}
    }

    // Step 2: lex + classify into absolute tuples in source order.
    var lex_diags = compiler.Diagnostics.init(allocator);
    defer lex_diags.deinit();
    var lx = compiler.token.Lexer.init(source, &lex_diags);
    var toks = lx.tokenizeAll(allocator) catch {
        return allocator.alloc(AbsToken, 0);
    };
    defer toks.deinit(allocator);

    var abs = std.ArrayList(AbsToken){};
    defer abs.deinit(allocator);

    // Sliding window over the previous non-comment kind, used to decide
    // whether the current ident is a *declaration* site (e.g. the `helper` in
    // `fn helper`). `extern interface Name` is a two-keyword prefix, so we
    // also remember whether the previous-previous token was `extern`.
    var prev_kind: ?compiler.token.TokenKind = null;
    var prev_prev_kind: ?compiler.token.TokenKind = null;

    for (toks.items) |t| {
        if (t.kind == .eof) break;
        if (t.span.end <= t.span.start) continue;

        const tt: ?SemTokType = blk: {
            switch (t.kind) {
                .string_literal => break :blk .string,
                .int_literal, .float_literal => break :blk .number,
                .line_comment, .doc_comment => break :blk .comment,
                .ident => {
                    const slice = t.slice(source);
                    if (name_kind.get(slice)) |mapped| break :blk mapped;
                    break :blk .variable;
                },
                else => {
                    if (@intFromEnum(t.kind) >= @intFromEnum(compiler.token.TokenKind.kw_const) and
                        @intFromEnum(t.kind) <= @intFromEnum(compiler.token.TokenKind.kw_interface))
                    {
                        break :blk .keyword;
                    }
                    break :blk null;
                },
            }
        };

        if (tt) |type_val| {
            var mod: u32 = 0;
            if (t.kind == .ident) {
                const is_decl_site = blk: {
                    if (prev_kind) |pk| switch (pk) {
                        .kw_fn, .kw_trait, .kw_struct, .kw_owned => break :blk true,
                        .kw_interface => {
                            // Only `extern interface Name` declares a new
                            // interface; bare `interface` is treated as a
                            // keyword-flagged context (e.g. `impl Trait for X`).
                            if (prev_prev_kind) |ppk| {
                                if (ppk == .kw_extern) break :blk true;
                            }
                            break :blk false;
                        },
                        else => break :blk false,
                    };
                    break :blk false;
                };
                if (is_decl_site) mod |= SemTokMod.declaration;
            }

            const lc = compiler.locate(source, t.span.start);
            // Multi-line tokens (e.g. multi-line strings, `\\`-folded
            // literals) would break LSP's "no token spans multiple lines"
            // invariant. Drop those; the TextMate fallback covers them.
            const lc_end = compiler.locate(source, t.span.end);
            if (lc_end.line != lc.line) {
                prev_prev_kind = prev_kind;
                prev_kind = t.kind;
                continue;
            }

            try abs.append(allocator, .{
                .line = lc.line - 1,
                .char = lc.col - 1,
                .length = t.span.end - t.span.start,
                .token_type = @intFromEnum(type_val),
                .token_mod = mod,
            });
        }

        // Track only "real" tokens for the decl-site lookahead — comments and
        // whitespace shouldn't reset the `fn helper` adjacency.
        switch (t.kind) {
            .line_comment, .doc_comment => {},
            else => {
                prev_prev_kind = prev_kind;
                prev_kind = t.kind;
            },
        }
    }

    return abs.toOwnedSlice(allocator);
}

/// Step 3 of the semantic-tokens pipeline: encode an absolute-token slice as
/// LSP-relative `(deltaLine, deltaStart, length, type, mod)` quintuples in a
/// flat `u32` slice. Caller owns the returned slice. Deltas are computed
/// against the start of the document (line 0, column 0) — the same baseline
/// the LSP spec uses for the first token of either `full` or `range` results.
fn encodeSemanticTokensU32(
    allocator: std.mem.Allocator,
    abs: []const AbsToken,
) ![]u32 {
    var out = try allocator.alloc(u32, abs.len * 5);
    errdefer allocator.free(out);
    var prev_line: u32 = 0;
    var prev_char: u32 = 0;
    for (abs, 0..) |a, i| {
        const delta_line = a.line - prev_line;
        const delta_start = if (delta_line == 0) a.char - prev_char else a.char;
        out[i * 5 + 0] = delta_line;
        out[i * 5 + 1] = delta_start;
        out[i * 5 + 2] = a.length;
        out[i * 5 + 3] = a.token_type;
        out[i * 5 + 4] = a.token_mod;
        prev_line = a.line;
        prev_char = a.char;
    }
    return out;
}

/// Stringify a flat `u32` semantic-tokens array as the JSON literal LSP
/// expects (e.g. `[1,2,3,4,5,...]`). Caller owns the returned slice.
fn u32ArrayToJson(allocator: std.mem.Allocator, data: []const u32) ![]u8 {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);
    try out.append(allocator, '[');
    for (data, 0..) |v, i| {
        if (i != 0) try out.append(allocator, ',');
        const buf = try std.fmt.allocPrint(allocator, "{d}", .{v});
        defer allocator.free(buf);
        try out.appendSlice(allocator, buf);
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

/// Build the LSP `data` JSON array (as an owned slice, e.g. `[1,2,3,4,5,...]`)
/// for a `textDocument/semanticTokens/full` response. Returns `[]` when
/// allocation of the absolute-token list fails — partial syntax mid-edit is
/// the common case in an LSP, and we'd rather drop highlighting than drop the
/// connection.
fn buildSemanticTokens(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const data = try buildSemanticTokensU32(allocator, source);
    defer allocator.free(data);
    return u32ArrayToJson(allocator, data);
}

/// Same as `buildSemanticTokens` but returns the flat `u32` array directly,
/// which is what the cache + delta path needs. Caller owns the returned slice.
fn buildSemanticTokensU32(allocator: std.mem.Allocator, source: []const u8) ![]u32 {
    const abs = try collectSemanticTokens(allocator, source);
    defer allocator.free(abs);
    return encodeSemanticTokensU32(allocator, abs);
}

/// Build the LSP `data` JSON array for a `textDocument/semanticTokens/range`
/// response. Tokenises the entire `source` (so identifier classification still
/// sees out-of-range top-level decls), then keeps only the tuples whose line
/// is in `[start_line, end_line]` and re-encodes them with deltas relative to
/// the start of the document. Returns `[]` when the filtered set is empty.
fn buildSemanticTokensRange(
    allocator: std.mem.Allocator,
    source: []const u8,
    start_line: u32,
    end_line: u32,
) ![]u8 {
    const abs = try collectSemanticTokens(allocator, source);
    defer allocator.free(abs);

    // Filter in place into a fresh buffer; preserves source order (the
    // collector already emits tokens in lexical order, so a single linear
    // sweep is enough).
    var filtered = std.ArrayList(AbsToken){};
    defer filtered.deinit(allocator);
    for (abs) |t| {
        if (t.line < start_line) continue;
        if (t.line > end_line) continue;
        try filtered.append(allocator, t);
    }

    const u32_data = try encodeSemanticTokensU32(allocator, filtered.items);
    defer allocator.free(u32_data);
    return u32ArrayToJson(allocator, u32_data);
}

/// Insert / refresh the cached u32 semantic-tokens array for `uri` and return
/// the new `result_id`. Frees the previous cache entry's `data` slice. The
/// cache takes ownership of `new_data` (caller must NOT free it on success).
fn cacheSemanticTokens(server: *Server, uri: []const u8, new_data: []u32) !usize {
    const id = server.semantic_tokens_next_id;
    server.semantic_tokens_next_id += 1;
    if (server.semantic_tokens.fetchRemove(uri)) |kv| {
        server.allocator.free(kv.key);
        server.allocator.free(kv.value.data);
    }
    const key = try server.allocator.dupe(u8, uri);
    try server.semantic_tokens.put(key, .{ .result_id = id, .data = new_data });
    return id;
}

/// Build the JSON response body for `textDocument/semanticTokens/full/delta`.
///
/// If the cached result_id matches `prev_id`, returns
/// `{"resultId":"<id>","edits":[<single edit>]}` where the edit is a single
/// `{start, deleteCount, data}` covering the suffix that differs from the
/// cached array (longest common prefix / suffix trim). The LSP spec
/// explicitly allows a single broad edit instead of per-token diffs.
///
/// Otherwise — no cache, mismatched id, parse failure — returns the full
/// `{"resultId":"<id>","data":[...]}` shape, which the spec lists as a valid
/// fallback. Always refreshes the cache with the freshly computed tokens.
fn buildSemanticTokensDelta(
    allocator: std.mem.Allocator,
    server: *Server,
    uri: []const u8,
    source: []const u8,
    prev_id: usize,
) ![]u8 {
    const new_data = try buildSemanticTokensU32(allocator, source);
    // We need a stable view of the OLD data (the LCP/LCS scan) before the
    // cache write blows it away. Snapshot the pointer + length first; the
    // cache write below frees the old slice, so we must finish all reads of
    // `old` before that point.
    var old_copy: ?[]u32 = null;
    defer if (old_copy) |o| allocator.free(o);

    if (server.semantic_tokens.get(uri)) |cached| {
        if (cached.result_id == prev_id) {
            const dup = try allocator.alloc(u32, cached.data.len);
            @memcpy(dup, cached.data);
            old_copy = dup;
        }
    }

    if (old_copy == null) {
        // Full fallback (no cache or mismatched id). Refresh the cache and
        // emit the full `{resultId, data}` shape.
        const json_data = try u32ArrayToJson(allocator, new_data);
        defer allocator.free(json_data);
        const new_id = try cacheSemanticTokens(server, uri, new_data);
        return std.fmt.allocPrint(
            allocator,
            "{{\"resultId\":\"{d}\",\"data\":{s}}}",
            .{ new_id, json_data },
        );
    }

    // Single-range diff: longest common prefix + longest common suffix.
    const old = old_copy.?;
    var prefix: usize = 0;
    const min_len = @min(old.len, new_data.len);
    while (prefix < min_len and old[prefix] == new_data[prefix]) : (prefix += 1) {}

    var suffix: usize = 0;
    while (suffix < (min_len - prefix) and
        old[old.len - 1 - suffix] == new_data[new_data.len - 1 - suffix]) : (suffix += 1)
    {}

    const delete_count = old.len - prefix - suffix;
    const insert = new_data[prefix .. new_data.len - suffix];

    // Pre-stringify the edit body BEFORE the cache write so we don't need to
    // hold any references to `new_data` across `cacheSemanticTokens` (which
    // takes ownership).
    const body = if (delete_count == 0 and insert.len == 0)
        try allocator.dupe(u8, "[]")
    else blk: {
        const insert_json = try u32ArrayToJson(allocator, insert);
        defer allocator.free(insert_json);
        break :blk try std.fmt.allocPrint(
            allocator,
            "[{{\"start\":{d},\"deleteCount\":{d},\"data\":{s}}}]",
            .{ prefix, delete_count, insert_json },
        );
    };
    defer allocator.free(body);

    const new_id = try cacheSemanticTokens(server, uri, new_data);
    return std.fmt.allocPrint(
        allocator,
        "{{\"resultId\":\"{d}\",\"edits\":{s}}}",
        .{ new_id, body },
    );
}

fn onWorkspaceSymbol(server: *Server, id_text: []const u8, params: ?std.json.Value) !void {
    var query: []const u8 = "";
    if (params) |p| {
        if (p == .object) {
            if (p.object.get("query")) |q| {
                if (q == .string) query = q.string;
            }
        }
    }
    const allocator = server.allocator;
    const result = try buildWorkspaceSymbols(allocator, &server.docs, query);
    defer allocator.free(result);
    try writeResult(server.allocator, id_text, result);
}

/// Build the `result` JSON array for a workspace/symbol request: a
/// `SymbolInformation[]` derived from every cached open document. `query`
/// is a case-insensitive substring filter over the symbol name; an empty
/// string emits all symbols. Returns "[]" when no docs are cached.
fn buildWorkspaceSymbols(
    allocator: std.mem.Allocator,
    docs: *const DocStore,
    query: []const u8,
) ![]u8 {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);
    try out.append(allocator, '[');
    var first = true;

    var it = docs.iterator();
    while (it.next()) |entry| {
        const uri = entry.key_ptr.*;
        const source = entry.value_ptr.*;
        try appendWorkspaceSymbolsForDoc(allocator, &out, &first, uri, source, query);
    }

    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

fn appendWorkspaceSymbolsForDoc(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    first: *bool,
    uri: []const u8,
    source: []const u8,
    query: []const u8,
) !void {
    var diags = compiler.Diagnostics.init(allocator);
    defer diags.deinit();
    var arena = compiler.ast.Arena.init(allocator);
    defer arena.deinit();
    const file = compiler.parseSource(allocator, source, &arena, &diags) catch return;

    const uri_json = try jsonStringify(allocator, uri);
    defer allocator.free(uri_json);

    for (file.decls) |decl| {
        const item: ?struct { name: []const u8, kind: SymbolKind, owns_name: bool } = switch (decl) {
            .fn_decl => |fd| .{ .name = fd.sig.name, .kind = .function, .owns_name = false },
            .trait => |t| .{ .name = t.name, .kind = .interface, .owns_name = false },
            .owned_struct => |os| .{ .name = os.name, .kind = .@"struct", .owns_name = false },
            .struct_decl => |sd| .{ .name = sd.name, .kind = .@"struct", .owns_name = false },
            .extern_interface => |ei| .{ .name = ei.name, .kind = .module, .owns_name = false },
            .impl_block => |ib| blk: {
                const label = try std.fmt.allocPrint(allocator, "impl {s} for {s}", .{ ib.trait_name, ib.target_type });
                break :blk .{ .name = label, .kind = .class, .owns_name = true };
            },
            .raw => null,
        };
        if (item == null) continue;
        const it_val = item.?;
        defer if (it_val.owns_name) allocator.free(it_val.name);

        if (!matchesQuery(it_val.name, query)) continue;

        if (!first.*) try out.append(allocator, ',');
        first.* = false;

        const name_json = try jsonStringify(allocator, it_val.name);
        defer allocator.free(name_json);

        try out.appendSlice(allocator, "{\"name\":");
        try out.appendSlice(allocator, name_json);
        const kind_buf = try std.fmt.allocPrint(allocator, ",\"kind\":{d},\"location\":{{\"uri\":", .{@intFromEnum(it_val.kind)});
        defer allocator.free(kind_buf);
        try out.appendSlice(allocator, kind_buf);
        try out.appendSlice(allocator, uri_json);
        try out.appendSlice(allocator, ",\"range\":");
        try appendRangeJson(out, allocator, rangeFromSpan(source, decl.span()));
        try out.appendSlice(allocator, "},\"containerName\":\"\"}");
    }
}

/// Case-insensitive substring match. Empty `query` matches everything.
fn matchesQuery(name: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    if (query.len > name.len) return false;
    var i: usize = 0;
    const last = name.len - query.len;
    while (i <= last) : (i += 1) {
        var j: usize = 0;
        while (j < query.len) : (j += 1) {
            if (std.ascii.toLower(name[i + j]) != std.ascii.toLower(query[j])) break;
        }
        if (j == query.len) return true;
    }
    return false;
}

fn countLines(s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| if (c == '\n') {
        n += 1;
    };
    return n + 1;
}

/// Allocates a JSON-quoted version of `s`, including surrounding quotes.
fn lowerAscii(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

fn jsonStringify(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);
    try out.append(allocator, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(allocator, "\\\""),
        '\\' => try out.appendSlice(allocator, "\\\\"),
        '\n' => try out.appendSlice(allocator, "\\n"),
        '\r' => try out.appendSlice(allocator, "\\r"),
        '\t' => try out.appendSlice(allocator, "\\t"),
        0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
            var buf: [8]u8 = undefined;
            const slice = try std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c});
            try out.appendSlice(allocator, slice);
        },
        else => try out.append(allocator, c),
    };
    try out.append(allocator, '"');
    return out.toOwnedSlice(allocator);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const exit = try runServer(allocator);
    std.process.exit(@intFromEnum(exit));
}

test "jsonStringify escapes quotes and backslashes" {
    const a = std.testing.allocator;
    const out = try jsonStringify(a, "hi \"there\"\n\\");
    defer a.free(out);
    try std.testing.expectEqualStrings("\"hi \\\"there\\\"\\n\\\\\"", out);
}

test "countLines counts newlines + 1" {
    try std.testing.expectEqual(@as(usize, 1), countLines(""));
    try std.testing.expectEqual(@as(usize, 3), countLines("a\nb\nc"));
}

test "buildDocumentSymbols emits one symbol per top-level decl" {
    const a = std.testing.allocator;
    const src =
        \\trait Writer { fn write(self, bytes: []const u8) !usize; }
        \\struct Counter {
        \\    n: usize,
        \\    pub fn bump(self: *Counter) void { self.n += 1; }
        \\}
        \\fn helper(x: usize) usize { return x + 1; }
    ;
    const out = try buildDocumentSymbols(a, src);
    defer a.free(out);

    // Three top-level decls -> three symbols. We don't pin the exact JSON
    // shape (children/range numbers shift if the parser ever tweaks spans),
    // we just sanity-check the names + kinds.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"Writer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"kind\":11") != null); // interface
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"Counter\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"kind\":23") != null); // struct
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"helper\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"kind\":12") != null); // function
    // Method child of the struct.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"bump\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"kind\":6") != null); // method
}

test "buildDocumentSymbols labels impl blocks and skips raw zig" {
    const a = std.testing.allocator;
    const src =
        \\const std = @import("std");
        \\trait Writer { fn write(self, bytes: []const u8) !usize; }
        \\struct FW { n: usize, pub fn write(self: *FW, bytes: []const u8) !usize { _ = self; return bytes.len; } }
        \\impl Writer for FW { pub fn write(self: *FW, bytes: []const u8) !usize { _ = self; return bytes.len; } }
    ;
    const out = try buildDocumentSymbols(a, src);
    defer a.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"impl Writer for FW\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"kind\":5") != null); // class for impl
    // The leading `const std = @import("std");` falls into RawZig and must
    // not produce a symbol entry.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"std\"") == null);
}

test "buildDocumentSymbols returns [] on empty source" {
    const a = std.testing.allocator;
    const out = try buildDocumentSymbols(a, "");
    defer a.free(out);
    try std.testing.expectEqualStrings("[]", out);
}

test "buildCompletionResult emits keywords and top-level idents" {
    const a = std.testing.allocator;
    const src =
        \\trait Writer { fn write(self, bytes: []const u8) !usize; }
        \\struct Counter {
        \\    n: usize,
        \\    pub fn bump(self: *Counter) void { self.n += 1; }
        \\}
        \\fn helper(x: usize) usize { return x + 1; }
    ;
    const out = try buildCompletionResult(a, src);
    defer a.free(out);

    // Result envelope.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"isIncomplete\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"items\":[") != null);

    // A handful of keywords sourced from compiler/token.zig.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"label\":\"fn\",\"kind\":14") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"label\":\"trait\",\"kind\":14") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"label\":\"effects\",\"kind\":14") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"label\":\"impl\",\"kind\":14") != null);

    // Identifiers from the parsed top-level decls.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"label\":\"Writer\",\"kind\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"label\":\"Counter\",\"kind\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"label\":\"helper\",\"kind\":3") != null);
}

test "buildCompletionResult falls back to keywords on missing doc" {
    const a = std.testing.allocator;
    const out = try buildCompletionResult(a, null);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"label\":\"fn\",\"kind\":14") != null);
    // No identifier items should be present (kind 3 / kind 7).
    try std.testing.expect(std.mem.indexOf(u8, out, "\"kind\":3") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"kind\":7") == null);
}

test "buildCompletionResult dedupes label collisions between idents and keywords" {
    const a = std.testing.allocator;
    // A user-defined top-level fn whose name collides with a keyword would
    // otherwise produce two items with the same label. dedup picks the
    // keyword (which we emit first).
    const src = "fn fn_helper() void {}";
    const out = try buildCompletionResult(a, src);
    defer a.free(out);
    // Only one entry for the keyword `fn`.
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, out, idx, "\"label\":\"fn\"")) |pos| {
        count += 1;
        idx = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
    // The user's fn_helper still shows up.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"label\":\"fn_helper\",\"kind\":3") != null);
}

test "buildDefinition resolves a same-file fn name" {
    const a = std.testing.allocator;
    const src =
        \\fn helper(x: usize) usize { return x + 1; }
        \\pub fn main() void {
        \\    _ = helper(2);
        \\}
    ;
    // Position lands on `helper` at line 2 (0-indexed), character 9.
    const out = try buildDefinition(a, src, "file:///x.zpp", 2, 9);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"uri\":\"file:///x.zpp\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"range\":") != null);
    // Range must point back to line 0 where `fn helper` is declared.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"start\":{\"line\":0") != null);
}

test "buildDefinition returns null when ident matches no decl" {
    const a = std.testing.allocator;
    const src = "fn helper() void { _ = unknown_name; }\n";
    // Position lands inside `unknown_name`.
    const out = try buildDefinition(a, src, "file:///x.zpp", 0, 25);
    defer a.free(out);
    try std.testing.expectEqualStrings("null", out);
}

test "buildDefinition returns null when off identifier" {
    const a = std.testing.allocator;
    const src = "fn helper() void {}\n";
    // Position is on the space between `fn` and `helper`.
    const out = try buildDefinition(a, src, "file:///x.zpp", 0, 2);
    defer a.free(out);
    try std.testing.expectEqualStrings("null", out);
}

test "buildReferences returns 2 occurrences of an ident (decl + use)" {
    const a = std.testing.allocator;
    const src =
        \\fn helper(x: usize) usize { return x + 1; }
        \\pub fn main() void {
        \\    _ = helper(2);
        \\}
    ;
    // Cursor on `helper` at the use site (line 2, column 9).
    const out = try buildReferences(a, src, "file:///x.zpp", 2, 9, true);
    defer a.free(out);
    // Two ranges -> exactly two `"uri":` entries.
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, out, idx, "\"uri\":")) |pos| {
        count += 1;
        idx = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    // First hit must be on line 0 (the declaration); second on line 2.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"start\":{\"line\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"start\":{\"line\":2") != null);
}

test "buildReferences with includeDeclaration=false drops the decl" {
    const a = std.testing.allocator;
    const src =
        \\fn helper(x: usize) usize { return x + 1; }
        \\pub fn main() void {
        \\    _ = helper(2);
        \\}
    ;
    const out = try buildReferences(a, src, "file:///x.zpp", 2, 9, false);
    defer a.free(out);
    // One Location -> one `"uri":` entry.
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, out, idx, "\"uri\":")) |pos| {
        count += 1;
        idx = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
    // The remaining hit is the use site on line 2.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"start\":{\"line\":2") != null);
    // The decl on line 0 must NOT appear.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"start\":{\"line\":0") == null);
}

test "buildReferences skips occurrences inside string literals" {
    const a = std.testing.allocator;
    // The literal "helper" inside the string MUST NOT count as a reference.
    const src =
        \\fn helper() void {
        \\    _ = "helper inside a string";
        \\    _ = helper;
        \\}
    ;
    // Cursor on `helper` decl (line 0, column 4).
    const out = try buildReferences(a, src, "file:///x.zpp", 0, 4, true);
    defer a.free(out);
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, out, idx, "\"uri\":")) |pos| {
        count += 1;
        idx = pos + 1;
    }
    // Decl on line 0 + use on line 2 = 2; the in-string occurrence is skipped.
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "buildReferences returns [] when off identifier" {
    const a = std.testing.allocator;
    const src = "fn helper() void {}\n";
    // Position on the space between `fn` and `helper`.
    const out = try buildReferences(a, src, "file:///x.zpp", 0, 2, true);
    defer a.free(out);
    try std.testing.expectEqualStrings("[]", out);
}

test "buildWorkspaceSymbols with empty query returns all top-level decls" {
    const a = std.testing.allocator;
    const src =
        \\trait Writer { fn write(self, bytes: []const u8) !usize; }
        \\struct Counter {
        \\    n: usize,
        \\    pub fn bump(self: *Counter) void { self.n += 1; }
        \\}
        \\fn helper(x: usize) usize { return x + 1; }
        \\impl Writer for Counter { pub fn write(self: *Counter, bytes: []const u8) !usize { _ = self; return bytes.len; } }
    ;
    var docs = DocStore.init(a);
    defer docs.deinit();
    try docs.put("file:///x.zpp", @constCast(src[0..]));

    const out = try buildWorkspaceSymbols(a, &docs, "");
    defer a.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"Writer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"Counter\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"helper\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"impl Writer for Counter\"") != null);
    // Each entry has a `containerName` field per LSP SymbolInformation.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"containerName\":\"\"") != null);
    // Each entry has a `location` with the doc URI.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"uri\":\"file:///x.zpp\"") != null);
}

test "buildWorkspaceSymbols with non-empty query filters case-insensitively" {
    const a = std.testing.allocator;
    const src =
        \\trait Writer { fn write(self, bytes: []const u8) !usize; }
        \\struct Counter { n: usize, pub fn bump(self: *Counter) void { self.n += 1; } }
        \\fn helper(x: usize) usize { return x + 1; }
    ;
    var docs = DocStore.init(a);
    defer docs.deinit();
    try docs.put("file:///x.zpp", @constCast(src[0..]));

    // Case-insensitive substring match on `count` should match `Counter`
    // and nothing else.
    const out = try buildWorkspaceSymbols(a, &docs, "count");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"Counter\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"Writer\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"helper\"") == null);
}

test "buildWorkspaceSymbols returns [] when no docs cached" {
    const a = std.testing.allocator;
    var docs = DocStore.init(a);
    defer docs.deinit();
    const out = try buildWorkspaceSymbols(a, &docs, "");
    defer a.free(out);
    try std.testing.expectEqualStrings("[]", out);
}

test "buildPrepareRename returns range + placeholder for a fn name" {
    const a = std.testing.allocator;
    const src =
        \\fn helper(x: usize) usize { return x + 1; }
        \\pub fn main() void {
        \\    _ = helper(2);
        \\}
    ;
    // Cursor on `helper` declaration (line 0, column 4).
    const out = try buildPrepareRename(a, src, 0, 4);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"placeholder\":\"helper\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"range\":") != null);
    // The range must point at the identifier (line 0, character 3 -> 9).
    try std.testing.expect(std.mem.indexOf(u8, out, "\"start\":{\"line\":0,\"character\":3}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"end\":{\"line\":0,\"character\":9}") != null);
}

test "buildPrepareRename returns null for a parameter name" {
    const a = std.testing.allocator;
    const src =
        \\fn helper(my_param: usize) usize { return my_param + 1; }
    ;
    // Cursor on `my_param` parameter (line 0, column 12).
    const out = try buildPrepareRename(a, src, 0, 12);
    defer a.free(out);
    try std.testing.expectEqualStrings("null", out);
}

test "buildPrepareRename returns null when off identifier" {
    const a = std.testing.allocator;
    const src = "fn helper() void {}\n";
    // Position is on the space between `fn` and `helper`.
    const out = try buildPrepareRename(a, src, 0, 2);
    defer a.free(out);
    try std.testing.expectEqualStrings("null", out);
}

test "buildRename produces a WorkspaceEdit covering all occurrences" {
    const a = std.testing.allocator;
    const src =
        \\fn helper(x: usize) usize { return x + 1; }
        \\pub fn main() void {
        \\    _ = helper(2);
        \\}
    ;
    // Cursor on `helper` use site (line 2, column 9).
    const out = try buildRename(a, src, "file:///x.zpp", 2, 9, "renamed");
    defer a.free(out);
    // Wrapper shape.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"changes\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"file:///x.zpp\":[") != null);
    // Two TextEdits -> two `"newText":"renamed"` entries.
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, out, idx, "\"newText\":\"renamed\"")) |pos| {
        count += 1;
        idx = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    // One edit on line 0 (decl), one on line 2 (use).
    try std.testing.expect(std.mem.indexOf(u8, out, "\"start\":{\"line\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"start\":{\"line\":2") != null);
}

test "buildRename rejects an invalid newName" {
    const a = std.testing.allocator;
    const src = "fn helper() void {}\n";
    const out_digit = try buildRename(a, src, "file:///x.zpp", 0, 4, "123abc");
    defer a.free(out_digit);
    try std.testing.expectEqualStrings("null", out_digit);
    const out_empty = try buildRename(a, src, "file:///x.zpp", 0, 4, "");
    defer a.free(out_empty);
    try std.testing.expectEqualStrings("null", out_empty);
    const out_punct = try buildRename(a, src, "file:///x.zpp", 0, 4, "no-dash");
    defer a.free(out_punct);
    try std.testing.expectEqualStrings("null", out_punct);
}

test "buildRename does not replace occurrences inside string literals" {
    const a = std.testing.allocator;
    const src =
        \\fn helper() void {
        \\    _ = "helper inside a string";
        \\    _ = helper;
        \\}
    ;
    // Cursor on `helper` decl (line 0, column 4).
    const out = try buildRename(a, src, "file:///x.zpp", 0, 4, "renamed");
    defer a.free(out);
    // Only the decl on line 0 and the use on line 2 should be replaced -> 2 newText entries.
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, out, idx, "\"newText\":\"renamed\"")) |pos| {
        count += 1;
        idx = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    // The original literal text "helper" must stay present in the source —
    // the rename output never contains the string-literal location of the
    // word as an edit. Sanity-check no edit landed on line 1 (the string).
    try std.testing.expect(std.mem.indexOf(u8, out, "\"start\":{\"line\":1") == null);
}

test "buildRename returns null when off a renameable decl" {
    const a = std.testing.allocator;
    const src = "fn helper() void { _ = unknown_name; }\n";
    // Cursor inside `unknown_name` — not a top-level decl -> null.
    const out = try buildRename(a, src, "file:///x.zpp", 0, 25, "renamed");
    defer a.free(out);
    try std.testing.expectEqualStrings("null", out);
}

/// Test helper: seed `server.diags` for `uri` with a list of `HoverDiag`.
/// Mirrors the bookkeeping of `publishDiagnostics` so the test only has to
/// describe the cache state, not how it gets populated.
fn seedHoverDiags(server: *Server, uri: []const u8, items: []const HoverDiag) !void {
    var list: std.ArrayList(HoverDiag) = .{};
    errdefer list.deinit(server.allocator);
    for (items) |it| try list.append(server.allocator, it);
    const key = try server.allocator.dupe(u8, uri);
    try server.diags.put(key, list);
}

test "buildCodeActions emits one quickfix per matching cached diag" {
    const a = std.testing.allocator;
    var server = Server.init(a);
    defer server.deinit();

    // Two diagnostics on lines 0 and 5; the request range covers only line 0.
    try seedHoverDiags(&server, "file:///x.zpp", &.{
        .{ .line = 0, .col_start = 0, .col_end = 10, .code = .z0010_missing_deinit_on_owned },
        .{ .line = 5, .col_start = 0, .col_end = 10, .code = .z0001_unknown_trait },
    });

    const range: LspRange = .{ .start_line = 0, .start_col = 0, .end_line = 0, .end_col = 0 };
    const out = try buildCodeActions(a, &server, "file:///x.zpp", range, null);
    defer a.free(out);

    // One CodeAction with the Z0010 title format. Line-5 diag (Z0001) must
    // not appear because the request range doesn't cross it.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"kind\":\"quickfix\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"title\":\"Explain Z0010:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Z0001") == null);
    // Command echoes the Z#### id for the client to feed back into
    // `zigpp.explain`.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"command\":\"zigpp.explain\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"arguments\":[\"Z0010\"]") != null);
    // Exactly one entry -> exactly one `"kind":"quickfix"`.
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, out, idx, "\"kind\":\"quickfix\"")) |pos| {
        count += 1;
        idx = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "buildCodeActions returns [] when range overlaps no cached diag" {
    const a = std.testing.allocator;
    var server = Server.init(a);
    defer server.deinit();

    try seedHoverDiags(&server, "file:///x.zpp", &.{
        .{ .line = 0, .col_start = 0, .col_end = 10, .code = .z0010_missing_deinit_on_owned },
    });

    // Request on line 7 — well past the only cached diag on line 0.
    const range: LspRange = .{ .start_line = 7, .start_col = 0, .end_line = 7, .end_col = 0 };
    const out = try buildCodeActions(a, &server, "file:///x.zpp", range, null);
    defer a.free(out);
    try std.testing.expectEqualStrings("[]", out);
}

test "buildCodeActions title includes both Z#### and the summary text" {
    const a = std.testing.allocator;
    var server = Server.init(a);
    defer server.deinit();

    try seedHoverDiags(&server, "file:///x.zpp", &.{
        .{ .line = 0, .col_start = 0, .col_end = 10, .code = .z0010_missing_deinit_on_owned },
    });

    const range: LspRange = .{ .start_line = 0, .start_col = 0, .end_line = 0, .end_col = 0 };
    const out = try buildCodeActions(a, &server, "file:///x.zpp", range, null);
    defer a.free(out);

    // Z#### prefix.
    try std.testing.expect(std.mem.indexOf(u8, out, "Explain Z0010:") != null);
    // Summary text from compiler.diagnostics.summary(...) — for Z0010 the
    // first line of explain() is "Z0010: owned struct missing deinit", so
    // summary() returns "owned struct missing deinit".
    const expected_summary = compiler.diagnostics.summary(.z0010_missing_deinit_on_owned);
    try std.testing.expect(std.mem.indexOf(u8, out, expected_summary) != null);
}

test "buildCodeActions prefers ctx_diags echo when supplied" {
    const a = std.testing.allocator;
    var server = Server.init(a);
    defer server.deinit();
    // Cache deliberately empty — when ctx_diags is supplied we must use it
    // rather than fall back to the cache.

    // Build a fake LSP `context.diagnostics` array containing one Z0010.
    const fake_params =
        \\{
        \\  "diagnostics": [
        \\    {
        \\      "range": {
        \\        "start": {"line": 2, "character": 4},
        \\        "end":   {"line": 2, "character": 8}
        \\      },
        \\      "severity": 1,
        \\      "code": "Z0010",
        \\      "message": "owned struct missing deinit",
        \\      "source": "zpp"
        \\    }
        \\  ]
        \\}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, a, fake_params, .{});
    defer parsed.deinit();
    const ctx_diags = parsed.value.object.get("diagnostics").?;

    const range: LspRange = .{ .start_line = 2, .start_col = 0, .end_line = 2, .end_col = 20 };
    const out = try buildCodeActions(a, &server, "file:///x.zpp", range, ctx_diags);
    defer a.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "\"title\":\"Explain Z0010:") != null);
    // The echoed diagnostic must include the original `source` field — proof
    // that we echoed it verbatim rather than synthesised our own object.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"source\":\"zpp\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"arguments\":[\"Z0010\"]") != null);
}

test "buildCodeActions skips ctx diagnostics with unknown codes" {
    const a = std.testing.allocator;
    var server = Server.init(a);
    defer server.deinit();

    // ZF999 is not a real diagnostic code — should be silently dropped.
    const fake_params =
        \\{
        \\  "diagnostics": [
        \\    {
        \\      "range": {"start":{"line":0,"character":0},"end":{"line":0,"character":1}},
        \\      "code": "ZF999",
        \\      "message": "bogus"
        \\    }
        \\  ]
        \\}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, a, fake_params, .{});
    defer parsed.deinit();
    const ctx_diags = parsed.value.object.get("diagnostics").?;

    const range: LspRange = .{ .start_line = 0, .start_col = 0, .end_line = 0, .end_col = 1 };
    const out = try buildCodeActions(a, &server, "file:///x.zpp", range, ctx_diags);
    defer a.free(out);
    try std.testing.expectEqualStrings("[]", out);
}

/// Test helper: seed `server.docs` for `uri` with `text`. Mirrors what
/// `textDocument/didOpen` does so auto-fix tests can describe the cached
/// source without going through the JSON-RPC layer.
fn seedDoc(server: *Server, uri: []const u8, text: []const u8) !void {
    const key = try server.allocator.dupe(u8, uri);
    errdefer server.allocator.free(key);
    const val = try server.allocator.dupe(u8, text);
    try server.docs.put(key, val);
}

test "buildCodeActions Z0010 emits both Explain and Auto-fix actions" {
    const a = std.testing.allocator;
    var server = Server.init(a);
    defer server.deinit();

    // The cached source is what the auto-fix path parses — it must contain
    // a real `owned struct` so `buildZ0010AutoFix` can locate the close
    // brace and emit a TextEdit.
    const src =
        \\owned struct Buffer {
        \\    data: []u8,
        \\}
    ;
    try seedDoc(&server, "file:///x.zpp", src);
    try seedHoverDiags(&server, "file:///x.zpp", &.{
        .{ .line = 0, .col_start = 0, .col_end = 19, .code = .z0010_missing_deinit_on_owned },
    });

    const range: LspRange = .{ .start_line = 0, .start_col = 0, .end_line = 0, .end_col = 0 };
    const out = try buildCodeActions(a, &server, "file:///x.zpp", range, null);
    defer a.free(out);

    // Both the Explain entry and the Auto-fix entry must appear.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"title\":\"Explain Z0010:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Auto-fix: add `pub fn deinit") != null);
    // Two quickfix entries -> exactly two `"kind":"quickfix"` markers.
    var qf_count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, out, idx, "\"kind\":\"quickfix\"")) |pos| {
        qf_count += 1;
        idx = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 2), qf_count);
    // Auto-fix carries a WorkspaceEdit with the deinit stub text.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"edit\":{\"changes\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn deinit") != null);
}

test "buildCodeActions Z0040 auto-fix stubs every missing trait method" {
    const a = std.testing.allocator;
    var server = Server.init(a);
    defer server.deinit();

    // Trait declares two methods; impl block only defines `greet` -> `wave`
    // is missing and must show up as a stub in the WorkspaceEdit.
    const src =
        \\trait Greeter {
        \\    fn greet(self) void;
        \\    fn wave(self) void;
        \\}
        \\impl Greeter for Friendly {
        \\    pub fn greet(self) void {}
        \\}
    ;
    try seedDoc(&server, "file:///x.zpp", src);
    try seedHoverDiags(&server, "file:///x.zpp", &.{
        .{ .line = 4, .col_start = 0, .col_end = 25, .code = .z0040_impl_missing_method },
    });

    const range: LspRange = .{ .start_line = 4, .start_col = 0, .end_line = 4, .end_col = 0 };
    const out = try buildCodeActions(a, &server, "file:///x.zpp", range, null);
    defer a.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "\"title\":\"Explain Z0040:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Auto-fix: stub missing trait method(s)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"edit\":{\"changes\":") != null);
    // The stub for the only missing method (`wave`) must be present, and
    // the already-implemented `greet` must NOT generate a duplicate stub.
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn wave") != null);
    // `greet` appears in the diag echo / synthetic message, so we instead
    // check for the stub-specific opener; only one stub line exists.
    var wave_count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, out, idx, "pub fn wave")) |pos| {
        wave_count += 1;
        idx = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), wave_count);
    // Two quickfix entries (Explain + Auto-fix).
    var qf_count: usize = 0;
    idx = 0;
    while (std.mem.indexOfPos(u8, out, idx, "\"kind\":\"quickfix\"")) |pos| {
        qf_count += 1;
        idx = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 2), qf_count);
}

test "buildCodeActions emits ONLY Explain action for non-autofixable codes" {
    const a = std.testing.allocator;
    var server = Server.init(a);
    defer server.deinit();

    // Z0030 (effect violation) has no auto-fix path — only the Explain
    // entry should appear, even though the doc text is cached.
    const src =
        \\fn pure() void effects(.noalloc) {
        \\    _ = std.heap.page_allocator.alloc(u8, 1) catch unreachable;
        \\}
    ;
    try seedDoc(&server, "file:///x.zpp", src);
    try seedHoverDiags(&server, "file:///x.zpp", &.{
        .{ .line = 1, .col_start = 8, .col_end = 40, .code = .z0030_effect_violation },
    });

    const range: LspRange = .{ .start_line = 1, .start_col = 0, .end_line = 1, .end_col = 0 };
    const out = try buildCodeActions(a, &server, "file:///x.zpp", range, null);
    defer a.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "\"title\":\"Explain Z0030:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Auto-fix:") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"edit\":") == null);
    // Exactly one quickfix entry.
    var qf_count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, out, idx, "\"kind\":\"quickfix\"")) |pos| {
        qf_count += 1;
        idx = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), qf_count);
}

/// Parse a `buildSemanticTokens` JSON array (e.g. `[1,2,3,4,5,...]`) back
/// into a flat `[]u32`. Caller owns the returned slice. Test-only — it does
/// no validation beyond what `parseInt` already enforces.
fn parseSemTokData(allocator: std.mem.Allocator, json: []const u8) ![]u32 {
    var out = std.ArrayList(u32){};
    defer out.deinit(allocator);
    if (json.len < 2) return out.toOwnedSlice(allocator);
    // Strip the surrounding `[` / `]`.
    const inner = json[1 .. json.len - 1];
    if (inner.len == 0) return out.toOwnedSlice(allocator);
    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |chunk| {
        const trimmed = std.mem.trim(u8, chunk, " ");
        if (trimmed.len == 0) continue;
        const v = try std.fmt.parseInt(u32, trimmed, 10);
        try out.append(allocator, v);
    }
    return out.toOwnedSlice(allocator);
}

test "buildSemanticTokens emits a u32 array with quintuple cardinality" {
    const a = std.testing.allocator;
    const src =
        \\fn helper(x: usize) usize { return x + 1; }
    ;
    const json = try buildSemanticTokens(a, src);
    defer a.free(json);
    const data = try parseSemTokData(a, json);
    defer a.free(data);
    try std.testing.expect(data.len > 0);
    // LSP requires the data array to come in groups of 5: `(deltaLine,
    // deltaStart, length, type, mod)`.
    try std.testing.expectEqual(@as(usize, 0), data.len % 5);
}

test "buildSemanticTokens first token deltaLine matches first source token" {
    const a = std.testing.allocator;
    // Lead with two blank lines so the first real token is on line 2.
    const src =
        \\
        \\
        \\fn helper() void {}
    ;
    const json = try buildSemanticTokens(a, src);
    defer a.free(json);
    const data = try parseSemTokData(a, json);
    defer a.free(data);
    try std.testing.expect(data.len >= 5);
    // Source-relative: first token on line 2 (0-indexed) -> deltaLine = 2.
    try std.testing.expectEqual(@as(u32, 2), data[0]);
}

test "buildSemanticTokens classifies `fn` as keyword (type 0)" {
    const a = std.testing.allocator;
    const src = "fn helper() void {}\n";
    const json = try buildSemanticTokens(a, src);
    defer a.free(json);
    const data = try parseSemTokData(a, json);
    defer a.free(data);
    try std.testing.expect(data.len >= 5);
    // First token is `fn`, length 2, type=keyword(0), mod=0.
    try std.testing.expectEqual(@as(u32, 0), data[0]); // deltaLine
    try std.testing.expectEqual(@as(u32, 0), data[1]); // deltaStart
    try std.testing.expectEqual(@as(u32, 2), data[2]); // length
    try std.testing.expectEqual(@as(u32, @intFromEnum(SemTokType.keyword)), data[3]);
    try std.testing.expectEqual(@as(u32, 0), data[4]);
}

test "buildSemanticTokens flags fn name with declaration modifier" {
    const a = std.testing.allocator;
    const src = "fn helper(x: usize) usize { return x + 1; }\n";
    const json = try buildSemanticTokens(a, src);
    defer a.free(json);
    const data = try parseSemTokData(a, json);
    defer a.free(data);

    // The tokens after `fn` are `helper`, `(`, `x`, `:`, `usize`, `)`,
    // `usize`, `{`, `return`, `x`, `+`, `1`, `;`, `}`. Only those classified
    // by our legend are emitted (keywords, idents, numbers). Walk the
    // quintuples and verify:
    //   - the first ident emitted ("helper") has type=function, mod=declaration
    //   - subsequent occurrences of "x" have type=variable, mod=0
    try std.testing.expect(data.len >= 10);
    // Token #2 (after `fn`) should be `helper` — function, declaration.
    try std.testing.expectEqual(@as(u32, @intFromEnum(SemTokType.function)), data[5 + 3]);
    try std.testing.expectEqual(@as(u32, 1), data[5 + 4]); // declaration bit
}

test "buildSemanticTokens marks reused fn name as function without declaration" {
    const a = std.testing.allocator;
    const src =
        \\fn helper(x: usize) usize { return x + 1; }
        \\pub fn main() void { _ = helper(2); }
    ;
    const json = try buildSemanticTokens(a, src);
    defer a.free(json);
    const data = try parseSemTokData(a, json);
    defer a.free(data);

    // Walk all quintuples and find every `helper` occurrence by re-scanning
    // the source for its absolute (line, char) position, then verifying the
    // matching tuple's type/mod. The reused `helper` must be type=function,
    // mod=0 — declaration only fires at the decl site (the one immediately
    // after `fn`).
    var saw_decl = false;
    var saw_use = false;
    var line: u32 = 0;
    var char: u32 = 0;
    var i: usize = 0;
    while (i + 5 <= data.len) : (i += 5) {
        const dl = data[i];
        const ds = data[i + 1];
        const len = data[i + 2];
        const ty = data[i + 3];
        const mod = data[i + 4];
        if (dl != 0) {
            line += dl;
            char = ds;
        } else {
            char += ds;
        }
        // Compute the byte offset for (line, char) the same way LSP would.
        const off = posToOffset(src, line, char) orelse continue;
        if (off + len > src.len) continue;
        const slice = src[off .. off + len];
        if (!std.mem.eql(u8, slice, "helper")) continue;
        try std.testing.expectEqual(@as(u32, @intFromEnum(SemTokType.function)), ty);
        if (mod & 1 != 0) saw_decl = true else saw_use = true;
    }
    try std.testing.expect(saw_decl);
    try std.testing.expect(saw_use);
}

test "buildSemanticTokens returns [] on empty source" {
    const a = std.testing.allocator;
    const out = try buildSemanticTokens(a, "");
    defer a.free(out);
    try std.testing.expectEqualStrings("[]", out);
}
