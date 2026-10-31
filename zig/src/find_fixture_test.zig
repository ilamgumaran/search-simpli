//! S3-T2 ruling 4: `find` (words, phrase, prefix) end to end.
//!
//! Over the frozen family-folder fixture (`fixtures/family-folder/`, S3-T7)
//! the three roots are copied side by side into one folder (so a document
//! path is `root_id/relative`, the shape S3-T3's roots give it) and indexed
//! with `indexer.indexFolder` (HYBLEX02). Every phrase and prefix judgment is
//! paged through to the end (page size 2, so the cursor is exercised) and
//! must reach precision and recall 1.00 after overlap deduplication; the
//! judgments' `expected_engine_miss` entries (the chunk-local phrase that
//! straddles a window edge, the front-matter prefix line) must be missed.
//! Smaller folders cover repeated tokens, punctuation, Unicode, an empty
//! query, the expansion cap, the scope, cursors, ordering, deduplication,
//! offsets, snippets and a HYBLEX01 generation.
const std = @import("std");
const analyzer_v2 = @import("analyzer_v2.zig");
const chunker = @import("chunker.zig");
const engine_module = @import("engine.zig");
const find = @import("find.zig");
const hybrid = @import("hybrid.zig");
const importer = @import("importer.zig");
const indexer = @import("indexer.zig");
const lexical_build = @import("lexical_build.zig");
const lexical_segment = @import("lexical_segment.zig");
const manifest = @import("manifest.zig");
const snapshot_open = @import("snapshot_open.zig");

const pack = "../fixtures/family-folder";
const root_ids = [_][]const u8{ "home", "laptop", "school" };

fn readAll(arena: std.mem.Allocator, dir: std.Io.Dir, path: []const u8) ![]u8 {
    const io = std.testing.io;
    const stat = try dir.statFile(io, path, .{});
    const buffer = try arena.alloc(u8, std.math.cast(usize, stat.size) orelse return error.FileTooBig);
    return dir.readFile(io, path, buffer);
}

/// Copy `from` (recursively, files only) into `to`.
fn copyTree(arena: std.mem.Allocator, from: std.Io.Dir, to: std.Io.Dir) !void {
    const io = std.testing.io;
    var walker = try from.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .directory => try to.createDirPath(io, entry.path),
            .file => try to.writeFile(io, .{ .sub_path = entry.path, .data = try readAll(arena, from, entry.path) }),
            else => {},
        }
    }
}

const Indexed = struct {
    engine: engine_module.Engine,
    judgments: std.json.ObjectMap,
};

fn indexPack(arena: std.mem.Allocator, tmp: std.Io.Dir) !Indexed {
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const judgments = (try std.json.parseFromSliceLeaky(std.json.Value, arena, try readAll(arena, cwd, pack ++ "/judgments.json"), .{})).object;
    try tmp.createDir(io, "union", .default_dir);
    try tmp.createDir(io, "out", .default_dir);
    var union_dir = try tmp.openDir(io, "union", .{ .iterate = true });
    defer union_dir.close(io);
    for (root_ids) |root_id| {
        try union_dir.createDir(io, root_id, .default_dir);
        var to = try union_dir.openDir(io, root_id, .{});
        defer to.close(io);
        var from = try cwd.openDir(io, try std.fmt.allocPrint(arena, "{s}/{s}", .{ pack, root_id }), .{ .iterate = true });
        defer from.close(io);
        try copyTree(arena, from, to);
    }
    var out = try tmp.openDir(io, "out", .{ .iterate = true });
    defer out.close(io);
    const report = try indexer.indexFolder(arena, io, union_dir, out, .v2, 1, chunker.default_max_chars, chunker.default_overlap_lines, .{});
    try std.testing.expectEqual(@as(usize, 0), report.unreadable);
    return .{ .engine = try snapshot_open.open(arena, io, out), .judgments = judgments };
}

const Expected = struct { root_id: []const u8, path: []const u8, start_line: u32, end_line: u32 };

fn expectedList(arena: std.mem.Allocator, value: ?std.json.Value) ![]Expected {
    const items = if (value) |present| present.array.items else return &.{};
    const list = try arena.alloc(Expected, items.len);
    for (items, list) |item, *slot| slot.* = .{
        .root_id = item.object.get("root_id").?.string,
        .path = item.object.get("path").?.string,
        .start_line = @intCast(item.object.get("start_line").?.integer),
        .end_line = @intCast(item.object.get("end_line").?.integer),
    };
    return list;
}

fn overlaps(hit: find.Hit, expected: Expected) bool {
    return std.mem.eql(u8, hit.root_id, expected.root_id) and std.mem.eql(u8, hit.path, expected.path) and
        hit.start_line <= expected.end_line and expected.start_line <= hit.end_line;
}

