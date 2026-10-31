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
const analysis = @import("analysis.zig");
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

/// The `ascii-alnum-v1` twin of `build` (S2-T2): the same dictionary,
/// postings, document lengths and average length as `postings.build`, in
/// the same term order (first seen, document order), but in time linear in
/// total tokens. `postings.build` scans the growing term list and re-scans
/// the document for every token; this keys one hash map on the
/// ASCII-lowercased token instead. A term's bytes stay the first-seen
/// spelling (a slice of the document text, as `postings.build` stores
/// them), so the encoded lexical section is byte-identical to the old path.
/// Document text must outlive the returned index; the rest is owned by
/// `allocator` (an arena).
pub fn buildAscii(
    allocator: std.mem.Allocator,
    documents: []const hybrid.Document,
) (BuildError || postings.BuildError)!postings.Index {
    if (documents.len > std.math.maxInt(u32)) return error.DocumentCountOverflow;

    const Entry = struct { term: u32, document: u32, frequency: u32 };
    var terms = std.ArrayList(postings.TermEntry).empty;
    // Per term: the last document that counted it, and its slot in `entries`.
    var last_document = std.ArrayList(u32).empty;
    var last_entry = std.ArrayList(usize).empty;
    var entries = std.ArrayList(Entry).empty;
    var folded = std.ArrayList(u8).empty;
    const document_lengths = try allocator.alloc(u32, documents.len);
    var total_length: usize = 0;

    var term_index_by_name = std.StringHashMap(u32).init(allocator);
    defer term_index_by_name.deinit();

    for (documents, 0..) |document, document_index| {
        var length: usize = 0;
        var tokens = analysis.TokenIterator.init(document.text);
        while (tokens.next()) |token| {
            length += 1;
            folded.clearRetainingCapacity();
            try folded.ensureTotalCapacity(allocator, token.bytes.len);
            for (token.bytes) |byte| folded.appendAssumeCapacity(std.ascii.toLower(byte));
            const term_index: u32 = if (term_index_by_name.get(folded.items)) |found| found else add: {
                if (terms.items.len >= std.math.maxInt(u32)) return error.TermCountOverflow;
                const index: u32 = @intCast(terms.items.len);
                try term_index_by_name.put(try allocator.dupe(u8, folded.items), index);
                try terms.append(allocator, .{
                    .term = token.bytes,
                    .document_frequency = 0,
                    .postings_start = 0,
                    .postings_length = 0,
                });
                try last_document.append(allocator, std.math.maxInt(u32));
                try last_entry.append(allocator, 0);
                break :add index;
            };
            if (last_document.items[term_index] == document_index) {
                entries.items[last_entry.items[term_index]].frequency += 1;
            } else {
                last_document.items[term_index] = @intCast(document_index);
                last_entry.items[term_index] = entries.items.len;
                terms.items[term_index].document_frequency += 1;
                try entries.append(allocator, .{
                    .term = term_index,
                    .document = @intCast(document_index),
                    .frequency = 1,
                });
            }
        }
        if (length > std.math.maxInt(u32)) return error.DocumentLengthOverflow;
        document_lengths[document_index] = @intCast(length);
        total_length = std.math.add(usize, total_length, length) catch return error.DocumentLengthOverflow;
    }

    // Counting sort of the entries by term; entries are already in document
    // order, so each term's postings stay in document order.
    const fills = try allocator.alloc(usize, terms.items.len);
    @memset(fills, 0);
    var posting_count: usize = 0;
    for (terms.items) |*entry| {
        entry.postings_start = posting_count;
        entry.postings_length = entry.document_frequency;
        posting_count = std.math.add(usize, posting_count, entry.postings_length) catch
            return error.PostingCountOverflow;
    }
    const all_postings = try allocator.alloc(postings.Posting, posting_count);
    for (entries.items) |entry| {
        const slot = terms.items[entry.term].postings_start + fills[entry.term];
        all_postings[slot] = .{ .document_index = entry.document, .term_frequency = entry.frequency };
        fills[entry.term] += 1;
    }

    const average_document_length = if (documents.len == 0)
        0
    else
        @as(f32, @floatFromInt(total_length)) / @as(f32, @floatFromInt(documents.len));
    return .{
        .terms = try terms.toOwnedSlice(allocator),
        .postings = all_postings,
        .document_lengths = document_lengths,
        .average_document_length = average_document_length,
    };
}

