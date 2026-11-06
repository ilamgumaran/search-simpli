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
const filename_field = @import("filename_field.zig");

/// S4-T9: the two allocators of an open. `blocks` gives the exact blocks a
/// handle keeps (the open's, `OpenBlock`; later the source section's and the
/// filename sections' at their first use), each one allocation of the size
/// the manifest states, so none of them pays an arena's geometric growth;
/// `close` frees them. `arena` gives the rest (the parsed meta, the folder,
/// the per-load tables), released wholesale by the owner. A one-shot caller
/// passes one allocator for both (`Allocators.one`), usually an arena,
/// discarded wholesale with everything in it.
pub const Allocators = struct {
    blocks: std.mem.Allocator,
    arena: std.mem.Allocator,

    pub fn one(allocator: std.mem.Allocator) Allocators {
        return .{ .blocks = allocator, .arena = allocator };
    }
};

/// Open the current published generation in `dir`. All returned buffers
/// (and the decoded `Engine`) are allocated from `allocator`; the intended
/// use is a one-shot CLI command or test with an arena, discarded wholesale.
pub fn open(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !engine.Engine {
    const loaded = try loadEngine(.one(allocator), io, dir, .{});
    var opened = loaded.engine;
    if (loaded.metadata.meta.len != 0) opened.roots = (try manifest.parseMeta(allocator, loaded.metadata.meta)).roots;
    // The one-shot open is eager: it also loads the filename sections now
    // (`openScoped` defers them to the first filename query, S4-T2 R4).
    if (loaded.metadata.filename) |f| {
        const catalog_file = try dir.openFile(io, f.catalog_file, .{});
        defer catalog_file.close(io);
        const lexical_file = try dir.openFile(io, f.lexical_file, .{});
        defer lexical_file.close(io);
        var reserved = std.heap.FixedBufferAllocator.init(loaded.filename_reserved);
        opened.filename_decoded = filename_field.load(reserved.allocator(), io, catalog_file, lexical_file, loaded.metadata, opened.documents, opened.lexical_index) catch |err| switch (err) {
            error.OutOfMemory => try filename_field.load(allocator, io, catalog_file, lexical_file, loaded.metadata, opened.documents, opened.lexical_index),
            else => return err,
        };
    }
    // S3-T2: one pass over sections 4 and 5, so `find` reads only its own
    // terms' ordinals and its hits' offsets.
    if (opened.lexical_index.positions != null) opened.position_tables = try postings.buildPositionTables(allocator, opened.lexical_index);
    return opened;
}

const Loaded = struct {
    engine: engine.Engine,
    metadata: manifest.Manifest,
    /// S4-T2 R4: reserved, unread bytes for the filename load.
    filename_reserved: []u8 = &.{},
};

/// S4-T9: where each part of the open's one block lies, from the manifest's
/// counts: the decoded tables (`hybrid.Document` × `document_count`, the
/// vectors, `postings.TermEntry` × `term_count`, `postings.Posting` ×
/// `posting_count`, the `u32` document lengths), each at its own alignment,
/// then the manifest's bytes and the documents and lexical sections as read.
pub const OpenBlock = struct {
    documents: usize,
    terms: usize,
    vectors: usize,
    postings: usize,
    document_lengths: usize,
    manifest: usize,
    documents_section: usize,
    lexical_section: usize,
    source_reserved: usize,
    filename_reserved: usize,
    /// The block's length in bytes.
    total: usize,

    pub fn of(metadata: manifest.Manifest, manifest_bytes: usize) error{IndexTooLarge}!OpenBlock {
        var size: usize = 0;
        const vector_count = std.math.mul(usize, metadata.document_count, metadata.vector_dimensions) catch
            return error.IndexTooLarge;
        var block: OpenBlock = undefined;
        block.documents = try place(&size, hybrid.Document, metadata.document_count);
        block.terms = try place(&size, postings.TermEntry, metadata.term_count);
        block.vectors = try place(&size, f32, vector_count);
        block.postings = try place(&size, postings.Posting, metadata.posting_count);
        block.document_lengths = try place(&size, u32, metadata.document_count);
        block.manifest = try place(&size, u8, manifest_bytes);
        block.documents_section = try place(&size, u8, metadata.documents_bytes);
        block.lexical_section = try place(&size, u8, metadata.lexical_bytes);
        block.source_reserved = try place(&size, u8, metadata.source_bytes);
        block.filename_reserved = try place(&size, u8, filename_field.loadReservation(metadata));
        block.total = size;
        return block;
    }

    fn place(size: *usize, comptime T: type, count: usize) error{IndexTooLarge}!usize {
        const start = std.mem.alignForward(usize, size.*, @alignOf(T));
        const bytes = std.math.mul(usize, count, @sizeOf(T)) catch return error.IndexTooLarge;
        size.* = std.math.add(usize, start, bytes) catch return error.IndexTooLarge;
        return start;
    }

    fn slice(comptime T: type, block: engine.OpenBlockBytes, offset: usize, count: usize) []T {
        if (count == 0) return &.{};
        const first: [*]T = @ptrCast(@alignCast(block.ptr + offset));
        return first[0..count];
    }
};

/// The manifest and the document and lexical sections, each section's
/// checksum computed once (S4-T1; `publication.loadCurrent` followed by
/// `Engine.open` computed it three times), with every check of
/// `manifest.validateSnapshot` and `Engine.open`.
///
/// S4-T9: everything the open keeps of them is one exact block from
/// `allocators.blocks` (`OpenBlock`), owned by the engine
/// (`Engine.open_block`) and freed by `close`; before, one arena request
/// held the two sections, and the arena sized its block at about 1.5 times
/// that (`docs/tasks/S4-T8.md`). The manifest is read once into a buffer of
/// its own (its counts size the block), then copied into the block and
/// decoded from there; that buffer is freed before the open returns.
fn loadEngine(allocators: Allocators, io: std.Io, dir: std.Io.Dir, options: engine.Engine.OpenOptions) !Loaded {
    const blocks = allocators.blocks;
    var manifest_file = try dir.openFile(io, publication.current_manifest_file, .{});
    const manifest_stat = try manifest_file.stat(io);
    manifest_file.close(io);
    const manifest_size = std.math.cast(usize, manifest_stat.size) orelse return error.IndexTooLarge;
    const manifest_read = try blocks.alloc(u8, manifest_size);
    defer blocks.free(manifest_read);
    const manifest_first = try dir.readFile(io, publication.current_manifest_file, manifest_read);
    const layout = try OpenBlock.of(try manifest.decode(manifest_first), manifest_first.len);

    const block = try blocks.alignedAlloc(u8, .fromByteUnits(engine.open_block_alignment), layout.total);
    errdefer blocks.free(block);
    const manifest_encoded = block[layout.manifest..][0..manifest_first.len];
    @memcpy(manifest_encoded, manifest_first);
    const metadata = try manifest.decode(manifest_encoded);

    // PR #21's slab kept the source section's buffer and S4-T2 R4 the
    // filename sections' beside the two sections read here; they are still
    // reserved in the block. The filename sections are not read here (S4-T2 R4).
    const documents_buffer = block[layout.documents_section..][0..metadata.documents_bytes];
    const lexical_buffer = block[layout.lexical_section..][0..metadata.lexical_bytes];
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

    const vector_count = metadata.document_count * metadata.vector_dimensions; // checked by `OpenBlock.of`
    var opened = try engine.Engine.openWith(
        snapshot,
        OpenBlock.slice(hybrid.Document, block, layout.documents, metadata.document_count),
        OpenBlock.slice(f32, block, layout.vectors, vector_count),
        OpenBlock.slice(postings.TermEntry, block, layout.terms, metadata.term_count),
        OpenBlock.slice(postings.Posting, block, layout.postings, metadata.posting_count),
        OpenBlock.slice(u32, block, layout.document_lengths, metadata.document_count),
        options,
    );
    opened.open_block = block;
    if (metadata.hasSource()) opened.source_buffer = block[layout.source_reserved..][0..metadata.source_bytes];

    // The policy comes from the manifest; `index_status` reports it without
    // reading the sections.
    opened.filename_index_enabled = metadata.filename != null;
    if (metadata.filename) |f| opened.filename_policy_id = f.policy_id;
    return .{ .engine = opened, .metadata = metadata, .filename_reserved = block[layout.filename_reserved..layout.total] };
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
    return openScopedWith(.one(allocator), io, dir);
}

/// S4-T9: `openScoped` with the exact blocks from `allocators.blocks` (the
/// handle's parent allocator: `ss_open`'s C allocator, `rpc.Generation`'s
/// `gpa`) and the rest from `allocators.arena`. The owner calls `close`
/// before it releases the arena.
pub fn openScopedWith(allocators: Allocators, io: std.Io, dir: std.Io.Dir) !Scoped {
    const allocator = allocators.arena;
    const loaded = try loadEngine(allocators, io, dir, .{ .validate_positions = false });
    errdefer allocators.blocks.free(loaded.engine.open_block.?);
    var opened_engine = loaded.engine;
    const metadata = loaded.metadata;
    const meta: ?manifest.Meta = if (metadata.meta.len != 0) try manifest.parseMeta(allocator, metadata.meta) else null;
    opened_engine.roots = if (meta) |m| m.roots else &scope.legacy_roots;
    const loads = try allocator.create(scope.Loads);
    loads.* = .{
        .io = io,
        .allocator = allocator,
        .blocks = allocators.blocks,
        .documents = opened_engine.documents,
        .index = opened_engine.lexical_index,
        .source_bytes = metadata.source_bytes,
        .source_buffer = opened_engine.source_buffer,
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
    // S4-T2 R4: the filename sections' files, opened (not read) like the
    // source section's, so the first filename query reads this generation's
    // own bytes even after a writer pruned them.
    if (metadata.filename) |f| {
        loads.filename_manifest = metadata;
        loads.filename_reserved = loaded.filename_reserved;
        loads.filename_catalog_file = dir.openFile(io, f.catalog_file, .{}) catch |err| blk: {
            loads.filename_error = err;
            break :blk null;
        };
        if (loads.filename_error == null) loads.filename_lexical_file = dir.openFile(io, f.lexical_file, .{}) catch |err| blk: {
            loads.filename_error = err;
            break :blk null;
        };
    }
    errdefer if (loads.filename_catalog_file) |file| file.close(io);
    errdefer if (loads.filename_lexical_file) |file| file.close(io);
    const folder = try allocator.create(scope.Folder);
    folder.* = try scope.Folder.build(allocator, meta, loads);
    folder.has_positions = metadata.has_positions;
    folder.source_bound = metadata.hasSource();
    opened_engine.folder = folder;
    return .{ .engine = opened_engine, .folder = folder };
}

/// S4-T9: release what `openScopedWith` keeps outside its arena: the files
/// (`scope.Folder.close`) and the exact blocks, through the allocator the
/// open was given. Nothing of the opened generation may be used afterwards;
/// the arena is the owner's to release after this.
pub fn close(opened_engine: engine.Engine, folder: *const scope.Folder) void {
    folder.close();
    if (opened_engine.open_block) |block| folder.loads.blocks.free(block);
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
