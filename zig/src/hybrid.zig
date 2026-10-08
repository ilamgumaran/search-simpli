const analysis = @import("analysis.zig");
const scoring = @import("scoring.zig");
const std = @import("std");

pub const Document = struct {
    id: []const u8,
    text: []const u8,
    vector: []const f32 = &.{},
    path: []const u8 = "",
    start_line: u32 = 0,
    end_line: u32 = 0,
    /// Canonical newline-separated labels; every label is required.
    required_labels: []const u8 = "",
};

pub const SearchOptions = struct {
    top_k: usize = 10,
    candidate_k: usize = 100,
    rrf_k: f32 = 60,
    bm25: scoring.Bm25Parameters = .{},
    retrieval_mode: RetrievalMode = .hybrid,
    path_prefix: ?[]const u8 = null,
    principal_labels: []const []const u8 = &.{},
};

pub const RetrievalMode = enum { lexical, vector, hybrid };

pub const Result = struct {
    document_index: usize,
    document_id: []const u8,
    path: []const u8,
    start_line: u32,
    end_line: u32,
    lexical_score: f32,
    semantic_score: f32,
    lexical_rank: ?usize,
    semantic_rank: ?usize,
    fused_score: f32,
};

pub const SearchError = error{
    WorkspaceTooSmall,
    VectorDimensionMismatch,
    LexicalScoreCountMismatch,
};

/// Allocation-free exhaustive hybrid retrieval.
/// Complexity is intentionally simple: O(query_terms * documents^2) lexical
/// statistics for this correctness oracle, plus O(documents * log(documents))
/// ranking. Persistent postings replace the lexical scans in the engine path
/// while preserving Result semantics.
pub fn search(
    query: []const u8,
    query_vector: []const f32,
    documents: []const Document,
    workspace: []Result,
    options: SearchOptions,
) SearchError![]Result {
    if (workspace.len < documents.len) return error.WorkspaceTooSmall;
    if (documents.len == 0 or options.top_k == 0) return workspace[0..0];

    var total_document_length: usize = 0;
    for (documents) |document| total_document_length += analysis.tokenCount(document.text);
    const average_document_length = @as(f32, @floatFromInt(total_document_length)) /
        @as(f32, @floatFromInt(documents.len));

    for (documents, 0..) |document, document_index| {
        workspace[document_index] = .{
            .document_index = document_index,
            .document_id = document.id,
            .path = document.path,
            .start_line = document.start_line,
            .end_line = document.end_line,
            .lexical_score = lexicalScore(
                query,
                document,
                documents,
                average_document_length,
                options.bm25,
            ),
            .semantic_score = 0,
            .lexical_rank = null,
            .semantic_rank = null,
            .fused_score = 0,
        };
    }

    return finishSearch(query_vector, documents, workspace[0..documents.len], options);
}

/// Fuse caller-supplied lexical scores with exact semantic scores. Persistent
/// postings use this path so ranking/fusion semantics stay identical to the
/// scan-based correctness oracle above.
pub fn searchWithLexicalScores(
    query_vector: []const f32,
    documents: []const Document,
    lexical_scores: []const f32,
    workspace: []Result,
    options: SearchOptions,
) SearchError![]Result {
    if (workspace.len < documents.len) return error.WorkspaceTooSmall;
    if (lexical_scores.len != documents.len) return error.LexicalScoreCountMismatch;
    if (documents.len == 0 or options.top_k == 0) return workspace[0..0];

    for (documents, lexical_scores, 0..) |document, lexical_score, document_index| {
        workspace[document_index] = .{
            .document_index = document_index,
            .document_id = document.id,
            .path = document.path,
            .start_line = document.start_line,
            .end_line = document.end_line,
            .lexical_score = lexical_score,
            .semantic_score = 0,
            .lexical_rank = null,
            .semantic_rank = null,
            .fused_score = 0,
        };
    }
    return finishSearch(query_vector, documents, workspace[0..documents.len], options);
}

