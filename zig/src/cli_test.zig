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
