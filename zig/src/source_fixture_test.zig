//! S3-T1 ruling 6 end to end over the frozen family-folder fixture
//! (`fixtures/family-folder/`, S3-T7): each root is indexed with
//! `indexer.indexFolder` (the source section on, the default), the
//! generation's source section is opened from disk, and
//! - every `read_span` judgment returns text whose sha256 and byte length
//!   equal the judgment's;
//! - every fixture file reads back whole, byte for byte (BOM aside), through
//!   `read_span` in pieces within the caps, and its retained sha256 is the
//!   file's;
//! - every `outline` judgment equals the core's outline;
//! - each document record points at its own file in the source section and
//!   names the chunker its extension selects;
//! and a generation without a source section answers `CAPACITY` "re-index
//! required: source absent".
const std = @import("std");
const chunker = @import("chunker.zig");
const hybrid = @import("hybrid.zig");
const importer = @import("importer.zig");
const incremental_state = @import("incremental_state.zig");
const indexer = @import("indexer.zig");
const manifest = @import("manifest.zig");
const snapshot_open = @import("snapshot_open.zig");
const scope = @import("scope.zig");
const source = @import("source.zig");

const pack = "../fixtures/family-folder";

fn readAll(arena: std.mem.Allocator, dir: std.Io.Dir, path: []const u8) ![]u8 {
    const io = std.testing.io;
    const stat = try dir.statFile(io, path, .{});
    const buffer = try arena.alloc(u8, std.math.cast(usize, stat.size) orelse return error.FileTooBig);
    return dir.readFile(io, path, buffer);
}

const IndexedRoot = struct {
    name: []const u8,
    source: source.Section,
    engine: @import("engine.zig").Engine,
    meta: manifest.Meta,
    metadata: manifest.Manifest,
};

fn indexRoot(arena: std.mem.Allocator, name: []const u8, out_dir: std.Io.Dir) !IndexedRoot {
    const io = std.testing.io;
    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ pack, name });
    var root = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer root.close(io);
    const report = try indexer.indexFolder(arena, io, root, out_dir, .v2, 1, chunker.default_max_chars, chunker.default_overlap_lines, .{});
    try std.testing.expectEqual(@as(usize, 0), report.unreadable);
    const opened = try snapshot_open.openSource(arena, io, out_dir);
    return .{
        .name = name,
        .source = opened.source.?,
        .engine = try snapshot_open.open(arena, io, out_dir),
        .meta = try manifest.parseMeta(arena, opened.metadata.meta),
        .metadata = opened.metadata,
    };
}

fn intOf(value: std.json.Value) u32 {
    return @intCast(value.integer);
}

