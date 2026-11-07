//! S5-T3: `fuzzy-v1`, misspelling tolerance at query time
//! (`docs/fuzzy-v1.md`, `docs/tasks/S5-T3.md` ruling 2). A query term that
//! no chunk in scope holds and no visible file's title field holds, all
//! Latin and at least `min_code_points` long, is also searched as its
//! nearest dictionary words: the body terms held in scope and the visible
//! title terms that share its first code point, within an optimal string
//! alignment distance of 1 (5 code points) or 2 (6 or more), counted on
//! code points; ordered by (distance, key df descending, UTF-8 bytes) and
//! cut to `max_expansions`. Each kept word weighs `weightOf(distance)`.
//!
//! The scan reads the sorted body dictionary (HYBLEX02, bytewise) and the
//! title field's sorted term table in place: the terms sharing the first
//! code point are one contiguous range of each. A letter-count lower bound
//! (`bagDistance`) skips most of the range before any alignment; it never
//! changes a result. Nothing is kept between queries: `compute` allocates
//! the groups from the caller's allocator (`Groups.deinit`) and its scratch
//! is freed before it returns.
//!
//! Scope (orchestrator, Phase 1 deviation 8): roots and labels narrow the
//! key df (`scope.documentFrequency`); a path prefix does not, but a
//! candidate must be held under it (by a chunk, or by a visible file's
//! title) to be kept, as the trigger itself is prefix-narrowed.
const std = @import("std");
const hybrid = @import("hybrid.zig");
const postings = @import("postings.zig");
const scope = @import("scope.zig");
const title_field = @import("title_field.zig");

pub const policy_id = "fuzzy-v1";
pub const min_code_points = 5;
pub const distance_2_min_code_points = 6;
pub const max_expansions = 3;

/// 1.0 at distance 1, 0.5 at distance 2.
pub fn weightOf(distance: u8) f32 {
    return if (distance == 1) 1.0 else 0.5;
}

/// The bound for a term of `code_points`: 0 (no expansion), 1 or 2.
pub fn maxDistance(code_points: usize) u8 {
    if (code_points >= distance_2_min_code_points) return 2;
    return if (code_points >= min_code_points) 1 else 0;
}

/// A digit 0-9 or a Latin letter, by code point range (ruling 2's table).
pub fn latinCodePoint(c: u21) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'z') or
        (c >= 0xDF and c <= 0xFF and c != 0xF7) or
        (c >= 0x100 and c <= 0x24F) or (c >= 0x1E00 and c <= 0x1EFF);
}

pub fn codePointCount(bytes: []const u8) usize {
    var n: usize = 0;
    for (bytes) |b| n += @intFromBool(b & 0xC0 != 0x80);
    return n;
}

/// Decode valid UTF-8 `bytes` into `out` (at least `codePointCount` long).
fn decode(bytes: []const u8, out: []u21) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < bytes.len) : (n += 1) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch unreachable;
        out[n] = std.unicode.utf8Decode(bytes[i .. i + len]) catch unreachable;
        i += len;
    }
    return n;
}

pub fn latin(term: []const u8) bool {
    const view = std.unicode.Utf8View.init(term) catch return false;
    var it = view.iterator();
    while (it.nextCodepoint()) |c| if (!latinCodePoint(c)) return false;
    return true;
}

const Histogram = @Vector(64, i8);

fn histogram(cps: []const u21) Histogram {
    var h: [64]i8 = @splat(0);
    for (cps) |c| h[c & 63] +%= 1;
    return h;
}

/// The letter-count (bag) distance over 64 buckets: a lower bound on OSA (a
/// transposition moves no count, any other edit moves at most one each way,
/// and merging buckets only lowers it). Terms are short (the length filter
/// keeps them within 2 of the query term), so the i8 counts cannot wrap for
/// any term this is asked about.
fn bagDistance(typed: Histogram, cps: []const u21) u32 {
    var h: [64]i8 = typed;
    for (cps) |c| h[c & 63] -%= 1;
    const v: Histogram = h;
    const zero: Histogram = @splat(0);
    const pos: @Vector(64, i16) = @max(v, zero);
    const neg: @Vector(64, i16) = @max(-%v, zero);
    return @intCast(@max(@reduce(.Add, pos), @reduce(.Add, neg)));
}

