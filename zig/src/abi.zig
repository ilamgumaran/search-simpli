//! C ABI over the Zig engine (ADR 0002, `docs/tasks/S1-T0.md`).
//!
//! Every exported `ss_*` function is documented in `zig/include/search_simpli.h`;
//! this file is the implementation. Design notes that do not fit the header:
//!
//! - **Allocation.** All memory this file allocates (the opened handle, its
//!   decoded workspaces, and every returned JSON string) comes from the C
//!   allocator (`malloc`/`free`), never from a Zig allocator with hidden
//!   metadata. `ss_free` therefore just calls `free()` on the pointer; there
//!   is no bookkeeping table and no global allocator state.
//! - **I/O.** `ss_open` and `ss_import_json` are the only functions that touch
//!   the filesystem. They use `std.Io.Threaded.global_single_threaded`, the
//!   standard library's ready-made synchronous, non-concurrent `Io`
//!   implementation, so this library needs no `std.process.Init` and starts
//!   no threads of its own.
//! - **Errors.** Functions that return a pointer (`ss_open`, `ss_status`,
//!   `ss_query`, `ss_evidence`) return `NULL` on failure. The one function
//!   that returns an integer result (`ss_import_json`) returns a negative
//!   `ss_error_code` (see below) on failure. Either way, `ss_last_error()`
//!   returns a thread-local, human-readable description of the most recent
//!   failure on the calling thread; it is not part of the engine's state (no
//!   handle is required to read it, and no handle's behavior depends on it),
//!   so it does not count against "no global mutable state beyond the
//!   handle" any more than C's own `errno`/`strerror` would.
//! - **Concurrency.** A single handle must not be used from two threads at
//!   once without external synchronization: `ss_query`/`ss_evidence`/
//!   `ss_status` only read the handle's immutable decoded snapshot and
//!   allocate fresh scratch space per call (never touching shared mutable
//!   scratch), so concurrent *reads* on the same handle from multiple
//!   threads are safe; `ss_close` racing with any other call on the same
//!   handle is not.

const std = @import("std");
const chunker = @import("chunker.zig");
const engine_module = @import("engine.zig");
const generation_alloc = @import("generation_alloc.zig");
const hybrid = @import("hybrid.zig");
const importer = @import("importer.zig");
const indexer = @import("indexer.zig");
const manifest = @import("manifest.zig");
const postings = @import("postings.zig");
const publication = @import("publication.zig");
const rpc = @import("rpc.zig");
const service_module = @import("service.zig");

/// Negative error codes returned by `ss_import_json`. Matches
/// `docs/zig-engine-api.md`'s ABI section.
pub const SS_ERR_INVALID_ARGUMENT: i64 = -1;
pub const SS_ERR_IO: i64 = -2;
pub const SS_ERR_CORRUPT_SNAPSHOT: i64 = -3;
pub const SS_ERR_CAPACITY: i64 = -4;
pub const SS_ERR_OUT_OF_MEMORY: i64 = -5;
pub const SS_ERR_NOT_FOUND: i64 = -6;
pub const SS_ERR_INTERNAL: i64 = -7;

const allocator = std.heap.c_allocator;
/// Supplied by `build.zig` (`contractsVersionOptions`), which reads
/// `contracts/CONTRACTS_VERSION` at configure time — `@embedFile` cannot
/// reach outside `zig/`'s own module package boundary.
const contracts_version: [:0]const u8 = @import("build_options").contracts_version;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

threadlocal var last_error_buffer: [512]u8 = undefined;
threadlocal var last_error_len: usize = 0;

fn clearLastError() void {
    last_error_len = 0;
    last_error_buffer[0] = 0;
}

fn setLastError(comptime fmt: []const u8, args: anytype) void {
    const available = last_error_buffer[0 .. last_error_buffer.len - 1];
    const written = std.fmt.bufPrint(available, fmt, args) catch available;
    last_error_len = written.len;
    last_error_buffer[last_error_len] = 0;
}

/// Returns a thread-local, null-terminated description of the most recent
/// failure on the calling thread (empty string if there has been none yet).
/// Valid until the next `ss_*` call that fails on this thread.
pub export fn ss_last_error() callconv(.c) [*:0]const u8 {
    return @ptrCast(last_error_buffer[0..last_error_len :0].ptr);
}

/// The engine contract/build version (`contracts/CONTRACTS_VERSION`), e.g.
/// `"1.0.0"`. Static storage: never pass this pointer to `ss_free`.
pub export fn ss_version() callconv(.c) [*:0]const u8 {
    return contracts_version.ptr;
}

