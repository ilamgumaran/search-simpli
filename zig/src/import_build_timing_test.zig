//! S2-T2 plant: `ss_import_json` / `searchd import-json` with
//! `"analyzer_id": "ascii-alnum-v1"` must build its index in time linear in
//! the number of tokens.
//!
//! The old build (`postings.build`) scanned the growing term list and
//! re-scanned the document for every token, so doubling the corpus (and with
//! it the vocabulary) quadrupled the time. Nothing here is an absolute
//! wall-clock threshold: the test imports 125, 250 and 500 generated documents
//! (best of five each) and asserts the growth ratios. Linear is 2x per
//! doubling and 4x for 125 -> 500; quadratic is 4x and 16x. The bounds sit
//! between the two. Kept in its own file so restoring the old importer
//! leaves the test in place and makes it fail.
const std = @import("std");
const importer = @import("importer.zig");

const runs = 5;
// Each document holds 24 tokens: 16 words not seen in any other document
// (the vocabulary grows with the corpus, as in a real one) and 8 from a
// small shared set, written in mixed case.
const sizes = [_]usize{ 125, 250, 500 };

fn interchange(arena: std.mem.Allocator, document_count: usize) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll("{\"format_version\":1,\"generation\":1,\"analyzer_id\":\"ascii-alnum-v1\",\"embedding_model_id\":\"none\",\"documents\":[");
    const shared = [_][]const u8{ "the", "The", "AND", "search", "Search", "index", "lexical", "zig" };
    for (0..document_count) |doc| {
        if (doc != 0) try w.writeAll(",");
        try w.print("{{\"id\":\"d{d}\",\"path\":\"p{d}.md\",\"start_line\":1,\"end_line\":1,\"vector\":[],\"text\":\"", .{ doc, doc });
        for (0..16) |k| {
            const id = doc * 16 + k;
            if (k % 4 == 0) {
                try w.print("Zq{d}x ", .{id});
            } else {
                try w.print("zq{d}x ", .{id});
            }
        }
        for (shared) |word| try w.print("{s} ", .{word});
        try w.writeAll("\"}");
    }
    try w.writeAll("]}");
    return out.written();
}

fn bestImportNanoseconds(io: std.Io, json: []const u8) !i96 {
    var best: i96 = std.math.maxInt(i96);
    for (0..runs) |_| {
        var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena_state.deinit();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const start = std.Io.Clock.awake.now(io).nanoseconds;
        const report = try importer.importJson(tmp.dir, io, arena_state.allocator(), json);
        const finish = std.Io.Clock.awake.now(io).nanoseconds;
        try std.testing.expect(report.terms > 0);
        best = @min(best, finish - start);
    }
    return best;
}

test "ascii-alnum-v1 import time grows linearly with the corpus (S2-T2 plant)" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    var best: [sizes.len]f64 = undefined;
    for (sizes, 0..) |count, i| {
        const json = try interchange(arena_state.allocator(), count);
        best[i] = @floatFromInt(try bestImportNanoseconds(io, json));
    }
    const first_doubling = best[1] / best[0];
    const second_doubling = best[2] / best[1];
    const quadrupling = best[2] / best[0];
    std.debug.print(
        "\nimport best-of-{d}: 125 docs {d:.1} ms, 250 {d:.1} ms, 500 {d:.1} ms; growth 125->250 {d:.2}x, 250->500 {d:.2}x, 125->500 {d:.2}x\n",
        .{ runs, best[0] / 1e6, best[1] / 1e6, best[2] / 1e6, first_doubling, second_doubling, quadrupling },
    );
    // Linear ~2x / ~4x, quadratic ~4x / ~16x.
    try std.testing.expect(quadrupling < 8.0);
    try std.testing.expect(first_doubling < 3.2);
    try std.testing.expect(second_doubling < 3.2);
}
