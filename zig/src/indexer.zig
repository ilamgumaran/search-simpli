//! Native folder indexing (S1-T1 acceptance criterion 3): walks a folder,
//! chunks UTF-8 text/markdown/source files with `chunker.zig`
//! (`line-window-v1`), tokenizes with the selected analyzer, builds a
//! lexical-only (no embeddings) index, and publishes it through the
//! existing `segment`/`lexical_segment`/`manifest`/`lifecycle` machinery --
//! no Python involved. Extension list and ignored-directory set mirror
//! `search_platform.core.DEFAULT_EXTENSIONS`/`IGNORED_DIRECTORIES` exactly,
//! so the same folder produces the same candidate file set as the Python
//! reference.
const std = @import("std");
const analysis = @import("analysis.zig");
const analyzer_v2 = @import("analyzer_v2.zig");
const chunker = @import("chunker.zig");
const engine_module = @import("engine.zig");
const generation_alloc = @import("generation_alloc.zig");
const hybrid = @import("hybrid.zig");
const incremental_state = @import("incremental_state.zig");
const lexical_build = @import("lexical_build.zig");
const lexical_segment = @import("lexical_segment.zig");
const lifecycle = @import("lifecycle.zig");
const manifest = @import("manifest.zig");
const postings = @import("postings.zig");
const segment = @import("segment.zig");
const snapshot_open = @import("snapshot_open.zig");

pub const AnalyzerId = enum {
    v1,
    v2,

    pub fn label(self: AnalyzerId) []const u8 {
        return switch (self) {
            .v1 => "analyzer-v1",
            .v2 => "analyzer-v2",
        };
    }

    pub fn parse(text: []const u8) ?AnalyzerId {
        if (std.mem.eql(u8, text, "analyzer-v1") or std.mem.eql(u8, text, "v1")) return .v1;
        if (std.mem.eql(u8, text, "analyzer-v2") or std.mem.eql(u8, text, "v2")) return .v2;
        return null;
    }
};

/// `search_platform.core.DEFAULT_EXTENSIONS`.
pub const default_extensions = [_][]const u8{
    ".c", ".cpp", ".css", ".go", ".h", ".html", ".java", ".js", ".json",
    ".md", ".py", ".rs", ".rst", ".toml", ".ts", ".txt", ".yaml", ".yml", ".zig",
};

/// `search_platform.core.IGNORED_DIRECTORIES`.
pub const ignored_directories = [_][]const u8{
    ".git", ".search", ".zig-cache", "__pycache__", "node_modules", "zig-out",
};

pub const IndexReport = struct {
    generation: u64,
    analyzer_id: []const u8,
    files_indexed: usize,
    files_skipped: usize,
    documents: usize,
    terms: usize,
    postings: usize,
};

fn hasAllowedExtension(name: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    const suffix = name[dot..];
    var lowered_buffer: [16]u8 = undefined;
    if (suffix.len > lowered_buffer.len) return false;
    for (suffix, 0..) |byte, i| lowered_buffer[i] = std.ascii.toLower(byte);
    const lowered = lowered_buffer[0..suffix.len];
    for (default_extensions) |candidate| {
        if (std.mem.eql(u8, candidate, lowered)) return true;
    }
    return false;
}

fn isIgnoredComponent(part: []const u8) bool {
    if (part.len > 0 and part[0] == '.') return true;
    for (ignored_directories) |ignored| {
        if (std.mem.eql(u8, ignored, part)) return true;
    }
    return false;
}

fn isIgnoredPath(relative_path: []const u8) bool {
    var it = std.mem.splitScalar(u8, relative_path, '/');
    while (it.next()) |part| {
        if (isIgnoredComponent(part)) return true;
    }
    return false;
}

fn lessThanPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Walk `root` and return every candidate file's relative path (matching
/// extension, not under an ignored directory/dotfile), sorted. Shared by
/// `indexFolder` and `indexFolderIncremental` so both see the same file set
/// for the same folder.
fn collectCandidatePaths(allocator: std.mem.Allocator, io: std.Io, root: std.Io.Dir) ![][]const u8 {
    var paths = std.ArrayList([]const u8).empty;
    var walker = try root.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (isIgnoredPath(entry.path)) continue;
        if (!hasAllowedExtension(entry.basename)) continue;
        try paths.append(allocator, try allocator.dupe(u8, entry.path));
    }
    const items = try paths.toOwnedSlice(allocator);
    std.mem.sort([]const u8, items, {}, lessThanPath);
    return items;
}

