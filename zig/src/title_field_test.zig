//! S5-T2: the title field's tokens and grouping (`title_field.zig`). The
//! expected tokens are the Python reference's (`core._title_tokens`).
const std = @import("std");
const filename_field = @import("filename_field.zig");
const hybrid = @import("hybrid.zig");
const manifest = @import("manifest.zig");
const scope = @import("scope.zig");
const title_field = @import("title_field.zig");

const roots = [_]manifest.RootEntry{
    .{ .root_id = "r-home", .label = "home", .kind = "local", .retain_source = true },
    .{ .root_id = scope.legacy_root_id, .label = "folder", .kind = "local", .retain_source = true },
};

fn expectTokens(path: []const u8, expected: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const got = try title_field.tokens(arena.allocator(), &roots, path);
    try std.testing.expectEqual(expected.len, got.len);
    for (expected, got) |e, g| try std.testing.expectEqualStrings(e, g);
}

test "title tokens: folders then the stem, never the root id" {
    try expectTokens("r-home/Music/Recorder-Practice.md", &.{ "music", "recorder", "practice" });
    try expectTokens("r-home/garden/garden/garden-diary.md", &.{ "garden", "garden", "garden", "diary" });
    try expectTokens("r-home/a/archive.tar.gz", &.{ "a", "archive", "tar" });
}

test "title tokens: a legacy-root or unrooted path is taken whole" {
    try expectTokens("loose/Kids_Questions.txt", &.{ "loose", "kids", "questions" });
    const legacy_only = [_]manifest.RootEntry{scope.legacy_roots[0]};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const got = try title_field.tokens(arena.allocator(), &legacy_only, "r-home/notes/plan.md");
    const expected = [_][]const u8{ "r", "home", "notes", "plan" };
    try std.testing.expectEqual(expected.len, got.len);
    for (expected, got) |e, g| try std.testing.expectEqualStrings(e, g);
}

test "title stem follows Path.stem, not the filename field's stem" {
    try std.testing.expectEqualStrings(".bashrc", title_field.pathStem(".bashrc"));
    try std.testing.expectEqualStrings("notes.", title_field.pathStem("notes."));
    try std.testing.expectEqualStrings("archive.tar", title_field.pathStem("archive.tar.gz"));
    try std.testing.expectEqualStrings("plain", title_field.pathStem("plain"));
    try expectTokens("r-home/.bashrc", &.{"bashrc"});
    try expectTokens("r-home/notes.", &.{"notes"});
    // The filename field (S4-T2) keeps its own stem: a dot-first name is "".
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const docs = [_]hybrid.Document{.{ .id = "x", .text = "t", .path = "r-home/.bashrc", .start_line = 1, .end_line = 1 }};
    const catalog = try filename_field.group(arena.allocator(), &docs);
    try std.testing.expectEqualStrings("", catalog[0].text);
}

test "title tokens fold like analyzer-v2: Tamil NFC and NFD, full-width, accents" {
    try expectTokens("r-home/தமிழ்/வகுப்பு.md", &.{ "தமிழ்", "வகுப்பு" });
    // A decomposed accent (NFD) folds to the composed token.
    try expectTokens("r-home/Cafe\u{301}/menu.md", &.{ "café", "menu" });
    try expectTokens("r-home/Ｆｕｌｌ/Café-Straße.ﬁle.md", &.{ "ｆｕｌｌ", "café", "straße", "ﬁle" });
}

fn checkField(derived: title_field.Derived, documents: []const hybrid.Document) !void {
    const field = derived.field;
    try std.testing.expectEqual(documents.len, field.file_of.len);
    // Every chunk's file holds its path; each file's first chunk is its
    // anchor (smallest start line, end line, id).
    for (documents, field.file_of) |document, f| {
        const anchor = documents[field.files[f].first_chunk];
        try std.testing.expectEqualStrings(anchor.path, document.path);
        try std.testing.expect(anchor.start_line <= document.start_line);
    }
    // The term table is sorted bytewise and every term is found.
    for (field.terms[0..field.terms.len -| 1], field.terms[@min(1, field.terms.len)..]) |a, b| {
        try std.testing.expect(std.mem.order(u8, field.termBytes(a), field.termBytes(b)) == .lt);
    }
    for (field.terms) |term| {
        const found = field.lookup(field.termBytes(term)) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(term.postings_start, found.postings_start);
        const list = field.termPostings(term);
        for (list[0..list.len -| 1], list[@min(1, list.len)..]) |a, b| try std.testing.expect(a.file < b.file);
    }
    try std.testing.expectEqual(@as(?title_field.Term, null), field.lookup("absent"));
}

