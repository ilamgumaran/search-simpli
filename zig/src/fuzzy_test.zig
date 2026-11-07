//! S5-T3: `fuzzy-v1` (`fuzzy.zig`, `docs/fuzzy-v1.md`): the bounded OSA,
//! the trigger, the scan (range, order, cut, title-only candidates,
//! privacy, the path prefix), the group scoring, and the
//! `query_term_expanded` warnings of the `ss_query` report.
const std = @import("std");
const abi = @import("abi.zig");
const analyzer_v2 = @import("analyzer_v2.zig");
const engine_module = @import("engine.zig");
const filename_field = @import("filename_field.zig");
const fuzzy = @import("fuzzy.zig");
const hybrid = @import("hybrid.zig");
const lexical_build = @import("lexical_build.zig");
const manifest = @import("manifest.zig");
const postings = @import("postings.zig");
const title_field = @import("title_field.zig");

// ---------------------------------------------------------------- OSA

/// The full optimal-string-alignment table on code points.
fn fullOsa(a: []const u8, b: []const u8) !usize {
    const allocator = std.testing.allocator;
    var ca = std.ArrayList(u21).empty;
    defer ca.deinit(allocator);
    var cb = std.ArrayList(u21).empty;
    defer cb.deinit(allocator);
    var it = (try std.unicode.Utf8View.init(a)).iterator();
    while (it.nextCodepoint()) |c| try ca.append(allocator, c);
    it = (try std.unicode.Utf8View.init(b)).iterator();
    while (it.nextCodepoint()) |c| try cb.append(allocator, c);
    const w = cb.items.len + 1;
    const d = try allocator.alloc(usize, (ca.items.len + 1) * w);
    defer allocator.free(d);
    for (0..ca.items.len + 1) |i| d[i * w] = i;
    for (0..w) |j| d[j] = j;
    for (1..ca.items.len + 1) |i| for (1..w) |j| {
        const x = ca.items;
        const y = cb.items;
        const cost: usize = @intFromBool(x[i - 1] != y[j - 1]);
        var v = @min(@min(d[(i - 1) * w + j] + 1, d[i * w + j - 1] + 1), d[(i - 1) * w + j - 1] + cost);
        if (i > 1 and j > 1 and x[i - 1] == y[j - 2] and x[i - 2] == y[j - 1]) v = @min(v, d[(i - 2) * w + j - 2] + 1);
        d[i * w + j] = v;
    };
    return d[ca.items.len * w + cb.items.len];
}

fn expectBanded(a: []const u8, b: []const u8) !void {
    const full = try fullOsa(a, b);
    for ([_]u8{ 1, 2 }) |k| {
        const banded = try fuzzy.distanceWithin(std.testing.allocator, a, b, k);
        const expected: ?u8 = if (full <= k) @intCast(full) else null;
        try std.testing.expectEqual(expected, banded);
    }
}

test "OSA: the banded table with its early exit equals the full table" {
    const pairs = [_][2][]const u8{
        .{ "tournamnet", "tournament" }, // a swap
        .{ "choclate", "chocolate" }, // a deletion
        .{ "sandwitches", "sandwiches" }, // an insertion
        .{ "mikroscope", "microscope" }, // a substitution
        .{ "brekfest", "breakfast" }, // two edits
        .{ "acb", "abcx" }, // a swap plus an insertion
        .{ "abdc", "bacd" }, // two swaps
        .{ "ca", "abc" }, // OSA 3: no substring is edited twice
        .{ "fruhling", "frühling" }, // an accented pair, on code points
        .{ "pâté", "pate" },
        .{ "பாடல்", "பால்" }, // Tamil: never reached (not Latin), still exact
        .{ "same", "same" },
        .{ "", "ab" },
    };
    for (pairs) |p| try expectBanded(p[0], p[1]);
    try std.testing.expectEqual(@as(?u8, 1), try fuzzy.distanceWithin(std.testing.allocator, "tournamnet", "tournament", 2));
    try std.testing.expectEqual(@as(usize, 3), try fullOsa("ca", "abc"));
    try std.testing.expectEqual(@as(?u8, null), try fuzzy.distanceWithin(std.testing.allocator, "ca", "abc", 2));
    try std.testing.expectEqual(@as(?u8, 1), try fuzzy.distanceWithin(std.testing.allocator, "fruhling", "frühling", 1));

    // 3,000 random pairs over a small alphabet with multi-byte letters.
    const alphabet = [_][]const u8{ "a", "b", "c", "d", "é", "ß" };
    var prng = std.Random.DefaultPrng.init(0x5e53);
    const random = prng.random();
    var buffers: [2][64]u8 = undefined;
    for (0..3000) |_| {
        var words: [2][]const u8 = undefined;
        for (&words, &buffers) |*word, *buffer| {
            var len: usize = 0;
            for (0..random.uintLessThan(usize, 9)) |_| {
                const letter = alphabet[random.uintLessThan(usize, alphabet.len)];
                @memcpy(buffer[len .. len + letter.len], letter);
                len += letter.len;
            }
            word.* = buffer[0..len];
        }
        try expectBanded(words[0], words[1]);
    }
}

