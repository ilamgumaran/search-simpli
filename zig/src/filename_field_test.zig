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

test "streaming filename validation rejects a semantically wrong posting frequency" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = [_]hybrid.Document{.{ .id = "a", .path = "annual_annual.md", .text = "body", .start_line = 1, .end_line = 1 }};
    const built = try filename_field.build(a, &body, analyzer_v2.analyzer_id);
    const decoded = try filename_field.decode(a, &body, try makeBodyIndex(a, &body), built.catalog, built.lexical);
    try filename_field.validateDecoded(a, decoded, analyzer_v2.analyzer_id);
    @constCast(decoded.lexical.postings)[0].term_frequency += 1;
    try std.testing.expectError(error.FilenameLexicalMismatch, filename_field.validateDecoded(a, decoded, analyzer_v2.analyzer_id));
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
    try std.testing.expect(opened.filename_decoded != null);
    const hits = try opened.queryFields(allocator, "annual budget", .filename, .{ .retrieval_mode = .lexical, .top_k = 3, .candidate_k = 3 });
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqualStrings("Annual_Budget_2026.md", opened.documents[hits[0].document_index].path);
    // S4-T2 R6: an omitted setting keeps the directory's, for an update and
    // for a full rebuild; asking for none is refused.
    try tmp.dir.writeFile(io, .{ .sub_path = "Harbour_Map.md", .data = "tide tables" });
    _ = try indexer.indexFolderIncremental(allocator, io, tmp.dir, out_dir, .v2, chunker.default_max_chars, chunker.default_overlap_lines, .{});
    _ = try indexer.indexFolder(allocator, io, tmp.dir, out_dir, .v2, 9, chunker.default_max_chars, chunker.default_overlap_lines, .{});
    const kept = try snapshot_open.open(allocator, io, out_dir);
    try std.testing.expectEqual(@as(u64, 9), kept.generation);
    const harbour = try kept.queryFields(allocator, "harbour", .filename, .{ .retrieval_mode = .lexical, .top_k = 3, .candidate_k = 3 });
    try std.testing.expectEqualStrings("Harbour_Map.md", kept.documents[harbour[0].document_index].path);
    try std.testing.expectError(error.FilenameMigrationRequiresNewDirectory, indexer.indexFolder(allocator, io, tmp.dir, out_dir, .v2, 10, chunker.default_max_chars, chunker.default_overlap_lines, .{ .filename_index = false }));
    try std.testing.expectError(error.FilenameSettingMismatch, indexer.indexFolderIncremental(allocator, io, tmp.dir, out_dir, .v2, chunker.default_max_chars, chunker.default_overlap_lines, .{ .filename_index = false }));
    // A directory without the channel keeps none.
    try tmp.dir.createDir(io, "plain", .default_dir);
    var plain = try tmp.dir.openDir(io, "plain", .{ .iterate = true });
    defer plain.close(io);
    _ = try indexer.indexFolderIncremental(allocator, io, tmp.dir, plain, .v2, chunker.default_max_chars, chunker.default_overlap_lines, .{});
    _ = try indexer.indexFolderIncremental(allocator, io, tmp.dir, plain, .v2, chunker.default_max_chars, chunker.default_overlap_lines, .{});
    try std.testing.expect(!(try snapshot_open.open(allocator, io, plain)).filename_index_enabled);
}

test "cached filename anchors apply body ordinals and isolate scoped averages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Body order differs from the sorted catalog; hidden short names must
    // neither pass the mask nor affect the visible file's BM25 score.
    const body = [_]hybrid.Document{
        .{ .id = "visible", .path = "z/annual_budget.md", .text = "budget evidence", .start_line = 1, .end_line = 1 },
        .{ .id = "hidden", .path = "a/annual.md", .text = "annual", .start_line = 1, .end_line = 1 },
    };
    const built = try filename_field.build(a, &body, analyzer_v2.analyzer_id);
    const decoded = try filename_field.decode(a, &body, try makeBodyIndex(a, &body), built.catalog, built.lexical);
    try std.testing.expectEqualSlices(usize, &.{ 1, 0 }, decoded.anchors);
    const opts = hybrid.SearchOptions{ .retrieval_mode = .lexical, .top_k = 2, .candidate_k = 2, .visible_roots = .{ .document_roots = &.{ 0, 1 }, .allowed = &.{ true, false } } };
    const hits = try filename_field.queryDecoded(a, &body, try makeBodyIndex(a, &body), decoded, analyzer_v2.analyzer_id, "annual", .filename, opts);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqual(@as(usize, 0), hits[0].document_index);
    const alone = try filename_field.build(a, body[0..1], analyzer_v2.analyzer_id);
    const reference = try filename_field.query(a, body[0..1], try makeBodyIndex(a, body[0..1]), alone.catalog, alone.lexical, analyzer_v2.analyzer_id, "annual", .filename, .{ .retrieval_mode = .lexical, .top_k = 2, .candidate_k = 2 });
    try std.testing.expectEqual(reference[0].filename_score, hits[0].filename_score);
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