const in_order = [_]hybrid.Document{
    .{ .id = "g2", .text = "", .path = "r-home/garden/garden-diary.md", .start_line = 9, .end_line = 12 },
    .{ .id = "g1", .text = "", .path = "r-home/garden/garden-diary.md", .start_line = 1, .end_line = 8 },
    .{ .id = "h1", .text = "", .path = "r-home/house-rules.md", .start_line = 1, .end_line = 5 },
    .{ .id = "m1", .text = "", .path = "r-home/music/recorder-practice.md", .start_line = 1, .end_line = 4 },
};

test "grouping in one pass when the paths come in order" {
    const derived = try title_field.derive(std.testing.allocator, std.testing.allocator, &in_order, &roots);
    defer derived.deinit(std.testing.allocator);
    try std.testing.expect(derived.profile.in_order);
    try std.testing.expectEqual(@as(usize, 3), derived.profile.files);
    try std.testing.expectEqual(@as(usize, 2), derived.profile.distinct_folders);
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 1, 2 }, derived.field.file_of);
    try std.testing.expectEqual(@as(u32, 1), derived.field.files[0].first_chunk);
    // garden x2 in file 0 (folder + stem), lengths 3, 2, 3.
    const garden = derived.field.lookup("garden").?;
    try std.testing.expectEqual(@as(u32, 1), garden.postings_len);
    try std.testing.expectEqual(title_field.Posting{ .file = 0, .frequency = 2 }, derived.field.termPostings(garden)[0]);
    try std.testing.expectEqual(@as(u32, 3), derived.field.files[0].length);
    try std.testing.expectEqual(@as(u32, 2), derived.field.files[1].length);
    try std.testing.expectEqual(@as(u64, 8), derived.field.total_length);
    try std.testing.expect(derived.field.lookup("r-home") == null and derived.field.lookup("home") == null);
    try checkField(derived, &in_order);
}

test "grouping falls back when a file's chunks are not adjacent" {
    // A file's chunks split by another file's: the one-pass grouping does
    // not apply; the fallback groups by path and keeps first-chunk order.
    const scattered = [_]hybrid.Document{
        .{ .id = "m1", .text = "", .path = "r-home/music/recorder-practice.md", .start_line = 1, .end_line = 4 },
        .{ .id = "g2", .text = "", .path = "r-home/garden/garden-diary.md", .start_line = 9, .end_line = 12 },
        .{ .id = "h1", .text = "", .path = "r-home/house-rules.md", .start_line = 1, .end_line = 5 },
        .{ .id = "g1", .text = "", .path = "r-home/garden/garden-diary.md", .start_line = 1, .end_line = 8 },
    };
    const derived = try title_field.derive(std.testing.allocator, std.testing.allocator, &scattered, &roots);
    defer derived.deinit(std.testing.allocator);
    try std.testing.expect(!derived.profile.in_order);
    try std.testing.expectEqual(@as(usize, 3), derived.profile.files);
    // Ordinals by each file's earliest chunk: music 0, garden 1, house 2.
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 1 }, derived.field.file_of);
    try std.testing.expectEqual(@as(u32, 3), derived.field.files[1].first_chunk);
    try checkField(derived, &scattered);
    // The same terms, frequencies and lengths as the in-order derive.
    const ordered = try title_field.derive(std.testing.allocator, std.testing.allocator, &in_order, &roots);
    defer ordered.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(ordered.field.term_bytes, derived.field.term_bytes);
    try std.testing.expectEqual(ordered.field.total_length, derived.field.total_length);
}

