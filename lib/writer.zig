//! Writer trait — a write-bytes sink with three concrete implementations
//! (stdout, arbitrary file, buffered).
//!
//! This module is the `Writer` slot of Phase 2's "stdlib trait" exit
//! criterion (see ROADMAP). The shape mirrors `std.fs.File`'s write/flush
//! pair so wrapping a real file is a one-liner, but the public surface is
//! type-erased through `dyn.Dyn` so library code can sink into anything
//! without becoming generic over the concrete sink type.
//!
//! Allocation policy. Zig++ is a no-hidden-alloc language, so this
//! module performs zero heap allocations. `print(fmt, args)` uses a
//! fixed 1024-byte stack buffer and streams formatted output in chunks
//! to the underlying `write` call — no heap, no comptime quota inflation.

const std = @import("std");
const traits = @import("traits.zig");
const dyn = @import("dyn.zig");

/// All Writer methods propagate the same error set as `std.fs.File.write`.
/// This keeps `FileWriter` zero-conversion and is a strict superset of the
/// errors a `BufferedWriter` or `StdoutWriter` actually emits.
pub const WriterError = std.fs.File.WriteError;

/// Vtable for the Writer trait.
///
/// `write` returns the number of bytes written; partial writes are legal,
/// and callers that want all-or-nothing behaviour should use `writeAll`.
/// `flush` is a hint to drain any buffered state — for unbuffered sinks
/// (stdout, raw file) it is a no-op.
pub const Writer_VTable = struct {
    write: *const fn (ptr: *anyopaque, bytes: []const u8) WriterError!usize,
    flush: *const fn (ptr: *anyopaque) WriterError!void,
};

/// Type-erased Writer fat pointer. Constructed via `Dyn.from(T, &impl, .{...})`
/// or by handing a pre-built vtable to `dyn.into`.
pub const Writer = dyn.Dyn(Writer_VTable);

/// Write every byte in `bytes`, looping over the underlying `write` until
/// either the slice is fully consumed or `write` returns an error. A zero-
/// length write is treated as `error.BrokenPipe` to avoid silent infinite
/// loops on pathological sinks.
pub fn writeAll(self: Writer, bytes: []const u8) WriterError!void {
    var i: usize = 0;
    while (i < bytes.len) {
        const n = try self.vtable.write(self.ptr, bytes[i..]);
        if (n == 0) return error.BrokenPipe;
        i += n;
    }
}

/// Flush any buffered state. Convenience wrapper over the vtable slot.
pub fn flush(self: Writer) WriterError!void {
    return self.vtable.flush(self.ptr);
}

/// Print formatted text through the trait.
///
/// Allocation policy: a 1024-byte buffer is allocated on the caller's stack
/// and used as the staging area for `std.Io.Writer`'s formatter. When the
/// formatter fills the buffer it drains the contents to `self.write` and
/// continues, so arbitrarily long formatted output is supported with O(1)
/// stack — no heap allocation occurs at any point.
pub fn print(self: Writer, comptime fmt: []const u8, args: anytype) WriterError!void {
    var stage: [1024]u8 = undefined;
    var adapter = TraitWriter.init(self, &stage);
    adapter.io.print(fmt, args) catch |e| switch (e) {
        error.WriteFailed => return adapter.last_err orelse error.BrokenPipe,
    };
    adapter.io.flush() catch |e| switch (e) {
        error.WriteFailed => return adapter.last_err orelse error.BrokenPipe,
    };
}

