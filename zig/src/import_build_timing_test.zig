//! S2-T2 plant: `ss_import_json` / `searchd import-json` with
//! `"analyzer_id": "ascii-alnum-v1"` must build its index in time linear in
//! the number of tokens.
//!
//! The old build (`postings.build`) scanned the growing term list and
//! re-scanned the document for every token, so doubling the corpus (and with
//! it the vocabulary) quadrupled the time. Nothing here is an absolute
//! wall-clock threshold: the test imports 125 and 1,000 generated documents
//! (runs interleaved, best of five each) and asserts one growth ratio below
//! 24x. Linear is 8x; quadratic is 64x. Kept in its own file so restoring
//! the old importer leaves the test in place and makes it fail.
const std = @import("std");
const importer = @import("importer.zig");

const runs = 5;
// Each document holds 24 tokens: 16 words not seen in any other document
// (the vocabulary grows with the corpus, as in a real one) and 8 from a
// small shared set, written in mixed case.
const small_count: usize = 125;
const large_count: usize = 1000;

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

fn importNanoseconds(io: std.Io, json: []const u8) !i96 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const start = std.Io.Clock.awake.now(io).nanoseconds;
    const report = try importer.importJson(tmp.dir, io, arena_state.allocator(), json);
    const finish = std.Io.Clock.awake.now(io).nanoseconds;
    try std.testing.expect(report.terms > 0);
    return finish - start;
}

test "ascii-alnum-v1 import time grows linearly with the corpus (S2-T2 plant)" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const small_json = try interchange(arena_state.allocator(), small_count);
    const large_json = try interchange(arena_state.allocator(), large_count);
    // Runs are interleaved so that machine load hits both sizes alike, and
    // one wide-span ratio replaces per-doubling bounds: a short import can
    // finish inside one scheduler slice while a long one is preempted, so
    // load only ever pushes a ratio up, and narrow bounds flake.
    var best_small: i96 = std.math.maxInt(i96);
    var best_large: i96 = std.math.maxInt(i96);
    for (0..runs) |_| {
        best_small = @min(best_small, try importNanoseconds(io, small_json));
        best_large = @min(best_large, try importNanoseconds(io, large_json));
    }
    const growth = @as(f64, @floatFromInt(best_large)) / @as(f64, @floatFromInt(best_small));
    std.debug.print(
        "\nimport best-of-{d}: {d} docs {d:.1} ms, {d} docs {d:.1} ms; growth {d:.2}x\n",
        .{ runs, small_count, @as(f64, @floatFromInt(best_small)) / 1e6, large_count, @as(f64, @floatFromInt(best_large)) / 1e6, growth },
    );
    // 8x the documents: linear is 8x, quadratic is 64x.
    try std.testing.expect(growth < 24.0);
}
