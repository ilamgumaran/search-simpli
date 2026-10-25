const incremental_state = @import("incremental_state.zig");
const manifest = @import("manifest.zig");
const publication = @import("publication.zig");
const std = @import("std");

pub const writer_lock_file = "WRITER.LOCK";

pub const WriterLease = struct {
    file: std.Io.File,
    held: bool = true,

    pub fn release(lease: *WriterLease, io: std.Io) void {
        if (lease.held) {
            lease.file.unlock(io);
            lease.file.close(io);
            lease.held = false;
        }
    }
};

pub const ScanReport = struct {
    current_generation: ?u64,
    current_files: usize,
    /// Unreferenced `documents-N.hybseg` / `lexical-N.hyblex` files that are
    /// NOT a well-formed older generation (`N` below the current generation):
    /// a crash leftover at or past the current generation, an oddly named
    /// section file, or every section file when no valid `MANIFEST` exists.
    orphan_document_files: usize,
    orphan_lexical_files: usize,
    /// Older generations' files (`N` below the current generation), i.e. the
    /// retained history `keep_generations` leaves behind and the files it
    /// prunes (S2-T5). Reported separately so a deliberately retained
    /// generation is not an anomaly.
    superseded_document_files: usize = 0,
    superseded_lexical_files: usize = 0,
    unknown_files: usize,
};

pub const document_prefix = "documents-";
pub const document_suffix = ".hybseg";
pub const lexical_prefix = "lexical-";
pub const lexical_suffix = ".hyblex";
pub const filename_catalog_prefix = "filenames-";
pub const filename_catalog_suffix = ".hybseg";
pub const filename_lexical_prefix = "filename-lexical-";
pub const filename_lexical_suffix = ".hyblex";

pub const SectionKind = enum { documents, lexical, catalog, filename_lexical };

pub fn sectionKindForGeneration(name: []const u8) ?SectionKind {
    if (std.mem.startsWith(u8, name, document_prefix) and std.mem.endsWith(u8, name, document_suffix)) return .documents;
    if (std.mem.startsWith(u8, name, lexical_prefix) and std.mem.endsWith(u8, name, lexical_suffix)) return .lexical;
    if (std.mem.startsWith(u8, name, filename_catalog_prefix) and std.mem.endsWith(u8, name, filename_catalog_suffix)) return .catalog;
    if (std.mem.startsWith(u8, name, filename_lexical_prefix) and std.mem.endsWith(u8, name, filename_lexical_suffix)) return .filename_lexical;
    return null;
}

/// The generation number of a canonical section file name
/// (`documents-<N>.hybseg`, `lexical-<N>.hyblex`, `filenames-<N>.hybseg`, or
/// `filename-lexical-<N>.hyblex`, `N` plain decimal, no
/// leading zeros), or null for any other name. This is the only shape
/// pruning will ever touch.
pub fn sectionGeneration(name: []const u8) ?u64 {
    const kind = sectionKindForGeneration(name) orelse return null;
    const prefix, const suffix = switch (kind) {
        .documents => .{ document_prefix, document_suffix },
        .lexical => .{ lexical_prefix, lexical_suffix },
        .catalog => .{ filename_catalog_prefix, filename_catalog_suffix },
        .filename_lexical => .{ filename_lexical_prefix, filename_lexical_suffix },
    };
    if (name.len <= prefix.len + suffix.len) return null;
    const digits = name[prefix.len .. name.len - suffix.len];
    for (digits) |c| if (c < '0' or c > '9') return null;
    if (digits.len > 1 and digits[0] == '0') return null;
    return std.fmt.parseInt(u64, digits, 10) catch null;
}

pub const PruneReport = struct {
    /// Superseded section files unlinked.
    deleted: usize = 0,
    /// Deletions that failed (or could not be attempted); the publish itself
    /// still succeeded and the files remain for a later run.
    failed: usize = 0,
};