test "derive of no documents, and the scratch is released (testing allocator)" {
    const derived = try title_field.derive(std.testing.allocator, std.testing.allocator, &.{}, &roots);
    defer derived.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), derived.profile.files);
    try std.testing.expectEqual(@as(?title_field.Term, null), derived.field.lookup("x"));
}

test "derive marks its five stages in order" {
    const Recorder = struct {
        names: [8][]const u8 = undefined,
        count: usize = 0,
        pub fn mark(self: *@This(), comptime name: []const u8) void {
            self.names[self.count] = name;
            self.count += 1;
        }
    };
    var recorder = Recorder{};
    const derived = try title_field.deriveMarked(std.testing.allocator, std.testing.allocator, &in_order, &roots, &recorder);
    defer derived.deinit(std.testing.allocator);
    const expected = [_][]const u8{ "grouping", "folders", "stems", "postings", "lookup" };
    try std.testing.expectEqual(expected.len, recorder.count);
    for (expected, recorder.names[0..recorder.count]) |e, g| try std.testing.expectEqualStrings(e, g);
}

test "the ASCII token path agrees with analyzer_v2.tokenize" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const analyzer_v2 = @import("analyzer_v2.zig");
    // Every ASCII byte between two letters, and seeded random ASCII strings
    // (some longer than the 256-byte run buffer), plus non-ASCII text.
    var texts = std.ArrayList([]const u8).empty;
    for (0..128) |c| try texts.append(a, try std.fmt.allocPrint(a, "Ab{c}Cd", .{@as(u8, @intCast(c))}));
    var prng = std.Random.DefaultPrng.init(0x55e2);
    const random = prng.random();
    for (0..2000) |n| {
        const len = if (n % 100 == 0) 300 + random.uintLessThan(usize, 200) else random.uintLessThan(usize, 40);
        const text = try a.alloc(u8, len);
        for (text) |*c| c.* = if (n % 100 == 0) "aZ09"[random.uintLessThan(usize, 4)] else random.uintLessThan(u8, 128);
        try texts.append(a, text);
    }
    try texts.appendSlice(a, &.{ "Café-Straße", "தமிழ்-வகுப்பு", "Ｆｕｌｌ", "Cafe\u{301}", "1\u{FE0F}\u{20E3}x", "", "---" });
    for (texts.items) |text| {
        const want = try analyzer_v2.tokenize(a, text);
        const got = try title_field.tokenizeText(a, text);
        try std.testing.expectEqual(want.len, got.len);
        for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
    }
}

// ------------------------------------------------- scoring (Phase 2) ---

const analyzer_v2_module = @import("analyzer_v2.zig");
const engine_module = @import("engine.zig");
const lexical_build = @import("lexical_build.zig");
const postings = @import("postings.zig");

const golden_path = "../fixtures/title-field-golden.json";

test "title scores match the Python reference's golden over J2's paths and knowledge queries" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, golden_path, a, .unlimited) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("skipping: {s} not found (run scripts/gen_title_golden.py)\n", .{golden_path});
            return;
        },
        else => return err,
    };
    const golden = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{});
    var golden_roots = std.ArrayList(manifest.RootEntry).empty;
    for (golden.object.get("roots").?.array.items) |root| try golden_roots.append(a, .{ .root_id = root.string, .label = root.string, .kind = "host", .retain_source = true });
    var documents = std.ArrayList(hybrid.Document).empty;
    for (golden.object.get("paths").?.array.items, 0..) |path, i| {
        try documents.append(a, .{ .id = try std.fmt.allocPrint(a, "c{d}", .{i}), .text = "", .path = path.string, .start_line = 1, .end_line = 1 });
    }
    const derived = try title_field.derive(a, a, documents.items, golden_roots.items);
    var compared: usize = 0;
    for (golden.object.get("queries").?.array.items) |q| {
        const query = q.object.get("query").?.string;
        const expected = q.object.get("files").?.array.items;
        const parts = try title_field.scoreQuery(a, &derived.field, documents.items, query, .{}) orelse {
            if (expected.len != 0) std.debug.print("query {s}: no title parts, golden has {d}\n", .{ query, expected.len });
            try std.testing.expectEqual(@as(usize, 0), expected.len);
            continue;
        };
        try std.testing.expectEqual(expected.len, parts.touched.len);
        for (expected) |entry| {
            const path = entry.object.get("path").?.string;
            const want: f64 = switch (entry.object.get("score").?) {
                .float => |f| f,
                .integer => |n| @floatFromInt(n),
                else => return error.TestUnexpectedResult,
            };
            var chunk: ?usize = null;
            for (documents.items, 0..) |d, i| if (std.mem.eql(u8, d.path, path)) {
                chunk = i;
            };
            const got: f64 = parts.scores[derived.field.file_of[chunk.?]];
            if (@abs(got - want) > 1e-4 * @max(1.0, @abs(want))) {
                std.debug.print("query {s} file {s}: zig {d} python {d}\n", .{ query, path, got, want });
                return error.TestExpectedEqual;
            }
            compared += 1;
        }
    }
    try std.testing.expect(compared > 100);
    std.debug.print("S5-T2 title golden: {d} file scores compared within 1e-4\n", .{compared});
}