/// Every hit of `query`, paging with `page_size` until `next_cursor` is null.
fn allPages(arena: std.mem.Allocator, engine: engine_module.Engine, request: find.Request) ![]find.Hit {
    var hits = std.ArrayList(find.Hit).empty;
    var current = request;
    var total: ?usize = null;
    var pages: usize = 0;
    while (true) {
        const answer = (try find.find(arena, engine, current)).ok;
        if (total) |value| try std.testing.expectEqual(value, answer.total_hits) else total = answer.total_hits;
        try std.testing.expectEqual(answer.hits.len == 0, answer.empty);
        try std.testing.expect(answer.hits.len <= current.page_size);
        try hits.appendSlice(arena, answer.hits);
        pages += 1;
        current.cursor = answer.next_cursor orelse break;
    }
    try std.testing.expectEqual(total.?, hits.items.len);
    return hits.items;
}

/// Each `match_offsets` range covers exactly the matched tokens: the
/// analyzed text of the range is the phrase (phrase), one query term
/// (words), or an earlier term or one token starting with the prefix
/// (prefix); the snippet is a substring of `content` of at most 240
/// codepoints whose offsets are matches shifted by its start.
fn expectOffsetsExact(arena: std.mem.Allocator, hit: find.Hit, mode: find.Mode, query_tokens: []const []const u8) !void {
    try std.testing.expect(hit.match_offsets.len > 0);
    for (hit.match_offsets) |range| {
        const text = codepoints(hit.content, range[0], range[1]);
        const tokens = try analyzer_v2.tokenize(arena, text);
        switch (mode) {
            .phrase => {
                try std.testing.expectEqual(query_tokens.len, tokens.len);
                for (query_tokens, tokens) |want, got| try std.testing.expectEqualStrings(want, got);
            },
            .words => {
                try std.testing.expectEqual(@as(usize, 1), tokens.len);
                var found = false;
                for (query_tokens) |want| found = found or std.mem.eql(u8, want, tokens[0]);
                try std.testing.expect(found);
            },
            .prefix => {
                try std.testing.expectEqual(@as(usize, 1), tokens.len);
                var found = std.mem.startsWith(u8, tokens[0], query_tokens[query_tokens.len - 1]);
                for (query_tokens[0 .. query_tokens.len - 1]) |want| found = found or std.mem.eql(u8, want, tokens[0]);
                try std.testing.expect(found);
            },
        }
        // The range is exactly the token(s): no letter or digit just outside.
        if (range[0] > 0) try std.testing.expectEqual(@as(usize, 0), (try analyzer_v2.tokenize(arena, codepoints(hit.content, range[0] - 1, range[0] + 1))).len -| 1);
    }
    const snippet_length: u32 = @intCast(std.unicode.utf8CountCodepoints(hit.snippet) catch unreachable);
    try std.testing.expect(snippet_length <= find.max_snippet_codepoints);
    try std.testing.expectEqualStrings(codepoints(hit.content, hit.snippet_start, hit.snippet_start + snippet_length), hit.snippet);
    try std.testing.expect(hit.snippet_offsets.len > 0);
    for (hit.snippet_offsets) |range| {
        var found = false;
        for (hit.match_offsets) |match| found = found or (match[0] == range[0] + hit.snippet_start and match[1] == range[1] + hit.snippet_start);
        try std.testing.expect(found);
    }
}

fn codepoints(text: []const u8, start: u32, end: u32) []const u8 {
    var index: u32 = 0;
    var start_byte: usize = text.len;
    var end_byte: usize = text.len;
    for (text, 0..) |byte, at| {
        if (byte & 0xC0 == 0x80) continue;
        if (index == start) start_byte = at;
        if (index == end) {
            end_byte = at;
            break;
        }
        index += 1;
    }
    return text[@min(start_byte, end_byte)..end_byte];
}

const CaseResult = struct { hits: usize, precision: f64, recall: f64 };

fn judgeCase(arena: std.mem.Allocator, engine: engine_module.Engine, case: std.json.ObjectMap, page_size: usize) !CaseResult {
    const query = case.get("query").?.string;
    const mode = find.Mode.parse(case.get("mode").?.string).?;
    const expected = try expectedList(arena, case.get("expected"));
    const misses = try expectedList(arena, case.get("expected_engine_miss"));
    const hits = try allPages(arena, engine, .{ .query = query, .mode = mode, .page_size = page_size, .root_ids = &root_ids });

    var tokens = try analyzer_v2.tokenize(arena, query);
    _ = &tokens;
    var relevant: usize = 0;
    for (hits) |hit| {
        try expectOffsetsExact(arena, hit, mode, tokens);
        var matched = false;
        for (expected) |entry| matched = matched or overlaps(hit, entry);
        if (matched) relevant += 1 else std.debug.print("S3-T2 {s}: unexpected hit {s}/{s}:{d}-{d}\n", .{ case.get("id").?.string, hit.root_id, hit.path, hit.start_line, hit.end_line });
        for (misses) |entry| {
            if (overlaps(hit, entry)) std.debug.print("S3-T2 {s}: the expected miss {s}:{d} was found\n", .{ case.get("id").?.string, entry.path, entry.start_line });
            try std.testing.expect(!overlaps(hit, entry));
        }
    }
    var wanted: usize = 0;
    var covered: usize = 0;
    outer: for (expected) |entry| {
        for (misses) |miss| {
            if (std.mem.eql(u8, miss.path, entry.path) and miss.start_line == entry.start_line) continue :outer;
        }
        wanted += 1;
        var found = false;
        for (hits) |hit| found = found or overlaps(hit, entry);
        if (found) covered += 1 else std.debug.print("S3-T2 {s}: missed {s}/{s}:{d}\n", .{ case.get("id").?.string, entry.root_id, entry.path, entry.start_line });
    }
    return .{
        .hits = hits.len,
        .precision = if (hits.len == 0) 1.0 else @as(f64, @floatFromInt(relevant)) / @as(f64, @floatFromInt(hits.len)),
        .recall = if (wanted == 0) 1.0 else @as(f64, @floatFromInt(covered)) / @as(f64, @floatFromInt(wanted)),
    };
}

