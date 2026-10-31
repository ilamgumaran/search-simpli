//! Golden conformance test for `md-section-v1` (S3-T1 ruling 2): the Zig
//! port in `chunker_md.zig` reproduces the Python reference
//! (`search_platform.core._md_section_chunks` and `markdown_outline`) exactly
//! on every file in `fixtures/chunk-golden-md.json`: chunk ids, line ranges,
//! text, section paths, heading lines, and the outline (front matter range,
//! fields, headings with levels, lines and end lines, line count).
//! Regenerate with `python3 scripts/gen_chunk_golden_md.py > fixtures/chunk-golden-md.json`.
const std = @import("std");
const chunker = @import("chunker.zig");
const chunker_md = @import("chunker_md.zig");

const golden_path = "../fixtures/chunk-golden-md.json";

fn readAll(arena: std.mem.Allocator, path: []const u8) ![]u8 {
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const stat = try cwd.statFile(io, path, .{});
    const size = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
    const buffer = try arena.alloc(u8, size);
    return cwd.readFile(io, path, buffer);
}

fn intField(object: std.json.ObjectMap, name: []const u8) u32 {
    return @intCast(object.get(name).?.integer);
}

test "md-section-v1 matches the Python reference on every golden file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const golden_bytes = try readAll(arena, golden_path);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, golden_bytes, .{});
    const root = parsed.object;
    try std.testing.expectEqualStrings(chunker_md.chunker_id, root.get("chunker_id").?.string);
    const max_chars: usize = @intCast(root.get("max_chars").?.integer);
    const overlap_lines: usize = @intCast(root.get("overlap_lines").?.integer);

    var files_compared: usize = 0;
    var chunks_compared: usize = 0;
    var headings_compared: usize = 0;
    for (root.get("files").?.array.items) |file_value| {
        const entry = file_value.object;
        const relative_path = entry.get("path").?.string;
        const full_path = try std.fmt.allocPrint(arena, "../{s}/{s}", .{ entry.get("root").?.string, relative_path });
        const source = try readAll(arena, full_path);

        const spans = try chunker_md.chunk(arena, source, max_chars, overlap_lines);
        const expected_chunks = entry.get("chunks").?.array.items;
        if (expected_chunks.len != spans.len) std.debug.print("chunk count differs: {s}\n", .{full_path});
        try std.testing.expectEqual(expected_chunks.len, spans.len);
        for (spans, expected_chunks) |span, expected_value| {
            const expected = expected_value.object;
            var id_hex: [20]u8 = undefined;
            chunker.chunkId(&id_hex, relative_path, span.start_line, span.end_line, span.text);
            try std.testing.expectEqualStrings(expected.get("id").?.string, &id_hex);
            try std.testing.expectEqual(intField(expected, "start_line"), span.start_line);
            try std.testing.expectEqual(intField(expected, "end_line"), span.end_line);
            try std.testing.expectEqualStrings(expected.get("text").?.string, span.text);
            try std.testing.expectEqual(intField(expected, "heading_line"), span.heading_line);
            const path_items = expected.get("section_path").?.array.items;
            try std.testing.expectEqual(path_items.len, span.section_depth);
            var joined = std.ArrayList(u8).empty;
            for (path_items, 0..) |item, position| {
                if (position > 0) try joined.append(arena, chunker_md.section_separator);
                try joined.appendSlice(arena, item.string);
            }
            try std.testing.expectEqualStrings(joined.items, span.section_path);
            chunks_compared += 1;
        }

        const expected_outline = entry.get("outline").?.object;
        const outline = try chunker_md.outline(arena, source);
        try std.testing.expectEqual(intField(expected_outline, "lines"), outline.lines);
        const expected_headings = expected_outline.get("headings").?.array.items;
        try std.testing.expectEqual(expected_headings.len, outline.headings.len);
        for (outline.headings, expected_headings) |heading, expected_value| {
            const expected = expected_value.object;
            try std.testing.expectEqual(intField(expected, "level"), heading.level);
            try std.testing.expectEqualStrings(expected.get("text").?.string, heading.text);
            try std.testing.expectEqual(intField(expected, "line"), heading.line);
            try std.testing.expectEqual(intField(expected, "end_line"), heading.end_line);
            headings_compared += 1;
        }
        switch (expected_outline.get("front_matter").?) {
            .null => try std.testing.expect(outline.front_matter == null),
            .object => |front| {
                const mine = outline.front_matter.?;
                try std.testing.expectEqual(intField(front, "start_line"), @as(u32, @intCast(mine.start + 1)));
                try std.testing.expectEqual(intField(front, "end_line"), @as(u32, @intCast(mine.end + 1)));
                const fields = front.get("fields").?.object;
                try std.testing.expectEqual(fields.count(), mine.fields.len);
                var iterator = fields.iterator();
                var position: usize = 0;
                while (iterator.next()) |field| : (position += 1) {
                    try std.testing.expectEqualStrings(field.key_ptr.*, mine.fields[position].key);
                    try std.testing.expectEqualStrings(field.value_ptr.*.string, mine.fields[position].value);
                }
                try std.testing.expectEqual(front.get("raw") == null, mine.valid);
                if (front.get("raw")) |raw| try std.testing.expectEqualStrings(raw.string, mine.raw);
            },
            else => return error.UnexpectedGoldenShape,
        }
        files_compared += 1;
    }
    std.debug.print("chunk-golden-md conformance: {d} files, {d} chunks, {d} headings identical\n", .{ files_compared, chunks_compared, headings_compared });
    try std.testing.expect(files_compared >= 40);
}
