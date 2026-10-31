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
    /// S3-T1: `source-N.hybsrc` files, counted apart so the document and
    /// lexical counters above keep their meaning. `current_files` counts the
    /// current generation's document and lexical files only.
    current_source_files: usize = 0,
    orphan_source_files: usize = 0,
    superseded_source_files: usize = 0,
};

pub const document_prefix = "documents-";
pub const document_suffix = ".hybseg";
pub const lexical_prefix = "lexical-";
pub const lexical_suffix = ".hyblex";
pub const source_prefix = "source-";
pub const source_suffix = ".hybsrc";

/// The generation number of a canonical `source-<N>.hybsrc` name (same
/// digit rules as `sectionGeneration`), or null.
pub fn sourceGeneration(name: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, name, source_prefix) or !std.mem.endsWith(u8, name, source_suffix) or
        name.len <= source_prefix.len + source_suffix.len) return null;
    const digits = name[source_prefix.len .. name.len - source_suffix.len];
    for (digits) |c| if (c < '0' or c > '9') return null;
    if (digits.len > 1 and digits[0] == '0') return null;
    return std.fmt.parseInt(u64, digits, 10) catch null;
}

/// The generation number of a canonical section file name
/// (`documents-<N>.hybseg` or `lexical-<N>.hyblex`, `N` plain decimal, no
/// leading zeros), or null for any other name. This is the only shape
/// pruning will ever touch.
pub fn sectionGeneration(name: []const u8) ?u64 {
    const digits = blk: {
        if (std.mem.startsWith(u8, name, document_prefix) and std.mem.endsWith(u8, name, document_suffix) and
            name.len > document_prefix.len + document_suffix.len)
            break :blk name[document_prefix.len .. name.len - document_suffix.len];
        if (std.mem.startsWith(u8, name, lexical_prefix) and std.mem.endsWith(u8, name, lexical_suffix) and
            name.len > lexical_prefix.len + lexical_suffix.len)
            break :blk name[lexical_prefix.len .. name.len - lexical_suffix.len];
        return null;
    };
    for (digits) |c| if (c < '0' or c > '9') return null;
    if (digits.len > 1 and digits[0] == '0') return null;
    return std.fmt.parseInt(u64, digits, 10) catch null;
}

pub const PruneReport = struct {
    /// Superseded document and lexical section files unlinked.
    deleted: usize = 0,
    /// S3-T1: superseded `source-N.hybsrc` files unlinked with them (kept
    /// apart so `deleted`, reported as `pruned_files`, keeps its meaning).
    deleted_source: usize = 0,
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
    return pruneSupersededWithSource(allocator, dir, io, keep, current_generation, current_documents_file, current_lexical_file, "");
}

/// `pruneSuperseded` that also removes `source-N.hybsrc` files (S3-T1) of
/// every generation it removes, never the current generation's
/// (`current_source_file`, empty when it has none). A source file never
/// makes an older generation count as complete: completeness stays "both
/// the document and the lexical file exist".
pub fn pruneSupersededWithSource(
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    io: std.Io,
    keep: usize,
    current_generation: u64,
    current_documents_file: []const u8,
    current_lexical_file: []const u8,
    current_source_file: []const u8,
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
    const Seen = struct { number: u64, documents: bool, lexical: bool };
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
        if (sourceGeneration(entry.name)) |source_number| {
            if (source_number >= current_generation or std.mem.eql(u8, entry.name, current_source_file)) continue;
            const owned_source = allocator.dupe(u8, entry.name) catch {
                report.failed += 1;
                return report;
            };
            names.append(allocator, owned_source) catch {
                allocator.free(owned_source);
                report.failed += 1;
                return report;
            };
            continue;
        }
        const number = sectionGeneration(entry.name) orelse continue;
        if (number >= current_generation) continue;
        if (std.mem.eql(u8, entry.name, current_documents_file) or std.mem.eql(u8, entry.name, current_lexical_file)) continue;
        const is_documents = std.mem.startsWith(u8, entry.name, document_prefix);
        var slot: ?*Seen = null;
        for (seen.items) |*item| {
            if (item.number == number) slot = item;
        }
        if (slot == null) {
            seen.append(allocator, .{ .number = number, .documents = false, .lexical = false }) catch {
                report.failed += 1;
                return report;
            };
            slot = &seen.items[seen.items.len - 1];
        }
        if (is_documents) slot.?.documents = true else slot.?.lexical = true;
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
        if (item.documents and item.lexical) complete.append(allocator, item.number) catch {
            report.failed += 1;
            return report;
        };
    }
    std.mem.sort(u64, complete.items, {}, std.sort.desc(u64));
    const survivors = @min(keep - 1, complete.items.len);
    for (names.items) |name| {
        const is_source = sourceGeneration(name) != null;
        const number = if (is_source) sourceGeneration(name).? else sectionGeneration(name).?;
        if (std.mem.indexOfScalar(u64, complete.items[0..survivors], number) != null) continue;
        dir.deleteFile(io, name) catch {
            report.failed += 1;
            continue;
        };
        if (is_source) report.deleted_source += 1 else report.deleted += 1;
    }
    // Make the unlinks durable; best effort, the publish already succeeded.
    if (report.deleted + report.deleted_source > 0) publication.syncDirectory(dir, io, null) catch {
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
    return publishSerializedKeepingWithSource(allocator, dir, io, manifest_encoded, documents_encoded, lexical_encoded, null, keep_generations);
}

