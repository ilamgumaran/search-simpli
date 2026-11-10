//! S5-T5: fold-groups-v2's verb forms through the engine (`fold.compute`,
//! `verb_forms.zig`, `docs/fold-groups-v2.md`): a word the files do not hold
//! takes R's forms at 1.0 and is not also expanded by fuzzy-v1; a held word
//! takes a form at 0.5 only when its key df is not above the word's own (the
//! invariant: a held word's group never takes a df above the word's own
//! through R); members only from chunks in scope and visible titles under the
//! prefix. Invented content only.
const std = @import("std");
const analyzer_v2 = @import("analyzer_v2.zig");
const engine_module = @import("engine.zig");
const fold = @import("fold.zig");
const fuzzy = @import("fuzzy.zig");
const hybrid = @import("hybrid.zig");
const lexical_build = @import("lexical_build.zig");
const manifest = @import("manifest.zig");
const postings = @import("postings.zig");
const title_field = @import("title_field.zig");

const roots = [_]manifest.RootEntry{.{ .root_id = "r-home", .label = "home", .kind = "local", .retain_source = true }};

const docs = [_]hybrid.Document{
    .{ .id = "p1", .text = "painting the fence", .path = "r-home/home/fence.md", .start_line = 1, .end_line = 1 },
    .{ .id = "p2", .text = "painted the gate", .path = "r-home/home/gate.md", .start_line = 1, .end_line = 1 },
    .{ .id = "p3", .text = "the painted shed", .path = "r-home/home/shed.md", .start_line = 1, .end_line = 1 },
    .{ .id = "p4", .text = "paint pots", .path = "r-home/home/pots.md", .start_line = 1, .end_line = 1 },
    .{ .id = "p5", .text = "painting day", .path = "r-home/home/day.md", .start_line = 1, .end_line = 1 },
    .{ .id = "j1", .text = "juggled three balls", .path = "r-home/other/more.md", .start_line = 1, .end_line = 1 },
    .{ .id = "j2", .text = "secret juggling practice", .path = "r-home/private/plan.md", .start_line = 1, .end_line = 1, .required_labels = "private" },
    .{ .id = "k1", .text = "rink times", .path = "r-home/private/skating-plan.md", .start_line = 1, .end_line = 1, .required_labels = "private" },
    .{ .id = "d1", .text = "we went dancing", .path = "r-home/school/disco.md", .start_line = 1, .end_line = 1 },
    .{ .id = "s1", .text = "snow on the hill", .path = "r-home/days-out/sledging.md", .start_line = 1, .end_line = 1 },
    .{ .id = "b1", .text = "baking bread baked beans bakes", .path = "r-home/home/kitchen.md", .start_line = 1, .end_line = 1 },
    .{ .id = "b2", .text = "bake sale", .path = "r-home/school/sale.md", .start_line = 1, .end_line = 1 },
    .{ .id = "b3", .text = "baking trays", .path = "r-home/home/trays.md", .start_line = 1, .end_line = 1 },
    .{ .id = "b4", .text = "baking again", .path = "r-home/home/again.md", .start_line = 1, .end_line = 1 },
};

const Corpus = struct {
    engine: engine_module.Engine,
    field: title_field.Field,
};

/// The corpus with its dictionary sorted bytewise (as HYBLEX02 is).
fn makeCorpus(a: std.mem.Allocator) !Corpus {
    const token_lists = try a.alloc([][]const u8, docs.len);
    for (docs, token_lists) |doc, *tokens_out| tokens_out.* = try analyzer_v2.tokenize(a, doc.text);
    var index = try lexical_build.build(a, &docs, token_lists);
    const terms = try a.dupe(postings.TermEntry, index.terms);
    std.mem.sort(postings.TermEntry, terms, {}, struct {
        fn less(_: void, x: postings.TermEntry, y: postings.TermEntry) bool {
            return std.mem.order(u8, x.term, y.term) == .lt;
        }
    }.less);
    index.terms = terms;
    index.sorted_terms = true;
    const derived = try title_field.derive(a, a, &docs, &roots);
    return .{
        .engine = .{ .generation = 1, .analyzer_id = analyzer_v2.analyzer_id, .embedding_model_id = "", .vector_dimensions = 0, .documents = &docs, .lexical_index = index, .roots = &roots },
        .field = derived.field,
    };
}

