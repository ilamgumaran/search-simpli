const hybrid = @import("hybrid.zig");
const lexical_segment = @import("lexical_segment.zig");
const manifest = @import("manifest.zig");
const postings = @import("postings.zig");
const segment = @import("segment.zig");
const std = @import("std");

pub const current_manifest_file = "MANIFEST";

pub const LoadedSnapshot = struct {
    metadata: manifest.Manifest,
    manifest_encoded: []u8,
    documents_encoded: []u8,
    lexical_encoded: []u8,
};

/// Publish immutable generation files first and make them visible only by an
/// atomic replacement of MANIFEST after all bytes and metadata validate.
/// Generation files use non-replacing links, preventing accidental mutation.
pub fn publish(
    dir: std.Io.Dir,
    io: std.Io,
    manifest_encoded: []const u8,
    documents_encoded: []const u8,
    lexical_encoded: []const u8,
) !void {
    const metadata = try manifest.decode(manifest_encoded);
    try manifest.validateSnapshot(metadata, documents_encoded, lexical_encoded);

    try writeImmutable(dir, io, metadata.documents_file, documents_encoded);
    errdefer dir.deleteFile(io, metadata.documents_file) catch {};
    try writeImmutable(dir, io, metadata.lexical_file, lexical_encoded);
    errdefer dir.deleteFile(io, metadata.lexical_file) catch {};
    try replaceCurrentManifest(dir, io, manifest_encoded);
}

/// Load the atomically selected generation into caller-owned buffers, then
/// validate every manifest/section size, checksum, count, and version.
pub fn loadCurrent(
    dir: std.Io.Dir,
    io: std.Io,
    manifest_buffer: []u8,
    documents_buffer: []u8,
    lexical_buffer: []u8,
) !LoadedSnapshot {
    const manifest_encoded = try dir.readFile(io, current_manifest_file, manifest_buffer);
    const metadata = try manifest.decode(manifest_encoded);
    const documents_encoded = try dir.readFile(io, metadata.documents_file, documents_buffer);
    const lexical_encoded = try dir.readFile(io, metadata.lexical_file, lexical_buffer);
    try manifest.validateSnapshot(metadata, documents_encoded, lexical_encoded);
    return .{
        .metadata = metadata,
        .manifest_encoded = manifest_encoded,
        .documents_encoded = documents_encoded,
        .lexical_encoded = lexical_encoded,
    };
}

fn writeImmutable(dir: std.Io.Dir, io: std.Io, filename: []const u8, bytes: []const u8) !void {
    try writeAtomicFile(dir, io, filename, bytes, false);
}

fn replaceCurrentManifest(dir: std.Io.Dir, io: std.Io, bytes: []const u8) !void {
    try writeAtomicFile(dir, io, current_manifest_file, bytes, true);
}

/// Portable atomic file write: create a uniquely-named temporary file in
/// `dir` (`Dir.createFile` with `.exclusive = true`, i.e. plain
/// `open(O_CREAT|O_EXCL)`), write `bytes`, sync, then materialize it at
/// `filename` -- `dir.rename` (replacing) when `replace_existing` is true,
/// `dir.renamePreserve` (failing with `error.PathAlreadyExists` if
/// `filename` already exists, exactly as the immutable-section contract
/// requires) when false.
///
/// Deliberately does *not* use `Dir.createFileAtomic`: on Linux (Android
/// included), that function opens an *unnamed* temporary file with
/// `O_TMPFILE` whenever its `replace` option is false. Found on an Android
/// emulator (API 37, S1-T2's builder): the app's SELinux policy denies
/// `O_TMPFILE` inside the app's own private data directory, so publishing
/// the immutable `documents-N.hybseg`/`lexical-N.hyblex` sections (and
/// therefore `ss_import_json`, `searchd index`, and `searchd index
/// --update`) failed with `AccessDenied` on-device even though the
/// identical code worked on macOS, Linux desktop, and every emulator
/// version tested before. This helper never issues `O_TMPFILE`, on any
/// platform -- it always goes straight to the named-temp-file-plus-rename
/// sequence that `Dir.createFileAtomic`/`File.Atomic.link` themselves only
/// fall back to once a named temp file already exists -- so behavior is
/// identical everywhere the library runs, including inside an Android
/// app's private storage. See `docs/publication-recovery.md`.
pub fn writeAtomicFile(
    dir: std.Io.Dir,
    io: std.Io,
    filename: []const u8,
    bytes: []const u8,
    replace_existing: bool,
) !void {
    while (true) {
        var random_integer: u64 = undefined;
        io.random(std.mem.asBytes(&random_integer));
        const tmp_name = std.fmt.hex(random_integer);

        var file = dir.createFile(io, &tmp_name, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => |e| return e,
        };
        var file_open = true;
        var temp_exists = true;
        defer {
            if (file_open) file.close(io);
            if (temp_exists) dir.deleteFile(io, &tmp_name) catch {};
        }

        try file.writeStreamingAll(io, bytes);
        try file.sync(io);
        file.close(io);
        file_open = false;

        if (replace_existing) {
            try dir.rename(&tmp_name, dir, filename, io);
        } else {
            try dir.renamePreserve(&tmp_name, dir, filename, io);
        }
        temp_exists = false;
        return;
    }
}

