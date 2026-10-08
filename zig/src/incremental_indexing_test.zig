//! S1-T3 acceptance criterion 3: a fixture folder mutated in five steps
//! (add, edit, delete, rename, oversize), asserting the report and query
//! results after each step; plus a crash-mid-publication recovery test
//! using the existing scanner (`lifecycle.scan`).
const std = @import("std");
const chunker = @import("chunker.zig");
const generation_alloc = @import("generation_alloc.zig");
const hybrid = @import("hybrid.zig");
const indexer = @import("indexer.zig");
const lifecycle = @import("lifecycle.zig");
const snapshot_open = @import("snapshot_open.zig");

const default_caps = indexer.Caps{};

fn indexOnce(arena: std.mem.Allocator, io: std.Io, root: std.Io.Dir, out: std.Io.Dir) !indexer.IncrementalReport {
    return indexer.indexFolderIncremental(
        arena,
        io,
        root,
        out,
        .v2,
        chunker.default_max_chars,
        chunker.default_overlap_lines,
        default_caps,
    );
}

fn queryPaths(arena: std.mem.Allocator, io: std.Io, out: std.Io.Dir, query_text: []const u8) ![]const []const u8 {
    const opened = try snapshot_open.open(arena, io, out);
    const results = try arena.alloc(hybrid.Result, opened.documents.len);
    const found = try opened.queryTokenized(arena, query_text, &.{}, results, .{
        .top_k = opened.documents.len,
        .candidate_k = opened.documents.len,
        .retrieval_mode = .lexical,
    });
    var paths = std.ArrayList([]const u8).empty;
    for (found) |result| {
        if (result.fused_score > 0) try paths.append(arena, result.path);
    }
    return paths.toOwnedSlice(arena);
}

fn containsPath(paths: []const []const u8, path: []const u8) bool {
    for (paths) |candidate| {
        if (std.mem.eql(u8, candidate, path)) return true;
    }
    return false;
}