/// PR #21's query, kept as the oracle for S4-T2 R5's linear query: every
/// visible catalog entry and chunk walked per query, chunks grouped by path
/// through a hash map, hits merged by a scan over the output. (The body
/// dictionary lookup is exact either way.)
fn prQuery(allocator: std.mem.Allocator, body_docs: []const hybrid.Document, body_index: postings.Index, decoded: filename_field.Decoded, query_text: []const u8, field: filename_field.Field, options: hybrid.SearchOptions) ![]filename_field.Hit {
    const scoring = @import("scoring.zig");
    const Candidate = struct { path: []const u8, body_index: usize, score: f32 = 0, catalog_index: usize = 0 };
    const Order = struct {
        fn less(docs: []const hybrid.Document, a: Candidate, b: Candidate) bool {
            if (a.score != b.score) return a.score > b.score;
            const order = std.mem.order(u8, a.path, b.path);
            if (order != .eq) return order == .lt;
            return std.mem.order(u8, docs[a.body_index].id, docs[b.body_index].id) == .lt;
        }
        fn hitLess(docs: []const hybrid.Document, a: filename_field.Hit, b: filename_field.Hit) bool {
            if (a.fused_score != b.fused_score) return a.fused_score > b.fused_score;
            const x = std.mem.order(u8, docs[a.document_index].path, docs[b.document_index].path);
            if (x != .eq) return x == .lt;
            return std.mem.order(u8, docs[a.document_index].id, docs[b.document_index].id) == .lt;
        }
        fn merge(a: std.mem.Allocator, out: *std.ArrayList(filename_field.Hit), docs: []const hybrid.Document, c: Candidate, is_body: bool, rank: usize) !void {
            const k: f32 = 60;
            for (out.items) |*h| if (std.mem.eql(u8, docs[h.document_index].path, c.path)) {
                if (is_body) {
                    h.body_rank = rank;
                    h.body_score = c.score;
                } else {
                    h.filename_rank = rank;
                    h.filename_score = c.score;
                }
                h.fused_score += 1 / (k + @as(f32, @floatFromInt(rank)));
                return;
            };
            try out.append(a, .{ .document_index = c.body_index, .body_score = if (is_body) c.score else 0, .body_rank = if (is_body) rank else null, .filename_score = if (is_body) 0 else c.score, .filename_rank = if (is_body) null else rank, .fused_score = 1 / (k + @as(f32, @floatFromInt(rank))) });
        }
    };
    const catalog = decoded.catalog;
    const lexical = decoded.lexical;
    const qt = try filename_field.tokenize(allocator, analyzer_v2.analyzer_id, query_text);
    var filename = try allocator.alloc(Candidate, catalog.len);
    var fn_count: usize = 0;
    const filename_visible = try allocator.alloc(bool, catalog.len);
    var filename_total_len: usize = 0;
    for (catalog, 0..) |doc, i| {
        filename_visible[i] = hybrid.inScope(doc, decoded.anchors[i], options);
        if (!filename_visible[i]) continue;
        filename_total_len += lexical.document_lengths[i];
        filename[fn_count] = .{ .path = doc.path, .body_index = decoded.anchors[i], .catalog_index = i };
        fn_count += 1;
    }
    const filename_avg = if (fn_count == 0) 0 else @as(f32, @floatFromInt(filename_total_len)) / @as(f32, @floatFromInt(fn_count));
    const body_visible = try allocator.alloc(bool, body_docs.len);
    var visible_count: usize = 0;
    var total_len: usize = 0;
    for (body_docs, 0..) |doc, i| {
        body_visible[i] = hybrid.inScope(doc, i, options);
        if (body_visible[i]) {
            visible_count += 1;
            total_len += body_index.document_lengths[i];
        }
    }
    const avg = if (visible_count == 0) 0 else @as(f32, @floatFromInt(total_len)) / @as(f32, @floatFromInt(visible_count));
    const body_scores = try allocator.alloc(f32, body_docs.len);
    @memset(body_scores, 0);
    const fname_scores = try allocator.alloc(f32, catalog.len);
    @memset(fname_scores, 0);
    for (qt, 0..) |term, qi| {
        var repeated = false;
        for (qt[0..qi]) |previous| if (std.mem.eql(u8, previous, term)) {
            repeated = true;
        };
        if (repeated) continue;
        if (decoded.filenameTerm(term)) |ti| {
            const ent = lexical.terms[ti];
            var df: u32 = 0;
            for (lexical.postings[ent.postings_start .. ent.postings_start + ent.postings_length]) |p| if (filename_visible[p.document_index]) {
                df += 1;
            };
            for (lexical.postings[ent.postings_start .. ent.postings_start + ent.postings_length]) |p| if (filename_visible[p.document_index]) {
                fname_scores[p.document_index] += scoring.bm25Contribution(@floatFromInt(p.term_frequency), @floatFromInt(lexical.document_lengths[p.document_index]), filename_avg, df, @intCast(fn_count), options.bm25);
            };
        }
        if (postings.lookupExact(body_index, term)) |ti| {
            const ent = body_index.terms[ti];
            var df: u32 = 0;
            for (body_index.postings[ent.postings_start .. ent.postings_start + ent.postings_length]) |p| if (body_visible[p.document_index]) {
                df += 1;
            };
            for (body_index.postings[ent.postings_start .. ent.postings_start + ent.postings_length]) |p| if (body_visible[p.document_index]) {
                body_scores[p.document_index] += scoring.bm25Contribution(@floatFromInt(p.term_frequency), @floatFromInt(body_index.document_lengths[p.document_index]), avg, df, @intCast(visible_count), options.bm25);
            };
        }
    }
    var positive_count: usize = 0;
    for (filename[0..fn_count]) |c| {
        const score = fname_scores[c.catalog_index];
        if (score <= 0) continue;
        filename[positive_count] = c;
        filename[positive_count].score = score;
        positive_count += 1;
    }
    fn_count = positive_count;
    std.mem.sort(Candidate, filename[0..fn_count], body_docs, Order.less);
    var body = std.ArrayList(Candidate).empty;
    if (field == .both) {
        var by_path: std.StringHashMapUnmanaged(usize) = .empty;
        for (body_docs, body_scores, 0..) |doc, score, bi| if (score > 0 and body_visible[bi]) {
            const slot = try by_path.getOrPut(allocator, doc.path);
            if (slot.found_existing) {
                const ix = slot.value_ptr.*;
                if (score > body.items[ix].score or (score == body.items[ix].score and std.mem.order(u8, doc.id, body_docs[body.items[ix].body_index].id) == .lt)) body.items[ix] = .{ .path = doc.path, .body_index = bi, .score = score };
            } else {
                slot.value_ptr.* = body.items.len;
                try body.append(allocator, .{ .path = doc.path, .body_index = bi, .score = score });
            }
        };
        std.mem.sort(Candidate, body.items, body_docs, Order.less);
    }
    const fn_limit = @min(fn_count, options.candidate_k);
    const body_limit = @min(body.items.len, options.candidate_k);
    var out = std.ArrayList(filename_field.Hit).empty;
    if (field == .filename) {
        for (filename[0..fn_limit], 0..) |c, rank| if (c.score > 0 and out.items.len < options.top_k) try out.append(allocator, .{ .document_index = c.body_index, .filename_score = c.score, .filename_rank = rank + 1, .fused_score = c.score });
    } else {
        for (body.items[0..body_limit], 0..) |c, rank| try Order.merge(allocator, &out, body_docs, c, true, rank + 1);
        for (filename[0..fn_limit], 0..) |c, rank| if (c.score > 0) try Order.merge(allocator, &out, body_docs, c, false, rank + 1);
        std.mem.sort(filename_field.Hit, out.items, body_docs, Order.hitLess);
        out.items = out.items[0..@min(out.items.len, options.top_k)];
    }
    return out.toOwnedSlice(allocator);
}