const Fixture = struct {
    documents: [3]hybrid.Document,
    document_bytes: [512]u8,
    lexical_bytes: [2048]u8,
    document_length: usize,
    lexical_length: usize,

    fn init() !Fixture {
        var fixture = Fixture{
            .documents = .{
                .{ .id = "both", .text = "hybrid retrieval combines ranks", .vector = &.{ 0.8, 0.2 } },
                .{ .id = "lexical", .text = "hybrid hybrid exact", .vector = &.{ 0, 1 } },
                .{ .id = "semantic", .text = "meaning based result", .vector = &.{ 1, 0 } },
            },
            .document_bytes = undefined,
            .lexical_bytes = undefined,
            .document_length = 0,
            .lexical_length = 0,
        };
        fixture.document_length = (try segment.encode(&fixture.documents, &fixture.document_bytes)).len;
        var terms: [24]postings.TermEntry = undefined;
        var posting_storage: [32]postings.Posting = undefined;
        var lengths: [fixture.documents.len]u32 = undefined;
        var fills: [24]usize = undefined;
        const index = try postings.build(&fixture.documents, &terms, &posting_storage, &lengths, &fills);
        fixture.lexical_length = (try lexical_segment.encode(index, &fixture.lexical_bytes)).len;
        return fixture;
    }

    fn documentsEncoded(fixture: *Fixture) []u8 {
        return fixture.document_bytes[0..fixture.document_length];
    }

    fn lexicalEncoded(fixture: *Fixture) []u8 {
        return fixture.lexical_bytes[0..fixture.lexical_length];
    }

    fn encodeManifest(
        fixture: *Fixture,
        generation: u64,
        documents_file: []const u8,
        lexical_file: []const u8,
        output: []u8,
    ) ![]u8 {
        const metadata = try manifest.create(
            generation,
            "ascii-alnum-v1",
            "manual-test-vectors-v1",
            documents_file,
            lexical_file,
            fixture.documentsEncoded(),
            fixture.lexicalEncoded(),
        );
        return manifest.encode(metadata, output);
    }
};

test "publication atomically selects a complete generation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var fixture = try Fixture.init();
    var manifest_one_storage: [512]u8 = undefined;
    const manifest_one = try fixture.encodeManifest(1, "documents-1.hybseg", "lexical-1.hyblex", &manifest_one_storage);
    try publish(tmp.dir, io, manifest_one, fixture.documentsEncoded(), fixture.lexicalEncoded());

    var manifest_read_buffer: [512]u8 = undefined;
    var documents_read_buffer: [512]u8 = undefined;
    var lexical_read_buffer: [2048]u8 = undefined;
    const first = try loadCurrent(tmp.dir, io, &manifest_read_buffer, &documents_read_buffer, &lexical_read_buffer);
    try std.testing.expectEqual(@as(u64, 1), first.metadata.generation);

    var decoded_documents: [3]hybrid.Document = undefined;
    var vector_storage: [6]f32 = undefined;
    const documents = try segment.decode(first.documents_encoded, &decoded_documents, &vector_storage);
    var decoded_terms: [24]postings.TermEntry = undefined;
    var decoded_postings: [32]postings.Posting = undefined;
    var decoded_lengths: [3]u32 = undefined;
    const lexical_index = try lexical_segment.decode(first.lexical_encoded, &decoded_terms, &decoded_postings, &decoded_lengths);
    var score_storage: [3]f32 = undefined;
    const lexical_scores = try postings.scoreQuery(lexical_index, "hybrid", &score_storage, .{});
    var result_workspace: [3]hybrid.Result = undefined;
    const results = try hybrid.searchWithLexicalScores(&.{ 1, 0 }, documents, lexical_scores, &result_workspace, .{});
    try std.testing.expectEqualStrings("both", results[0].document_id);

    var manifest_two_storage: [512]u8 = undefined;
    const manifest_two = try fixture.encodeManifest(2, "documents-2.hybseg", "lexical-2.hyblex", &manifest_two_storage);
    try publish(tmp.dir, io, manifest_two, fixture.documentsEncoded(), fixture.lexicalEncoded());
    const second = try loadCurrent(tmp.dir, io, &manifest_read_buffer, &documents_read_buffer, &lexical_read_buffer);
    try std.testing.expectEqual(@as(u64, 2), second.metadata.generation);
    try std.testing.expectEqualStrings("documents-2.hybseg", second.metadata.documents_file);
}

