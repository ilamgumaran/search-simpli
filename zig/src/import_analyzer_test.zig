//! S2-T1: `ss_import_json` / `searchd import-json` with `"analyzer_id":
//! "analyzer-v2"` (contract 1.1.0).
//!
//! Kept out of `importer.zig` on purpose: restoring `origin/main`'s
//! importer (which accepted only `ascii-alnum-v1`) must leave these tests in
//! place and make them fail (criterion 6's plant).
//!
//! Each test takes the chunks `indexer.indexFolder` publishes for a fixture
//! folder (`analyzer-v2`), writes exactly those chunks as interchange JSON,
//! imports that JSON, and checks the two doors against each other: the
//! published `MANIFEST`, document section and lexical section must be
//! byte-identical, and the Tamil judged queries must hit their passage at
//! rank 1 through the import door.
const std = @import("std");
const chunker = @import("chunker.zig");
const hybrid = @import("hybrid.zig");
const importer = @import("importer.zig");
const indexer = @import("indexer.zig");
const publication = @import("publication.zig");
const snapshot_open = @import("snapshot_open.zig");

/// Index `source_root` with `analyzer-v2` into `out_dir` (generation 1) and
/// return the interchange JSON for exactly the chunks it published.
fn folderIndexAndInterchange(
    arena: std.mem.Allocator,
    io: std.Io,
    source_root: []const u8,
    out_dir: std.Io.Dir,
    analyzer_id: []const u8,
) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    var root_dir = try cwd.openDir(io, source_root, .{ .iterate = true });
    defer root_dir.close(io);
    const report = try indexer.indexFolder(arena, io, root_dir, out_dir, .v2, 1, chunker.default_max_chars, chunker.default_overlap_lines, .{});
    try std.testing.expect(report.documents > 0);
    const engine = try snapshot_open.open(arena, io, out_dir);

    var out: std.Io.Writer.Allocating = .init(arena);
    var json = std.json.Stringify{ .writer = &out.writer };
    try json.beginObject();
    try json.objectField("format_version");
    try json.write(@as(u16, 1));
    try json.objectField("generation");
    try json.write(@as(u64, 1));
    try json.objectField("analyzer_id");
    try json.write(analyzer_id);
    try json.objectField("embedding_model_id");
    try json.write("none");
    try json.objectField("documents");
    try json.beginArray();
    for (engine.documents) |document| {
        try json.beginObject();
        try json.objectField("id");
        try json.write(document.id);
        try json.objectField("path");
        try json.write(document.path);
        try json.objectField("start_line");
        try json.write(document.start_line);
        try json.objectField("end_line");
        try json.write(document.end_line);
        try json.objectField("text");
        try json.write(document.text);
        try json.objectField("vector");
        try json.beginArray();
        try json.endArray();
        try json.objectField("required_labels");
        try json.beginArray();
        try json.endArray();
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
    return out.toOwnedSlice();
}

fn readWhole(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8) ![]u8 {
    var file = try dir.openFile(io, name, .{});
    const stat = try file.stat(io);
    file.close(io);
    const buffer = try arena.alloc(u8, std.math.cast(usize, stat.size) orelse return error.FileTooBig);
    return dir.readFile(io, name, buffer);
}

fn expectSameSnapshotBytes(arena: std.mem.Allocator, io: std.Io, folder_dir: std.Io.Dir, import_dir: std.Io.Dir) !void {
    inline for (.{ publication.current_manifest_file, "documents-1.hybseg", "lexical-1.hyblex" }) |name| {
        const folder_bytes = try readWhole(arena, io, folder_dir, name);
        const import_bytes = try readWhole(arena, io, import_dir, name);
        std.testing.expectEqualSlices(u8, folder_bytes, import_bytes) catch |err| {
            std.debug.print("S2-T1: {s} differs between searchd index and import-json\n", .{name});
            return err;
        };
    }
}