test "S4-T2 R5: the linear filename query equals PR #21's query exactly, scoped and unscoped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Invented names and bodies: shared and rare words, several chunks per
    // file, a labelled folder, repeated query words, equal scores.
    const words = [_][]const u8{ "harbour", "tide", "ledger", "garden", "budget", "lantern", "orchard", "copper" };
    var documents = std.ArrayList(hybrid.Document).empty;
    for (0..240) |file| {
        const folder: []const u8 = switch (file % 3) {
            0 => "notes",
            1 => "school",
            else => "private",
        };
        const path = try std.fmt.allocPrint(a, "{s}/{s}_{s}_{d:0>3}.md", .{ folder, words[file % words.len], words[(file / 8) % words.len], file % 17 });
        const labels: []const u8 = if (file % 3 == 2) "family" else "";
        for (0..1 + file % 3) |chunk| {
            try documents.append(a, .{
                .id = try std.fmt.allocPrint(a, "c{d:0>4}-{d}", .{ file, chunk }),
                .path = path,
                .text = try std.fmt.allocPrint(a, "{s} {s} {s} note {d}", .{ words[(file + chunk) % words.len], words[(file * 3 + chunk) % words.len], if (chunk == 1) "tide" else "page", file % 5 }),
                .start_line = @intCast(1 + chunk * 10),
                .end_line = @intCast(9 + chunk * 10),
                .required_labels = labels,
            });
        }
    }
    // Paths repeat (file % 17 collides); keep one file's chunks per path.
    var unique = std.ArrayList(hybrid.Document).empty;
    var seen: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (documents.items) |doc| {
        const slot = try seen.getOrPut(a, doc.path);
        if (slot.found_existing and !std.mem.eql(u8, slot.value_ptr.*, doc.id[0..5])) continue;
        slot.value_ptr.* = doc.id[0..5];
        try unique.append(a, doc);
    }
    // Labelled (every query checks scope) and unlabelled (the unscoped
    // queries take the totals the load summed).
    const plain = try a.dupe(hybrid.Document, unique.items);
    for (plain) |*doc| doc.required_labels = "";
    const queries = [_][]const u8{ "harbour", "tide tide ledger", "budget garden 003", "lantern orchard copper harbour", "note", "absent", "copper 016", "page tide" };
    const scopes = [_]hybrid.SearchOptions{
        .{ .retrieval_mode = .lexical, .top_k = 5, .candidate_k = 10 },
        .{ .retrieval_mode = .lexical, .top_k = 20, .candidate_k = 20 },
        .{ .retrieval_mode = .lexical, .top_k = 3, .candidate_k = 100, .path_prefix = "school/" },
        .{ .retrieval_mode = .lexical, .top_k = 10, .candidate_k = 40, .principal_labels = &.{"family"} },
        .{ .retrieval_mode = .lexical, .top_k = 10, .candidate_k = 40, .path_prefix = "private/" },
    };
    var compared: usize = 0;
    for ([_][]const hybrid.Document{ unique.items, plain }) |body| {
        const built = try filename_field.build(a, body, analyzer_v2.analyzer_id);
        const body_index = try makeBodyIndex(a, body);
        const decoded = try filename_field.decode(a, body, body_index, built.catalog, built.lexical);
        try std.testing.expectEqual(body.ptr == unique.items.ptr, decoded.labeled);
        for (queries) |query| for (scopes) |options| for ([_]filename_field.Field{ .filename, .both }) |field| {
            const expected = try prQuery(a, body, body_index, decoded, query, field, options);
            const actual = try filename_field.queryDecoded(a, body, body_index, decoded, analyzer_v2.analyzer_id, query, field, options);
            try std.testing.expectEqual(expected.len, actual.len);
            for (expected, actual) |e, got| try std.testing.expectEqual(e, got);
            compared += expected.len;
        };
        // Root masks as the servers pass them: one root per folder, a mask
        // allowing every root (unscoped once the load knows every chunk's
        // root) and one hiding a root.
        const document_roots = try a.alloc(u16, body.len);
        for (body, document_roots) |doc, *root| root.* = if (std.mem.startsWith(u8, doc.path, "notes/")) 0 else if (std.mem.startsWith(u8, doc.path, "school/")) 1 else 2;
        var rooted = decoded;
        rooted.max_document_root = 2;
        for ([_][]const bool{ &.{ true, true, true }, &.{ true, false, true }, &.{ true, true } }) |allowed| for (queries) |query| for ([_]filename_field.Field{ .filename, .both }) |field| {
            const options = hybrid.SearchOptions{ .retrieval_mode = .lexical, .top_k = 10, .candidate_k = 40, .visible_roots = .{ .document_roots = document_roots, .allowed = allowed } };
            const expected = try prQuery(a, body, body_index, rooted, query, field, options);
            const actual = try filename_field.queryDecoded(a, body, body_index, rooted, analyzer_v2.analyzer_id, query, field, options);
            try std.testing.expectEqual(expected.len, actual.len);
            for (expected, actual) |e, got| try std.testing.expectEqual(e, got);
            compared += expected.len;
        };
    }
    try std.testing.expect(compared > 100);
}

