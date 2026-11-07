//! S5-T4 Phase 2 profile (the plan's ruling 13, query-side column; the
//! orchestrator's ruling 9 on Phase 1): K (`fold.zig`) per token, the fold
//! table lookup alone, the key map derive, and an estimate of what a group
//! adds to a warm `content` and `both` query. Opt-in diagnostic, not part of
//! any library or the build graph:
//!
//!     zig run -lc -OReleaseSmall zig/src/fold_bench.zig -- INDEX
//!
//! INDEX is a `searchd index --filename-index` over a
//! `scripts/gen_timing_corpus.py` corpus. Prints, as JSON lines:
//! - `index`: chunks, body terms, title terms;
//! - `k`: K per token, in ns per call (a run is 1,000 calls), on the five
//!   token kinds of ruling 13: an ASCII lowercase word, an ASCII plural, a
//!   fullwidth word, a Tamil word, and a word whose first letter has a
//!   4-code-point canonical decomposition (U+1F84), with K's output;
//! - `lookup`: `fold.foldOutput` alone, in ns per call, over every table
//!   code point (hits) and over as many misses (U+0B80-U+0BFF cycled: Tamil,
//!   a full-depth search);
//! - `derive`: the key map over the body terms and the title-only terms (the
//!   list built inside the timing), its entries, the keys shared by two or more
//!   indexed terms, kept bytes, and the derive's transient peak;
//! - `group`: per query word of the bench's list (below), the group (the
//!   indexed terms whose key is K(t), t first when indexed), K(t) plus the
//!   map lookup in ns, and today's warm `Engine.queryFields` (top 10,
//!   candidate 100, lexical) for t alone and for the group's indexed terms as
//!   plain terms (each member walked and scored, summed instead of the
//!   group's best member: an upper estimate of the group scoring);
//! - `s4`: the four `scripts/qbench.py` queries: today's warm `content` and
//!   the group checks a query adds (each distinct analysed term's key and the
//!   map lookup), with how many groups form.
//!
//! The query words (the timing corpus is pseudo-words of open syllables, so
//! almost nothing in it shares a key; at 10k one key, `system`, is shared):
//! - every indexed term of a key shared by two or more indexed terms (natural
//!   groups of two or three);
//! - each such key with its first `e` written `é` (K folds it back; t is not
//!   indexed, so the group is t and the indexed terms: three or four);
//! - from the 7-code-point ASCII body terms starting with `b`, bytewise, from
//!   the middle one on, the first two w for which w + `s` is held by neither
//!   the body nor the title field and K(w + `s`) is w: t = w + `s` (a group
//!   of two: t, not indexed, and w).
//! Timings are the p50 of 200 timed runs after 5 warm-ups, three repetitions,
//! in microseconds unless named ns.
const std = @import("std");
const analyzer_v2 = @import("analyzer_v2.zig");
const fold = @import("fold.zig");
const tables = @import("unicode_tables.zig");
const postings = @import("postings.zig");
const snapshot_open = @import("snapshot_open.zig");
const title_field = @import("title_field.zig");
const Capped = @import("nfr13_arena_test.zig").Capped;

const warmups = 5;
const timed = 200;
const repetitions = 3;
const k_calls = 1000;
const s4_queries = [_][]const u8{ "benico", "hybrid retrieval", "how does the hybrid retrieval work for a search", "the and of to in" };

const token_kinds = [_]struct { name: []const u8, token: []const u8 }{
    .{ .name = "ascii_word", .token = "garden" },
    .{ .name = "ascii_plural", .token = "gardens" },
    .{ .name = "fullwidth", .token = "ｇａｒｄｅｎｓ" },
    .{ .name = "tamil", .token = "புத்தகங்கள்" },
    .{ .name = "decomposition_4", .token = "ᾄδω" },
};

fn now(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn micros(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1000.0;
}

const Samples = struct {
    buf: []u64,

    /// `per` divides each sample (ns per call when a run makes `per` calls).
    fn print(samples: Samples, comptime label: []const u8, io: std.Io, arena: *std.heap.ArenaAllocator, context: anytype, comptime run: anytype, per: u64, ns: bool) !void {
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
            const p50 = samples.buf[timed / 2 - 1];
            const value = if (ns) @as(f64, @floatFromInt(p50)) / @as(f64, @floatFromInt(per)) else micros(p50) / @as(f64, @floatFromInt(per));
            std.debug.print("{s}{d:.2}", .{ if (rep == 0) "" else ",", value });
        }
        std.debug.print("]", .{});
    }
};

