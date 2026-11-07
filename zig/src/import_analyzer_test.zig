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
const lexical_segment = @import("lexical_segment.zig");
const chunker = @import("chunker.zig");
const hybrid = @import("hybrid.zig");
const importer = @import("importer.zig");
const indexer = @import("indexer.zig");
const manifest = @import("manifest.zig");
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

/// S3-T1 amendment: `searchd index` now publishes a v2 manifest, record-v4
/// documents and a source section, none of which interchange JSON v1 can
/// carry, while `import-json` keeps writing the v1 manifest and v3 records.
/// The two doors must still agree on everything interchange carries: the
/// lexical section byte for byte, every document's id, path, lines, text,
/// labels and vector, and the manifest's identities, counts, section names
/// and lexical checksum.
fn expectSameSnapshotBytes(arena: std.mem.Allocator, io: std.Io, folder_dir: std.Io.Dir, import_dir: std.Io.Dir) !void {
    const folder_lexical = try readWhole(arena, io, folder_dir, "lexical-1.hyblex");
    const import_lexical = try readWhole(arena, io, import_dir, "lexical-1.hyblex");
    // S3-T2: the folder door writes HYBLEX02 (positions), import-json
    // HYBLEX01 under its v1 manifest. Sections 1-3 (document lengths, the
    // sorted dictionary, postings) must still be equal byte for byte, as must
    // every header count and the average length.
    const folder_header = try lexical_segment.inspect(folder_lexical);
    const import_header = try lexical_segment.inspect(import_lexical);
    try std.testing.expect(folder_header.hasPositions());
    try std.testing.expect(!import_header.hasPositions());
    try std.testing.expectEqual(folder_header.document_count, import_header.document_count);
    try std.testing.expectEqual(folder_header.term_count, import_header.term_count);
    try std.testing.expectEqual(folder_header.posting_count, import_header.posting_count);
    try std.testing.expectEqual(folder_header.average_document_length, import_header.average_document_length);
    try std.testing.expectEqual(folder_header.dictionary_bytes, import_header.dictionary_bytes);
    const sections_bytes = folder_header.document_lengths_bytes + folder_header.dictionary_bytes + folder_header.postings_bytes;
    std.testing.expectEqualSlices(
        u8,
        folder_lexical[lexical_segment.header_length_v2..][0..sections_bytes],
        import_lexical[lexical_segment.header_length..][0..sections_bytes],
    ) catch |err| {
        std.debug.print("S2-T1: lexical sections 1-3 differ between searchd index and import-json\n", .{});
        return err;
    };

    const folder_manifest = try manifest.decode(try readWhole(arena, io, folder_dir, publication.current_manifest_file));
    const import_manifest = try manifest.decode(try readWhole(arena, io, import_dir, publication.current_manifest_file));
    try std.testing.expectEqual(@as(u16, 2), folder_manifest.format_version);
    try std.testing.expectEqual(@as(u16, 1), import_manifest.format_version);
    try std.testing.expectEqual(folder_manifest.generation, import_manifest.generation);
    try std.testing.expectEqualStrings(folder_manifest.analyzer_id, import_manifest.analyzer_id);
    try std.testing.expectEqualStrings(folder_manifest.embedding_model_id, import_manifest.embedding_model_id);
    try std.testing.expectEqualStrings(folder_manifest.documents_file, import_manifest.documents_file);
    try std.testing.expectEqualStrings(folder_manifest.lexical_file, import_manifest.lexical_file);
    try std.testing.expectEqual(folder_manifest.document_count, import_manifest.document_count);
    try std.testing.expectEqual(folder_manifest.term_count, import_manifest.term_count);
    try std.testing.expectEqual(folder_manifest.posting_count, import_manifest.posting_count);
    try std.testing.expect(folder_manifest.has_positions);
    try std.testing.expect(!import_manifest.has_positions);

    const folder_engine = try snapshot_open.open(arena, io, folder_dir);
    const import_engine = try snapshot_open.open(arena, io, import_dir);
    try std.testing.expectEqual(folder_engine.documents.len, import_engine.documents.len);
    for (folder_engine.documents, import_engine.documents) |left, right| {
        try std.testing.expectEqualStrings(left.id, right.id);
        try std.testing.expectEqualStrings(left.path, right.path);
        try std.testing.expectEqual(left.start_line, right.start_line);
        try std.testing.expectEqual(left.end_line, right.end_line);
        try std.testing.expectEqualStrings(left.text, right.text);
        try std.testing.expectEqualStrings(left.required_labels, right.required_labels);
        try std.testing.expectEqualSlices(f32, left.vector, right.vector);
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
        const results_buffer = try arena.alloc(hybrid.Result, engine.documents.len);
        const results = try engine.queryTokenized(arena, query_text, &.{}, results_buffer, .{
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

test "S1-T14: Tamil words absent from the corpus match nothing through either door (S5-T4: fold-groups-v1 off; on, only the plural of a held word)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var folder_tmp = std.testing.tmpDir(.{});
    defer folder_tmp.cleanup();
    var import_tmp = std.testing.tmpDir(.{});
    defer import_tmp.cleanup();

    const json_v2 = try folderIndexAndInterchange(arena, io, "../fixtures/tamil/passages", folder_tmp.dir, "analyzer-v2");
    _ = try importer.importJson(import_tmp.dir, io, arena, json_v2);
    const folder_engine = try snapshot_open.open(arena, io, folder_tmp.dir);
    const import_engine = try snapshot_open.open(arena, io, import_tmp.dir);

    const bytes = try readWhole(arena, io, std.Io.Dir.cwd(), "../fixtures/tamil-absent-judgments.json");
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
    const queries = parsed.object.get("queries").?.array.items;
    try std.testing.expect(queries.len >= 10);
    var total_hits: usize = 0;
    var folded_hits: usize = 0;
    inline for (.{ folder_engine, import_engine }) |engine| {
        for (queries) |query_value| {
            const query_text = query_value.object.get("query").?.string;
            const results_buffer = try arena.alloc(hybrid.Result, engine.documents.len);
            // S1-T14's property is the tokenizer's: no fragment of an absent
            // word matches. fold-groups-v1 is off for it.
            const results = try engine.queryTokenized(arena, query_text, &.{}, results_buffer, .{
                .top_k = 10,
                .candidate_k = engine.documents.len,
                .retrieval_mode = .lexical,
                .fold = false,
            });
            total_hits += results.len;
            if (results.len != 0) std.debug.print("absent query {s} matched {d} passages\n", .{ query_text, results.len });
            // S5-T4: with fold-groups-v1 on, the one "absent" word that is
            // the plural of a held word (யானைகள் -> யானை, T's rule 2)
            // finds the passage holding the singular; every other stays at 0.
            const folded = try engine.queryTokenized(arena, query_text, &.{}, results_buffer, .{
                .top_k = 10,
                .candidate_k = engine.documents.len,
                .retrieval_mode = .lexical,
            });
            folded_hits += folded.len;
            if (std.mem.eql(u8, query_text, "யானைகள்")) {
                try std.testing.expectEqual(@as(usize, 1), folded.len);
                try std.testing.expect(std.mem.endsWith(u8, engine.documents[folded[0].document_index].path, "passage-04-animals.md"));
            } else try std.testing.expectEqual(@as(usize, 0), folded.len);
        }
    }
    std.debug.print("S1-T14 absent Tamil queries: {d} queries x 2 doors, {d} hits; S5-T4 with fold-groups-v1 {d} hits (the plural of a held word)\n", .{ queries.len, total_hits, folded_hits });
    try std.testing.expectEqual(@as(usize, 0), total_hits);
}
