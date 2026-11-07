//! S5-T4: fold-groups-v1 through the engine (`fold.compute`,
//! `docs/fold-groups-v1.md`): the trigger, the members (in-scope chunks and
//! visible titles only), the order, fuzzy-v1 on the ungrouped tokens only,
//! the scoring, `both`, the filename channel left alone, more members than
//! fuzzy-v1's three, and the `query_term_grouped` warning of `ss_query`.
const std = @import("std");
const abi = @import("abi.zig");
const analyzer_v2 = @import("analyzer_v2.zig");
const engine_module = @import("engine.zig");
const filename_field = @import("filename_field.zig");
const fold = @import("fold.zig");
const fuzzy = @import("fuzzy.zig");
const hybrid = @import("hybrid.zig");
const lexical_build = @import("lexical_build.zig");
const manifest = @import("manifest.zig");
const postings = @import("postings.zig");
const title_field = @import("title_field.zig");

const roots = [_]manifest.RootEntry{.{ .root_id = "r-home", .label = "home", .kind = "local", .retain_source = true }};

const docs = [_]hybrid.Document{
    .{ .id = "s1", .text = "boxes on the shelf", .path = "r-home/home/shelf.md", .start_line = 1, .end_line = 1 },
    .{ .id = "s2", .text = "a box of toys", .path = "r-home/home/toys.md", .start_line = 1, .end_line = 1 },
    .{ .id = "s3", .text = "one more box", .path = "r-home/home/more.md", .start_line = 1, .end_line = 1 },
    .{ .id = "s4", .text = "the boxing club", .path = "r-home/home/sport.md", .start_line = 1, .end_line = 1 },
    .{ .id = "c1", .text = "café menu", .path = "r-home/notes/menu.md", .start_line = 1, .end_line = 1 },
    .{ .id = "c2", .text = "café terrace", .path = "r-home/notes/terrace.md", .start_line = 1, .end_line = 1 },
    .{ .id = "c3", .text = "cafe opening hours", .path = "r-home/notes/hours.md", .start_line = 1, .end_line = 1 },
    .{ .id = "r1", .text = "resume resumes résumé résumés resumé", .path = "r-home/work/cv.md", .start_line = 1, .end_line = 1 },
    .{ .id = "p1", .text = "pony club", .path = "r-home/home/club.md", .start_line = 1, .end_line = 1 },
    .{ .id = "h1", .text = "ponies ride", .path = "r-home/private/ride.md", .start_line = 1, .end_line = 1, .required_labels = "private" },
    .{ .id = "h2", .text = "rotor blades", .path = "r-home/private/kites-plan.md", .start_line = 1, .end_line = 1, .required_labels = "private" },
    .{ .id = "d1", .text = "dresses sale", .path = "r-home/school/sale.md", .start_line = 1, .end_line = 1 },
    .{ .id = "d2", .text = "dress code", .path = "r-home/home/code.md", .start_line = 1, .end_line = 1 },
    .{ .id = "l1", .text = "lunch at noon", .path = "r-home/home/noon.md", .start_line = 1, .end_line = 1 },
    .{ .id = "t1", .text = "appointment at nine", .path = "r-home/lunches/visit.md", .start_line = 1, .end_line = 1 },
};

const Corpus = struct {
    engine: engine_module.Engine,
    field: title_field.Field,
};

/// The corpus with its dictionary sorted bytewise (as HYBLEX02 is).
fn makeCorpus(a: std.mem.Allocator, documents: []const hybrid.Document) !Corpus {
    const token_lists = try a.alloc([][]const u8, documents.len);
    for (documents, token_lists) |doc, *tokens_out| tokens_out.* = try analyzer_v2.tokenize(a, doc.text);
    var index = try lexical_build.build(a, documents, token_lists);
    const terms = try a.dupe(postings.TermEntry, index.terms);
    std.mem.sort(postings.TermEntry, terms, {}, struct {
        fn less(_: void, x: postings.TermEntry, y: postings.TermEntry) bool {
            return std.mem.order(u8, x.term, y.term) == .lt;
        }
    }.less);
    index.terms = terms;
    index.sorted_terms = true;
    const derived = try title_field.derive(a, a, documents, &roots);
    return .{
        .engine = .{ .generation = 1, .analyzer_id = analyzer_v2.analyzer_id, .embedding_model_id = "", .vector_dimensions = 0, .documents = documents, .lexical_index = index, .roots = &roots },
        .field = derived.field,
    };
}

