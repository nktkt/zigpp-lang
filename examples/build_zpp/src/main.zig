const std = @import("std");

pub fn main() !void {
    var stdout_buf: [256]u8 = undefined;
    const slice = try std.fmt.bufPrint(&stdout_buf, "hello from build.zpp demo\n", .{});
    try std.fs.File.stdout().writeAll(slice);
}
