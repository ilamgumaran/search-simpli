//! S5-T2 Phase 1 profile (plan ruling 9): the title field's derive, stage by
//! stage, and an estimate of what the title part adds to a content query.
//! Opt-in diagnostic, not part of any library or the build graph:
//!
//!     zig run -lc -OReleaseSmall zig/src/title_field_bench.zig -- INDEX [ROUNDS]
//!
//! INDEX is a `searchd index --filename-index` over a
//! `scripts/gen_timing_corpus.py` corpus. Prints, as JSON lines:
//! - `derive`: the counts (chunks, files, distinct folders, tokens, terms,
//!   postings), the retained block's bytes, the scratch arena's peak, and the
//!   time of each stage for the first derive after the open and the median
//!   of ROUNDS more (default 20);
//! - per file-naming query (`doc`, `the doc`, `group`, `doc the`,
//!   `group doc 00042`), and two queries no title holds (`hybrid
//!   retrieval`, `nosuchword`): today's `content` and `both` (`Engine.queryFields`,
//!   top 10, candidate 100) p50, and the parts of a sketch of the Phase 2
//!   content path, each p50: the title walk (analyzer-v2 tokens, lookup,
//!   BM25 times coverage times 2.5 into per-file arrays), today's body path
//!   as the sketch runs it (the sparse scorer offering each match to a
//!   bounded top 10) and the sketch's whole path (the matches buffered, each
//!   file's best body chunk, the title part added to it, the title-only files
//!   offered at their first chunk). The sketch is not the Phase 2 code: its
//!   extra over its own body path is an estimate of the content query's
//!   extra time. 5 warm-ups, 200 timed, three repetitions.
const std = @import("std");
const analyzer_v2 = @import("analyzer_v2.zig");
const engine_module = @import("engine.zig");
const hybrid = @import("hybrid.zig");
const lexical_build = @import("lexical_build.zig");
const postings = @import("postings.zig");
const scoring = @import("scoring.zig");
const snapshot_open = @import("snapshot_open.zig");
const title_field = @import("title_field.zig");
const Capped = @import("nfr13_arena_test.zig").Capped;

/// The five file-naming queries of `capture_query_outputs.py`, then two
/// with no title term (a body phrase of the corpus and an absent word).
const queries = [_][]const u8{ "doc", "the doc", "group", "doc the", "group doc 00042", "hybrid retrieval", "nosuchword" };
const warmups = 5;
const timed = 200;
const repetitions = 3;
const stage_names = [_][]const u8{ "grouping", "folders", "stems", "postings", "lookup" };

const StageClock = struct {
    io: std.Io,
    last: i96,
    times: [stage_names.len]u64 = @splat(0),
    count: usize = 0,

    pub fn mark(self: *StageClock, comptime _: []const u8) void {
        const at = std.Io.Clock.awake.now(self.io).nanoseconds;
        self.times[self.count] = @intCast(at - self.last);
        self.count += 1;
        self.last = at;
    }
};