const scope_docs = [_]hybrid.Document{
    .{ .id = "a1", .text = "", .path = "r-one/garden/plan.md", .start_line = 1, .end_line = 2 },
    .{ .id = "a2", .text = "", .path = "r-one/garden-notes.md", .start_line = 1, .end_line = 2 },
    .{ .id = "a3", .text = "", .path = "r-one/tools.md", .start_line = 1, .end_line = 2 },
    .{ .id = "b1", .text = "", .path = "r-two/garden/seeds.md", .start_line = 1, .end_line = 2 },
    .{ .id = "b2", .text = "", .path = "r-two/secret-garden.md", .start_line = 1, .end_line = 2, .required_labels = "private" },
};
const scope_roots = [_]manifest.RootEntry{
    .{ .root_id = "r-one", .label = "one", .kind = "local", .retain_source = true },
    .{ .root_id = "r-two", .label = "two", .kind = "local", .retain_source = true },
};

fn partsByPath(a: std.mem.Allocator, documents: []const hybrid.Document, options: hybrid.SearchOptions) !std.StringHashMapUnmanaged(f32) {
    const derived = try title_field.derive(a, a, documents, &scope_roots);
    var field = derived.field;
    field.max_document_root = 1;
    var out: std.StringHashMapUnmanaged(f32) = .empty;
    const parts = (try title_field.scoreQuery(a, &field, documents, "garden", options)) orelse return out;
    for (parts.touched) |f| try out.put(a, documents[field.files[f].first_chunk].path, parts.scores[f]);
    return out;
}

fn expectSameParts(want: std.StringHashMapUnmanaged(f32), got: std.StringHashMapUnmanaged(f32)) !void {
    try std.testing.expectEqual(want.count(), got.count());
    var it = want.iterator();
    while (it.next()) |entry| try std.testing.expectEqual(entry.value_ptr.*, got.get(entry.key_ptr.*).?);
}

test "title statistics: a root mask and the labels narrow N, the average and df; a path prefix does not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const roots_of = [_]u16{ 0, 0, 0, 1, 1 };
    // Labels: without `private`, the labelled file leaves the statistics:
    // the parts equal those of the corpus without it.
    const unlabeled = try partsByPath(a, &scope_docs, .{});
    const without_private = try partsByPath(a, scope_docs[0..4], .{});
    try expectSameParts(without_private, unlabeled);
    try std.testing.expect(unlabeled.get("r-two/secret-garden.md") == null);
    const labeled = try partsByPath(a, &scope_docs, .{ .principal_labels = &.{"private"} });
    try std.testing.expect(labeled.get("r-two/secret-garden.md") != null);
    try std.testing.expect(labeled.get("r-one/garden/plan.md").? != unlabeled.get("r-one/garden/plan.md").?);
    // A root mask: only r-one's files count, as in a corpus of r-one alone.
    const mask = hybrid.RootMask{ .document_roots = &roots_of, .allowed = &.{ true, false } };
    try expectSameParts(try partsByPath(a, scope_docs[0..3], .{}), try partsByPath(a, &scope_docs, .{ .visible_roots = mask, .principal_labels = &.{"private"} }));
    // A mask allowing every root hides nothing.
    const all = hybrid.RootMask{ .document_roots = &roots_of, .allowed = &.{ true, true } };
    try expectSameParts(labeled, try partsByPath(a, &scope_docs, .{ .visible_roots = all, .principal_labels = &.{"private"} }));
    // A path prefix narrows nothing here.
    try expectSameParts(unlabeled, try partsByPath(a, &scope_docs, .{ .path_prefix = "r-one/" }));
}

