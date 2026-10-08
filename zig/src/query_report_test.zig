//! S2-T4 (contract 1.2.0): `warnings`, `request` and the opt-in `profile` in
//! the `ss_query` report. Each warning code has a test that fails when its
//! emission is removed; `report.zig` is the emitter, `engine.queryTraced`
//! the source of the unmatched terms, `hybrid.searchSparseTraced` of the
//! candidate counts.
const std = @import("std");
const abi = @import("abi.zig");
const hybrid_module = @import("hybrid.zig");
const report_module = @import("report.zig");

const ascii_docs =
    \\{"format_version":1,"generation":1,"analyzer_id":"ascii-alnum-v1","embedding_model_id":"none","documents":[
    \\{"id":"a","path":"public/a.md","start_line":1,"end_line":1,"text":"hybrid retrieval ranks chunks","vector":[],"required_labels":[]},
    \\{"id":"b","path":"public/b.md","start_line":1,"end_line":1,"text":"hybrid search ranks","vector":[],"required_labels":[]},
    \\{"id":"c","path":"private/c.md","start_line":1,"end_line":1,"text":"secret hybrid zebra","vector":[],"required_labels":[]},
    \\{"id":"d","path":"public/d.md","start_line":1,"end_line":1,"text":"retrieval of things","vector":[],"required_labels":[]},
    \\{"id":"e","path":"public/e.md","start_line":1,"end_line":1,"text":"labelled quokka","vector":[],"required_labels":["tenant:acme"]}
    \\]}
;

const vector_docs =
    \\{"format_version":1,"generation":1,"analyzer_id":"ascii-alnum-v1","embedding_model_id":"manual-v1","documents":[
    \\{"id":"a","path":"a.md","start_line":1,"end_line":1,"text":"hybrid retrieval","vector":[1,0],"required_labels":[]},
    \\{"id":"b","path":"b.md","start_line":1,"end_line":1,"text":"hybrid search","vector":[0.5,0.5],"required_labels":[]},
    \\{"id":"c","path":"c.md","start_line":1,"end_line":1,"text":"other words","vector":[0,1],"required_labels":[]}
    \\]}
;

