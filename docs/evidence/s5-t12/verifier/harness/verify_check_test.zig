//! Verifier's own cases for S5-T12's check (scratch only, not shipped):
//! every case compares the check's answer with a forced walk's
//! (`labeled_documents` unknown), with and without statistics groups.
const std = @import("std");
const analyzer_v2 = @import("analyzer_v2.zig");
const hybrid = @import("hybrid.zig");
const lexical_build = @import("lexical_build.zig");
const manifest = @import("manifest.zig");
const postings = @import("postings.zig");
const scope = @import("scope.zig");

const three_roots = [_]manifest.RootEntry{
    .{ .root_id = "p", .label = "p", .kind = "local", .retain_source = true },
    .{ .root_id = "q", .label = "q", .kind = "local", .retain_source = true },
    .{ .root_id = "e", .label = "e", .kind = "local", .retain_source = true },
};

const docs = [_]hybrid.Document{
    .{ .id = "1", .text = "lanterns by the canal", .path = "p/one.md", .start_line = 1, .end_line = 1 },
    .{ .id = "2", .text = "a lantern and a canal boat", .path = "p/two.md", .start_line = 1, .end_line = 1 },
    .{ .id = "3", .text = "boats boats boats", .path = "q/three.md", .start_line = 1, .end_line = 1 },
    .{ .id = "4", .text = "the canal at night", .path = "q/four.md", .start_line = 1, .end_line = 1 },
};
// One record labelled, in root q.
const labelled = [_]hybrid.Document{ docs[0], docs[1], docs[2], .{ .id = "4", .text = "the canal at night", .path = "q/four.md", .start_line = 1, .end_line = 1, .required_labels = "keepers" } };
// One record in no root.
const stray = [_]hybrid.Document{ docs[0], docs[1], docs[2], .{ .id = "4", .text = "the canal at night", .path = "z/four.md", .start_line = 1, .end_line = 1 } };

fn indexOf(a: std.mem.Allocator, documents: []const hybrid.Document) !postings.Index {
    const lists = try a.alloc([][]const u8, documents.len);
    for (documents, lists) |d, *l| l.* = try analyzer_v2.tokenize(a, d.text);
    return lexical_build.build(a, documents, lists);
}

fn folderOf(a: std.mem.Allocator, documents: []const hybrid.Document, index: postings.Index) !scope.Folder {
    const loads = try a.create(scope.Loads);
    loads.* = .{ .io = std.testing.io, .allocator = a, .blocks = a, .documents = documents, .index = index };
    const meta = manifest.Meta{ .chunkers = &.{}, .roots = @constCast(&three_roots), .source_section_version = 1 };
    return scope.Folder.build(a, meta, loads);
}

fn labelledOf(documents: []const hybrid.Document) bool {
    for (documents) |d| if (d.required_labels.len != 0) return true;
    return false;
}

fn same(a: std.mem.Allocator, documents: []const hybrid.Document, stats: ?*const scope.Statistics, index: postings.Index, mask: ?hybrid.RootMask, labels: []const []const u8) !bool {
    const before = scope.visible_walks;
    const checked = try scope.visibleCollection(a, index, documents, stats, labelledOf(documents), mask, labels);
    const did_walk = scope.visible_walks != before;
    const walked = try scope.visibleCollection(a, index, documents, stats, null, mask, labels);
    try std.testing.expectEqual(walked == null, checked == null);
    if (walked) |w| {
        try std.testing.expectEqual(w.collection.document_count, checked.?.collection.document_count);
        try std.testing.expectEqual(w.collection.average_document_length, checked.?.collection.average_document_length);
        try std.testing.expectEqualSlices(bool, w.visible_groups, checked.?.visible_groups);
    }
    return did_walk;
}

test "verifier: the check equals the walk on every mask over three roots, with and without statistics, labels and strays" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sets = [_][]const hybrid.Document{ &docs, &labelled, &stray };
    const principals = [_][]const []const u8{ &.{}, &.{"keepers"}, &.{"other"} };
    var skipped: usize = 0;
    var cases: usize = 0;
    for (sets) |documents| {
        const index = try indexOf(a, documents);
        const folder = try folderOf(a, documents, index);
        const stats = try scope.Statistics.build(a, documents, folder.document_roots, three_roots.len, index);
        // Every mask of 3 roots, plus too-short and too-long allowed lists.
        var bits: u8 = 0;
        while (bits < 8) : (bits += 1) {
            const allowed = try a.alloc(bool, 3);
            for (allowed, 0..) |*f, i| f.* = (bits >> @intCast(i)) & 1 == 1;
            const allowed_lists = [_][]const bool{ allowed, allowed[0..2], &.{ allowed[0], allowed[1], allowed[2], true } };
            for (allowed_lists) |list| {
                const m = folder.mask(list);
                var short = m;
                short.document_roots = m.document_roots[0..3];
                for ([_]hybrid.RootMask{ m, short }) |mask| for (principals) |labels| for ([_]?*const scope.Statistics{ null, &stats }) |s| {
                    cases += 1;
                    const walked = try same(a, documents, s, index, mask, labels);
                    if (!walked) {
                        skipped += 1;
                        // A skip only where nothing can be hidden.
                        try std.testing.expect(documents.ptr == (&docs).ptr and bits == 7 and list.len == 3 and mask.document_roots.len == 4);
                    }
                };
            }
        }
        // No mask at all.
        for (principals) |labels| for ([_]?*const scope.Statistics{ null, &stats }) |s| {
            cases += 1;
            _ = try same(a, documents, s, index, null, labels);
        };
    }
    // The unlabelled, all-rooted set skips for each principal and statistics choice.
    try std.testing.expectEqual(@as(usize, 6), skipped);
    try std.testing.expect(cases > 400);
}