/// The positional build (S3-T2, `HYBLEX02`): the same postings, document
/// frequencies, document lengths and average length as `build` over the
/// same token lists (so every BM25 score is unchanged), with the dictionary
/// sorted by term bytes, term ranges laid out in that order, and sections 4
/// (ordinals) and 5 (offsets) encoded from each token's ordinal and
/// codepoint span. `token_lists[i]` are the positioned tokens of
/// `documents[i].text` in text order. All memory from `allocator` (an arena).
pub fn buildPositional(
    allocator: std.mem.Allocator,
    documents: []const hybrid.Document,
    token_lists: []const []const analysis.PositionedToken,
) BuildError!postings.Index {
    std.debug.assert(documents.len == token_lists.len);
    if (documents.len > std.math.maxInt(u32)) return error.DocumentCountOverflow;
    // Working memory from a general-purpose allocator, freed before
    // returning; the index itself is allocated from `allocator` at its
    // exact size (an indexing arena keeps no growth garbage).
    const scratch = std.heap.smp_allocator;

    const Occurrence = struct { term: u32, document: u32, ordinal: u32 };
    var names = std.ArrayList([]const u8).empty;
    defer names.deinit(scratch);
    var occurrences = std.ArrayList(Occurrence).empty;
    defer occurrences.deinit(scratch);
    var offsets = std.ArrayList(u8).empty;
    defer offsets.deinit(scratch);
    const document_lengths = try allocator.alloc(u32, documents.len);
    var total_length: usize = 0;
    var id_by_name = std.StringHashMap(u32).init(scratch);
    defer id_by_name.deinit();

    var token_total: usize = 0;
    for (token_lists) |tokens| token_total += tokens.len;
    try occurrences.ensureTotalCapacity(scratch, token_total);
    try offsets.ensureTotalCapacity(scratch, documents.len * 4 + token_total * 2);

    for (token_lists, 0..) |tokens, document_index| {
        if (tokens.len > std.math.maxInt(u32)) return error.DocumentCountOverflow;
        document_lengths[document_index] = @intCast(tokens.len);
        total_length += tokens.len;
        var count_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &count_bytes, @intCast(tokens.len), .little);
        try offsets.appendSlice(scratch, &count_bytes);
        var previous_start: u32 = 0;
        for (tokens, 0..) |token, ordinal| {
            const gop = try id_by_name.getOrPut(token.bytes);
            if (!gop.found_existing) {
                if (names.items.len >= std.math.maxInt(u32)) return error.TermCountOverflow;
                gop.value_ptr.* = @intCast(names.items.len);
                try names.append(scratch, token.bytes);
            }
            occurrences.appendAssumeCapacity(.{ .term = gop.value_ptr.*, .document = @intCast(document_index), .ordinal = @intCast(ordinal) });
            // Offsets come from the tokenizer in text order; a mapped token
            // (NFC changed its text) may share its start with the previous one.
            const start = @max(token.start, previous_start);
            try postings.appendVarint(&offsets, scratch, start - previous_start);
            try postings.appendVarint(&offsets, scratch, @max(token.length, 1));
            previous_start = start;
        }
    }

    // Rank every term by bytes; lay occurrences out term-major in that order
    // (a stable counting sort keeps document, then ordinal, order).
    const order = try scratch.alloc(u32, names.items.len);
    defer scratch.free(order);
    for (order, 0..) |*slot, i| slot.* = @intCast(i);
    std.sort.pdq(u32, order, names.items, struct {
        fn lessThan(all: [][]const u8, a: u32, b: u32) bool {
            return std.mem.order(u8, all[a], all[b]) == .lt;
        }
    }.lessThan);
    const rank = try scratch.alloc(u32, names.items.len);
    defer scratch.free(rank);
    for (order, 0..) |term, r| rank[term] = @intCast(r);
    const bucket_start = try scratch.alloc(usize, names.items.len + 1);
    defer scratch.free(bucket_start);
    @memset(bucket_start, 0);
    for (occurrences.items) |occurrence| bucket_start[rank[occurrence.term] + 1] += 1;
    for (1..bucket_start.len) |i| bucket_start[i] += bucket_start[i - 1];
    const fill = try scratch.dupe(usize, bucket_start[0..names.items.len]);
    defer scratch.free(fill);
    const sorted = try scratch.alloc(Occurrence, occurrences.items.len);
    defer scratch.free(sorted);
    for (occurrences.items) |occurrence| {
        const r = rank[occurrence.term];
        sorted[fill[r]] = occurrence;
        fill[r] += 1;
    }

    // Postings count = distinct (term, document) pairs.
    var posting_total: usize = 0;
    for (sorted, 0..) |occurrence, i| {
        if (i == 0 or sorted[i - 1].term != occurrence.term or sorted[i - 1].document != occurrence.document) posting_total += 1;
    }
    var terms = try allocator.alloc(postings.TermEntry, names.items.len);
    const all_postings = try allocator.alloc(postings.Posting, posting_total);
    var posting_count: usize = 0;
    var positions = std.ArrayList(u8).empty;
    defer positions.deinit(scratch);
    try positions.ensureTotalCapacity(scratch, sorted.len + sorted.len / 4);
    for (order, 0..) |term, r| {
        const group = sorted[bucket_start[r]..bucket_start[r + 1]];
        const postings_start = posting_count;
        var i: usize = 0;
        while (i < group.len) {
            var j = i + 1;
            while (j < group.len and group[j].document == group[i].document) : (j += 1) {}
            all_postings[posting_count] = .{ .document_index = group[i].document, .term_frequency = @intCast(j - i) };
            posting_count += 1;
            var previous: u32 = 0;
            for (group[i..j], 0..) |occurrence, k| {
                try postings.appendVarint(&positions, scratch, if (k == 0) occurrence.ordinal else occurrence.ordinal - previous);
                previous = occurrence.ordinal;
            }
            i = j;
        }
        const postings_length = posting_count - postings_start;
        terms[r] = .{
            .term = names.items[term],
            .document_frequency = @intCast(postings_length),
            .postings_start = postings_start,
            .postings_length = postings_length,
        };
    }
    std.debug.assert(posting_count == posting_total);

    const average_document_length = if (documents.len == 0)
        0
    else
        @as(f32, @floatFromInt(total_length)) / @as(f32, @floatFromInt(documents.len));
    return .{
        .terms = terms,
        .postings = all_postings,
        .document_lengths = document_lengths,
        .average_document_length = average_document_length,
        .positions = .{ .positions = try allocator.dupe(u8, positions.items), .offsets = try allocator.dupe(u8, offsets.items) },
        .sorted_terms = true,
    };
}