test "S3-T2: phrase and prefix judgments reach precision and recall 1.00 across all pages; the listed misses are missed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const indexed = try indexPack(arena, tmp.dir);
    const engine = indexed.engine;
    try std.testing.expect(engine.lexical_index.positions != null);

    var cases: usize = 0;
    inline for (.{ "phrase", "prefix" }) |kind| {
        for (indexed.judgments.get(kind).?.array.items) |case_value| {
            const case = case_value.object;
            inline for (.{ 2, 100 }) |page_size| {
                const result = try judgeCase(arena, engine, case, page_size);
                const deduplicated = (try find.find(arena, engine, .{ .query = case.get("query").?.string, .mode = find.Mode.parse(case.get("mode").?.string).?, .root_ids = &root_ids })).ok.deduplicated;
                std.debug.print("S3-T2 {s} page {d}: {d} hits ({d} deduplicated), precision {d:.2}, recall {d:.2}\n", .{ case.get("id").?.string, page_size, result.hits, deduplicated, result.precision, result.recall });
                try std.testing.expectEqual(@as(f64, 1.0), result.precision);
                try std.testing.expectEqual(@as(f64, 1.0), result.recall);
            }
            cases += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 10), cases);

    // p3 is the chunk-local miss: no chunk holds the whole phrase.
    const p3 = (try find.find(arena, engine, .{ .query = "round the old mill pond", .mode = .phrase, .root_ids = &root_ids })).ok;
    try std.testing.expectEqual(@as(usize, 0), p3.total_hits);
    try std.testing.expectEqual(false, p3.exact_match.?);
    try std.testing.expect(p3.empty);
    // ... nor all five words (words mode is chunk-local too), while
    // search_knowledge (disjunctive) still ranks the chant.
    const p3_words = (try find.find(arena, engine, .{ .query = "round the old mill pond", .mode = .words, .root_ids = &root_ids })).ok;
    try std.testing.expectEqual(@as(usize, 0), p3_words.total_hits);
    try std.testing.expect(p3_words.exact_match == null);
    const p3_results = try arena.alloc(hybrid.Result, 5);
    const p3_ranked = try engine.queryTokenized(arena, "round the old mill pond", &.{}, p3_results, .{ .top_k = 5, .retrieval_mode = .lexical });
    var chant_ranked = false;
    for (p3_ranked) |result| chant_ranked = chant_ranked or std.mem.eql(u8, result.path, "school/clapping-chant.txt");
    try std.testing.expect(chant_ranked);

    // The scenarios that name a phrase or prefix (2, 3, 10) and the newt.
    const dough = try allPages(arena, engine, .{ .query = "\"the dough rests\"", .root_ids = &root_ids });
    try std.testing.expectEqual(@as(usize, 1), dough.len);
    try std.testing.expectEqualStrings("recipes/bread.md", dough[0].path);
    try std.testing.expect(dough[0].start_line <= 19 and dough[0].end_line >= 19);
    try std.testing.expectEqualStrings("Weekend bread", dough[0].section_path[0]);
    try std.testing.expectEqualStrings("Method", dough[0].section_path[1]);
    const newt = (try find.find(arena, engine, .{ .query = "newts", .root_ids = &root_ids })).ok;
    try std.testing.expect(newt.empty);
    try std.testing.expectEqual(@as(usize, 0), newt.coverage.files);

    // Words recall@5: the `words` scenario through `find` words mode, the
    // `answer` scenarios (a model's question, not every word present)
    // through `search_knowledge`, as the pack runner does.
    var recall_sum: f64 = 0;
    var recall_cases: usize = 0;
    for (indexed.judgments.get("scenarios").?.array.items) |scenario_value| {
        const scenario = scenario_value.object;
        const kind = scenario.get("kind").?.string;
        if (!std.mem.eql(u8, kind, "words") and !std.mem.eql(u8, kind, "answer")) continue;
        const expected = try expectedList(arena, scenario.get("expected"));
        const query = scenario.get("query").?.string;
        var covered: usize = 0;
        if (std.mem.eql(u8, kind, "words")) {
            const answer = (try find.find(arena, engine, .{ .query = query, .page_size = 5, .root_ids = &root_ids })).ok;
            for (expected) |entry| {
                var found = false;
                for (answer.hits) |hit| found = found or overlaps(hit, entry);
                covered += @intFromBool(found);
            }
        } else {
            const results = try arena.alloc(hybrid.Result, 5);
            const ranked = try engine.queryTokenized(arena, query, &.{}, results, .{ .top_k = 5, .retrieval_mode = .lexical });
            for (expected) |entry| {
                var found = false;
                for (ranked) |result| {
                    const split = find.splitRoot(result.path, &root_ids);
                    found = found or (std.mem.eql(u8, split.root_id, entry.root_id) and std.mem.eql(u8, split.path, entry.path) and
                        result.start_line <= entry.end_line and entry.start_line <= result.end_line);
                }
                covered += @intFromBool(found);
            }
        }
        const recall = @as(f64, @floatFromInt(covered)) / @as(f64, @floatFromInt(expected.len));
        std.debug.print("S3-T2 {s} ({s}): recall@5 {d:.2}\n", .{ scenario.get("id").?.string, kind, recall });
        recall_sum += recall;
        recall_cases += 1;
    }
    const words_recall = recall_sum / @as(f64, @floatFromInt(recall_cases));
    std.debug.print("S3-T2 words recall@5 over {d} cases: {d:.3}\n", .{ recall_cases, words_recall });
    try std.testing.expect(words_recall >= 0.9);

    // Offsets from section 5 equal offsets recomputed by re-tokenizing (the
    // rollback path), hit for hit.
    for ([_][]const u8{ "\"count me in\"", "photosyn*", "tide table", "\"பள்ளி விடுமுறை\"" }) |query| {
        const stored = (try find.find(arena, engine, .{ .query = query, .page_size = 100, .root_ids = &root_ids })).ok;
        const recomputed = (try find.find(arena, engine, .{ .query = query, .page_size = 100, .root_ids = &root_ids, .recompute_offsets = true })).ok;
        try std.testing.expectEqual(stored.hits.len, recomputed.hits.len);
        for (stored.hits, recomputed.hits) |left, right| {
            try std.testing.expectEqualStrings(left.chunk_id, right.chunk_id);
            try std.testing.expectEqualSlices(find.Range, left.match_offsets, right.match_offsets);
            try std.testing.expectEqualStrings(left.snippet, right.snippet);
        }
    }

    // Words hits score exactly what search_knowledge scores them.
    const words = (try find.find(arena, engine, .{ .query = "tide table", .page_size = 100, .root_ids = &root_ids })).ok;
    const results = try arena.alloc(hybrid.Result, engine.documents.len);
    const ranked = try engine.queryTokenized(arena, "tide table", &.{}, results, .{ .top_k = engine.documents.len, .candidate_k = engine.documents.len, .retrieval_mode = .lexical });
    for (words.hits) |hit| {
        var found = false;
        for (ranked) |result| {
            if (result.document_index == hit.document_index) {
                try std.testing.expectEqual(result.lexical_score, hit.score);
                found = true;
            }
        }
        try std.testing.expect(found);
    }

    // Deterministic: the same request gives the same answer.
    const first = (try find.find(arena, engine, .{ .query = "spell*", .page_size = 100, .root_ids = &root_ids })).ok;
    const second = (try find.find(arena, engine, .{ .query = "spell*", .page_size = 100, .root_ids = &root_ids })).ok;
    try std.testing.expectEqual(first.hits.len, second.hits.len);
    for (first.hits, second.hits) |left, right| try std.testing.expectEqualStrings(left.chunk_id, right.chunk_id);
    try std.testing.expectEqual(@as(?bool, null), first.exact_match);
}