fn tokenizeV1(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var tokens = std.ArrayList([]const u8).empty;
    defer tokens.deinit(allocator);
    var iterator = analysis.TokenIterator.init(text);
    while (iterator.next()) |token| {
        const owned = try allocator.alloc(u8, token.bytes.len);
        for (token.bytes, 0..) |byte, i| owned[i] = std.ascii.toLower(byte);
        try tokens.append(allocator, owned);
    }
    return tokens.toOwnedSlice(allocator);
}

pub fn tokenize(allocator: std.mem.Allocator, analyzer: AnalyzerId, text: []const u8) ![][]const u8 {
    return switch (analyzer) {
        .v1 => tokenizeV1(allocator, text),
        .v2 => analyzer_v2.tokenize(allocator, text),
    };
}

/// Walk `root`, chunk and tokenize every matching file, and publish a fresh
/// generation into `out_dir`. `allocator` is expected to be an arena: every
/// document, token list, and encoded buffer this function produces is freed
/// together when the caller tears the arena down.
pub fn indexFolder(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    out_dir: std.Io.Dir,
    analyzer: AnalyzerId,
    generation: u64,
    max_chars: usize,
    overlap_lines: usize,
) !IndexReport {
    const paths = try collectCandidatePaths(allocator, io, root);

    var documents = std.ArrayList(hybrid.Document).empty;
    var files_skipped: usize = 0;

    for (paths) |relative_path| {
        const stat = root.statFile(io, relative_path, .{}) catch {
            files_skipped += 1;
            continue;
        };
        const size = std.math.cast(usize, stat.size) orelse {
            files_skipped += 1;
            continue;
        };
        const buffer = try allocator.alloc(u8, size);
        const content = root.readFile(io, relative_path, buffer) catch {
            files_skipped += 1;
            continue;
        };
        if (!std.unicode.utf8ValidateSlice(content)) {
            files_skipped += 1;
            continue;
        }

        const spans = chunker.chunk(allocator, content, max_chars, overlap_lines) catch {
            files_skipped += 1;
            continue;
        };
        for (spans) |span| {
            var id_hex: [20]u8 = undefined;
            chunker.chunkId(&id_hex, relative_path, span.start_line, span.end_line, span.text);
            const owned_id = try allocator.dupe(u8, &id_hex);
            try documents.append(allocator, .{
                .id = owned_id,
                .text = span.text,
                .vector = &.{},
                .path = relative_path,
                .start_line = span.start_line,
                .end_line = span.end_line,
            });
        }
    }

    if (documents.items.len == 0) return error.NoDocuments;

    var token_lists = try allocator.alloc([][]const u8, documents.items.len);
    for (documents.items, 0..) |document, i| {
        token_lists[i] = try tokenize(allocator, analyzer, document.text);
    }

    const lexical_index = try lexical_build.build(allocator, documents.items, token_lists);

    const documents_encoded_len = try segment.encodedLength(documents.items);
    const documents_buffer = try allocator.alloc(u8, documents_encoded_len);
    const documents_encoded = try segment.encode(documents.items, documents_buffer);

    const lexical_encoded_len = try lexical_segment.encodedLength(lexical_index);
    const lexical_buffer = try allocator.alloc(u8, lexical_encoded_len);
    const lexical_encoded = try lexical_segment.encode(lexical_index, lexical_buffer);

    const documents_file = try std.fmt.allocPrint(allocator, "documents-{d}.hybseg", .{generation});
    const lexical_file = try std.fmt.allocPrint(allocator, "lexical-{d}.hyblex", .{generation});

    const metadata = try manifest.create(
        generation,
        analyzer.label(),
        "none",
        documents_file,
        lexical_file,
        documents_encoded,
        lexical_encoded,
    );
    const manifest_len = try manifest.encodedLength(metadata);
    const manifest_buffer = try allocator.alloc(u8, manifest_len);
    const manifest_encoded = try manifest.encode(metadata, manifest_buffer);

    try lifecycle.publishSerialized(out_dir, io, manifest_encoded, documents_encoded, lexical_encoded);

    return .{
        .generation = generation,
        .analyzer_id = analyzer.label(),
        .files_indexed = paths.len - files_skipped,
        .files_skipped = files_skipped,
        .documents = documents.items.len,
        .terms = lexical_index.terms.len,
        .postings = lexical_index.postings.len,
    };
}