// ------------------------------------------------------------- a corpus

const roots = [_]manifest.RootEntry{.{ .root_id = "r-home", .label = "home", .kind = "local", .retain_source = true }};

const docs = [_]hybrid.Document{
    .{ .id = "a1", .text = "the dinosaur museum trip", .path = "r-home/school/trip.md", .start_line = 1, .end_line = 1 },
    .{ .id = "a2", .text = "dinosaur bones and fossils", .path = "r-home/school/fossils.md", .start_line = 1, .end_line = 1 },
    .{ .id = "a3", .text = "a dinosaurs poster", .path = "r-home/home/poster.md", .start_line = 1, .end_line = 1 },
    .{ .id = "h1", .text = "secret notes", .path = "r-home/private/notes.md", .start_line = 1, .end_line = 1, .required_labels = "private" },
    .{ .id = "c1", .text = "école lunch menu", .path = "r-home/school/lunch.md", .start_line = 1, .end_line = 1 },
    .{ .id = "b1", .text = "baker baked", .path = "r-home/kitchen/one.md", .start_line = 1, .end_line = 1 },
    .{ .id = "b2", .text = "baker bakel", .path = "r-home/kitchen/two.md", .start_line = 1, .end_line = 1 },
    .{ .id = "b3", .text = "baker bakes", .path = "r-home/kitchen/three.md", .start_line = 1, .end_line = 1 },
    .{ .id = "e1", .text = "heath walk", .path = "r-home/walks/heath.md", .start_line = 1, .end_line = 1 },
    .{ .id = "e2", .text = "a heath again", .path = "r-home/walks/again.md", .start_line = 1, .end_line = 1 },
    .{ .id = "t1", .text = "appointment at nine", .path = "r-home/health/doctor-visits.md", .start_line = 1, .end_line = 1 },
    .{ .id = "t2", .text = "rotor blades", .path = "r-home/private/helicopter-plans.md", .start_line = 1, .end_line = 1, .required_labels = "private" },
    .{ .id = "n1", .text = "naive tamil பழங்கள் café", .path = "r-home/notes/misc.md", .start_line = 1, .end_line = 1 },
};

const Corpus = struct {
    engine: engine_module.Engine,
    field: title_field.Field,
};

fn makeCorpus(a: std.mem.Allocator, documents: []const hybrid.Document) !Corpus {
    const token_lists = try a.alloc([][]const u8, documents.len);
    for (documents, token_lists) |doc, *tokens_out| tokens_out.* = try analyzer_v2.tokenize(a, doc.text);
    const index = try lexical_build.build(a, documents, token_lists);
    const derived = try title_field.derive(a, a, documents, &roots);
    return .{
        .engine = .{ .generation = 1, .analyzer_id = analyzer_v2.analyzer_id, .embedding_model_id = "", .vector_dimensions = 0, .documents = documents, .lexical_index = index, .roots = &roots },
        .field = derived.field,
    };
}

/// The same corpus with its dictionary sorted bytewise (as HYBLEX02 is).
fn sortedCorpus(a: std.mem.Allocator, documents: []const hybrid.Document) !Corpus {
    var corpus = try makeCorpus(a, documents);
    const terms = try a.dupe(postings.TermEntry, corpus.engine.lexical_index.terms);
    std.mem.sort(postings.TermEntry, terms, {}, struct {
        fn less(_: void, x: postings.TermEntry, y: postings.TermEntry) bool {
            return std.mem.order(u8, x.term, y.term) == .lt;
        }
    }.less);
    corpus.engine.lexical_index.terms = terms;
    corpus.engine.lexical_index.sorted_terms = true;
    return corpus;
}