/// The body terms, then the title terms the body does not hold.
fn keyMapTerms(allocator: std.mem.Allocator, index: postings.Index, field: title_field.Field) ![][]const u8 {
    var list = try std.ArrayList([]const u8).initCapacity(allocator, index.terms.len + field.terms.len);
    for (index.terms) |entry| list.appendAssumeCapacity(entry.term);
    for (field.terms) |term| {
        const bytes = field.termBytes(term);
        if (postings.lookupExact(index, bytes) == null) list.appendAssumeCapacity(bytes);
    }
    return list.toOwnedSlice(allocator);
}

const Context = struct {
    index: postings.Index,
    field: *const title_field.Field,
    terms: [][]const u8,
    map: *const fold.KeyMap,
};

/// The indexed terms of t's group: K(t), then the term equal to the key when
/// indexed and its key is itself, then the map's entries for the key.
fn groupOf(allocator: std.mem.Allocator, ctx: Context, t: []const u8, out: *std.ArrayList([]const u8)) !void {
    var keyer = fold.Keyer.init(allocator);
    var k = std.ArrayList(u8).empty;
    try keyer.appendKey(t, &k);
    out.clearRetainingCapacity();
    if (indexed(ctx, k.items)) {
        var kk = std.ArrayList(u8).empty;
        try keyer.appendKey(k.items, &kk);
        if (std.mem.eql(u8, kk.items, k.items)) try out.append(allocator, ctx.terms[termIndex(ctx, k.items).?]);
    }
    const r = ctx.map.range(k.items);
    for (ctx.map.term_of[r.start..r.end]) |i| try out.append(allocator, ctx.terms[i]);
}

fn termIndex(ctx: Context, bytes: []const u8) ?usize {
    if (postings.lookupExact(ctx.index, bytes)) |i| return i;
    for (ctx.terms[ctx.index.terms.len..], ctx.index.terms.len..) |t, i| if (std.mem.eql(u8, t, bytes)) return i;
    return null;
}

fn indexed(ctx: Context, bytes: []const u8) bool {
    return postings.lookupExact(ctx.index, bytes) != null or ctx.field.lookup(bytes) != null;
}

/// What a query adds before scoring: each distinct analysed term's key, the
/// key's own lookup and the map's range. Returns the groups that form.
fn groupChecks(allocator: std.mem.Allocator, ctx: Context, query: []const u8) !usize {
    const tokens = try analyzer_v2.tokenize(allocator, query);
    var keyer = fold.Keyer.init(allocator);
    var k = std.ArrayList(u8).empty;
    var groups: usize = 0;
    for (tokens, 0..) |token, position| {
        var seen = false;
        for (tokens[0..position]) |earlier| seen = seen or std.mem.eql(u8, earlier, token);
        if (seen) continue;
        k.clearRetainingCapacity();
        try keyer.appendKey(token, &k);
        var members: usize = 0;
        if (!std.mem.eql(u8, k.items, token) and indexed(ctx, k.items)) members += 1;
        const r = ctx.map.range(k.items);
        for (ctx.map.term_of[r.start..r.end]) |i| {
            if (!std.mem.eql(u8, ctx.terms[i], token)) members += 1;
        }
        if (members != 0) groups += 1;
    }
    return groups;
}

fn QueryRun(comptime field: anytype) type {
    return struct {
        fn run(allocator: std.mem.Allocator, c: anytype) !void {
            const hits = try c.engine.queryFields(allocator, c.query, field, .{ .retrieval_mode = .lexical, .top_k = 10, .candidate_k = 100 });
            std.mem.doNotOptimizeAway(hits.len);
        }
    };
}

