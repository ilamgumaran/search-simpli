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
    /// HYBLEX02 (S3-T2, `docs/lexical-segment-format-v2.md`): sections 4
    /// (token ordinals) and 5 (token offsets), in memory exactly as on disk.
    /// Null for a `HYBLEX01` section or an index built without positions.
    positions: ?PositionSections = null,
    /// True when `terms` is sorted by bytes (every `HYBLEX02` dictionary):
    /// lookups binary-search and a prefix is one contiguous range.
    sorted_terms: bool = false,
};

/// Section 4: for each posting in posting order, `term_frequency` unsigned
/// LEB128 varints, the term's token ordinals in the document, the first
/// absolute and every later one a gap >= 1. Section 5: for each document in
/// document order, a u32 token count (equal to its document length) and per
/// token two varints, the start codepoint as a delta from the previous
/// token's start (the first from 0) and the length in codepoints, into the
/// chunk's text.
pub const PositionSections = struct {
    positions: []const u8,
    offsets: []const u8,
};

/// One token's codepoint range in a chunk's text (section 5).
pub const TokenSpan = struct {
    start: u32,
    length: u32,
};

/// Where each term's ordinals and each document's offset table begin in
/// sections 4 and 5. Built once per opened generation
/// (`buildPositionTables`), so a query reads only the bytes of its own
/// terms and hits.
pub const PositionTables = struct {
    term_starts: []const usize,
    document_starts: []const usize,
};

/// Append `value` as an unsigned LEB128 varint.
pub fn appendVarint(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) std.mem.Allocator.Error!void {
    var remaining = value;
    while (remaining >= 0x80) {
        try list.append(allocator, @as(u8, @truncate(remaining)) | 0x80);
        remaining >>= 7;
    }
    try list.append(allocator, @truncate(remaining));
}

/// Read one unsigned LEB128 varint of at most five bytes whose value fits a
/// u32, or null (truncated, too long, or overflowing).
pub fn readVarint(bytes: []const u8, offset: *usize) ?u32 {
    var value: u64 = 0;
    var shift: u6 = 0;
    var at = offset.*;
    while (true) {
        if (at >= bytes.len or shift > 28) return null;
        const byte = bytes[at];
        at += 1;
        value |= @as(u64, byte & 0x7F) << shift;
        if (byte & 0x80 == 0) break;
        shift += 7;
    }
    if (value > std.math.maxInt(u32)) return null;
    offset.* = at;
    return @intCast(value);
}

/// Skip `count` varints already validated by the segment decoder.
pub fn skipVarints(bytes: []const u8, offset: *usize, count: usize) void {
    var remaining = count;
    var at = offset.*;
    while (remaining > 0) : (at += 1) {
        if (bytes[at] & 0x80 == 0) remaining -= 1;
    }
    offset.* = at;
}

/// The position tables of a validated positional index (see
/// `lexical_segment.decode`, which checks every rule this walk relies on:
/// term ranges contiguous in dictionary order, well-formed varints, token
/// counts equal to document lengths). Owned by `allocator`.
pub fn buildPositionTables(allocator: std.mem.Allocator, index: Index) std.mem.Allocator.Error!PositionTables {
    const sections = index.positions.?;
    const term_starts = try allocator.alloc(usize, index.terms.len);
    errdefer allocator.free(term_starts);
    var at: usize = 0;
    for (index.terms, 0..) |entry, term_index| {
        term_starts[term_index] = at;
        var ordinals: usize = 0;
        for (index.postings[entry.postings_start .. entry.postings_start + entry.postings_length]) |posting| ordinals += posting.term_frequency;
        skipVarints(sections.positions, &at, ordinals);
    }
    const document_starts = try allocator.alloc(usize, index.document_lengths.len);
    at = 0;
    for (index.document_lengths, 0..) |length, document_index| {
        document_starts[document_index] = at;
        at += 4;
        skipVarints(sections.offsets, &at, @as(usize, length) * 2);
    }
    return .{ .term_starts = term_starts, .document_starts = document_starts };
}

/// The token spans of `document_index` (section 5) into `output`, which must
/// hold its document length. Returns the filled prefix.
pub fn readTokenSpans(index: Index, tables: PositionTables, document_index: usize, output: []TokenSpan) []TokenSpan {
    const bytes = index.positions.?.offsets;
    var at = tables.document_starts[document_index];
    const count: usize = std.mem.readInt(u32, bytes[at..][0..4], .little);
    at += 4;
    var start: u32 = 0;
    for (output[0..count]) |*span| {
        start += readVarint(bytes, &at).?;
        span.* = .{ .start = start, .length = readVarint(bytes, &at).? };
    }
    return output[0..count];
}

/// The dictionary index of exactly `term` (bytes): a binary search in a
/// sorted dictionary, else a scan.
pub fn lookupExact(index: Index, term: []const u8) ?usize {
    if (!index.sorted_terms) {
        for (index.terms, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.term, term)) return i;
        }
        return null;
    }
    const position = lowerBound(index.terms, term);
    if (position < index.terms.len and std.mem.eql(u8, index.terms[position].term, term)) return position;
    return null;
}