/// Delete the section files of generations older than the newest `keep`
/// (`keep >= 1`; the current generation always counts as one of them).
///
/// Conservative by construction:
/// - only canonical `documents-N.hybseg` / `lexical-N.hyblex` names with
///   `N` strictly below `current_generation` are candidates, so a crash
///   leftover at or past the current generation, `MANIFEST`, `WRITER.LOCK`,
///   `INDEX-STATE.json`, temp files and unknown files are never touched;
/// - the current generation's two files (by name, from its manifest) are
///   never touched whatever their numbers;
/// - the kept set is the current generation plus the newest `keep - 1`
///   COMPLETE older generations (both section files present). An incomplete
///   older leftover (one lone section file) is never counted and is always
///   deleted; and
/// - no error is returned: a failed unlink is counted in `failed`.
///
/// A reader in another process that already opened an older generation keeps
/// working: on macOS/Linux/Android unlinking an open file only removes the
/// name. A reader that opens `MANIFEST` and then the sections can lose that
/// race only if it started before the publish that superseded the generation
/// it chose; retention `keep >= 2` leaves the newest complete older generation for it.
pub fn pruneSuperseded(
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    io: std.Io,
    keep: usize,
    current_generation: u64,
    current_documents_file: []const u8,
    current_lexical_file: []const u8,
) PruneReport {
    return pruneSupersededWithFilename(allocator, dir, io, keep, current_generation, current_documents_file, current_lexical_file, "", "");
}

pub fn pruneSupersededWithFilename(
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    io: std.Io,
    keep: usize,
    current_generation: u64,
    current_documents_file: []const u8,
    current_lexical_file: []const u8,
    current_catalog_file: []const u8,
    current_filename_lexical_file: []const u8,
) PruneReport {
    var report = PruneReport{};
    if (keep == 0) return report;
    var iterable = dir.openDir(io, ".", .{ .iterate = true }) catch {
        report.failed += 1;
        return report;
    };
    defer iterable.close(io);

    // Per generation number below the current one: which of its two section
    // files exist. A generation counts toward `keep` only when BOTH exist; a
    // lone leftover (a crash between the two section links) is never
    // counted and is always pruned.
    const Seen = struct { number: u64, documents: bool = false, lexical: bool = false, catalog: bool = false, filename_lexical: bool = false };
    var seen = std.ArrayList(Seen).empty;
    defer seen.deinit(allocator);
    var names = std.ArrayList([]u8).empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    var iterator = iterable.iterate();
    while (true) {
        const entry = (iterator.next(io) catch {
            report.failed += 1;
            return report;
        }) orelse break;
        if (entry.kind != .file) continue;
        const number = sectionGeneration(entry.name) orelse continue;
        if (number >= current_generation) continue;
        if (std.mem.eql(u8, entry.name, current_documents_file) or std.mem.eql(u8, entry.name, current_lexical_file) or
            std.mem.eql(u8, entry.name, current_catalog_file) or std.mem.eql(u8, entry.name, current_filename_lexical_file)) continue;
        const kind = sectionKindForGeneration(entry.name).?;
        var slot: ?*Seen = null;
        for (seen.items) |*item| {
            if (item.number == number) slot = item;
        }
        if (slot == null) {
            seen.append(allocator, .{ .number = number }) catch {
                report.failed += 1;
                return report;
            };
            slot = &seen.items[seen.items.len - 1];
        }
        switch (kind) {
            .documents => slot.?.documents = true,
            .lexical => slot.?.lexical = true,
            .catalog => slot.?.catalog = true,
            .filename_lexical => slot.?.filename_lexical = true,
        }
        const owned = allocator.dupe(u8, entry.name) catch {
            report.failed += 1;
            return report;
        };
        names.append(allocator, owned) catch {
            allocator.free(owned);
            report.failed += 1;
            return report;
        };
    }

    // Complete older generations, newest first; the newest `keep - 1` of
    // them survive beside the current generation.
    var complete = std.ArrayList(u64).empty;
    defer complete.deinit(allocator);
    for (seen.items) |item| {
        if (item.documents and item.lexical and (item.catalog == item.filename_lexical)) complete.append(allocator, item.number) catch {
            report.failed += 1;
            return report;
        };
    }
    std.mem.sort(u64, complete.items, {}, std.sort.desc(u64));
    const survivors = @min(keep - 1, complete.items.len);
    for (names.items) |name| {
        const number = sectionGeneration(name).?;
        if (std.mem.indexOfScalar(u64, complete.items[0..survivors], number) != null) continue;
        dir.deleteFile(io, name) catch {
            report.failed += 1;
            continue;
        };
        report.deleted += 1;
    }
    // Make the unlinks durable; best effort, the publish already succeeded.
    if (report.deleted > 0) publication.syncDirectory(dir, io, null) catch {
        report.failed += 1;
    };
    return report;
}

