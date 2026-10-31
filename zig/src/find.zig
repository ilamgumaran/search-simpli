//! `find` in the core (S3-T2, CAP-19 FR-17 and FR-25,
//! `docs/folder-knowledge-implementation.md` §3 and §8): the traditional
//! search box over one opened generation.
//!
//! Modes (`Mode`):
//! - `words`: every analyzed query term occurs in the chunk (conjunctive),
//!   then BM25 order. `search_knowledge` stays disjunctive BM25.
//! - `phrase`: the analyzed query tokens are adjacent and in order by token
//!   ordinal (`HYBLEX02` section 4) within one chunk, then BM25 order;
//!   repeated tokens ("the the") are ordinary positions. A generation
//!   without positions answers `CAPACITY` "re-index required: positions
//!   absent". A phrase is chunk-local (CAP-19 open decision 1).
//! - `prefix`: earlier query terms are required literally; only the last
//!   token may end in `*` and it expands over the sorted dictionary to the
//!   terms that occur in at least one chunk the caller may see, at most
//!   1,000 of them, else `CAPACITY`.
//! A query in double quotes forces `phrase`; a trailing `*` forces `prefix`.
//!
//! Every matching chunk is scored (page size never bounds scoring work, NFR-10),
//! overlapping chunks of one file whose matches all lie in their shared lines
//! are deduplicated to the earlier chunk, the rest is ordered by score desc,
//! then root_id, path, start_line (INV-08) and paged by a generation-bound
//! cursor `"<generation>:<offset>"`. Hits carry `match_offsets` (zero-based
//! half-open codepoint ranges into the chunk's `content`) and a snippet of at
//! most 240 codepoints cut at token boundaries with `snippet_offsets`.
//!
//! Scope: the request's `path_prefix` and trusted `principal_labels` filter
//! before candidate generation and bound prefix expansion; S3-T3 widens the
//! scope to roots and supplies visible-scope BM25 statistics through
//! `scoring.CorpusStatistics` (`Request.statistics`).
//!
//! Memory: everything an `Answer` points at, and every temporary, comes from
//! the caller's `allocator`, which should be an arena released after the
//! answer is used (nothing is freed piecemeal).
const std = @import("std");
const analysis = @import("analysis.zig");
const analyzer_v2 = @import("analyzer_v2.zig");
const chunker = @import("chunker.zig");
const engine_module = @import("engine.zig");
const hybrid = @import("hybrid.zig");
const postings = @import("postings.zig");
const scoring = @import("scoring.zig");
const source = @import("source.zig");

pub const Mode = enum {
    words,
    phrase,
    prefix,

    pub fn label(mode: Mode) []const u8 {
        return @tagName(mode);
    }

    pub fn parse(text: []const u8) ?Mode {
        return std.meta.stringToEnum(Mode, text);
    }
};

pub const default_page_size: usize = 20;
pub const max_page_size: usize = 100;
pub const max_prefix_expansions: usize = 1_000;
pub const max_snippet_codepoints: u32 = 240;
pub const positions_absent_message = "re-index required: positions absent";
pub const stale_cursor_message = "stale cursor";
pub const legacy_root_id = "r-legacy";

pub const Request = struct {
    query: []const u8,
    mode: Mode = .words,
    path_prefix: ?[]const u8 = null,
    principal_labels: []const []const u8 = &.{},
    page_size: usize = default_page_size,
    cursor: ?[]const u8 = null,
    /// The generation's root ids (manifest `meta.roots`). A document path
    /// `"<root_id>/rest"` belongs to that root; any other path to the first.
    root_ids: []const []const u8 = &.{legacy_root_id},
    /// BM25 statistics (S3-T3 hook); null is the whole generation.
    statistics: ?scoring.CorpusStatistics = null,
    /// S3-T3: the roots the trusted caller named (`scope.zig`); null = all.
    visible_roots: ?hybrid.RootMask = null,
    /// S3-T3: filled by the scoped caller (`service.ScopedService.find`) from
    /// the generation's pending and skipped files in the scope.
    pending_files: usize = 0,
    truncated: bool = false,
    bm25: scoring.Bm25Parameters = .{},
    /// Recompute highlight offsets by re-tokenizing each hit's text instead
    /// of reading section 5: the rollback NFR-11 names, kept so its cost can
    /// be measured. A `HYBLEX01` generation always recomputes.
    recompute_offsets: bool = false,
};

/// `[start, end)` in codepoints.
pub const Range = [2]u32;

pub const Hit = struct {
    document_index: usize,
    chunk_id: []const u8,
    root_id: []const u8,
    path: []const u8,
    section_path: []const []const u8,
    start_line: u32,
    end_line: u32,
    score: f32,
    content: []const u8,
    match_offsets: []const Range,
    snippet: []const u8,
    snippet_start: u32,
    snippet_offsets: []const Range,
};

pub const FileCount = struct {
    root_id: []const u8,
    path: []const u8,
    hits: usize,
};

pub const Coverage = struct {
    files: usize,
    sections: usize,
};

pub const Answer = struct {
    generation: u64,
    query: []const u8,
    mode: Mode,
    page_size: usize,
    cursor: ?[]const u8,
    path_prefix: ?[]const u8,
    hits: []const Hit,
    files: []const FileCount,
    total_hits: usize,
    /// Overlapping chunks dropped because an earlier chunk shows the same
    /// occurrence (not part of the JSON).
    deduplicated: usize,
    exact_match: ?bool,
    empty: bool,
    coverage: Coverage,
    truncated: bool,
    next_cursor: ?[]const u8,
    pending_files: usize,
};