// --- S4-T4 ruling 4: the writer's check and the sort skip ---

fn writerBody(a: std.mem.Allocator) ![]hybrid.Document {
    var list = std.ArrayList(hybrid.Document).empty;
    const names = [_][]const u8{ "docs/Annual_Budget_2026.md", "docs/annual-notes.txt", "garden/frog_spawn.md", "garden/frog_spawn.md", "school/week-07.md", "school/week-07.md", "school/week-07.md", "z/\u{e9}t\u{e9} notes.md" };
    for (names, 0..) |path, i| try list.append(a, .{
        .id = try std.fmt.allocPrint(a, "id-{d:0>3}", .{i}),
        .text = "body text",
        .path = path,
        .start_line = @intCast(1 + 10 * i),
        .end_line = @intCast(5 + 10 * i),
        .required_labels = if (std.mem.startsWith(u8, path, "school/")) "family" else "",
    });
    return list.toOwnedSlice(a);
}

test "S4-T4 R4: the writer's check accepts what build encoded, and the full re-tokenizing check agrees" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = try writerBody(a);
    const built = try filename_field.build(a, body, analyzer_v2.analyzer_id);
    try filename_field.validateBuilt(a, body, built);
    try filename_field.validate(a, body, built.catalog, built.lexical, analyzer_v2.analyzer_id);
    // Documents out of path order (a caller that does not sort): the sort
    // runs and the sections are byte-identical to the ordered input's.
    const shuffled = try a.dupe(hybrid.Document, body);
    std.mem.reverse(hybrid.Document, shuffled);
    const from_shuffled = try filename_field.build(a, shuffled, analyzer_v2.analyzer_id);
    try std.testing.expectEqualSlices(u8, built.catalog, from_shuffled.catalog);
    try std.testing.expectEqualSlices(u8, built.lexical, from_shuffled.lexical);
    try filename_field.validateBuilt(a, shuffled, from_shuffled);
}