/// `publishSerializedKeeping` for a generation that may bind a source
/// section (S3-T1, `publication.publishWithSource`).
pub fn publishSerializedKeepingWithSource(
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    io: std.Io,
    manifest_encoded: []const u8,
    documents_encoded: []const u8,
    lexical_encoded: []const u8,
    source_encoded: ?[]const u8,
    keep_generations: ?usize,
) !PruneReport {
    if (keep_generations) |keep| if (keep == 0) return error.InvalidKeepGenerations;
    var lease = (try tryAcquireWriter(dir, io)) orelse return error.WriterBusy;
    defer lease.release(io);
    return publishLeasedKeepingWithSource(allocator, dir, io, manifest_encoded, documents_encoded, lexical_encoded, source_encoded, keep_generations);
}

/// `publishSerializedKeepingWithSource` for a caller that already holds the
/// writer lease (S3-T3: `apply.zig` takes `WRITER.LOCK` before it reads the
/// current generation, so the `expect_generation` check, the reading of the
/// previous generation and the publication are one critical section).
pub fn publishLeasedKeepingWithSource(
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    io: std.Io,
    manifest_encoded: []const u8,
    documents_encoded: []const u8,
    lexical_encoded: []const u8,
    source_encoded: ?[]const u8,
    keep_generations: ?usize,
) !PruneReport {
    if (keep_generations) |keep| if (keep == 0) return error.InvalidKeepGenerations;
    try publication.publishWithSource(dir, io, manifest_encoded, documents_encoded, lexical_encoded, source_encoded);
    const keep = keep_generations orelse return .{};
    const metadata = manifest.decode(manifest_encoded) catch return .{ .failed = 1 };
    return pruneSupersededWithSource(allocator, dir, io, keep, metadata.generation, metadata.documents_file, metadata.lexical_file, metadata.source_file);
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
    try publication.publish(dir, io, manifest_encoded, documents_encoded, lexical_encoded);
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
    const current_metadata: ?manifest.Manifest = if (current) |snapshot| snapshot.metadata else null;
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
                std.mem.eql(u8, entry.name, metadata.lexical_file))
            {
                report.current_files += 1;
                continue;
            }
            if (metadata.hasSource() and std.mem.eql(u8, entry.name, metadata.source_file)) {
                report.current_source_files += 1;
                continue;
            }
        }
        if (std.mem.endsWith(u8, entry.name, source_suffix)) {
            const older = if (current_metadata) |metadata|
                (if (sourceGeneration(entry.name)) |number| number < metadata.generation else false)
            else
                false;
            if (older) report.superseded_source_files += 1 else report.orphan_source_files += 1;
            continue;
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

test "pruning removes superseded source sections and scan counts them apart (S3-T1)" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    inline for (.{ "documents-1.hybseg", "lexical-1.hyblex", "source-1.hybsrc", "documents-2.hybseg", "lexical-2.hyblex", "source-2.hybsrc", "source-3.hybsrc", "source-9.hybsrc", "source-04.hybsrc" }) |name| {
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "x" });
    }
    const report = pruneSupersededWithSource(std.testing.allocator, tmp.dir, io, 2, 3, "documents-3.hybseg", "lexical-3.hyblex", "source-3.hybsrc");
    try std.testing.expectEqual(@as(usize, 2), report.deleted);
    try std.testing.expectEqual(@as(usize, 1), report.deleted_source);
    try std.testing.expectEqual(@as(usize, 0), report.failed);
    inline for (.{ "documents-1.hybseg", "lexical-1.hyblex", "source-1.hybsrc" }) |gone| {
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, gone, .{}));
    }
    inline for (.{ "source-2.hybsrc", "source-3.hybsrc", "source-9.hybsrc", "source-04.hybsrc" }) |kept| {
        _ = try tmp.dir.statFile(io, kept, .{});
    }
    try std.testing.expectEqual(@as(?u64, 12), sourceGeneration("source-12.hybsrc"));
    try std.testing.expectEqual(@as(?u64, null), sourceGeneration("source-012.hybsrc"));
    try std.testing.expectEqual(@as(?u64, null), sourceGeneration("documents-1.hybseg"));
}