const Folder = struct {
    tmp: std.testing.TmpDir,
    engine: engine_module.Engine,

    fn deinit(folder: *Folder) void {
        folder.tmp.cleanup();
    }
};

const FileSpec = struct { path: []const u8, data: []const u8 };

fn indexFiles(arena: std.mem.Allocator, files: []const FileSpec) !Folder {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    errdefer tmp.cleanup();
    try tmp.dir.createDir(io, "root", .default_dir);
    try tmp.dir.createDir(io, "out", .default_dir);
    var root = try tmp.dir.openDir(io, "root", .{ .iterate = true });
    defer root.close(io);
    var out = try tmp.dir.openDir(io, "out", .{ .iterate = true });
    defer out.close(io);
    for (files) |file| {
        if (std.fs.path.dirname(file.path)) |parent| try root.createDirPath(io, parent);
        try root.writeFile(io, .{ .sub_path = file.path, .data = file.data });
    }
    _ = try indexer.indexFolder(arena, io, root, out, .v2, 1, chunker.default_max_chars, chunker.default_overlap_lines, .{});
    return .{ .tmp = tmp, .engine = try snapshot_open.open(arena, io, out) };
}

fn expectFailure(outcome: find.Outcome, code: @import("source.zig").Code, message: ?[]const u8) !void {
    switch (outcome) {
        .ok => return error.TestExpectedFailure,
        .failed => |failure| {
            try std.testing.expectEqual(code, failure.code);
            if (message) |want| try std.testing.expectEqualStrings(want, failure.message);
        },
    }
}