test "five-step fixture mutation: add, edit, delete, rename, oversize" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root = try tmp.dir.createDirPathOpen(io, "root", .{ .open_options = .{ .iterate = true } });
    defer root.close(io);
    try tmp.dir.createDir(io, "out", .default_dir);
    var out = try tmp.dir.openDir(io, "out", .{ .iterate = true });
    defer out.close(io);

    // --- step 0: baseline, two files ---------------------------------
    try root.writeFile(io, .{ .sub_path = "alpha.md", .data = "alpha document about hybrid retrieval systems\n" });
    try root.writeFile(io, .{ .sub_path = "beta.md", .data = "beta document about lexical search ranking\n" });

    {
        const report = try indexOnce(arena, io, root, out);
        try std.testing.expectEqual(@as(u64, 1), report.generation);
        try std.testing.expectEqual(@as(usize, 2), report.added);
        try std.testing.expectEqual(@as(usize, 0), report.changed);
        try std.testing.expectEqual(@as(usize, 0), report.removed);
        try std.testing.expectEqual(@as(usize, 0), report.unchanged);
        try std.testing.expectEqual(@as(usize, 0), report.budget_exhausted);
        try std.testing.expectEqual(@as(usize, 0), report.too_large);
        try std.testing.expectEqual(@as(usize, 0), report.unreadable);

        const hits = try queryPaths(arena, io, out, "hybrid");
        try std.testing.expect(containsPath(hits, "alpha.md"));
    }

    // --- step 1: add a third file -------------------------------------
    try root.writeFile(io, .{ .sub_path = "gamma.md", .data = "gamma document about vector embeddings\n" });
    {
        const report = try indexOnce(arena, io, root, out);
        try std.testing.expectEqual(@as(u64, 2), report.generation);
        try std.testing.expectEqual(@as(usize, 1), report.added);
        try std.testing.expectEqual(@as(usize, 0), report.changed);
        try std.testing.expectEqual(@as(usize, 0), report.removed);
        try std.testing.expectEqual(@as(usize, 2), report.unchanged); // alpha, beta unchanged
        try std.testing.expectEqual(@as(usize, 0), report.budget_exhausted);

        const hits = try queryPaths(arena, io, out, "embeddings");
        try std.testing.expect(containsPath(hits, "gamma.md"));
    }

    // --- step 2: edit beta.md ------------------------------------------
    try root.writeFile(io, .{ .sub_path = "beta.md", .data = "beta document now about quantum reranking instead\n" });
    {
        const report = try indexOnce(arena, io, root, out);
        try std.testing.expectEqual(@as(u64, 3), report.generation);
        try std.testing.expectEqual(@as(usize, 0), report.added);
        try std.testing.expectEqual(@as(usize, 1), report.changed);
        try std.testing.expectEqual(@as(usize, 0), report.removed);
        try std.testing.expectEqual(@as(usize, 2), report.unchanged); // alpha, gamma unchanged

        const old_hits = try queryPaths(arena, io, out, "ranking");
        try std.testing.expect(!containsPath(old_hits, "beta.md"));
        const new_hits = try queryPaths(arena, io, out, "quantum");
        try std.testing.expect(containsPath(new_hits, "beta.md"));
    }

    // --- step 3: delete gamma.md -----------------------------------------
    try root.deleteFile(io, "gamma.md");
    {
        const report = try indexOnce(arena, io, root, out);
        try std.testing.expectEqual(@as(u64, 4), report.generation);
        try std.testing.expectEqual(@as(usize, 0), report.added);
        try std.testing.expectEqual(@as(usize, 0), report.changed);
        try std.testing.expectEqual(@as(usize, 1), report.removed);
        try std.testing.expectEqual(@as(usize, 2), report.unchanged); // alpha, beta unchanged

        const hits = try queryPaths(arena, io, out, "embeddings");
        try std.testing.expect(!containsPath(hits, "gamma.md"));
    }

    // --- step 4: rename alpha.md -> delta.md (delete + add) ---------------
    const alpha_bytes = try root.readFileAlloc(io, "alpha.md", arena, .unlimited);
    try root.writeFile(io, .{ .sub_path = "delta.md", .data = alpha_bytes });
    try root.deleteFile(io, "alpha.md");
    {
        const report = try indexOnce(arena, io, root, out);
        try std.testing.expectEqual(@as(u64, 5), report.generation);
        try std.testing.expectEqual(@as(usize, 1), report.added); // delta.md, new path
        try std.testing.expectEqual(@as(usize, 0), report.changed);
        try std.testing.expectEqual(@as(usize, 1), report.removed); // alpha.md gone
        try std.testing.expectEqual(@as(usize, 1), report.unchanged); // beta.md unchanged

        const hits = try queryPaths(arena, io, out, "hybrid");
        try std.testing.expect(containsPath(hits, "delta.md"));
        try std.testing.expect(!containsPath(hits, "alpha.md"));
    }

    // --- step 5: oversize file, capped out -------------------------------
    const oversize_content = try arena.alloc(u8, 64);
    @memset(oversize_content, 'z');
    try root.writeFile(io, .{ .sub_path = "huge.md", .data = oversize_content });
    {
        const tiny_caps = indexer.Caps{ .max_file_bytes = 55, .max_total_bytes = default_caps.max_total_bytes };
        const report = try indexer.indexFolderIncremental(
            arena,
            io,
            root,
            out,
            .v2,
            chunker.default_max_chars,
            chunker.default_overlap_lines,
            tiny_caps,
        );
        try std.testing.expectEqual(@as(u64, 6), report.generation);
        try std.testing.expectEqual(@as(usize, 0), report.added);
        try std.testing.expectEqual(@as(usize, 0), report.changed);
        try std.testing.expectEqual(@as(usize, 0), report.removed);
        try std.testing.expectEqual(@as(usize, 1), report.too_large); // huge.md excluded
        try std.testing.expectEqual(@as(usize, 1), report.too_large_paths.len);
        try std.testing.expectEqualStrings("huge.md", report.too_large_paths[0]);
        try std.testing.expectEqual(@as(usize, 2), report.unchanged); // beta.md, delta.md unchanged

        const hits = try queryPaths(arena, io, out, "zzz");
        try std.testing.expectEqual(@as(usize, 0), hits.len); // huge.md never indexed
    }
}

