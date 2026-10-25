const hybrid = @import("hybrid.zig");
const lexical_segment = @import("lexical_segment.zig");
const postings = @import("postings.zig");
const segment = @import("segment.zig");
const std = @import("std");

pub const magic = "HYBMAN01";
pub const filename_magic = "HYBMAN02";
pub const version: u16 = 1;
pub const header_length: usize = 88;
pub const filename_version: u16 = 2;
pub const filename_header_length: usize = 136;

pub const FilenameMetadata = struct {
    file_count: usize,
    term_count: usize,
    posting_count: usize,
    catalog_bytes: usize,
    catalog_checksum: u64,
    lexical_bytes: usize,
    lexical_checksum: u64,
    catalog_file: []const u8,
    lexical_file: []const u8,
    policy_id: []const u8,
};

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
    filename: ?FilenameMetadata = null,
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
    FilenameSectionsRequired,
    InvalidFilenameCatalog,
    InvalidFilenameLexicalSection,
    FilenameCountMismatch,
    FilenameTermCountMismatch,
    FilenamePostingCountMismatch,
    FilenameCatalogSizeMismatch,
    FilenameLexicalSizeMismatch,
    FilenameCatalogChecksumMismatch,
    FilenameLexicalChecksumMismatch,
    InvalidFilenamePolicy,
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