/// Opaque handle to one opened, immutable, published snapshot generation.
/// Every field is owned by the handle and freed together by `ss_close`.
const Handle = struct {
    manifest_buffer: []u8,
    documents_buffer: []u8,
    lexical_buffer: []u8,
    documents_output: []hybrid.Document,
    vectors_output: []f32,
    terms_output: []postings.TermEntry,
    postings_output: []postings.Posting,
    document_lengths_output: []u32,
    engine: engine_module.Engine,
};

/// Open the published snapshot directory `dir` (as written by `searchd
/// init-demo`, `searchd import-json`, or `ss_import_json`) and decode its
/// current generation into freshly allocated workspaces. Returns `NULL` on
/// any I/O or validation failure; see `ss_last_error()`.
pub export fn ss_open(dir_path: [*:0]const u8) callconv(.c) ?*Handle {
    clearLastError();
    return openImpl(std.mem.span(dir_path)) catch |err| {
        setLastError("ss_open: {s}", .{@errorName(err)});
        return null;
    };
}

fn openImpl(path: []const u8) !*Handle {
    const gio = io();
    var dir = try std.Io.Dir.cwd().openDir(gio, path, .{});
    defer dir.close(gio);

    var manifest_file = try dir.openFile(gio, publication.current_manifest_file, .{});
    const manifest_stat = try manifest_file.stat(gio);
    manifest_file.close(gio);
    const manifest_size = std.math.cast(usize, manifest_stat.size) orelse return error.IndexTooLarge;
    const manifest_buffer = try allocator.alloc(u8, manifest_size);
    errdefer allocator.free(manifest_buffer);
    const manifest_encoded = try dir.readFile(gio, publication.current_manifest_file, manifest_buffer);
    const metadata = try manifest.decode(manifest_encoded);

    const documents_buffer = try allocator.alloc(u8, metadata.documents_bytes);
    errdefer allocator.free(documents_buffer);
    const lexical_buffer = try allocator.alloc(u8, metadata.lexical_bytes);
    errdefer allocator.free(lexical_buffer);
    const snapshot = try publication.loadCurrent(dir, gio, manifest_buffer, documents_buffer, lexical_buffer);

    const documents_output = try allocator.alloc(hybrid.Document, metadata.document_count);
    errdefer allocator.free(documents_output);
    const vector_count = std.math.mul(usize, metadata.document_count, metadata.vector_dimensions) catch
        return error.IndexTooLarge;
    const vectors_output = try allocator.alloc(f32, vector_count);
    errdefer allocator.free(vectors_output);
    const terms_output = try allocator.alloc(postings.TermEntry, metadata.term_count);
    errdefer allocator.free(terms_output);
    const postings_output = try allocator.alloc(postings.Posting, metadata.posting_count);
    errdefer allocator.free(postings_output);
    const document_lengths_output = try allocator.alloc(u32, metadata.document_count);
    errdefer allocator.free(document_lengths_output);

    const engine = try engine_module.Engine.open(
        snapshot,
        documents_output,
        vectors_output,
        terms_output,
        postings_output,
        document_lengths_output,
    );

    const handle = try allocator.create(Handle);
    handle.* = .{
        .manifest_buffer = manifest_buffer,
        .documents_buffer = documents_buffer,
        .lexical_buffer = lexical_buffer,
        .documents_output = documents_output,
        .vectors_output = vectors_output,
        .terms_output = terms_output,
        .postings_output = postings_output,
        .document_lengths_output = document_lengths_output,
        .engine = engine,
    };
    return handle;
}

/// Free everything opened by `ss_open`. `NULL` is a safe no-op.
pub export fn ss_close(handle: ?*Handle) callconv(.c) void {
    const h = handle orelse return;
    allocator.free(h.manifest_buffer);
    allocator.free(h.documents_buffer);
    allocator.free(h.lexical_buffer);
    allocator.free(h.documents_output);
    allocator.free(h.vectors_output);
    allocator.free(h.terms_output);
    allocator.free(h.postings_output);
    allocator.free(h.document_lengths_output);
    allocator.destroy(h);
}

/// Snapshot status as JSON (the same fields as JSON-RPC `index_status`'s
/// `result`): `ready`, `generation`, `analyzer_id`, `embedding_model_id`,
/// `vector_dimensions`, `documents`, `terms`, `postings`. Caller frees the
/// result with `ss_free`. `NULL` on failure (`ss_last_error()`).
pub export fn ss_status(handle: ?*Handle) callconv(.c) ?[*:0]u8 {
    clearLastError();
    const h = handle orelse {
        setLastError("ss_status: null handle", .{});
        return null;
    };
    return statusImpl(h) catch |err| {
        setLastError("ss_status: {s}", .{@errorName(err)});
        return null;
    };
}

