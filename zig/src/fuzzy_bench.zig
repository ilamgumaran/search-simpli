//! S5-T3 Phase 1 profile (plan ruling 9): the `fuzzy-v1` dictionary scan
//! alone, stage by stage, with the letter-count prefilter off and on, and an
//! estimate of what an expansion adds to a warm `content` and `both` query.
//! Opt-in diagnostic, not part of any library or the build graph:
//!
//!     zig run -lc -OReleaseSmall zig/src/fuzzy_bench.zig -- INDEX
//!
//! INDEX is a `searchd index --filename-index` over a
//! `scripts/gen_timing_corpus.py` corpus. The misspelt words are chosen
//! here, deterministically: the 7-code-point ASCII body terms starting with
//! `b`, in bytewise order; from the middle one on, the first two whose
//! code points 4 and 5 differ and whose swap is held by neither the body
//! dictionary nor the title field (one edit, a transposition, OSA 1).
//! Prints, as JSON lines:
//! - `words`: the chosen words and their misspellings;
//! - `scan`: for one and for two misspelt words, the operation counts (the
//!   first-letter range, after the length filter, the prefilter's checks and
//!   survivors, OSA runs and cells, within the bound, with in-scope df >= 1,
//!   the title field's range, kept) and the p50 of the scan cut after each
//!   stage (`range`, `length`, `prefilter`, `osa`, `df`, `cut`; each stage's
//!   cost is the difference to the one before), prefilter off and on, once
//!   unscoped and once under a synthetic scope (every other chunk hidden by
//!   a root mask: in-scope df then walks each candidate's postings, the
//!   dearer of `scope.documentFrequency`'s two paths), and the scan's
//!   transient peak bytes (nothing is kept between scans);
//! - `query`: today's warm `content` and `both` (`Engine.queryFields`, top
//!   10, candidate 100) for the words correctly spelt, misspelt, and with
//!   each misspelt word replaced by its kept members as plain terms (the
//!   members' postings walked and scored: the scoring part of an expansion,
//!   summed instead of the group's best member, so an upper estimate);
//! - `s4`: the four `scripts/qbench.py` queries: today's warm `content`, the
//!   trigger checks (each distinct analysed term looked up; an unmatched one
//!   stops at the length check below 5 code points) and how many scans run.
//! Every timing is the p50 of 200 timed runs after 5 warm-ups, three
//! repetitions, in microseconds. A second argument `--counts-only` skips
//! every timing (a Debug build then also checks each banded OSA against the
//! full table).
const std = @import("std");
const builtin = @import("builtin");
const analyzer_v2 = @import("analyzer_v2.zig");
const hybrid = @import("hybrid.zig");
const postings = @import("postings.zig");
const scope = @import("scope.zig");
const snapshot_open = @import("snapshot_open.zig");
const title_field = @import("title_field.zig");
const Capped = @import("nfr13_arena_test.zig").Capped;

const warmups = 5;
const timed = 200;
const repetitions = 3;
const max_expansions = 3;
const s4_queries = [_][]const u8{ "benico", "hybrid retrieval", "how does the hybrid retrieval work for a search", "the and of to in" };

const Stage = enum { range, length, prefilter, osa, df, cut };
const stages_off = [_]Stage{ .range, .length, .osa, .df, .cut };
const stages_on = [_]Stage{ .range, .length, .prefilter, .osa, .df, .cut };