/// `publishSerialized`, then (when `keep_generations` is set) prune
/// superseded generations while still holding the writer lease. A pruning
/// problem never fails the publish; see `PruneReport`.
pub fn publishSerializedKeeping(
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    io: std.Io,
    manifest_encoded: []const u8,
    documents_encoded: []const u8,
    lexical_encoded: []const u8,
    keep_generations: ?usize,
) !PruneReport {
    if (keep_generations) |keep| if (keep == 0) return error.InvalidKeepGenerations;
    var lease = (try tryAcquireWriter(dir, io)) orelse return error.WriterBusy;
    defer lease.release(io);
    const proposed = try manifest.decode(manifest_encoded);
    try validateFilenameModeTransition(std.heap.page_allocator, dir, io, proposed);
    try publication.publish(dir, io, manifest_encoded, documents_encoded, lexical_encoded);
    const keep = keep_generations orelse return .{};
    const metadata = manifest.decode(manifest_encoded) catch return .{ .failed = 1 };
    return pruneSuperseded(allocator, dir, io, keep, metadata.generation, metadata.documents_file, metadata.lexical_file);
}

pub fn publishSerializedWithFilenameKeeping(
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    io: std.Io,
    manifest_encoded: []const u8,
    documents_encoded: []const u8,
    lexical_encoded: []const u8,
    catalog_encoded: []const u8,
    filename_lexical_encoded: []const u8,
    keep_generations: ?usize,
) !PruneReport {
    if (keep_generations) |keep| if (keep == 0) return error.InvalidKeepGenerations;
    var lease = (try tryAcquireWriter(dir, io)) orelse return error.WriterBusy;
    defer lease.release(io);
    const proposed = try manifest.decode(manifest_encoded);
    try validateFilenameModeTransition(std.heap.page_allocator, dir, io, proposed);
    try publication.publishWithFilename(dir, io, manifest_encoded, documents_encoded, lexical_encoded, catalog_encoded, filename_lexical_encoded);
    const keep = keep_generations orelse return .{};
    const metadata = manifest.decode(manifest_encoded) catch return .{ .failed = 1 };
    const filename = metadata.filename orelse return .{ .failed = 1 };
    return pruneSupersededWithFilename(allocator, dir, io, keep, metadata.generation, metadata.documents_file, metadata.lexical_file, filename.catalog_file, filename.lexical_file);
}

pub fn tryAcquireWriter(dir: std.Io.Dir, io: std.Io) !?WriterLease {
    const file = try dir.createFile(io, writer_lock_file, .{ .read = true, .truncate = false });
    errdefer file.close(io);
    if (!try file.tryLock(io, .exclusive)) {
        file.close(io);
        return null;
    }
    return .{ .file = file };
}

pub fn publishSerialized(
    dir: std.Io.Dir,
    io: std.Io,
    manifest_encoded: []const u8,
    documents_encoded: []const u8,
    lexical_encoded: []const u8,
) !void {
    var lease = (try tryAcquireWriter(dir, io)) orelse return error.WriterBusy;
    defer lease.release(io);
    const proposed = try manifest.decode(manifest_encoded);
    try validateFilenameModeTransition(std.heap.page_allocator, dir, io, proposed);
    try publication.publish(dir, io, manifest_encoded, documents_encoded, lexical_encoded);
}

