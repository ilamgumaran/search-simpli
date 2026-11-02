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
    const loaded = try loadEngine(allocator, io, dir, .{});
    var opened = loaded.engine;
    // S3-T2: one pass over sections 4 and 5, so `find` reads only its own
    // terms' ordinals and its hits' offsets.
    if (opened.lexical_index.positions != null) opened.position_tables = try postings.buildPositionTables(allocator, opened.lexical_index);
    return opened;
}

const Loaded = struct {
    engine: engine.Engine,
    metadata: manifest.Manifest,
};

/// The manifest and the document and lexical sections, each section's
/// checksum computed once (S4-T1; `publication.loadCurrent` followed by
/// `Engine.open` computed it three times), with every check of
/// `manifest.validateSnapshot` and `Engine.open`.
fn loadEngine(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, options: engine.Engine.OpenOptions) !Loaded {
    var manifest_file = try dir.openFile(io, publication.current_manifest_file, .{});
    const manifest_stat = try manifest_file.stat(io);
    manifest_file.close(io);
    const manifest_size = std.math.cast(usize, manifest_stat.size) orelse return error.IndexTooLarge;
    const manifest_buffer = try allocator.alloc(u8, manifest_size);
    const manifest_encoded = try dir.readFile(io, publication.current_manifest_file, manifest_buffer);
    const metadata = try manifest.decode(manifest_encoded);

    const documents_buffer = try allocator.alloc(u8, metadata.documents_bytes);
    const lexical_buffer = try allocator.alloc(u8, metadata.lexical_bytes);
    const snapshot = publication.LoadedSnapshot{
        .metadata = metadata,
        .manifest_encoded = manifest_encoded,
        .documents_encoded = try dir.readFile(io, metadata.documents_file, documents_buffer),
        .lexical_encoded = try dir.readFile(io, metadata.lexical_file, lexical_buffer),
    };
    // S3-T4 (S3-T1 finding 2): the source section is not read here, and a
    // lost or damaged one does not fail the open: `query`, `find` and every
    // other operation that never reads it keep working, and only the
    // source-reading operations (`read_span`, `outline`) answer `CAPACITY`
    // (`openSource` reports why). A writer still treats it as a missing
    // section and heals it (`index --update`, `apply_changes`).

    const documents = try allocator.alloc(hybrid.Document, metadata.document_count);
    const vector_count = std.math.mul(usize, metadata.document_count, metadata.vector_dimensions) catch
        return error.IndexTooLarge;
    const vectors = try allocator.alloc(f32, vector_count);
    const terms = try allocator.alloc(postings.TermEntry, metadata.term_count);
    const posting_storage = try allocator.alloc(postings.Posting, metadata.posting_count);
    const document_lengths = try allocator.alloc(u32, metadata.document_count);

    return .{
        .engine = try engine.Engine.openWith(snapshot, documents, vectors, terms, posting_storage, document_lengths, options),
        .metadata = metadata,
    };
}

/// The current generation's manifest and source section (S3-T1), validated
/// against the manifest and opened with a path index, or `source == null`
/// when the generation retains no source bytes (a v1 manifest or a v2
/// manifest without the flag): `read_span`/`outline` then answer
/// `CAPACITY` "re-index required: source absent". Buffers from `allocator`.
pub const OpenedSource = struct {
    metadata: manifest.Manifest,
    source: ?source_section.Section,
    /// S3-T4: the manifest binds a source section that could not be read
    /// or did not validate (a lost file, a wrong size, a bad checksum): the
    /// error's name. `source` is then null.
    source_error: ?[]const u8 = null,
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
    const bytes = (publication.loadSource(dir, io, metadata, buffer) catch |err|
        return .{ .metadata = metadata, .source = null, .source_error = @errorName(err) }).?;
    const section = source_section.openIndexed(allocator, bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{ .metadata = metadata, .source = null, .source_error = @errorName(err) },
    };
    return .{ .metadata = metadata, .source = section };
}

/// S3-T3: the current generation with its roots, pending files, source
/// section and visible-scope statistics (`scope.Folder`). For the scoped
/// operations of `service.ScopedService`. Everything from `allocator`.
///
/// S4-T1: a lazy open. It validates the manifest and the document and
/// lexical sections (each checksum once) and decodes what `index_status`
/// needs; the source section (opened here, read at first use), the
/// statistics groups and the position tables (with the validation of the
/// lexical section's positions and offsets) load at first use through
/// `folder.loads` (`scope.Loads`). The engine's `statistics` and
/// `position_tables` stay null: an operation that needs them asks the
/// folder (`service.zig`), and until then nothing reads the positions.
/// `folder.close()` releases the source section's file handle.
pub const Scoped = struct {
    engine: engine.Engine,
    folder: *scope.Folder,
};

pub fn openScoped(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !Scoped {
    const loaded = try loadEngine(allocator, io, dir, .{ .validate_positions = false });
    const opened_engine = loaded.engine;
    const metadata = loaded.metadata;
    const meta: ?manifest.Meta = if (metadata.meta.len != 0) try manifest.parseMeta(allocator, metadata.meta) else null;
    const loads = try allocator.create(scope.Loads);
    loads.* = .{
        .io = io,
        .allocator = allocator,
        .documents = opened_engine.documents,
        .index = opened_engine.lexical_index,
        .source_bytes = metadata.source_bytes,
        .source_checksum = metadata.source_checksum,
        .xxh3_sections = metadata.xxh3_sections,
    };
    if (metadata.hasSource()) {
        if (dir.openFile(io, metadata.source_file, .{})) |file| {
            loads.source_file = file;
        } else |err| {
            // A lost file is known now: the source is unavailable from the
            // start, exactly as a failed load would leave it.
            loads.source_error = @errorName(err);
            loads.source_done.store(true, .release);
        }
    } else {
        loads.source_done.store(true, .release);
    }
    errdefer if (loads.source_file) |file| file.close(io);
    const folder = try allocator.create(scope.Folder);
    folder.* = try scope.Folder.build(allocator, meta, loads);
    folder.has_positions = metadata.has_positions;
    folder.source_bound = metadata.hasSource();
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