pub const Outcome = union(enum) {
    ok: Answer,
    failed: source.Failure,
};

pub const Error = std.mem.Allocator.Error || analyzer_v2.Error;

/// One match inside a chunk: token ordinals `first..last` (inclusive) and a
/// key naming what matched (a query term for words/prefix; 0 for a phrase).
const Match = struct {
    first: u32,
    last: u32,
    key: u32,
};

const Candidate = struct {
    document_index: u32,
    score: f32,
    matches: []Match = &.{},
    /// `matches` is filled (phrase: always; words/prefix: on demand).
    attached: bool = false,
    root_id: []const u8 = "",
    path: []const u8 = "",
    kept: bool = true,
};

const Parsed = struct {
    mode: Mode,
    text: []const u8,
};

pub fn find(allocator: std.mem.Allocator, engine: engine_module.Engine, request: Request) Error!Outcome {
    if (!std.unicode.utf8ValidateSlice(request.query)) return fail(allocator, .invalid_argument, "query is not valid UTF-8", .{});
    if (request.page_size < 1 or request.page_size > max_page_size)
        return fail(allocator, .invalid_argument, "page_size must be 1..{d}", .{max_page_size});
    const offset: usize = if (request.cursor) |cursor| switch (parseCursor(cursor, engine.generation)) {
        .offset => |value| value,
        .malformed => return fail(allocator, .invalid_argument, "malformed cursor", .{}),
        .stale => return fail(allocator, .invalid_argument, stale_cursor_message, .{}),
    } else 0;

    const parsed = parseQuery(request.query, request.mode) orelse
        return fail(allocator, .invalid_argument, "only the last token may end in *", .{});
    const tokens = try tokenizeQuery(allocator, engine, parsed.text);
    if (tokens.len == 0) return fail(allocator, .invalid_argument, "empty query", .{});
    const index = engine.lexical_index;
    if (parsed.mode == .phrase and index.positions == null)
        return .{ .failed = .{ .code = .capacity, .message = positions_absent_message } };

    var context = Context{
        .allocator = allocator,
        .engine = engine,
        .index = index,
        .request = request,
        .statistics = request.statistics orelse scoring.CorpusStatistics.global(index.document_lengths.len, index.average_document_length),
        .tables = null,
    };
    if (index.positions != null) context.tables = engine.position_tables orelse try postings.buildPositionTables(allocator, index);

    var candidates: []Candidate = &.{};
    switch (parsed.mode) {
        .words, .phrase => {
            const resolved = try context.resolveAll(tokens);
            if (resolved) |terms| {
                context.highlight_terms = terms.unique;
                candidates = try context.conjunctive(terms.unique, null);
                if (parsed.mode == .phrase) candidates = try context.filterPhrase(candidates, terms);
            }
        },
        .prefix => {
            const earlier = tokens[0 .. tokens.len - 1];
            const resolved = try context.resolveAll(earlier);
            if (resolved) |terms| {
                const expansion = try context.expand(tokens[tokens.len - 1]);
                switch (expansion) {
                    .over => return fail(allocator, .capacity, "prefix \"{s}\" expands to more than {d} terms", .{ tokens[tokens.len - 1], max_prefix_expansions }),
                    .terms => |expanded| if (expanded.len > 0) {
                        const highlight = try allocator.alloc(usize, terms.unique.len + expanded.len);
                        @memcpy(highlight[0..terms.unique.len], terms.unique);
                        @memcpy(highlight[terms.unique.len..], expanded);
                        context.highlight_terms = highlight;
                        candidates = try context.conjunctive(terms.unique, expanded);
                    },
                }
            }
        },
    }

    for (candidates) |*candidate| {
        const document = engine.documents[candidate.document_index];
        const split = splitRoot(document.path, request.root_ids);
        candidate.root_id = split.root_id;
        candidate.path = split.path;
    }
    try context.deduplicate(candidates, parsed.mode);

    var kept = std.ArrayList(Candidate).empty;
    for (candidates) |candidate| if (candidate.kept) try kept.append(allocator, candidate);
    std.sort.pdq(Candidate, kept.items, engine.documents, rankedBefore);

    const total = kept.items.len;
    const page_start = @min(offset, total);
    const page_end = @min(page_start + request.page_size, total);
    const page = kept.items[page_start..page_end];
    if (parsed.mode != .phrase) try context.attachMatches(page);

    const hits = try allocator.alloc(Hit, page.len);
    for (page, hits) |candidate, *hit| hit.* = try context.makeHit(candidate);

    return .{ .ok = .{
        .generation = engine.generation,
        .query = request.query,
        .mode = parsed.mode,
        .page_size = request.page_size,
        .cursor = request.cursor,
        .path_prefix = request.path_prefix,
        .hits = hits,
        .files = try fileCounts(allocator, kept.items),
        .total_hits = total,
        .deduplicated = candidates.len - total,
        .exact_match = if (parsed.mode == .phrase) total > 0 else null,
        .empty = hits.len == 0,
        .coverage = try coverageOf(allocator, hits),
        .truncated = request.truncated,
        .next_cursor = if (page_end < total) try std.fmt.allocPrint(allocator, "{d}:{d}", .{ engine.generation, page_end }) else null,
        .pending_files = request.pending_files,
    } };
}