fn context(corpus: *const Corpus, options: hybrid.SearchOptions) fuzzy.Context {
    return .{ .index = corpus.engine.lexical_index, .documents = corpus.engine.documents, .title = &corpus.field, .options = options };
}

fn expectMembers(a: std.mem.Allocator, ctx: fuzzy.Context, typed: []const u8, expected: []const []const u8) !void {
    const members = try fuzzy.scan(a, ctx, typed);
    if (members.len != expected.len) {
        std.debug.print("{s}: got", .{typed});
        for (members) |m| std.debug.print(" {s}({d},{d})", .{ m.term, m.distance, m.key_df });
        std.debug.print("\n", .{});
    }
    try std.testing.expectEqual(expected.len, members.len);
    for (members, expected) |m, e| try std.testing.expectEqualStrings(e, m.term);
}

// ------------------------------------------------------------ the trigger

test "trigger: 5 code points and Latin script; never below, never Tamil or mixed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const corpus = try sortedCorpus(arena.allocator(), &docs);
    const ctx = context(&corpus, .{});
    try std.testing.expect(!ctx.triggers("dino")); // 4 code points
    try std.testing.expect(ctx.triggers("dinox")); // 5
    try std.testing.expect(ctx.triggers("fruhling"));
    try std.testing.expect(ctx.triggers("naïve")); // accented Latin, df 0
    try std.testing.expect(!ctx.triggers("naive")); // held
    try std.testing.expect(!ctx.triggers("பழங்கல்")); // Tamil
    try std.testing.expect(!ctx.triggers("caféபழ")); // mixed script
    try std.testing.expect(!ctx.triggers("dinosaur")); // held in scope
}

test "trigger: a term held only outside the scope triggers; a visible title guards, a hidden one does not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const corpus = try sortedCorpus(arena.allocator(), &docs);
    // `bones` is only under school/ (and in no file's name): outside the
    // prefix it is unmatched. `fossils` is also a visible file's name, so
    // the title guard (roots and labels, no prefix) holds it.
    try std.testing.expect(!context(&corpus, .{}).triggers("bones"));
    try std.testing.expect(context(&corpus, .{ .path_prefix = "r-home/home/" }).triggers("bones"));
    try std.testing.expect(!context(&corpus, .{ .path_prefix = "r-home/home/" }).triggers("fossils"));
    // `health` is only a visible file's folder name: the title guard holds.
    try std.testing.expect(!context(&corpus, .{}).triggers("health"));
    // `helicopter` is only in a label-hidden file's name: it triggers
    // without the label, and is guarded with it.
    try std.testing.expect(context(&corpus, .{}).triggers("helicopter"));
    try std.testing.expect(!context(&corpus, .{ .principal_labels = &.{"private"} }).triggers("helicopter"));
}

// --------------------------------------------------------------- the scan

test "scan: the first-letter range, the order (distance, key df, bytes) and N = 3" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]bool{ true, false }) |sorted| {
        const corpus = if (sorted) try sortedCorpus(a, &docs) else try makeCorpus(a, &docs);
        const ctx = context(&corpus, .{});
        // dinosaur (1, df 2) before dinosaurs (2, df 1).
        try expectMembers(a, ctx, "dinosuar", &.{ "dinosaur", "dinosaurs" });
        // A multi-byte first code point: é... reaches école; e... does not.
        try expectMembers(a, ctx, "écolz", &.{"école"});
        try expectMembers(a, ctx, "ecolz", &.{});
        // baker (df 3) first, then df 1 by bytes: baked, bakel; bakes is cut.
        try expectMembers(a, ctx, "bakex", &.{ "baker", "baked", "bakel" });
        const members = try fuzzy.scan(a, ctx, "bakex");
        try std.testing.expectEqual(@as(u32, 3), members[0].key_df);
        for (members) |m| try std.testing.expectEqual(@as(f32, 1.0), m.weight);
        // Distance 2 weighs 0.5.
        const two = try fuzzy.scan(a, ctx, "dinosuar");
        try std.testing.expectEqual(@as(f32, 0.5), two[1].weight);
    }
}

