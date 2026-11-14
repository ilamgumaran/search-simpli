//! S5-T12 (review R07): the visible-collection view of a request.
//!
//! Part (a)1, the check: `scope.visibleCollection` returns null without
//! walking a document when no record carries a label and the mask allows
//! every root of every document (`RootMask.allowsEvery`), and in every case
//! it answers exactly what the walk answers. The walks are counted
//! (`scope.visible_walks`, test builds only), so a test can say a query did
//! not walk.
const std = @import("std");
const analyzer_v2 = @import("analyzer_v2.zig");
const engine_module = @import("engine.zig");
const filename_field = @import("filename_field.zig");
const hybrid = @import("hybrid.zig");
const lexical_build = @import("lexical_build.zig");
const manifest = @import("manifest.zig");
const postings = @import("postings.zig");
const scope = @import("scope.zig");

const two_roots = [_]manifest.RootEntry{
    .{ .root_id = "r-a", .label = "a", .kind = "local", .retain_source = true },
    .{ .root_id = "r-b", .label = "b", .kind = "local", .retain_source = true },
};

const plain_docs = [_]hybrid.Document{
    .{ .id = "a1", .text = "boxes on the shelf", .path = "r-a/shelf.md", .start_line = 1, .end_line = 1 },
    .{ .id = "a2", .text = "a box of toys", .path = "r-a/toys.md", .start_line = 1, .end_line = 1 },
    .{ .id = "b1", .text = "one more box and boxes", .path = "r-b/more.md", .start_line = 1, .end_line = 1 },
    .{ .id = "b2", .text = "the shelf is full", .path = "r-b/full.md", .start_line = 1, .end_line = 1 },
};

/// `plain_docs` with one record that requires a label.
const labelled_docs = [_]hybrid.Document{
    plain_docs[0],
    plain_docs[1],
    plain_docs[2],
    .{ .id = "b2", .text = "the shelf is full", .path = "r-b/full.md", .start_line = 1, .end_line = 1, .required_labels = "private" },
};

/// `plain_docs` with one record whose path is in no root.
const stray_docs = [_]hybrid.Document{
    plain_docs[0],
    plain_docs[1],
    plain_docs[2],
    .{ .id = "x1", .text = "the shelf is full", .path = "elsewhere/full.md", .start_line = 1, .end_line = 1 },
};

fn indexOf(a: std.mem.Allocator, documents: []const hybrid.Document) !postings.Index {
    const token_lists = try a.alloc([][]const u8, documents.len);
    for (documents, token_lists) |doc, *tokens_out| tokens_out.* = try analyzer_v2.tokenize(a, doc.text);
    return lexical_build.build(a, documents, token_lists);
}

/// `scope.Folder.build` over `documents` with the two roots.
fn folderOf(a: std.mem.Allocator, documents: []const hybrid.Document, index: postings.Index) !scope.Folder {
    const loads = try a.create(scope.Loads);
    loads.* = .{ .io = std.testing.io, .allocator = a, .blocks = a, .documents = documents, .index = index };
    const meta = manifest.Meta{ .chunkers = &.{}, .roots = @constCast(&two_roots), .source_section_version = 1 };
    return scope.Folder.build(a, meta, loads);
}

fn labelledOf(documents: []const hybrid.Document) bool {
    for (documents) |document| if (document.required_labels.len != 0) return true;
    return false;
}

const Answer = struct { walked: bool, view: ?scope.View };

fn answer(a: std.mem.Allocator, index: postings.Index, documents: []const hybrid.Document, labeled: ?bool, mask: ?hybrid.RootMask, labels: []const []const u8) !Answer {
    const before = scope.visible_walks;
    const view = try scope.visibleCollection(a, index, documents, null, labeled, mask, labels);
    return .{ .walked = scope.visible_walks != before, .view = view };
}

/// The check's answer under `labeled` (what `open` found) equals the walk's
/// (forced with `labeled_documents` unknown), and the check walked exactly
/// when `expect_walk`.
fn expectSameAsWalk(a: std.mem.Allocator, documents: []const hybrid.Document, mask: hybrid.RootMask, labels: []const []const u8, expect_walk: bool) !void {
    const index = try indexOf(a, documents);
    const checked = try answer(a, index, documents, labelledOf(documents), mask, labels);
    const walked = try answer(a, index, documents, null, mask, labels);
    try std.testing.expect(walked.walked);
    try std.testing.expectEqual(expect_walk, checked.walked);
    try std.testing.expectEqual(walked.view == null, checked.view == null);
    if (walked.view) |w| {
        const c = checked.view.?;
        try std.testing.expectEqual(w.collection.document_count, c.collection.document_count);
        try std.testing.expectEqual(w.collection.average_document_length, c.collection.average_document_length);
    }
}