fn fail(allocator: std.mem.Allocator, code: source.Code, comptime format: []const u8, arguments: anytype) Error!Outcome {
    return .{ .failed = .{ .code = code, .message = try std.fmt.allocPrint(allocator, format, arguments) } };
}

const CursorParse = union(enum) { offset: usize, malformed, stale };

fn parseCursor(cursor: []const u8, generation: u64) CursorParse {
    const colon = std.mem.indexOfScalar(u8, cursor, ':') orelse return .malformed;
    const cursor_generation = std.fmt.parseInt(u64, cursor[0..colon], 10) catch return .malformed;
    const value = std.fmt.parseInt(usize, cursor[colon + 1 ..], 10) catch return .malformed;
    if (cursor_generation != generation) return .stale;
    return .{ .offset = value };
}

/// A query in double quotes is a phrase; a trailing `*` makes a prefix
/// query; null when a `*` ends any token but the last.
fn parseQuery(query: []const u8, mode: Mode) ?Parsed {
    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"')
        return .{ .mode = .phrase, .text = trimmed[1 .. trimmed.len - 1] };
    var text = trimmed;
    var effective = mode;
    if (text.len > 0 and text[text.len - 1] == '*') {
        effective = .prefix;
        text = text[0 .. text.len - 1];
    }
    if (std.mem.indexOfScalar(u8, text, '*') != null) return null;
    return .{ .mode = effective, .text = text };
}

fn isAnalyzerV2(engine: engine_module.Engine) bool {
    return std.mem.eql(u8, engine.analyzer_id, analyzer_v2.analyzer_id);
}

/// The query's analyzed tokens in order (repeats kept), with the engine's
/// analyzer: `analyzer-v2` for v2 generations, the ASCII tokenizer
/// lowercased for every older one (their dictionaries match ASCII
/// case-insensitively).
fn tokenizeQuery(allocator: std.mem.Allocator, engine: engine_module.Engine, text: []const u8) Error![]const []const u8 {
    if (isAnalyzerV2(engine)) return analyzer_v2.tokenize(allocator, text);
    const positioned = try analysis.tokenizePositioned(allocator, text, true);
    const tokens = try allocator.alloc([]const u8, positioned.len);
    for (positioned, tokens) |token, *slot| slot.* = token.bytes;
    return tokens;
}

const Resolved = struct {
    /// Dictionary indexes of the unique terms, in first-occurrence order.
    unique: []const usize,
    /// For each query token, its slot in `unique`.
    slots: []const u32,
};

const Expansion = union(enum) { terms: []const usize, over };