const Corpus = struct {
    engine: engine_module.Engine,
    field: title_field.Field,
};

fn makeCorpus(a: std.mem.Allocator, documents: []const hybrid.Document, corpus_roots: []const manifest.RootEntry) !Corpus {
    const token_lists = try a.alloc([][]const u8, documents.len);
    for (documents, token_lists) |doc, *tokens_out| tokens_out.* = try analyzer_v2_module.tokenize(a, doc.text);
    const index = try lexical_build.build(a, documents, token_lists);
    const derived = try title_field.derive(a, a, documents, corpus_roots);
    return .{
        .engine = .{ .generation = 1, .analyzer_id = analyzer_v2_module.analyzer_id, .embedding_model_id = "", .vector_dimensions = 0, .documents = documents, .lexical_index = index, .roots = corpus_roots },
        .field = derived.field,
    };
}

fn contentQuery(a: std.mem.Allocator, corpus: *const Corpus, query: []const u8, with_title: bool, weight: f32) ![]hybrid.Result {
    const out = try a.alloc(hybrid.Result, corpus.engine.documents.len);
    return corpus.engine.queryTokenized(a, query, &.{}, out, .{ .top_k = 10, .candidate_k = 100, .retrieval_mode = .lexical, .title = if (with_title) &corpus.field else null, .title_weight = weight });
}

const content_docs = [_]hybrid.Document{
    .{ .id = "g-b", .text = "tomato rows by the fence", .path = "r-home/garden.md", .start_line = 1, .end_line = 4 },
    .{ .id = "g-a", .text = "tomato rows by the fence", .path = "r-home/garden.md", .start_line = 5, .end_line = 8 },
    .{ .id = "d-2", .text = "the nurse said to rest", .path = "r-home/health/doctor-visits.md", .start_line = 7, .end_line = 9 },
    .{ .id = "d-1", .text = "appointment at nine", .path = "r-home/health/doctor-visits.md", .start_line = 1, .end_line = 6 },
    .{ .id = "n-1", .text = "a note about tomato soup", .path = "r-home/notes.md", .start_line = 1, .end_line = 2 },
};

test "content: a title-only file is returned through its first chunk" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const corpus = try makeCorpus(a, &content_docs, &roots);
    try std.testing.expectEqual(@as(usize, 0), (try contentQuery(a, &corpus, "health", false, 2.5)).len);
    const results = try contentQuery(a, &corpus, "health", true, 2.5);
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("d-1", results[0].document_id);
    try std.testing.expectEqual(results[0].lexical_score, results[0].title_score.?);
    try std.testing.expect(results[0].lexical_score > 0);
}

test "content: the part goes on the file's best body chunk, an exact tie to the smaller id" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const corpus = try makeCorpus(a, &content_docs, &roots);
    const plain = try contentQuery(a, &corpus, "garden tomato", false, 2.5);
    const titled = try contentQuery(a, &corpus, "garden tomato", true, 2.5);
    try std.testing.expectEqual(plain.len, titled.len);
    // g-a and g-b tie on the body; g-a (the smaller id) takes the part.
    try std.testing.expectEqualStrings("g-a", titled[0].document_id);
    try std.testing.expect(titled[0].title_score.? > 0);
    var body_of_a: f32 = 0;
    for (plain) |r| if (std.mem.eql(u8, r.document_id, "g-a")) {
        body_of_a = r.lexical_score;
    };
    try std.testing.expectEqual(body_of_a + titled[0].title_score.?, titled[0].lexical_score);
    for (titled[1..]) |r| try std.testing.expect(r.title_score == null);
}