/// The first dictionary index whose term is not less than `term` (bytes);
/// the dictionary must be sorted.
pub fn lowerBound(terms: []const TermEntry, term: []const u8) usize {
    var low: usize = 0;
    var high: usize = terms.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (std.mem.order(u8, terms[middle].term, term) == .lt) low = middle + 1 else high = middle;
    }
    return low;
}

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

/// The dictionary entries of a query's unique terms, in first-occurrence
/// order -- exactly the terms (and the order) `scoreQuery` accumulates over.
/// Caller frees the slice.
pub fn resolveQuery(allocator: std.mem.Allocator, index: Index, query: []const u8) std.mem.Allocator.Error![]TermEntry {
    return resolveQueryTraced(allocator, index, query, null, true);
}

/// `resolveQuery` that also records, in `trace` (S2-T4), how many unique terms
/// the query analysed to and which of them were not found in the files the
/// query may search: not in the dictionary, or only in chunks outside the
/// trace's path prefix and label scope. They are recorded as the analysed
/// (lowercased) query term, in query order. `lookup == false` still counts the
/// terms but skips the dictionary (vector mode never uses the result).
pub fn resolveQueryTraced(
    allocator: std.mem.Allocator,
    index: Index,
    query: []const u8,
    trace: ?*hybrid.Trace,
    lookup: bool,
) std.mem.Allocator.Error![]TermEntry {
    var resolved = std.ArrayList(TermEntry).empty;
    errdefer resolved.deinit(allocator);
    var query_tokens = analysis.TokenIterator.init(query);
    while (query_tokens.next()) |query_token| {
        if (!analysis.isFirstOccurrence(query, query_token)) continue;
        if (trace) |t| t.unique_terms += 1;
        if (!lookup) continue;
        const term_index = findTerm(index.terms, query_token.bytes) orelse {
            if (trace) |t| try noteUnmatched(t, query_token.bytes, true);
            continue;
        };
        if (trace) |t| {
            if (!hasInScopePosting(index, index.terms[term_index], t)) try noteUnmatched(t, query_token.bytes, true);
        }
        try resolved.append(allocator, index.terms[term_index]);
    }
    return resolved.toOwnedSlice(allocator);
}

/// Record `term` (copied, lowercased when `lower`) as unmatched in `trace`.
pub fn noteUnmatched(trace: *hybrid.Trace, term: []const u8, lower: bool) std.mem.Allocator.Error!void {
    const copy = try trace.allocator.dupe(u8, term);
    if (lower) for (copy) |*byte| {
        byte.* = std.ascii.toLower(byte.*);
    };
    try trace.unmatched.append(trace.allocator, .{ .term = copy });
}

/// Whether `entry` occurs in any chunk inside `trace`'s path prefix and label
/// scope. Stops at the first such chunk, so an unscoped query reads one
/// posting per term.
pub fn hasInScopePosting(index: Index, entry: TermEntry, trace: *const hybrid.Trace) bool {
    const list = index.postings[entry.postings_start .. entry.postings_start + entry.postings_length];
    for (list) |posting| {
        const document = trace.scope_documents[posting.document_index];
        if (trace.scope_roots) |mask| if (!mask.allows(posting.document_index)) continue; // S3-T3
        if (hybrid.matchesPath(document.path, trace.scope_prefix) and
            hybrid.isAuthorized(document.required_labels, trace.scope_labels)) return true;
    }
    return false;
}

/// Sparse BM25 scoring of a resolved query: yields only the chunks that
/// contain at least one query term, in ascending `document_index`, with the
/// per-term contributions summed in query-term order -- the same additions in
/// the same order as `scoreQuery`, so every score is bit-identical to the
/// dense array's entry. Needs each term's postings to be strictly ascending by
/// document (the segment decoder rejects anything else) and keeps no
/// per-chunk state: only one cursor per query term.
/// S5-T3 (`fuzzy.zig`): which of a `SparseScorer`'s terms are the members
/// of a typed term's group. A group's members are adjacent in `terms`; in a
/// chunk the group adds its best member's `weight` x BM25 (at the group's
/// one df, in `document_frequencies`), never their sum.
pub const Grouping = struct {
    pub const plain = std.math.maxInt(u32);
    /// Per term: its group, or `plain`.
    group_of: []const u32,
    weights: []const f32,
};