fn groupOf(a: std.mem.Allocator, corpus: *const Corpus, options: hybrid.SearchOptions, typed: []const u8) ![]const fuzzy.Member {
    var map = try fold.KeyMap.deriveIndexed(a, a, corpus.engine.lexical_index, &corpus.field);
    const context = fuzzy.Context{ .index = corpus.engine.lexical_index, .documents = corpus.engine.documents, .title = &corpus.field, .options = options };
    const groups = try fold.compute(a, context, &map, &.{typed});
    return if (groups) |g| g.items[0].members else &.{};
}

/// The members and their weights `fold.compute` gives `typed` (empty: no group).
fn expectWeighted(a: std.mem.Allocator, corpus: *const Corpus, options: hybrid.SearchOptions, typed: []const u8, expected: []const []const u8, weights: []const f32) !void {
    const members = try groupOf(a, corpus, options, typed);
    if (members.len != expected.len) {
        std.debug.print("{s}: got", .{typed});
        for (members) |m| std.debug.print(" {s}({d}, {d})", .{ m.term, m.key_df, m.weight });
        std.debug.print("\n", .{});
    }
    try std.testing.expectEqual(expected.len, members.len);
    for (members, expected, weights) |m, e, w| {
        try std.testing.expectEqualStrings(e, m.term);
        try std.testing.expectEqual(w, m.weight);
    }
}

fn lexical(corpus: *const Corpus) hybrid.SearchOptions {
    return .{ .top_k = docs.len, .candidate_k = docs.len, .retrieval_mode = .lexical, .title = &corpus.field };
}

test "R: a word no chunk and no title holds takes its forms at 1.0, and fuzzy-v1 does not also run on it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const corpus = try makeCorpus(a);
    try expectWeighted(a, &corpus, .{}, "danced", &.{"dancing"}, &.{1.0});
    // R's forms of `bakery` (bakeries, ...) are held nowhere: no group.
    try expectWeighted(a, &corpus, .{}, "bakery", &.{}, &.{});
    const out = try a.alloc(hybrid.Result, docs.len);
    var trace = hybrid.Trace{ .allocator = a, .io = std.testing.io };
    const results = try corpus.engine.queryTraced(a, "danced", &.{}, out, lexical(&corpus), &trace);
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("d1", results[0].document_id);
    try std.testing.expectEqual(@as(usize, 1), trace.grouped.items.len);
    try std.testing.expectEqualStrings("dancing", trace.grouped.items[0].members[0]);
    try std.testing.expectEqual(@as(usize, 0), trace.expanded.items.len);
    // Fold off: fuzzy-v1 alone, which does not reach `dancing`.
    var off = lexical(&corpus);
    off.fold = false;
    var trace_off = hybrid.Trace{ .allocator = a, .io = std.testing.io };
    _ = try corpus.engine.queryTraced(a, "danced", &.{}, out, off, &trace_off);
    try std.testing.expectEqual(@as(usize, 0), trace_off.grouped.items.len);
}

test "R: a held word takes a form at 0.5 only when the form's key df is not above its own" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const corpus = try makeCorpus(a);
    // painting (df 2): painted (df 2) and paint (df 1) join at 0.5.
    try expectWeighted(a, &corpus, .{}, "painting", &.{ "painting", "painted", "paint" }, &.{ 1.0, 0.5, 0.5 });
    // paint (df 1): painting and painted (df 2) are above it: no group.
    try expectWeighted(a, &corpus, .{}, "paint", &.{}, &.{});
    // baked (df 1): bake and bakes (df 1 each; bakes keys to bake, not to
    // baked, so it is R-only) join; baking (df 3) does not.
    try expectWeighted(a, &corpus, .{}, "baked", &.{ "baked", "bake", "bakes" }, &.{ 1.0, 0.5, 0.5 });
    // The scores: painting's group df stays painting's own (2).
    const groups = try groupOf(a, &corpus, .{}, "painting");
    const group = fuzzy.Group{ .typed = "painting", .members = groups };
    try std.testing.expectEqual(@as(u32, 2), group.bodyFrequency());
}