fn chooseWords(allocator: std.mem.Allocator, ctx: Context, map: fold.KeyMap, out: *std.ArrayList([]const u8)) !void {
    // Natural groups: every indexed term of a key two or more indexed terms share.
    var i: usize = 0;
    while (i < map.len()) {
        const r = map.range(map.keyOf(i));
        const k = map.keyOf(i);
        const self_indexed = indexed(ctx, k) and blk: {
            const kk = try fold.key(allocator, k);
            break :blk std.mem.eql(u8, kk, k);
        };
        const size = r.end - r.start + @intFromBool(self_indexed);
        if (size >= 2) {
            if (self_indexed) try out.append(allocator, k);
            for (map.term_of[r.start..r.end]) |t| try out.append(allocator, ctx.terms[t]);
            // The key with its first `e` written `é`.
            if (std.mem.indexOfScalar(u8, k, 'e')) |at| {
                try out.append(allocator, try std.mem.concat(allocator, u8, &.{ k[0..at], "é", k[at + 1 ..] }));
            }
        }
        i = r.end;
    }
    // Plurals of pseudo-words.
    var pool = std.ArrayList([]const u8).empty;
    for (ctx.index.terms) |entry| {
        const t = entry.term;
        if (t.len != 7 or t[0] != 'b') continue;
        var ascii = true;
        for (t) |c| ascii = ascii and c < 0x80;
        if (ascii) try pool.append(allocator, t);
    }
    var found: usize = 0;
    for (pool.items[pool.items.len / 2 ..]) |w| {
        const plural = try std.mem.concat(allocator, u8, &.{ w, "s" });
        if (indexed(ctx, plural)) continue;
        const k = try fold.key(allocator, plural);
        if (!std.mem.eql(u8, k, w)) continue;
        try out.append(allocator, plural);
        found += 1;
        if (found == 2) break;
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args = init.minimal.args.iterate();
    _ = args.next();
    const path = args.next() orelse return error.MissingIndex;

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
    var work = std.heap.ArenaAllocator.init(gpa);
    defer work.deinit();
    const w = work.allocator();
    const samples = Samples{ .buf = try gpa.alloc(u64, timed) };
    defer gpa.free(samples.buf);

    std.debug.print("{{\"index\":{{\"chunks\":{d},\"body_terms\":{d},\"title_terms\":{d},\"fold_table\":{{\"entries\":{d},\"outputs\":{d},\"pool_bytes\":{d},\"bytes\":{d}}}}}}}\n", .{
        engine.documents.len,                                                                                                                 index.terms.len, field.terms.len, tables.fold_from.len, tables.fold_offsets.len - 1, tables.fold_pool.len,
        @sizeOf(@TypeOf(tables.fold_from)) + @sizeOf(@TypeOf(tables.fold_to)) + @sizeOf(@TypeOf(tables.fold_offsets)) + tables.fold_pool.len,
    });

    // K per token.
    for (token_kinds) |kind| {
        const out = try fold.key(w, kind.token);
        std.debug.print("{{\"k\":\"{s}\",\"token\":\"{s}\",\"key\":\"{s}\"", .{ kind.name, kind.token, out });
        try samples.print("ns_per_call", io, &request, kind.token, struct {
            fn run(allocator: std.mem.Allocator, token: []const u8) !void {
                var keyer = fold.Keyer.init(allocator);
                var buffer = std.ArrayList(u8).empty;
                for (0..k_calls) |_| {
                    buffer.clearRetainingCapacity();
                    try keyer.appendKey(token, &buffer);
                    std.mem.doNotOptimizeAway(buffer.items.len);
                }
            }
        }.run, k_calls, true);
        std.debug.print("}}\n", .{});
    }

    // The table lookup alone.
    {
        const n = tables.fold_from.len;
        const misses = try w.alloc(u21, n);
        for (misses, 0..) |*m, i| m.* = @intCast(0x0B80 + i % 0x80);
        std.debug.print("{{\"lookup\":{d}", .{n});
        try samples.print("hit_ns_per_call", io, &request, &tables.fold_from, struct {
            fn run(_: std.mem.Allocator, cps: []const u21) !void {
                for (cps) |cp| std.mem.doNotOptimizeAway(fold.foldOutput(cp));
            }
        }.run, n, true);
        try samples.print("miss_ns_per_call", io, &request, @as([]const u21, misses), struct {
            fn run(_: std.mem.Allocator, cps: []const u21) !void {
                for (cps) |cp| std.mem.doNotOptimizeAway(fold.foldOutput(cp));
            }
        }.run, n, true);
        std.debug.print("}}\n", .{});
    }

    // The key map derive.
    const terms = try keyMapTerms(w, index, field.*);
    var map = try fold.KeyMap.derive(w, gpa, terms);
    {
        var peak = Capped{ .parent = gpa, .cap = std.math.maxInt(usize) };
        var kept = Capped{ .parent = gpa, .cap = std.math.maxInt(usize) };
        var list_peak = Capped{ .parent = gpa, .cap = std.math.maxInt(usize) };
        const list = try keyMapTerms(list_peak.allocator(), index, field.*);
        var measured = try fold.KeyMap.derive(kept.allocator(), peak.allocator(), list);
        defer measured.deinit(kept.allocator());
        list_peak.allocator().free(list);
        var shared: usize = 0;
        var i: usize = 0;
        while (i < map.len()) {
            const r = map.range(map.keyOf(i));
            const k = map.keyOf(i);
            const self_indexed = indexed(.{ .index = index, .field = field, .terms = terms, .map = &map }, k) and std.mem.eql(u8, try fold.key(w, k), k);
            if (r.end - r.start + @intFromBool(self_indexed) >= 2) shared += 1;
            i = r.end;
        }
        std.debug.print("{{\"derive\":{{\"terms\":{d},\"entries\":{d},\"shared_keys\":{d},\"kept_bytes\":{d},\"kept_reported\":{d},\"transient_peak_bytes\":{d},\"transient_left\":{d},\"term_list_bytes\":{d}}}", .{ terms.len, map.len(), shared, kept.live, measured.keptBytes(), peak.peak, peak.live, list_peak.peak });
        std.debug.print(",\"entries_list\":[", .{});
        for (0..map.len()) |e| std.debug.print("{s}[\"{s}\",\"{s}\"]", .{ if (e == 0) "" else ",", map.keyOf(e), terms[map.term_of[e]] });
        std.debug.print("]", .{});
        try samples.print("derive_us", io, &request, .{ .index = index, .field = field }, struct {
            fn run(allocator: std.mem.Allocator, c: anytype) !void {
                const fresh = try keyMapTerms(allocator, c.index, c.field.*);
                const m = try fold.KeyMap.derive(allocator, allocator, fresh);
                std.mem.doNotOptimizeAway(m.len());
            }
        }.run, 1, false);
        std.debug.print("}}\n", .{});
    }

    const ctx = Context{ .index = index, .field = field, .terms = terms, .map = &map };
    var words = std.ArrayList([]const u8).empty;
    try chooseWords(w, ctx, map, &words);
    for (words.items) |t| {
        var group = std.ArrayList([]const u8).empty;
        try groupOf(w, ctx, t, &group);
        var members = std.ArrayList(u8).empty;
        for (group.items, 0..) |m, i| try members.print(w, "{s}{s}", .{ if (i == 0) "" else " ", m });
        std.debug.print("{{\"group\":\"{s}\",\"t_indexed\":{},\"members\":[", .{ t, indexed(ctx, t) });
        for (group.items, 0..) |m, i| {
            const df = if (postings.lookupExact(index, m)) |at| index.terms[at].document_frequency else 0;
            std.debug.print("{s}[\"{s}\",{d}]", .{ if (i == 0) "" else ",", m, df });
        }
        std.debug.print("]", .{});
        try samples.print("key_and_lookup_ns", io, &request, .{ .ctx = ctx, .t = t }, struct {
            fn run(allocator: std.mem.Allocator, c: anytype) !void {
                var g = std.ArrayList([]const u8).empty;
                try groupOf(allocator, c.ctx, c.t, &g);
                std.mem.doNotOptimizeAway(g.items.len);
            }
        }.run, 1, true);
        inline for (.{ .{ "content", .content }, .{ "both", .both } }) |fd| {
            try samples.print(fd[0] ++ "_t_today_us", io, &request, .{ .engine = engine, .query = t }, QueryRun(fd[1]).run, 1, false);
            try samples.print(fd[0] ++ "_members_us", io, &request, .{ .engine = engine, .query = members.items }, QueryRun(fd[1]).run, 1, false);
        }
        std.debug.print("}}\n", .{});
    }

    for (s4_queries) |query| {
        const groups = try groupChecks(request.allocator(), ctx, query);
        _ = request.reset(.retain_capacity);
        std.debug.print("{{\"s4\":\"{s}\",\"groups\":{d}", .{ query, groups });
        try samples.print("content_today_us", io, &request, .{ .engine = engine, .query = query }, QueryRun(.content).run, 1, false);
        try samples.print("group_checks_us", io, &request, .{ .ctx = ctx, .query = query }, struct {
            fn run(allocator: std.mem.Allocator, c: anytype) !void {
                std.mem.doNotOptimizeAway(try groupChecks(allocator, c.ctx, c.query));
            }
        }.run, 1, false);
        std.debug.print("}}\n", .{});
    }
}
