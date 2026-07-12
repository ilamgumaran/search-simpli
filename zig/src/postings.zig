const analysis = @import("analysis.zig");
const hybrid = @import("hybrid.zig");
const scoring = @import("scoring.zig");
const segment = @import("segment.zig");
const std = @import("std");

pub const Posting = struct {
    document_index: u32,
    term_frequency: u32,
};

pub const TermEntry = struct {
    term: []const u8,
    document_frequency: u32,
    postings_start: usize,
    postings_length: usize,
};

pub const Index = struct {
    terms: []const TermEntry,
    postings: []const Posting,
    document_lengths: []const u32,
    average_document_length: f32,
};

pub const BuildError = error{
    DocumentCountOverflow,
    DocumentLengthOverflow,
    DocumentLengthCapacityTooSmall,
    TermCapacityTooSmall,
    PostingCapacityTooSmall,
    FillCapacityTooSmall,
    PostingCountOverflow,
};

pub const QueryError = error{ScoreCapacityTooSmall};

/// Build an allocation-free inverted index whose term slices borrow document
/// text. Terms are kept in first-seen order for now; a persistent dictionary
/// can sort or encode them without changing postings score behavior.
pub fn build(
    documents: []const hybrid.Document,
    term_output: []TermEntry,
    posting_output: []Posting,
    document_length_output: []u32,
    posting_fill_output: []usize,
) BuildError!Index {
    if (documents.len > std.math.maxInt(u32)) return error.DocumentCountOverflow;
    if (document_length_output.len < documents.len) return error.DocumentLengthCapacityTooSmall;

    var term_count: usize = 0;
    var total_document_length: usize = 0;
    for (documents, 0..) |document, document_index| {
        const document_length = analysis.tokenCount(document.text);
        if (document_length > std.math.maxInt(u32)) return error.DocumentLengthOverflow;
        document_length_output[document_index] = @intCast(document_length);
        total_document_length = std.math.add(usize, total_document_length, document_length) catch
            return error.DocumentLengthOverflow;

        var tokens = analysis.TokenIterator.init(document.text);
        while (tokens.next()) |token| {
            if (!analysis.isFirstOccurrence(document.text, token)) continue;
            const term_index = findTerm(term_output[0..term_count], token.bytes) orelse add: {
                if (term_count >= term_output.len) return error.TermCapacityTooSmall;
                term_output[term_count] = .{
                    .term = token.bytes,
                    .document_frequency = 0,
                    .postings_start = 0,
                    .postings_length = 0,
                };
                term_count += 1;
                break :add term_count - 1;
            };
            term_output[term_index].document_frequency += 1;
        }
    }

    if (posting_fill_output.len < term_count) return error.FillCapacityTooSmall;
    var posting_count: usize = 0;
    for (term_output[0..term_count], 0..) |*entry, term_index| {
        entry.postings_start = posting_count;
        entry.postings_length = entry.document_frequency;
        posting_count = std.math.add(usize, posting_count, entry.postings_length) catch
            return error.PostingCountOverflow;
        posting_fill_output[term_index] = 0;
    }
    if (posting_output.len < posting_count) return error.PostingCapacityTooSmall;

    for (documents, 0..) |document, document_index| {
        var tokens = analysis.TokenIterator.init(document.text);
        while (tokens.next()) |token| {
            if (!analysis.isFirstOccurrence(document.text, token)) continue;
            const term_index = findTerm(term_output[0..term_count], token.bytes).?;
            const entry = term_output[term_index];
            const posting_index = entry.postings_start + posting_fill_output[term_index];
            const frequency = analysis.termFrequency(document.text, token.bytes);
            posting_output[posting_index] = .{
                .document_index = @intCast(document_index),
                .term_frequency = @intCast(frequency),
            };
            posting_fill_output[term_index] += 1;
        }
    }

    const average_document_length = if (documents.len == 0)
        0
    else
        @as(f32, @floatFromInt(total_document_length)) / @as(f32, @floatFromInt(documents.len));
    return .{
        .terms = term_output[0..term_count],
        .postings = posting_output[0..posting_count],
        .document_lengths = document_length_output[0..documents.len],
        .average_document_length = average_document_length,
    };
}