fn finishSearch(
    query_vector: []const f32,
    documents: []const Document,
    results: []Result,
    options: SearchOptions,
) SearchError![]Result {
    for (documents, results) |document, *result| {
        if (!matchesPath(document.path, options.path_prefix) or
            !isAuthorized(document.required_labels, options.principal_labels))
        {
            result.lexical_score = 0;
            result.semantic_score = 0;
            continue;
        }
        if (options.retrieval_mode == .vector) result.lexical_score = 0;
        result.semantic_score = if (options.retrieval_mode == .lexical)
            0
        else
            semanticScore(query_vector, document.vector) catch return error.VectorDimensionMismatch;
    }

    assignRanks(results, .lexical);
    assignRanks(results, .semantic);
    for (results) |*result| {
        if (result.lexical_rank != null and result.lexical_rank.? > options.candidate_k) result.lexical_rank = null;
        if (result.semantic_rank != null and result.semantic_rank.? > options.candidate_k) result.semantic_rank = null;
        result.fused_score = scoring.reciprocalRankContribution(result.lexical_rank, options.rrf_k) +
            scoring.reciprocalRankContribution(result.semantic_rank, options.rrf_k);
    }
    sortByFusedScore(results);

    var result_count: usize = 0;
    while (result_count < results.len and results[result_count].fused_score > 0) result_count += 1;
    return results[0..@min(result_count, options.top_k)];
}

/// One chunk a lexical source matched, with its summed BM25 score.
pub const LexicalMatch = struct {
    document_index: u32,
    score: f32,
};

/// Lexical scores supplied as a dense array (one entry per document). Adapter
/// for callers and tests that already hold dense scores; the persistent
/// postings path uses `postings.SparseScorer` and never builds this array.
pub const DenseLexical = struct {
    scores: []const f32,
    position: usize = 0,

    pub fn next(source: *DenseLexical) ?LexicalMatch {
        while (source.position < source.scores.len) {
            const index = source.position;
            source.position += 1;
            if (source.scores[index] != 0) return .{ .document_index = @intCast(index), .score = source.scores[index] };
        }
        return null;
    }

    pub fn scoreOf(source: *const DenseLexical, document_index: usize) f32 {
        return source.scores[document_index];
    }
};

const Candidate = struct {
    document_index: u32,
    score: f32,
};

fn candidateBefore(left: Candidate, right: Candidate) bool {
    if (left.score != right.score) return left.score > right.score;
    return left.document_index < right.document_index;
}

fn candidateLess(_: void, left: Candidate, right: Candidate) bool {
    return candidateBefore(left, right);
}

/// Bounded selection of the `capacity` best candidates under
/// `candidateBefore`, a total order (the document index breaks every tie), so
/// the survivors are exactly the first `capacity` of a full sort. The heap
/// root is the worst survivor.
const TopK = struct {
    items: []Candidate,
    count: usize = 0,

    fn offer(top: *TopK, candidate: Candidate) void {
        if (top.items.len == 0) return;
        if (top.count < top.items.len) {
            top.items[top.count] = candidate;
            top.count += 1;
            top.siftUp(top.count - 1);
        } else if (candidateBefore(candidate, top.items[0])) {
            top.items[0] = candidate;
            top.siftDown(0);
        }
    }

    // Invariant: a parent never comes before (is never better than) its children.
    fn siftUp(top: *TopK, start: usize) void {
        var child = start;
        while (child > 0) {
            const parent = (child - 1) / 2;
            if (!candidateBefore(top.items[parent], top.items[child])) break;
            std.mem.swap(Candidate, &top.items[parent], &top.items[child]);
            child = parent;
        }
    }

    fn siftDown(top: *TopK, start: usize) void {
        var parent = start;
        while (true) {
            var worst = parent;
            const left = 2 * parent + 1;
            const right = left + 1;
            if (left < top.count and candidateBefore(top.items[worst], top.items[left])) worst = left;
            if (right < top.count and candidateBefore(top.items[worst], top.items[right])) worst = right;
            if (worst == parent) return;
            std.mem.swap(Candidate, &top.items[parent], &top.items[worst]);
            parent = worst;
        }
    }

    fn sorted(top: *TopK) []Candidate {
        std.sort.pdq(Candidate, top.items[0..top.count], {}, candidateLess);
        return top.items[0..top.count];
    }
};

const Fused = struct {
    document_index: u32,
    lexical_rank: u32 = 0,
    semantic_rank: u32 = 0,
    lexical_score: f32 = 0,
    semantic_score: f32 = 0,
    fused_score: f32 = 0,
};

