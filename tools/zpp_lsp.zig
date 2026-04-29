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
            \\{"capabilities":{"textDocumentSync":1,"documentFormattingProvider":true,"hoverProvider":true,"diagnosticProvider":{"interFileDependencies":false,"workspaceDiagnostics":false}},"serverInfo":{"name":"zpp-lsp","version":"0.1.0"}}
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
