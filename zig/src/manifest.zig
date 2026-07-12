const hybrid = @import("hybrid.zig");
const lexical_segment = @import("lexical_segment.zig");
const postings = @import("postings.zig");
const segment = @import("segment.zig");
const std = @import("std");

pub const magic = "HYBMAN01";
pub const version: u16 = 1;
pub const header_length: usize = 88;

pub const Manifest = struct {
    generation: u64,
    document_count: usize,
    vector_dimensions: usize,
    term_count: usize,
    posting_count: usize,
    documents_bytes: usize,
    documents_checksum: u64,
    lexical_bytes: usize,
    lexical_checksum: u64,
    analyzer_id: []const u8,
    embedding_model_id: []const u8,
    documents_file: []const u8,
    lexical_file: []const u8,
};

pub const ManifestError = error{
    BufferTooSmall,
    BadMagic,
    UnsupportedVersion,
    UnsupportedFlags,
    Truncated,
    TrailingData,
    ChecksumMismatch,
    SizeOverflow,
    CountOverflow,
    GenerationZero,
    InvalidIdentifier,
    UnsafeFilename,
    SameFilename,
    InvalidDocumentSection,
    InvalidLexicalSection,
    DocumentCountMismatch,
    VectorDimensionMismatch,
    TermCountMismatch,
    PostingCountMismatch,
    DocumentSectionSizeMismatch,
    LexicalSectionSizeMismatch,
    DocumentSectionChecksumMismatch,
    LexicalSectionChecksumMismatch,
};

pub fn create(
    generation: u64,
    analyzer_id: []const u8,
    embedding_model_id: []const u8,
    documents_file: []const u8,
    lexical_file: []const u8,
    documents_encoded: []const u8,
    lexical_encoded: []const u8,
) ManifestError!Manifest {
    const document_header = segment.inspect(documents_encoded) catch return error.InvalidDocumentSection;
    const lexical_header = lexical_segment.inspect(lexical_encoded) catch return error.InvalidLexicalSection;
    if (document_header.document_count != lexical_header.document_count) return error.DocumentCountMismatch;
    const value = Manifest{
        .generation = generation,
        .document_count = document_header.document_count,
        .vector_dimensions = document_header.vector_dimensions,
        .term_count = lexical_header.term_count,
        .posting_count = lexical_header.posting_count,
        .documents_bytes = documents_encoded.len,
        .documents_checksum = document_header.checksum,
        .lexical_bytes = lexical_encoded.len,
        .lexical_checksum = lexical_header.checksum,
        .analyzer_id = analyzer_id,
        .embedding_model_id = embedding_model_id,
        .documents_file = documents_file,
        .lexical_file = lexical_file,
    };
    try validateFields(value);
    return value;
}

pub fn encodedLength(value: Manifest) ManifestError!usize {
    try validateFields(value);
    var payload_length: usize = 0;
    inline for (.{ value.analyzer_id, value.embedding_model_id, value.documents_file, value.lexical_file }) |field| {
        payload_length = try checkedAdd(payload_length, @sizeOf(u32));
        payload_length = try checkedAdd(payload_length, field.len);
    }
    return checkedAdd(header_length, payload_length);
}

pub fn encode(value: Manifest, output: []u8) ManifestError![]u8 {
    const required = try encodedLength(value);
    if (output.len < required) return error.BufferTooSmall;
    const payload_length = required - header_length;

    @memcpy(output[0..magic.len], magic);
    var header_offset: usize = magic.len;
    writeU16(output, &header_offset, version);
    writeU16(output, &header_offset, 0);
    writeU64(output, &header_offset, value.generation);
    writeU32(output, &header_offset, @intCast(value.document_count));
    writeU32(output, &header_offset, @intCast(value.vector_dimensions));
    writeU32(output, &header_offset, @intCast(value.term_count));
    writeU32(output, &header_offset, 0);
    writeU64(output, &header_offset, @intCast(value.posting_count));
    writeU64(output, &header_offset, @intCast(value.documents_bytes));
    writeU64(output, &header_offset, value.documents_checksum);
    writeU64(output, &header_offset, @intCast(value.lexical_bytes));
    writeU64(output, &header_offset, value.lexical_checksum);
    writeU32(output, &header_offset, @intCast(payload_length));
    const checksum_offset = header_offset;
    writeU64(output, &header_offset, 0);
    std.debug.assert(header_offset == header_length);

    var payload_offset = header_length;
    inline for (.{ value.analyzer_id, value.embedding_model_id, value.documents_file, value.lexical_file }) |field| {
        writeU32(output, &payload_offset, @intCast(field.len));
        @memcpy(output[payload_offset .. payload_offset + field.len], field);
        payload_offset += field.len;
    }
    std.debug.assert(payload_offset == required);

    var checksum_write_offset = checksum_offset;
    writeU64(output, &checksum_write_offset, manifestChecksum(output[0..checksum_offset], output[header_length..required]));
    return output[0..required];
}

