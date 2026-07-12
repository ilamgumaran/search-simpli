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
    orphan_document_files: usize,
    orphan_lexical_files: usize,
    unknown_files: usize,
};

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
/// external retention/lease policy.
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
            std.mem.eql(u8, entry.name, writer_lock_file)) continue;
        if (current_metadata) |metadata| {
            if (std.mem.eql(u8, entry.name, metadata.documents_file) or
                std.mem.eql(u8, entry.name, metadata.lexical_file))
            {
                report.current_files += 1;
                continue;
            }
        }
        if (std.mem.endsWith(u8, entry.name, ".hybseg")) {
            report.orphan_document_files += 1;
        } else if (std.mem.endsWith(u8, entry.name, ".hyblex")) {
            report.orphan_lexical_files += 1;
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

    var manifest_read: [512]u8 = undefined;
    var document_read: [256]u8 = undefined;
    var lexical_read: [512]u8 = undefined;
    const report = try scan(tmp.dir, io, &manifest_read, &document_read, &lexical_read);
    try std.testing.expectEqual(@as(?u64, 1), report.current_generation);
    try std.testing.expectEqual(@as(usize, 2), report.current_files);
    try std.testing.expectEqual(@as(usize, 1), report.orphan_document_files);
    try std.testing.expectEqual(@as(usize, 1), report.orphan_lexical_files);
    try std.testing.expectEqual(@as(usize, 1), report.unknown_files);
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