/// Keep a published directory's filename-index mode and analyzer stable for
/// every serialized writer. This check runs under the same lease as the
/// publication so two concurrent writers cannot both validate against stale
/// mode metadata and then publish incompatible manifests.
fn validateFilenameModeTransition(allocator: std.mem.Allocator, dir: std.Io.Dir, io: std.Io, proposed: manifest.Manifest) !void {
    var file = dir.openFile(io, publication.current_manifest_file, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close(io);
    const stat = try file.stat(io);
    const size = std.math.cast(usize, stat.size) orelse return error.IndexTooLarge;
    const storage = try allocator.alloc(u8, size);
    defer allocator.free(storage);
    const encoded = try dir.readFile(io, publication.current_manifest_file, storage);
    const is_v1 = std.mem.startsWith(u8, encoded, manifest.magic);
    const current = manifest.decode(encoded) catch {
        // Preserve the historical body-only repair path for damaged v1
        // manifests. A filename-enabled update cannot infer the old mode
        // from corrupt metadata, and malformed v2/unknown formats fail
        // closed rather than silently dropping the feature.
        if (is_v1 and proposed.filename == null) return;
        return error.FilenameMigrationRequiresNewDirectory;
    };
    const current_has_filename = current.filename != null;
    const proposed_has_filename = proposed.filename != null;
    if (current_has_filename or proposed_has_filename) {
        if (!current_has_filename or !proposed_has_filename or !std.mem.eql(u8, current.analyzer_id, proposed.analyzer_id)) {
            return error.FilenameMigrationRequiresNewDirectory;
        }
    }
}

/// Classify generation files without deleting anything. Orphans may still be
/// held by readers of an older immutable manifest, so cleanup requires an
/// external retention/lease policy. `MANIFEST`, `WRITER.LOCK`, and
/// `INDEX-STATE.json` (S1-T4 criterion 3, round-B non-blocking finding 3)
/// are all known, non-generation files and never counted under
/// `unknown_files`: an incrementally indexed directory's own bookkeeping
/// file is not an operator-facing anomaly.
pub fn scan(
    iterable_dir: std.Io.Dir,
    io: std.Io,
    manifest_buffer: []u8,
    documents_buffer: []u8,
    lexical_buffer: []u8,
) !ScanReport {
    const current: ?publication.LoadedSnapshot = publication.loadCurrent(
        iterable_dir,
        io,
        manifest_buffer,
        documents_buffer,
        lexical_buffer,
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    return scanMetadata(iterable_dir, io, if (current) |snapshot| snapshot.metadata else null);
}

pub fn scanWithFilename(
    iterable_dir: std.Io.Dir,
    io: std.Io,
    manifest_buffer: []u8,
    documents_buffer: []u8,
    lexical_buffer: []u8,
    catalog_buffer: []u8,
    filename_lexical_buffer: []u8,
) !ScanReport {
    const current: ?publication.LoadedSnapshot = publication.loadCurrentWithFilename(
        iterable_dir,
        io,
        manifest_buffer,
        documents_buffer,
        lexical_buffer,
        catalog_buffer,
        filename_lexical_buffer,
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    return scanMetadata(iterable_dir, io, if (current) |snapshot| snapshot.metadata else null);
}

fn scanMetadata(iterable_dir: std.Io.Dir, io: std.Io, current_metadata: ?manifest.Manifest) !ScanReport {
    var report = ScanReport{
        .current_generation = if (current_metadata) |metadata| metadata.generation else null,
        .current_files = 0,
        .orphan_document_files = 0,
        .orphan_lexical_files = 0,
        .unknown_files = 0,
    };

    var iterator = iterable_dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, entry.name, publication.current_manifest_file) or
            std.mem.eql(u8, entry.name, writer_lock_file) or
            std.mem.eql(u8, entry.name, incremental_state.state_file)) continue;
        if (current_metadata) |metadata| {
            if (std.mem.eql(u8, entry.name, metadata.documents_file) or
                std.mem.eql(u8, entry.name, metadata.lexical_file) or
                (metadata.filename != null and (std.mem.eql(u8, entry.name, metadata.filename.?.catalog_file) or std.mem.eql(u8, entry.name, metadata.filename.?.lexical_file))))
            {
                report.current_files += 1;
                continue;
            }
        }
        const superseded = if (current_metadata) |metadata|
            (if (sectionGeneration(entry.name)) |number| number < metadata.generation else false)
        else
            false;
        if (std.mem.endsWith(u8, entry.name, ".hybseg")) {
            if (superseded) report.superseded_document_files += 1 else report.orphan_document_files += 1;
        } else if (std.mem.endsWith(u8, entry.name, ".hyblex")) {
            if (superseded) report.superseded_lexical_files += 1 else report.orphan_lexical_files += 1;
        } else {
            report.unknown_files += 1;
        }
    }
    return report;
}