const Context = struct {
    allocator: std.mem.Allocator,
    engine: engine_module.Engine,
    index: postings.Index,
    request: Request,
    statistics: scoring.CorpusStatistics,
    tables: ?postings.PositionTables,
    /// The terms a words or prefix hit highlights: the query's unique terms,
    /// or a prefix query's earlier terms followed by its expansions. A
    /// match's key is the term's slot here.
    highlight_terms: []const usize = &.{},

    fn lookup(context: *const Context, term: []const u8) ?usize {
        if (context.index.sorted_terms) return postings.lookupExact(context.index, term);
        return postings.findTerm(context.index.terms, term);
    }

    /// Null when any token is not in the dictionary (nothing can match).
    fn resolveAll(context: *const Context, tokens: []const []const u8) Error!?Resolved {
        var unique = std.ArrayList(usize).empty;
        const slots = try context.allocator.alloc(u32, tokens.len);
        for (tokens, slots) |token, *slot| {
            const term_index = context.lookup(token) orelse return null;
            const existing = std.mem.indexOfScalar(usize, unique.items, term_index);
            slot.* = @intCast(existing orelse unique.items.len);
            if (existing == null) try unique.append(context.allocator, term_index);
        }
        return .{ .unique = unique.items, .slots = slots };
    }

    fn postingsOf(context: *const Context, term_index: usize) []const postings.Posting {
        const entry = context.index.terms[term_index];
        return context.index.postings[entry.postings_start .. entry.postings_start + entry.postings_length];
    }

    fn visible(context: *const Context, document_index: usize) bool {
        if (context.request.visible_roots) |mask| if (!mask.allows(document_index)) return false;
        const document = context.engine.documents[document_index];
        return hybrid.matchesPath(document.path, context.request.path_prefix) and
            hybrid.isAuthorized(document.required_labels, context.request.principal_labels);
    }

    fn contribution(context: *const Context, term_index: usize, posting: postings.Posting) f32 {
        return context.statistics.contribution(
            posting.term_frequency,
            context.index.document_lengths[posting.document_index],
            term_index,
            context.index.terms[term_index].document_frequency,
            context.request.bm25,
        );
    }

    /// Dictionary terms starting with `prefix` that occur in a visible
    /// chunk, in dictionary order, or `.over` past the cap.
    fn expand(context: *const Context, prefix: []const u8) Error!Expansion {
        var found = std.ArrayList(usize).empty;
        const terms = context.index.terms;
        if (context.index.sorted_terms) {
            var at = postings.lowerBound(terms, prefix);
            while (at < terms.len and std.mem.startsWith(u8, terms[at].term, prefix)) : (at += 1) {
                if (!context.hasVisiblePosting(at)) continue;
                if (found.items.len == max_prefix_expansions) return .over;
                try found.append(context.allocator, at);
            }
        } else {
            for (terms, 0..) |entry, at| {
                if (entry.term.len < prefix.len or !analysis.eqlCaseFoldAscii(entry.term[0..prefix.len], prefix)) continue;
                if (!context.hasVisiblePosting(at)) continue;
                if (found.items.len == max_prefix_expansions) return .over;
                try found.append(context.allocator, at);
            }
        }
        return .{ .terms = found.items };
    }

    fn hasVisiblePosting(context: *const Context, term_index: usize) bool {
        for (context.postingsOf(term_index)) |posting| {
            if (context.visible(posting.document_index)) return true;
        }
        return false;
    }

    /// Visible chunks holding every term of `required` and, when
    /// `any_of` is given, at least one of its terms; scored by BM25 over
    /// `required` (query order) plus every `any_of` term present.
    fn conjunctive(context: *Context, required: []const usize, any_of: ?[]const usize) Error![]Candidate {
        const allocator = context.allocator;
        const document_count = context.index.document_lengths.len;
        var union_score: []f32 = &.{};
        var union_present: []bool = &.{};
        if (any_of) |terms| {
            union_score = try allocator.alloc(f32, document_count);
            union_present = try allocator.alloc(bool, document_count);
            @memset(union_score, 0);
            @memset(union_present, false);
            for (terms) |term_index| {
                for (context.postingsOf(term_index)) |posting| {
                    union_score[posting.document_index] += context.contribution(term_index, posting);
                    union_present[posting.document_index] = true;
                }
            }
        }

        var found = std.ArrayList(Candidate).empty;
        if (required.len == 0) {
            for (union_present, 0..) |present, document_index| {
                if (!present or !context.visible(document_index)) continue;
                try found.append(allocator, .{ .document_index = @intCast(document_index), .score = union_score[document_index] });
            }
            return found.items;
        }

        // Drive by the shortest list; find the document in the others by a
        // moving binary search (every list is ascending by document).
        var driver: usize = 0;
        for (required, 0..) |term_index, slot| {
            if (context.postingsOf(term_index).len < context.postingsOf(required[driver]).len) driver = slot;
        }
        const lows = try allocator.alloc(usize, required.len);
        @memset(lows, 0);
        const found_postings = try allocator.alloc(postings.Posting, required.len);
        outer: for (context.postingsOf(required[driver])) |driver_posting| {
            const document_index = driver_posting.document_index;
            if (any_of != null and !union_present[document_index]) continue;
            for (required, 0..) |term_index, slot| {
                if (slot == driver) {
                    found_postings[slot] = driver_posting;
                    continue;
                }
                const list = context.postingsOf(term_index);
                var low = lows[slot];
                var high = list.len;
                while (low < high) {
                    const middle = low + (high - low) / 2;
                    if (list[middle].document_index < document_index) low = middle + 1 else high = middle;
                }
                lows[slot] = low;
                if (low >= list.len) break :outer;
                if (list[low].document_index != document_index) continue :outer;
                found_postings[slot] = list[low];
            }
            if (!context.visible(document_index)) continue;
            var score: f32 = 0;
            for (required, found_postings) |term_index, posting| score += context.contribution(term_index, posting);
            if (any_of != null) score += union_score[document_index];
            try found.append(allocator, .{ .document_index = document_index, .score = score });
        }
        return found.items;
    }

    /// Every candidate's ordinals of `terms` (key = slot in `terms`), merged
    /// in ordinal order: one forward walk of each term's section-4 run over
    /// the candidates (ascending by document).
    fn ordinals(context: *const Context, sorted_documents: []const u32, terms: []const usize) Error![][]Match {
        const allocator = context.allocator;
        const tables = context.tables.?;
        const bytes = context.index.positions.?.positions;
        const lists = try allocator.alloc(std.ArrayList(Match), sorted_documents.len);
        for (lists) |*list| list.* = .empty;
        for (terms, 0..) |term_index, key| {
            const list = context.postingsOf(term_index);
            var at = tables.term_starts[term_index];
            var next: usize = 0;
            for (list) |posting| {
                if (next >= sorted_documents.len) break;
                while (next < sorted_documents.len and sorted_documents[next] < posting.document_index) next += 1;
                if (next < sorted_documents.len and sorted_documents[next] == posting.document_index) {
                    var ordinal: u32 = 0;
                    for (0..posting.term_frequency) |k| {
                        const value = postings.readVarint(bytes, &at).?;
                        ordinal = if (k == 0) value else ordinal + value;
                        try lists[next].append(allocator, .{ .first = ordinal, .last = ordinal, .key = @intCast(key) });
                    }
                } else postings.skipVarints(bytes, &at, posting.term_frequency);
            }
        }
        const result = try allocator.alloc([]Match, sorted_documents.len);
        for (lists, result) |*list, *slot| {
            std.sort.pdq(Match, list.items, {}, matchBefore);
            slot.* = list.items;
        }
        return result;
    }

    /// Keep the candidates where the query tokens occur adjacent and in
    /// order; record each occurrence (non-overlapping, left to right).
    fn filterPhrase(context: *const Context, candidates: []Candidate, terms: Resolved) Error![]Candidate {
        const allocator = context.allocator;
        const documents = try allocator.alloc(u32, candidates.len);
        for (candidates, documents) |candidate, *slot| slot.* = candidate.document_index;
        const per_document = try context.ordinals(documents, terms.unique);
        var kept = std.ArrayList(Candidate).empty;
        const length: u32 = @intCast(terms.slots.len);
        for (candidates, per_document) |candidate, matches| {
            // Ordinals of each unique term, ascending.
            const by_slot = try allocator.alloc(std.ArrayList(u32), terms.unique.len);
            for (by_slot) |*list| list.* = .empty;
            for (matches) |match| try by_slot[match.key].append(allocator, match.first);
            var occurrences = std.ArrayList(Match).empty;
            var next_free: u32 = 0;
            for (by_slot[terms.slots[0]].items) |start| {
                if (start < next_free) continue;
                var all = true;
                for (terms.slots[1..], 1..) |slot, i| {
                    if (std.sort.binarySearch(u32, by_slot[slot].items, start + @as(u32, @intCast(i)), orderU32) == null) {
                        all = false;
                        break;
                    }
                }
                if (!all) continue;
                try occurrences.append(allocator, .{ .first = start, .last = start + length - 1, .key = 0 });
                next_free = start + length;
            }
            if (occurrences.items.len == 0) continue;
            var copy = candidate;
            copy.matches = occurrences.items;
            copy.attached = true;
            try kept.append(allocator, copy);
        }
        return kept.items;
    }

    /// Ordinal matches for words/prefix candidates (`terms` = the query's
    /// unique terms, or the prefix query's earlier terms then expansions).
    /// Only candidates not yet attached are filled.
    fn attachMatches(context: *Context, candidates: []Candidate) Error!void {
        const allocator = context.allocator;
        var order = std.ArrayList(u32).empty;
        for (candidates, 0..) |candidate, i| if (!candidate.attached) try order.append(allocator, @intCast(i));
        if (order.items.len == 0) return;
        if (context.index.positions == null) {
            for (order.items) |i| candidates[i].matches = try context.recomputedMatches(candidates[i].document_index);
        } else {
            std.sort.pdq(u32, order.items, candidates, struct {
                fn lessThan(all: []Candidate, a: u32, b: u32) bool {
                    return all[a].document_index < all[b].document_index;
                }
            }.lessThan);
            const documents = try allocator.alloc(u32, order.items.len);
            for (order.items, documents) |i, *slot| slot.* = candidates[i].document_index;
            const per_document = try context.ordinals(documents, context.highlight_terms);
            for (order.items, per_document) |i, matches| candidates[i].matches = matches;
        }
        for (order.items) |i| candidates[i].attached = true;
    }

    /// Matches found by re-tokenizing the chunk (a `HYBLEX01` generation):
    /// tokens equal to a highlight term.
    fn recomputedMatches(context: *const Context, document_index: u32) Error![]Match {
        const tokens = try context.contentTokens(document_index);
        var matches = std.ArrayList(Match).empty;
        const terms = context.index.terms;
        for (tokens, 0..) |token, ordinal| {
            for (context.highlight_terms, 0..) |term_index, slot| {
                if (!analysis.eqlCaseFoldAscii(terms[term_index].term, token.bytes)) continue;
                try matches.append(context.allocator, .{ .first = @intCast(ordinal), .last = @intCast(ordinal), .key = @intCast(slot) });
                break;
            }
        }
        return matches.items;
    }

    fn contentTokens(context: *const Context, document_index: u32) Error![]const analysis.PositionedToken {
        const text = context.engine.documents[document_index].text;
        if (isAnalyzerV2(context.engine)) return analyzer_v2.tokenizePositioned(context.allocator, text);
        return analysis.tokenizePositioned(context.allocator, text, true);
    }

    /// Each token's codepoint span in the chunk: section 5, or re-tokenized
    /// (no positions, or `recompute_offsets`).
    fn spans(context: *const Context, document_index: u32) Error![]const postings.TokenSpan {
        if (context.tables) |tables| if (!context.request.recompute_offsets) {
            const output = try context.allocator.alloc(postings.TokenSpan, context.index.document_lengths[document_index]);
            return postings.readTokenSpans(context.index, tables, document_index, output);
        };
        const tokens = try context.contentTokens(document_index);
        const output = try context.allocator.alloc(postings.TokenSpan, tokens.len);
        for (tokens, output) |token, *span| span.* = .{ .start = token.start, .length = token.length };
        return output;
    }

    /// Overlapping chunks of one file (the window overlap) whose every match
    /// lies in the lines they share with an earlier kept hit are dropped:
    /// the earlier chunk already shows that occurrence.
    fn deduplicate(context: *Context, candidates: []Candidate, mode: Mode) Error!void {
        if (candidates.len < 2) return;
        const allocator = context.allocator;
        const documents = context.engine.documents;
        const order = try allocator.alloc(u32, candidates.len);
        for (order, 0..) |*slot, i| slot.* = @intCast(i);
        std.sort.pdq(u32, order, CandidateView{ .candidates = candidates, .documents = documents }, CandidateView.byFileLine);

        // Which candidates overlap an earlier one of the same file at all.
        var needs = std.ArrayList(u32).empty;
        for (order, 0..) |i, position| {
            if (position == 0) continue;
            const previous = documents[candidates[order[position - 1]].document_index];
            const current = documents[candidates[i].document_index];
            if (std.mem.eql(u8, previous.path, current.path) and previous.end_line >= current.start_line) try needs.append(allocator, i);
        }
        if (needs.items.len == 0) return;
        if (mode != .phrase) {
            // Only the later chunk of an overlapping pair needs its matches.
            var later = std.ArrayList(Candidate).empty;
            for (needs.items) |i| try later.append(allocator, candidates[i]);
            try context.attachMatches(later.items);
            for (needs.items, later.items) |i, filled| candidates[i] = filled;
        }

        var group_start: usize = 0;
        while (group_start < order.len) {
            var group_end = group_start + 1;
            const path = documents[candidates[order[group_start]].document_index].path;
            while (group_end < order.len and std.mem.eql(u8, documents[candidates[order[group_end]].document_index].path, path)) group_end += 1;
            const group = order[group_start..group_end];
            for (group, 0..) |later, position| {
                if (position == 0) continue;
                const b = &candidates[later];
                const b_document = documents[b.document_index];
                const previous = documents[candidates[group[position - 1]].document_index];
                if (previous.end_line < b_document.start_line) continue;
                const b_spans = try context.spans(b.document_index);
                var all_shared = b.matches.len > 0;
                for (b.matches) |match| {
                    const end_line = lineOf(b_document.text, endOffset(b_spans, match.last));
                    var shared = false;
                    for (group[0..position]) |earlier| {
                        const a = candidates[earlier];
                        if (!a.kept) continue;
                        const a_document = documents[a.document_index];
                        if (a_document.end_line < b_document.start_line) continue;
                        const lines = sharedLines(a_document.text, b_document.text, a_document.end_line - b_document.start_line + 1);
                        if (end_line < lines) {
                            shared = true;
                            break;
                        }
                    }
                    if (!shared) {
                        all_shared = false;
                        break;
                    }
                }
                if (all_shared) b.kept = false;
            }
            group_start = group_end;
        }
    }

    fn makeHit(context: *const Context, candidate: Candidate) Error!Hit {
        const allocator = context.allocator;
        const document = context.engine.documents[candidate.document_index];
        const token_spans = try context.spans(candidate.document_index);
        const ranges = try allocator.alloc(Range, candidate.matches.len);
        const keys = try allocator.alloc(u32, candidate.matches.len);
        for (candidate.matches, ranges, keys) |match, *range, *key| {
            const first = token_spans[match.first];
            range.* = .{ first.start, endOffset(token_spans, match.last) };
            key.* = match.key;
        }
        const snippet = try makeSnippet(allocator, document.text, token_spans, ranges, keys);
        return .{
            .document_index = candidate.document_index,
            .chunk_id = document.id,
            .root_id = candidate.root_id,
            .path = candidate.path,
            .section_path = try splitSectionPath(allocator, document.section_path),
            .start_line = document.start_line,
            .end_line = document.end_line,
            .score = candidate.score,
            .content = document.text,
            .match_offsets = ranges,
            .snippet = snippet.text,
            .snippet_start = snippet.start,
            .snippet_offsets = snippet.offsets,
        };
    }
};

