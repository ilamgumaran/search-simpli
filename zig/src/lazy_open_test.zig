//! S4-T1 ruling 1: a lazy scoped open. `snapshot_open.openScoped` (and so
//! `ss_open`, `searchd serve`/`mcp` and the CLI's scoped commands) loads
//! what `index_status` needs; the source section, the statistics groups and
//! the position tables load at first use, once per opened generation, and
//! a second caller during a load waits for it.
//!
//! S4-T2 R4: so do the v2.2 filename sections. The scoped open reads
//! neither; the first filename or both query reads, checks and decodes both
//! once per opened generation.
const std = @import("std");
const checksum = @import("checksum.zig");
const filename_field = @import("filename_field.zig");
const chunker = @import("chunker.zig");
const find_module = @import("find.zig");
const indexer = @import("indexer.zig");
const lexical_segment = @import("lexical_segment.zig");
const manifest = @import("manifest.zig");
const publication = @import("publication.zig");
const scope = @import("scope.zig");
const service_module = @import("service.zig");
const snapshot_open = @import("snapshot_open.zig");
const source = @import("source.zig");

const io = std.testing.io;

test "lazy source rejects appended and truncated bytes on its pinned handle" {
    for ([_]bool{ false, true }) |append| {
        var indexed = try Indexed.init();
        defer indexed.deinit();
        const a = indexed.arena();
        const dir = indexed.out_tmp.dir;
        const metadata = try manifest.decode(try dir.readFileAlloc(io, publication.current_manifest_file, a, .unlimited));
        const bytes = try dir.readFileAlloc(io, metadata.source_file, a, .unlimited);
        const opened = try snapshot_open.openScoped(a, io, dir);
        defer opened.folder.close();
        const scoped = service_module.ScopedService{ .service = .{ .engine = opened.engine, .folder = opened.folder } };
        try std.testing.expectEqualStrings("unverified", (try scoped.indexStatus(a, .{})).source);
        const damaged = if (append) try std.mem.concat(a, u8, &.{ bytes, "EXTRA-BYTES" }) else bytes[0 .. bytes.len - 1];
        try dir.writeFile(io, .{ .sub_path = metadata.source_file, .data = damaged });
        const result = try scoped.readSpan(a, .{}, "r-legacy", "week.md", 1, 1, 0);
        try std.testing.expect(result == .failed);
        try std.testing.expectEqualStrings("unavailable", (try scoped.indexStatus(a, .{})).source);
        try std.testing.expectEqualStrings("SourceSectionSizeMismatch", opened.folder.sourceError().?);
        // Retained-source damage does not disable token/position retrieval.
        try std.testing.expect((try scoped.find(a, .{ .query = "tide" }, .{})).ok.hits.len > 0);
    }
}

const Indexed = struct {
    arena_state: std.heap.ArenaAllocator,
    folder_tmp: std.testing.TmpDir,
    out_tmp: std.testing.TmpDir,

    fn init() !Indexed {
        return initWith(.{});
    }

    fn initWith(caps: indexer.Caps) !Indexed {
        var indexed = Indexed{
            .arena_state = std.heap.ArenaAllocator.init(std.testing.allocator),
            .folder_tmp = std.testing.tmpDir(.{ .iterate = true }),
            .out_tmp = std.testing.tmpDir(.{ .iterate = true }),
        };
        errdefer indexed.deinit();
        try indexed.folder_tmp.dir.writeFile(io, .{ .sub_path = "week.md", .data = "# Week\n\nThe tide table for the harbour walk.\n\n## Friday\n\nBring the blue folder.\n" });
        try indexed.folder_tmp.dir.writeFile(io, .{ .sub_path = "list.txt", .data = "flour\neggs\nthe blue folder\n" });
        _ = try indexer.indexFolderIncremental(indexed.arena(), io, indexed.folder_tmp.dir, indexed.out_tmp.dir, .v2, chunker.default_max_chars, chunker.default_overlap_lines, caps);
        return indexed;
    }

    fn deinit(indexed: *Indexed) void {
        indexed.out_tmp.cleanup();
        indexed.folder_tmp.cleanup();
        indexed.arena_state.deinit();
    }

    fn arena(indexed: *Indexed) std.mem.Allocator {
        return indexed.arena_state.allocator();
    }
};

