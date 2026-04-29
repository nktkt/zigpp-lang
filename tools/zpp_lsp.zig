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

const Server = struct {
    allocator: std.mem.Allocator,
    docs: DocStore,
    diags: HoverStore,
    initialized: bool = false,
    shutdown_requested: bool = false,

    fn init(allocator: std.mem.Allocator) Server {
        return .{
            .allocator = allocator,
            .docs = DocStore.init(allocator),
            .diags = HoverStore.init(allocator),
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
            \\{"capabilities":{"textDocumentSync":1,"documentFormattingProvider":true,"hoverProvider":true,"documentSymbolProvider":true,"definitionProvider":true,"referencesProvider":true,"workspaceSymbolProvider":true,"completionProvider":{"triggerCharacters":[".",":"]},"diagnosticProvider":{"interFileDependencies":false,"workspaceDiagnostics":false}},"serverInfo":{"name":"zpp-lsp","version":"0.5.0"}}
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