test "S3-T1: read_span, outline and the source binding agree with the family-folder judgments" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const judgments_path = pack ++ "/judgments.json";
    const judgments = (try std.json.parseFromSliceLeaky(std.json.Value, arena, try readAll(arena, cwd, judgments_path), .{})).object;

    var temporaries: [3]std.testing.TmpDir = undefined;
    var roots: [3]IndexedRoot = undefined;
    for (judgments.get("roots").?.array.items, 0..) |root_value, index| {
        temporaries[index] = std.testing.tmpDir(.{ .iterate = true });
        roots[index] = try indexRoot(arena, root_value.string, temporaries[index].dir);
    }
    defer for (&temporaries) |*tmp| tmp.cleanup();

    const findRoot = struct {
        fn run(all: []IndexedRoot, name: []const u8) *IndexedRoot {
            for (all) |*root| if (std.mem.eql(u8, root.name, name)) return root;
            unreachable;
        }
    }.run;

    // read_span judgments: sha256 and byte length of the returned text.
    var spans_exact: usize = 0;
    for (judgments.get("read_span").?.array.items) |case_value| {
        const case = case_value.object;
        const root = findRoot(&roots, case.get("root_id").?.string);
        const result = try source.readSpan(arena, root.source, case.get("path").?.string, intOf(case.get("start_line").?), intOf(case.get("end_line").?), intOf(case.get("context_lines").?));
        const span = result.ok;
        const hex = std.fmt.bytesToHex(span.sha256, .lower);
        try std.testing.expectEqualStrings(case.get("sha256").?.string, &hex);
        try std.testing.expectEqual(@as(usize, intOf(case.get("byte_length").?)), span.text.len);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(span.text, &digest, .{});
        try std.testing.expectEqualSlices(u8, &span.sha256, &digest);
        spans_exact += 1;
    }
    try std.testing.expectEqual(@as(usize, 8), spans_exact);

    // Every file of every root reads back whole through read_span.
    var files_checked: usize = 0;
    var retained_bytes: usize = 0;
    for (&roots) |*root| {
        const root_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ pack, root.name });
        var dir = try cwd.openDir(io, root_path, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(arena);
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const disk = try readAll(arena, dir, entry.path);
            const retained = root.source.find(entry.path) orelse {
                std.debug.print("not retained: {s}/{s}\n", .{ root.name, entry.path });
                return error.TestUnexpectedResult;
            };
            try std.testing.expectEqualSlices(u8, disk, retained.bytes);
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(disk, &digest, .{});
            try std.testing.expectEqualSlices(u8, &digest, &retained.sha256);
            var rebuilt = std.ArrayList(u8).empty;
            var line: u32 = 1;
            while (line <= retained.line_count) {
                var count: u32 = @min(400, retained.line_count - line + 1);
                const span = while (true) {
                    switch (try source.readSpan(arena, root.source, entry.path, line, line + count - 1, 0)) {
                        .ok => |value| break value,
                        .failed => |failure| {
                            try std.testing.expectEqual(source.Code.capacity, failure.code);
                            count = @max(1, count / 2);
                        },
                    }
                };
                try rebuilt.appendSlice(arena, span.text);
                line += count;
            }
            const body = if (std.mem.startsWith(u8, disk, "\xef\xbb\xbf")) disk[3..] else disk;
            try std.testing.expectEqualSlices(u8, body, rebuilt.items);
            files_checked += 1;
            retained_bytes += disk.len;
        }
    }
    try std.testing.expect(files_checked >= 40);

    // Outline judgments.
    var outlines_exact: usize = 0;
    for (judgments.get("outline").?.array.items) |case_value| {
        const case = case_value.object;
        const root = findRoot(&roots, case.get("root_id").?.string);
        const data = (try source.outline(arena, root.source, case.get("path").?.string)).ok;
        try std.testing.expectEqualStrings(case.get("chunker").?.string, data.chunker.id());
        try std.testing.expectEqual(intOf(case.get("lines").?), data.lines);
        const markdown = data.markdown.?;
        const headings = case.get("headings").?.array.items;
        try std.testing.expectEqual(headings.len, markdown.headings.len);
        for (headings, markdown.headings) |expected_value, heading| {
            const expected = expected_value.object;
            try std.testing.expectEqual(intOf(expected.get("level").?), heading.level);
            try std.testing.expectEqualStrings(expected.get("text").?.string, heading.text);
            try std.testing.expectEqual(intOf(expected.get("line").?), heading.line);
            try std.testing.expectEqual(intOf(expected.get("end_line").?), heading.end_line);
        }
        switch (case.get("front_matter").?) {
            .null => try std.testing.expect(markdown.front_matter == null),
            .object => |front| {
                const mine = markdown.front_matter.?;
                try std.testing.expectEqual(intOf(front.get("start_line").?), @as(u32, @intCast(mine.start + 1)));
                try std.testing.expectEqual(intOf(front.get("end_line").?), @as(u32, @intCast(mine.end + 1)));
                const fields = front.get("fields").?.object;
                try std.testing.expectEqual(fields.count(), mine.fields.len);
                for (mine.fields) |field| try std.testing.expectEqualStrings(fields.get(field.key).?.string, field.value);
            },
            else => return error.UnexpectedJudgmentShape,
        }
        outlines_exact += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), outlines_exact);

    // Every record points at its own file and names its chunker.
    var line_window_chunks: usize = 0;
    var markdown_chunks: usize = 0;
    for (&roots) |*root| {
        try std.testing.expectEqualStrings(indexer.legacy_root_id, root.meta.roots[0].root_id);
        for (root.engine.documents) |document| {
            try std.testing.expect(document.source_doc_index < root.source.file_count);
            try std.testing.expectEqualStrings(document.path, root.source.file(document.source_doc_index).path);
            const id = root.meta.chunkerId(document.chunker_index).?;
            try std.testing.expectEqualStrings(chunker.kindForPath(document.path).id(), id);
            if (document.chunker_index == 0) line_window_chunks += 1 else markdown_chunks += 1;
        }
    }
    std.debug.print(
        "S3-T1 family-folder: {d} read_span exact, {d} outlines exact, {d} files read back whole ({d} bytes retained); chunks line-window-v1 {d}, md-section-v1 {d}\n",
        .{ spans_exact, outlines_exact, files_checked, retained_bytes, line_window_chunks, markdown_chunks },
    );
}