test "S3-T2: phrase handles repeated tokens, punctuation inside the phrase and Tamil; quotes force phrase" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var folder = try indexFiles(arena, &.{
        .{ .path = "a.txt", .data = "the the the\n" },
        .{ .path = "b.txt", .data = "the the the the\n" },
        .{ .path = "c.txt", .data = "the cat the\n" },
        .{ .path = "d.txt", .data = "Yes: count, me... in! And COUNT me IN.\n" },
        .{ .path = "e.txt", .data = "பள்ளி விடுமுறை நாளை. விடுமுறை பள்ளி\n" },
        .{ .path = "f.txt", .data = "me count in\n" },
    });
    defer folder.deinit();
    const engine = folder.engine;

    const repeated = (try find.find(arena, engine, .{ .query = "the the", .mode = .phrase, .page_size = 100 })).ok;
    try std.testing.expectEqual(@as(usize, 2), repeated.hits.len);
    for (repeated.hits) |hit| {
        // Non-overlapping occurrences, left to right: "the the the" holds one,
        // "the the the the" two.
        const want: usize = if (std.mem.eql(u8, hit.path, "a.txt")) 1 else 2;
        try std.testing.expectEqual(want, hit.match_offsets.len);
        try std.testing.expectEqual(find.Range{ 0, 7 }, hit.match_offsets[0]);
    }
    const tokens_the = try analyzer_v2.tokenize(arena, "the the");
    for (repeated.hits) |hit| try expectOffsetsExact(arena, hit, .phrase, tokens_the);

    // Punctuation inside the phrase, in the text and in the query, is not a token.
    const punctuated = (try find.find(arena, engine, .{ .query = "\"count -- me, in\"", .page_size = 100 })).ok;
    try std.testing.expectEqual(find.Mode.phrase, punctuated.mode);
    try std.testing.expectEqual(@as(usize, 1), punctuated.hits.len);
    try std.testing.expectEqualStrings("d.txt", punctuated.hits[0].path);
    try std.testing.expectEqual(@as(usize, 2), punctuated.hits[0].match_offsets.len);
    try std.testing.expectEqual(find.Range{ 5, 20 }, punctuated.hits[0].match_offsets[0]);
    try std.testing.expectEqual(find.Range{ 26, 37 }, punctuated.hits[0].match_offsets[1]);
    // Out of order is not a phrase; words mode still finds both orders.
    const words = (try find.find(arena, engine, .{ .query = "count me in", .page_size = 100 })).ok;
    try std.testing.expectEqual(@as(usize, 2), words.hits.len);
    try std.testing.expectEqual(@as(?bool, null), words.exact_match);

    const tamil = (try find.find(arena, engine, .{ .query = "\"பள்ளி விடுமுறை\"", .page_size = 100 })).ok;
    try std.testing.expectEqual(@as(usize, 1), tamil.hits.len);
    try std.testing.expectEqual(@as(usize, 1), tamil.hits[0].match_offsets.len);
    try std.testing.expectEqual(find.Range{ 0, 14 }, tamil.hits[0].match_offsets[0]);
    try expectOffsetsExact(arena, tamil.hits[0], .phrase, try analyzer_v2.tokenize(arena, "பள்ளி விடுமுறை"));
    const tamil_prefix = (try find.find(arena, engine, .{ .query = "விடு*", .page_size = 100 })).ok;
    try std.testing.expectEqual(@as(usize, 1), tamil_prefix.hits.len);
    try std.testing.expectEqual(@as(usize, 2), tamil_prefix.hits[0].match_offsets.len);
}

test "S3-T2: empty queries, a stray star, page size and cursors are INVALID_ARGUMENT; a stale cursor says so" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var folder = try indexFiles(arena, &.{
        .{ .path = "a.txt", .data = "alpha beta gamma\n" },
        .{ .path = "b.txt", .data = "alpha beta\n" },
        .{ .path = "c.txt", .data = "alpha\n" },
    });
    defer folder.deinit();
    const engine = folder.engine;
    for ([_][]const u8{ "", "   ", "!!! ...", "*", "\"\"", "\" \"" }) |query| {
        inline for (.{ find.Mode.words, find.Mode.phrase, find.Mode.prefix }) |mode| {
            try expectFailure(try find.find(arena, engine, .{ .query = query, .mode = mode }), .invalid_argument, "empty query");
        }
    }
    try expectFailure(try find.find(arena, engine, .{ .query = "al* beta" }), .invalid_argument, "only the last token may end in *");
    try expectFailure(try find.find(arena, engine, .{ .query = "al*be*" }), .invalid_argument, null);
    try expectFailure(try find.find(arena, engine, .{ .query = "alpha", .page_size = 0 }), .invalid_argument, null);
    try expectFailure(try find.find(arena, engine, .{ .query = "alpha", .page_size = 101 }), .invalid_argument, null);
    try expectFailure(try find.find(arena, engine, .{ .query = "\xff" }), .invalid_argument, null);

    const first = (try find.find(arena, engine, .{ .query = "alpha", .page_size = 2 })).ok;
    try std.testing.expectEqual(@as(usize, 3), first.total_hits);
    try std.testing.expectEqualStrings("1:2", first.next_cursor.?);
    const second = (try find.find(arena, engine, .{ .query = "alpha", .page_size = 2, .cursor = first.next_cursor })).ok;
    try std.testing.expectEqual(@as(usize, 1), second.hits.len);
    try std.testing.expect(second.next_cursor == null);
    const past = (try find.find(arena, engine, .{ .query = "alpha", .page_size = 2, .cursor = "1:9" })).ok;
    try std.testing.expect(past.empty);
    try std.testing.expectEqual(@as(usize, 0), past.coverage.files);

    try expectFailure(try find.find(arena, engine, .{ .query = "alpha", .cursor = "2:2" }), .invalid_argument, "stale cursor");
    try expectFailure(try find.find(arena, engine, .{ .query = "alpha", .cursor = "0:0" }), .invalid_argument, "stale cursor");
    for ([_][]const u8{ "", "1", "1:", ":2", "x:2", "1:-1", "1:2:3" }) |cursor| {
        try expectFailure(try find.find(arena, engine, .{ .query = "alpha", .cursor = cursor }), .invalid_argument, "malformed cursor");
    }
}