/// Banded optimal string alignment of two code-point strings, values clamped
/// to `k + 1`; stops when a row's minimum exceeds `k` (the diagonal never
/// decreases, so the stop is exact). `rows` holds `3 * (b.len + 1)`.
pub fn osa(a: []const u21, b: []const u21, k: u8, rows: []u8) u8 {
    const big: u8 = k + 1;
    const n = a.len;
    const m = b.len;
    if ((if (n > m) n - m else m - n) > k) return big;
    const width = m + 1;
    var prev2 = rows[0..width];
    var prev = rows[width .. 2 * width];
    var cur = rows[2 * width .. 3 * width];
    @memset(prev2, big);
    @memset(cur, big);
    for (prev, 0..) |*v, j| v.* = if (j <= k) @intCast(j) else big;
    for (1..n + 1) |i| {
        const lo = if (i > k) i - k else 1;
        const hi = @min(m, i + k);
        cur[lo - 1] = if (lo == 1) (if (i <= k) @intCast(i) else big) else big;
        var row_min: u8 = cur[lo - 1];
        var j = lo;
        while (j <= hi) : (j += 1) {
            const cost: u8 = @intFromBool(a[i - 1] != b[j - 1]);
            var v = @min(@min(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + cost);
            if (i > 1 and j > 1 and a[i - 1] == b[j - 2] and a[i - 2] == b[j - 1]) v = @min(v, prev2[j - 2] + 1);
            v = @min(v, big);
            cur[j] = v;
            row_min = @min(row_min, v);
        }
        if (hi < m) cur[hi + 1] = big;
        if (row_min > k) return big;
        const t = prev2;
        prev2 = prev;
        prev = cur;
        cur = t;
    }
    return @min(prev[m], big);
}

/// OSA distance of two UTF-8 strings when at most `k`, else null (tests).
pub fn distanceWithin(allocator: std.mem.Allocator, a: []const u8, b: []const u8, k: u8) !?u8 {
    const ca = try allocator.alloc(u21, codePointCount(a));
    defer allocator.free(ca);
    const cb = try allocator.alloc(u21, codePointCount(b));
    defer allocator.free(cb);
    _ = decode(a, ca);
    _ = decode(b, cb);
    const rows = try allocator.alloc(u8, 3 * (cb.len + 1));
    defer allocator.free(rows);
    const d = osa(ca, cb, k, rows);
    return if (d > k) null else d;
}

/// One kept expansion of a typed term.
pub const Member = struct {
    /// Borrowed from the body dictionary or the title field (they outlive
    /// the query).
    term: []const u8,
    distance: u8,
    weight: f32,
    /// The order's key: the in-scope body df, or 1 for a title-only member.
    key_df: u32,
    /// The body dictionary's entry when a chunk under the request's scope
    /// and prefix holds the member; null for a title-only member (it adds 0
    /// to the group's body df and has no body postings).
    body: ?postings.TermEntry,
};

/// The group of a triggering term: its kept members, best first.
pub const Group = struct {
    typed: []const u8,
    members: []const Member,

    /// The group's one body document frequency: the largest in-scope body
    /// df among the members (0 when every member is title-only).
    pub fn bodyFrequency(group: Group) u32 {
        var df: u32 = 0;
        for (group.members) |m| if (m.body != null) {
            df = @max(df, m.key_df);
        };
        return df;
    }
};

pub const Groups = struct {
    items: []const Group,

    pub fn of(groups: Groups, term: []const u8) ?Group {
        for (groups.items) |g| if (std.mem.eql(u8, g.typed, term)) return g;
        return null;
    }

    pub fn deinit(groups: Groups, allocator: std.mem.Allocator) void {
        for (groups.items) |g| {
            allocator.free(g.typed);
            allocator.free(g.members);
        }
        allocator.free(groups.items);
    }
};

/// What a query's scan reads: the body dictionary and chunks, the title
/// field (null: none), the roots-and-labels view for the key df (null: the
/// whole index is visible) and the request (roots, labels, prefix).
pub const Context = struct {
    index: postings.Index,
    documents: []const hybrid.Document,
    title: ?*const title_field.Field = null,
    view: ?scope.View = null,
    options: hybrid.SearchOptions,

    fn heldInScope(context: Context, entry: postings.TermEntry) bool {
        const list = context.index.postings[entry.postings_start .. entry.postings_start + entry.postings_length];
        for (list) |p| if (hybrid.inScope(context.documents[p.document_index], p.document_index, context.options)) return true;
        return false;
    }

    fn keyFrequency(context: Context, entry: postings.TermEntry) u32 {
        return if (context.view) |view| scope.documentFrequency(view, context.index, context.documents, entry) else entry.document_frequency;
    }

    /// A visible file's title holds `term` (roots and labels; `under_prefix`
    /// also asks for the file to lie under the request's prefix).
    fn titleHeld(context: Context, field: *const title_field.Field, term: title_field.Term, under_prefix: bool) bool {
        for (field.termPostings(term)) |p| {
            const chunk = field.files[p.file].first_chunk;
            if (context.options.visible_roots) |mask| if (!mask.allows(chunk)) continue;
            const document = context.documents[chunk];
            if (!hybrid.isAuthorized(document.required_labels, context.options.principal_labels)) continue;
            if (under_prefix and !hybrid.matchesPath(document.path, context.options.path_prefix)) continue;
            return true;
        }
        return false;
    }

    /// Ruling 2's trigger, cheapest check first: the length, the script, no
    /// chunk in scope holding it, no visible title holding it.
    pub fn triggers(context: Context, term: []const u8) bool {
        if (maxDistance(codePointCount(term)) == 0) return false;
        if (!latin(term)) return false;
        if (postings.lookupExact(context.index, term)) |i| {
            if (context.heldInScope(context.index.terms[i])) return false;
        }
        if (context.title) |field| if (field.lookup(term)) |t| {
            if (context.titleHeld(field, t, false)) return false;
        };
        return true;
    }
};

const Kept = struct {
    items: [max_expansions]Member = undefined,
    len: usize = 0,

    fn better(a: Member, b: Member) bool {
        if (a.distance != b.distance) return a.distance < b.distance;
        if (a.key_df != b.key_df) return a.key_df > b.key_df;
        return std.mem.order(u8, a.term, b.term) == .lt;
    }

    fn offer(kept: *Kept, c: Member) void {
        if (kept.len == max_expansions and !better(c, kept.items[max_expansions - 1])) return;
        var i = if (kept.len < max_expansions) kept.len else max_expansions - 1;
        if (kept.len < max_expansions) kept.len += 1;
        while (i > 0 and better(c, kept.items[i - 1])) : (i -= 1) kept.items[i] = kept.items[i - 1];
        kept.items[i] = c;
    }
};

fn titleLowerBound(field: *const title_field.Field, bytes: []const u8) usize {
    var low: usize = 0;
    var high: usize = field.terms.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (std.mem.order(u8, field.termBytes(field.terms[middle]), bytes) == .lt) low = middle + 1 else high = middle;
    }
    return low;
}