test "crash mid-publication: an orphaned generation file does not corrupt the current snapshot, and the existing scanner sees it" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root = try tmp.dir.createDirPathOpen(io, "root", .{ .open_options = .{ .iterate = true } });
    defer root.close(io);
    try tmp.dir.createDir(io, "out", .default_dir);
    var out = try tmp.dir.openDir(io, "out", .{ .iterate = true });
    defer out.close(io);

    try root.writeFile(io, .{ .sub_path = "note.md", .data = "search evidence combines lexical and semantic ranks\n" });
    const first = try indexOnce(arena, io, root, out);
    try std.testing.expectEqual(@as(u64, 1), first.generation);

    // Simulate a process that crashed mid-publication of generation 2:
    // an immutable document-section file was linked (per
    // `docs/publication-recovery.md`'s crash-visibility matrix, "after
    // only document file") but the process died before MANIFEST was
    // replaced, so MANIFEST still names generation 1 and this file is an
    // orphan.
    try out.writeFile(io, .{ .sub_path = "documents-2.hybseg", .data = "not a real section, just an orphan from a crash" });

    // The existing recovery scanner sees exactly this: generation 1 is
    // still current, and there is one orphaned document-section file.
    var manifest_buffer: [4096]u8 = undefined;
    var documents_buffer: [65536]u8 = undefined;
    var lexical_buffer: [65536]u8 = undefined;
    const scan = try lifecycle.scan(out, io, &manifest_buffer, &documents_buffer, &lexical_buffer);
    try std.testing.expectEqual(@as(?u64, 1), scan.current_generation);
    try std.testing.expectEqual(@as(usize, 1), scan.orphan_document_files);
    try std.testing.expectEqual(@as(usize, 0), scan.orphan_lexical_files);

    // The snapshot is still exactly generation 1 and still queryable --
    // the crash orphan did not corrupt anything.
    {
        const opened = try snapshot_open.open(arena, io, out);
        try std.testing.expectEqual(@as(u64, 1), opened.generation);
    }

    // A subsequent incremental run must not blindly try generation 2 again
    // (it would fail with the very `PathAlreadyExists` docs/tasks/S1-T1.md
    // found) -- `generation_alloc.nextFreeGeneration` routes around the
    // orphan, and indexing recovers cleanly.
    try root.writeFile(io, .{ .sub_path = "note2.md", .data = "a second note about recovery and publication\n" });
    const second = try indexOnce(arena, io, root, out);
    try std.testing.expectEqual(@as(u64, 3), second.generation); // skipped the occupied generation 2
    try std.testing.expectEqual(@as(usize, 1), second.added);
    try std.testing.expectEqual(@as(usize, 1), second.unchanged);

    const opened_after = try snapshot_open.open(arena, io, out);
    try std.testing.expectEqual(@as(u64, 3), opened_after.generation);
    try std.testing.expectEqual(@as(usize, 2), opened_after.documents.len);

    // The orphan is still there, untouched -- recovery scanning classifies,
    // it does not delete (`docs/generation-lifecycle.md`). Generation 3 is
    // now current, so generation 1's files have also become orphans (no GC
    // is implemented): the injected crash orphan (generation 2) plus
    // generation 1's superseded document file, two in total.
    const rescan = try lifecycle.scan(out, io, &manifest_buffer, &documents_buffer, &lexical_buffer);
    try std.testing.expectEqual(@as(?u64, 3), rescan.current_generation);
    // S2-T5: files of generations older than the current one are reported
    // as `superseded_*` (retained history) rather than `orphan_*`; the
    // total of unreferenced files is unchanged (2 document files, 1 lexical).
    try std.testing.expectEqual(@as(usize, 2), rescan.orphan_document_files + rescan.superseded_document_files);
    try std.testing.expectEqual(@as(usize, 1), rescan.orphan_lexical_files + rescan.superseded_lexical_files);
    try std.testing.expectEqual(@as(usize, 2), rescan.superseded_document_files);
    try std.testing.expectEqual(@as(usize, 1), rescan.superseded_lexical_files);
}