test "S3-T2: prefix expands over the visible vocabulary only, at most 1,000 terms, else CAPACITY" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // 1,000 distinct "zq..." terms in public/, one more in hidden/.
    var public_text = std.ArrayList(u8).empty;
    for (0..1000) |i| try public_text.print(arena, "zq{d:0>4} {s}", .{ i, if (i % 10 == 9) "\n" else "" });
    var folder = try indexFiles(arena, &.{
        .{ .path = "public/terms.txt", .data = public_text.items },
        .{ .path = "hidden/extra.txt", .data = "zq9999 zebra\n" },
    });
    defer folder.deinit();
    const engine = folder.engine;

    try expectFailure(try find.find(arena, engine, .{ .query = "zq*" }), .capacity, "prefix \"zq\" expands to more than 1000 terms");
    // The hidden file's term is not visible under the scope: exactly 1,000.
    const scoped = (try find.find(arena, engine, .{ .query = "zq*", .path_prefix = "public/", .page_size = 100 })).ok;
    try std.testing.expect(scoped.total_hits > 0);
    for (scoped.hits) |hit| try std.testing.expect(std.mem.startsWith(u8, hit.path, "public/"));
    // A narrower prefix is fine everywhere, and only visible terms match.
    const narrow = (try find.find(arena, engine, .{ .query = "zq99*", .page_size = 100 })).ok;
    var saw_hidden = false;
    for (narrow.hits) |hit| saw_hidden = saw_hidden or std.mem.startsWith(u8, hit.path, "hidden/");
    try std.testing.expect(saw_hidden);
    const narrow_scoped = (try find.find(arena, engine, .{ .query = "zq99*", .path_prefix = "public/", .page_size = 100 })).ok;
    for (narrow_scoped.hits) |hit| try std.testing.expect(std.mem.startsWith(u8, hit.path, "public/"));
    // A term only in hidden documents does not expand at all under the scope.
    const hidden_only = (try find.find(arena, engine, .{ .query = "zeb*", .path_prefix = "public/" })).ok;
    try std.testing.expect(hidden_only.empty);
    // Earlier terms are required literally.
    const earlier = (try find.find(arena, engine, .{ .query = "zebra zq99*", .page_size = 100 })).ok;
    try std.testing.expectEqual(@as(usize, 1), earlier.hits.len);
    try std.testing.expectEqualStrings("hidden/extra.txt", earlier.hits[0].path);
    try std.testing.expectEqual(@as(usize, 2), earlier.hits[0].match_offsets.len);
    const prefix_tokens = try analyzer_v2.tokenize(arena, "zebra zq99");
    try expectOffsetsExact(arena, earlier.hits[0], .prefix, prefix_tokens);
}

test "S3-T2: ordering is score desc, then root_id, path, start_line; files and coverage count hits" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var folder = try indexFiles(arena, &.{
        .{ .path = "school/b.md", .data = "# Notes\n\nlantern festival\n" },
        .{ .path = "home/z.md", .data = "# Notes\n\nlantern festival\n" },
        .{ .path = "school/a.md", .data = "# Notes\n\nlantern festival\n" },
        .{ .path = "home/a.md", .data = "# Notes\n\nlantern festival\n" },
        .{ .path = "home/long.md", .data = "# Notes\n\nlantern festival lantern lantern festival again and again and again\n" },
    });
    defer folder.deinit();
    const ids = [_][]const u8{ "home", "school" };
    const answer = (try find.find(arena, folder.engine, .{ .query = "\"lantern festival\"", .page_size = 100, .root_ids = &ids })).ok;
    try std.testing.expectEqual(@as(usize, 5), answer.hits.len);
    const order = [_][2][]const u8{ .{ "home", "a.md" }, .{ "home", "z.md" }, .{ "school", "a.md" }, .{ "school", "b.md" } };
    var equal_scored: usize = 0;
    for (answer.hits) |hit| {
        if (std.mem.eql(u8, hit.path, "long.md")) continue;
        try std.testing.expectEqualStrings(order[equal_scored][0], hit.root_id);
        try std.testing.expectEqualStrings(order[equal_scored][1], hit.path);
        equal_scored += 1;
    }
    for (answer.hits[1..], 1..) |hit, i| try std.testing.expect(answer.hits[i - 1].score >= hit.score);
    try std.testing.expectEqual(@as(usize, 5), answer.files.len);
    try std.testing.expectEqual(@as(usize, 5), answer.coverage.files);
    try std.testing.expectEqual(@as(usize, 5), answer.coverage.sections);
    try std.testing.expectEqual(@as(usize, 1), answer.hits[0].section_path.len);
}

