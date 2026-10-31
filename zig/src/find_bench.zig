//! S3-T2 timing tool (§13 profile): query latency over a published index.
//!
//!     zig run -OReleaseFast zig/src/find_bench.zig -- INDEX_DIR [MODE ...]
//!
//! MODE is any of `knowledge` (search_knowledge: `Engine.queryTokenized`,
//! lexical, top 10), `words`, `phrase`, `prefix` (`find`, page size 20),
//! `phrase-recompute`, `words-recompute` (`find` with offsets recomputed by
//! re-tokenizing, the NFR-11 rollback); default all. Queries are drawn
//! deterministically from the indexed chunks (205 per mode: chunk
//! `(q * 7919) mod n`; phrase = three adjacent tokens, words = two tokens of
//! the chunk far apart, prefix = the first four codepoints of a token of
//! six or more codepoints plus `*`), so every query has at least one hit. Per mode: 5
//! warm-up queries, then 200 timed, three repetitions; prints p50 and p95
//! in microseconds per repetition, mean hits, and the lexical section's
//! sizes. Each query runs in an arena reset between queries. Not part of any
//! library or the build graph.
//!
//! The `find` blocks are fenced by `find:begin`/`find:end` lines: deleting
//! them gives the same tool for a tree without `find.zig` (how the "before"
//! numbers of `knowledge` were taken on `main`).
const std = @import("std");
const analyzer_v2 = @import("analyzer_v2.zig");
const engine_module = @import("engine.zig");
const hybrid = @import("hybrid.zig");
const lexical_segment = @import("lexical_segment.zig");
const manifest = @import("manifest.zig");
const publication = @import("publication.zig");
const snapshot_open = @import("snapshot_open.zig");
// find:begin
const find = @import("find.zig");
// find:end

const warmups = 5;
const timed = 200;
const repetitions = 3;
const query_count = warmups + timed;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args = init.minimal.args.iterate();
    _ = args.next();
    const dir_path = args.next() orelse return error.MissingIndexDir;
    var modes = std.ArrayList([]const u8).empty;
    defer modes.deinit(gpa);
    while (args.next()) |mode| try modes.append(gpa, mode);
    if (modes.items.len == 0) try modes.appendSlice(gpa, &.{ "knowledge", "words", "phrase", "prefix", "words-recompute", "phrase-recompute" });

    var open_arena = std.heap.ArenaAllocator.init(gpa);
    defer open_arena.deinit();
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    const open_start = std.Io.Clock.awake.now(io).nanoseconds;
    const engine = try snapshot_open.open(open_arena.allocator(), io, dir);
    const open_ns = std.Io.Clock.awake.now(io).nanoseconds - open_start;
    try printSections(open_arena.allocator(), io, dir, engine, open_ns);

    const queries = try buildQueries(open_arena.allocator(), engine);
    var query_arena = std.heap.ArenaAllocator.init(gpa);
    defer query_arena.deinit();
    const samples = try gpa.alloc(u64, timed);
    defer gpa.free(samples);

    for (modes.items) |mode| {
        const list = if (std.mem.startsWith(u8, mode, "words") or std.mem.eql(u8, mode, "knowledge"))
            queries.words
        else if (std.mem.startsWith(u8, mode, "phrase")) queries.phrase else queries.prefix;
        std.debug.print("{s}:", .{mode});
        var hits_total: usize = 0;
        for (0..repetitions) |_| {
            hits_total = 0;
            for (list, 0..) |query, q| {
                _ = query_arena.reset(.retain_capacity);
                const start = std.Io.Clock.awake.now(io).nanoseconds;
                const hits = try runOne(query_arena.allocator(), engine, mode, query);
                const elapsed: u64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds - start);
                if (q >= warmups) {
                    samples[q - warmups] = elapsed;
                    hits_total += hits;
                }
            }
            std.mem.sort(u64, samples, {}, std.sort.asc(u64));
            std.debug.print(" p50 {d:.1} p95 {d:.1} |", .{ micros(samples[timed / 2 - 1]), micros(samples[timed * 95 / 100 - 1]) });
        }
        std.debug.print(" mean hits {d:.1}\n", .{@as(f64, @floatFromInt(hits_total)) / timed});
    }
}

fn micros(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1000.0;
}