const v2_docs =
    \\{"format_version":1,"generation":1,"analyzer_id":"analyzer-v2","embedding_model_id":"none","documents":[
    \\{"id":"t","path":"t.md","start_line":1,"end_line":1,"text":"caf\u00e9 \u0ba4\u0bae\u0bbf\u0bb4\u0bcd \u0bae\u0bca\u0bb4\u0bbf","vector":[],"required_labels":[]}
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

    /// The raw report text (caller frees with `abi.ss_free`).
    fn raw(fixture: Fixture, text: [:0]const u8, vector: []const f32, top_k: usize, options: ?[:0]const u8) ![:0]u8 {
        const out = abi.ss_query(
            fixture.handle,
            text.ptr,
            if (vector.len == 0) null else vector.ptr,
            vector.len,
            top_k,
            if (options) |o| o.ptr else null,
        ) orelse return error.QueryFailed;
        return std.mem.span(out);
    }
};

const Parsed = std.json.Parsed(std.json.Value);

fn parse(text: []const u8) !Parsed {
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
}

/// How many warnings with `code` (and, when given, `term`) the report holds.
fn countWarnings(report: std.json.Value, code: []const u8, term: ?[]const u8) usize {
    var count: usize = 0;
    for (report.object.get("warnings").?.array.items) |item| {
        if (!std.mem.eql(u8, item.object.get("code").?.string, code)) continue;
        if (term) |wanted| {
            const found = item.object.get("term") orelse continue;
            if (!std.mem.eql(u8, found.string, wanted)) continue;
        }
        count += 1;
    }
    return count;
}

fn run(fixture: Fixture, text: [:0]const u8, vector: []const f32, top_k: usize, options: ?[:0]const u8) !Parsed {
    const out = try fixture.raw(text, vector, top_k, options);
    defer abi.ss_free(out.ptr);
    return parse(out);
}

test "query_term_unmatched names every word that matches no chunk (lexical, hybrid)" {
    var fixture = try Fixture.open(ascii_docs);
    defer fixture.close();

    var lexical = try run(fixture, "Hybrid DINOSAURUS ranks dinosaurus zzz", &.{}, 5, "{\"retrieval_mode\":\"lexical\"}");
    defer lexical.deinit();
    try std.testing.expectEqual(@as(usize, 1), countWarnings(lexical.value, "query_term_unmatched", "dinosaurus"));
    try std.testing.expectEqual(@as(usize, 1), countWarnings(lexical.value, "query_term_unmatched", "zzz"));
    try std.testing.expectEqual(@as(usize, 2), countWarnings(lexical.value, "query_term_unmatched", null));
    try std.testing.expect(lexical.value.object.get("results").?.array.items.len > 0);

    // Hybrid mode (no vectors in this snapshot) uses the words too.
    var hybrid = try run(fixture, "hybrid dinosaurus", &.{}, 5, null);
    defer hybrid.deinit();
    try std.testing.expectEqual(@as(usize, 1), countWarnings(hybrid.value, "query_term_unmatched", "dinosaurus"));

    // A word that exists is not reported.
    var clean = try run(fixture, "hybrid ranks", &.{}, 5, "{\"retrieval_mode\":\"lexical\"}");
    defer clean.deinit();
    try std.testing.expectEqual(@as(usize, 0), clean.value.object.get("warnings").?.array.items.len);
}

test "query_term_unmatched also covers a term present only outside the searched scope" {
    var fixture = try Fixture.open(ascii_docs);
    defer fixture.close();

    // `zebra` is only in private/c.md, `quokka` only in a chunk needing a label.
    var scoped = try run(fixture, "hybrid zebra quokka", &.{}, 5, "{\"retrieval_mode\":\"lexical\",\"path_prefix\":\"public/\"}");
    defer scoped.deinit();
    try std.testing.expectEqual(@as(usize, 1), countWarnings(scoped.value, "query_term_unmatched", "zebra"));
    try std.testing.expectEqual(@as(usize, 1), countWarnings(scoped.value, "query_term_unmatched", "quokka"));
    try std.testing.expectEqual(@as(usize, 0), countWarnings(scoped.value, "query_term_unmatched", "hybrid"));

    // With the label and without the prefix both are reachable.
    var open_scope = try run(fixture, "zebra quokka", &.{}, 5, "{\"retrieval_mode\":\"lexical\",\"principal_labels\":[\"tenant:acme\"]}");
    defer open_scope.deinit();
    try std.testing.expectEqual(@as(usize, 0), open_scope.value.object.get("warnings").?.array.items.len);
}

test "query terms are neither looked up nor warned about in vector mode" {
    var fixture = try Fixture.open(vector_docs);
    defer fixture.close();
    var vector = try run(fixture, "dinosaurus !!!", &.{ 1, 0 }, 3, "{\"retrieval_mode\":\"vector\"}");
    defer vector.deinit();
    try std.testing.expectEqual(@as(usize, 0), vector.value.object.get("warnings").?.array.items.len);
    try std.testing.expect(vector.value.object.get("results").?.array.items.len > 0);
    // The same query in hybrid mode does warn.
    var hybrid = try run(fixture, "dinosaurus", &.{ 1, 0 }, 3, null);
    defer hybrid.deinit();
    try std.testing.expectEqual(@as(usize, 1), countWarnings(hybrid.value, "query_term_unmatched", "dinosaurus"));
}

test "query_empty_after_analysis for punctuation, an empty query and unsearchable script" {
    var fixture = try Fixture.open(ascii_docs);
    defer fixture.close();
    for ([_][:0]const u8{ "?!... --", "", "   " }) |text| {
        var report = try run(fixture, text, &.{}, 5, "{\"retrieval_mode\":\"lexical\"}");
        defer report.deinit();
        try std.testing.expectEqual(@as(usize, 1), countWarnings(report.value, "query_empty_after_analysis", null));
        try std.testing.expectEqual(@as(usize, 0), countWarnings(report.value, "query_term_unmatched", null));
    }
    // ascii-alnum-v1 analyses Tamil to nothing.
    var tamil = try run(fixture, "\u{0ba4}\u{0bae}\u{0bbf}\u{0bb4}\u{0bcd}", &.{}, 5, null);
    defer tamil.deinit();
    try std.testing.expectEqual(@as(usize, 1), countWarnings(tamil.value, "query_empty_after_analysis", null));
    // A query with a word is not empty.
    var word = try run(fixture, "hybrid", &.{}, 5, null);
    defer word.deinit();
    try std.testing.expectEqual(@as(usize, 0), countWarnings(word.value, "query_empty_after_analysis", null));

    // Vector mode does not use the words: no warning even for "".
    var vector_fixture = try Fixture.open(vector_docs);
    defer vector_fixture.close();
    var vector = try run(vector_fixture, "?!", &.{ 1, 0 }, 3, "{\"retrieval_mode\":\"vector\"}");
    defer vector.deinit();
    try std.testing.expectEqual(@as(usize, 0), vector.value.object.get("warnings").?.array.items.len);
}

test "analyzer-v2 reports Unicode terms that match nothing" {
    var fixture = try Fixture.open(v2_docs);
    defer fixture.close();
    // NFC and case folding: "CAFE" + combining acute matches the stored "café".
    var report = try run(fixture, "CAFE\u{0301} dinosaur\u{00e9}s", &.{}, 5, "{\"retrieval_mode\":\"lexical\"}");
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 1), countWarnings(report.value, "query_term_unmatched", null));
    try std.testing.expectEqual(@as(usize, 1), countWarnings(report.value, "query_term_unmatched", "dinosaur\u{00e9}s"));
    try std.testing.expectEqualStrings("analyzer-v2", report.value.object.get("request").?.object.get("analyzer_id").?.string);
}

