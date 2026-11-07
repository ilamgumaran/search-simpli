//! S5-T2 planner scratch (not committed): what a title field derived from the
//! documents section's record paths costs at 10k, ReleaseSmall.
//! zig run -lc -OReleaseSmall zig/src/s5t2_title_bench.zig -- INDEX
const std = @import("std");
const snapshot = @import("snapshot_open.zig");
const hybrid = @import("hybrid.zig");
const analyzer_v2 = @import("analyzer_v2.zig");
const lexical_build = @import("lexical_build.zig");
const postings = @import("postings.zig");
const scoring = @import("scoring.zig");
const scope = @import("scope.zig");
const manifest = @import("manifest.zig");

const Title = struct {
    files: []hybrid.Document,
    file_of: []u32,
    index: postings.Index,
    lookup: std.StringHashMap(u32),
    tokens: usize,
    distinct_dirs: usize,
};

fn derive(a: std.mem.Allocator, docs: []const hybrid.Document, roots: []const manifest.RootEntry) !Title {
    var files: usize = 0;
    for (docs, 0..) |d, i| {
        if (i == 0 or !std.mem.eql(u8, docs[i - 1].path, d.path)) files += 1;
    }
    const catalog = try a.alloc(hybrid.Document, files);
    const lists = try a.alloc([][]const u8, files);
    const file_of = try a.alloc(u32, docs.len);
    var dir_cache = std.StringHashMap([][]const u8).init(a);
    var f: usize = 0;
    var tokens: usize = 0;
    for (docs, 0..) |d, i| {
        if (i != 0 and std.mem.eql(u8, docs[i - 1].path, d.path)) {
            file_of[i] = @intCast(f - 1);
            continue;
        }
        const rel = if (scope.rootOfPath(roots, d.path)) |r| scope.relativePath(roots[r], d.path) else d.path;
        const slash = std.mem.lastIndexOfScalar(u8, rel, '/');
        const dir = if (slash) |s| rel[0..s] else "";
        const name = if (slash) |s| rel[s + 1 ..] else rel;
        const dot = std.mem.lastIndexOfScalar(u8, name, '.');
        const stem = if (dot) |x| (if (x == 0) name else name[0..x]) else name;
        const gop = try dir_cache.getOrPut(dir);
        if (!gop.found_existing) gop.value_ptr.* = try analyzer_v2.tokenize(a, dir);
        const stem_tokens = try analyzer_v2.tokenize(a, stem);
        const list = try a.alloc([]const u8, gop.value_ptr.len + stem_tokens.len);
        @memcpy(list[0..gop.value_ptr.len], gop.value_ptr.*);
        @memcpy(list[gop.value_ptr.len..], stem_tokens);
        lists[f] = list;
        tokens += list.len;
        catalog[f] = .{ .id = d.id, .path = d.path, .text = "" };
        file_of[i] = @intCast(f);
        f += 1;
    }
    const index = try lexical_build.build(a, catalog, lists);
    var lookup = std.StringHashMap(u32).init(a);
    try lookup.ensureTotalCapacity(@intCast(index.terms.len));
    for (index.terms, 0..) |t, i| lookup.putAssumeCapacity(t.term, @intCast(i));
    return .{ .files = catalog, .file_of = file_of, .index = index, .lookup = lookup, .tokens = tokens, .distinct_dirs = dir_cache.count() };
}