test "writer lease serializes publication attempts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var first = (try tryAcquireWriter(tmp.dir, io)).?;
    defer first.release(io);
    try std.testing.expect((try tryAcquireWriter(tmp.dir, io)) == null);
    first.release(io);
    var second = (try tryAcquireWriter(tmp.dir, io)).?;
    second.release(io);
}

test "filename section names participate in scanning and pruning generations" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    inline for (.{
        "documents-1.hybseg", "lexical-1.hyblex", "filenames-1.hybseg", "filename-lexical-1.hyblex",
        "documents-2.hybseg", "lexical-2.hyblex",
    }) |name| try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "section" });
    try std.testing.expectEqual(@as(?u64, 1), sectionGeneration("filenames-1.hybseg"));
    try std.testing.expectEqual(@as(?u64, 1), sectionGeneration("filename-lexical-1.hyblex"));
    try std.testing.expectEqual(@as(?u64, null), sectionGeneration("filename-01.hyblex"));

    const pruned = pruneSuperseded(std.testing.allocator, tmp.dir, io, 2, 3, "documents-3.hybseg", "lexical-3.hyblex");
    try std.testing.expectEqual(@as(usize, 4), pruned.deleted);
    inline for (.{ "documents-1.hybseg", "lexical-1.hyblex", "filenames-1.hybseg", "filename-lexical-1.hyblex" }) |name| {
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, name, .{}));
    }
    inline for (.{ "documents-2.hybseg", "lexical-2.hyblex" }) |name| _ = try tmp.dir.statFile(io, name, .{});
}

test "scanWithFilename counts the selected four-section generation" {
    const hybrid = @import("hybrid.zig");
    const segment = @import("segment.zig");
    const postings = @import("postings.zig");
    const lexical_segment = @import("lexical_segment.zig");
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    const docs = [_]hybrid.Document{.{ .id = "anchor", .path = "dir/alpha.md", .text = "alpha search", .vector = &.{}, .start_line = 1, .end_line = 1 }};
    var docs_storage: [256]u8 = undefined;
    const docs_encoded = try segment.encode(&docs, &docs_storage);
    var terms: [8]postings.TermEntry = undefined;
    var posts: [8]postings.Posting = undefined;
    var lengths: [1]u32 = undefined;
    var fills: [8]usize = undefined;
    const index = try postings.build(&docs, &terms, &posts, &lengths, &fills);
    var lex_storage: [512]u8 = undefined;
    const lex_encoded = try lexical_segment.encode(index, &lex_storage);
    const base = try manifest.create(4, "ascii-alnum-v1", "none", "documents-4.hybseg", "lexical-4.hyblex", docs_encoded, lex_encoded);
    var catalog_storage: [256]u8 = undefined;
    const catalog = try segment.encode(&docs, &catalog_storage);
    var filename_terms: [8]postings.TermEntry = undefined;
    var filename_posts: [8]postings.Posting = undefined;
    var filename_lengths: [1]u32 = undefined;
    var filename_fills: [8]usize = undefined;
    const filename_index = try postings.build(&docs, &filename_terms, &filename_posts, &filename_lengths, &filename_fills);
    var filename_lex_storage: [512]u8 = undefined;
    const filename_lex = try lexical_segment.encode(filename_index, &filename_lex_storage);
    const with_filename = try manifest.withFilename(base, "filenames-4.hybseg", "filename-lexical-4.hyblex", catalog, filename_lex);
    var metadata_storage: [768]u8 = undefined;
    const metadata = try manifest.encode(with_filename, &metadata_storage);
    try publication.publishWithFilename(tmp.dir, io, metadata, docs_encoded, lex_encoded, catalog, filename_lex);

    var mb: [768]u8 = undefined;
    var db: [256]u8 = undefined;
    var lb: [512]u8 = undefined;
    var cb: [256]u8 = undefined;
    var flb: [512]u8 = undefined;
    const report = try scanWithFilename(tmp.dir, io, &mb, &db, &lb, &cb, &flb);
    try std.testing.expectEqual(@as(usize, 4), report.current_files);
    try std.testing.expectEqual(@as(usize, 0), report.orphan_document_files + report.orphan_lexical_files);
    var legacy_mb: [768]u8 = undefined;
    var legacy_db: [256]u8 = undefined;
    var legacy_lb: [512]u8 = undefined;
    try std.testing.expectError(error.FilenameSectionsRequired, scan(tmp.dir, io, &legacy_mb, &legacy_db, &legacy_lb));
}