fn now(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn micros(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1000.0;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args = init.minimal.args.iterate();
    _ = args.next();
    const path = args.next() orelse return error.MissingIndex;
    const rounds = try std.fmt.parseInt(usize, args.next() orelse "20", 10);

    var open_counter = Capped{ .parent = gpa, .cap = std.math.maxInt(usize) };
    var open_arena = std.heap.ArenaAllocator.init(open_counter.allocator());
    defer open_arena.deinit();
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
    defer dir.close(io);
    const open_start = now(io);
    const opened = try snapshot_open.openScoped(open_arena.allocator(), io, dir);
    defer opened.folder.close();
    const open_ns: u64 = @intCast(now(io) - open_start);
    const engine = opened.engine;
    const documents = engine.documents;
    const roots = engine.roots;

    // -- the derive: the first after the open, then `rounds` more.
    var block_counter = Capped{ .parent = gpa, .cap = std.math.maxInt(usize) };
    var scratch_counter = Capped{ .parent = gpa, .cap = std.math.maxInt(usize) };
    var first_clock = StageClock{ .io = io, .last = now(io) };
    const derived = try title_field.deriveMarked(block_counter.allocator(), scratch_counter.allocator(), documents, roots, &first_clock);
    defer derived.deinit(block_counter.allocator());
    const first_total: u64 = blk: {
        var sum: u64 = 0;
        for (first_clock.times) |t| sum += t;
        break :blk sum;
    };
    const scratch_peak_first = scratch_counter.peak;
    const retained_live = block_counter.live;
    const per_stage = try gpa.alloc([stage_names.len + 1]u64, rounds);
    defer gpa.free(per_stage);
    for (per_stage) |*row| {
        var clock = StageClock{ .io = io, .last = now(io) };
        var counter = Capped{ .parent = gpa, .cap = std.math.maxInt(usize) };
        const again = try title_field.deriveMarked(counter.allocator(), scratch_counter.allocator(), documents, roots, &clock);
        again.deinit(counter.allocator());
        var sum: u64 = 0;
        for (clock.times, 0..) |t, i| {
            row[i] = t;
            sum += t;
        }
        row[stage_names.len] = sum;
    }
    const p = derived.profile;
    std.debug.print("{{\"derive\":{{\"chunks\":{d},\"files\":{d},\"in_order\":{},\"distinct_folders\":{d},\"tokens\":{d},\"terms\":{d},\"postings\":{d},\"block_bytes\":{d},\"retained_live_bytes\":{d},\"scratch_peak_bytes\":{d},\"open_ns\":{d},\"open_live_bytes\":{d}}}}}\n", .{ p.chunks, p.files, p.in_order, p.distinct_folders, p.tokens, p.terms, p.postings, p.block_bytes, retained_live, scratch_peak_first, open_ns, open_counter.live });
    std.debug.print("{{\"stages_us\":{{\"first\":{{", .{});
    for (stage_names, 0..) |name, i| std.debug.print("\"{s}\":{d:.1},", .{ name, micros(first_clock.times[i]) });
    std.debug.print("\"total\":{d:.1}}},\"median_of_{d}\":{{", .{ micros(first_total), rounds });
    for (0..stage_names.len + 1) |i| {
        const column = try gpa.alloc(u64, rounds);
        defer gpa.free(column);
        for (per_stage, column) |row, *c| c.* = row[i];
        std.mem.sort(u64, column, {}, std.sort.asc(u64));
        const name = if (i < stage_names.len) stage_names[i] else "total";
        std.debug.print("\"{s}\":{d:.1}{s}", .{ name, micros(column[rounds / 2]), if (i < stage_names.len) "," else "" });
    }
    std.debug.print("}}}}}}\n", .{});

    // -- the five file-naming queries.
    var request = std.heap.ArenaAllocator.init(gpa);
    defer request.deinit();
    const samples = try gpa.alloc(u64, timed);
    defer gpa.free(samples);
    const field = derived.field;
    for (queries) |query| {
        const counts = try sketch(request.allocator(), engine, field, query, .whole);
        _ = request.reset(.retain_capacity);
        std.debug.print("{{\"query\":\"{s}\",\"title_files\":{d},\"body_matches\":{d},\"title_only_files\":{d}", .{ query, counts.title_files, counts.body_matches, counts.title_only });
        inline for (.{ "content_today", "both_today", "title_walk", "sketch_body", "sketch_whole" }) |what| {
            std.debug.print(",\"{s}_us\":[", .{what});
            for (0..repetitions) |rep| {
                for (0..warmups + timed) |q| {
                    _ = request.reset(.retain_capacity);
                    const a = request.allocator();
                    const start = now(io);
                    if (comptime std.mem.eql(u8, what, "content_today")) {
                        _ = try engine.queryFields(a, query, .content, .{ .retrieval_mode = .lexical, .top_k = 10, .candidate_k = 100 });
                    } else if (comptime std.mem.eql(u8, what, "both_today")) {
                        _ = try engine.queryFields(a, query, .both, .{ .retrieval_mode = .lexical, .top_k = 10, .candidate_k = 100 });
                    } else if (comptime std.mem.eql(u8, what, "title_walk")) {
                        _ = try titleWalk(a, field, query);
                    } else if (comptime std.mem.eql(u8, what, "sketch_body")) {
                        _ = try sketch(a, engine, field, query, .body);
                    } else {
                        _ = try sketch(a, engine, field, query, .whole);
                    }
                    const elapsed: u64 = @intCast(now(io) - start);
                    if (q >= warmups) samples[q - warmups] = elapsed;
                }
                std.mem.sort(u64, samples, {}, std.sort.asc(u64));
                std.debug.print("{s}{d:.2}", .{ if (rep == 0) "" else ",", micros(samples[timed / 2 - 1]) });
            }
            std.debug.print("]", .{});
        }
        std.debug.print("}}\n", .{});
    }
}

const Walk = struct { scores: []f32, touched: []u32 };

/// The title part of every file the query's title terms reach: weight x
/// BM25 (k1 1.2, b 0.75, unscoped statistics) x coverage.
fn titleWalk(allocator: std.mem.Allocator, field: title_field.Field, query: []const u8) !Walk {
    const raw = try analyzer_v2.tokenize(allocator, query);
    std.mem.sort([]const u8, raw, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    var distinct: usize = 0;
    for (raw, 0..) |token, i| {
        if (i == 0 or !std.mem.eql(u8, raw[i - 1], token)) {
            raw[distinct] = token;
            distinct += 1;
        }
    }
    const files = field.files.len;
    const scores = try allocator.alloc(f32, files);
    @memset(scores, 0);
    const covered = try allocator.alloc(u16, files);
    @memset(covered, 0);
    var touched = std.ArrayList(u32).empty;
    const count: u32 = @intCast(files);
    const average: f32 = if (files == 0) 0 else @floatCast(@as(f64, @floatFromInt(field.total_length)) / @as(f64, @floatFromInt(files)));
    for (raw[0..distinct]) |token| {
        const term = field.lookup(token) orelse continue;
        for (field.termPostings(term)) |posting| {
            if (covered[posting.file] == 0) try touched.append(allocator, posting.file);
            covered[posting.file] += 1;
            scores[posting.file] += scoring.bm25Contribution(@floatFromInt(posting.frequency), @floatFromInt(field.files[posting.file].length), average, term.postings_len, count, .{});
        }
    }
    const terms_f: f32 = @floatFromInt(@max(distinct, 1));
    for (touched.items) |f| scores[f] = title_field.default_weight * scores[f] * (@as(f32, @floatFromInt(covered[f])) / terms_f);
    return .{ .scores = scores, .touched = touched.items };
}

const Ranked = struct { document: u32, score: f32 };
fn rankedBefore(documents: []const hybrid.Document, a: Ranked, b: Ranked) bool {
    if (a.score != b.score) return a.score > b.score;
    return std.mem.order(u8, documents[a.document].id, documents[b.document].id) == .lt;
}
const Top = hybrid.BoundedTop(Ranked, []const hybrid.Document, rankedBefore);
const Counts = struct { title_files: usize = 0, body_matches: usize = 0, title_only: usize = 0 };
const none = std.math.maxInt(u32);

fn sketch(allocator: std.mem.Allocator, engine: engine_module.Engine, field: title_field.Field, query: []const u8, part: enum { body, whole }) !Counts {
    var counts = Counts{};
    // Resolved as `Engine.queryTraced` resolves an analyzer-v2 query.
    const query_tokens = try analyzer_v2.tokenize(allocator, query);
    const terms = try lexical_build.resolveTokensTraced(allocator, engine.lexical_index, query_tokens, null, true);
    const cursors = try allocator.alloc(usize, terms.len);
    var scorer = postings.SparseScorer.init(engine.lexical_index, terms, cursors, .{});
    var slots: [10]Ranked = undefined;
    var top = Top{ .items = &slots, .context = engine.documents };
    if (part == .body) {
        while (scorer.next()) |match| {
            counts.body_matches += 1;
            top.offer(.{ .document = match.document_index, .score = match.score });
        }
        std.mem.doNotOptimizeAway(top.count);
        return counts;
    }
    const walk = try titleWalk(allocator, field, query);
    counts.title_files = walk.touched.len;
    var matches = std.ArrayList(hybrid.LexicalMatch).empty;
    while (scorer.next()) |match| try matches.append(allocator, match);
    counts.body_matches = matches.items.len;
    // Each titled file's best body chunk (ties to the smaller id).
    const best = try allocator.alloc(u32, field.files.len);
    @memset(best, none);
    const best_score = try allocator.alloc(f32, field.files.len);
    for (matches.items) |match| {
        const f = field.file_of[match.document_index];
        if (walk.scores[f] == 0) continue;
        if (best[f] == none or match.score > best_score[f] or (match.score == best_score[f] and
            std.mem.order(u8, engine.documents[match.document_index].id, engine.documents[best[f]].id) == .lt))
        {
            best[f] = match.document_index;
            best_score[f] = match.score;
        }
    }
    for (matches.items) |match| {
        const f = field.file_of[match.document_index];
        const title = if (best[f] == match.document_index) walk.scores[f] else 0;
        top.offer(.{ .document = match.document_index, .score = match.score + title });
    }
    for (walk.touched) |f| {
        if (best[f] != none) continue;
        counts.title_only += 1;
        top.offer(.{ .document = field.files[f].first_chunk, .score = walk.scores[f] });
    }
    std.mem.doNotOptimizeAway(top.count);
    return counts;
}
