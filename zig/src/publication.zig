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
    var atomic_file = try dir.createFileAtomic(io, filename, .{ .replace = false });
    defer atomic_file.deinit(io);
    try atomic_file.file.writeStreamingAll(io, bytes);
    try atomic_file.file.sync(io);
    try atomic_file.link(io);
}

fn replaceCurrentManifest(dir: std.Io.Dir, io: std.Io, bytes: []const u8) !void {
    var atomic_file = try dir.createFileAtomic(io, current_manifest_file, .{ .replace = true });
    defer atomic_file.deinit(io);
    try atomic_file.file.writeStreamingAll(io, bytes);
    try atomic_file.file.sync(io);
    try atomic_file.replace(io);
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