test "vector_ignored when a vector is passed and not used" {
    var fixture = try Fixture.open(vector_docs);
    defer fixture.close();
    var lexical = try run(fixture, "hybrid", &.{ 1, 0 }, 3, "{\"retrieval_mode\":\"lexical\"}");
    defer lexical.deinit();
    try std.testing.expectEqual(@as(usize, 1), countWarnings(lexical.value, "vector_ignored", null));
    // Used in hybrid and vector mode: no warning. None passed in lexical mode: none.
    var hybrid = try run(fixture, "hybrid", &.{ 1, 0 }, 3, null);
    defer hybrid.deinit();
    try std.testing.expectEqual(@as(usize, 0), countWarnings(hybrid.value, "vector_ignored", null));
    var none = try run(fixture, "hybrid", &.{}, 3, "{\"retrieval_mode\":\"lexical\"}");
    defer none.deinit();
    try std.testing.expectEqual(@as(usize, 0), countWarnings(none.value, "vector_ignored", null));

    // A snapshot without vectors ignores a passed vector in every mode.
    var plain = try Fixture.open(ascii_docs);
    defer plain.close();
    var plain_hybrid = try run(plain, "hybrid", &.{ 1, 0 }, 3, null);
    defer plain_hybrid.deinit();
    try std.testing.expectEqual(@as(usize, 1), countWarnings(plain_hybrid.value, "vector_ignored", null));
}

test "candidate_depth_cut in hybrid mode, for each channel that offered more than candidate_k" {
    var fixture = try Fixture.open(vector_docs);
    defer fixture.close();
    // `hybrid` is in 2 chunks and the query vector scores 2 chunks above zero.
    var cut = try run(fixture, "hybrid", &.{ 1, 0 }, 1, "{\"candidate_k\":1}");
    defer cut.deinit();
    try std.testing.expectEqual(@as(usize, 2), countWarnings(cut.value, "candidate_depth_cut", null));
    // candidate_k equal to the candidates, or above, cuts nothing.
    var exact = try run(fixture, "hybrid", &.{ 1, 0 }, 1, "{\"candidate_k\":2}");
    defer exact.deinit();
    try std.testing.expectEqual(@as(usize, 0), countWarnings(exact.value, "candidate_depth_cut", null));
    var deep = try run(fixture, "hybrid", &.{ 1, 0 }, 1, null);
    defer deep.deinit();
    try std.testing.expectEqual(@as(usize, 0), countWarnings(deep.value, "candidate_depth_cut", null));
}

test "candidate_depth_cut stays quiet in single-channel modes when candidate_k >= top_k" {
    var fixture = try Fixture.open(ascii_docs);
    defer fixture.close();
    // `hybrid` is in 3 chunks; candidate_k 2 cuts the list, but top_k 1 <= 2
    // so the returned list cannot change: no warning.
    var cut = try run(fixture, "hybrid", &.{}, 1, "{\"retrieval_mode\":\"lexical\",\"candidate_k\":2}");
    defer cut.deinit();
    try std.testing.expectEqual(@as(usize, 0), countWarnings(cut.value, "candidate_depth_cut", null));
    var deep = try run(fixture, "hybrid", &.{}, 1, "{\"retrieval_mode\":\"lexical\"}");
    defer deep.deinit();
    try std.testing.expectEqual(@as(usize, 0), countWarnings(deep.value, "candidate_depth_cut", null));

    var vectors = try Fixture.open(vector_docs);
    defer vectors.close();
    var vector_cut = try run(vectors, "zzz", &.{ 1, 1 }, 1, "{\"retrieval_mode\":\"vector\",\"candidate_k\":1}");
    defer vector_cut.deinit();
    try std.testing.expectEqual(@as(usize, 0), countWarnings(vector_cut.value, "candidate_depth_cut", null));
}

/// The ABI rejects `candidate_k < top_k`, so the single-channel positive case
/// is tested on the writer directly.
fn depthCutCount(mode: hybrid_module.RetrievalMode, top_k: usize, candidate_k: usize, offered: usize) !usize {
    var trace = hybrid_module.Trace{ .allocator = std.testing.allocator, .io = std.testing.io };
    trace.unique_terms = 1;
    trace.depth = @min(candidate_k, offered);
    trace.lexical_candidates = offered;
    trace.semantic_candidates = 0;
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var json = std.json.Stringify{ .writer = &out.writer };
    try json.beginObject();
    try report_module.write(&json, .{ .trace = &trace, .mode = mode, .analyzer_id = "ascii-alnum-v1", .top_k = top_k, .candidate_k = candidate_k, .path_prefix = null });
    try json.endObject();
    var parsed = try parse(out.written());
    defer parsed.deinit();
    return countWarnings(parsed.value, "candidate_depth_cut", null);
}