test "AnalyzerMismatch is rejected rather than silently mixing tokenizations" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root = try tmp.dir.createDirPathOpen(io, "root", .{ .open_options = .{ .iterate = true } });
    defer root.close(io);
    try tmp.dir.createDir(io, "out", .default_dir);
    var out = try tmp.dir.openDir(io, "out", .{ .iterate = true });
    defer out.close(io);

    try root.writeFile(io, .{ .sub_path = "note.md", .data = "hybrid retrieval combines lexical and semantic ranks\n" });
    _ = try indexer.indexFolderIncremental(arena, io, root, out, .v1, chunker.default_max_chars, chunker.default_overlap_lines, default_caps);

    try std.testing.expectError(error.AnalyzerMismatch, indexer.indexFolderIncremental(
        arena,
        io,
        root,
        out,
        .v2,
        chunker.default_max_chars,
        chunker.default_overlap_lines,
        default_caps,
    ));
}

test "last-file deletion publishes an empty generation instead of NoDocuments" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root = try tmp.dir.createDirPathOpen(io, "root", .{ .open_options = .{ .iterate = true } });
    defer root.close(io);
    try tmp.dir.createDir(io, "out", .default_dir);
    var out = try tmp.dir.openDir(io, "out", .{ .iterate = true });
    defer out.close(io);

    try root.writeFile(io, .{ .sub_path = "only.md", .data = "the only file in this folder, about to be deleted\n" });
    const first = try indexOnce(arena, io, root, out);
    try std.testing.expectEqual(@as(usize, 1), first.documents);

    try root.deleteFile(io, "only.md");
    const second = try indexOnce(arena, io, root, out);
    try std.testing.expectEqual(@as(u64, 2), second.generation);
    try std.testing.expectEqual(@as(usize, 1), second.removed);
    try std.testing.expectEqual(@as(usize, 0), second.documents);
    try std.testing.expectEqual(@as(usize, 0), second.terms);

    const opened = try snapshot_open.open(arena, io, out);
    try std.testing.expectEqual(@as(u64, 2), opened.generation);
    try std.testing.expectEqual(@as(usize, 0), opened.documents.len);

    // A folder that was never indexed and has no candidate files at all
    // also publishes (generation 1, not an error).
    var tmp2 = std.testing.tmpDir(.{ .iterate = true });
    defer tmp2.cleanup();
    var empty_root = try tmp2.dir.createDirPathOpen(io, "root", .{ .open_options = .{ .iterate = true } });
    defer empty_root.close(io);
    try tmp2.dir.createDir(io, "out", .default_dir);
    var empty_out = try tmp2.dir.openDir(io, "out", .{ .iterate = true });
    defer empty_out.close(io);
    const empty_report = try indexOnce(arena, io, empty_root, empty_out);
    try std.testing.expectEqual(@as(u64, 1), empty_report.generation);
    try std.testing.expectEqual(@as(usize, 0), empty_report.documents);
}