/// The kept candidates of one triggering term (ruling 2), best first.
pub fn scan(allocator: std.mem.Allocator, context: Context, typed: []const u8) ![]Member {
    var kept = Kept{};
    const n = codePointCount(typed);
    const k = maxDistance(n);
    if (k == 0) return allocator.alloc(Member, 0);
    var scratch_state = std.heap.ArenaAllocator.init(allocator);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    const typed_cps = try scratch.alloc(u21, n);
    _ = decode(typed, typed_cps);
    const typed_hist = histogram(typed_cps);
    const cand = try scratch.alloc(u21, n + k);
    const rows = try scratch.alloc(u8, 3 * (n + k + 1));
    const first_len = std.unicode.utf8ByteSequenceLength(typed[0]) catch unreachable;
    var next_buf: [4]u8 = undefined;
    const next_len = std.unicode.utf8Encode(typed_cps[0] + 1, &next_buf) catch unreachable;
    const first = typed[0..first_len];
    const next = next_buf[0..next_len];

    const terms = context.index.terms;
    // HYBLEX02 sorts the dictionary bytewise, so the terms sharing the first
    // code point are one range; an older, first-seen dictionary is read
    // whole, with the first code point compared.
    const sorted = context.index.sorted_terms;
    const lo = if (sorted) postings.lowerBound(terms, first) else 0;
    const hi = if (sorted) postings.lowerBound(terms, next) else terms.len;
    for (terms[lo..hi]) |entry| {
        if (!sorted and !std.mem.startsWith(u8, entry.term, first)) continue;
        const m = codePointCount(entry.term);
        if ((if (m > n) m - n else n - m) > k) continue;
        const cps = cand[0..decode(entry.term, cand)];
        if (bagDistance(typed_hist, cps) > k) continue;
        const d = osa(typed_cps, cps, k, rows);
        if (d == 0 or d > k) continue;
        if (!context.heldInScope(entry)) continue;
        kept.offer(.{ .term = entry.term, .distance = d, .weight = weightOf(d), .key_df = context.keyFrequency(entry), .body = entry });
    }
    if (context.title) |field| {
        const tlo = titleLowerBound(field, first);
        const thi = titleLowerBound(field, next);
        for (field.terms[tlo..thi]) |term| {
            const bytes = field.termBytes(term);
            const m = codePointCount(bytes);
            if ((if (m > n) m - n else n - m) > k) continue;
            const cps = cand[0..decode(bytes, cand)];
            if (bagDistance(typed_hist, cps) > k) continue;
            const d = osa(typed_cps, cps, k, rows);
            if (d == 0 or d > k) continue;
            // Held under the scope by a chunk: already a body candidate.
            if (postings.lookupExact(context.index, bytes)) |i| if (context.heldInScope(terms[i])) continue;
            if (!context.titleHeld(field, term, true)) continue;
            kept.offer(.{ .term = bytes, .distance = d, .weight = weightOf(d), .key_df = 1, .body = null });
        }
    }
    return allocator.dupe(Member, kept.items[0..kept.len]);
}