test "R: the invariant, on every held word of the corpus: no R-only member's key df above the word's own, the group df unchanged by R" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const corpus = try makeCorpus(a);
    var checked: usize = 0;
    for (corpus.engine.lexical_index.terms) |entry| {
        const members = try groupOf(a, &corpus, .{}, entry.term);
        if (members.len == 0) continue;
        // The df of the members at 1.0 (the word, its key-mates, and an
        // unheld word's R members): R's members at 0.5 never raise it.
        var v1_df: u32 = 0;
        for (members) |m| if (m.weight == 1.0 and m.body != null) {
            v1_df = @max(v1_df, m.key_df);
        };
        for (members) |m| if (m.weight != 1.0) {
            try std.testing.expect(m.key_df <= entry.document_frequency);
            checked += 1;
        };
        const group = fuzzy.Group{ .typed = entry.term, .members = members };
        try std.testing.expectEqual(v1_df, group.bodyFrequency());
    }
    try std.testing.expect(checked >= 4);
}

test "R: members only from chunks in scope and visible titles under the prefix; the form held by a hidden chunk or a hidden name is not named" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const corpus = try makeCorpus(a);
    // juggling is held only by a label-hidden chunk.
    try expectWeighted(a, &corpus, .{}, "juggle", &.{"juggled"}, &.{1.0});
    try expectWeighted(a, &corpus, .{ .principal_labels = &.{"private"} }, "juggle", &.{ "juggled", "juggling" }, &.{ 1.0, 1.0 });
    try expectWeighted(a, &corpus, .{ .principal_labels = &.{"private"}, .path_prefix = "r-home/home/" }, "juggle", &.{}, &.{});
    // skating is only a hidden file's name.
    try expectWeighted(a, &corpus, .{}, "skated", &.{}, &.{});
    try expectWeighted(a, &corpus, .{ .principal_labels = &.{"private"} }, "skated", &.{"skating"}, &.{1.0});
    // sledging is only a visible file's name: a title member (no body postings).
    try expectWeighted(a, &corpus, .{}, "sledged", &.{"sledging"}, &.{1.0});
    const sledging = try groupOf(a, &corpus, .{}, "sledged");
    try std.testing.expect(sledging[0].body == null);
    try expectWeighted(a, &corpus, .{ .path_prefix = "r-home/home/" }, "sledged", &.{}, &.{});
    // Through the engine: the hidden chunk is neither a hit nor a member.
    const out = try a.alloc(hybrid.Result, docs.len);
    var trace = hybrid.Trace{ .allocator = a, .io = std.testing.io };
    const results = try corpus.engine.queryTraced(a, "juggle", &.{}, out, lexical(&corpus), &trace);
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("j1", results[0].document_id);
    try std.testing.expectEqual(@as(usize, 1), trace.grouped.items[0].members.len);
}

test "R: fold off ranks as before; a word R does not apply to ranks as with fold-groups-v1" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const corpus = try makeCorpus(a);
    // Under four letters, digits, or no form held: no R member.
    for ([_][]const u8{ "shed", "rink2", "fence", "gate" }) |q| try expectWeighted(a, &corpus, .{}, q, &.{}, &.{});
    var off = lexical(&corpus);
    off.fold = false;
    const on = lexical(&corpus);
    for ([_][]const u8{ "fence gate", "snow hill", "the" }) |q| {
        const x = try corpus.engine.queryTokenized(a, q, &.{}, try a.alloc(hybrid.Result, docs.len), on);
        const y = try corpus.engine.queryTokenized(a, q, &.{}, try a.alloc(hybrid.Result, docs.len), off);
        try std.testing.expectEqual(y.len, x.len);
        for (x, y) |p, q2| {
            try std.testing.expectEqualStrings(q2.document_id, p.document_id);
            try std.testing.expectEqual(q2.lexical_score, p.lexical_score);
        }
    }
}