test "the check: no walk exactly when no record is labelled and the mask allows every root of every document; the walk's answer in every case" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Folder.build knows whether every record is in a root, and the mask
    // carries it only with one flag per root.
    const plain_folder = try folderOf(a, &plain_docs, try indexOf(a, &plain_docs));
    try std.testing.expect(plain_folder.every_document_rooted);
    const all = plain_folder.mask(&.{ true, true });
    try std.testing.expect(all.rooted and all.allowsEvery(plain_docs.len));
    const one = plain_folder.mask(&.{ true, false });
    try std.testing.expect(one.rooted and !one.allowsEvery(plain_docs.len));
    try std.testing.expect(!plain_folder.mask(&.{true}).rooted);
    const stray_folder = try folderOf(a, &stray_docs, try indexOf(a, &stray_docs));
    try std.testing.expect(!stray_folder.every_document_rooted);
    const stray_all = stray_folder.mask(&.{ true, true });
    try std.testing.expect(!stray_all.rooted and !stray_all.allowsEvery(stray_docs.len));

    // All roots, no label anywhere: null, and no walk.
    try expectSameAsWalk(a, &plain_docs, all, &.{}, false);
    // All roots, one labelled record: the check does not apply; the walk
    // hides it from a caller without the label and not from one with it.
    const labelled_folder = try folderOf(a, &labelled_docs, try indexOf(a, &labelled_docs));
    const labelled_all = labelled_folder.mask(&.{ true, true });
    try expectSameAsWalk(a, &labelled_docs, labelled_all, &.{}, true);
    try expectSameAsWalk(a, &labelled_docs, labelled_all, &.{"private"}, true);
    {
        const index = try indexOf(a, &labelled_docs);
        const hidden = try answer(a, index, &labelled_docs, true, labelled_all, &.{});
        try std.testing.expectEqual(@as(u32, 3), hidden.view.?.collection.document_count);
        const shown = try answer(a, index, &labelled_docs, true, labelled_all, &.{"private"});
        try std.testing.expect(shown.view == null);
    }
    // A mask that hides one root: the walk, and its view.
    try expectSameAsWalk(a, &plain_docs, one, &.{}, true);
    {
        const index = try indexOf(a, &plain_docs);
        const hidden = try answer(a, index, &plain_docs, false, one, &.{});
        try std.testing.expectEqual(@as(u32, 2), hidden.view.?.collection.document_count);
    }
    // Every root allowed, but a record in no root: not known to be covered,
    // so the walk runs, and hides that record.
    try expectSameAsWalk(a, &stray_docs, stray_all, &.{}, true);
    {
        const index = try indexOf(a, &stray_docs);
        const hidden = try answer(a, index, &stray_docs, false, stray_all, &.{});
        try std.testing.expectEqual(@as(u32, 3), hidden.view.?.collection.document_count);
    }
    // A mask built by hand (no `rooted`) is never taken as covering.
    const by_hand = hybrid.RootMask{ .document_roots = plain_folder.document_roots, .allowed = &.{ true, true } };
    try std.testing.expect(!by_hand.allowsEvery(plain_docs.len));
    try expectSameAsWalk(a, &plain_docs, by_hand, &.{}, true);
    // A mask over fewer documents than the request's is not covering.
    var short = all;
    short.document_roots = all.document_roots[0..2];
    try std.testing.expect(!short.allowsEvery(plain_docs.len));
}

/// An engine over `documents` with the two roots and the file-name channel,
/// as `open` leaves it (`labeled_documents` set).
fn bothEngine(a: std.mem.Allocator, documents: []const hybrid.Document) !engine_module.Engine {
    const index = try indexOf(a, documents);
    const built = try filename_field.build(a, documents, analyzer_v2.analyzer_id);
    return .{
        .generation = 1,
        .analyzer_id = analyzer_v2.analyzer_id,
        .embedding_model_id = "",
        .vector_dimensions = 0,
        .documents = documents,
        .lexical_index = index,
        .roots = &two_roots,
        .labeled_documents = labelledOf(documents),
        .filename_index_enabled = true,
        .filename_decoded = try filename_field.decode(a, documents, index, built.catalog, built.lexical),
    };
}

fn walksOf(a: std.mem.Allocator, engine: engine_module.Engine, query: []const u8, field: filename_field.Field, options: hybrid.SearchOptions) !usize {
    const before = scope.visible_walks;
    _ = try engine.queryFields(a, query, field, options);
    return scope.visible_walks - before;
}

test "the check through the engine: an unscoped both or content query with every root allowed walks nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const folder = try folderOf(a, &plain_docs, try indexOf(a, &plain_docs));
    const engine = try bothEngine(a, &plain_docs);
    var options = hybrid.SearchOptions{ .top_k = 4, .candidate_k = 4, .retrieval_mode = .lexical };
    options.visible_roots = folder.mask(&.{ true, true });
    // `box` is grouped (boxes), `shelf` has no group.
    for ([_][]const u8{ "box", "shelf" }) |q| {
        try std.testing.expectEqual(@as(usize, 0), try walksOf(a, engine, q, .both, options));
        try std.testing.expectEqual(@as(usize, 0), try walksOf(a, engine, q, .content, options));
    }
    // A labelled record under the same mask: the walk runs, as before.
    const labelled = try bothEngine(a, &labelled_docs);
    const labelled_folder = try folderOf(a, &labelled_docs, try indexOf(a, &labelled_docs));
    options.visible_roots = labelled_folder.mask(&.{ true, true });
    try std.testing.expect(try walksOf(a, labelled, "shelf", .content, options) == 1);
}