test "scan: a title-only candidate at key df 1, after a body word at a higher df" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const corpus = try sortedCorpus(a, &docs);
    const members = try fuzzy.scan(a, context(&corpus, .{}), "helth");
    try std.testing.expectEqual(@as(usize, 2), members.len);
    try std.testing.expectEqualStrings("heath", members[0].term);
    try std.testing.expectEqual(@as(u32, 2), members[0].key_df);
    try std.testing.expect(members[0].body != null);
    try std.testing.expectEqualStrings("health", members[1].term);
    try std.testing.expectEqual(@as(u32, 1), members[1].key_df);
    try std.testing.expect(members[1].body == null);
}

test "scan privacy: a word held only by a label-hidden chunk or file is neither used nor reported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const corpus = try sortedCorpus(a, &docs);
    try expectMembers(a, context(&corpus, .{}), "secrat", &.{});
    try expectMembers(a, context(&corpus, .{ .principal_labels = &.{"private"} }), "secrat", &.{"secret"});
    // A hidden file's name is no candidate either.
    try expectMembers(a, context(&corpus, .{}), "helicoptr", &.{});
    try expectMembers(a, context(&corpus, .{ .principal_labels = &.{"private"} }), "helicoptr", &.{"helicopter"});
    // And no group, no warning, no hit through the engine.
    const out = try a.alloc(hybrid.Result, docs.len);
    var trace = hybrid.Trace{ .allocator = a, .io = std.testing.io };
    const results = try corpus.engine.queryTraced(a, "secrat", &.{}, out, .{ .retrieval_mode = .lexical, .title = &corpus.field }, &trace);
    try std.testing.expectEqual(@as(usize, 0), results.len);
    try std.testing.expectEqual(@as(usize, 0), trace.expanded.items.len);
    try std.testing.expectEqual(@as(usize, 1), trace.unmatched.items.len);
}

test "scan under a path prefix: the key df is the scope's, the candidate must be held under the prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // baker is held by 4 chunks, one of them under kitchen/b/; bakes, baked
    // and bakel by 2 each, all under it. The whole-scope df keeps baker
    // first (4) and cuts bakes by bytes; a prefix-narrowed df would put
    // baker last (1) and cut it.
    const prefixed = [_]hybrid.Document{
        .{ .id = "p1", .text = "baker", .path = "r-home/kitchen/a/one.md", .start_line = 1, .end_line = 1 },
        .{ .id = "p2", .text = "baker", .path = "r-home/kitchen/a/two.md", .start_line = 1, .end_line = 1 },
        .{ .id = "p3", .text = "baker", .path = "r-home/kitchen/a/three.md", .start_line = 1, .end_line = 1 },
        .{ .id = "q1", .text = "baker bakes baked bakel", .path = "r-home/kitchen/b/one.md", .start_line = 1, .end_line = 1 },
        .{ .id = "q2", .text = "bakes baked bakel", .path = "r-home/kitchen/b/two.md", .start_line = 1, .end_line = 1 },
        .{ .id = "q3", .text = "bakery only", .path = "r-home/kitchen/a/four.md", .start_line = 1, .end_line = 1 },
    };
    const corpus = try sortedCorpus(a, &prefixed);
    const options = hybrid.SearchOptions{ .path_prefix = "r-home/kitchen/b/" };
    try expectMembers(a, context(&corpus, options), "bakex", &.{ "baker", "baked", "bakel" });
    // A word held only outside the prefix is no candidate there.
    try expectMembers(a, context(&corpus, .{}), "bakeryy", &.{ "bakery", "baker" });
    try expectMembers(a, context(&corpus, options), "bakeryy", &.{"baker"});
}

// ---------------------------------------------------------- the scoring