fn now(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn micros(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1000.0;
}

const Counts = struct {
    range: u64 = 0,
    length_kept: u64 = 0,
    prefilter_checks: u64 = 0,
    prefilter_kept: u64 = 0,
    osa_runs: u64 = 0,
    osa_cells: u64 = 0,
    within: u64 = 0,
    df_kept: u64 = 0,
    title_range: u64 = 0,
    title_within: u64 = 0,
    kept: u64 = 0,

    fn add(a: *Counts, b: Counts) void {
        inline for (std.meta.fields(Counts)) |f| @field(a, f.name) += @field(b, f.name);
    }
};

const Candidate = struct { term: []const u8, distance: u8, df: u32 };

/// (distance ascending, key df descending, UTF-8 bytes ascending).
fn better(a: Candidate, b: Candidate) bool {
    if (a.distance != b.distance) return a.distance < b.distance;
    if (a.df != b.df) return a.df > b.df;
    return std.mem.order(u8, a.term, b.term) == .lt;
}

const Kept = struct {
    items: [max_expansions]Candidate = undefined,
    len: usize = 0,

    fn offer(kept: *Kept, c: Candidate) void {
        if (kept.len == max_expansions and !better(c, kept.items[max_expansions - 1])) return;
        var i = if (kept.len < max_expansions) kept.len else max_expansions - 1;
        if (kept.len < max_expansions) kept.len += 1;
        while (i > 0 and better(c, kept.items[i - 1])) : (i -= 1) kept.items[i] = kept.items[i - 1];
        kept.items[i] = c;
    }

    fn slice(kept: *const Kept) []const Candidate {
        return kept.items[0..kept.len];
    }
};

fn codePointCount(bytes: []const u8) usize {
    var n: usize = 0;
    for (bytes) |b| n += @intFromBool(b & 0xC0 != 0x80);
    return n;
}

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

const Histogram = @Vector(64, i8);

fn histogram(cps: []const u21) Histogram {
    var h: [64]i8 = @splat(0);
    for (cps) |c| h[c & 63] +%= 1;
    return h;
}

/// The letter-count (bag) distance over 64 buckets: a lower bound on OSA
/// (a transposition moves no count; any other edit moves at most one each
/// way; merging buckets only lowers it).
fn bagDistance(typed: Histogram, cps: []const u21) u32 {
    var h: [64]i8 = typed;
    for (cps) |c| h[c & 63] -%= 1;
    const v: Histogram = h;
    const zero: Histogram = @splat(0);
    const pos: @Vector(64, i16) = @max(v, zero);
    const neg: @Vector(64, i16) = @max(-%v, zero);
    return @intCast(@max(@reduce(.Add, pos), @reduce(.Add, neg)));
}

/// Banded optimal string alignment on code points, values clamped to k + 1,
/// stopping when a row's minimum exceeds k (the diagonal never decreases).
fn osa(a: []const u21, b: []const u21, k: u8, rows: []u8, cells: *u64) u8 {
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
        cells.* += hi + 1 - lo;
        if (hi < m) cur[hi + 1] = big;
        if (row_min > k) return big;
        const t = prev2;
        prev2 = prev;
        prev = cur;
        cur = t;
    }
    return @min(prev[m], big);
}

/// The full OSA table (the Debug check of `osa`).
fn fullOsa(allocator: std.mem.Allocator, a: []const u21, b: []const u21) !usize {
    const w = b.len + 1;
    const d = try allocator.alloc(usize, (a.len + 1) * w);
    defer allocator.free(d);
    for (0..a.len + 1) |i| d[i * w] = i;
    for (0..w) |j| d[j] = j;
    for (1..a.len + 1) |i| for (1..w) |j| {
        const cost: usize = @intFromBool(a[i - 1] != b[j - 1]);
        var v = @min(@min(d[(i - 1) * w + j] + 1, d[i * w + j - 1] + 1), d[(i - 1) * w + j - 1] + cost);
        if (i > 1 and j > 1 and a[i - 1] == b[j - 2] and a[i - 2] == b[j - 1]) v = @min(v, d[(i - 2) * w + j - 2] + 1);
        d[i * w + j] = v;
    };
    return d[a.len * w + b.len];
}

const Scope = struct {
    index: postings.Index,
    documents: []const hybrid.Document,
    field: ?*const title_field.Field,
    view: ?scope.View,
};

fn visibleTitle(s: Scope, term: title_field.Term) bool {
    const view = s.view orelse return true;
    const field = s.field.?;
    for (field.termPostings(term)) |p| {
        const chunk = field.files[p.file].first_chunk;
        if (view.mask) |m| if (!m.allows(chunk)) continue;
        if (hybrid.isAuthorized(s.documents[chunk].required_labels, view.labels)) return true;
    }
    return false;
}