/// The members `fold.compute` gives `typed` under `options` (empty: no group).
fn expectGroup(a: std.mem.Allocator, corpus: *const Corpus, options: hybrid.SearchOptions, typed: []const u8, expected: []const []const u8) !void {
    var map = try fold.KeyMap.deriveIndexed(a, a, corpus.engine.lexical_index, &corpus.field);
    defer map.deinit(a);
    const context = fuzzy.Context{ .index = corpus.engine.lexical_index, .documents = corpus.engine.documents, .title = &corpus.field, .options = options };
    const groups = try fold.compute(a, context, &map, &.{typed});
    const members: []const fuzzy.Member = if (groups) |g| g.items[0].members else &.{};
    if (members.len != expected.len) {
        std.debug.print("{s}: got", .{typed});
        for (members) |m| std.debug.print(" {s}({d})", .{ m.term, m.key_df });
        std.debug.print("\n", .{});
    }
    try std.testing.expectEqual(expected.len, members.len);
    for (members, expected) |m, e| {
        try std.testing.expectEqualStrings(e, m.term);
        try std.testing.expectEqual(@as(f32, 1.0), m.weight);
    }
}

fn lexical(corpus: *const Corpus) hybrid.SearchOptions {
    return .{ .top_k = docs.len, .candidate_k = docs.len, .retrieval_mode = .lexical, .title = &corpus.field };
}

test "groups: the trigger (not empty, not the term alone), the order (term, key df, bytes) and the members past three" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const corpus = try makeCorpus(a, &docs);
    try expectGroup(a, &corpus, .{}, "boxes", &.{ "boxes", "box" });
    try expectGroup(a, &corpus, .{}, "box", &.{ "box", "boxes" });
    // `boxing` keys to itself and no other term shares it.
    try expectGroup(a, &corpus, .{}, "boxing", &.{});
    // An unheld typed term: café (df 2) before cafe (df 1), the df over bytes.
    try expectGroup(a, &corpus, .{}, "cafes", &.{ "café", "cafe" });
    try expectGroup(a, &corpus, .{}, "cafe", &.{ "cafe", "café" });
    // Five members (fuzzy-v1 keeps three): every one, by bytes at one df.
    try expectGroup(a, &corpus, .{}, "resume", &.{ "resume", "resumes", "resumé", "résumé", "résumés" });
    // Nothing shares the key: no group, whatever the term.
    try expectGroup(a, &corpus, .{}, "shelf", &.{});
    try expectGroup(a, &corpus, .{}, "zebras", &.{});
}