test "content: title weight 0 and no title field give today's results, byte for byte" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // A 1,000-chunk synthetic corpus: 250 files under 25 folders whose names
    // share the body's words.
    const words = [_][]const u8{ "harbour", "tide", "ledger", "garden", "budget", "lantern", "orchard", "copper", "pond", "maple" };
    var prng = std.Random.DefaultPrng.init(0x5e72);
    const random = prng.random();
    const docs = try a.alloc(hybrid.Document, 1000);
    for (docs, 0..) |*doc, i| {
        const file = i / 4;
        var text = std.ArrayList(u8).empty;
        for (0..6) |_| {
            try text.appendSlice(a, words[random.uintLessThan(usize, words.len)]);
            try text.append(a, ' ');
        }
        doc.* = .{
            .id = try std.fmt.allocPrint(a, "{x:0>8}", .{random.int(u32)}),
            .text = text.items,
            .path = try std.fmt.allocPrint(a, "r-home/{s}-{d}/{s}-{d:0>3}.md", .{ words[file % 10], file % 25, words[(file / 10) % 10], file }),
            .start_line = @intCast((i % 4) * 10 + 1),
            .end_line = @intCast((i % 4) * 10 + 9),
        };
    }
    const corpus = try makeCorpus(a, docs, &roots);
    for ([_][]const u8{ "harbour", "tide ledger", "garden budget lantern", "maple 042", "nosuchword" }) |query| {
        const today = try contentQuery(a, &corpus, query, false, 2.5);
        const zero = try contentQuery(a, &corpus, query, true, 0);
        try std.testing.expectEqual(today.len, zero.len);
        for (today, zero) |x, y| {
            try std.testing.expectEqual(x.document_index, y.document_index);
            try std.testing.expectEqual(x.lexical_score, y.lexical_score);
            try std.testing.expectEqual(x.lexical_rank, y.lexical_rank);
            try std.testing.expectEqual(x.fused_score, y.fused_score);
            try std.testing.expect(y.title_score == null);
        }
    }
}

test "the title field is derived once per opened generation, at the first content or both query, never at the open" {
    const io = std.testing.io;
    const chunker = @import("chunker.zig");
    const indexer = @import("indexer.zig");
    const snapshot_open = @import("snapshot_open.zig");
    const service_module = @import("service.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var folder_tmp = std.testing.tmpDir(.{ .iterate = true });
    defer folder_tmp.cleanup();
    var out_tmp = std.testing.tmpDir(.{ .iterate = true });
    defer out_tmp.cleanup();
    try folder_tmp.dir.createDirPath(io, "garden");
    try folder_tmp.dir.writeFile(io, .{ .sub_path = "garden/plan.md", .data = "# Plan\n\nTomatoes by the fence.\n" });
    try folder_tmp.dir.writeFile(io, .{ .sub_path = "week.md", .data = "# Week\n\nThe tide table for the harbour walk.\n" });
    _ = try indexer.indexFolderIncremental(a, io, folder_tmp.dir, out_tmp.dir, .v2, chunker.default_max_chars, chunker.default_overlap_lines, .{ .filename_index = true });
    const opened = try snapshot_open.openScoped(a, io, out_tmp.dir);
    defer opened.folder.close();
    const loads = opened.folder.loads;
    const scoped = service_module.ScopedService{ .service = .{ .engine = opened.engine, .folder = opened.folder } };
    _ = try scoped.indexStatus(a, .{});
    try std.testing.expect(!opened.folder.titleDerived());
    try std.testing.expectEqual(@as(u32, 0), loads.title_loads);
    const results = try a.alloc(hybrid.Result, 4);
    const evidence = try a.alloc(engine_module.Evidence, 4);
    const found = try scoped.searchKnowledge(a, "garden", &.{}, .{ .retrieval_mode = .lexical }, .{}, results, evidence, null);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("garden/plan.md", found[0].path);
    try std.testing.expectEqual(@as(u32, 1), loads.title_loads);
    _ = try scoped.searchKnowledge(a, "tide", &.{}, .{ .retrieval_mode = .lexical }, .{}, results, evidence, null);
    _ = try opened.engine.queryFields(a, "garden", .both, .{ .retrieval_mode = .lexical, .top_k = 4, .candidate_k = 4 });
    try std.testing.expectEqual(@as(u32, 1), loads.title_loads);
}