test "S4-T1: the scoped open defers the source, the statistics and the position tables to their first use" {
    var indexed = try Indexed.init();
    defer indexed.deinit();
    const a = indexed.arena();
    const opened = try snapshot_open.openScoped(a, io, indexed.out_tmp.dir);
    defer opened.folder.close();
    const loads = opened.folder.loads;
    const scoped = service_module.ScopedService{ .service = .{ .engine = opened.engine, .folder = opened.folder } };

    // After the open: nothing loaded, and index_status loads nothing.
    try std.testing.expectEqual(scope.SourceState.unverified, opened.folder.sourceState());
    try std.testing.expect(opened.folder.loadedStatistics() == null);
    try std.testing.expect(opened.engine.statistics == null and opened.engine.position_tables == null);
    const status = try scoped.indexStatus(a, .{});
    try std.testing.expectEqualStrings("unverified", status.source);
    try std.testing.expect(status.has_source);
    try std.testing.expectEqual(@as(usize, 2), status.files);
    try std.testing.expectEqual(@as(u32, 0), loads.source_loads + loads.statistics_loads + loads.positions_loads);

    // The first find builds the statistics and the position tables, not the source.
    switch (try scoped.find(a, .{ .query = "blue folder", .mode = .phrase }, .{})) {
        .ok => |answer| try std.testing.expectEqual(@as(usize, 2), answer.hits.len),
        .failed => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(u32, 1), loads.statistics_loads);
    try std.testing.expectEqual(@as(u32, 1), loads.positions_loads);
    try std.testing.expectEqual(@as(u32, 0), loads.source_loads);
    try std.testing.expectEqual(scope.SourceState.unverified, opened.folder.sourceState());

    // The first read_span loads and verifies the source; later calls reuse everything.
    const span = (try scoped.readSpan(a, .{}, "r-legacy", "week.md", 3, 3, 0)).ok;
    try std.testing.expectEqualStrings("The tide table for the harbour walk.\n", span.text);
    try std.testing.expectEqual(scope.SourceState.verified, opened.folder.sourceState());
    try std.testing.expectEqualStrings("verified", (try scoped.indexStatus(a, .{})).source);
    _ = try scoped.outline(a, .{}, "r-legacy", "week.md");
    _ = try scoped.find(a, .{ .query = "tide" }, .{});
    _ = try scoped.searchKnowledge(a, "harbour", &.{}, .{ .retrieval_mode = .lexical }, .{}, try a.alloc(@import("hybrid.zig").Result, 4), try a.alloc(@import("engine.zig").Evidence, 4), null);
    try std.testing.expectEqual(@as(u32, 1), loads.source_loads);
    try std.testing.expectEqual(@as(u32, 1), loads.statistics_loads);
    try std.testing.expectEqual(@as(u32, 1), loads.positions_loads);
}

test "S4-T1: the lazy open answers every operation exactly as the eager open did" {
    var indexed = try Indexed.init();
    defer indexed.deinit();
    const a = indexed.arena();
    const lazy = try snapshot_open.openScoped(a, io, indexed.out_tmp.dir);
    defer lazy.folder.close();
    const eager_engine = try snapshot_open.open(a, io, indexed.out_tmp.dir);
    const scoped = service_module.ScopedService{ .service = .{ .engine = lazy.engine, .folder = lazy.folder } };
    // `find` over the lazy service equals `find` over the eagerly opened
    // engine (positions validated and tables built at open).
    for ([_]find_module.Mode{ .words, .phrase, .prefix }) |mode| {
        const query: []const u8 = if (mode == .prefix) "fold*" else "blue folder";
        const from_lazy = (try scoped.find(a, .{ .query = query, .mode = mode }, .{})).ok;
        const from_eager = (try find_module.find(a, eager_engine, .{ .query = query, .mode = mode })).ok;
        try std.testing.expectEqual(from_eager.hits.len, from_lazy.hits.len);
        for (from_eager.hits, from_lazy.hits) |e, l| {
            try std.testing.expectEqualStrings(e.chunk_id, l.chunk_id);
            try std.testing.expectEqual(e.score, l.score);
            try std.testing.expectEqualStrings(e.snippet, l.snippet);
        }
    }
    const section = (try snapshot_open.openSource(a, io, indexed.out_tmp.dir)).source.?;
    const lazy_section = (try lazy.folder.sourceSection()).?;
    try std.testing.expectEqualSlices(u8, section.encoded, lazy_section.encoded);
}