fn fusedByDocument(_: void, left: Fused, right: Fused) bool {
    return left.document_index < right.document_index;
}

fn fusedBefore(_: void, left: Fused, right: Fused) bool {
    if (left.fused_score != right.fused_score) return left.fused_score > right.fused_score;
    return left.document_index < right.document_index;
}

/// Ranks only the chunks that can reach the result list. Produces exactly the
/// output of `searchWithLexicalScores` (same scores, ranks, fused scores and
/// order, including every `document_index` tiebreak) without ordering the
/// corpus:
///
/// * the lexical channel ranks only chunks the source matched (nonzero score),
///   keeping a bounded top `candidate_k`;
/// * the semantic channel runs only when `query_vector` is non-empty and the
///   mode is not `.lexical` (the caller passes an empty vector for a snapshot
///   with zero vector dimensions);
/// * fusion runs over the union of the two candidate sets.
///
/// `lexical` is any type with `next() ?LexicalMatch` (matches in ascending
/// `document_index`, scores summed in the same order as the dense path) and
/// `scoreOf(document_index) f32`. Scratch comes from `allocator` and is
/// released before returning: proportional to `min(candidate_k, documents)`,
/// never to the corpus. `workspace` only has to hold `min(top_k, documents)`
/// results.
pub fn searchSparse(
    comptime Lexical: type,
    allocator: std.mem.Allocator,
    lexical: *Lexical,
    query_vector: []const f32,
    documents: []const Document,
    workspace: []Result,
    options: SearchOptions,
) (SearchError || std.mem.Allocator.Error)![]Result {
    if (workspace.len < @min(options.top_k, documents.len)) return error.WorkspaceTooSmall;
    if (documents.len == 0 or options.top_k == 0) return workspace[0..0];

    const want_lexical = options.retrieval_mode != .vector;
    const want_semantic = options.retrieval_mode != .lexical and query_vector.len != 0;
    const depth = @min(options.candidate_k, documents.len);

    const lexical_storage = try allocator.alloc(Candidate, if (want_lexical) depth else 0);
    defer allocator.free(lexical_storage);
    const semantic_storage = try allocator.alloc(Candidate, if (want_semantic) depth else 0);
    defer allocator.free(semantic_storage);
    var lexical_top = TopK{ .items = lexical_storage };
    var semantic_top = TopK{ .items = semantic_storage };

    if (want_lexical) {
        while (lexical.next()) |match| {
            if (!(match.score <= 0)) {
                const document = documents[match.document_index];
                if (matchesPath(document.path, options.path_prefix) and
                    isAuthorized(document.required_labels, options.principal_labels))
                {
                    lexical_top.offer(.{ .document_index = match.document_index, .score = match.score });
                }
            }
        }
    }
    if (want_semantic) {
        for (documents, 0..) |document, document_index| {
            if (!matchesPath(document.path, options.path_prefix) or
                !isAuthorized(document.required_labels, options.principal_labels)) continue;
            const score = semanticScore(query_vector, document.vector) catch return error.VectorDimensionMismatch;
            if (!(score <= 0)) semantic_top.offer(.{ .document_index = @intCast(document_index), .score = score });
        }
    }

    const lexical_ranked = lexical_top.sorted();
    const semantic_ranked = semantic_top.sorted();

    const union_storage = try allocator.alloc(Fused, lexical_ranked.len + semantic_ranked.len);
    defer allocator.free(union_storage);
    for (lexical_ranked, 0..) |candidate, index| {
        union_storage[index] = .{
            .document_index = candidate.document_index,
            .lexical_rank = @intCast(index + 1),
            .lexical_score = candidate.score,
        };
    }
    for (semantic_ranked, 0..) |candidate, index| {
        union_storage[lexical_ranked.len + index] = .{
            .document_index = candidate.document_index,
            .semantic_rank = @intCast(index + 1),
            .semantic_score = candidate.score,
        };
    }
    std.sort.pdq(Fused, union_storage, {}, fusedByDocument);

    // Merge the (at most two) entries of one document.
    var merged: usize = 0;
    for (union_storage) |entry| {
        if (merged > 0 and union_storage[merged - 1].document_index == entry.document_index) {
            const into = &union_storage[merged - 1];
            if (entry.lexical_rank != 0) {
                into.lexical_rank = entry.lexical_rank;
                into.lexical_score = entry.lexical_score;
            }
            if (entry.semantic_rank != 0) {
                into.semantic_rank = entry.semantic_rank;
                into.semantic_score = entry.semantic_score;
            }
        } else {
            union_storage[merged] = entry;
            merged += 1;
        }
    }
    const fused = union_storage[0..merged];
    for (fused) |*entry| {
        entry.fused_score = scoring.reciprocalRankContribution(if (entry.lexical_rank != 0) entry.lexical_rank else null, options.rrf_k) +
            scoring.reciprocalRankContribution(if (entry.semantic_rank != 0) entry.semantic_rank else null, options.rrf_k);
    }
    std.sort.pdq(Fused, fused, {}, fusedBefore);

    var result_count: usize = 0;
    while (result_count < fused.len and fused[result_count].fused_score > 0) result_count += 1;
    result_count = @min(result_count, options.top_k);

    for (fused[0..result_count], workspace[0..result_count]) |entry, *result| {
        const document = documents[entry.document_index];
        // A chunk ranked by one channel still reports its score in the other
        // (the dense path scored every chunk), even when that rank is past
        // `candidate_k`.
        const lexical_score = if (!want_lexical)
            0
        else if (entry.lexical_rank != 0)
            entry.lexical_score
        else
            lexical.scoreOf(entry.document_index);
        const semantic_score = if (!want_semantic)
            0
        else if (entry.semantic_rank != 0)
            entry.semantic_score
        else
            semanticScore(query_vector, document.vector) catch return error.VectorDimensionMismatch;
        result.* = .{
            .document_index = entry.document_index,
            .document_id = document.id,
            .path = document.path,
            .start_line = document.start_line,
            .end_line = document.end_line,
            .lexical_score = lexical_score,
            .semantic_score = semantic_score,
            .lexical_rank = if (entry.lexical_rank != 0) entry.lexical_rank else null,
            .semantic_rank = if (entry.semantic_rank != 0) entry.semantic_rank else null,
            .fused_score = entry.fused_score,
        };
    }
    return workspace[0..result_count];
}