test "S4-T4 R4: the writer's check refuses sections that differ from what build produced" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = try writerBody(a);
    const built = try filename_field.build(a, body, analyzer_v2.analyzer_id);
    // The structures differ from the bytes: one posting frequency, one
    // document length, one term, one anchor line.
    {
        const lexical = built.decoded_lexical.?;
        const posts = try a.dupe(postings.Posting, lexical.postings);
        posts[posts.len - 1].term_frequency += 1;
        var changed = built;
        changed.decoded_lexical.?.postings = posts;
        try std.testing.expectError(error.FilenameLexicalMismatch, filename_field.validateBuilt(a, body, changed));
    }
    {
        const lengths = try a.dupe(u32, built.decoded_lexical.?.document_lengths);
        lengths[0] += 1;
        var changed = built;
        changed.decoded_lexical.?.document_lengths = lengths;
        try std.testing.expectError(error.FilenameLexicalMismatch, filename_field.validateBuilt(a, body, changed));
    }
    {
        const terms = try a.dupe(postings.TermEntry, built.decoded_lexical.?.terms);
        terms[0].term = "zzzz";
        var changed = built;
        changed.decoded_lexical.?.terms = terms;
        try std.testing.expectError(error.FilenameLexicalMismatch, filename_field.validateBuilt(a, body, changed));
    }
    {
        const catalog = try a.dupe(hybrid.Document, built.decoded_catalog);
        catalog[1].start_line += 1;
        var changed = built;
        changed.decoded_catalog = catalog;
        try std.testing.expectError(error.FilenameCatalogMismatch, filename_field.validateBuilt(a, body, changed));
    }
    {
        var changed = built;
        changed.decoded_lexical = null;
        try std.testing.expectError(error.FilenameLexicalMismatch, filename_field.validateBuilt(a, body, changed));
    }
    // A damaged section is refused by the decode it starts with.
    const damaged = try a.dupe(u8, built.lexical);
    damaged[damaged.len - 1] ^= 0x01;
    var changed = built;
    changed.lexical = damaged;
    try std.testing.expect(std.meta.isError(filename_field.validateBuilt(a, body, changed)));
}