/// Score only documents present in postings for unique query terms.
pub fn scoreQuery(
    index: Index,
    query: []const u8,
    score_output: []f32,
    parameters: scoring.Bm25Parameters,
) QueryError![]f32 {
    if (score_output.len < index.document_lengths.len) return error.ScoreCapacityTooSmall;
    const scores = score_output[0..index.document_lengths.len];
    @memset(scores, 0);

    var query_tokens = analysis.TokenIterator.init(query);
    while (query_tokens.next()) |query_token| {
        if (!analysis.isFirstOccurrence(query, query_token)) continue;
        const term_index = findTerm(index.terms, query_token.bytes) orelse continue;
        const entry = index.terms[term_index];
        for (index.postings[entry.postings_start .. entry.postings_start + entry.postings_length]) |posting| {
            const document_index: usize = posting.document_index;
            scores[document_index] += scoring.bm25Contribution(
                @floatFromInt(posting.term_frequency),
                @floatFromInt(index.document_lengths[document_index]),
                index.average_document_length,
                entry.document_frequency,
                @intCast(index.document_lengths.len),
                parameters,
            );
        }
    }
    return scores;
}

pub fn findTerm(terms: []const TermEntry, term: []const u8) ?usize {
    for (terms, 0..) |entry, index| {
        if (analysis.eqlCaseFoldAscii(entry.term, term)) return index;
    }
    return null;
}

test "postings store document and term frequencies" {
    const documents = [_]hybrid.Document{
        .{ .id = "one", .text = "zig search zig" },
        .{ .id = "two", .text = "search platform" },
    };
    var terms: [8]TermEntry = undefined;
    var posting_storage: [8]Posting = undefined;
    var lengths: [documents.len]u32 = undefined;
    var fills: [8]usize = undefined;
    const index = try build(&documents, &terms, &posting_storage, &lengths, &fills);

    try std.testing.expectEqual(@as(usize, 3), index.terms.len);
    const zig_entry = index.terms[findTerm(index.terms, "ZIG").?];
    try std.testing.expectEqual(@as(u32, 1), zig_entry.document_frequency);
    try std.testing.expectEqual(@as(usize, 1), zig_entry.postings_length);
    const zig_posting = index.postings[zig_entry.postings_start];
    try std.testing.expectEqual(@as(u32, 0), zig_posting.document_index);
    try std.testing.expectEqual(@as(u32, 2), zig_posting.term_frequency);
}

test "postings BM25 matches the scan oracle" {
    const documents = [_]hybrid.Document{
        .{ .id = "engine", .text = "postings postings store identifiers for lexical retrieval" },
        .{ .id = "orchard", .text = "apples and pears grow here" },
        .{ .id = "other", .text = "retrieval finds useful evidence" },
    };
    var terms: [24]TermEntry = undefined;
    var posting_storage: [32]Posting = undefined;
    var lengths: [documents.len]u32 = undefined;
    var fills: [24]usize = undefined;
    const index = try build(&documents, &terms, &posting_storage, &lengths, &fills);
    var posting_scores_storage: [documents.len]f32 = undefined;
    const posting_scores = try scoreQuery(index, "postings retrieval", &posting_scores_storage, .{});

    var scan_workspace: [documents.len]hybrid.Result = undefined;
    const scan_results = try hybrid.search("postings retrieval", &.{}, &documents, &scan_workspace, .{});
    var scan_scores: [documents.len]f32 = @splat(0);
    for (scan_results) |result| scan_scores[result.document_index] = result.lexical_score;
    for (posting_scores, scan_scores) |posting_score, scan_score| {
        try std.testing.expectApproxEqAbs(scan_score, posting_score, 0.000001);
    }
}