pub fn decode(encoded: []const u8) ManifestError!Manifest {
    var cursor = Cursor{ .bytes = encoded };
    if (!std.mem.eql(u8, try cursor.take(magic.len), magic)) return error.BadMagic;
    if (try cursor.readU16() != version) return error.UnsupportedVersion;
    if (try cursor.readU16() != 0) return error.UnsupportedFlags;
    const generation = try cursor.readU64();
    const document_count = try castToUsize(try cursor.readU32());
    const vector_dimensions = try castToUsize(try cursor.readU32());
    const term_count = try castToUsize(try cursor.readU32());
    _ = try cursor.readU32();
    const posting_count = try castToUsize(try cursor.readU64());
    const documents_bytes = try castToUsize(try cursor.readU64());
    const documents_checksum = try cursor.readU64();
    const lexical_bytes = try castToUsize(try cursor.readU64());
    const lexical_checksum = try cursor.readU64();
    const payload_length = try castToUsize(try cursor.readU32());
    const expected_checksum = try cursor.readU64();
    std.debug.assert(cursor.offset == header_length);

    const expected_total = try checkedAdd(header_length, payload_length);
    if (encoded.len < expected_total) return error.Truncated;
    if (encoded.len > expected_total) return error.TrailingData;
    if (manifestChecksum(encoded[0 .. header_length - @sizeOf(u64)], encoded[header_length..]) != expected_checksum) {
        return error.ChecksumMismatch;
    }

    var payload = Cursor{ .bytes = encoded[header_length..] };
    const analyzer_id = try readString(&payload);
    const embedding_model_id = try readString(&payload);
    const documents_file = try readString(&payload);
    const lexical_file = try readString(&payload);
    if (payload.offset != payload.bytes.len) return error.TrailingData;
    const value = Manifest{
        .generation = generation,
        .document_count = document_count,
        .vector_dimensions = vector_dimensions,
        .term_count = term_count,
        .posting_count = posting_count,
        .documents_bytes = documents_bytes,
        .documents_checksum = documents_checksum,
        .lexical_bytes = lexical_bytes,
        .lexical_checksum = lexical_checksum,
        .analyzer_id = analyzer_id,
        .embedding_model_id = embedding_model_id,
        .documents_file = documents_file,
        .lexical_file = lexical_file,
    };
    try validateFields(value);
    return value;
}

pub fn validateSnapshot(
    value: Manifest,
    documents_encoded: []const u8,
    lexical_encoded: []const u8,
) ManifestError!void {
    try validateFields(value);
    if (documents_encoded.len != value.documents_bytes) return error.DocumentSectionSizeMismatch;
    if (lexical_encoded.len != value.lexical_bytes) return error.LexicalSectionSizeMismatch;
    const document_header = segment.inspect(documents_encoded) catch return error.InvalidDocumentSection;
    const lexical_header = lexical_segment.inspect(lexical_encoded) catch return error.InvalidLexicalSection;
    if (document_header.checksum != value.documents_checksum) return error.DocumentSectionChecksumMismatch;
    if (lexical_header.checksum != value.lexical_checksum) return error.LexicalSectionChecksumMismatch;
    if (document_header.document_count != value.document_count or lexical_header.document_count != value.document_count) {
        return error.DocumentCountMismatch;
    }
    if (document_header.vector_dimensions != value.vector_dimensions) return error.VectorDimensionMismatch;
    if (lexical_header.term_count != value.term_count) return error.TermCountMismatch;
    if (lexical_header.posting_count != value.posting_count) return error.PostingCountMismatch;
}