const CandidateView = struct {
    candidates: []const Candidate,
    documents: []const hybrid.Document,

    fn byFileLine(view: CandidateView, a: u32, b: u32) bool {
        const left = view.documents[view.candidates[a].document_index];
        const right = view.documents[view.candidates[b].document_index];
        switch (std.mem.order(u8, left.path, right.path)) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
        if (left.start_line != right.start_line) return left.start_line < right.start_line;
        return view.candidates[a].document_index < view.candidates[b].document_index;
    }
};

fn matchBefore(_: void, a: Match, b: Match) bool {
    if (a.first != b.first) return a.first < b.first;
    return a.key < b.key;
}

fn orderU32(target: u32, item: u32) std.math.Order {
    return std.math.order(target, item);
}

/// Score desc, then root_id, path, start_line (INV-08), then document index.
fn rankedBefore(documents: []const hybrid.Document, a: Candidate, b: Candidate) bool {
    if (a.score != b.score) return a.score > b.score;
    switch (std.mem.order(u8, a.root_id, b.root_id)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    switch (std.mem.order(u8, a.path, b.path)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    const left = documents[a.document_index];
    const right = documents[b.document_index];
    if (left.start_line != right.start_line) return left.start_line < right.start_line;
    return a.document_index < b.document_index;
}

fn endOffset(token_spans: []const postings.TokenSpan, ordinal: u32) u32 {
    const span = token_spans[ordinal];
    return span.start + span.length;
}

const RootSplit = struct { root_id: []const u8, path: []const u8 };

/// `"<root_id>/rest"` names a root of the generation; any other path belongs
/// to the first root (`r-legacy` for `index_folder` until S3-T3).
pub fn splitRoot(path: []const u8, root_ids: []const []const u8) RootSplit {
    for (root_ids) |root_id| {
        if (path.len > root_id.len and std.mem.startsWith(u8, path, root_id) and path[root_id.len] == '/')
            return .{ .root_id = root_id, .path = path[root_id.len + 1 ..] };
    }
    return .{ .root_id = if (root_ids.len > 0) root_ids[0] else legacy_root_id, .path = path };
}

fn splitSectionPath(allocator: std.mem.Allocator, joined: []const u8) Error![]const []const u8 {
    if (joined.len == 0) return &.{};
    var parts = std.ArrayList([]const u8).empty;
    var iterator = std.mem.splitScalar(u8, joined, 0x1F);
    while (iterator.next()) |part| try parts.append(allocator, part);
    return parts.items;
}

/// The 0-based line (LF count) of the codepoint just before `end`.
fn lineOf(text: []const u8, end: u32) usize {
    var line: usize = 0;
    var codepoint: u32 = 0;
    for (text) |byte| {
        if (byte & 0xC0 == 0x80) continue;
        if (codepoint + 1 >= end) break;
        if (byte == '\n') line += 1;
        codepoint += 1;
    }
    return line;
}

/// How many leading lines of chunk `b` are the trailing lines of chunk `a`
/// (the window overlap): the largest `j <= bound` with the last `j` lines of
/// `a` equal to the first `j` lines of `b`, each compared without leading
/// and trailing whitespace (both texts are stripped as a whole).
pub fn sharedLines(a: []const u8, b: []const u8, bound: u32) usize {
    var a_count: usize = 1;
    for (a) |byte| a_count += @intFromBool(byte == '\n');
    var b_count: usize = 1;
    for (b) |byte| b_count += @intFromBool(byte == '\n');
    var j: usize = @min(@as(usize, bound), @min(a_count, b_count));
    while (j > 0) : (j -= 1) {
        var a_lines = std.mem.splitScalar(u8, a, '\n');
        for (0..a_count - j) |_| _ = a_lines.next();
        var b_lines = std.mem.splitScalar(u8, b, '\n');
        var equal = true;
        for (0..j) |_| {
            if (!std.mem.eql(u8, stripped(a_lines.next().?), stripped(b_lines.next().?))) {
                equal = false;
                break;
            }
        }
        if (equal) return j;
    }
    return 0;
}

fn stripped(line: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = line.len;
    while (start < end) {
        const length = std.unicode.utf8ByteSequenceLength(line[start]) catch break;
        const cp = std.unicode.utf8Decode(line[start .. start + length]) catch break;
        if (!chunker.isWhitespace(cp)) break;
        start += length;
    }
    while (end > start) {
        var begin = end - 1;
        while (begin > start and line[begin] & 0xC0 == 0x80) begin -= 1;
        const cp = std.unicode.utf8Decode(line[begin..end]) catch break;
        if (!chunker.isWhitespace(cp)) break;
        end = begin;
    }
    return line[start..end];
}

const Snippet = struct { text: []const u8, start: u32, offsets: []const Range };

/// At most 240 codepoints of `text` around the best window of matches: the
/// window of at most 240 codepoints covering the most distinct match keys,
/// then the most matches, earliest first; widened evenly on both sides and
/// cut so it starts at a token start (or the text start) and ends at a token
/// end (or the text end). `snippet_offsets` are the matches inside it,
/// relative to its start.
fn makeSnippet(
    allocator: std.mem.Allocator,
    text: []const u8,
    token_spans: []const postings.TokenSpan,
    ranges: []const Range,
    keys: []const u32,
) Error!Snippet {
    const total: u32 = @intCast(analysis.codepointCount(text));
    var start: u32 = 0;
    var end: u32 = total;
    if (total > max_snippet_codepoints) {
        var window_start: u32 = 0;
        var window_end: u32 = 0;
        if (ranges.len > 0) {
            var best_first: usize = 0;
            var best_last: usize = 0;
            var best_distinct: usize = 0;
            var best_count: usize = 0;
            var seen = std.ArrayList(u32).empty;
            for (ranges, 0..) |first_range, first| {
                seen.clearRetainingCapacity();
                var last = first;
                var k = first;
                while (k < ranges.len and ranges[k][1] - first_range[0] <= max_snippet_codepoints) : (k += 1) {
                    if (std.mem.indexOfScalar(u32, seen.items, keys[k]) == null) try seen.append(allocator, keys[k]);
                    last = k;
                }
                const count = if (k > first) k - first else 1;
                const distinct = @max(seen.items.len, 1);
                if (distinct > best_distinct or (distinct == best_distinct and count > best_count)) {
                    best_first = first;
                    best_last = last;
                    best_distinct = distinct;
                    best_count = count;
                }
            }
            window_start = ranges[best_first][0];
            window_end = @max(ranges[best_last][1], ranges[best_first][1]);
            if (window_end - window_start > max_snippet_codepoints) window_end = window_start + max_snippet_codepoints;
        }
        const slack = max_snippet_codepoints - (window_end - window_start);
        var left = slack / 2;
        var right = slack - left;
        if (left > window_start) {
            right += left - window_start;
            left = window_start;
        }
        if (window_end + right > total) {
            const spare = window_end + right - total;
            right = total - window_end;
            left = @min(window_start, left + spare);
        }
        start = window_start - left;
        end = window_end + right;
        // Cut at token boundaries: never inside a token.
        if (start > 0) {
            var snapped = window_start;
            for (token_spans) |span| {
                if (span.start >= start) {
                    snapped = @min(span.start, window_start);
                    break;
                }
            }
            start = snapped;
        }
        if (end < total) {
            var snapped = window_end;
            var i = token_spans.len;
            while (i > 0) {
                i -= 1;
                const span_end = token_spans[i].start + token_spans[i].length;
                if (span_end <= end) {
                    snapped = @max(span_end, window_end);
                    break;
                }
            }
            end = @min(snapped, start + max_snippet_codepoints);
        }
    }
    var inside = std.ArrayList(Range).empty;
    for (ranges) |range| {
        if (range[0] >= start and range[1] <= end) try inside.append(allocator, .{ range[0] - start, range[1] - start });
    }
    return .{ .text = codepointSlice(text, start, end), .start = start, .offsets = inside.items };
}

fn codepointSlice(text: []const u8, start: u32, end: u32) []const u8 {
    var codepoint: u32 = 0;
    var start_byte: usize = text.len;
    var end_byte: usize = text.len;
    for (text, 0..) |byte, at| {
        if (byte & 0xC0 == 0x80) continue;
        if (codepoint == start) start_byte = at;
        if (codepoint == end) {
            end_byte = at;
            break;
        }
        codepoint += 1;
    }
    if (start_byte > end_byte) start_byte = end_byte;
    return text[start_byte..end_byte];
}

fn fileCounts(allocator: std.mem.Allocator, ranked: []const Candidate) Error![]const FileCount {
    var files = std.ArrayList(FileCount).empty;
    var slot_by_key = std.StringHashMap(usize).init(allocator);
    for (ranked) |candidate| {
        const key = try std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ candidate.root_id, candidate.path });
        const gop = try slot_by_key.getOrPut(key);
        if (!gop.found_existing) {
            gop.value_ptr.* = files.items.len;
            try files.append(allocator, .{ .root_id = candidate.root_id, .path = candidate.path, .hits = 0 });
        }
        files.items[gop.value_ptr.*].hits += 1;
    }
    return files.items;
}