fn nextCodePointBytes(typed: []const u8, buf: *[4]u8) []const u8 {
    const len = std.unicode.utf8ByteSequenceLength(typed[0]) catch unreachable;
    const first = std.unicode.utf8Decode(typed[0..len]) catch unreachable;
    const n = std.unicode.utf8Encode(first + 1, buf) catch unreachable;
    return buf[0..n];
}

/// One triggering term's scan, cut after `upto`. Allocates only from
/// `allocator` and keeps nothing.
fn scan(comptime upto: Stage, comptime prefilter: bool, allocator: std.mem.Allocator, s: Scope, typed: []const u8, counts: *Counts) !Kept {
    var kept = Kept{};
    const n = codePointCount(typed);
    const k: u8 = if (n >= 6) 2 else 1;
    const typed_cps = try allocator.alloc(u21, n);
    defer allocator.free(typed_cps);
    _ = decode(typed, typed_cps);
    const typed_hist = histogram(typed_cps);
    const cand = try allocator.alloc(u21, n + k);
    defer allocator.free(cand);
    const rows = try allocator.alloc(u8, 3 * (n + k + 1));
    defer allocator.free(rows);
    const first_len = std.unicode.utf8ByteSequenceLength(typed[0]) catch unreachable;
    var next_buf: [4]u8 = undefined;
    const next = nextCodePointBytes(typed, &next_buf);

    const terms = s.index.terms;
    const lo = postings.lowerBound(terms, typed[0..first_len]);
    const hi = postings.lowerBound(terms, next);
    for (terms[lo..hi]) |entry| {
        counts.range += 1;
        if (upto == .range) {
            std.mem.doNotOptimizeAway(entry.term.len);
            continue;
        }
        const m = codePointCount(entry.term);
        if ((if (m > n) m - n else n - m) > k) continue;
        counts.length_kept += 1;
        if (upto == .length) continue;
        const cps = cand[0..decode(entry.term, cand)];
        if (prefilter) {
            counts.prefilter_checks += 1;
            if (bagDistance(typed_hist, cps) > k) continue;
            counts.prefilter_kept += 1;
        }
        if (upto == .prefilter) continue;
        counts.osa_runs += 1;
        const d = osa(typed_cps, cps, k, rows, &counts.osa_cells);
        if (builtin.mode == .Debug) {
            const full = try fullOsa(allocator, typed_cps, cps);
            if (@min(full, k + 1) != d) return error.BandedOsaDisagrees;
        }
        if (d == 0 or d > k) continue;
        counts.within += 1;
        if (upto == .osa) continue;
        const df = if (s.view) |view| scope.documentFrequency(view, s.index, s.documents, entry) else entry.document_frequency;
        if (df == 0) continue;
        counts.df_kept += 1;
        if (upto == .df) continue;
        kept.offer(.{ .term = entry.term, .distance = d, .df = df });
    }
    if (upto != .cut) return kept;
    // The title field's terms: a title-only one (no in-scope body df) at key df 1.
    if (s.field) |field| {
        const tlo = titleLowerBound(field.*, typed[0..first_len]);
        const thi = titleLowerBound(field.*, next);
        for (field.terms[tlo..thi]) |term| {
            counts.title_range += 1;
            const bytes = field.termBytes(term);
            const m = codePointCount(bytes);
            if ((if (m > n) m - n else n - m) > k) continue;
            const cps = cand[0..decode(bytes, cand)];
            if (prefilter and bagDistance(typed_hist, cps) > k) continue;
            const d = osa(typed_cps, cps, k, rows, &counts.osa_cells);
            if (d == 0 or d > k) continue;
            if (postings.lookupExact(s.index, bytes)) |i| {
                const entry = s.index.terms[i];
                const df = if (s.view) |view| scope.documentFrequency(view, s.index, s.documents, entry) else entry.document_frequency;
                if (df != 0) continue; // already a body candidate
            }
            if (!visibleTitle(s, term)) continue;
            counts.title_within += 1;
            kept.offer(.{ .term = bytes, .distance = d, .df = 1 });
        }
    }
    counts.kept += kept.len;
    return kept;
}