fn statusImpl(h: *Handle) ![*:0]u8 {
    const service = service_module.Service{ .engine = h.engine };
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var json = std.json.Stringify{ .writer = &out.writer };
    try json.write(service.indexStatus());
    const owned = try out.toOwnedSliceSentinel(0);
    return owned.ptr;
}

const QueryOptions = struct {
    retrieval_mode: ?[]const u8 = null,
    candidate_k: ?usize = null,
    path_prefix: ?[]const u8 = null,
    principal_labels: []const []const u8 = &.{},
};

/// Run one query and return the same `result` JSON object a `search_knowledge`
/// JSON-RPC response would carry (`tool`, `query`, `index`, `retrieval`,
/// `results`, `answer_policy`) — produced by the identical code
/// (`rpc.writeSearchResultValue`), so it is byte-for-byte what the JSON-RPC
/// service would return for the same request.
///
/// `query_vector`/`dims` are ignored for lexical mode and for snapshots with
/// zero vector dimensions; otherwise `dims` must equal the snapshot's vector
/// dimensions (see `ss_status`). `top_k` must be 1-100. `options_json` may be
/// `NULL`/empty for defaults, or a JSON object with any of `retrieval_mode`
/// (`"lexical"`/`"vector"`/`"hybrid"`, default `"hybrid"`), `candidate_k`
/// (default 100, must be >= `top_k` and <= 10000), `path_prefix`, and
/// `principal_labels` (array of strings).
///
/// Caller frees the result with `ss_free`. `NULL` on failure
/// (`ss_last_error()`).
pub export fn ss_query(
    handle: ?*Handle,
    query_text: [*:0]const u8,
    query_vector: ?[*]const f32,
    dims: usize,
    top_k: usize,
    options_json: ?[*:0]const u8,
) callconv(.c) ?[*:0]u8 {
    clearLastError();
    const h = handle orelse {
        setLastError("ss_query: null handle", .{});
        return null;
    };
    const text = std.mem.span(query_text);
    const vector: []const f32 = if (query_vector) |ptr| ptr[0..dims] else &.{};
    const options_text = if (options_json) |ptr| std.mem.span(ptr) else "";
    return queryImpl(h, text, vector, top_k, options_text) catch |err| {
        setLastError("ss_query: {s}", .{@errorName(err)});
        return null;
    };
}

fn queryImpl(
    h: *Handle,
    query_text: []const u8,
    query_vector: []const f32,
    top_k: usize,
    options_json: []const u8,
) ![*:0]u8 {
    if (top_k == 0 or top_k > 100) return error.InvalidTopK;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const options: QueryOptions = if (options_json.len == 0)
        .{}
    else blk: {
        const parsed = try std.json.parseFromSlice(QueryOptions, arena.allocator(), options_json, .{});
        break :blk parsed.value;
    };

    const mode = if (options.retrieval_mode) |name|
        rpc.parseMode(name) orelse return error.InvalidRetrievalMode
    else
        .hybrid;
    const candidate_k = options.candidate_k orelse 100;
    if (candidate_k < top_k or candidate_k > 10_000) return error.InvalidCandidateDepth;

    const effective_vector: []const f32 = if (mode == .lexical or h.engine.vector_dimensions == 0)
        &.{}
    else vec: {
        if (query_vector.len != h.engine.vector_dimensions) return error.VectorDimensionMismatch;
        for (query_vector) |value| if (!std.math.isFinite(value)) return error.VectorDimensionMismatch;
        break :vec query_vector;
    };

    const service = service_module.Service{ .engine = h.engine };
    const document_count = h.engine.documents.len;
    const lexical_scores = try allocator.alloc(f32, document_count);
    defer allocator.free(lexical_scores);
    const results = try allocator.alloc(hybrid.Result, document_count);
    defer allocator.free(results);
    const evidence = try allocator.alloc(engine_module.Evidence, document_count);
    defer allocator.free(evidence);

    // S1-T1 threaded an allocator through `searchKnowledge` so query
    // tokenization dispatches on the snapshot's `analyzer_id`
    // (`Engine.queryTokenized`): an `analyzer-v2` snapshot has to NFC-normalise
    // and Unicode-tokenize the query text, which allocates. The per-call arena
    // above already owns everything this call needs and is torn down before
    // `ss_query` returns, so the ABI keeps its "no hidden allocator, nothing
    // retained between calls" contract.
    const found = try service.searchKnowledge(arena.allocator(), query_text, effective_vector, .{
        .top_k = top_k,
        .candidate_k = candidate_k,
        .retrieval_mode = mode,
        .path_prefix = options.path_prefix,
        .principal_labels = options.principal_labels,
    }, lexical_scores, results, evidence);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var json = std.json.Stringify{ .writer = &out.writer };
    try rpc.writeSearchResultValue(&json, service, query_text, mode, options.principal_labels.len, found);
    const owned = try out.toOwnedSliceSentinel(0);
    return owned.ptr;
}

