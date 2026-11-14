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

// ------------------------------------------- part (a)2: the lazy view --

/// Root r-a and r-b hold the same words in different numbers, so a key df
/// over r-a alone orders and admits members differently from the whole
/// index: `café` is the more common spelling overall and ties with `cafe`
/// in r-a; `painting` is more common than `paint` overall (so it is no
/// verb-form member of a held `paint`) and not in r-a (so it is one).
const skewed_docs = [_]hybrid.Document{
    .{ .id = "a1", .text = "cafe by the paint shop", .path = "r-a/one.md", .start_line = 1, .end_line = 1 },
    .{ .id = "a2", .text = "café painting", .path = "r-a/two.md", .start_line = 1, .end_line = 1 },
    .{ .id = "a3", .text = "a quiet shelf", .path = "r-a/three.md", .start_line = 1, .end_line = 1 },
    .{ .id = "b1", .text = "café painting paint", .path = "r-b/one.md", .start_line = 1, .end_line = 1 },
    .{ .id = "b2", .text = "café painting", .path = "r-b/two.md", .start_line = 1, .end_line = 1 },
    .{ .id = "b3", .text = "café corner", .path = "r-b/three.md", .start_line = 1, .end_line = 1 },
};

/// The members (term, key df) `both` gives `query`'s first group, or none.
fn bothMembers(a: std.mem.Allocator, engine: engine_module.Engine, query: []const u8, options: hybrid.SearchOptions) ![]const @import("fuzzy.zig").Member {
    const groups = (try engine.bothGroups(a, query, options)) orelse return &.{};
    return groups.items[0].members;
}

/// The members the `content` path (its view built eagerly, for BM25)
/// names for `query`'s first group, the typed word left out, or none.
fn contentMembers(a: std.mem.Allocator, engine: engine_module.Engine, query: []const u8, options: hybrid.SearchOptions) ![]const []const u8 {
    var trace = hybrid.Trace{ .allocator = a, .io = std.testing.io };
    _ = try engine.queryTraced(a, query, &.{}, try a.alloc(hybrid.Result, engine.documents.len), options, &trace);
    if (trace.grouped.items.len == 0) return &.{};
    return trace.grouped.items[0].members;
}

fn expectMembers(members: []const @import("fuzzy.zig").Member, typed: []const u8, expected: []const []const u8) !void {
    var named = std.ArrayList([]const u8).empty;
    defer named.deinit(std.testing.allocator);
    for (members) |m| if (!std.mem.eql(u8, m.term, typed)) try named.append(std.testing.allocator, m.term);
    try std.testing.expectEqual(expected.len, named.items.len);
    for (named.items, expected) |got, want| try std.testing.expectEqualStrings(want, got);
}

test "the lazy view: under a scope that hides a root, a both query walks once when its words form a group and not at all when they form none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const folder = try folderOf(a, &plain_docs, try indexOf(a, &plain_docs));
    const engine = try bothEngine(a, &plain_docs);
    var options = hybrid.SearchOptions{ .top_k = 4, .candidate_k = 4, .retrieval_mode = .lexical };
    options.visible_roots = folder.mask(&.{ true, false });
    // `shelf` and `toys` are held and form no group (`toys` keys to `toy`,
    // which no chunk holds); `zebra` is held nowhere and has no near word.
    for ([_][]const u8{ "shelf", "toys", "zebra", "shelf toys" }) |q| {
        try std.testing.expectEqual(@as(usize, 0), try walksOf(a, engine, q, .both, options));
    }
    // `box` is grouped with `boxes` in r-a: one walk for the query, however
    // many members or words read a key df.
    try std.testing.expectEqual(@as(usize, 1), try walksOf(a, engine, "box", .both, options));
    try std.testing.expectEqual(@as(usize, 1), try walksOf(a, engine, "box boxes shelf", .both, options));
    // The content path still builds its view for BM25, once.
    try std.testing.expectEqual(@as(usize, 1), try walksOf(a, engine, "shelf", .content, options));
}

test "the lazy view is the request's: key df order and verb-form admission as the content path's view gives them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const folder = try folderOf(a, &skewed_docs, try indexOf(a, &skewed_docs));
    const engine = try bothEngine(a, &skewed_docs);
    var scoped = hybrid.SearchOptions{ .top_k = 6, .candidate_k = 6, .retrieval_mode = .lexical };
    scoped.visible_roots = folder.mask(&.{ true, false });
    var unscoped = scoped;
    unscoped.visible_roots = folder.mask(&.{ true, true });

    // Over the whole index café (df 4) comes before cafe (df 1); in r-a they
    // tie at 1 and order by bytes.
    try expectMembers(try bothMembers(a, engine, "cafes", unscoped), "cafes", &.{ "café", "cafe" });
    try expectMembers(try bothMembers(a, engine, "cafes", scoped), "cafes", &.{ "cafe", "café" });
    for ([_]hybrid.SearchOptions{ scoped, unscoped }) |options| {
        const both = try bothMembers(a, engine, "cafes", options);
        const content = try contentMembers(a, engine, "cafes", options);
        try expectMembers(both, "cafes", content);
    }
    for (try bothMembers(a, engine, "cafes", scoped)) |m| try std.testing.expectEqual(@as(u32, 1), m.key_df);

    // A held `paint` takes `painting` at half weight only when the form is
    // no more common: not over the whole index (3 against 2), yes in r-a
    // (1 against 1). Whether the group exists reads the view.
    try std.testing.expectEqual(@as(usize, 0), (try bothMembers(a, engine, "paint", unscoped)).len);
    const painted = try bothMembers(a, engine, "paint", scoped);
    try expectMembers(painted, "paint", &.{"painting"});
    try expectMembers(painted, "paint", try contentMembers(a, engine, "paint", scoped));
    try std.testing.expectEqual(@as(usize, 0), (try contentMembers(a, engine, "paint", unscoped)).len);
    try std.testing.expectEqual(@as(usize, 1), try walksOf(a, engine, "paint", .both, scoped));
    try std.testing.expectEqual(@as(usize, 0), try walksOf(a, engine, "paint", .both, unscoped));
}