test "group scoring: the best member per chunk at one df, never the sum; no group ranks as before" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const corpus = try sortedCorpus(a, &docs);
    const out = try a.alloc(hybrid.Result, docs.len);
    // bakex: baker, baked, bakel at df_g 3 (baker's). b1 holds baker and
    // baked: one member counts, so its score equals b3's (baker alone).
    const results = try corpus.engine.queryTokenized(a, "bakex", &.{}, out, .{ .retrieval_mode = .lexical });
    try std.testing.expectEqual(@as(usize, 3), results.len);
    var by_id = std.StringHashMap(f32).init(a);
    for (results) |r| try by_id.put(r.document_id, r.lexical_score);
    try std.testing.expectEqual(by_id.get("b1").?, by_id.get("b3").?);
    try std.testing.expectEqual(by_id.get("b2").?, by_id.get("b3").?);
    // The one plain term "baker" scores each chunk as the group does
    // (weight 1, the same df 3).
    const plain = try corpus.engine.queryTokenized(a, "baker", &.{}, try a.alloc(hybrid.Result, docs.len), .{ .retrieval_mode = .lexical });
    try std.testing.expectEqual(plain[0].lexical_score, by_id.get("b1").?);
    // fuzzy off: nothing found, as before S5-T3.
    try std.testing.expectEqual(@as(usize, 0), (try corpus.engine.queryTokenized(a, "bakex", &.{}, out, .{ .retrieval_mode = .lexical, .fuzzy = false })).len);
    // A query with no triggering term is identical with fuzzy on and off.
    for ([_][]const u8{ "dinosaur museum", "baker heath", "the a of" }) |q| {
        const on = try corpus.engine.queryTokenized(a, q, &.{}, try a.alloc(hybrid.Result, docs.len), .{ .retrieval_mode = .lexical, .title = &corpus.field });
        const off = try corpus.engine.queryTokenized(a, q, &.{}, try a.alloc(hybrid.Result, docs.len), .{ .retrieval_mode = .lexical, .title = &corpus.field, .fuzzy = false });
        try std.testing.expectEqual(off.len, on.len);
        for (on, off) |x, y| {
            try std.testing.expectEqualStrings(y.document_id, x.document_id);
            try std.testing.expectEqual(y.lexical_score, x.lexical_score);
            try std.testing.expectEqual(y.fused_score, x.fused_score);
        }
    }
}

test "group scoring: a distance-2 member weighs half; a title-only member scores in the title part" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const corpus = try sortedCorpus(a, &docs);
    const out = try a.alloc(hybrid.Result, docs.len);
    // helth: heath (body) and health (the title of doctor-visits.md).
    const results = try corpus.engine.queryTokenized(a, "helth", &.{}, out, .{ .retrieval_mode = .lexical, .title = &corpus.field });
    var title_hit = false;
    for (results) |r| if (std.mem.eql(u8, r.document_id, "t1")) {
        title_hit = true;
        try std.testing.expect(r.title_score != null and r.title_score.? > 0);
    };
    try std.testing.expect(title_hit);
    try std.testing.expect(results.len == 3);
}

test "both: the body scoring and the title part share the groups; the filename channel is not expanded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var corpus = try sortedCorpus(a, &docs);
    const built = try filename_field.build(a, &docs, analyzer_v2.analyzer_id);
    const decoded = try filename_field.decode(a, &docs, corpus.engine.lexical_index, built.catalog, built.lexical);
    corpus.engine.filename_index_enabled = true;
    corpus.engine.filename_decoded = decoded;
    const options = hybrid.SearchOptions{ .top_k = 10, .candidate_k = 10, .retrieval_mode = .lexical, .title = &corpus.field };
    const hits = try corpus.engine.queryFields(a, "helth", .both, options);
    try std.testing.expectEqual(@as(usize, 3), hits.len);
    for (hits) |hit| try std.testing.expect(hit.filename_score == 0 and hit.filename_rank == null);
    const doctor = for (hits) |hit| {
        if (std.mem.eql(u8, docs[hit.document_index].id, "t1")) break hit;
    } else return error.TestUnexpectedResult;
    try std.testing.expect(doctor.title_score != null and doctor.body_score == 0);
    // The filename field alone is never expanded.
    try std.testing.expectEqual(@as(usize, 0), (try corpus.engine.queryFields(a, "helth", .filename, options)).len);
    // fuzzy off: only nothing.
    var off = options;
    off.fuzzy = false;
    try std.testing.expectEqual(@as(usize, 0), (try corpus.engine.queryFields(a, "helth", .both, off)).len);
}