const EvidenceRequest = struct {
    ids: []const []const u8,
    path_prefix: ?[]const u8 = null,
    principal_labels: []const []const u8 = &.{},
};

/// Look up stored chunks by id. `ids_json` is a JSON object:
/// `{"ids": ["chunk-1", ...], "path_prefix": "guides/", "principal_labels": []}`
/// (`path_prefix` and `principal_labels` are optional, same meaning as
/// `read_chunk`). Returns a JSON array with one entry per id, in the same
/// order: a chunk object (`chunk_id`, `citation`, `content` — the same
/// fields and layout `read_chunk` returns, via `rpc.writeChunkFields`) when
/// found and authorized, or `{"chunk_id": "...", "found": false}` otherwise.
///
/// Caller frees the result with `ss_free`. `NULL` on failure
/// (`ss_last_error()`), which includes a malformed `ids_json`.
pub export fn ss_evidence(handle: ?*Handle, ids_json: [*:0]const u8) callconv(.c) ?[*:0]u8 {
    clearLastError();
    const h = handle orelse {
        setLastError("ss_evidence: null handle", .{});
        return null;
    };
    return evidenceImpl(h, std.mem.span(ids_json)) catch |err| {
        setLastError("ss_evidence: {s}", .{@errorName(err)});
        return null;
    };
}

fn evidenceImpl(h: *Handle, ids_json: []const u8) ![*:0]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSlice(EvidenceRequest, arena.allocator(), ids_json, .{});
    const request = parsed.value;
    const service = service_module.Service{ .engine = h.engine };

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var json = std.json.Stringify{ .writer = &out.writer };
    try json.beginArray();
    for (request.ids) |id| {
        if (service.readChunk(id, request.path_prefix, request.principal_labels)) |chunk| {
            try json.beginObject();
            try rpc.writeChunkFields(&json, chunk);
            try json.endObject();
        } else {
            try json.beginObject();
            try json.objectField("chunk_id");
            try json.write(id);
            try json.objectField("found");
            try json.write(false);
            try json.endObject();
        }
    }
    try json.endArray();
    const owned = try out.toOwnedSliceSentinel(0);
    return owned.ptr;
}

/// Validate the neutral interchange JSON in `bytes[0..bytes_len]`
/// (`contracts/snapshot-interchange.schema.json`) and atomically publish it
/// as a new generation under `dir` (created if missing), exactly as `searchd
/// import-json` does. Returns the published generation number (>= 1) on
/// success, or a negative `ss_error_code` (`SS_ERR_*` above) on failure; see
/// `ss_last_error()` for the reason.
pub export fn ss_import_json(dir_path: [*:0]const u8, bytes: [*]const u8, bytes_len: usize) callconv(.c) i64 {
    clearLastError();
    const generation = importImpl(std.mem.span(dir_path), bytes[0..bytes_len]) catch |err| {
        setLastError("ss_import_json: {s}", .{@errorName(err)});
        return errorCode(err);
    };
    return @intCast(generation);
}

fn importImpl(dir_path: []const u8, bytes: []const u8) !u64 {
    const gio = io();
    var dir = try std.Io.Dir.cwd().createDirPathOpen(gio, dir_path, .{});
    defer dir.close(gio);
    const report = try importer.importJson(dir, gio, allocator, bytes);
    return report.generation;
}