/// Caps applied to a single `indexFolderIncremental` run. Both come from the
/// caller's `opts` (CLI flags or `ss_index_folder`'s `opts` JSON object) --
/// see `docs/tasks/S1-T3.md` criterion 2.
pub const Caps = struct {
    /// A file larger than this (bytes) is never read; it is excluded from
    /// the index and counted under the report's `too_large`.
    max_file_bytes: u64 = 10 * 1024 * 1024,
    /// Once this many bytes have been read from disk in this run, remaining
    /// unprocessed candidate files are left untouched for this generation
    /// (their previous chunks, if any, are carried forward unchanged) and
    /// counted under the report's `skipped`. Guards worst-case run time on
    /// an enormous folder; a later `--update` run picks up where this one
    /// left off.
    max_total_bytes: u64 = 512 * 1024 * 1024,
};

pub const IncrementalReport = struct {
    generation: u64,
    analyzer_id: []const u8,
    added: usize,
    changed: usize,
    removed: usize,
    skipped: usize,
    too_large: usize,
    unreadable: usize,
    documents: usize,
    terms: usize,
    postings: usize,
};

fn hashHex(content: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(content);
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

/// Reconstruct each old document's token multiset directly from the
/// previous generation's already-built postings (`term`, per-document
/// `term_frequency`), instead of re-running the analyzer over its text.
/// This is what makes "unchanged files are skipped" a real, measured saving
/// rather than only skipping `chunker.chunk`: the lexical index still has
/// to be rebuilt in full every generation (no delta segments -- see
/// `docs/incremental-indexing.md`'s "Option C", explicitly out of scope
/// here), so every retained document's tokens are needed again, but pulling
/// them back out of postings is one linear pass over integers, not
/// NFC-normalizing and Unicode-category-classifying raw text again.
/// Token order within a document does not matter to `lexical_build.build`
/// (it only counts), so the reconstructed order (term-major) need not match
/// the original tokenization order.
fn reconstructTokensFromPostings(
    allocator: std.mem.Allocator,
    index: postings.Index,
    document_count: usize,
) ![][][]const u8 {
    if (document_count == 0) return &.{};
    const lists = try allocator.alloc(std.ArrayList([]const u8), document_count);
    for (lists) |*list| list.* = .empty;
    for (index.terms) |term_entry| {
        const term_postings = index.postings[term_entry.postings_start .. term_entry.postings_start + term_entry.postings_length];
        for (term_postings) |posting| {
            const document_index: usize = posting.document_index;
            var remaining = posting.term_frequency;
            while (remaining > 0) : (remaining -= 1) {
                try lists[document_index].append(allocator, term_entry.term);
            }
        }
    }
    const result = try allocator.alloc([][]const u8, document_count);
    for (lists, 0..) |*list, i| result[i] = try list.toOwnedSlice(allocator);
    return result;
}

/// Incremental folder indexing (S1-T3, `docs/tasks/S1-T3.md`; see also
/// `docs/incremental-indexing.md`, whose reuse contract this mirrors in the
/// native engine): re-walks `root`, hashes every candidate file's content,
/// and only re-reads/re-chunks files whose hash changed since the last
/// published generation in `out_dir` (or that are new). Deleted files are
/// tombstoned (their chunks are not carried into the new generation).
/// Unchanged files' chunks are carried forward from the *previous*
/// generation's document section, not re-chunked, which is the whole point:
/// the walk, hash, and disk read still happen for every candidate file (a
/// hash requires reading the bytes), but chunking and tokenizing -- and
/// certainly the original full-corpus rebuild -- do not.
///
/// Publishes a new generation (`out_dir`'s current generation + 1, routed
/// around any orphaned generation files via `generation_alloc.nextFreeGeneration`)
/// through the same `lifecycle.publishSerialized` atomic path `indexFolder`
/// uses, then -- only after that publish succeeds -- writes
/// `INDEX-STATE.json` (`incremental_state.zig`) recording every currently
/// indexed file's path/hash/size for the next incremental run.
///
/// Fails closed (`error.AnalyzerMismatch`) if `out_dir` already holds a
/// generation published with a different analyzer: mixing `analyzer-v1` and
/// `analyzer-v2` documents in one lexical index would silently produce
/// incoherent tokenization.
///
/// `allocator` is expected to be an arena, exactly like `indexFolder`.
pub fn indexFolderIncremental(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    out_dir: std.Io.Dir,
    analyzer: AnalyzerId,
    max_chars: usize,
    overlap_lines: usize,
    caps: Caps,
) !IncrementalReport {
    const paths = try collectCandidatePaths(allocator, io, root);

    const previous_engine: ?engine_module.Engine = snapshot_open.open(allocator, io, out_dir) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (previous_engine) |prev| {
        if (!std.mem.eql(u8, prev.analyzer_id, analyzer.label())) return error.AnalyzerMismatch;
    }

    var old_document_tokens: [][][]const u8 = &.{};
    var previous_indices_by_path = std.StringHashMap(std.ArrayList(usize)).init(allocator);
    if (previous_engine) |prev| {
        old_document_tokens = try reconstructTokensFromPostings(allocator, prev.lexical_index, prev.documents.len);
        for (prev.documents, 0..) |document, index| {
            const gop = try previous_indices_by_path.getOrPut(document.path);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(allocator, index);
        }
    }

    const previous_state = try incremental_state.load(allocator, io, out_dir);
    var previous_entry_by_path = std.StringHashMap(incremental_state.Entry).init(allocator);
    if (previous_state) |state| {
        for (state.files) |entry| try previous_entry_by_path.put(entry.path, entry);
    }

    var current_path_set = std.StringHashMap(void).init(allocator);
    for (paths) |path| try current_path_set.put(path, {});

    var documents = std.ArrayList(hybrid.Document).empty;
    var token_lists = std.ArrayList([][]const u8).empty;
    var new_state_entries = std.ArrayList(incremental_state.Entry).empty;

    var added: usize = 0;
    var changed: usize = 0;
    var skipped: usize = 0;
    var too_large: usize = 0;
    var unreadable: usize = 0;
    var total_bytes_processed: u64 = 0;
    var budget_exhausted = false;

    for (paths) |relative_path| {
        const previous_entry = previous_entry_by_path.get(relative_path);
        const previous_indices: []const usize = if (previous_indices_by_path.get(relative_path)) |list| list.items else &.{};

        // Append every old document (and its reconstructed token list, not
        // re-tokenized) that belonged to this path, then optionally record
        // its still-valid state entry. Used whenever this path is not
        // (re)chunked this run: unreadable, over budget, or unchanged.
        const carryForward = struct {
            fn run(
                a: std.mem.Allocator,
                docs: *std.ArrayList(hybrid.Document),
                toks: *std.ArrayList([][]const u8),
                state_entries: *std.ArrayList(incremental_state.Entry),
                prev_engine: ?engine_module.Engine,
                old_tokens: [][][]const u8,
                indices: []const usize,
                entry_for_path: ?incremental_state.Entry,
            ) !void {
                if (prev_engine) |prev| {
                    for (indices) |old_index| {
                        try docs.append(a, prev.documents[old_index]);
                        try toks.append(a, old_tokens[old_index]);
                    }
                }
                if (entry_for_path) |entry| try state_entries.append(a, entry);
            }
        }.run;

        const stat = root.statFile(io, relative_path, .{}) catch {
            unreadable += 1;
            try carryForward(allocator, &documents, &token_lists, &new_state_entries, previous_engine, old_document_tokens, previous_indices, previous_entry);
            continue;
        };
        const size = std.math.cast(usize, stat.size) orelse {
            unreadable += 1;
            try carryForward(allocator, &documents, &token_lists, &new_state_entries, previous_engine, old_document_tokens, previous_indices, previous_entry);
            continue;
        };

        if (size > caps.max_file_bytes) {
            too_large += 1;
            continue;
        }

        if (budget_exhausted or total_bytes_processed + size > caps.max_total_bytes) {
            budget_exhausted = true;
            skipped += 1;
            try carryForward(allocator, &documents, &token_lists, &new_state_entries, previous_engine, old_document_tokens, previous_indices, previous_entry);
            continue;
        }

        const buffer = try allocator.alloc(u8, size);
        const content = root.readFile(io, relative_path, buffer) catch {
            unreadable += 1;
            try carryForward(allocator, &documents, &token_lists, &new_state_entries, previous_engine, old_document_tokens, previous_indices, previous_entry);
            continue;
        };
        if (!std.unicode.utf8ValidateSlice(content)) {
            unreadable += 1;
            try carryForward(allocator, &documents, &token_lists, &new_state_entries, previous_engine, old_document_tokens, previous_indices, previous_entry);
            continue;
        }
        total_bytes_processed += size;

        const digest_hex = hashHex(content);
        if (previous_entry) |entry| {
            if (std.mem.eql(u8, entry.hash, &digest_hex)) {
                skipped += 1;
                try carryForward(allocator, &documents, &token_lists, &new_state_entries, previous_engine, old_document_tokens, previous_indices, null);
                try new_state_entries.append(allocator, entry);
                continue;
            }
        }

        const spans = chunker.chunk(allocator, content, max_chars, overlap_lines) catch {
            unreadable += 1;
            try carryForward(allocator, &documents, &token_lists, &new_state_entries, previous_engine, old_document_tokens, previous_indices, previous_entry);
            continue;
        };
        for (spans) |span| {
            var id_hex: [20]u8 = undefined;
            chunker.chunkId(&id_hex, relative_path, span.start_line, span.end_line, span.text);
            const owned_id = try allocator.dupe(u8, &id_hex);
            try documents.append(allocator, .{
                .id = owned_id,
                .text = span.text,
                .vector = &.{},
                .path = relative_path,
                .start_line = span.start_line,
                .end_line = span.end_line,
            });
            try token_lists.append(allocator, try tokenize(allocator, analyzer, span.text));
        }
        if (previous_entry != null) changed += 1 else added += 1;
        try new_state_entries.append(allocator, .{
            .path = relative_path,
            .hash = try allocator.dupe(u8, &digest_hex),
            .size = size,
        });
    }

    var removed: usize = 0;
    if (previous_state) |state| {
        for (state.files) |entry| {
            if (!current_path_set.contains(entry.path)) removed += 1;
        }
    }

    if (documents.items.len == 0) return error.NoDocuments;

    const lexical_index = try lexical_build.build(allocator, documents.items, token_lists.items);

    const documents_encoded_len = try segment.encodedLength(documents.items);
    const documents_buffer = try allocator.alloc(u8, documents_encoded_len);
    const documents_encoded = try segment.encode(documents.items, documents_buffer);

    const lexical_encoded_len = try lexical_segment.encodedLength(lexical_index);
    const lexical_buffer = try allocator.alloc(u8, lexical_encoded_len);
    const lexical_encoded = try lexical_segment.encode(lexical_index, lexical_buffer);

    const generation = try generation_alloc.nextFreeGeneration(allocator, io, out_dir);
    const documents_file = try std.fmt.allocPrint(allocator, "documents-{d}.hybseg", .{generation});
    const lexical_file = try std.fmt.allocPrint(allocator, "lexical-{d}.hyblex", .{generation});

    const metadata = try manifest.create(
        generation,
        analyzer.label(),
        "none",
        documents_file,
        lexical_file,
        documents_encoded,
        lexical_encoded,
    );
    const manifest_len = try manifest.encodedLength(metadata);
    const manifest_buffer = try allocator.alloc(u8, manifest_len);
    const manifest_encoded = try manifest.encode(metadata, manifest_buffer);

    try lifecycle.publishSerialized(out_dir, io, manifest_encoded, documents_encoded, lexical_encoded);

    // Only after the generation is durably published: persist the state
    // that lets the *next* incremental run skip unchanged files again. A
    // crash before this point leaves the previous state file in place (see
    // `incremental_state.zig`'s doc comment); a crash after this point is
    // indistinguishable from a normal run that finished.
    try incremental_state.save(io, out_dir, allocator, .{
        .generation = generation,
        .analyzer_id = analyzer.label(),
        .files = new_state_entries.items,
    });

    return .{
        .generation = generation,
        .analyzer_id = analyzer.label(),
        .added = added,
        .changed = changed,
        .removed = removed,
        .skipped = skipped,
        .too_large = too_large,
        .unreadable = unreadable,
        .documents = documents.items.len,
        .terms = lexical_index.terms.len,
        .postings = lexical_index.postings.len,
    };
}

test "indexFolder publishes a queryable generation from a real folder" {
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

    const report = try indexFolder(arena, io, tmp.dir, out_dir, .v2, 1, chunker.default_max_chars, chunker.default_overlap_lines);
    try std.testing.expectEqual(@as(usize, 1), report.files_indexed);
    try std.testing.expect(report.documents >= 1);
    try std.testing.expectEqualStrings("analyzer-v2", report.analyzer_id);
}

test "hasAllowedExtension matches DEFAULT_EXTENSIONS case-insensitively" {
    try std.testing.expect(hasAllowedExtension("README.MD"));
    try std.testing.expect(hasAllowedExtension("main.zig"));
    try std.testing.expect(!hasAllowedExtension("image.png"));
    try std.testing.expect(!hasAllowedExtension("noext"));
}

test "isIgnoredPath skips dotfiles and ignored directories" {
    try std.testing.expect(isIgnoredPath(".git/config"));
    try std.testing.expect(isIgnoredPath("node_modules/pkg/index.js"));
    try std.testing.expect(isIgnoredPath("src/.hidden.md"));
    try std.testing.expect(!isIgnoredPath("src/main.md"));
}