test "S3-T1: without a source section read_span and outline answer CAPACITY source absent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    // A generation written with retention off: v2 manifest, no source.
    var root_tmp = std.testing.tmpDir(.{ .iterate = true });
    defer root_tmp.cleanup();
    try root_tmp.dir.writeFile(io, .{ .sub_path = "week.md", .data = "# Week\n\nspelling test on Friday\n" });
    var out_tmp = std.testing.tmpDir(.{ .iterate = true });
    defer out_tmp.cleanup();
    _ = try indexer.indexFolder(arena, io, root_tmp.dir, out_tmp.dir, .v2, 1, chunker.default_max_chars, chunker.default_overlap_lines, .{ .retain_source = false });
    const without = try snapshot_open.openSource(arena, io, out_tmp.dir);
    try std.testing.expectEqual(@as(u16, 2), without.metadata.format_version);
    try std.testing.expect(without.source == null);
    const engine = try snapshot_open.open(arena, io, out_tmp.dir);
    try std.testing.expectEqual(hybrid.no_source_doc, engine.documents[0].source_doc_index);
    try std.testing.expectEqualStrings("Week", engine.documents[0].section_path);
    const span = (try source.readSpan(arena, without.source, "week.md", 1, 1, 0)).failed;
    try std.testing.expectEqual(source.Code.capacity, span.code);
    try std.testing.expectEqualStrings("re-index required: source absent", span.message);
    try std.testing.expectEqualStrings("re-index required: source absent", (try source.outline(arena, without.source, "week.md")).failed.message);

    // A legacy v1 manifest (import-json) opens and answers the same.
    var legacy_tmp = std.testing.tmpDir(.{ .iterate = true });
    defer legacy_tmp.cleanup();
    _ = try importer.importJson(legacy_tmp.dir, io, arena,
        \\{"format_version":1,"generation":1,"analyzer_id":"analyzer-v2","embedding_model_id":"none","documents":[{"id":"a","path":"a.md","start_line":1,"end_line":1,"text":"alpha","vector":[],"required_labels":[]}]}
    );
    const legacy = try snapshot_open.openSource(arena, io, legacy_tmp.dir);
    try std.testing.expectEqual(@as(u16, 1), legacy.metadata.format_version);
    try std.testing.expect(legacy.source == null);
    try std.testing.expectEqual(source.Code.capacity, (try source.readSpan(arena, legacy.source, "a.md", 1, 1, 0)).failed.code);
}

