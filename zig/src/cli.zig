//! `searchd index|query|evidence` (S1-T1 acceptance criterion 3): native,
//! Python-free folder indexing and querying on top of `indexer.zig`,
//! `chunker.zig`, and the existing segment/manifest/engine machinery.
//!
//! Query-time analyzer awareness: a plain `Engine.query` call always
//! tokenizes the query text with the ASCII `analysis.zig` scanner, which is
//! correct for an `analyzer-v1` (or legacy `ascii-alnum-v1`) index but wrong
//! for an `analyzer-v2` (Unicode) index -- an ASCII scanner cannot see
//! Tamil, or accented Latin, in the query text at all. `Engine.queryTokenized`
//! (in `engine.zig`) checks `analyzer_id` and dispatches to
//! `analyzer_v2.tokenize` + `lexical_build.scoreQuery` for `analyzer-v2`
//! snapshots; `runQuery`/`runEvidence` below use it, and so does
//! `Service.searchKnowledge` (`service.zig`) -- which means `searchd serve`,
//! stdio and `--http` alike, is analyzer-aware too, not just this CLI path.
const std = @import("std");
const chunker = @import("chunker.zig");
const engine_module = @import("engine.zig");
const hybrid = @import("hybrid.zig");
const indexer = @import("indexer.zig");
const snapshot_open = @import("snapshot_open.zig");

pub const IndexOptions = struct {
    analyzer: indexer.AnalyzerId = .v2,
    max_chars: usize = chunker.default_max_chars,
    overlap_lines: usize = chunker.default_overlap_lines,
    generation: u64 = 1,
};

pub fn runIndex(
    io: std.Io,
    allocator: std.mem.Allocator,
    folder_path: []const u8,
    out_path: []const u8,
    options: IndexOptions,
    output: *std.Io.Writer,
) !void {
    var root = try std.Io.Dir.cwd().openDir(io, folder_path, .{ .iterate = true });
    defer root.close(io);
    var out_dir = try std.Io.Dir.cwd().createDirPathOpen(io, out_path, .{});
    defer out_dir.close(io);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    const report = try indexer.indexFolder(
        arena_state.allocator(),
        io,
        root,
        out_dir,
        options.analyzer,
        options.generation,
        options.max_chars,
        options.overlap_lines,
    );

    try output.print(
        "indexed {s}: analyzer={s} generation={d} files_indexed={d} files_skipped={d} documents={d} terms={d} postings={d}\n",
        .{ folder_path, report.analyzer_id, report.generation, report.files_indexed, report.files_skipped, report.documents, report.terms, report.postings },
    );
}

pub const QueryOptions = struct {
    top_k: usize = 10,
    json: bool = false,
};

fn runSearch(
    allocator: std.mem.Allocator,
    engine: engine_module.Engine,
    query_text: []const u8,
    top_k: usize,
) ![]hybrid.Result {
    const result_output = try allocator.alloc(hybrid.Result, engine.documents.len);
    const score_output = try allocator.alloc(f32, engine.documents.len);
    const options = hybrid.SearchOptions{ .top_k = top_k, .candidate_k = @max(top_k, engine.documents.len), .retrieval_mode = .lexical };
    return engine.queryTokenized(allocator, query_text, &.{}, score_output, result_output, options);
}

pub fn runQuery(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    query_text: []const u8,
    options: QueryOptions,
    output: *std.Io.Writer,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
    defer dir.close(io);
    const engine = try snapshot_open.open(arena, io, dir);
    const results = try runSearch(arena, engine, query_text, options.top_k);

    if (options.json) {
        var json = std.json.Stringify{ .writer = output };
        try json.beginObject();
        try json.objectField("query");
        try json.write(query_text);
        try json.objectField("analyzer_id");
        try json.write(engine.analyzer_id);
        try json.objectField("results");
        try json.beginArray();
        for (results) |result| {
            const evidence = engine.evidence(result);
            try json.beginObject();
            try json.objectField("chunk_id");
            try json.write(evidence.chunk_id);
            try json.objectField("path");
            try json.write(evidence.path);
            try json.objectField("start_line");
            try json.write(evidence.start_line);
            try json.objectField("end_line");
            try json.write(evidence.end_line);
            try json.objectField("score");
            try json.write(evidence.fused_score);
            try json.endObject();
        }
        try json.endArray();
        try json.endObject();
        try output.writeByte('\n');
        return;
    }

    try output.print("query: {s} (analyzer={s})\n", .{ query_text, engine.analyzer_id });
    for (results, 0..) |result, index| {
        try output.print("{d}. {s}:{d}-{d} score={d:.6}\n", .{ index + 1, result.path, result.start_line, result.end_line, result.fused_score });
    }
}

pub fn runEvidence(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    query_text: []const u8,
    options: QueryOptions,
    output: *std.Io.Writer,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
    defer dir.close(io);
    const engine = try snapshot_open.open(arena, io, dir);
    const results = try runSearch(arena, engine, query_text, options.top_k);

    var json = std.json.Stringify{ .writer = output };
    try json.beginObject();
    try json.objectField("query");
    try json.write(query_text);
    try json.objectField("analyzer_id");
    try json.write(engine.analyzer_id);
    try json.objectField("evidence");
    try json.beginArray();
    for (results) |result| {
        const evidence = engine.evidence(result);
        try json.beginObject();
        try json.objectField("chunk_id");
        try json.write(evidence.chunk_id);
        try json.objectField("path");
        try json.write(evidence.path);
        try json.objectField("start_line");
        try json.write(evidence.start_line);
        try json.objectField("end_line");
        try json.write(evidence.end_line);
        try json.objectField("content");
        try json.write(evidence.content);
        try json.objectField("fused_score");
        try json.write(evidence.fused_score);
        try json.objectField("lexical_score");
        try json.write(evidence.lexical_score);
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
    try output.writeByte('\n');
}