fn errorCode(err: anyerror) i64 {
    return switch (err) {
        error.OutOfMemory => SS_ERR_OUT_OF_MEMORY,

        error.FileNotFound,
        error.AccessDenied,
        error.NotDir,
        error.IsDir,
        error.WriterBusy,
        error.PathAlreadyExists,
        => SS_ERR_IO,

        error.BadMagic,
        error.UnsupportedVersion,
        error.UnsupportedFlags,
        error.Truncated,
        error.TrailingData,
        error.ChecksumMismatch,
        error.SizeOverflow,
        error.CountOverflow,
        error.GenerationZero,
        error.InvalidIdentifier,
        error.UnsafeFilename,
        error.SameFilename,
        error.InvalidDocumentSection,
        error.InvalidLexicalSection,
        error.DocumentCountMismatch,
        error.VectorDimensionMismatch,
        error.TermCountMismatch,
        error.PostingCountMismatch,
        error.DocumentSectionSizeMismatch,
        error.LexicalSectionSizeMismatch,
        error.DocumentSectionChecksumMismatch,
        error.LexicalSectionChecksumMismatch,
        error.InvalidCitation,
        error.InvalidRequiredLabels,
        => SS_ERR_CORRUPT_SNAPSHOT,

        error.DocumentCapacityTooSmall,
        error.VectorCapacityTooSmall,
        error.EvidenceCapacityTooSmall,
        error.SourceCapacityTooSmall,
        error.WorkspaceTooSmall,
        => SS_ERR_CAPACITY,

        error.UnsupportedInterchangeVersion,
        error.UnsupportedAnalyzer,
        error.InvalidEmbeddingModel,
        error.EmbeddingMetadataMismatch,
        error.InvalidDocument,
        error.VectorDimensionsInconsistent,
        error.TooManyRequiredLabels,
        error.InvalidRequiredLabel,
        error.DuplicateRequiredLabel,
        error.IndexTooLarge,
        // S1-T3/S1-T4 (`ss_index_folder`): an unrecognized `opts.analyzer`
        // value, or an `--update` run whose `out_dir` was already published
        // with a different analyzer -- caller mistakes, not corruption or
        // I/O. (`error.NoDocuments` used to appear here too, for a folder
        // with no indexable files; S1-T4 criterion 3 makes that publish an
        // empty generation instead of failing, so `indexFolder`/
        // `indexFolderIncremental` no longer raise it.)
        error.InvalidAnalyzer,
        error.AnalyzerMismatch,
        => SS_ERR_INVALID_ARGUMENT,

        else => SS_ERR_INTERNAL,
    };
}

/// Free a pointer previously returned by `ss_status`, `ss_query`, or
/// `ss_evidence`. Never call this on the result of `ss_version()`. `NULL` is
/// a safe no-op.
pub export fn ss_free(ptr: ?[*:0]u8) callconv(.c) void {
    if (ptr) |p| std.c.free(p);
}

// === S1-T3: ss_index_folder ================================================
// Additive only (docs/tasks/S1-T3.md): appended at the end of the file so it
// merges cleanly alongside S1-T2's Dart FFI package, which does not bind
// this function.

const IndexFolderOptions = struct {
    /// `"analyzer-v1"`/`"v1"` or `"analyzer-v2"`/`"v2"` (default), same
    /// spelling `indexer.AnalyzerId.parse` and `searchd index --analyzer`
    /// accept.
    analyzer: []const u8 = "analyzer-v2",
    max_chars: ?usize = null,
    overlap_lines: ?usize = null,
    /// `false` (default): full rebuild, always publishing the next free
    /// generation in `dir_path` (S1-T3 criterion 5 -- never
    /// `PathAlreadyExists` on a directory that already holds a snapshot).
    /// `true`: incremental update (`indexer.indexFolderIncremental`) --
    /// content hashes, unchanged files skipped, deleted files tombstoned.
    update: bool = false,
    max_file_bytes: ?u64 = null,
    max_total_bytes: ?u64 = null,
};