test "serialized publication keeps filename mode and analyzer stable under its lease" {
    const hybrid = @import("hybrid.zig");
    const segment = @import("segment.zig");
    const postings = @import("postings.zig");
    const lexical_segment = @import("lexical_segment.zig");
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    const docs = [_]hybrid.Document{.{ .id = "anchor", .path = "alpha.md", .text = "alpha search", .vector = &.{}, .start_line = 1, .end_line = 1 }};
    var docs_storage: [256]u8 = undefined;
    const docs_encoded = try segment.encode(&docs, &docs_storage);
    var terms: [8]postings.TermEntry = undefined;
    var posts: [8]postings.Posting = undefined;
    var lengths: [1]u32 = undefined;
    var fills: [8]usize = undefined;
    const index = try postings.build(&docs, &terms, &posts, &lengths, &fills);
    var lex_storage: [512]u8 = undefined;
    const lex_encoded = try lexical_segment.encode(index, &lex_storage);
    var catalog_storage: [256]u8 = undefined;
    const catalog = try segment.encode(&docs, &catalog_storage);
    var filename_lex_storage: [512]u8 = undefined;
    const filename_lex = try lexical_segment.encode(index, &filename_lex_storage);

    const body_one = try manifest.create(1, "ascii-alnum-v1", "none", "documents-1.hybseg", "lexical-1.hyblex", docs_encoded, lex_encoded);
    var body_one_storage: [768]u8 = undefined;
    const body_one_encoded = try manifest.encode(body_one, &body_one_storage);
    try publishSerialized(tmp.dir, io, body_one_encoded, docs_encoded, lex_encoded);

    const filename_two_base = try manifest.create(2, "ascii-alnum-v1", "none", "documents-2.hybseg", "lexical-2.hyblex", docs_encoded, lex_encoded);
    const filename_two = try manifest.withFilename(filename_two_base, "filenames-2.hybseg", "filename-lexical-2.hyblex", catalog, filename_lex);
    var filename_two_storage: [768]u8 = undefined;
    const filename_two_encoded = try manifest.encode(filename_two, &filename_two_storage);
    try std.testing.expectError(error.FilenameMigrationRequiresNewDirectory, publishSerializedWithFilenameKeeping(std.testing.allocator, tmp.dir, io, filename_two_encoded, docs_encoded, lex_encoded, catalog, filename_lex, null));
    var current_buffer: [768]u8 = undefined;
    try std.testing.expectEqualSlices(u8, body_one_encoded, try tmp.dir.readFile(io, publication.current_manifest_file, &current_buffer));

    try tmp.dir.writeFile(io, .{ .sub_path = publication.current_manifest_file, .data = "HYBMAN01corrupt" });
    const repair = try manifest.create(2, "ascii-alnum-v1", "none", "documents-2.hybseg", "lexical-2.hyblex", docs_encoded, lex_encoded);
    var repair_storage: [768]u8 = undefined;
    const repair_encoded = try manifest.encode(repair, &repair_storage);
    try publishSerialized(tmp.dir, io, repair_encoded, docs_encoded, lex_encoded);
    try std.testing.expectEqualSlices(u8, repair_encoded, try tmp.dir.readFile(io, publication.current_manifest_file, &current_buffer));

    try tmp.dir.writeFile(io, .{ .sub_path = publication.current_manifest_file, .data = "UNKNOWN!" });
    const unknown_repair = try manifest.create(3, "ascii-alnum-v1", "none", "documents-3.hybseg", "lexical-3.hyblex", docs_encoded, lex_encoded);
    var unknown_storage: [768]u8 = undefined;
    const unknown_encoded = try manifest.encode(unknown_repair, &unknown_storage);
    try std.testing.expectError(error.FilenameMigrationRequiresNewDirectory, publishSerialized(tmp.dir, io, unknown_encoded, docs_encoded, lex_encoded));
    try std.testing.expectEqualStrings("UNKNOWN!", try tmp.dir.readFile(io, publication.current_manifest_file, &current_buffer));

    var fresh = std.testing.tmpDir(.{ .iterate = true });
    defer fresh.cleanup();
    const filename_one_base = try manifest.create(1, "ascii-alnum-v1", "none", "documents-1.hybseg", "lexical-1.hyblex", docs_encoded, lex_encoded);
    const filename_one = try manifest.withFilename(filename_one_base, "filenames-1.hybseg", "filename-lexical-1.hyblex", catalog, filename_lex);
    var filename_one_storage: [768]u8 = undefined;
    const filename_one_encoded = try manifest.encode(filename_one, &filename_one_storage);
    _ = try publishSerializedWithFilenameKeeping(std.testing.allocator, fresh.dir, io, filename_one_encoded, docs_encoded, lex_encoded, catalog, filename_lex, null);

    const body_two = try manifest.create(2, "ascii-alnum-v1", "none", "documents-2.hybseg", "lexical-2.hyblex", docs_encoded, lex_encoded);
    var body_two_storage: [768]u8 = undefined;
    const body_two_encoded = try manifest.encode(body_two, &body_two_storage);
    try std.testing.expectError(error.FilenameMigrationRequiresNewDirectory, publishSerializedKeeping(std.testing.allocator, fresh.dir, io, body_two_encoded, docs_encoded, lex_encoded, null));
    var fresh_current: [768]u8 = undefined;
    try std.testing.expectEqualSlices(u8, filename_one_encoded, try fresh.dir.readFile(io, publication.current_manifest_file, &fresh_current));

    _ = try publishSerializedWithFilenameKeeping(std.testing.allocator, fresh.dir, io, filename_two_encoded, docs_encoded, lex_encoded, catalog, filename_lex, null);
    const analyzer_change_base = try manifest.create(3, "other-analyzer-v1", "none", "documents-3.hybseg", "lexical-3.hyblex", docs_encoded, lex_encoded);
    const analyzer_change = try manifest.withFilename(analyzer_change_base, "filenames-3.hybseg", "filename-lexical-3.hyblex", catalog, filename_lex);
    var analyzer_change_storage: [768]u8 = undefined;
    const analyzer_change_encoded = try manifest.encode(analyzer_change, &analyzer_change_storage);
    try std.testing.expectError(error.FilenameMigrationRequiresNewDirectory, publishSerializedWithFilenameKeeping(std.testing.allocator, fresh.dir, io, analyzer_change_encoded, docs_encoded, lex_encoded, catalog, filename_lex, null));
}

