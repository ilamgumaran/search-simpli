//! Builds a `postings.Index` from pre-tokenized documents, for any
//! analyzer. `postings.build` (the original, still used by every existing
//! caller and test) hardcodes `analysis.zig`'s ASCII `TokenIterator` and
//! ASCII case-fold comparator; rather than making that hot, already-tested
//! path generic (higher risk of regressing S1-T0's parallel work and every
//! existing postings/engine/service test), this is an additive module that
//! produces the *same* `postings.Index`/`TermEntry`/`Posting` wire types
//! from a caller-supplied, already-tokenized-and-folded token list per
//! document. `lexical_segment.encode`/`decode` and `postings.scoreQuery`'s
//! wire format do not care how the dictionary was built, so both
//! `analyzer-v1` (ASCII, via `postings.build`) and `analyzer-v2` (Unicode,
//! via this module) round-trip through the identical persisted format.
//!
//! Term matching here is exact byte equality: both dictionary construction
//! and query tokenization go through the same analyzer-v2 tokenizer, which
//! already NFC-normalizes and casefolds every token, so there is nothing
//! left for a case-insensitive comparator to do (unlike `analysis.zig`,
//! where tokens are stored unfolded and folded only at comparison time).
const std = @import("std");
const hybrid = @import("hybrid.zig");
const postings = @import("postings.zig");
const scoring = @import("scoring.zig");

pub const BuildError = error{ OutOfMemory, DocumentCountOverflow, TermCountOverflow };

/// Build a lexical index from `token_lists[i]` = the analyzer-v2 tokens of
/// `documents[i].text`, in document order. All memory is owned by
/// `allocator` (intended use: an arena, discarded wholesale by the caller).
pub fn build(
    allocator: std.mem.Allocator,
    documents: []const hybrid.Document,
    token_lists: []const [][]const u8,
) BuildError!postings.Index {
    std.debug.assert(documents.len == token_lists.len);
    if (documents.len > std.math.maxInt(u32)) return error.DocumentCountOverflow;

    var terms = std.ArrayList(postings.TermEntry).empty;
    var postings_by_term = std.ArrayList(std.ArrayList(postings.Posting)).empty;
    var document_lengths = try allocator.alloc(u32, documents.len);
    var total_length: usize = 0;

    // Global term -> index into `terms`/`postings_by_term`. A hash map here
    // (S1-T3, `docs/tasks/S1-T3.md` criterion 4, replacing the linear scans
    // this used to do) is what makes `build` linear in total tokens instead
    // of superlinear in vocabulary size: the old code re-walked the entire
    // (growing) term list, and the entire per-document "seen so far" list,
    // for every token of every document -- O(unique terms x total tokens).
    // The round-A verdict measured this at 9.69s on a realistic
    // 20,000-term/1,000-file corpus; see docs/tasks/S1-T3.md's Report for
    // the hash-map timing on the same corpus.
    var term_index_by_name = std.StringHashMap(usize).init(allocator);
    defer term_index_by_name.deinit();

    for (token_lists, 0..) |tokens, document_index| {
        document_lengths[document_index] = @intCast(tokens.len);
        total_length += tokens.len;

        // Per-document term frequency via a hash map instead of a linear
        // scan of tokens seen so far in this document.
        var doc_counts = std.StringHashMap(u32).init(allocator);
        defer doc_counts.deinit();
        for (tokens) |token| {
            const gop = try doc_counts.getOrPut(token);
            if (gop.found_existing) {
                gop.value_ptr.* += 1;
            } else {
                gop.value_ptr.* = 1;
            }
        }

        var doc_iterator = doc_counts.iterator();
        while (doc_iterator.next()) |doc_entry| {
            const token = doc_entry.key_ptr.*;
            const count = doc_entry.value_ptr.*;
            const gop = try term_index_by_name.getOrPut(token);
            if (!gop.found_existing) {
                try terms.append(allocator, .{
                    .term = token,
                    .document_frequency = 0,
                    .postings_start = 0,
                    .postings_length = 0,
                });
                try postings_by_term.append(allocator, std.ArrayList(postings.Posting).empty);
                gop.value_ptr.* = terms.items.len - 1;
            }
            const index = gop.value_ptr.*;
            terms.items[index].document_frequency += 1;
            try postings_by_term.items[index].append(allocator, .{
                .document_index = @intCast(document_index),
                .term_frequency = count,
            });
        }
    }

    if (terms.items.len > std.math.maxInt(u32)) return error.TermCountOverflow;

    var all_postings = std.ArrayList(postings.Posting).empty;
    for (terms.items, 0..) |*entry, index| {
        entry.postings_start = all_postings.items.len;
        entry.postings_length = postings_by_term.items[index].items.len;
        try all_postings.appendSlice(allocator, postings_by_term.items[index].items);
    }

    const average_document_length = if (documents.len == 0)
        0
    else
        @as(f32, @floatFromInt(total_length)) / @as(f32, @floatFromInt(documents.len));

    return .{
        .terms = try terms.toOwnedSlice(allocator),
        .postings = try all_postings.toOwnedSlice(allocator),
        .document_lengths = document_lengths,
        .average_document_length = average_document_length,
    };
}

/// Score a query against an analyzer-v2-built index: `query_tokens` must
/// come from the same tokenizer used to build `index`.
pub fn scoreQuery(
    index: postings.Index,
    query_tokens: []const []const u8,
    score_output: []f32,
    parameters: scoring.Bm25Parameters,
) postings.QueryError![]f32 {
    if (score_output.len < index.document_lengths.len) return error.ScoreCapacityTooSmall;
    const scores = score_output[0..index.document_lengths.len];
    @memset(scores, 0);

    for (query_tokens, 0..) |query_token, position| {
        var already_scored = false;
        for (query_tokens[0..position]) |earlier| {
            if (std.mem.eql(u8, earlier, query_token)) {
                already_scored = true;
                break;
            }
        }
        if (already_scored) continue;

        const term_index = findExact(index.terms, query_token) orelse continue;
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

fn findExact(terms: []const postings.TermEntry, term: []const u8) ?usize {
    for (terms, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.term, term)) return index;
    }
    return null;
}

test "build and scoreQuery reproduce BM25 ranking from pre-tokenized documents" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const documents = [_]hybrid.Document{
        .{ .id = "a", .text = "search evidence search", .path = "a.md", .start_line = 1, .end_line = 1 },
        .{ .id = "b", .text = "unrelated passage", .path = "b.md", .start_line = 1, .end_line = 1 },
    };
    const token_lists = [_][][]const u8{
        try dupTokens(arena, &.{ "search", "evidence", "search" }),
        try dupTokens(arena, &.{ "unrelated", "passage" }),
    };
    const index = try build(arena, &documents, &token_lists);

    var scores: [2]f32 = undefined;
    const result = try scoreQuery(index, &.{"search"}, &scores, .{});
    try std.testing.expect(result[0] > 0);
    try std.testing.expectEqual(@as(f32, 0), result[1]);
}

fn dupTokens(allocator: std.mem.Allocator, tokens: []const []const u8) ![][]const u8 {
    return allocator.dupe([]const u8, tokens);
}