fn matchesPath(path: []const u8, prefix: ?[]const u8) bool {
    const required = prefix orelse return true;
    return std.mem.startsWith(u8, path, required);
}

pub fn isAuthorized(required_labels: []const u8, principal_labels: []const []const u8) bool {
    if (required_labels.len == 0) return true;
    var labels = std.mem.splitScalar(u8, required_labels, '\n');
    while (labels.next()) |required| {
        var found = false;
        for (principal_labels) |present| {
            if (std.mem.eql(u8, required, present)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn lexicalScore(
    query: []const u8,
    document: Document,
    documents: []const Document,
    average_document_length: f32,
    parameters: scoring.Bm25Parameters,
) f32 {
    if (average_document_length == 0) return 0;
    var score: f32 = 0;
    var query_tokens = analysis.TokenIterator.init(query);
    while (query_tokens.next()) |query_token| {
        if (!analysis.isFirstOccurrence(query, query_token)) continue;
        const frequency = analysis.termFrequency(document.text, query_token.bytes);
        if (frequency == 0) continue;

        var document_frequency: u32 = 0;
        for (documents) |candidate| {
            if (analysis.termFrequency(candidate.text, query_token.bytes) > 0) document_frequency += 1;
        }
        score += scoring.bm25Contribution(
            @floatFromInt(frequency),
            @floatFromInt(analysis.tokenCount(document.text)),
            average_document_length,
            document_frequency,
            @intCast(documents.len),
            parameters,
        );
    }
    return score;
}

fn semanticScore(query_vector: []const f32, document_vector: []const f32) scoring.VectorError!f32 {
    if (query_vector.len == 0 or document_vector.len == 0) return 0;
    return scoring.cosineSimilarity(query_vector, document_vector);
}

const RankChannel = enum { lexical, semantic };

fn assignRanks(results: []Result, channel: RankChannel) void {
    // The document index is the stable tie-breaker. Sorting may reorder the
    // workspace between channels, so relying on the current slice position
    // would make semantic ranks depend on whether lexical ranking ran first.
    std.sort.pdq(Result, results, channel, channelComesBefore);
    for (results, 0..) |*result, index| {
        if (channelScore(result.*, channel) <= 0) continue;
        switch (channel) {
            .lexical => result.lexical_rank = index + 1,
            .semantic => result.semantic_rank = index + 1,
        }
    }
}

fn channelComesBefore(channel: RankChannel, left: Result, right: Result) bool {
    const left_score = channelScore(left, channel);
    const right_score = channelScore(right, channel);
    if (left_score != right_score) return left_score > right_score;
    return left.document_index < right.document_index;
}

fn channelScore(result: Result, channel: RankChannel) f32 {
    return switch (channel) {
        .lexical => result.lexical_score,
        .semantic => result.semantic_score,
    };
}

fn sortByFusedScore(results: []Result) void {
    std.sort.pdq(Result, results, {}, fusedComesBefore);
}

fn fusedComesBefore(_: void, left: Result, right: Result) bool {
    return comesBefore(left, right);
}

fn comesBefore(left: Result, right: Result) bool {
    if (left.fused_score != right.fused_score) return left.fused_score > right.fused_score;
    return left.document_index < right.document_index;
}

test "lexical search ranks an exact rare term" {
    const documents = [_]Document{
        .{ .id = "engine", .text = "postings store identifiers for lexical retrieval", .path = "docs/engine.md", .start_line = 4, .end_line = 8 },
        .{ .id = "orchard", .text = "apples and pears grow here" },
        .{ .id = "other", .text = "retrieval finds useful evidence" },
    };
    var workspace: [documents.len]Result = undefined;
    const results = try search("postings identifiers", &.{}, &documents, &workspace, .{});
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("engine", results[0].document_id);
    try std.testing.expectEqualStrings("docs/engine.md", results[0].path);
    try std.testing.expectEqual(@as(u32, 4), results[0].start_line);
    try std.testing.expectEqual(@as(u32, 8), results[0].end_line);
    try std.testing.expectEqual(@as(?usize, 1), results[0].lexical_rank);
    try std.testing.expectEqual(@as(?usize, null), results[0].semantic_rank);
}

test "semantic vectors retrieve a paraphrase without lexical overlap" {
    const documents = [_]Document{
        .{ .id = "vehicle", .text = "an automobile moves on roads", .vector = &.{ 1, 0 } },
        .{ .id = "fruit", .text = "an apple grows in an orchard", .vector = &.{ 0, 1 } },
    };
    var workspace: [documents.len]Result = undefined;
    const results = try search("transportation", &.{ 1, 0 }, &documents, &workspace, .{});
    try std.testing.expectEqualStrings("vehicle", results[0].document_id);
    try std.testing.expectEqual(@as(?usize, null), results[0].lexical_rank);
    try std.testing.expectEqual(@as(?usize, 1), results[0].semantic_rank);
}

test "optimized ranking preserves channel ties candidate cutoffs and fused order" {
    const documents = [_]Document{
        .{ .id = "zero", .text = "zero", .vector = &.{ 0.9, 0.1 } },
        .{ .id = "one", .text = "one", .vector = &.{ 1, 0 } },
        .{ .id = "two", .text = "two", .vector = &.{ 0, 1 } },
        .{ .id = "three", .text = "three", .vector = &.{ 0.5, 0.5 } },
        .{ .id = "four", .text = "four", .vector = &.{ 1, 0 } },
    };
    const lexical_scores = [_]f32{ 2, 4, 4, 0, 1 };
    var workspace: [documents.len]Result = undefined;
    const results = try searchWithLexicalScores(
        &.{ 1, 0 },
        &documents,
        &lexical_scores,
        &workspace,
        .{ .top_k = 5, .candidate_k = 3 },
    );

    try std.testing.expectEqual(@as(usize, 4), results.len);
    try std.testing.expectEqualStrings("one", results[0].document_id);
    try std.testing.expectEqual(@as(?usize, 1), results[0].lexical_rank);
    try std.testing.expectEqual(@as(?usize, 1), results[0].semantic_rank);
    try std.testing.expectEqualStrings("zero", results[1].document_id);
    try std.testing.expectEqual(@as(?usize, 3), results[1].lexical_rank);
    try std.testing.expectEqual(@as(?usize, 3), results[1].semantic_rank);
    try std.testing.expectEqualStrings("two", results[2].document_id);
    try std.testing.expectEqual(@as(?usize, 2), results[2].lexical_rank);
    try std.testing.expectEqual(@as(?usize, null), results[2].semantic_rank);
    try std.testing.expectEqualStrings("four", results[3].document_id);
    try std.testing.expectEqual(@as(?usize, null), results[3].lexical_rank);
    try std.testing.expectEqual(@as(?usize, 2), results[3].semantic_rank);
}

test "RRF rewards a document supported by both channels" {
    const documents = [_]Document{
        .{ .id = "both", .text = "quasar background", .vector = &.{ 0.8, 0.2 } },
        .{ .id = "lexical", .text = "quasar quasar quasar", .vector = &.{ 0, 1 } },
        .{ .id = "semantic", .text = "astronomy concept", .vector = &.{ 1, 0 } },
    };
    var workspace: [documents.len]Result = undefined;
    const results = try search("quasar", &.{ 1, 0 }, &documents, &workspace, .{});
    try std.testing.expectEqualStrings("both", results[0].document_id);
    try std.testing.expect(results[0].lexical_rank != null);
    try std.testing.expect(results[0].semantic_rank != null);
}

test "search validates workspace and vector dimensions" {
    const documents = [_]Document{.{ .id = "one", .text = "search", .vector = &.{ 1, 0 } }};
    var empty_workspace: [0]Result = .{};
    try std.testing.expectError(error.WorkspaceTooSmall, search("search", &.{ 1, 0 }, &documents, &empty_workspace, .{}));

    var workspace: [documents.len]Result = undefined;
    try std.testing.expectError(error.VectorDimensionMismatch, search("search", &.{1}, &documents, &workspace, .{}));
}

test "empty evidence produces no results" {
    const documents = [_]Document{.{ .id = "one", .text = "search evidence" }};
    var workspace: [documents.len]Result = undefined;
    const results = try search("unmatched", &.{}, &documents, &workspace, .{});
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "candidate depth is applied independently before fusion" {
    const documents = [_]Document{
        .{ .id = "semantic-first", .text = "unrelated", .vector = &.{ 1, 0 } },
        .{ .id = "lexical-first", .text = "rare", .vector = &.{ 0.8, 0.2 } },
    };
    var workspace: [documents.len]Result = undefined;
    const results = try search("rare", &.{ 1, 0 }, &documents, &workspace, .{ .candidate_k = 1 });
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("semantic-first", results[0].document_id);
    try std.testing.expectEqual(@as(?usize, 1), results[0].semantic_rank);
    try std.testing.expectEqualStrings("lexical-first", results[1].document_id);
    try std.testing.expectEqual(@as(?usize, 1), results[1].lexical_rank);
    try std.testing.expectEqual(@as(?usize, null), results[1].semantic_rank);
}

test "path scope and retrieval mode apply before component ranks" {
    const documents = [_]Document{
        .{ .id = "public-lexical", .text = "exact search phrase", .vector = &.{ 0, 1 }, .path = "public/a.md", .start_line = 1, .end_line = 1 },
        .{ .id = "public-vector", .text = "different wording", .vector = &.{ 1, 0 }, .path = "public/b.md", .start_line = 1, .end_line = 1 },
        .{ .id = "private", .text = "exact search phrase private", .vector = &.{ 1, 0 }, .path = "private/secret.md", .start_line = 1, .end_line = 1 },
    };
    var lexical_workspace: [documents.len]Result = undefined;
    const lexical = try search("exact search", &.{ 1, 0 }, &documents, &lexical_workspace, .{
        .path_prefix = "public/",
        .retrieval_mode = .lexical,
    });
    try std.testing.expectEqualStrings("public-lexical", lexical[0].document_id);
    try std.testing.expectEqual(@as(?usize, null), lexical[0].semantic_rank);

    var vector_workspace: [documents.len]Result = undefined;
    const vector = try search("exact search", &.{ 1, 0 }, &documents, &vector_workspace, .{
        .path_prefix = "public/",
        .retrieval_mode = .vector,
    });
    try std.testing.expectEqualStrings("public-vector", vector[0].document_id);
    try std.testing.expectEqual(@as(?usize, null), vector[0].lexical_rank);
    for (vector) |result| try std.testing.expect(std.mem.startsWith(u8, result.path, "public/"));
}

test "required labels filter both channels before component ranks" {
    const documents = [_]Document{
        .{ .id = "public", .text = "launch plan", .vector = &.{ 0, 1 } },
        .{ .id = "tenant", .text = "confidential launch plan", .vector = &.{ 1, 0 }, .required_labels = "tenant:acme" },
        .{ .id = "engineering", .text = "secret engine", .vector = &.{ 1, 0 }, .required_labels = "group:engineering\ntenant:acme" },
    };
    var anonymous_workspace: [documents.len]Result = undefined;
    const anonymous = try search("launch", &.{ 0, 1 }, &documents, &anonymous_workspace, .{
        .top_k = 3,
        .candidate_k = 3,
    });
    try std.testing.expectEqual(@as(usize, 1), anonymous.len);
    try std.testing.expectEqualStrings("public", anonymous[0].document_id);

    var tenant_workspace: [documents.len]Result = undefined;
    const tenant = try search("confidential", &.{ 1, 0 }, &documents, &tenant_workspace, .{
        .top_k = 3,
        .candidate_k = 3,
        .principal_labels = &.{"tenant:acme"},
    });
    try std.testing.expectEqualStrings("tenant", tenant[0].document_id);
    for (tenant) |result| try std.testing.expect(!std.mem.eql(u8, result.document_id, "engineering"));

    try std.testing.expect(isAuthorized("group:engineering\ntenant:acme", &.{ "tenant:acme", "group:engineering" }));
    try std.testing.expect(!isAuthorized("group:engineering\ntenant:acme", &.{"tenant:acme"}));
}

test "sparse ranking equals the dense reference on random tie-heavy inputs" {
    var prng = std.Random.DefaultPrng.init(0x53325433);
    const random = prng.random();
    const allocator = std.testing.allocator;
    const count = 60;
    var documents: [count]Document = undefined;
    var vectors: [count][3]f32 = undefined;
    const labels = [_][]const u8{ "", "", "", "tenant:a" };
    const paths = [_][]const u8{ "a/x.md", "b/y.md", "a/z.md" };
    for (&documents, &vectors, 0..) |*document, *vector, index| {
        for (vector) |*component| component.* = @floatFromInt(random.intRangeAtMost(i8, -1, 2));
        document.* = .{
            .id = "d",
            .text = "t",
            .vector = if (index % 13 == 0) &.{} else vector,
            .path = paths[random.uintLessThan(usize, paths.len)],
            .required_labels = labels[random.uintLessThan(usize, labels.len)],
        };
    }
    const modes = [_]RetrievalMode{ .lexical, .vector, .hybrid };
    const query_vectors = [_][]const f32{ &.{ 1, 0, 1 }, &.{ 0, 0, 0 }, &.{} };
    var round: usize = 0;
    while (round < 400) : (round += 1) {
        var scores: [count]f32 = undefined;
        for (&scores) |*score| score.* = if (random.uintLessThan(u8, 3) == 0) @floatFromInt(random.intRangeAtMost(u8, 1, 4)) else 0;
        const query_vector = query_vectors[random.uintLessThan(usize, query_vectors.len)];
        const options = SearchOptions{
            .top_k = random.intRangeAtMost(usize, 1, 12),
            .candidate_k = random.intRangeAtMost(usize, 0, 70),
            .retrieval_mode = modes[random.uintLessThan(usize, modes.len)],
            .path_prefix = if (random.boolean()) "a/" else null,
            .principal_labels = if (random.boolean()) &.{"tenant:a"} else &.{},
        };
        var dense_workspace: [count]Result = undefined;
        var sparse_workspace: [count]Result = undefined;
        const dense_result = searchWithLexicalScores(query_vector, &documents, &scores, &dense_workspace, options);
        var source = DenseLexical{ .scores = &scores };
        const sparse_result = searchSparse(DenseLexical, allocator, &source, query_vector, &documents, &sparse_workspace, options);
        if (dense_result) |dense| {
            const sparse = try sparse_result;
            try std.testing.expectEqual(dense.len, sparse.len);
            for (dense, sparse) |expected, actual| try std.testing.expectEqualDeep(expected, actual);
        } else |_| {
            try std.testing.expectError(error.VectorDimensionMismatch, sparse_result);
        }
    }
}