test "scanner distinguishes current generation and conservative orphans" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;

    const documents = [_]@import("hybrid.zig").Document{.{ .id = "one", .text = "search evidence" }};
    var document_storage: [256]u8 = undefined;
    const documents_encoded = try @import("segment.zig").encode(&documents, &document_storage);
    var terms: [8]@import("postings.zig").TermEntry = undefined;
    var posting_storage: [8]@import("postings.zig").Posting = undefined;
    var lengths: [1]u32 = undefined;
    var fills: [8]usize = undefined;
    const index = try @import("postings.zig").build(&documents, &terms, &posting_storage, &lengths, &fills);
    var lexical_storage: [512]u8 = undefined;
    const lexical_encoded = try @import("lexical_segment.zig").encode(index, &lexical_storage);
    const metadata = try manifest.create(1, "ascii-v1", "none", "documents-1.hybseg", "lexical-1.hyblex", documents_encoded, lexical_encoded);
    var manifest_storage: [512]u8 = undefined;
    const manifest_encoded = try manifest.encode(metadata, &manifest_storage);
    try publishSerialized(tmp.dir, io, manifest_encoded, documents_encoded, lexical_encoded);

    try tmp.dir.writeFile(io, .{ .sub_path = "documents-0.hybseg", .data = "orphan" });
    try tmp.dir.writeFile(io, .{ .sub_path = "lexical-0.hyblex", .data = "orphan" });
    try tmp.dir.writeFile(io, .{ .sub_path = "README.txt", .data = "unknown" });
    // A leftover at or past the current generation (crash orphan) stays an
    // orphan.
    try tmp.dir.writeFile(io, .{ .sub_path = "documents-7.hybseg", .data = "orphan" });

    var manifest_read: [512]u8 = undefined;
    var document_read: [256]u8 = undefined;
    var lexical_read: [512]u8 = undefined;
    const report = try scan(tmp.dir, io, &manifest_read, &document_read, &lexical_read);
    try std.testing.expectEqual(@as(?u64, 1), report.current_generation);
    try std.testing.expectEqual(@as(usize, 2), report.current_files);
    // Generation 0 is older than the current generation 1: superseded, not
    // an orphan (S2-T5).
    try std.testing.expectEqual(@as(usize, 1), report.orphan_document_files);
    try std.testing.expectEqual(@as(usize, 0), report.orphan_lexical_files);
    try std.testing.expectEqual(@as(usize, 1), report.superseded_document_files);
    try std.testing.expectEqual(@as(usize, 1), report.superseded_lexical_files);
    try std.testing.expectEqual(@as(usize, 1), report.unknown_files);
}