fn validateFields(value: Manifest) ManifestError!void {
    if (value.generation == 0) return error.GenerationZero;
    if (value.document_count > std.math.maxInt(u32) or
        value.vector_dimensions > std.math.maxInt(u32) or
        value.term_count > std.math.maxInt(u32)) return error.CountOverflow;
    try validateIdentifier(value.analyzer_id);
    try validateIdentifier(value.embedding_model_id);
    try validateFilename(value.documents_file);
    try validateFilename(value.lexical_file);
    if (std.mem.eql(u8, value.documents_file, value.lexical_file)) return error.SameFilename;
}

fn validateIdentifier(value: []const u8) ManifestError!void {
    if (value.len == 0 or value.len > std.math.maxInt(u32)) return error.InvalidIdentifier;
    for (value) |byte| {
        if (byte == 0 or byte == '\n' or byte == '\r') return error.InvalidIdentifier;
    }
}

fn validateFilename(value: []const u8) ManifestError!void {
    if (value.len == 0 or value.len > std.math.maxInt(u32) or std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..")) {
        return error.UnsafeFilename;
    }
    for (value) |byte| {
        if (byte == 0 or byte == '/' or byte == '\\' or byte == '\n' or byte == '\r') return error.UnsafeFilename;
    }
}

fn readString(cursor: *Cursor) ManifestError![]const u8 {
    const length = try castToUsize(try cursor.readU32());
    return cursor.take(length);
}

fn checkedAdd(left: usize, right: usize) ManifestError!usize {
    return std.math.add(usize, left, right) catch error.SizeOverflow;
}

fn castToUsize(value: anytype) ManifestError!usize {
    return std.math.cast(usize, value) orelse error.SizeOverflow;
}

fn manifestChecksum(header_without_checksum: []const u8, payload: []const u8) u64 {
    var value: u64 = 14_695_981_039_346_656_037;
    value = checksumUpdate(value, header_without_checksum);
    value = checksumUpdate(value, payload);
    return value;
}

fn checksumUpdate(initial: u64, bytes: []const u8) u64 {
    var value = initial;
    for (bytes) |byte| {
        value ^= byte;
        value *%= 1_099_511_628_211;
    }
    return value;
}

fn writeU16(output: []u8, offset: *usize, value: u16) void {
    output[offset.*] = @truncate(value);
    output[offset.* + 1] = @truncate(value >> 8);
    offset.* += 2;
}

fn writeU32(output: []u8, offset: *usize, value: u32) void {
    inline for (0..4) |index| output[offset.* + index] = @truncate(value >> @intCast(index * 8));
    offset.* += 4;
}

fn writeU64(output: []u8, offset: *usize, value: u64) void {
    inline for (0..8) |index| output[offset.* + index] = @truncate(value >> @intCast(index * 8));
    offset.* += 8;
}

const Cursor = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn take(cursor: *Cursor, length: usize) ManifestError![]const u8 {
        const end = try checkedAdd(cursor.offset, length);
        if (end > cursor.bytes.len) return error.Truncated;
        defer cursor.offset = end;
        return cursor.bytes[cursor.offset..end];
    }

    fn readU16(cursor: *Cursor) ManifestError!u16 {
        const bytes = try cursor.take(2);
        return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
    }

    fn readU32(cursor: *Cursor) ManifestError!u32 {
        const bytes = try cursor.take(4);
        var value: u32 = 0;
        inline for (0..4) |index| value |= @as(u32, bytes[index]) << @intCast(index * 8);
        return value;
    }

    fn readU64(cursor: *Cursor) ManifestError!u64 {
        const bytes = try cursor.take(8);
        var value: u64 = 0;
        inline for (0..8) |index| value |= @as(u64, bytes[index]) << @intCast(index * 8);
        return value;
    }
};