test "failed immutable filename reuse leaves current generation unchanged" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var fixture = try Fixture.init();
    var manifest_one_storage: [512]u8 = undefined;
    const manifest_one = try fixture.encodeManifest(1, "documents-1.hybseg", "lexical-1.hyblex", &manifest_one_storage);
    try publish(tmp.dir, io, manifest_one, fixture.documentsEncoded(), fixture.lexicalEncoded());

    var conflicting_storage: [512]u8 = undefined;
    const conflicting = try fixture.encodeManifest(2, "documents-1.hybseg", "lexical-1.hyblex", &conflicting_storage);
    try std.testing.expectError(error.PathAlreadyExists, publish(tmp.dir, io, conflicting, fixture.documentsEncoded(), fixture.lexicalEncoded()));

    var manifest_read_buffer: [512]u8 = undefined;
    var documents_read_buffer: [512]u8 = undefined;
    var lexical_read_buffer: [2048]u8 = undefined;
    const current = try loadCurrent(tmp.dir, io, &manifest_read_buffer, &documents_read_buffer, &lexical_read_buffer);
    try std.testing.expectEqual(@as(u64, 1), current.metadata.generation);
}

test "invalid snapshot is rejected before MANIFEST visibility" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var fixture = try Fixture.init();
    var manifest_storage: [512]u8 = undefined;
    const manifest_encoded = try fixture.encodeManifest(1, "documents-1.hybseg", "lexical-1.hyblex", &manifest_storage);
    const documents_encoded = fixture.documentsEncoded();
    documents_encoded[documents_encoded.len - 1] ^= 0xff;
    try std.testing.expectError(error.InvalidDocumentSection, publish(tmp.dir, io, manifest_encoded, documents_encoded, fixture.lexicalEncoded()));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, current_manifest_file, .{}));
}

// S1-T3 (docs/tasks/S1-T3.md criterion 6, added by the orchestrator after
// S1-T2's builder found `ss_import_json` failing with AccessDenied on an
// Android emulator): `writeAtomicFile` must never depend on `O_TMPFILE`
// (SELinux denies it inside an app's private directory) and must leave no
// stray temp file behind, on both the success path and a `renamePreserve`
// failure.
test "writeAtomicFile materializes bytes at the destination and leaves no stray temp file" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;

    try writeAtomicFile(tmp.dir, io, "dest.txt", "hello", false);

    var read_buffer: [16]u8 = undefined;
    const read_back = try tmp.dir.readFile(io, "dest.txt", &read_buffer);
    try std.testing.expectEqualStrings("hello", read_back);

    // Exactly one file exists: the destination itself. No leftover
    // 16-hex-character temp file from the create-temp/rename sequence.
    var count: usize = 0;
    var iterator = tmp.dir.iterate();
    while (try iterator.next(io)) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "writeAtomicFile with replace_existing=false fails closed and cleans up its temp file" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;

    try writeAtomicFile(tmp.dir, io, "dest.txt", "first", false);
    try std.testing.expectError(error.PathAlreadyExists, writeAtomicFile(tmp.dir, io, "dest.txt", "second", false));

    // The original content is untouched, and the failed attempt's named
    // temp file was cleaned up rather than left as an orphan.
    var read_buffer: [16]u8 = undefined;
    const read_back = try tmp.dir.readFile(io, "dest.txt", &read_buffer);
    try std.testing.expectEqualStrings("first", read_back);

    var count: usize = 0;
    var iterator = tmp.dir.iterate();
    while (try iterator.next(io)) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "writeAtomicFile with replace_existing=true overwrites and leaves no stray temp file" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;

    try writeAtomicFile(tmp.dir, io, "dest.txt", "first", true);
    try writeAtomicFile(tmp.dir, io, "dest.txt", "second-and-longer", true);

    var read_buffer: [32]u8 = undefined;
    const read_back = try tmp.dir.readFile(io, "dest.txt", &read_buffer);
    try std.testing.expectEqualStrings("second-and-longer", read_back);

    var count: usize = 0;
    var iterator = tmp.dir.iterate();
    while (try iterator.next(io)) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 1), count);
}