test "a file over max_total_bytes is reported budget_exhausted, distinct from unchanged" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root = try tmp.dir.createDirPathOpen(io, "root", .{ .open_options = .{ .iterate = true } });
    defer root.close(io);
    try tmp.dir.createDir(io, "out", .default_dir);
    var out = try tmp.dir.openDir(io, "out", .{ .iterate = true });
    defer out.close(io);

    try root.writeFile(io, .{ .sub_path = "alpha.md", .data = "alpha document about hybrid retrieval systems\n" });
    try root.writeFile(io, .{ .sub_path = "beta.md", .data = "beta document about lexical search ranking\n" });

    // A budget that only ever admits the first (alphabetically sorted)
    // candidate file: alpha.md is read, beta.md is left for a later run.
    const tiny_budget = indexer.Caps{ .max_total_bytes = 48 };
    const report = try indexer.indexFolderIncremental(arena, io, root, out, .v2, chunker.default_max_chars, chunker.default_overlap_lines, tiny_budget);
    try std.testing.expectEqual(@as(usize, 1), report.added);
    try std.testing.expectEqual(@as(usize, 0), report.unchanged);
    try std.testing.expectEqual(@as(usize, 1), report.budget_exhausted);

    // A second run with the default (huge) budget picks up beta.md, which
    // the first run left untouched -- it is reported "added", not
    // "unchanged", because it was never actually indexed before.
    const second = try indexOnce(arena, io, root, out);
    try std.testing.expectEqual(@as(usize, 1), second.added);
    try std.testing.expectEqual(@as(usize, 0), second.budget_exhausted);
}

test "an unreadable file's path is listed and its previous chunks are kept" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root = try tmp.dir.createDirPathOpen(io, "root", .{ .open_options = .{ .iterate = true } });
    defer root.close(io);
    try tmp.dir.createDir(io, "out", .default_dir);
    var out = try tmp.dir.openDir(io, "out", .{ .iterate = true });
    defer out.close(io);

    try root.writeFile(io, .{ .sub_path = "alpha.md", .data = "alpha document about hybrid retrieval systems\n" });
    const first = try indexOnce(arena, io, root, out);
    try std.testing.expectEqual(@as(usize, 1), first.documents);

    // A file that becomes invalid UTF-8 after it was already indexed is
    // "unreadable", not "too_large": its previous chunks are kept.
    try root.writeFile(io, .{ .sub_path = "alpha.md", .data = &[_]u8{ 0xff, 0xfe, 0x00 } });
    const second = try indexOnce(arena, io, root, out);
    try std.testing.expectEqual(@as(usize, 1), second.unreadable);
    try std.testing.expectEqual(@as(usize, 1), second.unreadable_paths.len);
    try std.testing.expectEqualStrings("alpha.md", second.unreadable_paths[0]);
    try std.testing.expectEqual(@as(usize, 1), second.documents); // kept, not tombstoned

    const hits = try queryPaths(arena, io, out, "hybrid");
    try std.testing.expect(containsPath(hits, "alpha.md"));
}