const Racer = struct {
    folder: *const scope.Folder,
    sections: [*]?source.Section,
    statistics: [*]*const scope.Statistics,
    catalogs: [*][*]const @import("hybrid.zig").Document,
    failed: *std.atomic.Value(bool),

    fn run(racer: Racer, slot: usize) void {
        // Half the threads start with the filename load (S4-T2 R4).
        if (slot % 2 == 0) racer.catalogs[slot] = (racer.folder.filenameDecoded() catch return racer.failed.store(true, .release)).catalog.ptr;
        racer.sections[slot] = racer.folder.sourceSection() catch return racer.failed.store(true, .release);
        racer.statistics[slot] = racer.folder.statistics() catch return racer.failed.store(true, .release);
        _ = racer.folder.positionTables() catch return racer.failed.store(true, .release);
        if (slot % 2 == 1) racer.catalogs[slot] = (racer.folder.filenameDecoded() catch return racer.failed.store(true, .release)).catalog.ptr;
    }
};

test "S4-T1: concurrent first uses load each table once and see the same tables" {
    var indexed = try Indexed.initWith(.{ .filename_index = true });
    defer indexed.deinit();
    const a = indexed.arena();
    const opened = try snapshot_open.openScoped(a, io, indexed.out_tmp.dir);
    defer opened.folder.close();
    const thread_count = 8;
    var sections: [thread_count]?source.Section = undefined;
    var statistics: [thread_count]*const scope.Statistics = undefined;
    var catalogs: [thread_count][*]const @import("hybrid.zig").Document = undefined;
    var failed = std.atomic.Value(bool).init(false);
    const racer = Racer{ .folder = opened.folder, .sections = &sections, .statistics = &statistics, .catalogs = &catalogs, .failed = &failed };
    var threads: [thread_count]std.Thread = undefined;
    for (&threads, 0..) |*thread, slot| thread.* = try std.Thread.spawn(.{}, Racer.run, .{ racer, slot });
    for (threads) |thread| thread.join();
    try std.testing.expect(!failed.load(.acquire));
    const loads = opened.folder.loads;
    try std.testing.expectEqual(@as(u32, 1), loads.source_loads);
    try std.testing.expectEqual(@as(u32, 1), loads.statistics_loads);
    try std.testing.expectEqual(@as(u32, 1), loads.positions_loads);
    try std.testing.expectEqual(@as(u32, 1), loads.filename_loads);
    for (sections, statistics, catalogs) |section, stats, catalog| {
        try std.testing.expectEqual(sections[0].?.encoded.ptr, section.?.encoded.ptr);
        try std.testing.expectEqual(statistics[0], stats);
        try std.testing.expectEqual(catalogs[0], catalog);
    }
}

const lexical_options = @import("hybrid.zig").SearchOptions{ .retrieval_mode = .lexical, .top_k = 5, .candidate_k = 10 };

test "S4-T2 R4: the scoped open reads neither filename section; the first filename query loads both once" {
    var indexed = try Indexed.initWith(.{ .filename_index = true });
    defer indexed.deinit();
    const a = indexed.arena();
    const opened = try snapshot_open.openScoped(a, io, indexed.out_tmp.dir);
    defer opened.folder.close();
    const loads = opened.folder.loads;
    const scoped = service_module.ScopedService{ .service = .{ .engine = opened.engine, .folder = opened.folder } };
    // The policy comes from the manifest; nothing is loaded at the open, by
    // index_status or by a content query.
    try std.testing.expect(opened.engine.filename_index_enabled);
    try std.testing.expectEqualStrings(filename_field.policy_id, opened.engine.filename_policy_id);
    try std.testing.expect(opened.engine.filename_decoded == null);
    _ = try scoped.indexStatus(a, .{});
    try std.testing.expect((try opened.engine.queryFields(a, "harbour", .content, lexical_options)).len > 0);
    try std.testing.expect(!opened.folder.filenameLoaded());
    try std.testing.expectEqual(@as(u32, 0), loads.filename_loads);
    // The first filename query loads both sections; both reuses them.
    const named = try opened.engine.queryFields(a, "week", .filename, lexical_options);
    try std.testing.expectEqual(@as(usize, 1), named.len);
    try std.testing.expectEqualStrings("week.md", opened.engine.documents[named[0].document_index].path);
    try std.testing.expect((try opened.engine.queryFields(a, "list harbour", .both, lexical_options)).len == 2);
    try std.testing.expectEqual(@as(u32, 1), loads.filename_loads);
    // The eager one-shot open answers the same.
    const eager = try snapshot_open.open(a, io, indexed.out_tmp.dir);
    const eager_named = try eager.queryFields(a, "week", .filename, lexical_options);
    try std.testing.expectEqual(named[0].document_index, eager_named[0].document_index);
    try std.testing.expectEqual(named[0].filename_score, eager_named[0].filename_score);
}