// ------------------------------------------------------------ the report

const v2_docs =
    \\{"format_version":1,"generation":1,"analyzer_id":"analyzer-v2","embedding_model_id":"none","documents":[
    \\{"id":"a","path":"public/a.md","start_line":1,"end_line":1,"text":"the dinosaur museum","vector":[],"required_labels":[]},
    \\{"id":"b","path":"public/b.md","start_line":1,"end_line":1,"text":"dinosaurs and tournament","vector":[],"required_labels":[]},
    \\{"id":"c","path":"public/c.md","start_line":1,"end_line":1,"text":"secret plan","vector":[],"required_labels":["tenant:acme"]}
    \\]}
;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    path_z: [:0]u8,
    handle: *abi.Handle,

    fn open(json: []const u8) !Fixture {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        const path_z = try std.fmt.allocPrintSentinel(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path}, 0);
        errdefer std.testing.allocator.free(path_z);
        try std.testing.expectEqual(@as(i64, 1), abi.ss_import_json(path_z, json.ptr, json.len));
        const handle = abi.ss_open(path_z) orelse return error.OpenFailed;
        return .{ .tmp = tmp, .path_z = path_z, .handle = handle };
    }

    fn close(fixture: *Fixture) void {
        abi.ss_close(fixture.handle);
        std.testing.allocator.free(fixture.path_z);
        fixture.tmp.cleanup();
    }

    fn run(fixture: Fixture, text: [:0]const u8, options: [:0]const u8) !std.json.Parsed(std.json.Value) {
        const out = abi.ss_query(fixture.handle, text.ptr, null, 0, 5, options.ptr) orelse return error.QueryFailed;
        defer abi.ss_free(out);
        return std.json.parseFromSlice(std.json.Value, std.testing.allocator, std.mem.span(out), .{});
    }
};

test "warnings: query_term_unmatched kept, followed by query_term_expanded with its expansions, in query order" {
    var fixture = try Fixture.open(v2_docs);
    defer fixture.close();
    var report = try fixture.run("tournamnet dino dinosuar", "{\"retrieval_mode\":\"lexical\"}");
    defer report.deinit();
    const warnings = report.value.object.get("warnings").?.array.items;
    const expected = [_][2][]const u8{
        .{ "query_term_unmatched", "tournamnet" },
        .{ "query_term_expanded", "tournamnet" },
        .{ "query_term_unmatched", "dino" },
        .{ "query_term_unmatched", "dinosuar" },
        .{ "query_term_expanded", "dinosuar" },
    };
    try std.testing.expectEqual(expected.len, warnings.len);
    for (expected, warnings) |e, w| {
        try std.testing.expectEqualStrings(e[0], w.object.get("code").?.string);
        try std.testing.expectEqualStrings(e[1], w.object.get("term").?.string);
    }
    const expansions = warnings[4].object.get("expansions").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), expansions.len);
    try std.testing.expectEqualStrings("dinosaur", expansions[0].string);
    try std.testing.expectEqualStrings("dinosaurs", expansions[1].string);
    try std.testing.expectEqualStrings("also searched: dinosaur, dinosaurs", warnings[4].object.get("message").?.string);
    try std.testing.expect(report.value.object.get("results").?.array.items.len == 2);
}

test "warnings: a word held only by a hidden chunk is never named as an expansion" {
    var fixture = try Fixture.open(v2_docs);
    defer fixture.close();
    var hidden = try fixture.run("secrat", "{\"retrieval_mode\":\"lexical\"}");
    defer hidden.deinit();
    const warnings = hidden.value.object.get("warnings").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), warnings.len);
    try std.testing.expectEqualStrings("query_term_unmatched", warnings[0].object.get("code").?.string);
    try std.testing.expectEqual(@as(usize, 0), hidden.value.object.get("results").?.array.items.len);
    var labelled = try fixture.run("secrat", "{\"retrieval_mode\":\"lexical\",\"principal_labels\":[\"tenant:acme\"]}");
    defer labelled.deinit();
    try std.testing.expectEqual(@as(usize, 2), labelled.value.object.get("warnings").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), labelled.value.object.get("results").?.array.items.len);
}