/// Index the folder at `folder_path` and atomically publish (or
/// re-publish/update) a lexical-only snapshot into `dir_path` (created,
/// including parent directories, if it does not already exist) -- the
/// native-engine equivalent of `searchd index`/`searchd index --update`
/// (S1-T3, `docs/tasks/S1-T3.md`).
///
/// This function mutates the directory identified by `dir_path` rather than
/// operating on an already-`ss_open`-ed handle: indexing publishes a *new*
/// generation, and a `Handle`'s decoded arrays are a snapshot of one
/// specific already-published generation, so there is nothing for an open
/// handle to do here that reopening afterward does not already cover. Close
/// and reopen (`ss_close` + `ss_open`) any handle on `dir_path` after this
/// call to see the new generation.
///
/// `opts_json` may be `NULL`/empty for defaults, or a JSON object with any
/// of `analyzer`, `max_chars`, `overlap_lines`, `update`, `max_file_bytes`,
/// `max_total_bytes` (see `IndexFolderOptions` above; same meanings as the
/// `searchd index` flags of the same names).
///
/// Returns a heap-allocated, null-terminated JSON report object on success
/// -- the caller must free it with `ss_free` -- with fields `generation`,
/// `analyzer_id`, `added`, `changed`, `removed`, `unchanged`,
/// `budget_exhausted`, `too_large`, `unreadable`, `too_large_paths` (array
/// of relative paths), `unreadable_paths` (array of relative paths),
/// `documents`, `terms`, `postings` (S1-T4, `docs/tasks/S1-T4.md` criterion
/// 3: `unchanged`/`budget_exhausted` replace the old, ambiguous `skipped`
/// field -- "nothing to do" and "left for a later run" are no longer the
/// same number -- and every `too_large`/`unreadable` file is named, not
/// just counted). A non-`--update` run always reports
/// `changed`/`removed`/`unchanged`/`budget_exhausted`/`too_large` as 0,
/// `too_large_paths` as `[]`, and `added`/`unreadable`/`unreadable_paths` as
/// the files indexed/skipped (matching `IndexReport`); an `--update` run
/// reports the full incremental breakdown (`IncrementalReport`). An empty
/// folder, or a folder whose last indexable file was just deleted, publishes
/// an empty generation (0 documents/terms/postings) rather than failing.
/// Returns `NULL` on failure -- a missing/unreadable `folder_path`, an
/// unrecognized `analyzer`, or (on `--update`) `dir_path` already holding a
/// snapshot published with a different analyzer -- see `ss_last_error()`.
pub export fn ss_index_folder(
    dir_path: [*:0]const u8,
    folder_path: [*:0]const u8,
    opts_json: ?[*:0]const u8,
) callconv(.c) ?[*:0]u8 {
    clearLastError();
    const options_text = if (opts_json) |ptr| std.mem.span(ptr) else "";
    return indexFolderImpl(std.mem.span(dir_path), std.mem.span(folder_path), options_text) catch |err| {
        setLastError("ss_index_folder: {s}", .{@errorName(err)});
        return null;
    };
}

fn indexFolderImpl(dir_path: []const u8, folder_path: []const u8, opts_json: []const u8) ![*:0]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const options: IndexFolderOptions = if (opts_json.len == 0)
        .{}
    else blk: {
        const parsed = try std.json.parseFromSlice(IndexFolderOptions, arena_allocator, opts_json, .{});
        break :blk parsed.value;
    };
    const analyzer = indexer.AnalyzerId.parse(options.analyzer) orelse return error.InvalidAnalyzer;
    const max_chars = options.max_chars orelse chunker.default_max_chars;
    const overlap_lines = options.overlap_lines orelse chunker.default_overlap_lines;
    const default_caps = indexer.Caps{};
    const caps = indexer.Caps{
        .max_file_bytes = options.max_file_bytes orelse default_caps.max_file_bytes,
        .max_total_bytes = options.max_total_bytes orelse default_caps.max_total_bytes,
    };

    const gio = io();
    var root = try std.Io.Dir.cwd().openDir(gio, folder_path, .{ .iterate = true });
    defer root.close(gio);
    var out_dir = try std.Io.Dir.cwd().createDirPathOpen(gio, dir_path, .{ .open_options = .{ .iterate = true } });
    defer out_dir.close(gio);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var json = std.json.Stringify{ .writer = &out.writer };

    if (options.update) {
        const report = try indexer.indexFolderIncremental(arena_allocator, gio, root, out_dir, analyzer, max_chars, overlap_lines, caps);
        try json.beginObject();
        try json.objectField("generation");
        try json.write(report.generation);
        try json.objectField("analyzer_id");
        try json.write(report.analyzer_id);
        try json.objectField("added");
        try json.write(report.added);
        try json.objectField("changed");
        try json.write(report.changed);
        try json.objectField("removed");
        try json.write(report.removed);
        try json.objectField("unchanged");
        try json.write(report.unchanged);
        try json.objectField("budget_exhausted");
        try json.write(report.budget_exhausted);
        try json.objectField("too_large");
        try json.write(report.too_large);
        try json.objectField("unreadable");
        try json.write(report.unreadable);
        try json.objectField("too_large_paths");
        try json.beginArray();
        for (report.too_large_paths) |path| try json.write(path);
        try json.endArray();
        try json.objectField("unreadable_paths");
        try json.beginArray();
        for (report.unreadable_paths) |path| try json.write(path);
        try json.endArray();
        try json.objectField("documents");
        try json.write(report.documents);
        try json.objectField("terms");
        try json.write(report.terms);
        try json.objectField("postings");
        try json.write(report.postings);
        try json.endObject();
    } else {
        const generation = try generation_alloc.nextFreeGeneration(arena_allocator, gio, out_dir);
        const report = try indexer.indexFolder(arena_allocator, gio, root, out_dir, analyzer, generation, max_chars, overlap_lines);
        try json.beginObject();
        try json.objectField("generation");
        try json.write(report.generation);
        try json.objectField("analyzer_id");
        try json.write(report.analyzer_id);
        try json.objectField("added");
        try json.write(report.files_indexed);
        try json.objectField("changed");
        try json.write(@as(usize, 0));
        try json.objectField("removed");
        try json.write(@as(usize, 0));
        try json.objectField("unchanged");
        try json.write(@as(usize, 0));
        try json.objectField("budget_exhausted");
        try json.write(@as(usize, 0));
        try json.objectField("too_large");
        try json.write(@as(usize, 0));
        try json.objectField("unreadable");
        try json.write(report.files_skipped);
        try json.objectField("too_large_paths");
        try json.beginArray();
        try json.endArray();
        try json.objectField("unreadable_paths");
        try json.beginArray();
        for (report.unreadable_paths) |path| try json.write(path);
        try json.endArray();
        try json.objectField("documents");
        try json.write(report.documents);
        try json.objectField("terms");
        try json.write(report.terms);
        try json.objectField("postings");
        try json.write(report.postings);
        try json.endObject();
    }
    const owned = try out.toOwnedSliceSentinel(0);
    return owned.ptr;
}