pub fn withFilename(
    base: Manifest,
    catalog_file: []const u8,
    filename_lexical_file: []const u8,
    catalog_encoded: []const u8,
    filename_lexical_encoded: []const u8,
) ManifestError!Manifest {
    const catalog = segment.inspect(catalog_encoded) catch return error.InvalidFilenameCatalog;
    const lexical = lexical_segment.inspect(filename_lexical_encoded) catch return error.InvalidFilenameLexicalSection;
    if (catalog.vector_dimensions != 0 or catalog.document_count != lexical.document_count) return error.FilenameCountMismatch;
    var value = base;
    value.filename = .{
        .file_count = catalog.document_count,
        .term_count = lexical.term_count,
        .posting_count = lexical.posting_count,
        .catalog_bytes = catalog_encoded.len,
        .catalog_checksum = catalog.checksum,
        .lexical_bytes = filename_lexical_encoded.len,
        .lexical_checksum = lexical.checksum,
        .catalog_file = catalog_file,
        .lexical_file = filename_lexical_file,
        .policy_id = "filename-field-v1",
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
    const header = if (value.filename != null) filename_header_length else header_length;
    if (value.filename) |filename| inline for (.{ filename.catalog_file, filename.lexical_file, filename.policy_id }) |field| {
        payload_length = try checkedAdd(payload_length, @sizeOf(u32));
        payload_length = try checkedAdd(payload_length, field.len);
    };
    return checkedAdd(header, payload_length);
}

pub fn encode(value: Manifest, output: []u8) ManifestError![]u8 {
    const required = try encodedLength(value);
    if (output.len < required) return error.BufferTooSmall;
    const is_filename = value.filename != null;
    const header_size = if (is_filename) filename_header_length else header_length;
    const payload_length = required - header_size;

    @memcpy(output[0..magic.len], if (is_filename) filename_magic else magic);
    var header_offset: usize = magic.len;
    writeU16(output, &header_offset, if (is_filename) filename_version else version);
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
    if (value.filename) |filename| {
        writeU32(output, &header_offset, @intCast(filename.file_count));
        writeU32(output, &header_offset, @intCast(filename.term_count));
        writeU64(output, &header_offset, @intCast(filename.posting_count));
        writeU64(output, &header_offset, @intCast(filename.catalog_bytes));
        writeU64(output, &header_offset, filename.catalog_checksum);
        writeU64(output, &header_offset, @intCast(filename.lexical_bytes));
        writeU64(output, &header_offset, filename.lexical_checksum);
    }
    writeU32(output, &header_offset, @intCast(payload_length));
    const checksum_offset = header_offset;
    writeU64(output, &header_offset, 0);
    std.debug.assert(header_offset == header_size);

    var payload_offset = header_size;
    inline for (.{ value.analyzer_id, value.embedding_model_id, value.documents_file, value.lexical_file }) |field| {
        writeU32(output, &payload_offset, @intCast(field.len));
        @memcpy(output[payload_offset .. payload_offset + field.len], field);
        payload_offset += field.len;
    }
    if (value.filename) |filename| inline for (.{ filename.catalog_file, filename.lexical_file, filename.policy_id }) |field| {
        writeU32(output, &payload_offset, @intCast(field.len));
        @memcpy(output[payload_offset .. payload_offset + field.len], field);
        payload_offset += field.len;
    };
    std.debug.assert(payload_offset == required);

    var checksum_write_offset = checksum_offset;
    writeU64(output, &checksum_write_offset, manifestChecksum(output[0..checksum_offset], output[header_size..required]));
    return output[0..required];
}

pub fn decode(encoded: []const u8) ManifestError!Manifest {
    var cursor = Cursor{ .bytes = encoded };
    const actual_magic = try cursor.take(magic.len);
    const is_filename = std.mem.eql(u8, actual_magic, filename_magic);
    if (!is_filename and !std.mem.eql(u8, actual_magic, magic)) return error.BadMagic;
    const actual_version = try cursor.readU16();
    if ((!is_filename and actual_version != version) or (is_filename and actual_version != filename_version)) return error.UnsupportedVersion;
    if (try cursor.readU16() != 0) return error.UnsupportedFlags;
    const generation = try cursor.readU64();
    const document_count = try castToUsize(try cursor.readU32());
    const vector_dimensions = try castToUsize(try cursor.readU32());
    const term_count = try castToUsize(try cursor.readU32());
    const reserved = try cursor.readU32();
    if (is_filename and reserved != 0) return error.UnsupportedFlags;
    const posting_count = try castToUsize(try cursor.readU64());
    const documents_bytes = try castToUsize(try cursor.readU64());
    const documents_checksum = try cursor.readU64();
    const lexical_bytes = try castToUsize(try cursor.readU64());
    const lexical_checksum = try cursor.readU64();
    var filename_metadata: ?FilenameMetadata = null;
    if (is_filename) {
        filename_metadata = .{
            .file_count = try castToUsize(try cursor.readU32()),
            .term_count = try castToUsize(try cursor.readU32()),
            .posting_count = try castToUsize(try cursor.readU64()),
            .catalog_bytes = try castToUsize(try cursor.readU64()),
            .catalog_checksum = try cursor.readU64(),
            .lexical_bytes = try castToUsize(try cursor.readU64()),
            .lexical_checksum = try cursor.readU64(),
            .catalog_file = "",
            .lexical_file = "",
            .policy_id = "",
        };
    }
    const payload_length = try castToUsize(try cursor.readU32());
    const expected_checksum = try cursor.readU64();
    const header_size = if (is_filename) filename_header_length else header_length;
    std.debug.assert(cursor.offset == header_size);

    const expected_total = try checkedAdd(header_size, payload_length);
    if (encoded.len < expected_total) return error.Truncated;
    if (encoded.len > expected_total) return error.TrailingData;
    if (manifestChecksum(encoded[0 .. header_size - @sizeOf(u64)], encoded[header_size..]) != expected_checksum) {
        return error.ChecksumMismatch;
    }

    var payload = Cursor{ .bytes = encoded[header_size..] };
    const analyzer_id = try readString(&payload);
    const embedding_model_id = try readString(&payload);
    const documents_file = try readString(&payload);
    const lexical_file = try readString(&payload);
    if (filename_metadata) |*filename| {
        filename.catalog_file = try readString(&payload);
        filename.lexical_file = try readString(&payload);
        filename.policy_id = try readString(&payload);
    }
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
        .filename = filename_metadata,
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
    if (value.filename != null) return error.FilenameSectionsRequired;
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

pub fn validateSnapshotWithFilename(
    value: Manifest,
    documents_encoded: []const u8,
    lexical_encoded: []const u8,
    catalog_encoded: []const u8,
    filename_lexical_encoded: []const u8,
) ManifestError!void {
    try validateSnapshotBody(value, documents_encoded, lexical_encoded);
    const filename = value.filename orelse return error.InvalidFilenamePolicy;
    if (catalog_encoded.len != filename.catalog_bytes) return error.FilenameCatalogSizeMismatch;
    if (filename_lexical_encoded.len != filename.lexical_bytes) return error.FilenameLexicalSizeMismatch;
    const catalog = segment.inspect(catalog_encoded) catch return error.InvalidFilenameCatalog;
    const lexical = lexical_segment.inspect(filename_lexical_encoded) catch return error.InvalidFilenameLexicalSection;
    if (catalog.checksum != filename.catalog_checksum) return error.FilenameCatalogChecksumMismatch;
    if (lexical.checksum != filename.lexical_checksum) return error.FilenameLexicalChecksumMismatch;
    if (catalog.document_count != filename.file_count or lexical.document_count != filename.file_count) return error.FilenameCountMismatch;
    if (catalog.vector_dimensions != 0) return error.InvalidFilenameCatalog;
    if (lexical.term_count != filename.term_count) return error.FilenameTermCountMismatch;
    if (lexical.posting_count != filename.posting_count) return error.FilenamePostingCountMismatch;
}

fn validateSnapshotBody(value: Manifest, documents_encoded: []const u8, lexical_encoded: []const u8) ManifestError!void {
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
    if (value.filename) |filename| {
        if (filename.file_count > std.math.maxInt(u32) or filename.term_count > std.math.maxInt(u32) or
            filename.posting_count > std.math.maxInt(u64) or filename.catalog_bytes > std.math.maxInt(u64) or
            filename.lexical_bytes > std.math.maxInt(u64)) return error.CountOverflow;
        try validateFilename(filename.catalog_file);
        try validateFilename(filename.lexical_file);
        try validateIdentifier(filename.policy_id);
        if (!std.mem.eql(u8, filename.policy_id, "filename-field-v1")) return error.InvalidFilenamePolicy;
        const names = .{ value.documents_file, value.lexical_file, filename.catalog_file, filename.lexical_file };
        inline for (0..4) |i| inline for (i + 1..4) |j| {
            if (std.mem.eql(u8, names[i], names[j])) return error.SameFilename;
        };
    }
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

test "filename manifest v2 round trips metadata and validates all section checksums" {
    var fixture = try SnapshotFixture.init();
    const base = try create(12, "ascii-alnum-v1", "manual-test-vectors-v1", "documents-12.hybseg", "lexical-12.hyblex", fixture.documentsEncoded(), fixture.lexicalEncoded());
    const catalog_documents = [_]hybrid.Document{
        .{ .id = "file-0", .path = "docs/alpha.txt", .text = "alpha", .vector = &.{}, .start_line = 1, .end_line = 1 },
        .{ .id = "file-1", .path = "docs/beta.md", .text = "beta", .vector = &.{}, .start_line = 1, .end_line = 1 },
    };
    var catalog_storage: [512]u8 = undefined;
    const catalog = try segment.encode(&catalog_documents, &catalog_storage);
    var filename_terms: [16]postings.TermEntry = undefined;
    var filename_postings: [16]postings.Posting = undefined;
    var filename_lengths: [catalog_documents.len]u32 = undefined;
    var filename_fills: [16]usize = undefined;
    const filename_index = try postings.build(&catalog_documents, &filename_terms, &filename_postings, &filename_lengths, &filename_fills);
    var filename_lexical_storage: [1024]u8 = undefined;
    const filename_lexical = try lexical_segment.encode(filename_index, &filename_lexical_storage);
    const value = try withFilename(base, "filenames-12.hybseg", "filename-lexical-12.hyblex", catalog, filename_lexical);

    var encoded_storage: [1024]u8 = undefined;
    const encoded = try encode(value, &encoded_storage);
    try std.testing.expectEqualStrings(filename_magic, encoded[0..8]);
    try std.testing.expectEqual(filename_version, @as(u16, encoded[8]) | (@as(u16, encoded[9]) << 8));
    try std.testing.expectEqual(filename_header_length, @as(usize, 136));
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, encoded[76..80], .little));
    try std.testing.expectEqual(@as(u32, @intCast(value.filename.?.term_count)), std.mem.readInt(u32, encoded[80..84], .little));
    try std.testing.expectEqual(@as(u64, @intCast(value.filename.?.posting_count)), std.mem.readInt(u64, encoded[84..92], .little));
    try std.testing.expectEqual(@as(u64, @intCast(catalog.len)), std.mem.readInt(u64, encoded[92..100], .little));
    try std.testing.expectEqual(@as(u64, @intCast(filename_lexical.len)), std.mem.readInt(u64, encoded[108..116], .little));
    const decoded = try decode(encoded);
    try std.testing.expectEqual(@as(usize, 2), decoded.filename.?.file_count);
    try std.testing.expectEqualStrings("filename-field-v1", decoded.filename.?.policy_id);
    try std.testing.expectEqualStrings("filenames-12.hybseg", decoded.filename.?.catalog_file);
    try validateSnapshotWithFilename(decoded, fixture.documentsEncoded(), fixture.lexicalEncoded(), catalog, filename_lexical);
    try std.testing.expectError(error.FilenameSectionsRequired, validateSnapshot(decoded, fixture.documentsEncoded(), fixture.lexicalEncoded()));

    var corrupt_header: [1024]u8 = undefined;
    @memcpy(corrupt_header[0..encoded.len], encoded);
    corrupt_header[80] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, decode(corrupt_header[0..encoded.len]));
    var corrupt_payload: [1024]u8 = undefined;
    @memcpy(corrupt_payload[0..encoded.len], encoded);
    corrupt_payload[encoded.len - 1] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, decode(corrupt_payload[0..encoded.len]));

    var reserved_nonzero: [1024]u8 = undefined;
    @memcpy(reserved_nonzero[0..encoded.len], encoded);
    reserved_nonzero[32] = 1;
    const reserved_checksum = manifestChecksum(reserved_nonzero[0..128], reserved_nonzero[filename_header_length..encoded.len]);
    var checksum_offset: usize = 128;
    writeU64(&reserved_nonzero, &checksum_offset, reserved_checksum);
    try std.testing.expectError(error.UnsupportedFlags, decode(reserved_nonzero[0..encoded.len]));

    const changed_catalog_documents = [_]hybrid.Document{
        .{ .id = "file-0", .path = "docs/alpha.txt", .text = "omega", .vector = &.{}, .start_line = 1, .end_line = 1 },
        .{ .id = "file-1", .path = "docs/beta.md", .text = "beta", .vector = &.{}, .start_line = 1, .end_line = 1 },
    };
    var changed_catalog_storage: [512]u8 = undefined;
    const changed_catalog = try segment.encode(&changed_catalog_documents, &changed_catalog_storage);
    try std.testing.expectEqual(catalog.len, changed_catalog.len);
    try std.testing.expectError(error.FilenameCatalogChecksumMismatch, validateSnapshotWithFilename(decoded, fixture.documentsEncoded(), fixture.lexicalEncoded(), changed_catalog, filename_lexical));
}

test "filename metadata requires the fixed policy and four distinct safe names" {
    var fixture = try SnapshotFixture.init();
    const base = try create(1, "ascii-v1", "none", "documents-1.hybseg", "lexical-1.hyblex", fixture.documentsEncoded(), fixture.lexicalEncoded());
    const empty_docs = [_]hybrid.Document{};
    var catalog_storage: [64]u8 = undefined;
    const catalog = try segment.encode(&empty_docs, &catalog_storage);
    var lengths: [0]u32 = .{};
    const empty_index = postings.Index{ .terms = &.{}, .postings = &.{}, .document_lengths = &lengths, .average_document_length = 0 };
    var lex_storage: [128]u8 = undefined;
    const lex = try lexical_segment.encode(empty_index, &lex_storage);
    try std.testing.expectError(error.SameFilename, withFilename(base, "documents-1.hybseg", "filename-lexical-1.hyblex", catalog, lex));
    var value = try withFilename(base, "filenames-1.hybseg", "filename-lexical-1.hyblex", catalog, lex);
    value.filename.?.policy_id = "other-policy";
    try std.testing.expectError(error.InvalidFilenamePolicy, encodedLength(value));
}