/// Distinct files and sections (file plus section path) among this page's hits.
fn coverageOf(allocator: std.mem.Allocator, hits: []const Hit) Error!Coverage {
    var files = std.StringHashMap(void).init(allocator);
    var sections = std.StringHashMap(void).init(allocator);
    for (hits) |hit| {
        const file_key = try std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ hit.root_id, hit.path });
        try files.put(file_key, {});
        var section_key = std.ArrayList(u8).empty;
        try section_key.appendSlice(allocator, file_key);
        for (hit.section_path) |part| {
            try section_key.append(allocator, 0x1F);
            try section_key.appendSlice(allocator, part);
        }
        try sections.put(section_key.items, {});
    }
    return .{ .files = files.count(), .sections = sections.count() };
}

/// The §8 JSON of an answer (the request echo, generation, hits, files,
/// accuracy fields and paging). S3-T4 wires it to the ABI, CLI and RPC.
pub fn writeJson(json: *std.json.Stringify, answer: Answer) !void {
    try json.beginObject();
    try json.objectField("request");
    try json.beginObject();
    try json.objectField("query");
    try json.write(answer.query);
    try json.objectField("mode");
    try json.write(answer.mode.label());
    try json.objectField("path_prefix");
    try json.write(answer.path_prefix);
    try json.objectField("page_size");
    try json.write(answer.page_size);
    try json.objectField("cursor");
    try json.write(answer.cursor);
    try json.endObject();
    try json.objectField("generation");
    try json.write(answer.generation);
    try json.objectField("hits");
    try json.beginArray();
    for (answer.hits) |hit| {
        try json.beginObject();
        try json.objectField("chunk_id");
        try json.write(hit.chunk_id);
        try json.objectField("root_id");
        try json.write(hit.root_id);
        try json.objectField("path");
        try json.write(hit.path);
        try json.objectField("section_path");
        try json.write(hit.section_path);
        try json.objectField("start_line");
        try json.write(hit.start_line);
        try json.objectField("end_line");
        try json.write(hit.end_line);
        try json.objectField("score");
        try json.write(hit.score);
        try json.objectField("snippet");
        try json.write(hit.snippet);
        try json.objectField("snippet_start");
        try json.write(hit.snippet_start);
        try json.objectField("snippet_offsets");
        try writeRanges(json, hit.snippet_offsets);
        try json.objectField("match_offsets");
        try writeRanges(json, hit.match_offsets);
        try json.endObject();
    }
    try json.endArray();
    try json.objectField("files");
    try json.beginArray();
    for (answer.files) |file| {
        try json.beginObject();
        try json.objectField("root_id");
        try json.write(file.root_id);
        try json.objectField("path");
        try json.write(file.path);
        try json.objectField("hits");
        try json.write(file.hits);
        try json.endObject();
    }
    try json.endArray();
    try json.objectField("exact_match");
    try json.write(answer.exact_match);
    try json.objectField("empty");
    try json.write(answer.empty);
    try json.objectField("coverage");
    try json.beginObject();
    try json.objectField("files");
    try json.write(answer.coverage.files);
    try json.objectField("sections");
    try json.write(answer.coverage.sections);
    try json.endObject();
    try json.objectField("truncated");
    try json.write(answer.truncated);
    try json.objectField("next_cursor");
    try json.write(answer.next_cursor);
    try json.objectField("pending_files");
    try json.write(answer.pending_files);
    try json.endObject();
}

fn writeRanges(json: *std.json.Stringify, ranges: []const Range) !void {
    try json.beginArray();
    for (ranges) |range| {
        try json.beginArray();
        try json.write(range[0]);
        try json.write(range[1]);
        try json.endArray();
    }
    try json.endArray();
}
