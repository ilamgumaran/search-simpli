//! Shared "open a published generation for querying" logic (S1-T1), factored
//! out of `main.zig`'s original `serveSnapshot` so the new `query`/`evidence`
//! CLI commands and the BM25 cross-language conformance test can open a
//! snapshot the same way `serve` always has, without duplicating the
//! manifest-decode/buffer-sizing boilerplate.
const std = @import("std");
const engine = @import("engine.zig");
const hybrid = @import("hybrid.zig");
const manifest = @import("manifest.zig");
const postings = @import("postings.zig");
const publication = @import("publication.zig");
const scope = @import("scope.zig");
const source_section = @import("source.zig");

/// Open the current published generation in `dir`. All returned buffers
/// (and the decoded `Engine`) are allocated from `allocator`; the intended
/// use is a one-shot CLI command or test with an arena, discarded wholesale.
pub fn open(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !engine.Engine {
    var manifest_file = try dir.openFile(io, publication.current_manifest_file, .{});
    const manifest_stat = try manifest_file.stat(io);
    manifest_file.close(io);
    const manifest_size = std.math.cast(usize, manifest_stat.size) orelse return error.IndexTooLarge;
    const manifest_buffer = try allocator.alloc(u8, manifest_size);
    const manifest_encoded = try dir.readFile(io, publication.current_manifest_file, manifest_buffer);
    const metadata = try manifest.decode(manifest_encoded);

    const documents_buffer = try allocator.alloc(u8, metadata.documents_bytes);
    const lexical_buffer = try allocator.alloc(u8, metadata.lexical_bytes);
    const snapshot = try publication.loadCurrent(dir, io, manifest_buffer, documents_buffer, lexical_buffer);
    // S3-T1: a generation that binds a source section is incomplete without
    // it. Only its presence and length are checked here (reading it is
    // `openSource`'s job), so a lost source file reads as a missing section
    // (`error.FileNotFound`), the same as a lost document or lexical file.
    if (metadata.hasSource()) {
        const stat = try dir.statFile(io, metadata.source_file, .{});
        if (stat.size != metadata.source_bytes) return error.SourceSectionSizeMismatch;
    }

    const documents = try allocator.alloc(hybrid.Document, metadata.document_count);
    const vector_count = std.math.mul(usize, metadata.document_count, metadata.vector_dimensions) catch
        return error.IndexTooLarge;
    const vectors = try allocator.alloc(f32, vector_count);
    const terms = try allocator.alloc(postings.TermEntry, metadata.term_count);
    const posting_storage = try allocator.alloc(postings.Posting, metadata.posting_count);
    const document_lengths = try allocator.alloc(u32, metadata.document_count);

    var opened = try engine.Engine.open(snapshot, documents, vectors, terms, posting_storage, document_lengths);
    // S3-T2: one pass over sections 4 and 5, so `find` reads only its own
    // terms' ordinals and its hits' offsets.
    if (opened.lexical_index.positions != null) opened.position_tables = try postings.buildPositionTables(allocator, opened.lexical_index);
    return opened;
}

/// The current generation's manifest and source section (S3-T1), validated
/// against the manifest and opened with a path index, or `source == null`
/// when the generation retains no source bytes (a v1 manifest or a v2
/// manifest without the flag): `read_span`/`outline` then answer
/// `CAPACITY` "re-index required: source absent". Buffers from `allocator`.
pub const OpenedSource = struct {
    metadata: manifest.Manifest,
    source: ?source_section.Section,
};

pub fn openSource(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !OpenedSource {
    var manifest_file = try dir.openFile(io, publication.current_manifest_file, .{});
    const manifest_stat = try manifest_file.stat(io);
    manifest_file.close(io);
    const manifest_size = std.math.cast(usize, manifest_stat.size) orelse return error.IndexTooLarge;
    const manifest_buffer = try allocator.alloc(u8, manifest_size);
    const manifest_encoded = try dir.readFile(io, publication.current_manifest_file, manifest_buffer);
    const metadata = try manifest.decode(manifest_encoded);
    if (!metadata.hasSource()) return .{ .metadata = metadata, .source = null };
    const buffer = try allocator.alloc(u8, metadata.source_bytes);
    const bytes = (try publication.loadSource(dir, io, metadata, buffer)).?;
    return .{ .metadata = metadata, .source = try source_section.openIndexed(allocator, bytes) };
}

/// S3-T3: the current generation with its roots, pending files, source
/// section and visible-scope statistics (`scope.Folder`), the engine's
/// `statistics` pointing at the folder's. For the scoped operations of
/// `service.ScopedService`. Everything from `allocator`.
pub const Scoped = struct {
    engine: engine.Engine,
    folder: *scope.Folder,
};

pub fn openScoped(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !Scoped {
    var opened_engine = try open(allocator, io, dir);
    const opened = try openSource(allocator, io, dir);
    const meta: ?manifest.Meta = if (opened.metadata.meta.len != 0) try manifest.parseMeta(allocator, opened.metadata.meta) else null;
    const folder = try allocator.create(scope.Folder);
    folder.* = try scope.Folder.build(allocator, opened_engine.documents, opened_engine.lexical_index, meta, opened.source);
    folder.has_positions = opened.metadata.has_positions;
    opened_engine.statistics = &folder.statistics;
    return .{ .engine = opened_engine, .folder = folder };
}

test "open reproduces a published demo generation" {
    const chunker = @import("chunker.zig");
    const indexer = @import("indexer.zig");

    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;

    try tmp.dir.writeFile(io, .{ .sub_path = "note.md", .data = "search evidence combines lexical and semantic ranks\n" });
    try tmp.dir.createDir(io, "out", .default_dir);
    var out_dir = try tmp.dir.openDir(io, "out", .{});
    defer out_dir.close(io);

    _ = try indexer.indexFolder(arena, io, tmp.dir, out_dir, .v2, 1, chunker.default_max_chars, chunker.default_overlap_lines, .{});

    const opened = try open(arena, io, out_dir);
    try std.testing.expectEqualStrings("analyzer-v2", opened.analyzer_id);
    try std.testing.expectEqual(@as(usize, 1), opened.documents.len);
}
