//! S1-T6 criterion 1: the non-`--update` `searchd index` summary line names
//! `budget_exhausted`, between `unreadable=` and `documents=`.
const std = @import("std");
const cli = @import("cli.zig");
const indexer = @import("indexer.zig");

test "index summary line prints budget_exhausted (S1-T6 criterion 1)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;

    // Three 41-byte files and a 50-byte budget: one fits, two are left over.
    const body = "123456789\n123456789\n123456789\n123456789\na";
    try tmp.dir.createDir(io, "in", .default_dir);
    var in_dir = try tmp.dir.openDir(io, "in", .{});
    defer in_dir.close(io);
    try in_dir.writeFile(io, .{ .sub_path = "a.md", .data = body });
    try in_dir.writeFile(io, .{ .sub_path = "b.md", .data = body });
    try in_dir.writeFile(io, .{ .sub_path = "c.md", .data = body });

    const in_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/in", .{tmp.sub_path});
    defer allocator.free(in_path);
    const out_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/out", .{tmp.sub_path});
    defer allocator.free(out_path);

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try cli.runIndex(io, allocator, in_path, out_path, .{ .caps = indexer.Caps{ .max_total_bytes = 50 } }, &output.writer);

    try std.testing.expect(std.mem.indexOf(
        u8,
        output.written(),
        "files_indexed=1 too_large=0 unreadable=0 budget_exhausted=2 documents=",
    ) != null);
}

// S1-T7 criterion 2: bad byte counts fail cleanly (one line naming the option
// and the value, `error.InvalidArgument` for the caller to turn into exit 1).
fn expectBadByteCount(option: []const u8, value: []const u8) !void {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectError(error.InvalidArgument, cli.parseByteCount(option, value, &output.writer));
    const text = output.written();
    try std.testing.expect(std.mem.indexOf(u8, text, option) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, value) != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "\n"));
}

test "--max-total-bytes rejects a negative number (S1-T7 criterion 2)" {
    try expectBadByteCount("--max-total-bytes", "-1");
}

test "--max-total-bytes rejects a non-number (S1-T7 criterion 2)" {
    try expectBadByteCount("--max-total-bytes", "abc");
}

test "--max-file-bytes rejects a negative number (S1-T7 criterion 2)" {
    try expectBadByteCount("--max-file-bytes", "-1");
}

test "--max-file-bytes rejects a non-number (S1-T7 criterion 2)" {
    try expectBadByteCount("--max-file-bytes", "abc");
}

test "byte counts accept valid numbers (S1-T7 criterion 2)" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectEqual(@as(u64, 0), try cli.parseByteCount("--max-file-bytes", "0", &output.writer));
    try std.testing.expectEqual(@as(u64, 1048576), try cli.parseByteCount("--max-total-bytes", "1048576", &output.writer));
    try std.testing.expectEqual(@as(usize, 0), output.written().len);
}