test "candidate_depth_cut in lexical mode needs candidate_k < top_k" {
    try std.testing.expectEqual(@as(usize, 1), try depthCutCount(.lexical, 5, 2, 9875));
    try std.testing.expectEqual(@as(usize, 0), try depthCutCount(.lexical, 5, 100, 9875));
    try std.testing.expectEqual(@as(usize, 0), try depthCutCount(.lexical, 5, 5, 9875));
    try std.testing.expectEqual(@as(usize, 1), try depthCutCount(.hybrid, 5, 100, 9875));
}

test "request echoes what was used, defaults included" {
    var fixture = try Fixture.open(ascii_docs);
    defer fixture.close();
    var report = try run(fixture, "hybrid", &.{}, 3, null);
    defer report.deinit();
    const request = report.value.object.get("request").?.object;
    try std.testing.expectEqualStrings("ascii-alnum-v1", request.get("analyzer_id").?.string);
    try std.testing.expectEqualStrings("hybrid", request.get("retrieval_mode").?.string);
    try std.testing.expectEqual(@as(i64, 3), request.get("top_k").?.integer);
    try std.testing.expectEqual(@as(i64, 100), request.get("candidate_k").?.integer);
    try std.testing.expect(request.get("path_prefix").? == .null);

    var set = try run(fixture, "hybrid", &.{}, 2, "{\"retrieval_mode\":\"lexical\",\"candidate_k\":7,\"path_prefix\":\"public/\"}");
    defer set.deinit();
    const used = set.value.object.get("request").?.object;
    try std.testing.expectEqualStrings("lexical", used.get("retrieval_mode").?.string);
    try std.testing.expectEqual(@as(i64, 2), used.get("top_k").?.integer);
    try std.testing.expectEqual(@as(i64, 7), used.get("candidate_k").?.integer);
    try std.testing.expectEqualStrings("public/", used.get("path_prefix").?.string);
}

test "profile appears only when asked for, and leaves the rest of the report unchanged" {
    var fixture = try Fixture.open(ascii_docs);
    defer fixture.close();

    const plain = try fixture.raw("hybrid retrieval", &.{}, 5, "{\"retrieval_mode\":\"lexical\"}");
    defer abi.ss_free(plain.ptr);
    try std.testing.expect(std.mem.indexOf(u8, plain, "\"profile\"") == null);
    const off = try fixture.raw("hybrid retrieval", &.{}, 5, "{\"retrieval_mode\":\"lexical\",\"profile\":false}");
    defer abi.ss_free(off.ptr);
    try std.testing.expectEqualStrings(plain, off);

    const profiled = try fixture.raw("hybrid retrieval", &.{}, 5, "{\"retrieval_mode\":\"lexical\",\"profile\":true}");
    defer abi.ss_free(profiled.ptr);
    // The profile is the last field; everything before it is the plain report.
    const marker = ",\"profile\":{\"tokenize_us\":";
    const at = std.mem.indexOf(u8, profiled, marker) orelse return error.NoProfile;
    try std.testing.expectEqualStrings(plain[0 .. plain.len - 1], profiled[0..at]);

    var parsed = try parse(profiled);
    defer parsed.deinit();
    const profile = parsed.value.object.get("profile").?.object;
    for ([_][]const u8{ "tokenize_us", "score_us", "rank_us", "serialize_us" }) |key| {
        try std.testing.expect(profile.get(key).?.integer >= 0);
    }
    // `hybrid` or `retrieval` is in chunks a, b, c and d.
    try std.testing.expectEqual(@as(i64, 4), profile.get("matched_chunks").?.integer);
}

test "vector mode reports zero matched chunks" {
    var fixture = try Fixture.open(vector_docs);
    defer fixture.close();
    var report = try run(fixture, "hybrid", &.{ 1, 0 }, 3, "{\"retrieval_mode\":\"vector\",\"profile\":true}");
    defer report.deinit();
    try std.testing.expectEqual(@as(i64, 0), report.value.object.get("profile").?.object.get("matched_chunks").?.integer);
}

test "an unknown option is still rejected" {
    var fixture = try Fixture.open(ascii_docs);
    defer fixture.close();
    try std.testing.expect(abi.ss_query(fixture.handle, "hybrid", null, 0, 3, "{\"bogus\":1}") == null);
    try std.testing.expect(abi.ss_query(fixture.handle, "hybrid", null, 0, 3, "{\"profile\":\"yes\"}") == null);
}