test "S3-T2: overlapping windows that show the same occurrence are deduplicated to the earlier chunk" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // 40 lines of 79 characters: windows of 20 lines overlapping by 3.
    var text = std.ArrayList(u8).empty;
    for (0..40) |line| {
        const words = switch (line) {
            19 => "the harbour light is green tonight",
            25 => "a harbour light again further down",
            else => "filler words here",
        };
        try text.print(arena, "{s:<78}\n", .{words});
    }
    var folder = try indexFiles(arena, &.{.{ .path = "log.txt", .data = text.items }});
    defer folder.deinit();
    const engine = folder.engine;
    try std.testing.expect(engine.documents.len >= 2);
    try std.testing.expect(engine.documents[0].end_line >= engine.documents[1].start_line);

    const answer = (try find.find(arena, engine, .{ .query = "\"harbour light\"", .page_size = 100 })).ok;
    // Line 20 is in both windows; line 26 only in the second. The second
    // chunk is kept for line 26, the first for line 20: two hits.
    try std.testing.expectEqual(@as(usize, 2), answer.hits.len);
    const only_shared = (try find.find(arena, engine, .{ .query = "\"green tonight\"", .page_size = 100 })).ok;
    try std.testing.expectEqual(@as(usize, 1), only_shared.hits.len);
    try std.testing.expectEqual(engine.documents[0].start_line, only_shared.hits[0].start_line);
    const words = (try find.find(arena, engine, .{ .query = "green tonight", .page_size = 100 })).ok;
    try std.testing.expectEqual(@as(usize, 1), words.hits.len);
    const prefix = (try find.find(arena, engine, .{ .query = "tonig*", .page_size = 100 })).ok;
    try std.testing.expectEqual(@as(usize, 1), prefix.hits.len);
    // Without overlap nothing is dropped.
    const further = (try find.find(arena, engine, .{ .query = "\"further down\"", .page_size = 100 })).ok;
    try std.testing.expectEqual(@as(usize, 1), further.hits.len);
}

test "S3-T2: snippets are at most 240 codepoints around the best window, cut at token boundaries" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var text = std.ArrayList(u8).empty;
    for (0..30) |i| try text.print(arena, "padding{d} ", .{i});
    try text.appendSlice(arena, "kestrel ");
    for (0..20) |i| try text.print(arena, "middle{d} ", .{i});
    try text.appendSlice(arena, "kestrel osprey kestrel ");
    for (0..30) |i| try text.print(arena, "tail{d} ", .{i});
    var folder = try indexFiles(arena, &.{.{ .path = "birds.txt", .data = text.items }});
    defer folder.deinit();
    const answer = (try find.find(arena, folder.engine, .{ .query = "kestrel osprey" })).ok;
    try std.testing.expectEqual(@as(usize, 1), answer.hits.len);
    const hit = answer.hits[0];
    try std.testing.expectEqual(@as(usize, 4), hit.match_offsets.len);
    try expectOffsetsExact(arena, hit, .words, try analyzer_v2.tokenize(arena, "kestrel osprey"));
    // The best window holds both terms (the second "kestrel osprey kestrel").
    try std.testing.expect(std.mem.indexOf(u8, hit.snippet, "kestrel osprey kestrel") != null);
    // Cut at token boundaries: no partial word at either end.
    try std.testing.expect(hit.snippet[0] != ' ' and hit.snippet[hit.snippet.len - 1] != ' ');
    const before = codepoints(hit.content, hit.snippet_start -| 1, hit.snippet_start);
    try std.testing.expect(hit.snippet_start == 0 or std.mem.eql(u8, before, " "));
    const length: u32 = @intCast(try std.unicode.utf8CountCodepoints(hit.snippet));
    try std.testing.expect(length <= 240 and length > 200);
    const after = codepoints(hit.content, hit.snippet_start + length, hit.snippet_start + length + 1);
    try std.testing.expect(after.len == 0 or std.mem.eql(u8, after, " "));
}