test "a file grown past max_file_bytes is reported too_large and its old chunks are tombstoned" {
    // docs/tasks/S1-T4.md criterion 3: unlike an unreadable file (kept), a
    // file that grows past the cap must lose its previously indexed chunks
    // -- this is the "grown past the cap", not "new and already oversized",
    // case the five-step fixture's `huge.md` step does not cover.
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root = try tmp.dir.createDirPathOpen(io, "root", .{ .open_options = .{ .iterate = true } });
    defer root.close(io);
    try tmp.dir.createDir(io, "out", .default_dir);
    var out = try tmp.dir.openDir(io, "out", .{ .iterate = true });
    defer out.close(io);

    // grows.md starts small (indexed normally); keeper.md never changes,
    // so its continued presence proves the tombstoning is specific to
    // grows.md, not a wipe of the whole generation.
    try root.writeFile(io, .{ .sub_path = "grows.md", .data = "a short document about hybrid retrieval\n" });
    try root.writeFile(io, .{ .sub_path = "keeper.md", .data = "an unrelated document about lexical scoring\n" });

    const small_caps = indexer.Caps{ .max_file_bytes = 64 };
    const first = try indexer.indexFolderIncremental(arena, io, root, out, .v2, chunker.default_max_chars, chunker.default_overlap_lines, small_caps);
    try std.testing.expectEqual(@as(usize, 2), first.added);
    try std.testing.expectEqual(@as(usize, 0), first.too_large);
    try std.testing.expectEqual(@as(usize, 2), first.documents);

    const before_hits = try queryPaths(arena, io, out, "hybrid");
    try std.testing.expect(containsPath(before_hits, "grows.md"));

    // grows.md grows past the 64-byte cap.
    const grown_content = try arena.alloc(u8, 128);
    @memset(grown_content, 'z');
    try root.writeFile(io, .{ .sub_path = "grows.md", .data = grown_content });

    const second = try indexer.indexFolderIncremental(arena, io, root, out, .v2, chunker.default_max_chars, chunker.default_overlap_lines, small_caps);
    try std.testing.expectEqual(@as(usize, 1), second.too_large);
    try std.testing.expectEqual(@as(usize, 1), second.too_large_paths.len);
    try std.testing.expectEqualStrings("grows.md", second.too_large_paths[0]);
    try std.testing.expectEqual(@as(usize, 1), second.unchanged); // keeper.md
    // Tombstoned, not silently kept: grows.md's previous chunk is gone from
    // the new generation entirely -- documents drops from 2 to 1.
    try std.testing.expectEqual(@as(usize, 1), second.documents);

    const after_hits = try queryPaths(arena, io, out, "hybrid");
    try std.testing.expect(!containsPath(after_hits, "grows.md"));
    try std.testing.expect(containsPath(try queryPaths(arena, io, out, "lexical"), "keeper.md"));

    // And it stays gone on the next run: not re-carried-forward from stale
    // INDEX-STATE.json, and not re-admitted just because the cap wasn't
    // re-checked.
    const third = try indexer.indexFolderIncremental(arena, io, root, out, .v2, chunker.default_max_chars, chunker.default_overlap_lines, small_caps);
    try std.testing.expectEqual(@as(usize, 1), third.too_large);
    try std.testing.expectEqual(@as(usize, 1), third.documents);
}

// === S2-T5: keep_generations ================================================

const CountedFiles = struct { documents: usize = 0, lexical: usize = 0, control: usize = 0, other: usize = 0 };

fn countFiles(io: std.Io, dir: std.Io.Dir) !CountedFiles {
    var counted = CountedFiles{};
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".hybseg")) {
            counted.documents += 1;
        } else if (std.mem.endsWith(u8, entry.name, ".hyblex")) {
            counted.lexical += 1;
        } else if (std.mem.eql(u8, entry.name, "MANIFEST") or std.mem.eql(u8, entry.name, "WRITER.LOCK") or
            std.mem.eql(u8, entry.name, "INDEX-STATE.json"))
        {
            counted.control += 1;
        } else {
            counted.other += 1;
        }
    }
    return counted;
}

fn publishTwenty(arena: std.mem.Allocator, io: std.Io, keep: ?usize) !CountedFiles {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root = try tmp.dir.createDirPathOpen(io, "root", .{ .open_options = .{ .iterate = true } });
    defer root.close(io);
    try tmp.dir.createDir(io, "out", .default_dir);
    var out = try tmp.dir.openDir(io, "out", .{ .iterate = true });
    defer out.close(io);
    try root.writeFile(io, .{ .sub_path = "note.md", .data = "search evidence combines lexical and semantic ranks\n" });

    var caps = indexer.Caps{};
    caps.keep_generations = keep;
    var last_pruned: usize = 0;
    var generation: u64 = 0;
    for (0..20) |_| {
        const gio = io;
        generation = try generation_alloc.nextFreeGeneration(arena, gio, out);
        const report = try indexer.indexFolder(arena, gio, root, out, .v2, generation, chunker.default_max_chars, chunker.default_overlap_lines, caps);
        last_pruned = report.pruned_files;
        try std.testing.expectEqual(@as(usize, 0), report.prune_failures);
    }
    try std.testing.expectEqual(@as(u64, 20), generation);
    if (keep != null) try std.testing.expectEqual(@as(usize, 2), last_pruned); // gen 18's two files

    var manifest_buffer: [4096]u8 = undefined;
    var documents_buffer: [65536]u8 = undefined;
    var lexical_buffer: [65536]u8 = undefined;
    const scan = try lifecycle.scan(out, io, &manifest_buffer, &documents_buffer, &lexical_buffer);
    try std.testing.expectEqual(@as(?u64, 20), scan.current_generation);
    try std.testing.expectEqual(@as(usize, 2), scan.current_files);
    try std.testing.expectEqual(@as(usize, 0), scan.orphan_document_files);
    try std.testing.expectEqual(@as(usize, 0), scan.orphan_lexical_files);
    try std.testing.expectEqual(@as(usize, 0), scan.unknown_files);
    // The current generation is still openable and queryable.
    const opened = try snapshot_open.open(arena, io, out);
    try std.testing.expectEqual(@as(u64, 20), opened.generation);
    return try countFiles(io, out);
}