test "ss_index_folder publishes and re-publishes, full and incremental" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io_impl = std.testing.io;

    try tmp.dir.createDir(io_impl, "notes", .default_dir);
    try tmp.dir.writeFile(io_impl, .{ .sub_path = "notes/a.md", .data = "hybrid retrieval combines lexical and semantic ranks\n" });

    const notes_path_z = try std.fmt.allocPrintSentinel(std.testing.allocator, ".zig-cache/tmp/{s}/notes", .{tmp.sub_path}, 0);
    defer std.testing.allocator.free(notes_path_z);
    const out_path_z = try std.fmt.allocPrintSentinel(std.testing.allocator, ".zig-cache/tmp/{s}/out", .{tmp.sub_path}, 0);
    defer std.testing.allocator.free(out_path_z);

    const first_json = ss_index_folder(out_path_z, notes_path_z, null) orelse {
        std.debug.print("ss_index_folder failed: {s}\n", .{ss_last_error()});
        return error.IndexFailed;
    };
    defer ss_free(first_json);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(first_json), "\"generation\":1") != null);

    // Criterion 5: re-running without --update re-publishes rather than
    // failing with PathAlreadyExists.
    const second_json = ss_index_folder(out_path_z, notes_path_z, null) orelse {
        std.debug.print("ss_index_folder failed: {s}\n", .{ss_last_error()});
        return error.IndexFailed;
    };
    defer ss_free(second_json);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(second_json), "\"generation\":2") != null);

    // --update: no changes yet, but the previous publish did not go through
    // the incremental path, so there is no INDEX-STATE.json and everything
    // is reported "added" once, establishing a baseline.
    const update_json = ss_index_folder(out_path_z, notes_path_z, "{\"update\":true}") orelse {
        std.debug.print("ss_index_folder failed: {s}\n", .{ss_last_error()});
        return error.IndexFailed;
    };
    defer ss_free(update_json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, std.mem.span(update_json), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 3), parsed.value.object.get("generation").?.integer);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("added").?.integer);

    const handle = ss_open(out_path_z) orelse return error.OpenFailed;
    defer ss_close(handle);
    const query_json = ss_query(handle, "hybrid", null, 0, 1, "{\"retrieval_mode\":\"lexical\"}") orelse return error.QueryFailed;
    defer ss_free(query_json);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(query_json), "a.md") != null);
}
// === end S1-T3 ==============================================================