test "S4-T2 R4: a damaged filename catalog opens, fails the first filename query with its error, content still answers" {
    var indexed = try Indexed.initWith(.{ .filename_index = true });
    defer indexed.deinit();
    const a = indexed.arena();
    const dir = indexed.out_tmp.dir;
    const metadata = try manifest.decode(try dir.readFileAlloc(io, publication.current_manifest_file, a, .unlimited));
    const catalog_bytes = try dir.readFileAlloc(io, metadata.filename.?.catalog_file, a, .unlimited);
    catalog_bytes[catalog_bytes.len - 2] ^= 0x01;
    try dir.writeFile(io, .{ .sub_path = metadata.filename.?.catalog_file, .data = catalog_bytes });

    const opened = try snapshot_open.openScoped(a, io, dir);
    defer opened.folder.close();
    const scoped = service_module.ScopedService{ .service = .{ .engine = opened.engine, .folder = opened.folder } };
    try std.testing.expectEqual(@as(usize, 2), (try scoped.indexStatus(a, .{})).files);
    try std.testing.expectError(error.FilenameCatalogChecksumMismatch, opened.engine.queryFields(a, "week", .filename, lexical_options));
    // Final for this opened generation, for both as well.
    try std.testing.expectError(error.FilenameCatalogChecksumMismatch, opened.engine.queryFields(a, "week", .both, lexical_options));
    try std.testing.expectEqual(@as(u32, 1), opened.folder.loads.filename_loads);
    // Content queries, find and read_span never read the filename sections.
    try std.testing.expect((try opened.engine.queryFields(a, "harbour", .content, lexical_options)).len > 0);
    try std.testing.expect((try scoped.find(a, .{ .query = "tide" }, .{})).ok.hits.len > 0);
    try std.testing.expect((try scoped.readSpan(a, .{}, "r-legacy", "week.md", 3, 3, 0)) == .ok);
    // The eager one-shot open refuses it at once.
    try std.testing.expectError(error.FilenameCatalogChecksumMismatch, snapshot_open.open(a, io, dir));
}

test "S4-T2 R4: writers run the full filename check before publishing; readers check checksums and structure" {
    var indexed = try Indexed.initWith(.{ .filename_index = true });
    defer indexed.deinit();
    const a = indexed.arena();
    const dir = indexed.out_tmp.dir;
    var metadata = try manifest.decode(try dir.readFileAlloc(io, publication.current_manifest_file, a, .unlimited));
    const f = metadata.filename.?;
    const catalog = try dir.readFileAlloc(io, f.catalog_file, a, .unlimited);
    const lexical = try dir.readFileAlloc(io, f.lexical_file, a, .unlimited);
    const eager = try snapshot_open.open(a, io, dir);
    try filename_field.validate(a, eager.documents, catalog, lexical, eager.analyzer_id);
    // A dictionary term that no name tokenizes to, resealed so only the
    // full check can see it: "week" becomes "wees".
    const kind = (try lexical_segment.inspect(lexical)).checksum_kind;
    const at = std.mem.indexOf(u8, lexical, "week").?;
    lexical[at + 3] = 's';
    const fixed = if (std.mem.eql(u8, lexical[0..8], lexical_segment.magic_v2)) lexical_segment.header_length_v2 else lexical_segment.header_length;
    const value = checksum.compute(kind, lexical[0 .. fixed - 8], lexical[fixed..]);
    std.mem.writeInt(u64, lexical[fixed - 8 ..][0..8], value, .little);
    try std.testing.expectError(error.FilenameLexicalMismatch, filename_field.validate(a, eager.documents, catalog, lexical, eager.analyzer_id));
    try dir.writeFile(io, .{ .sub_path = f.lexical_file, .data = lexical });
    metadata.filename.?.lexical_checksum = value;
    try writeManifest(a, dir, metadata);
    // The reader's load does not re-tokenize: it opens and answers by the
    // stored dictionary.
    const opened = try snapshot_open.openScoped(a, io, dir);
    defer opened.folder.close();
    try std.testing.expectEqual(@as(usize, 1), (try opened.engine.queryFields(a, "wees", .filename, lexical_options)).len);
}