/// The query's groups, one scan per distinct triggering term in query
/// order, or null when no term triggers or none has a candidate (the query
/// then ranks exactly as before S5-T3). Nothing is allocated for a query
/// with no triggering term.
pub fn compute(allocator: std.mem.Allocator, context: Context, tokens: []const []const u8) !?Groups {
    var items = std.ArrayList(Group).empty;
    errdefer {
        for (items.items) |g| {
            allocator.free(g.typed);
            allocator.free(g.members);
        }
        items.deinit(allocator);
    }
    for (tokens, 0..) |token, position| {
        var repeated = false;
        for (tokens[0..position]) |earlier| if (std.mem.eql(u8, earlier, token)) {
            repeated = true;
            break;
        };
        if (repeated or !context.triggers(token)) continue;
        const members = try scan(allocator, context, token);
        if (members.len == 0) {
            allocator.free(members);
            continue;
        }
        errdefer allocator.free(members);
        const typed = try allocator.dupe(u8, token);
        errdefer allocator.free(typed);
        try items.append(allocator, .{ .typed = typed, .members = members });
    }
    if (items.items.len == 0) {
        items.deinit(allocator);
        return null;
    }
    return .{ .items = try items.toOwnedSlice(allocator) };
}

/// The resolved query terms with each group's body members appended, for
/// `postings.SparseScorer`: `frequencies` holds each plain term's df (the
/// scope's when `base` is given, else the dictionary's) and each member's
/// group df; `grouping` says which terms form a group, and with what
/// weight.
pub const ScorerTerms = struct {
    terms: []postings.TermEntry,
    frequencies: []u32,
    group_of: []u32,
    weights: []f32,

    pub fn deinit(s: ScorerTerms, allocator: std.mem.Allocator) void {
        allocator.free(s.terms);
        allocator.free(s.frequencies);
        allocator.free(s.group_of);
        allocator.free(s.weights);
    }

    pub fn grouping(s: ScorerTerms) postings.Grouping {
        return .{ .group_of = s.group_of, .weights = s.weights };
    }
};

pub fn scorerTerms(allocator: std.mem.Allocator, resolved: []const postings.TermEntry, base: ?[]const u32, groups: Groups) !ScorerTerms {
    var count = resolved.len;
    for (groups.items) |g| for (g.members) |m| {
        if (m.body != null) count += 1;
    };
    const terms = try allocator.alloc(postings.TermEntry, count);
    errdefer allocator.free(terms);
    const frequencies = try allocator.alloc(u32, count);
    errdefer allocator.free(frequencies);
    const group_of = try allocator.alloc(u32, count);
    errdefer allocator.free(group_of);
    const weights = try allocator.alloc(f32, count);
    for (resolved, 0..) |entry, i| {
        terms[i] = entry;
        frequencies[i] = if (base) |b| b[i] else entry.document_frequency;
        group_of[i] = postings.Grouping.plain;
        weights[i] = 1;
    }
    var at = resolved.len;
    for (groups.items, 0..) |g, gi| {
        const df = g.bodyFrequency();
        for (g.members) |m| if (m.body) |entry| {
            terms[at] = entry;
            frequencies[at] = df;
            group_of[at] = @intCast(gi);
            weights[at] = m.weight;
            at += 1;
        };
    }
    return .{ .terms = terms, .frequencies = frequencies, .group_of = group_of, .weights = weights };
}