/// Title BM25 x matched fraction per file, for the query's distinct terms.
fn titleScores(a: std.mem.Allocator, t: Title, query: []const u8) !usize {
    const qt = try analyzer_v2.tokenize(a, query);
    const scores = try a.alloc(f32, t.files.len);
    @memset(scores, 0);
    const matched = try a.alloc(u8, t.files.len);
    @memset(matched, 0);
    var touched = std.ArrayList(u32).empty;
    var distinct: usize = 0;
    for (qt, 0..) |term, qi| {
        var repeated = false;
        for (qt[0..qi]) |p| if (std.mem.eql(u8, p, term)) {
            repeated = true;
        };
        if (repeated) continue;
        distinct += 1;
        const ti = t.lookup.get(term) orelse continue;
        const e = t.index.terms[ti];
        for (t.index.postings[e.postings_start .. e.postings_start + e.postings_length]) |p| {
            if (matched[p.document_index] == 0) try touched.append(a, p.document_index);
            matched[p.document_index] += 1;
            scores[p.document_index] += scoring.bm25Contribution(@floatFromInt(p.term_frequency), @floatFromInt(t.index.document_lengths[p.document_index]), t.index.average_document_length, e.document_frequency, @intCast(t.files.len), .{});
        }
    }
    var kept: usize = 0;
    for (touched.items) |i| {
        scores[i] *= @as(f32, @floatFromInt(matched[i])) / @as(f32, @floatFromInt(distinct));
        if (scores[i] > 0) kept += 1;
    }
    return kept;
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const path = args.next() orelse return error.MissingIndex;
    const io = init.io;
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
    defer dir.close(io);
    const opened = try snapshot.openScoped(arena.allocator(), io, dir);
    defer opened.folder.close();
    const engine = opened.engine;
    const docs = engine.documents;

    var samples: [20]u64 = undefined;
    var info: Title = undefined;
    var bytes: usize = 0;
    for (0..25) |i| {
        var scratch = std.heap.ArenaAllocator.init(init.gpa);
        defer scratch.deinit();
        const before = std.Io.Clock.awake.now(io).nanoseconds;
        const t = try derive(scratch.allocator(), docs, engine.roots);
        const elapsed: u64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds - before);
        if (i >= 5) samples[i - 5] = elapsed;
        info = t;
        bytes = scratch.queryCapacity();
    }
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    std.debug.print("derive: chunks {d} files {d} dirs {d} tokens {d} terms {d} arena_bytes {d} p50 {d:.3} ms p95 {d:.3} ms\n", .{ docs.len, info.files.len, info.distinct_dirs, info.tokens, info.index.terms.len, bytes, ms(samples[9]), ms(samples[18]) });

    var keep = std.heap.ArenaAllocator.init(init.gpa);
    defer keep.deinit();
    const t = try derive(keep.allocator(), docs, engine.roots);
    var term_bytes: usize = 0;
    for (t.index.terms) |e| term_bytes += e.term.len;
    const retained = t.index.terms.len * @sizeOf(postings.TermEntry) + term_bytes + t.index.postings.len * @sizeOf(postings.Posting) +
        t.index.document_lengths.len * 4 + t.file_of.len * 4 + t.lookup.capacity() * (@sizeOf([]const u8) + 4 + 1);
    std.debug.print("retained (structures a reader keeps, without the catalog copy): {d} bytes; TermEntry {d} B, Posting {d} B\n", .{ retained, @sizeOf(postings.TermEntry), @sizeOf(postings.Posting) });
    const queries = [_][]const u8{ "doc", "group 42", "doc 00042", "hybrid retrieval", "search ranking doc", "nosuchword" };
    for (queries) |q| {
        var title_s: [40]u64 = undefined;
        var content_s: [40]u64 = undefined;
        var kept: usize = 0;
        var q_arena = std.heap.ArenaAllocator.init(init.gpa);
        defer q_arena.deinit();
        for (0..50) |i| {
            _ = q_arena.reset(.retain_capacity);
            const b0 = std.Io.Clock.awake.now(io).nanoseconds;
            kept = try titleScores(q_arena.allocator(), t, q);
            const b1 = std.Io.Clock.awake.now(io).nanoseconds;
            var results: [10]hybrid.Result = undefined;
            _ = try engine.queryTokenized(q_arena.allocator(), q, &.{}, &results, .{ .top_k = 10, .retrieval_mode = .lexical });
            const b2 = std.Io.Clock.awake.now(io).nanoseconds;
            if (i >= 10) {
                title_s[i - 10] = @intCast(b1 - b0);
                content_s[i - 10] = @intCast(b2 - b1);
            }
        }
        std.mem.sort(u64, &title_s, {}, std.sort.asc(u64));
        std.mem.sort(u64, &content_s, {}, std.sort.asc(u64));
        std.debug.print("query {s:<22} title files {d:>6}  title p50 {d:.4} ms p95 {d:.4} | content p50 {d:.4} ms\n", .{ q, kept, ms(title_s[19]), ms(title_s[37]), ms(content_s[19]) });
    }
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}