/// Every document's positioned tokens, in text order, read back from a
/// positional index (S3-T2): the term at each ordinal (section 4) and each
/// token's span (section 5). `null` when the index has no positions. Used
/// by `--update` to carry unchanged documents into the next generation
/// without re-running the analyzer. Token bytes borrow the dictionary.
pub fn reconstructPositioned(allocator: std.mem.Allocator, index: postings.Index) std.mem.Allocator.Error!?[][]analysis.PositionedToken {
    const sections = index.positions orelse return null;
    const lists = try allocator.alloc([]analysis.PositionedToken, index.document_lengths.len);
    for (lists, index.document_lengths) |*list, length| list.* = try allocator.alloc(analysis.PositionedToken, length);
    var at: usize = 0;
    for (index.terms) |entry| {
        for (index.postings[entry.postings_start .. entry.postings_start + entry.postings_length]) |posting| {
            var ordinal: u32 = 0;
            for (0..posting.term_frequency) |k| {
                const value = postings.readVarint(sections.positions, &at).?;
                ordinal = if (k == 0) value else ordinal + value;
                lists[posting.document_index][ordinal].bytes = entry.term;
            }
        }
    }
    at = 0;
    for (lists) |list| {
        at += 4;
        var start: u32 = 0;
        for (list) |*token| {
            start += postings.readVarint(sections.offsets, &at).?;
            token.start = start;
            token.length = postings.readVarint(sections.offsets, &at).?;
        }
    }
    return lists;
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

        const term_index = postings.lookupExact(index, query_token) orelse continue;
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

/// The dictionary entries of a tokenised query's unique terms, in first-
/// occurrence order -- exactly the terms (and the order) `scoreQuery`
/// accumulates over. Caller frees the slice.
pub fn resolveTokens(
    allocator: std.mem.Allocator,
    index: postings.Index,
    query_tokens: []const []const u8,
) std.mem.Allocator.Error![]postings.TermEntry {
    return resolveTokensTraced(allocator, index, query_tokens, null, true);
}

/// `resolveTokens` that also records unique-term and unmatched-term counts in
/// `trace` (S2-T4); see `postings.resolveQueryTraced`.
pub fn resolveTokensTraced(
    allocator: std.mem.Allocator,
    index: postings.Index,
    query_tokens: []const []const u8,
    trace: ?*hybrid.Trace,
    lookup: bool,
) std.mem.Allocator.Error![]postings.TermEntry {
    var resolved = std.ArrayList(postings.TermEntry).empty;
    errdefer resolved.deinit(allocator);
    for (query_tokens, 0..) |query_token, position| {
        var already_scored = false;
        for (query_tokens[0..position]) |earlier| {
            if (std.mem.eql(u8, earlier, query_token)) {
                already_scored = true;
                break;
            }
        }
        if (already_scored) continue;
        if (trace) |t| t.unique_terms += 1;
        if (!lookup) continue;
        const term_index = postings.lookupExact(index, query_token) orelse {
            if (trace) |t| try postings.noteUnmatched(t, query_token, false);
            continue;
        };
        if (trace) |t| {
            if (!postings.hasInScopePosting(index, index.terms[term_index], t)) try postings.noteUnmatched(t, query_token, false);
        }
        try resolved.append(allocator, index.terms[term_index]);
    }
    return resolved.toOwnedSlice(allocator);
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

test "buildPositional keeps build's statistics, sorts terms and round-trips positions (S3-T2)" {
    const analyzer_v2 = @import("analyzer_v2.zig");
    const lexical_segment = @import("lexical_segment.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const documents = [_]hybrid.Document{
        .{ .id = "a", .text = "Zebra apple the the apple" },
        .{ .id = "b", .text = "" },
        .{ .id = "c", .text = "apple pie, cafe\u{0301} zebra" },
    };
    var plain: [documents.len][][]const u8 = undefined;
    var positioned: [documents.len][]const analysis.PositionedToken = undefined;
    for (documents, 0..) |document, i| {
        plain[i] = try analyzer_v2.tokenize(arena, document.text);
        positioned[i] = try analyzer_v2.tokenizePositioned(arena, document.text);
    }
    const reference = try build(arena, &documents, &plain);
    const index = try buildPositional(arena, &documents, &positioned);
    try std.testing.expect(index.sorted_terms);
    try std.testing.expectEqual(reference.average_document_length, index.average_document_length);
    try std.testing.expectEqualSlices(u32, reference.document_lengths, index.document_lengths);
    try std.testing.expectEqual(reference.terms.len, index.terms.len);
    for (index.terms[1..], 1..) |entry, i| try std.testing.expect(std.mem.order(u8, index.terms[i - 1].term, entry.term) == .lt);
    for (reference.terms) |want| {
        const got = index.terms[postings.lookupExact(index, want.term).?];
        try std.testing.expectEqual(want.document_frequency, got.document_frequency);
        const want_list = reference.postings[want.postings_start .. want.postings_start + want.postings_length];
        const got_list = index.postings[got.postings_start .. got.postings_start + got.postings_length];
        try std.testing.expectEqualSlices(postings.Posting, want_list, got_list);
    }
    var scores_a: [documents.len]f32 = undefined;
    var scores_b: [documents.len]f32 = undefined;
    const query = [_][]const u8{ "apple", "zebra", "the" };
    try std.testing.expectEqualSlices(f32, try scoreQuery(reference, &query, &scores_a, .{}), try scoreQuery(index, &query, &scores_b, .{}));

    var buffer: [4096]u8 = undefined;
    const encoded = try lexical_segment.encode(index, &buffer);
    try std.testing.expectEqualStrings(lexical_segment.magic_v2, encoded[0..8]);
    var terms_out: [16]postings.TermEntry = undefined;
    var postings_out: [16]postings.Posting = undefined;
    var lengths_out: [documents.len]u32 = undefined;
    const decoded = try lexical_segment.decode(encoded, &terms_out, &postings_out, &lengths_out);
    try std.testing.expect(decoded.positions != null);
    const tokens = (try reconstructPositioned(arena, decoded)).?;
    for (positioned, tokens) |want_list, got_list| {
        try std.testing.expectEqual(want_list.len, got_list.len);
        for (want_list, got_list) |want, got| {
            try std.testing.expectEqualStrings(want.bytes, got.bytes);
            try std.testing.expectEqual(want.start, got.start);
            try std.testing.expectEqual(want.length, got.length);
        }
    }
    try std.testing.expectEqual(@as(u32, 11), tokens[2][2].start);
    try std.testing.expectEqual(@as(u32, 5), tokens[2][2].length);
}