test "S3-T2: a HYBLEX01 generation answers phrase with CAPACITY; words and prefix still work" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const json =
        \\{"format_version":1,"generation":3,"analyzer_id":"analyzer-v2","embedding_model_id":"none","documents":[
        \\{"id":"a","path":"a.md","start_line":1,"end_line":1,"text":"Count me in for the Lantern walk","vector":[]},
        \\{"id":"b","path":"b.md","start_line":1,"end_line":1,"text":"lanterns and lamps","vector":[]}]}
    ;
    _ = try importer.importJson(tmp.dir, io, arena, json);
    const engine = try snapshot_open.open(arena, io, tmp.dir);
    try std.testing.expect(engine.lexical_index.positions == null);
    try expectFailure(try find.find(arena, engine, .{ .query = "count me in", .mode = .phrase }), .capacity, "re-index required: positions absent");
    try expectFailure(try find.find(arena, engine, .{ .query = "\"count me in\"" }), .capacity, "re-index required: positions absent");
    const words = (try find.find(arena, engine, .{ .query = "count lantern" })).ok;
    try std.testing.expectEqual(@as(usize, 1), words.hits.len);
    try std.testing.expectEqual(find.Range{ 0, 5 }, words.hits[0].match_offsets[0]);
    try std.testing.expectEqual(find.Range{ 20, 27 }, words.hits[0].match_offsets[1]);
    const prefix = (try find.find(arena, engine, .{ .query = "lan*", .page_size = 100 })).ok;
    try std.testing.expectEqual(@as(usize, 2), prefix.hits.len);
    try std.testing.expectEqualStrings("3:1", (try find.find(arena, engine, .{ .query = "lan*", .page_size = 1 })).ok.next_cursor.?);
}

test "S3-T2: a v1 manifest cannot bind HYBLEX02; a v2 manifest's flag follows the section" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const segment = @import("segment.zig");
    const documents = [_]hybrid.Document{.{ .id = "a", .text = "one two", .path = "a.md", .start_line = 1, .end_line = 1 }};
    const lists = [_][]const @import("analysis.zig").PositionedToken{try analyzer_v2.tokenizePositioned(arena, documents[0].text)};
    const index = try lexical_build.buildPositional(arena, &documents, &lists);
    const lexical = try lexical_segment.encode(index, try arena.alloc(u8, try lexical_segment.encodedLength(index)));
    const documents_encoded = try segment.encode(&documents, try arena.alloc(u8, try segment.encodedLength(&documents)));
    try std.testing.expectError(error.UnsupportedVersion, manifest.create(1, "analyzer-v2", "none", "d", "l", documents_encoded, lexical));
    const value = try manifest.createV2(1, "analyzer-v2", "none", "d", "l", "", "{\"manifest_meta\":2}", documents_encoded, lexical, null);
    try std.testing.expect(value.has_positions);
    const encoded = try manifest.encode(value, try arena.alloc(u8, try manifest.encodedLength(value)));
    const decoded = try manifest.decode(encoded);
    try std.testing.expect(decoded.has_positions);
    try manifest.validateSnapshot(decoded, documents_encoded, lexical);
    var lying = decoded;
    lying.has_positions = false;
    try std.testing.expectError(error.InvalidLexicalSection, manifest.validateSnapshot(lying, documents_encoded, lexical));
}

test "S3-T2: --update carries exact positions; a HYBLEX01 generation is upgraded" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "root", .default_dir);
    try tmp.dir.createDir(io, "out", .default_dir);
    try tmp.dir.createDir(io, "fresh", .default_dir);
    var root = try tmp.dir.openDir(io, "root", .{ .iterate = true });
    defer root.close(io);
    var out = try tmp.dir.openDir(io, "out", .{ .iterate = true });
    defer out.close(io);
    var fresh = try tmp.dir.openDir(io, "fresh", .{ .iterate = true });
    defer fresh.close(io);
    try root.writeFile(io, .{ .sub_path = "keep.md", .data = "# Keep\n\nCafe\u{0301} count me in, the the end\n" });
    try root.writeFile(io, .{ .sub_path = "change.txt", .data = "first version\n" });
    _ = try indexer.indexFolder(arena, io, root, out, .v2, 1, chunker.default_max_chars, chunker.default_overlap_lines, .{});
    try root.writeFile(io, .{ .sub_path = "change.txt", .data = "second version, count me in\n" });
    const report = try indexer.indexFolderIncremental(arena, io, root, out, .v2, chunker.default_max_chars, chunker.default_overlap_lines, .{});
    try std.testing.expectEqual(@as(usize, 1), report.unchanged);
    _ = try indexer.indexFolder(arena, io, root, fresh, .v2, 1, chunker.default_max_chars, chunker.default_overlap_lines, .{});
    const updated = try snapshot_open.open(arena, io, out);
    const rebuilt = try snapshot_open.open(arena, io, fresh);
    try std.testing.expectEqualSlices(u8, rebuilt.lexical_index.positions.?.offsets, updated.lexical_index.positions.?.offsets);
    try std.testing.expectEqualSlices(u8, rebuilt.lexical_index.positions.?.positions, updated.lexical_index.positions.?.positions);
    const answer = (try find.find(arena, updated, .{ .query = "\"count me in\"", .page_size = 100 })).ok;
    try std.testing.expectEqual(@as(usize, 2), answer.hits.len);
}