fn titleLowerBound(field: title_field.Field, bytes: []const u8) usize {
    var low: usize = 0;
    var high: usize = field.terms.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (std.mem.order(u8, field.termBytes(field.terms[middle]), bytes) == .lt) low = middle + 1 else high = middle;
    }
    return low;
}

fn scanAll(comptime upto: Stage, comptime prefilter: bool, allocator: std.mem.Allocator, s: Scope, words: []const []const u8, counts: *Counts, out: ?[]Kept) !void {
    for (words, 0..) |w, i| {
        const kept = try scan(upto, prefilter, allocator, s, w, counts);
        std.mem.doNotOptimizeAway(kept.len);
        if (out) |o| o[i] = kept;
    }
}

fn swapped(allocator: std.mem.Allocator, word: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, word);
    std.mem.swap(u8, &out[3], &out[4]);
    return out;
}

fn titleHolds(field: title_field.Field, bytes: []const u8) bool {
    return field.lookup(bytes) != null;
}

fn chooseWords(allocator: std.mem.Allocator, index: postings.Index, field: title_field.Field) ![2][]const u8 {
    var pool = std.ArrayList([]const u8).empty;
    defer pool.deinit(allocator);
    for (index.terms) |entry| {
        const t = entry.term;
        if (t.len != 7 or t[0] != 'b') continue;
        var ascii = true;
        for (t) |c| ascii = ascii and c < 0x80;
        if (ascii) try pool.append(allocator, t);
    }
    var chosen: [2][]const u8 = undefined;
    var found: usize = 0;
    for (pool.items[pool.items.len / 2 ..]) |t| {
        if (t[3] == t[4]) continue;
        const typo = try swapped(allocator, t);
        defer allocator.free(typo);
        if (postings.lookupExact(index, typo) != null or titleHolds(field, typo)) continue;
        chosen[found] = t;
        found += 1;
        if (found == 2) return chosen;
    }
    return error.NoWords;
}

const Samples = struct {
    buf: []u64,

    fn print(samples: Samples, comptime label: []const u8, io: std.Io, arena: *std.heap.ArenaAllocator, context: anytype, comptime run: anytype) !void {
        std.debug.print(",\"" ++ label ++ "\":[", .{});
        for (0..repetitions) |rep| {
            for (0..warmups + timed) |q| {
                _ = arena.reset(.retain_capacity);
                const start = now(io);
                try run(arena.allocator(), context);
                const elapsed: u64 = @intCast(now(io) - start);
                if (q >= warmups) samples.buf[q - warmups] = elapsed;
            }
            std.mem.sort(u64, samples.buf, {}, std.sort.asc(u64));
            std.debug.print("{s}{d:.2}", .{ if (rep == 0) "" else ",", micros(samples.buf[timed / 2 - 1]) });
        }
        std.debug.print("]", .{});
    }
};

fn ScanRun(comptime upto: Stage, comptime prefilter: bool) type {
    return struct {
        fn run(allocator: std.mem.Allocator, ctx: anytype) !void {
            var counts = Counts{};
            try scanAll(upto, prefilter, allocator, ctx.s, ctx.words, &counts, null);
            std.mem.doNotOptimizeAway(counts.range);
        }
    };
}

fn QueryRun(comptime field: anytype) type {
    return struct {
        fn run(allocator: std.mem.Allocator, ctx: anytype) !void {
            const hits = try ctx.engine.queryFields(allocator, ctx.query, field, .{ .retrieval_mode = .lexical, .top_k = 10, .candidate_k = 100 });
            std.mem.doNotOptimizeAway(hits.len);
        }
    };
}

