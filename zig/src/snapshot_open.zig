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

    const documents = try allocator.alloc(hybrid.Document, metadata.document_count);
    const vector_count = std.math.mul(usize, metadata.document_count, metadata.vector_dimensions) catch
        return error.IndexTooLarge;
    const vectors = try allocator.alloc(f32, vector_count);
    const terms = try allocator.alloc(postings.TermEntry, metadata.term_count);
    const posting_storage = try allocator.alloc(postings.Posting, metadata.posting_count);
    const document_lengths = try allocator.alloc(u32, metadata.document_count);

    return engine.Engine.open(snapshot, documents, vectors, terms, posting_storage, document_lengths);
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

    _ = try indexer.indexFolder(arena, io, tmp.dir, out_dir, .v2, 1, chunker.default_max_chars, chunker.default_overlap_lines);

    const opened = try open(arena, io, out_dir);
    try std.testing.expectEqualStrings("analyzer-v2", opened.analyzer_id);
    try std.testing.expectEqual(@as(usize, 1), opened.documents.len);
}