const SnapshotFixture = struct {
    documents: [3]hybrid.Document,
    document_bytes: [512]u8,
    lexical_bytes: [2048]u8,
    document_length: usize,
    lexical_length: usize,

    fn init() !SnapshotFixture {
        var fixture = SnapshotFixture{
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

    fn documentsEncoded(fixture: *SnapshotFixture) []u8 {
        return fixture.document_bytes[0..fixture.document_length];
    }

    fn lexicalEncoded(fixture: *SnapshotFixture) []u8 {
        return fixture.lexical_bytes[0..fixture.lexical_length];
    }
};

test "manifest round trip validates both immutable sections" {
    var fixture = try SnapshotFixture.init();
    const documents_encoded = fixture.documentsEncoded();
    const lexical_encoded = fixture.lexicalEncoded();
    const source = try create(
        7,
        "ascii-alnum-v1",
        "manual-test-vectors-v1",
        "documents-7.hybseg",
        "lexical-7.hyblex",
        documents_encoded,
        lexical_encoded,
    );
    var encoded_storage: [512]u8 = undefined;
    const encoded = try encode(source, &encoded_storage);
    const decoded = try decode(encoded);
    try std.testing.expectEqual(@as(u64, 7), decoded.generation);
    try std.testing.expectEqualStrings("ascii-alnum-v1", decoded.analyzer_id);
    try std.testing.expectEqualStrings("manual-test-vectors-v1", decoded.embedding_model_id);
    try validateSnapshot(decoded, documents_encoded, lexical_encoded);
}

test "manifest rejects cross-section document count disagreement" {
    var fixture = try SnapshotFixture.init();
    const lexical_encoded = fixture.lexicalEncoded();
    const shorter_documents = [_]hybrid.Document{ fixture.documents[0], fixture.documents[1] };
    var shorter_storage: [512]u8 = undefined;
    const shorter_encoded = try segment.encode(&shorter_documents, &shorter_storage);
    try std.testing.expectError(error.DocumentCountMismatch, create(
        1,
        "ascii-alnum-v1",
        "manual-test-vectors-v1",
        "documents-1.hybseg",
        "lexical-1.hyblex",
        shorter_encoded,
        lexical_encoded,
    ));
}

test "manifest checksum detects metadata and payload corruption" {
    var fixture = try SnapshotFixture.init();
    const documents_encoded = fixture.documentsEncoded();
    const lexical_encoded = fixture.lexicalEncoded();
    const source = try create(1, "ascii-v1", "none", "documents-1.hybseg", "lexical-1.hyblex", documents_encoded, lexical_encoded);
    var metadata_storage: [512]u8 = undefined;
    const metadata = try encode(source, &metadata_storage);
    metadata[12] ^= 0xff;
    try std.testing.expectError(error.ChecksumMismatch, decode(metadata));

    var payload_storage: [512]u8 = undefined;
    const payload = try encode(source, &payload_storage);
    payload[payload.len - 1] ^= 0xff;
    try std.testing.expectError(error.ChecksumMismatch, decode(payload));
}

test "snapshot validation detects wrong or corrupted section" {
    var fixture = try SnapshotFixture.init();
    const documents_encoded = fixture.documentsEncoded();
    const lexical_encoded = fixture.lexicalEncoded();
    const source = try create(1, "ascii-v1", "none", "documents-1.hybseg", "lexical-1.hyblex", documents_encoded, lexical_encoded);
    documents_encoded[documents_encoded.len - 1] ^= 0xff;
    try std.testing.expectError(error.InvalidDocumentSection, validateSnapshot(source, documents_encoded, lexical_encoded));
}

test "manifest rejects unsafe filenames and invalid identifiers" {
    var fixture = try SnapshotFixture.init();
    const documents_encoded = fixture.documentsEncoded();
    const lexical_encoded = fixture.lexicalEncoded();
    try std.testing.expectError(error.UnsafeFilename, create(1, "ascii-v1", "none", "../documents", "lexical", documents_encoded, lexical_encoded));
    try std.testing.expectError(error.SameFilename, create(1, "ascii-v1", "none", "same", "same", documents_encoded, lexical_encoded));
    try std.testing.expectError(error.InvalidIdentifier, create(1, "", "none", "documents", "lexical", documents_encoded, lexical_encoded));
}