/// `std.Io.Writer` adapter that drains its staging buffer through a
/// `Writer` trait object. `last_err` captures the original `WriterError`
/// from the trait so we can rethrow it after `std.Io.Writer` flattens it
/// to `error.WriteFailed`.
const TraitWriter = struct {
    io: std.Io.Writer,
    sink: Writer,
    last_err: ?WriterError = null,

    fn init(sink: Writer, buffer: []u8) TraitWriter {
        return .{
            .io = .{
                .vtable = &.{ .drain = drain, .flush = drainFlush },
                .buffer = buffer,
            },
            .sink = sink,
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *TraitWriter = @fieldParentPtr("io", w);
        // 1) Drain the staging buffer first.
        if (w.end != 0) {
            writeAll(self.sink, w.buffer[0..w.end]) catch |e| {
                self.last_err = e;
                return error.WriteFailed;
            };
            w.end = 0;
        }
        // 2) Then each `data[i]` in order, with `data[last]` repeated `splat` times.
        var consumed: usize = 0;
        if (data.len == 0) return 0;
        for (data[0 .. data.len - 1]) |chunk| {
            writeAll(self.sink, chunk) catch |e| {
                self.last_err = e;
                return error.WriteFailed;
            };
            consumed += chunk.len;
        }
        const tail = data[data.len - 1];
        var i: usize = 0;
        while (i < splat) : (i += 1) {
            writeAll(self.sink, tail) catch |e| {
                self.last_err = e;
                return error.WriteFailed;
            };
            consumed += tail.len;
        }
        return consumed;
    }

    fn drainFlush(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *TraitWriter = @fieldParentPtr("io", w);
        if (w.end != 0) {
            writeAll(self.sink, w.buffer[0..w.end]) catch |e| {
                self.last_err = e;
                return error.WriteFailed;
            };
            w.end = 0;
        }
    }
};

// -- StdoutWriter --------------------------------------------------------

/// Wrapper over the process's standard output. Carries no state beyond the
/// fd-equivalent `std.fs.File`, so `init` is `const`-folding.
pub const StdoutWriter = struct {
    file: std.fs.File,

    pub fn init() StdoutWriter {
        return .{ .file = std.fs.File.stdout() };
    }

    pub fn write(self: *StdoutWriter, bytes: []const u8) WriterError!usize {
        return self.file.write(bytes);
    }

    pub fn flush(self: *StdoutWriter) WriterError!void {
        _ = self;
    }

    /// Build a `Writer` fat pointer from a `*StdoutWriter`. The vtable is
    /// materialized once at comptime and stored as a `static const`.
    pub fn writer(self: *StdoutWriter) Writer {
        return dyn.fromImpl(Writer_VTable, StdoutWriter, self, .{
            .{ "write", StdoutWriter.write },
            .{ "flush", StdoutWriter.flush },
        });
    }
};

/// Convenience: `zpp.writer.stdout()` returns a fresh `StdoutWriter`.
pub fn stdout() StdoutWriter {
    return StdoutWriter.init();
}

// -- FileWriter ----------------------------------------------------------

/// Wraps an arbitrary `std.fs.File`. Ownership of the file stays with the
/// caller — `FileWriter` does not close it.
pub const FileWriter = struct {
    file: std.fs.File,

    pub fn init(file: std.fs.File) FileWriter {
        return .{ .file = file };
    }

    pub fn write(self: *FileWriter, bytes: []const u8) WriterError!usize {
        return self.file.write(bytes);
    }

    /// `flush` on a regular file is a no-op: `write` is unbuffered at this
    /// layer and the kernel handles its own page cache. Callers that need
    /// fsync semantics should reach for `self.file.sync()` directly.
    pub fn flush(self: *FileWriter) WriterError!void {
        _ = self;
    }

    pub fn writer(self: *FileWriter) Writer {
        return dyn.fromImpl(Writer_VTable, FileWriter, self, .{
            .{ "write", FileWriter.write },
            .{ "flush", FileWriter.flush },
        });
    }
};

// -- BufferedWriter ------------------------------------------------------

/// Wraps any inner `Writer` with a stack-resident byte buffer of
/// `BufSize` bytes. Small writes are coalesced; once the buffer is full
/// (or `flush` is called) it is forwarded to the inner writer in one go.
///
/// Allocation policy: the buffer is a fixed-size array stored inline in
/// the struct, so callers control exactly where it lives — no allocator
/// is consulted.
pub fn BufferedWriter(comptime BufSize: comptime_int) type {
    return struct {
        const Self = @This();

        inner: Writer,
        buf: [BufSize]u8 = undefined,
        len: usize = 0,

        pub fn init(inner: Writer) Self {
            return .{ .inner = inner };
        }

        pub fn write(self: *Self, bytes: []const u8) WriterError!usize {
            // Path 1: incoming chunk fits in remaining buffer — coalesce.
            if (self.len + bytes.len <= BufSize) {
                @memcpy(self.buf[self.len..][0..bytes.len], bytes);
                self.len += bytes.len;
                return bytes.len;
            }
            // Path 2: incoming chunk spans the buffer. Flush the existing
            // buffered prefix, then either inline the new bytes (if they
            // fit on their own) or forward them straight through.
            try self.flush();
            if (bytes.len <= BufSize) {
                @memcpy(self.buf[0..bytes.len], bytes);
                self.len = bytes.len;
                return bytes.len;
            }
            return self.inner.vtable.write(self.inner.ptr, bytes);
        }

        pub fn flush(self: *Self) WriterError!void {
            if (self.len != 0) {
                try writeAll(self.inner, self.buf[0..self.len]);
                self.len = 0;
            }
            try self.inner.vtable.flush(self.inner.ptr);
        }

        pub fn writer(self: *Self) Writer {
            return dyn.fromImpl(Writer_VTable, Self, self, .{
                .{ "write", Self.write },
                .{ "flush", Self.flush },
            });
        }
    };
}

// -- tests ---------------------------------------------------------------

test "Writer dispatches through vtable to FileWriter (write + read back)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file_name = "writer_dispatch.txt";
    const file = try tmp.dir.createFile(file_name, .{ .read = true });
    defer file.close();

    var fw = FileWriter.init(file);
    const w = fw.writer();
    try writeAll(w, "hello, ");
    try writeAll(w, "writer trait!");
    try flush(w);

    const expected = "hello, writer trait!";
    try file.seekTo(0);
    var buf: [64]u8 = undefined;
    const n = try file.readAll(&buf);
    try std.testing.expectEqualStrings(expected, buf[0..n]);
}