pub const SparseScorer = struct {
    index: Index,
    terms: []const TermEntry,
    cursors: []usize,
    parameters: scoring.Bm25Parameters,
    /// S3-T3: BM25 collection statistics over the caller's visible scope
    /// (`scope.zig`); null = the whole index's.
    collection: ?scoring.CollectionStatistics = null,
    /// S3-T3: each resolved term's document frequency in the visible scope,
    /// in `terms` order; null = the dictionary's.
    document_frequencies: ?[]const u32 = null,
    /// S5-T3: the fuzzy-v1 groups among `terms`; null scores every term as
    /// before (the code path of before S5-T3).
    grouping: ?Grouping = null,

    /// `cursors` must hold `terms.len` entries.
    pub fn init(index: Index, terms: []const TermEntry, cursors: []usize, parameters: scoring.Bm25Parameters) SparseScorer {
        std.debug.assert(cursors.len >= terms.len);
        @memset(cursors[0..terms.len], 0);
        return .{ .index = index, .terms = terms, .cursors = cursors[0..terms.len], .parameters = parameters };
    }

    fn contribution(scorer: *const SparseScorer, term_index: usize, entry: TermEntry, posting: Posting) f32 {
        const document_index: usize = posting.document_index;
        const collection = scorer.collection orelse scoring.CollectionStatistics{
            .document_count = @intCast(scorer.index.document_lengths.len),
            .average_document_length = scorer.index.average_document_length,
        };
        const document_frequency = if (scorer.document_frequencies) |frequencies| frequencies[term_index] else entry.document_frequency;
        return scoring.bm25Contribution(
            @floatFromInt(posting.term_frequency),
            @floatFromInt(scorer.index.document_lengths[document_index]),
            collection.average_document_length,
            document_frequency,
            collection.document_count,
            scorer.parameters,
        );
    }

    fn postingsOf(scorer: *const SparseScorer, entry: TermEntry) []const Posting {
        return scorer.index.postings[entry.postings_start .. entry.postings_start + entry.postings_length];
    }

    pub fn next(scorer: *SparseScorer) ?hybrid.LexicalMatch {
        var smallest: ?u32 = null;
        for (scorer.terms, scorer.cursors) |entry, cursor| {
            const list = scorer.postingsOf(entry);
            if (cursor >= list.len) continue;
            const candidate = list[cursor].document_index;
            if (smallest == null or candidate < smallest.?) smallest = candidate;
        }
        const document_index = smallest orelse return null;
        if (scorer.grouping) |grouping| return .{ .document_index = document_index, .score = scorer.groupedAt(grouping, document_index, true) };
        var score: f32 = 0;
        for (scorer.terms, scorer.cursors, 0..) |entry, *cursor, term_index| {
            const list = scorer.postingsOf(entry);
            if (cursor.* >= list.len or list[cursor.*].document_index != document_index) continue;
            score += scorer.contribution(term_index, entry, list[cursor.*]);
            cursor.* += 1;
        }
        return .{ .document_index = document_index, .score = score };
    }

    /// The grouped score of `document_index`: plain terms summed in order,
    /// each group's best weighted member added where the group ends. With
    /// `advance`, the cursors at `document_index` move on (`next`);
    /// otherwise each list is searched (`scoreOf`).
    fn groupedAt(scorer: *SparseScorer, grouping: Grouping, document_index: u32, comptime advance: bool) f32 {
        var score: f32 = 0;
        var best: ?f32 = null;
        for (scorer.terms, 0..) |entry, term_index| {
            const group = grouping.group_of[term_index];
            if (best != null and (group == Grouping.plain or group != grouping.group_of[term_index - 1])) {
                score += best.?;
                best = null;
            }
            const list = scorer.postingsOf(entry);
            const at: usize = if (advance) scorer.cursors[term_index] else lowerPosting(list, document_index);
            if (at >= list.len or list[at].document_index != document_index) continue;
            if (advance) scorer.cursors[term_index] += 1;
            const part = scorer.contribution(term_index, entry, list[at]);
            if (group == Grouping.plain) {
                score += part;
            } else {
                const weighted = grouping.weights[term_index] * part;
                if (best == null or weighted > best.?) best = weighted;
            }
        }
        if (best) |b| score += b;
        return score;
    }

    fn lowerPosting(list: []const Posting, document_index: usize) usize {
        var low: usize = 0;
        var high: usize = list.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (list[middle].document_index < document_index) low = middle + 1 else high = middle;
        }
        return low;
    }

    /// The score `next` yields for `document_index` (0 when no query term
    /// occurs in it), found by binary search; same summation order.
    pub fn scoreOf(scorer: *const SparseScorer, document_index: usize) f32 {
        if (scorer.grouping) |grouping| return @constCast(scorer).groupedAt(grouping, @intCast(document_index), false);
        var score: f32 = 0;
        for (scorer.terms, 0..) |entry, term_index| {
            const list = scorer.postingsOf(entry);
            var low: usize = 0;
            var high: usize = list.len;
            while (low < high) {
                const middle = low + (high - low) / 2;
                if (list[middle].document_index < document_index) low = middle + 1 else high = middle;
            }
            if (low < list.len and list[low].document_index == document_index) {
                score += scorer.contribution(term_index, entry, list[low]);
            }
        }
        return score;
    }
};

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
