const analyzer_v2 = @import("analyzer_v2.zig");
const filename_field = @import("filename_field.zig");
const hybrid = @import("hybrid.zig");
const indexer = @import("indexer.zig");
const chunker = @import("chunker.zig");
const snapshot_open = @import("snapshot_open.zig");
const lexical_build = @import("lexical_build.zig");
const postings = @import("postings.zig");
const std = @import("std");

fn makeBodyIndex(allocator: std.mem.Allocator, documents: []const hybrid.Document) !postings.Index {
    const token_lists = try allocator.alloc([][]const u8, documents.len);
    for (documents, 0..) |doc, i| token_lists[i] = try analyzer_v2.tokenize(allocator, doc.text);
    return lexical_build.build(allocator, documents, token_lists);
}

test "filename field builds validated file catalog and returns a real anchor" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const body = [_]hybrid.Document{
        .{ .id = "late", .text = "unrelated body passage", .path = "docs/Annual_Budget_2026.md", .start_line = 20, .end_line = 25 },
        .{ .id = "early", .text = "budget details", .path = "docs/Annual_Budget_2026.md", .start_line = 2, .end_line = 4 },
        .{ .id = "other", .text = "annual figures", .path = "reports/annual.md", .start_line = 1, .end_line = 3 },
    };
    const built = try filename_field.build(allocator, &body, analyzer_v2.analyzer_id);
    try filename_field.validate(allocator, &body, built.catalog, built.lexical, analyzer_v2.analyzer_id);

    const body_tokens = try allocator.alloc([][]const u8, body.len);
    for (body, 0..) |doc, i| body_tokens[i] = try analyzer_v2.tokenize(allocator, doc.text);
    const body_index = try lexical_build.build(allocator, &body, body_tokens);
    const opts = hybrid.SearchOptions{ .top_k = 5, .candidate_k = 5, .retrieval_mode = .lexical };
    const found = try filename_field.query(allocator, &body, body_index, built.catalog, built.lexical, analyzer_v2.analyzer_id, "annual budget 2026", .filename, opts);
    try std.testing.expect(found.len >= 1);
    try std.testing.expectEqualStrings("early", body[found[0].document_index].id);
    try std.testing.expect(found[0].filename_rank != null);
    try std.testing.expectEqual(@as(?usize, null), found[0].body_rank);

    const combined = try filename_field.query(allocator, &body, body_index, built.catalog, built.lexical, analyzer_v2.analyzer_id, "annual budget", .both, opts);
    try std.testing.expect(combined.len >= 1);
    try std.testing.expectEqualStrings("docs/Annual_Budget_2026.md", body[combined[0].document_index].path);

    const scoped = try filename_field.query(allocator, &body, body_index, built.catalog, built.lexical, analyzer_v2.analyzer_id, "annual", .filename, .{ .top_k = 2, .candidate_k = 2, .retrieval_mode = .lexical, .path_prefix = "reports" });
    try std.testing.expectEqual(@as(usize, 1), scoped.len);
    try std.testing.expectEqualStrings("reports/annual.md", body[scoped[0].document_index].path);
}

test "filename catalog validation rejects inconsistent labels" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const body = [_]hybrid.Document{
        .{ .id = "a", .text = "first", .path = "a.md", .start_line = 1, .end_line = 1, .required_labels = "private" },
        .{ .id = "b", .text = "second", .path = "a.md", .start_line = 2, .end_line = 2, .required_labels = "public" },
    };
    try std.testing.expectError(error.InconsistentLabels, filename_field.build(allocator, &body, analyzer_v2.analyzer_id));
}