test "groups: members only from chunks in scope (labels, prefix) and visible titles under the prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const corpus = try makeCorpus(a, &docs);
    // `ponies` is held only by a label-hidden chunk: {pony} alone is no group.
    try expectGroup(a, &corpus, .{}, "pony", &.{});
    try expectGroup(a, &corpus, .{ .principal_labels = &.{"private"} }, "pony", &.{ "pony", "ponies" });
    // `kites` is only a hidden file's name: no member, no group.
    try expectGroup(a, &corpus, .{}, "kite", &.{});
    try expectGroup(a, &corpus, .{ .principal_labels = &.{"private"} }, "kite", &.{"kites"});
    // `dresses` is held only under school/: outside that prefix, no group.
    try expectGroup(a, &corpus, .{}, "dress", &.{ "dress", "dresses" });
    try expectGroup(a, &corpus, .{ .path_prefix = "r-home/home/" }, "dress", &.{});
    // `lunches` is only a visible folder's name: a title member (no body
    // postings, key df 0), after the body term.
    try expectGroup(a, &corpus, .{}, "lunch", &.{ "lunch", "lunches" });
    try expectGroup(a, &corpus, .{}, "lunches", &.{ "lunches", "lunch" });
    try expectGroup(a, &corpus, .{ .path_prefix = "r-home/home/" }, "lunch", &.{});
    var map = try fold.KeyMap.deriveIndexed(a, a, corpus.engine.lexical_index, &corpus.field);
    const context = fuzzy.Context{ .index = corpus.engine.lexical_index, .documents = corpus.engine.documents, .title = &corpus.field, .options = .{} };
    const groups = (try fold.compute(a, context, &map, &.{"lunch"})).?;
    try std.testing.expect(groups.items[0].members[0].body != null);
    try std.testing.expect(groups.items[0].members[1].body == null);
    try std.testing.expectEqual(@as(u32, 0), groups.items[0].members[1].key_df);
    // Without a title field to look in, a title-only term is no member.
    const untitled = fuzzy.Context{ .index = corpus.engine.lexical_index, .documents = corpus.engine.documents, .options = .{} };
    try std.testing.expect((try fold.compute(a, untitled, &map, &.{"lunch"})) == null);
}

test "through the engine: privacy, fuzzy-v1 on the ungrouped tokens only, the grouped trace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const corpus = try makeCorpus(a, &docs);
    const out = try a.alloc(hybrid.Result, docs.len);
    {
        var trace = hybrid.Trace{ .allocator = a, .io = std.testing.io };
        const results = try corpus.engine.queryTraced(a, "pony", &.{}, out, lexical(&corpus), &trace);
        try std.testing.expectEqual(@as(usize, 1), results.len);
        try std.testing.expectEqual(@as(usize, 0), trace.grouped.items.len);
    }
    {
        var options = lexical(&corpus);
        options.principal_labels = &.{"private"};
        var trace = hybrid.Trace{ .allocator = a, .io = std.testing.io };
        const results = try corpus.engine.queryTraced(a, "pony", &.{}, out, options, &trace);
        try std.testing.expectEqual(@as(usize, 2), results.len);
        try std.testing.expectEqual(@as(usize, 1), trace.grouped.items.len);
        try std.testing.expectEqualStrings("pony", trace.grouped.items[0].term);
        try std.testing.expectEqual(@as(usize, 1), trace.grouped.items[0].members.len);
        try std.testing.expectEqualStrings("ponies", trace.grouped.items[0].members[0]);
    }
    // `cafes` (5 Latin code points, held nowhere) would trigger fuzzy-v1; its
    // fold group is used instead, and fuzzy-v1 does not run on it.
    {
        var trace = hybrid.Trace{ .allocator = a, .io = std.testing.io };
        const results = try corpus.engine.queryTraced(a, "cafes", &.{}, out, lexical(&corpus), &trace);
        try std.testing.expectEqual(@as(usize, 3), results.len);
        try std.testing.expectEqual(@as(usize, 1), trace.grouped.items.len);
        try std.testing.expectEqual(@as(usize, 0), trace.expanded.items.len);
        try std.testing.expectEqual(@as(usize, 1), trace.unmatched.items.len);
    }
    {
        var options = lexical(&corpus);
        options.fold = false;
        var trace = hybrid.Trace{ .allocator = a, .io = std.testing.io };
        _ = try corpus.engine.queryTraced(a, "cafes", &.{}, out, options, &trace);
        try std.testing.expectEqual(@as(usize, 0), trace.grouped.items.len);
        try std.testing.expectEqual(@as(usize, 1), trace.expanded.items.len);
    }
}

