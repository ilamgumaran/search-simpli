//! S6-T19: a test of `ops/filename_response.zig`, moved here from beside it with its
//! name and body unchanged apart from imports. It names `analyzer_v2.analyzer_id`, which
//! no operation or interface uses; a test beside the code in ops/ reaches the core only
//! through the public core API, a test in tests/ may use internals (docs/core-api.md),
//! so the move lets that name leave `api`.
const std = @import("std");
const engine_module = @import("core").engine;
const filename_field = @import("core").filename_field;
const hybrid = @import("core").hybrid;
const writeEvidence = @import("operations").filename_response.writeEvidence;

test "filename results expose source-based match sections and readable citations" {
    const allocator = std.testing.allocator;
    const docs = [_]hybrid.Document{.{
        .id = "chunk-1",
        .path = "docs/Annual_Report.md",
        .text = "The budget grew.",
        .start_line = 8,
        .end_line = 10,
    }};
    const engine = engine_module.Engine{
        .generation = 3,
        .analyzer_id = @import("core").analyzer_v2.analyzer_id,
        .embedding_model_id = "none",
        .vector_dimensions = 0,
        .documents = &docs,
        .lexical_index = .{ .terms = &.{}, .postings = &.{}, .document_lengths = &.{}, .average_document_length = 0 },
    };
    const hits = [_]filename_field.Hit{.{
        .document_index = 0,
        .body_rank = 1,
        .filename_rank = 1,
        .fused_score = 0.5,
    }};
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeEvidence(&out.writer, arena_state.allocator(), engine, "annual budget missing md", .both, .{ .top_k = 1, .candidate_k = 1, .retrieval_mode = .lexical }, &hits, false);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out.written(), .{});
    defer parsed.deinit();
    const sections = parsed.value.object.get("results").?.array.items[0].object.get("match_sections").?.object;
    const filename = sections.get("filename").?.object;
    try std.testing.expect(filename.get("matched").?.bool);
    try std.testing.expectEqualStrings("Annual_Report.md", filename.get("text").?.string);
    const filename_terms = filename.get("matched_terms").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), filename_terms.len);
    try std.testing.expectEqualStrings("annual", filename_terms[0].string);
    const filename_citation = filename.get("citation").?.object;
    try std.testing.expectEqualStrings("filename", filename_citation.get("field").?.string);
    try std.testing.expect(filename_citation.get("start_line") == null);
    const content = sections.get("content").?.object;
    try std.testing.expect(content.get("matched").?.bool);
    try std.testing.expectEqualStrings("The budget grew.", content.get("text").?.string);
    try std.testing.expectEqualStrings("budget", content.get("matched_terms").?.array.items[0].string);
    const content_citation = content.get("citation").?.object;
    try std.testing.expectEqualStrings("content", content_citation.get("field").?.string);
    try std.testing.expectEqual(@as(i64, 8), content_citation.get("start_line").?.integer);
    try std.testing.expectEqual(@as(i64, 10), content_citation.get("end_line").?.integer);

    var human: std.Io.Writer.Allocating = .init(allocator);
    defer human.deinit();
    try writeEvidence(&human.writer, arena_state.allocator(), engine, "annual budget missing md", .both, .{ .top_k = 1, .candidate_k = 1, .retrieval_mode = .lexical }, &hits, true);
    try std.testing.expect(std.mem.indexOf(u8, human.written(), "File name: MATCH") != null);
    try std.testing.expect(std.mem.indexOf(u8, human.written(), "Content: MATCH") != null);
    try std.testing.expect(std.mem.indexOf(u8, human.written(), "docs/Annual_Report.md:8-10") != null);
    try std.testing.expect(std.mem.indexOf(u8, human.written(), "text: The budget grew.") != null);
}