test "BufferedWriter coalesces small writes and flushes on overflow" {
    // Inner sink that records every call to `write`, so we can verify
    // exactly how many flushes the buffered wrapper triggered.
    const Recorder = struct {
        bytes: std.ArrayList(u8) = .{},
        call_count: usize = 0,

        fn write(self: *@This(), data: []const u8) WriterError!usize {
            self.call_count += 1;
            self.bytes.appendSlice(std.testing.allocator, data) catch return error.SystemResources;
            return data.len;
        }
        fn flush(self: *@This()) WriterError!void {
            _ = self;
        }
        fn writerOf(self: *@This()) Writer {
            return dyn.fromImpl(Writer_VTable, @This(), self, .{
                .{ "write", @This().write },
                .{ "flush", @This().flush },
            });
        }
    };

    var rec = Recorder{};
    defer rec.bytes.deinit(std.testing.allocator);
    const inner = rec.writerOf();

    var bw = BufferedWriter(8).init(inner);
    const w = bw.writer();

    // Four 2-byte writes (8 bytes total) should fit entirely in the buffer;
    // no inner write yet.
    try writeAll(w, "ab");
    try writeAll(w, "cd");
    try writeAll(w, "ef");
    try writeAll(w, "gh");
    try std.testing.expectEqual(@as(usize, 0), rec.call_count);

    // The next byte spills: the existing 8 bytes are flushed, the new
    // byte is parked in the freshly emptied buffer.
    try writeAll(w, "i");
    try std.testing.expectEqual(@as(usize, 1), rec.call_count);
    try std.testing.expectEqualStrings("abcdefgh", rec.bytes.items);

    // Explicit flush ships the trailing 'i'.
    try flush(w);
    try std.testing.expectEqual(@as(usize, 2), rec.call_count);
    try std.testing.expectEqualStrings("abcdefghi", rec.bytes.items);
}

test "BufferedWriter explicit flush forces inner write" {
    const Recorder = struct {
        bytes: std.ArrayList(u8) = .{},
        flush_count: usize = 0,

        fn write(self: *@This(), data: []const u8) WriterError!usize {
            self.bytes.appendSlice(std.testing.allocator, data) catch return error.SystemResources;
            return data.len;
        }
        fn flush(self: *@This()) WriterError!void {
            self.flush_count += 1;
        }
        fn writerOf(self: *@This()) Writer {
            return dyn.fromImpl(Writer_VTable, @This(), self, .{
                .{ "write", @This().write },
                .{ "flush", @This().flush },
            });
        }
    };

    var rec = Recorder{};
    defer rec.bytes.deinit(std.testing.allocator);

    var bw = BufferedWriter(64).init(rec.writerOf());
    const w = bw.writer();

    try writeAll(w, "buffered");
    try std.testing.expectEqualStrings("", rec.bytes.items);

    try flush(w);
    try std.testing.expectEqualStrings("buffered", rec.bytes.items);
    // Inner flush was forwarded as part of BufferedWriter.flush.
    try std.testing.expectEqual(@as(usize, 1), rec.flush_count);
}

test "print(fmt, args) routes through write" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("print.txt", .{ .read = true });
    defer file.close();

    var fw = FileWriter.init(file);
    const w = fw.writer();
    try print(w, "value={d}, name={s}\n", .{ 42, "zigpp" });

    try file.seekTo(0);
    var buf: [128]u8 = undefined;
    const n = try file.readAll(&buf);
    try std.testing.expectEqualStrings("value=42, name=zigpp\n", buf[0..n]);
}

test "print streams output longer than the staging buffer" {
    // Capture into an in-memory recorder so we don't depend on disk size.
    const Recorder = struct {
        bytes: std.ArrayList(u8) = .{},

        fn write(self: *@This(), data: []const u8) WriterError!usize {
            self.bytes.appendSlice(std.testing.allocator, data) catch return error.SystemResources;
            return data.len;
        }
        fn flush(self: *@This()) WriterError!void {
            _ = self;
        }
        fn writerOf(self: *@This()) Writer {
            return dyn.fromImpl(Writer_VTable, @This(), self, .{
                .{ "write", @This().write },
                .{ "flush", @This().flush },
            });
        }
    };

    var rec = Recorder{};
    defer rec.bytes.deinit(std.testing.allocator);
    const w = rec.writerOf();

    // 1500 'x's exceeds the 1024-byte staging buffer, exercising the
    // streaming-drain path inside `print`.
    try print(w, "{s}", .{"x" ** 1500});
    try std.testing.expectEqual(@as(usize, 1500), rec.bytes.items.len);
    for (rec.bytes.items) |c| try std.testing.expectEqual(@as(u8, 'x'), c);
}