test "opt-in folder index publishes filename channel and refresh setting is pinned" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "Annual_Budget_2026.md", .data = "numbers and forecasts" });
    try tmp.dir.writeFile(io, .{ .sub_path = "other.md", .data = "unrelated notes" });
    try tmp.dir.createDir(io, "out", .default_dir);
    var out_dir = try tmp.dir.openDir(io, "out", .{});
    defer out_dir.close(io);

    _ = try indexer.indexFolder(allocator, io, tmp.dir, out_dir, .v2, 1, chunker.default_max_chars, chunker.default_overlap_lines, .{ .filename_index = true });
    const opened = try snapshot_open.open(allocator, io, out_dir);
    const hits = try opened.queryFields(allocator, "annual budget", .filename, .{ .retrieval_mode = .lexical, .top_k = 3, .candidate_k = 3 });
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqualStrings("Annual_Budget_2026.md", opened.documents[hits[0].document_index].path);
    try std.testing.expectError(error.FilenameMigrationRequiresNewDirectory, indexer.indexFolder(allocator, io, tmp.dir, out_dir, .v2, 2, chunker.default_max_chars, chunker.default_overlap_lines, .{}));
    try std.testing.expectError(error.FilenameSettingMismatch, indexer.indexFolderIncremental(allocator, io, tmp.dir, out_dir, .v2, chunker.default_max_chars, chunker.default_overlap_lines, .{}));
}

test "filename and both scope scores ignore hidden earlier files and zero-score candidates" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const with_hidden = [_]hybrid.Document{
        .{ .id = "hidden", .text = "annual annual private body", .path = "a_annual_hidden.md", .start_line = 1, .end_line = 1, .required_labels = "secret" },
        .{ .id = "empty", .text = "unrelated body", .path = "b_empty.md", .start_line = 1, .end_line = 1 },
        .{ .id = "visible", .text = "annual body evidence", .path = "z_annual_visible.md", .start_line = 1, .end_line = 1 },
    };
    const visible_only = [_]hybrid.Document{ with_hidden[1], with_hidden[2] };
    const hidden_built = try filename_field.build(allocator, &with_hidden, analyzer_v2.analyzer_id);
    const visible_built = try filename_field.build(allocator, &visible_only, analyzer_v2.analyzer_id);
    const hidden_body = try makeBodyIndex(allocator, &with_hidden);
    const visible_body = try makeBodyIndex(allocator, &visible_only);
    const principal = [_][]const u8{"public"};
    const options = hybrid.SearchOptions{ .top_k = 1, .candidate_k = 1, .retrieval_mode = .lexical, .principal_labels = &principal };
    inline for (.{ filename_field.Field.filename, filename_field.Field.both }) |field| {
        const with_results = try filename_field.query(allocator, &with_hidden, hidden_body, hidden_built.catalog, hidden_built.lexical, analyzer_v2.analyzer_id, "annual", field, options);
        const without_results = try filename_field.query(allocator, &visible_only, visible_body, visible_built.catalog, visible_built.lexical, analyzer_v2.analyzer_id, "annual", field, options);
        try std.testing.expectEqual(@as(usize, 1), with_results.len);
        try std.testing.expectEqual(@as(usize, 1), without_results.len);
        try std.testing.expectEqualStrings("z_annual_visible.md", with_hidden[with_results[0].document_index].path);
        try std.testing.expectEqualStrings("z_annual_visible.md", visible_only[without_results[0].document_index].path);
        try std.testing.expectEqual(without_results[0].filename_score, with_results[0].filename_score);
        try std.testing.expectEqual(without_results[0].body_score, with_results[0].body_score);
        try std.testing.expectEqual(without_results[0].fused_score, with_results[0].fused_score);
    }
}

test "POSIX backslash filename is indexed literally" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const body = [_]hybrid.Document{
        .{ .id = "literal-backslash", .text = "real cited passage", .path = "notes\\draft.md", .start_line = 1, .end_line = 1 },
    };
    const built = try filename_field.build(allocator, &body, analyzer_v2.analyzer_id);
    const body_index = try makeBodyIndex(allocator, &body);
    const hits = try filename_field.query(allocator, &body, body_index, built.catalog, built.lexical, analyzer_v2.analyzer_id, "draft", .filename, .{ .top_k = 1, .candidate_k = 1, .retrieval_mode = .lexical });
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqualStrings("notes\\draft.md", body[hits[0].document_index].path);
}