test "scoring: the best member per chunk at one df; fold off ranks as before; no group ranks as before" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const corpus = try makeCorpus(a, &docs);
    var off = lexical(&corpus);
    off.fold = false;
    const on = lexical(&corpus);
    // box: s1 (boxes), s2 and s3 (box) at df_g 2 (box's), weight 1: the three
    // chunks score as the one term `box` would at df 2, each by its length.
    const grouped = try corpus.engine.queryTokenized(a, "box", &.{}, try a.alloc(hybrid.Result, docs.len), on);
    try std.testing.expectEqual(@as(usize, 3), grouped.len);
    const plain = try corpus.engine.queryTokenized(a, "box", &.{}, try a.alloc(hybrid.Result, docs.len), off);
    try std.testing.expectEqual(@as(usize, 2), plain.len);
    for (plain) |p| for (grouped) |g| if (std.mem.eql(u8, p.document_id, g.document_id)) {
        try std.testing.expectEqual(p.lexical_score, g.lexical_score);
    };
    // r1 holds five members once each: one counts, so its score is the one
    // term's (df 1, the same chunk), not five times it.
    const five = try corpus.engine.queryTokenized(a, "resume", &.{}, try a.alloc(hybrid.Result, docs.len), on);
    const one = try corpus.engine.queryTokenized(a, "resume", &.{}, try a.alloc(hybrid.Result, docs.len), off);
    try std.testing.expectEqual(@as(usize, 1), five.len);
    try std.testing.expectEqual(one[0].lexical_score, five[0].lexical_score);
    // A query with no group (and no fuzzy trigger) is identical on and off.
    for ([_][]const u8{ "shelf club", "boxing", "the a of", "opening hours" }) |q| {
        const x = try corpus.engine.queryTokenized(a, q, &.{}, try a.alloc(hybrid.Result, docs.len), on);
        const y = try corpus.engine.queryTokenized(a, q, &.{}, try a.alloc(hybrid.Result, docs.len), off);
        try std.testing.expectEqual(y.len, x.len);
        for (x, y) |p, q2| {
            try std.testing.expectEqualStrings(q2.document_id, p.document_id);
            try std.testing.expectEqual(q2.lexical_score, p.lexical_score);
            try std.testing.expectEqual(q2.fused_score, p.fused_score);
        }
    }
}

test "both: the body and the title part share the groups (title members included); the filename channel is not grouped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var corpus = try makeCorpus(a, &docs);
    const built = try filename_field.build(a, &docs, analyzer_v2.analyzer_id);
    corpus.engine.filename_index_enabled = true;
    corpus.engine.filename_decoded = try filename_field.decode(a, &docs, corpus.engine.lexical_index, built.catalog, built.lexical);
    const options = lexical(&corpus);
    // lunch: l1 by its body, t1 by its folder's name `lunches` (a title member).
    const hits = try corpus.engine.queryFields(a, "lunch", .both, options);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    const visit = for (hits) |hit| {
        if (std.mem.eql(u8, docs[hit.document_index].id, "t1")) break hit;
    } else return error.TestUnexpectedResult;
    try std.testing.expect(visit.title_score != null and visit.body_score == 0);
    var off = options;
    off.fold = false;
    try std.testing.expectEqual(@as(usize, 1), (try corpus.engine.queryFields(a, "lunch", .both, off)).len);
    // Five members through the body and title parts of `both`.
    const five = try corpus.engine.queryFields(a, "resume", .both, options);
    try std.testing.expectEqual(@as(usize, 1), five.len);
    // The filename field alone is the same with fold-groups-v1 on and off.
    for ([_][]const u8{ "lunch", "kites", "box", "cafe" }) |q| {
        const x = try corpus.engine.queryFields(a, q, .filename, options);
        const y = try corpus.engine.queryFields(a, q, .filename, off);
        try std.testing.expectEqual(y.len, x.len);
        for (x, y) |p, q2| {
            try std.testing.expectEqual(q2.document_index, p.document_index);
            try std.testing.expectEqual(q2.filename_score, p.filename_score);
        }
    }
    try std.testing.expect(!corpus.engine.foldApplies(.filename, options));
    try std.testing.expect(corpus.engine.foldApplies(.both, options));
    try std.testing.expect(!corpus.engine.foldApplies(.content, off));
}

// ------------------------------------------------------------ the report