/// What Phase 2 adds to a query no term of which triggers: each distinct
/// analysed term looked up, an unmatched one checked for length (then the
/// Latin table and the title guard), and a scan only past all three.
fn triggerChecks(allocator: std.mem.Allocator, s: Scope, query: []const u8, scans: *usize, unmatched: *usize) !void {
    const tokens = try analyzer_v2.tokenize(allocator, query);
    for (tokens, 0..) |token, position| {
        var seen = false;
        for (tokens[0..position]) |earlier| seen = seen or std.mem.eql(u8, earlier, token);
        if (seen) continue;
        if (postings.lookupExact(s.index, token) != null) continue;
        unmatched.* += 1;
        if (codePointCount(token) < 5) continue;
        if (s.field) |f| if (f.lookup(token) != null) continue;
        scans.* += 1;
        var counts = Counts{};
        _ = try scan(.cut, true, allocator, s, token, &counts);
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args = init.minimal.args.iterate();
    _ = args.next();
    const path = args.next() orelse return error.MissingIndex;
    const counts_only = if (args.next()) |a| std.mem.eql(u8, a, "--counts-only") else false;

    var open_arena = std.heap.ArenaAllocator.init(gpa);
    defer open_arena.deinit();
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
    defer dir.close(io);
    const opened = try snapshot_open.openScoped(open_arena.allocator(), io, dir);
    defer opened.folder.close();
    const engine = opened.engine;
    const index = engine.lexical_index;
    const field = try opened.folder.titleField();

    var request = std.heap.ArenaAllocator.init(gpa);
    defer request.deinit();
    const samples = Samples{ .buf = try gpa.alloc(u64, timed) };
    defer gpa.free(samples.buf);

    const words = try chooseWords(gpa, index, field.*);
    var typos: [2][]const u8 = undefined;
    for (words, &typos) |w, *t| t.* = try swapped(gpa, w);
    defer for (typos) |t| gpa.free(t);
    std.debug.print("{{\"words\":{{\"documents\":{d},\"terms\":{d},\"title_terms\":{d},\"correct\":[\"{s}\",\"{s}\"],\"misspelt\":[\"{s}\",\"{s}\"],\"df\":[{d},{d}]}}}}\n", .{ engine.documents.len, index.terms.len, field.terms.len, words[0], words[1], typos[0], typos[1], index.terms[postings.lookupExact(index, words[0]).?].document_frequency, index.terms[postings.lookupExact(index, words[1]).?].document_frequency });

    // A synthetic scope: every other chunk under a hidden root.
    const document_roots = try gpa.alloc(u16, engine.documents.len);
    defer gpa.free(document_roots);
    for (document_roots, 0..) |*r, i| r.* = @intCast(i % 2);
    const allowed = [_]bool{ true, false };
    const mask = hybrid.RootMask{ .document_roots = document_roots, .allowed = &allowed };
    var masked_view = (try scope.visibleCollection(gpa, index, engine.documents, null, null, mask, &.{})).?;
    defer masked_view.deinit(gpa);

    const unscoped = Scope{ .index = index, .documents = engine.documents, .field = field, .view = null };
    const masked = Scope{ .index = index, .documents = engine.documents, .field = field, .view = masked_view };

    const sets = [_]struct { name: []const u8, words: []const []const u8 }{
        .{ .name = "one", .words = typos[0..1] },
        .{ .name = "two", .words = typos[0..2] },
    };
    for (sets) |set| {
        inline for (.{ .{ "unscoped", 0 }, .{ "scoped", 1 } }) |sc| {
            const s = if (sc[1] == 0) unscoped else masked;
            const ctx = .{ .s = s, .words = set.words };
            // Counts and results, prefilter off and on (they must agree).
            var off_counts = Counts{};
            var on_counts = Counts{};
            var off_kept: [2]Kept = undefined;
            var on_kept: [2]Kept = undefined;
            try scanAll(.cut, false, gpa, s, set.words, &off_counts, off_kept[0..set.words.len]);
            try scanAll(.cut, true, gpa, s, set.words, &on_counts, on_kept[0..set.words.len]);
            for (off_kept[0..set.words.len], on_kept[0..set.words.len]) |a, b| {
                if (a.len != b.len) return error.PrefilterChangedResult;
                for (a.slice(), b.slice()) |x, y| if (!std.mem.eql(u8, x.term, y.term) or x.distance != y.distance or x.df != y.df) return error.PrefilterChangedResult;
            }
            var peak = Capped{ .parent = gpa, .cap = std.math.maxInt(usize) };
            var peak_counts = Counts{};
            try scanAll(.cut, true, peak.allocator(), s, set.words, &peak_counts, null);
            std.debug.print("{{\"scan\":\"{s}\",\"scope\":\"{s}\",\"transient_peak_bytes\":{d},\"live_after\":{d},\"kept\":[", .{ set.name, sc[0], peak.peak, peak.live });
            for (on_kept[0..set.words.len], 0..) |kept, i| {
                std.debug.print("{s}[", .{if (i == 0) "" else ","});
                for (kept.slice(), 0..) |c, j| std.debug.print("{s}[\"{s}\",{d},{d}]", .{ if (j == 0) "" else ",", c.term, c.distance, c.df });
                std.debug.print("]", .{});
            }
            std.debug.print("]", .{});
            inline for (.{ .{ "off", false }, .{ "on", true } }) |pf| {
                const c = if (pf[1]) on_counts else off_counts;
                std.debug.print(",\"counts_{s}\":{{", .{pf[0]});
                inline for (std.meta.fields(Counts), 0..) |f, i| std.debug.print("{s}\"{s}\":{d}", .{ if (i == 0) "" else ",", f.name, @field(c, f.name) });
                std.debug.print("}}", .{});
            }
            if (!counts_only) inline for (stages_off) |st| try samples.print("off_" ++ @tagName(st) ++ "_us", io, &request, ctx, ScanRun(st, false).run);
            if (!counts_only) inline for (stages_on) |st| try samples.print("on_" ++ @tagName(st) ++ "_us", io, &request, ctx, ScanRun(st, true).run);
            std.debug.print("}}\n", .{});
        }
    }

    // The scoring estimate: today's warm queries.
    if (!counts_only) for (sets) |set| {
        var correct = std.ArrayList(u8).empty;
        var misspelt = std.ArrayList(u8).empty;
        var members = std.ArrayList(u8).empty;
        defer correct.deinit(gpa);
        defer misspelt.deinit(gpa);
        defer members.deinit(gpa);
        for (set.words, 0..) |typo, i| {
            const sep = if (i == 0) "" else " ";
            try correct.print(gpa, "{s}{s}", .{ sep, words[i] });
            try misspelt.print(gpa, "{s}{s}", .{ sep, typo });
            var counts = Counts{};
            const kept = try scan(.cut, true, gpa, unscoped, typo, &counts);
            for (kept.slice(), 0..) |c, j| try members.print(gpa, "{s}{s}", .{ if (i == 0 and j == 0) "" else " ", c.term });
        }
        std.debug.print("{{\"query\":\"{s}\",\"correct\":\"{s}\",\"misspelt\":\"{s}\",\"members\":\"{s}\"", .{ set.name, correct.items, misspelt.items, members.items });
        inline for (.{ .{ "content", .content }, .{ "both", .both } }) |fd| {
            inline for (.{ "correct", "misspelt", "members" }) |which| {
                const q = if (comptime std.mem.eql(u8, which, "correct")) correct.items else if (comptime std.mem.eql(u8, which, "misspelt")) misspelt.items else members.items;
                try samples.print(fd[0] ++ "_" ++ which ++ "_us", io, &request, .{ .engine = engine, .query = q }, QueryRun(fd[1]).run);
            }
        }
        std.debug.print("}}\n", .{});
    };

    // The S4 query set: no scan.
    for (s4_queries) |query| {
        var scans: usize = 0;
        var unmatched: usize = 0;
        try triggerChecks(request.allocator(), unscoped, query, &scans, &unmatched);
        _ = request.reset(.retain_capacity);
        std.debug.print("{{\"s4\":\"{s}\",\"unmatched_terms\":{d},\"scans\":{d}", .{ query, unmatched, scans });
        if (counts_only) {
            std.debug.print("}}\n", .{});
            continue;
        }
        try samples.print("content_today_us", io, &request, .{ .engine = engine, .query = query }, QueryRun(.content).run);
        try samples.print("trigger_checks_us", io, &request, .{ .s = unscoped, .query = query }, struct {
            fn run(allocator: std.mem.Allocator, ctx: anytype) !void {
                var a: usize = 0;
                var b: usize = 0;
                try triggerChecks(allocator, ctx.s, ctx.query, &a, &b);
                std.mem.doNotOptimizeAway(a);
            }
        }.run);
        std.debug.print("}}\n", .{});
    }
}