test "ss_open reads a published demo snapshot and ss_query/ss_status/ss_evidence agree with the RPC path" {
    const segment = @import("segment.zig");
    const lexical_segment = @import("lexical_segment.zig");
    const lifecycle = @import("lifecycle.zig");

    const documents = [_]hybrid.Document{
        .{ .id = "both", .text = "hybrid retrieval combines ranks", .vector = &.{ 0.8, 0.2 }, .path = "guides/hybrid.md", .start_line = 1, .end_line = 6 },
        .{ .id = "lexical", .text = "hybrid hybrid exact", .vector = &.{ 0, 1 }, .path = "guides/lexical.md", .start_line = 10, .end_line = 12 },
        .{ .id = "semantic", .text = "meaning based result", .vector = &.{ 1, 0 }, .path = "guides/semantic.md", .start_line = 20, .end_line = 22 },
    };
    var document_encoded_storage: [1024]u8 = undefined;
    const documents_encoded = try segment.encode(&documents, &document_encoded_storage);
    var terms: [24]postings.TermEntry = undefined;
    var posting_storage: [32]postings.Posting = undefined;
    var lengths: [documents.len]u32 = undefined;
    var fills: [24]usize = undefined;
    const source_index = try postings.build(&documents, &terms, &posting_storage, &lengths, &fills);
    var lexical_encoded_storage: [2048]u8 = undefined;
    const lexical_encoded = try lexical_segment.encode(source_index, &lexical_encoded_storage);
    const metadata = try manifest.create(
        1,
        "ascii-alnum-v1",
        "manual-test-vectors-v1",
        "documents-1.hybseg",
        "lexical-1.hyblex",
        documents_encoded,
        lexical_encoded,
    );
    var manifest_encoded_storage: [512]u8 = undefined;
    const manifest_encoded = try manifest.encode(metadata, &manifest_encoded_storage);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try lifecycle.publishSerialized(tmp.dir, std.testing.io, manifest_encoded, documents_encoded, lexical_encoded);

    const path_z = try std.fmt.allocPrintSentinel(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path}, 0);
    defer std.testing.allocator.free(path_z);

    const handle = ss_open(path_z) orelse {
        std.debug.print("ss_open failed: {s}\n", .{ss_last_error()});
        return error.OpenFailed;
    };
    defer ss_close(handle);

    const status_json = ss_status(handle) orelse return error.StatusFailed;
    defer ss_free(status_json);
    const status_text = std.mem.span(status_json);
    try std.testing.expect(std.mem.indexOf(u8, status_text, "\"generation\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_text, "\"documents\":3") != null);

    const query_vector = [_]f32{ 1, 0 };
    const query_json = ss_query(handle, "hybrid", &query_vector, query_vector.len, 1, null) orelse return error.QueryFailed;
    defer ss_free(query_json);
    const query_text = std.mem.span(query_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, query_text, .{});
    defer parsed.deinit();
    const first = parsed.value.object.get("results").?.array.items[0].object;
    try std.testing.expectEqualStrings("both", first.get("chunk_id").?.string);

    const service = service_module.Service{ .engine = handle.engine };
    var scores: [documents.len]f32 = undefined;
    var results: [documents.len]hybrid.Result = undefined;
    var evidence_storage: [documents.len]engine_module.Evidence = undefined;
    const evidence = try service.searchKnowledge(std.testing.allocator, "hybrid", &query_vector, .{ .top_k = 1 }, &scores, &results, &evidence_storage);
    var golden: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer golden.deinit();
    var golden_json = std.json.Stringify{ .writer = &golden.writer };
    try rpc.writeSearchResultValue(&golden_json, service, "hybrid", .hybrid, 0, evidence);
    try std.testing.expectEqualStrings(golden.written(), query_text);

    const evidence_json = ss_evidence(handle, "{\"ids\":[\"both\",\"missing-id\"]}") orelse return error.EvidenceFailed;
    defer ss_free(evidence_json);
    var evidence_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, std.mem.span(evidence_json), .{});
    defer evidence_parsed.deinit();
    const evidence_items = evidence_parsed.value.array.items;
    try std.testing.expectEqualStrings("guides/hybrid.md", evidence_items[0].object.get("citation").?.object.get("path").?.string);
    try std.testing.expectEqual(false, evidence_items[1].object.get("found").?.bool);

    try std.testing.expectEqualStrings("1.0.0", std.mem.span(ss_version()));
}

test "ss_import_json publishes a queryable snapshot and reports negative codes on failure" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const path_z = try std.fmt.allocPrintSentinel(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path}, 0);
    defer std.testing.allocator.free(path_z);

    const json =
        \\{"format_version":1,"generation":1,"analyzer_id":"ascii-alnum-v1","embedding_model_id":"none","documents":[
        \\{"id":"one","path":"a.md","start_line":1,"end_line":1,"text":"search evidence","vector":[],"required_labels":[]}
        \\]}
    ;
    const generation = ss_import_json(path_z, json.ptr, json.len);
    try std.testing.expectEqual(@as(i64, 1), generation);

    const handle = ss_open(path_z) orelse return error.OpenFailed;
    defer ss_close(handle);
    try std.testing.expectEqual(@as(usize, 1), handle.engine.documents.len);

    const bad = ss_import_json(path_z, "not json", 8);
    try std.testing.expect(bad < 0);
    try std.testing.expect(std.mem.span(ss_last_error()).len > 0);
}