test "scanner does not count INDEX-STATE.json as an unknown file" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;

    const documents = [_]@import("hybrid.zig").Document{.{ .id = "one", .text = "search evidence" }};
    var document_storage: [256]u8 = undefined;
    const documents_encoded = try @import("segment.zig").encode(&documents, &document_storage);
    var terms: [8]@import("postings.zig").TermEntry = undefined;
    var posting_storage: [8]@import("postings.zig").Posting = undefined;
    var lengths: [1]u32 = undefined;
    var fills: [8]usize = undefined;
    const index = try @import("postings.zig").build(&documents, &terms, &posting_storage, &lengths, &fills);
    var lexical_storage: [512]u8 = undefined;
    const lexical_encoded = try @import("lexical_segment.zig").encode(index, &lexical_storage);
    const metadata = try manifest.create(1, "analyzer-v2", "none", "documents-1.hybseg", "lexical-1.hyblex", documents_encoded, lexical_encoded);
    var manifest_storage: [512]u8 = undefined;
    const manifest_encoded = try manifest.encode(metadata, &manifest_storage);
    try publishSerialized(tmp.dir, io, manifest_encoded, documents_encoded, lexical_encoded);

    try incremental_state.save(io, tmp.dir, std.testing.allocator, .{
        .generation = 1,
        .analyzer_id = "analyzer-v2",
        .files = &.{},
    });

    var manifest_read: [512]u8 = undefined;
    var document_read: [256]u8 = undefined;
    var lexical_read: [512]u8 = undefined;
    const report = try scan(tmp.dir, io, &manifest_read, &document_read, &lexical_read);
    try std.testing.expectEqual(@as(usize, 0), report.unknown_files);
}

test "scanner treats generation files as orphans when no manifest exists" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "documents-9.hybseg", .data = "orphan" });
    try tmp.dir.writeFile(io, .{ .sub_path = "lexical-9.hyblex", .data = "orphan" });

    var manifest_read: [128]u8 = undefined;
    var document_read: [128]u8 = undefined;
    var lexical_read: [128]u8 = undefined;
    const report = try scan(tmp.dir, io, &manifest_read, &document_read, &lexical_read);
    try std.testing.expectEqual(@as(?u64, null), report.current_generation);
    try std.testing.expectEqual(@as(usize, 1), report.orphan_document_files);
    try std.testing.expectEqual(@as(usize, 1), report.orphan_lexical_files);
}