test "keep_generations=2 leaves exactly two generations over 20 publishes; absent keeps all" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    const kept = try publishTwenty(arena, io, 2);
    try std.testing.expectEqual(@as(usize, 2), kept.documents);
    try std.testing.expectEqual(@as(usize, 2), kept.lexical);
    try std.testing.expectEqual(@as(usize, 3), kept.control); // MANIFEST, WRITER.LOCK, INDEX-STATE.json
    try std.testing.expectEqual(@as(usize, 0), kept.other);

    const all = try publishTwenty(arena, io, null);
    try std.testing.expectEqual(@as(usize, 20), all.documents);
    try std.testing.expectEqual(@as(usize, 20), all.lexical);
    try std.testing.expectEqual(@as(usize, 3), all.control);
}

test "pruning touches only superseded canonical section files" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    inline for (.{ "documents-1.hybseg", "lexical-1.hyblex", "documents-2.hybseg", "lexical-2.hyblex", "documents-3.hybseg", "lexical-3.hyblex", "documents-9.hybseg", "documents-04.hybseg", "documents-x.hybseg", "MANIFEST", "INDEX-STATE.json", "WRITER.LOCK", "notes.txt" }) |name| {
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "x" });
    }
    // Current generation 3, keep 2: generation 2 survives, generation 1 goes.
    const report = lifecycle.pruneSuperseded(std.testing.allocator, tmp.dir, io, 2, 3, "documents-3.hybseg", "lexical-3.hyblex");
    try std.testing.expectEqual(@as(usize, 2), report.deleted);
    try std.testing.expectEqual(@as(usize, 0), report.failed);
    inline for (.{ "documents-1.hybseg", "lexical-1.hyblex" }) |gone| {
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, gone, .{}));
    }
    inline for (.{ "documents-2.hybseg", "lexical-2.hyblex", "documents-3.hybseg", "lexical-3.hyblex", "documents-9.hybseg", "documents-04.hybseg", "documents-x.hybseg", "MANIFEST", "INDEX-STATE.json", "WRITER.LOCK", "notes.txt" }) |kept| {
        _ = try tmp.dir.statFile(io, kept, .{});
    }
    // keep=1 removes every older generation, still never the current one.
    const second = lifecycle.pruneSuperseded(std.testing.allocator, tmp.dir, io, 1, 3, "documents-3.hybseg", "lexical-3.hyblex");
    try std.testing.expectEqual(@as(usize, 2), second.deleted);
    _ = try tmp.dir.statFile(io, "documents-3.hybseg", .{});
    _ = try tmp.dir.statFile(io, "lexical-3.hyblex", .{});
}

test "keep_generations of zero is rejected before anything is written" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try std.testing.expectError(
        error.InvalidKeepGenerations,
        lifecycle.publishSerializedKeeping(arena_state.allocator(), tmp.dir, io, "", "", "", 0),
    );
}