test "S2-T1: Tamil fixture published through import-json with analyzer-v2 finds every judged passage at rank 1" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var folder_tmp = std.testing.tmpDir(.{});
    defer folder_tmp.cleanup();
    var import_tmp = std.testing.tmpDir(.{});
    defer import_tmp.cleanup();
    var ascii_folder_tmp = std.testing.tmpDir(.{});
    defer ascii_folder_tmp.cleanup();
    var ascii_tmp = std.testing.tmpDir(.{});
    defer ascii_tmp.cleanup();

    const json_v2 = try folderIndexAndInterchange(arena, io, "../fixtures/tamil/passages", folder_tmp.dir, "analyzer-v2");
    const report = try importer.importJson(import_tmp.dir, io, arena, json_v2);
    try std.testing.expectEqual(@as(u64, 1), report.generation);
    try std.testing.expect(report.terms > 0);
    try expectSameSnapshotBytes(arena, io, folder_tmp.dir, import_tmp.dir);

    const engine = try snapshot_open.open(arena, io, import_tmp.dir);
    try std.testing.expectEqualStrings("analyzer-v2", engine.analyzer_id);

    // The same chunks through the ASCII door: what the app gets today.
    const json_ascii = try folderIndexAndInterchange(arena, io, "../fixtures/tamil/passages", ascii_folder_tmp.dir, "ascii-alnum-v1");
    const ascii_report = try importer.importJson(ascii_tmp.dir, io, arena, json_ascii);
    try std.testing.expectEqual(@as(usize, 0), ascii_report.terms);

    const judgments_bytes = try readWhole(arena, io, std.Io.Dir.cwd(), "../fixtures/tamil/judgments.json");
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, judgments_bytes, .{});
    var judged: usize = 0;
    var hits_at_one: usize = 0;
    for (parsed.object.get("queries").?.array.items) |query_value| {
        const query_text = query_value.object.get("query").?.string;
        const relevant = query_value.object.get("relevant").?.array.items[0].object.get("path").?.string;
        // Judgments name paths relative to fixtures/tamil; the index root is passages/.
        const expected = relevant["passages/".len..];
        const scores = try arena.alloc(f32, engine.documents.len);
        const results_buffer = try arena.alloc(hybrid.Result, engine.documents.len);
        const results = try engine.queryTokenized(arena, query_text, &.{}, scores, results_buffer, .{
            .top_k = 10,
            .candidate_k = engine.documents.len,
            .retrieval_mode = .lexical,
        });
        judged += 1;
        if (results.len > 0 and std.mem.eql(u8, results[0].path, expected)) hits_at_one += 1;
    }
    std.debug.print("S2-T1 Tamil via import-json analyzer-v2: success@1 {d}/{d}\n", .{ hits_at_one, judged });
    try std.testing.expectEqual(@as(usize, 10), judged);
    try std.testing.expectEqual(judged, hits_at_one);
}

test "S2-T1: import-json with analyzer-v2 publishes the same bytes as searchd index on the app-text fixture" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var folder_tmp = std.testing.tmpDir(.{});
    defer folder_tmp.cleanup();
    var import_tmp = std.testing.tmpDir(.{});
    defer import_tmp.cleanup();

    const json_v2 = try folderIndexAndInterchange(arena, io, "../fixtures/app-text", folder_tmp.dir, "analyzer-v2");
    _ = try importer.importJson(import_tmp.dir, io, arena, json_v2);
    try expectSameSnapshotBytes(arena, io, folder_tmp.dir, import_tmp.dir);
}

test "S2-T1: import-json still rejects an analyzer id outside the contract's enum" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    inline for (.{ "v2", "analyzer-v1", "Analyzer-V2", "" }) |id| {
        try std.testing.expectError(error.UnsupportedAnalyzer, importer.importJson(
            tmp.dir,
            std.testing.io,
            std.testing.allocator,
            "{\"format_version\":1,\"generation\":1,\"analyzer_id\":\"" ++ id ++ "\",\"embedding_model_id\":\"none\",\"documents\":[]}",
        ));
    }
}