/// Rewrite the current generation's lexical section with `edit` applied to
/// its bytes, restamp the section's own checksum and the manifest's record
/// of it, so only the structural rules can refuse the result.
fn rewriteLexical(a: std.mem.Allocator, dir: std.Io.Dir, edit: *const fn ([]u8, lexical_segment.Header) void) !void {
    const manifest_bytes = try dir.readFileAlloc(io, publication.current_manifest_file, a, .unlimited);
    var metadata = try manifest.decode(manifest_bytes);
    const lexical = try dir.readFileAlloc(io, metadata.lexical_file, a, .unlimited);
    const header = try lexical_segment.inspect(lexical);
    edit(lexical, header);
    const fixed = lexical_segment.header_length_v2;
    const value = checksum.compute(header.checksum_kind, lexical[0 .. fixed - 8], lexical[fixed..]);
    std.mem.writeInt(u64, lexical[fixed - 8 ..][0..8], value, .little);
    try dir.writeFile(io, .{ .sub_path = metadata.lexical_file, .data = lexical });
    metadata.lexical_checksum = value;
    try writeManifest(a, dir, metadata);
}

fn writeManifest(a: std.mem.Allocator, dir: std.Io.Dir, metadata: manifest.Manifest) !void {
    const encoded = try manifest.encode(metadata, try a.alloc(u8, try manifest.encodedLength(metadata)));
    try dir.writeFile(io, .{ .sub_path = publication.current_manifest_file, .data = encoded });
}

fn breakPositions(lexical: []u8, header: lexical_segment.Header) void {
    const start = lexical_segment.header_length_v2 + header.document_lengths_bytes + header.dictionary_bytes + header.postings_bytes;
    // Every byte a continuation byte: no ordinal varint ever ends.
    @memset(lexical[start .. start + header.positions_bytes], 0x80);
}

test "S4-T1: damaged positions open lazily and fail the first find with the eager open's error" {
    var indexed = try Indexed.init();
    defer indexed.deinit();
    const a = indexed.arena();
    try rewriteLexical(a, indexed.out_tmp.dir, &breakPositions);

    try std.testing.expectError(error.InvalidPositions, snapshot_open.open(a, io, indexed.out_tmp.dir));
    const opened = try snapshot_open.openScoped(a, io, indexed.out_tmp.dir);
    defer opened.folder.close();
    const scoped = service_module.ScopedService{ .service = .{ .engine = opened.engine, .folder = opened.folder } };
    try std.testing.expectEqual(@as(usize, 2), (try scoped.indexStatus(a, .{})).files);
    try std.testing.expectError(error.InvalidPositions, scoped.find(a, .{ .query = "blue folder", .mode = .phrase }, .{}));
    // Final for this opened generation: the second call fails the same way.
    try std.testing.expectError(error.InvalidPositions, scoped.find(a, .{ .query = "tide" }, .{}));
    try std.testing.expectEqual(@as(u32, 1), opened.folder.loads.positions_loads);
}

test "S4-T1: XXH3 sections are refused under a manifest that does not set flag_xxh3_sections" {
    var indexed = try Indexed.init();
    defer indexed.deinit();
    const a = indexed.arena();
    const dir = indexed.out_tmp.dir;
    const manifest_bytes = try dir.readFileAlloc(io, publication.current_manifest_file, a, .unlimited);
    var metadata = try manifest.decode(manifest_bytes);
    try std.testing.expect(metadata.xxh3_sections);
    try std.testing.expectEqual(checksum.Kind.xxh3_64, (try source.inspect(try dir.readFileAlloc(io, metadata.source_file, a, .unlimited))).checksum_kind);
    metadata.xxh3_sections = false;
    try writeManifest(a, dir, metadata);
    try std.testing.expectError(error.InvalidDocumentSection, snapshot_open.openScoped(a, io, dir));
    try std.testing.expectError(error.InvalidDocumentSection, snapshot_open.open(a, io, dir));
}