test "S3-T1: --update carries retained bytes and re-chunks Markdown written by line windows" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var root_tmp = std.testing.tmpDir(.{ .iterate = true });
    defer root_tmp.cleanup();
    const note = "# Week 7\n\n## Dates\n\nband concert Friday\r\n";
    const plain = "one\ntwo\n";
    try root_tmp.dir.writeFile(io, .{ .sub_path = "week.md", .data = note });
    try root_tmp.dir.writeFile(io, .{ .sub_path = "list.txt", .data = plain });

    // A pre-S3 generation: a v1 manifest and v3 records whose Markdown file
    // was chunked by line windows, plus the INDEX-STATE.json that run wrote.
    var out_tmp = std.testing.tmpDir(.{ .iterate = true });
    defer out_tmp.cleanup();
    var week_id: [20]u8 = undefined;
    chunker.chunkId(&week_id, "week.md", 1, 5, "# Week 7\n\n## Dates\n\nband concert Friday");
    var list_id: [20]u8 = undefined;
    chunker.chunkId(&list_id, "list.txt", 1, 2, "one\ntwo");
    const payload = try std.fmt.allocPrint(arena,
        \\{{"format_version":1,"generation":1,"analyzer_id":"analyzer-v2","embedding_model_id":"none","documents":[
        \\{{"id":"{s}","path":"list.txt","start_line":1,"end_line":2,"text":"one\ntwo","vector":[],"required_labels":[]}},
        \\{{"id":"{s}","path":"week.md","start_line":1,"end_line":5,"text":"# Week 7\n\n## Dates\n\nband concert Friday","vector":[],"required_labels":[]}}]}}
    , .{ &list_id, &week_id });
    _ = try importer.importJson(out_tmp.dir, io, arena, payload);
    var note_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(note, &note_digest, .{});
    var plain_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(plain, &plain_digest, .{});
    const note_hex = std.fmt.bytesToHex(note_digest, .lower);
    const plain_hex = std.fmt.bytesToHex(plain_digest, .lower);
    try incremental_state.save(io, out_tmp.dir, arena, .{ .generation = 1, .analyzer_id = "analyzer-v2", .files = &.{
        .{ .path = "list.txt", .hash = &plain_hex, .size = plain.len },
        .{ .path = "week.md", .hash = &note_hex, .size = note.len },
    } });

    const report = try indexer.indexFolderIncremental(arena, io, root_tmp.dir, out_tmp.dir, .v2, chunker.default_max_chars, chunker.default_overlap_lines, .{});
    try std.testing.expectEqual(@as(u64, 2), report.generation);
    try std.testing.expectEqual(@as(usize, 1), report.unchanged); // list.txt: same bytes, same chunker
    try std.testing.expectEqual(@as(usize, 1), report.changed); // week.md: same bytes, chunker changed
    const opened = try snapshot_open.openSource(arena, io, out_tmp.dir);
    const section = opened.source.?;
    const engine = try snapshot_open.open(arena, io, out_tmp.dir);
    var saw_dates = false;
    for (engine.documents) |document| {
        try std.testing.expectEqualStrings(document.path, section.file(document.source_doc_index).path);
        if (std.mem.eql(u8, document.section_path, "Week 7\x1fDates")) saw_dates = true;
    }
    try std.testing.expect(saw_dates);
    try std.testing.expectEqualStrings("band concert Friday\r\n", (try source.readSpan(arena, section, "week.md", 5, 5, 0)).ok.text);

    // A third run with nothing changed carries everything, bytes included.
    const again = try indexer.indexFolderIncremental(arena, io, root_tmp.dir, out_tmp.dir, .v2, chunker.default_max_chars, chunker.default_overlap_lines, .{});
    try std.testing.expectEqual(@as(usize, 2), again.unchanged);
    const third = (try snapshot_open.openSource(arena, io, out_tmp.dir)).source.?;
    try std.testing.expectEqualStrings(plain, third.find("list.txt").?.bytes);
    try std.testing.expectEqualStrings(note, third.find("week.md").?.bytes);
}