const v2_docs =
    \\{"format_version":1,"generation":1,"analyzer_id":"analyzer-v2","embedding_model_id":"none","documents":[
    \\{"id":"a","path":"public/a.md","start_line":1,"end_line":1,"text":"boxes on the shelf","vector":[],"required_labels":[]},
    \\{"id":"b","path":"public/b.md","start_line":1,"end_line":1,"text":"a box and a café","vector":[],"required_labels":[]},
    \\{"id":"c","path":"public/c.md","start_line":1,"end_line":1,"text":"secret boxs cafe","vector":[],"required_labels":["tenant:acme"]}
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

test "warnings: query_term_grouped with its members, after an unmatched term's own; fold_policy_id beside fuzzy_policy_id" {
    var fixture = try Fixture.open(v2_docs);
    defer fixture.close();
    var report = try fixture.run("cafes dino boxes", "{\"retrieval_mode\":\"lexical\"}");
    defer report.deinit();
    const warnings = report.value.object.get("warnings").?.array.items;
    const expected = [_][2][]const u8{
        .{ "query_term_unmatched", "cafes" },
        .{ "query_term_grouped", "cafes" },
        .{ "query_term_unmatched", "dino" },
        .{ "query_term_grouped", "boxes" },
    };
    if (warnings.len != expected.len) for (warnings) |w| std.debug.print("{s} {s}\n", .{ w.object.get("code").?.string, w.object.get("term").?.string });
    try std.testing.expectEqual(expected.len, warnings.len);
    for (expected, warnings) |e, w| {
        try std.testing.expectEqualStrings(e[0], w.object.get("code").?.string);
        try std.testing.expectEqualStrings(e[1], w.object.get("term").?.string);
    }
    // cafe is held only by the tenant's chunk: the caller sees café alone.
    const cafes = warnings[1].object.get("members").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), cafes.len);
    try std.testing.expectEqualStrings("café", cafes[0].string);
    try std.testing.expectEqualStrings("also searched as: café", warnings[1].object.get("message").?.string);
    const boxes = warnings[3].object.get("members").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), boxes.len);
    try std.testing.expectEqualStrings("box", boxes[0].string);
    try std.testing.expect(report.value.object.get("results").?.array.items.len == 2);
    // Contract 2.5.0: the policy id sits beside fuzzy_policy_id.
    try std.testing.expectEqualStrings(fold.policy_id, report.value.object.get("retrieval").?.object.get("fold_policy_id").?.string);
    var vector = try fixture.run("boxes", "{\"retrieval_mode\":\"vector\"}");
    defer vector.deinit();
    try std.testing.expect(vector.value.object.get("retrieval").?.object.get("fold_policy_id") == null);
}

test "warnings: a member held only by a hidden chunk is never named" {
    var fixture = try Fixture.open(v2_docs);
    defer fixture.close();
    // cafe and boxs are held only by the tenant's chunk: members of café's
    // and box's groups for the tenant alone.
    var report = try fixture.run("café", "{\"retrieval_mode\":\"lexical\"}");
    defer report.deinit();
    for (report.value.object.get("warnings").?.array.items) |w| {
        try std.testing.expect(!std.mem.eql(u8, w.object.get("code").?.string, "query_term_grouped"));
    }
    var tenant = try fixture.run("café", "{\"retrieval_mode\":\"lexical\",\"principal_labels\":[\"tenant:acme\"]}");
    defer tenant.deinit();
    const warnings = tenant.value.object.get("warnings").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), warnings.len);
    try std.testing.expectEqualStrings("query_term_grouped", warnings[0].object.get("code").?.string);
    try std.testing.expectEqualStrings("cafe", warnings[0].object.get("members").?.array.items[0].string);
    var boxes = try fixture.run("boxes", "{\"retrieval_mode\":\"lexical\",\"principal_labels\":[\"tenant:acme\"]}");
    defer boxes.deinit();
    const members = boxes.value.object.get("warnings").?.array.items[0].object.get("members").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), members.len);
    try std.testing.expectEqualStrings("box", members[0].string);
    try std.testing.expectEqualStrings("boxs", members[1].string);
}