test "postings scores preserve full hybrid ordering" {
    const documents = [_]hybrid.Document{
        .{ .id = "both", .text = "hybrid retrieval combines ranks", .vector = &.{ 0.8, 0.2 } },
        .{ .id = "lexical", .text = "hybrid hybrid exact", .vector = &.{ 0, 1 } },
        .{ .id = "semantic", .text = "meaning based result", .vector = &.{ 1, 0 } },
    };
    var terms: [24]TermEntry = undefined;
    var posting_storage: [32]Posting = undefined;
    var lengths: [documents.len]u32 = undefined;
    var fills: [24]usize = undefined;
    const index = try build(&documents, &terms, &posting_storage, &lengths, &fills);
    var scores_storage: [documents.len]f32 = undefined;
    const lexical_scores = try scoreQuery(index, "hybrid", &scores_storage, .{});

    var scan_workspace: [documents.len]hybrid.Result = undefined;
    const scan_results = try hybrid.search("hybrid", &.{ 1, 0 }, &documents, &scan_workspace, .{});
    var postings_workspace: [documents.len]hybrid.Result = undefined;
    const postings_results = try hybrid.searchWithLexicalScores(&.{ 1, 0 }, &documents, lexical_scores, &postings_workspace, .{});

    try std.testing.expectEqual(scan_results.len, postings_results.len);
    for (scan_results, postings_results) |scan_result, postings_result| {
        try std.testing.expectEqualStrings(scan_result.document_id, postings_result.document_id);
        try std.testing.expectEqual(scan_result.lexical_rank, postings_result.lexical_rank);
        try std.testing.expectEqual(scan_result.semantic_rank, postings_result.semantic_rank);
        try std.testing.expectApproxEqAbs(scan_result.fused_score, postings_result.fused_score, 0.000001);
    }
}

test "postings build reports caller capacity errors" {
    const documents = [_]hybrid.Document{.{ .id = "one", .text = "one two" }};
    var no_terms: [0]TermEntry = .{};
    var postings_storage: [2]Posting = undefined;
    var lengths: [1]u32 = undefined;
    var fills: [2]usize = undefined;
    try std.testing.expectError(error.TermCapacityTooSmall, build(&documents, &no_terms, &postings_storage, &lengths, &fills));

    var terms: [2]TermEntry = undefined;
    var no_postings: [0]Posting = .{};
    try std.testing.expectError(error.PostingCapacityTooSmall, build(&documents, &terms, &no_postings, &lengths, &fills));

    var no_lengths: [0]u32 = .{};
    try std.testing.expectError(error.DocumentLengthCapacityTooSmall, build(&documents, &terms, &postings_storage, &no_lengths, &fills));
}

test "decoded segment can rebuild postings and preserve hybrid results" {
    const source_documents = [_]hybrid.Document{
        .{ .id = "both", .text = "hybrid retrieval combines ranks", .vector = &.{ 0.8, 0.2 } },
        .{ .id = "lexical", .text = "hybrid hybrid exact", .vector = &.{ 0, 1 } },
        .{ .id = "semantic", .text = "meaning based result", .vector = &.{ 1, 0 } },
    };
    var scan_workspace: [source_documents.len]hybrid.Result = undefined;
    const expected = try hybrid.search("hybrid", &.{ 1, 0 }, &source_documents, &scan_workspace, .{});

    var encoded_storage: [512]u8 = undefined;
    const encoded = try segment.encode(&source_documents, &encoded_storage);
    var decoded_storage: [source_documents.len]hybrid.Document = undefined;
    var vector_storage: [source_documents.len * 2]f32 = undefined;
    const documents = try segment.decode(encoded, &decoded_storage, &vector_storage);

    var terms: [24]TermEntry = undefined;
    var posting_storage: [32]Posting = undefined;
    var lengths: [source_documents.len]u32 = undefined;
    var fills: [24]usize = undefined;
    const index = try build(documents, &terms, &posting_storage, &lengths, &fills);
    var score_storage: [source_documents.len]f32 = undefined;
    const scores = try scoreQuery(index, "hybrid", &score_storage, .{});
    var result_workspace: [source_documents.len]hybrid.Result = undefined;
    const actual = try hybrid.searchWithLexicalScores(&.{ 1, 0 }, documents, scores, &result_workspace, .{});

    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_result, actual_result| {
        try std.testing.expectEqualStrings(expected_result.document_id, actual_result.document_id);
        try std.testing.expectEqual(expected_result.lexical_rank, actual_result.lexical_rank);
        try std.testing.expectEqual(expected_result.semantic_rank, actual_result.semantic_rank);
        try std.testing.expectApproxEqAbs(expected_result.fused_score, actual_result.fused_score, 0.000001);
    }
}