test "S3-T1/S3-T4: a lost source section fails only read_span and outline (CAPACITY); --update heals it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var root_tmp = std.testing.tmpDir(.{ .iterate = true });
    defer root_tmp.cleanup();
    try root_tmp.dir.writeFile(io, .{ .sub_path = "a.md", .data = "# A\nalpha\n" });
    var out_tmp = std.testing.tmpDir(.{ .iterate = true });
    defer out_tmp.cleanup();
    _ = try indexer.indexFolderIncremental(arena, io, root_tmp.dir, out_tmp.dir, .v2, chunker.default_max_chars, chunker.default_overlap_lines, .{});
    try out_tmp.dir.deleteFile(io, "source-1.hybsrc");
    // S3-T4 (S3-T1 finding 2): `query` never reads the source section, so it
    // works without it; only the source-reading operations answer CAPACITY.
    const engine = try snapshot_open.open(arena, io, out_tmp.dir);
    var results: [4]@import("hybrid.zig").Result = undefined;
    const found = try engine.queryTokenized(arena, "alpha", &.{}, &results, .{ .retrieval_mode = .lexical, .top_k = 4 });
    try std.testing.expectEqual(@as(usize, 1), found.len);
    const scoped_open = try snapshot_open.openScoped(arena, io, out_tmp.dir);
    // S4-T1: a lost file is known at open (the open opens, not reads, it).
    try std.testing.expectEqual(scope.SourceState.unavailable, scoped_open.folder.sourceState());
    try std.testing.expectEqualStrings("FileNotFound", scoped_open.folder.sourceError().?);
    const service_module = @import("service.zig");
    const scoped = service_module.ScopedService{ .service = .{ .engine = scoped_open.engine, .folder = scoped_open.folder } };
    const span = (try scoped.readSpan(arena, .{}, "r-legacy", "a.md", 1, 1, 0)).failed;
    try std.testing.expectEqual(source.Code.capacity, span.code);
    try std.testing.expectEqualStrings("re-index required: source section unavailable (FileNotFound)", span.message);
    try std.testing.expectEqual(source.Code.capacity, (try scoped.outline(arena, .{}, "r-legacy", "a.md")).failed.code);
    try std.testing.expectEqual(source.Code.capacity, (try scoped.readSpan(arena, .{}, "r-legacy", "unknown.md", 1, 1, 0)).failed.code);
    switch (try scoped.find(arena, .{ .query = "alpha" }, .{})) {
        .ok => |answer| try std.testing.expectEqual(@as(usize, 1), answer.hits.len),
        .failed => return error.TestUnexpectedResult,
    }
    const status = try scoped.indexStatus(arena, .{});
    try std.testing.expect(!status.has_source);
    try std.testing.expectEqualStrings("unavailable", status.source);
    // A damaged (not lost) section reads the same way, but only from the
    // first operation that reads it (S4-T1, a lazy open): the open and
    // `index_status` succeed and say `unverified`.
    try out_tmp.dir.writeFile(io, .{ .sub_path = "source-1.hybsrc", .data = "HYBSRC01 damaged" });
    const damaged = try snapshot_open.openScoped(arena, io, out_tmp.dir);
    defer damaged.folder.close();
    try std.testing.expectEqual(scope.SourceState.unverified, damaged.folder.sourceState());
    const damaged_service = service_module.ScopedService{ .service = .{ .engine = damaged.engine, .folder = damaged.folder } };
    const before_read = try damaged_service.indexStatus(arena, .{});
    try std.testing.expectEqualStrings("unverified", before_read.source);
    try std.testing.expect(before_read.has_source);
    const damaged_span = (try damaged_service.readSpan(arena, .{}, "r-legacy", "a.md", 1, 1, 0)).failed;
    try std.testing.expectEqual(source.Code.capacity, damaged_span.code);
    try std.testing.expectEqualStrings("re-index required: source section unavailable (SourceSectionSizeMismatch)", damaged_span.message);
    try std.testing.expectEqual(scope.SourceState.unavailable, damaged.folder.sourceState());
    const after_read = try damaged_service.indexStatus(arena, .{});
    try std.testing.expectEqualStrings("unavailable", after_read.source);
    try std.testing.expect(!after_read.has_source);
    try std.testing.expect((try damaged.folder.sourceSection()) == null);
    try std.testing.expect(damaged.folder.sourceError() != null);
    try out_tmp.dir.deleteFile(io, "source-1.hybsrc");
    const healed = try indexer.indexFolderIncremental(arena, io, root_tmp.dir, out_tmp.dir, .v2, chunker.default_max_chars, chunker.default_overlap_lines, .{});
    try std.testing.expectEqualStrings("missing_section", healed.recovered.?);
    try std.testing.expectEqual(@as(usize, 1), healed.added);
    const section = (try snapshot_open.openSource(arena, io, out_tmp.dir)).source.?;
    try std.testing.expectEqualStrings("# A\nalpha\n", section.find("a.md").?.bytes);
}