// S2-T5 rework: a lone crash leftover is never counted as a kept generation.
test "keep_generations counts only complete generations and always prunes a lone leftover" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root = try tmp.dir.createDirPathOpen(io, "root", .{ .open_options = .{ .iterate = true } });
    defer root.close(io);
    try tmp.dir.createDir(io, "out", .default_dir);
    var out = try tmp.dir.openDir(io, "out", .{ .iterate = true });
    defer out.close(io);
    try root.writeFile(io, .{ .sub_path = "note.md", .data = "search evidence combines lexical and semantic ranks\n" });

    // Generations 1..4 complete, no pruning.
    for (1..5) |g| {
        _ = try indexer.indexFolder(arena, io, root, out, .v2, g, chunker.default_max_chars, chunker.default_overlap_lines, .{});
    }
    // A crash between the two section links left a lone generation-5 file.
    try out.writeFile(io, .{ .sub_path = "documents-5.hybseg", .data = "half-written leftover" });

    var caps = indexer.Caps{};
    caps.keep_generations = 2;
    const report = try indexer.indexFolder(arena, io, root, out, .v2, 6, chunker.default_max_chars, chunker.default_overlap_lines, caps);
    // Deleted: generations 1, 2, 3 (2 files each) and the lone leftover.
    try std.testing.expectEqual(@as(usize, 7), report.pruned_files);
    try std.testing.expectEqual(@as(usize, 0), report.prune_failures);

    // Kept: the current generation 6 and the newest COMPLETE older one, 4.
    inline for (.{ "documents-4.hybseg", "lexical-4.hyblex", "documents-6.hybseg", "lexical-6.hyblex" }) |name| {
        _ = try out.statFile(io, name, .{});
    }
    inline for (.{ "documents-5.hybseg", "documents-3.hybseg", "lexical-3.hyblex", "documents-1.hybseg" }) |name| {
        try std.testing.expectError(error.FileNotFound, out.statFile(io, name, .{}));
    }
    const counted = try countFiles(io, out);
    try std.testing.expectEqual(@as(usize, 2), counted.documents);
    try std.testing.expectEqual(@as(usize, 2), counted.lexical);
}

// S2-T5 rework: MANIFEST present but a section it names is gone. `--update`
// must not trust INDEX-STATE.json (which marks everything unchanged) and
// publish an empty generation; it re-indexes everything and says so.
test "update with a missing section re-indexes every file instead of publishing an empty generation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root = try tmp.dir.createDirPathOpen(io, "root", .{ .open_options = .{ .iterate = true } });
    defer root.close(io);
    try tmp.dir.createDir(io, "out", .default_dir);
    var out = try tmp.dir.openDir(io, "out", .{ .iterate = true });
    defer out.close(io);
    try root.writeFile(io, .{ .sub_path = "a.md", .data = "alpha evidence about recovery\n" });
    try root.writeFile(io, .{ .sub_path = "b.md", .data = "beta evidence about publication\n" });
    try root.writeFile(io, .{ .sub_path = "c.md", .data = "gamma evidence about directories\n" });

    const first = try indexOnce(arena, io, root, out);
    try std.testing.expectEqual(@as(u64, 1), first.generation);
    try std.testing.expectEqual(@as(usize, 3), first.documents);
    try std.testing.expect(first.recovered == null);

    try out.deleteFile(io, "lexical-1.hyblex");

    const healed = try indexOnce(arena, io, root, out);
    try std.testing.expectEqual(@as(u64, 2), healed.generation);
    try std.testing.expectEqual(@as(usize, 3), healed.documents); // never 0
    try std.testing.expectEqual(@as(usize, 3), healed.added);
    try std.testing.expectEqual(@as(usize, 0), healed.unchanged);
    try std.testing.expectEqualStrings("missing_section", healed.recovered.?);

    const opened = try snapshot_open.open(arena, io, out);
    try std.testing.expectEqual(@as(u64, 2), opened.generation);
    try std.testing.expectEqual(@as(usize, 3), opened.documents.len);

    // The next run is an ordinary update again.
    const again = try indexOnce(arena, io, root, out);
    try std.testing.expect(again.recovered == null);
    try std.testing.expectEqual(@as(usize, 3), again.unchanged);
}