fn runOne(allocator: std.mem.Allocator, engine: engine_module.Engine, mode: []const u8, query: []const u8) !usize {
    if (std.mem.eql(u8, mode, "knowledge")) {
        var results: [10]hybrid.Result = undefined;
        const ranked = try engine.queryTokenized(allocator, query, &.{}, &results, .{ .top_k = 10, .retrieval_mode = .lexical });
        return ranked.len;
    }
    // find:begin
    const find_mode: find.Mode = if (std.mem.startsWith(u8, mode, "words")) .words else if (std.mem.startsWith(u8, mode, "phrase")) .phrase else .prefix;
    const outcome = try find.find(allocator, engine, .{
        .query = query,
        .mode = find_mode,
        .recompute_offsets = std.mem.endsWith(u8, mode, "-recompute"),
    });
    switch (outcome) {
        .ok => |answer| return answer.total_hits,
        .failed => |failure| {
            std.debug.print("\nfind failed for {s}: {s}\n", .{ query, failure.message });
            return error.FindFailed;
        },
    }
    // find:end
    return error.UnknownMode;
}

const Queries = struct { words: []const []const u8, phrase: []const []const u8, prefix: []const []const u8 };

fn buildQueries(allocator: std.mem.Allocator, engine: engine_module.Engine) !Queries {
    const words = try allocator.alloc([]const u8, query_count);
    const phrase = try allocator.alloc([]const u8, query_count);
    const prefix = try allocator.alloc([]const u8, query_count);
    const n = engine.documents.len;
    for (0..query_count) |q| {
        var pick = (q * 7919) % n;
        var tokens = try analyzer_v2.tokenize(allocator, engine.documents[pick].text);
        while (tokens.len < 8) {
            pick = (pick + 1) % n;
            tokens = try analyzer_v2.tokenize(allocator, engine.documents[pick].text);
        }
        const middle = tokens.len / 2;
        phrase[q] = try std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ tokens[middle], tokens[middle + 1], tokens[middle + 2] });
        words[q] = try std.fmt.allocPrint(allocator, "{s} {s}", .{ tokens[1], tokens[tokens.len - 2] });
        var chosen: []const u8 = tokens[middle];
        for (tokens[middle..]) |token| {
            if ((std.unicode.utf8CountCodepoints(token) catch 0) >= 6) {
                chosen = token;
                break;
            }
        }
        prefix[q] = try std.fmt.allocPrint(allocator, "{s}*", .{firstCodepoints(chosen, 4)});
    }
    return .{ .words = words, .phrase = phrase, .prefix = prefix };
}

/// The first `count` codepoints of `text` (never a partial sequence).
fn firstCodepoints(text: []const u8, count: usize) []const u8 {
    var seen: usize = 0;
    for (text, 0..) |byte, at| {
        if (byte & 0xC0 == 0x80) continue;
        if (seen == count) return text[0..at];
        seen += 1;
    }
    return text;
}

fn printSections(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, engine: engine_module.Engine, open_ns: i96) !void {
    var manifest_file = try dir.openFile(io, publication.current_manifest_file, .{});
    const size = (try manifest_file.stat(io)).size;
    manifest_file.close(io);
    const manifest_bytes = try dir.readFile(io, publication.current_manifest_file, try allocator.alloc(u8, @intCast(size)));
    const metadata = try manifest.decode(manifest_bytes);
    const lexical = try dir.readFile(io, metadata.lexical_file, try allocator.alloc(u8, metadata.lexical_bytes));
    const header = try lexical_segment.inspect(lexical);
    std.debug.print("generation {d}, {d} chunks, {d} terms, {d} postings; documents section {d} B; source section {d} B; open {d:.1} ms\n", .{
        engine.generation,       engine.documents.len,  header.term_count, header.posting_count,
        metadata.documents_bytes, metadata.source_bytes, @as(f64, @floatFromInt(open_ns)) / 1e6,
    });
    // HYBLEX02 fields exist only on a tree that has them (comptime-pruned on `main`).
    if (comptime @hasDecl(lexical_segment, "header_length_v2")) {
        std.debug.print("lexical section {d} B: version {d}, header {d}, lengths {d}, dictionary {d}, postings {d}, positions {d}, offsets {d}\n", .{
            metadata.lexical_bytes,       header.version,
            if (header.version == 2) lexical_segment.header_length_v2 else lexical_segment.header_length,
            header.document_lengths_bytes, header.dictionary_bytes,
            header.postings_bytes,        header.positions_bytes,
            header.offsets_bytes,
        });
    } else {
        std.debug.print("lexical section {d} B: version 1, header {d}, lengths {d}, dictionary {d}, postings {d}\n", .{
            metadata.lexical_bytes, lexical_segment.header_length, header.document_lengths_bytes, header.dictionary_bytes, header.postings_bytes,
        });
    }
}
