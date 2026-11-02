const checksum = @import("checksum.zig");
const hybrid = @import("hybrid.zig");
const std = @import("std");

pub const magic = "HYBSEG01";
/// Newest record version this module reads and writes (S3-T1: v4,
/// `docs/segment-format-v4.md`). `encode` keeps writing v3 byte for byte
/// (the importer and every pre-S3 writer); `encodeV4` writes v4.
pub const version: u16 = 4;
pub const legacy_version: u16 = 3;
pub const minimum_supported_version: u16 = 1;
const v3_fixed_length: usize = 28;
const v4_fixed_length: usize = 44;
pub const header_length: usize = 36;

pub const EncodeError = error{
    BufferTooSmall,
    DocumentCountOverflow,
    FieldTooLarge,
    SizeOverflow,
    VectorDimensionsInconsistent,
    InvalidCitation,
    InvalidRequiredLabels,
    InvalidSection,
    RequiresVersion4,
};

pub const DecodeError = error{
    BadMagic,
    UnsupportedVersion,
    UnsupportedFlags,
    Truncated,
    ChecksumMismatch,
    TrailingData,
    DocumentCapacityTooSmall,
    VectorCapacityTooSmall,
    InvalidVectorDimensions,
    InvalidCitation,
    InvalidRequiredLabels,
    InvalidSection,
    SizeOverflow,
};

pub const Header = struct {
    format_version: u16,
    document_count: usize,
    vector_dimensions: usize,
    payload_length: usize,
    checksum: u64,
    /// S4-T1: header flags bit 0 (`checksum.flag_xxh3`); record v4 sets it.
    checksum_kind: checksum.Kind = .fnv1a64,
};

/// Return the exact number of bytes required by encode (record v3).
pub fn encodedLength(documents: []const hybrid.Document) EncodeError!usize {
    return encodedLengthVersion(documents, legacy_version);
}

/// Return the exact number of bytes required by encodeV4.
pub fn encodedLengthV4(documents: []const hybrid.Document) EncodeError!usize {
    return encodedLengthVersion(documents, version);
}

fn hasV4Fields(document: hybrid.Document) bool {
    return document.chunker_index != 0 or document.section_depth != 0 or document.heading_line != 0 or
        document.source_doc_index != hybrid.no_source_doc or document.section_path.len != 0;
}

fn encodedLengthVersion(documents: []const hybrid.Document, record_version: u16) EncodeError!usize {
    _ = try vectorDimensions(documents);
    if (documents.len > std.math.maxInt(u32)) return error.DocumentCountOverflow;

    var length = header_length;
    for (documents) |document| {
        try validateCitation(document.path, document.start_line, document.end_line);
        try validateFieldLength(document.id.len);
        try validateFieldLength(document.path.len);
        try validateFieldLength(document.text.len);
        try validateFieldLength(document.vector.len);
        try validateFieldLength(document.required_labels.len);
        try validateRequiredLabels(document.required_labels);
        if (record_version >= 4) {
            try validateFieldLength(document.section_path.len);
            validateSection(document.section_depth, document.heading_line, document.start_line, document.section_path) catch
                return error.InvalidSection;
            length = try checkedAdd(length, v4_fixed_length);
            length = try checkedAdd(length, document.section_path.len);
        } else {
            if (hasV4Fields(document)) return error.RequiresVersion4;
            length = try checkedAdd(length, v3_fixed_length);
        }
        length = try checkedAdd(length, document.id.len);
        length = try checkedAdd(length, document.path.len);
        length = try checkedAdd(length, document.text.len);
        length = try checkedAdd(length, document.required_labels.len);
        length = try checkedAdd(length, try checkedMultiply(document.vector.len, @sizeOf(f32)));
    }
    return length;
}

/// Encode one immutable segment (record v3) into caller-owned memory.
pub fn encode(documents: []const hybrid.Document, output: []u8) EncodeError![]u8 {
    return encodeVersion(documents, output, legacy_version);
}

/// Encode one immutable segment with record v4 (chunker index, section
/// path, heading line, source document index).
pub fn encodeV4(documents: []const hybrid.Document, output: []u8) EncodeError![]u8 {
    return encodeVersion(documents, output, version);
}

fn encodeVersion(documents: []const hybrid.Document, output: []u8, record_version: u16) EncodeError![]u8 {
    const required = try encodedLengthVersion(documents, record_version);
    if (output.len < required) return error.BufferTooSmall;
    const dimensions = try vectorDimensions(documents);

    @memcpy(output[0..magic.len], magic);
    var header_offset: usize = magic.len;
    writeU16(output, &header_offset, record_version);
    // Flags: bit 0 (S4-T1) = XXH3-64 checksum. Record v4 (the folder
    // writers) sets it; v3 (`import-json`) stays FNV-1a byte for byte.
    const kind: checksum.Kind = if (record_version >= 4) .xxh3_64 else .fnv1a64;
    writeU16(output, &header_offset, checksum.flagsOf(kind));
    writeU32(output, &header_offset, @intCast(documents.len));
    writeU32(output, &header_offset, @intCast(dimensions));
    writeU64(output, &header_offset, @intCast(required - header_length));
    const checksum_offset = header_offset;
    writeU64(output, &header_offset, 0);
    std.debug.assert(header_offset == header_length);

    var payload_offset = header_length;
    for (documents) |document| {
        writeU32(output, &payload_offset, @intCast(document.id.len));
        writeU32(output, &payload_offset, @intCast(document.path.len));
        writeU32(output, &payload_offset, @intCast(document.text.len));
        writeU32(output, &payload_offset, @intCast(document.vector.len));
        writeU32(output, &payload_offset, document.start_line);
        writeU32(output, &payload_offset, document.end_line);
        writeU32(output, &payload_offset, @intCast(document.required_labels.len));
        if (record_version >= 4) {
            writeU16(output, &payload_offset, document.chunker_index);
            writeU16(output, &payload_offset, document.section_depth);
            writeU32(output, &payload_offset, document.heading_line);
            writeU32(output, &payload_offset, document.source_doc_index);
            writeU32(output, &payload_offset, @intCast(document.section_path.len));
        }
        @memcpy(output[payload_offset .. payload_offset + document.id.len], document.id);
        payload_offset += document.id.len;
        @memcpy(output[payload_offset .. payload_offset + document.path.len], document.path);
        payload_offset += document.path.len;
        @memcpy(output[payload_offset .. payload_offset + document.text.len], document.text);
        payload_offset += document.text.len;
        @memcpy(output[payload_offset .. payload_offset + document.required_labels.len], document.required_labels);
        payload_offset += document.required_labels.len;
        for (document.vector) |value| writeU32(output, &payload_offset, @bitCast(value));
        if (record_version >= 4) {
            @memcpy(output[payload_offset .. payload_offset + document.section_path.len], document.section_path);
            payload_offset += document.section_path.len;
        }
    }
    std.debug.assert(payload_offset == required);

    var checksum_write_offset = checksum_offset;
    writeU64(output, &checksum_write_offset, checksum.compute(kind, output[0..checksum_offset], output[header_length..required]));
    return output[0..required];
}

/// Read and validate only the segment header and payload checksum.
pub fn inspect(encoded: []const u8) DecodeError!Header {
    var cursor = Cursor{ .bytes = encoded };
    const actual_magic = try cursor.take(magic.len);
    if (!std.mem.eql(u8, actual_magic, magic)) return error.BadMagic;
    const actual_version = try cursor.readU16();
    if (actual_version < minimum_supported_version or actual_version > version) return error.UnsupportedVersion;
    // Flags: bit 0 (S4-T1) selects XXH3-64; before S4-T1 the field was
    // written zero and not read, and any other bit is refused.
    const flags = try cursor.readU16();
    if (flags & ~checksum.flag_xxh3 != 0) return error.UnsupportedFlags;
    const kind = checksum.kindOfFlags(flags);
    const document_count: usize = try castU64ToUsize(try cursor.readU32());
    const dimensions: usize = try castU64ToUsize(try cursor.readU32());
    const payload_length: usize = try castU64ToUsize(try cursor.readU64());
    const expected_checksum = try cursor.readU64();
    std.debug.assert(cursor.offset == header_length);

    const expected_total = try decodeCheckedAdd(header_length, payload_length);
    if (encoded.len < expected_total) return error.Truncated;
    if (encoded.len > expected_total) return error.TrailingData;
    const actual_checksum = checksum.compute(kind, encoded[0 .. header_length - @sizeOf(u64)], encoded[header_length..]);
    if (actual_checksum != expected_checksum) return error.ChecksumMismatch;
    return .{
        .format_version = actual_version,
        .document_count = document_count,
        .vector_dimensions = dimensions,
        .payload_length = payload_length,
        .checksum = expected_checksum,
        .checksum_kind = kind,
    };
}

/// Decode zero-copy ids/text and copied, aligned f32 vectors into caller-owned
/// workspaces. The returned document slices borrow both encoded and vectors.
pub fn decode(
    encoded: []const u8,
    document_output: []hybrid.Document,
    vector_output: []f32,
) DecodeError![]hybrid.Document {
    return decodeInspected(encoded, try inspect(encoded), document_output, vector_output);
}

/// `decode` for bytes whose header `inspect` already validated (checksum
/// included), so the checksum is not computed a second time (S4-T1).
pub fn decodeInspected(
    encoded: []const u8,
    header: Header,
    document_output: []hybrid.Document,
    vector_output: []f32,
) DecodeError![]hybrid.Document {
    if (document_output.len < header.document_count) return error.DocumentCapacityTooSmall;

    var cursor = Cursor{ .bytes = encoded, .offset = header_length };
    var vector_offset: usize = 0;
    for (document_output[0..header.document_count]) |*document| {
        const id_length: usize = try castU64ToUsize(try cursor.readU32());
        const path_length: usize = if (header.format_version >= 2)
            try castU64ToUsize(try cursor.readU32())
        else
            0;
        const text_length: usize = try castU64ToUsize(try cursor.readU32());
        const vector_length: usize = try castU64ToUsize(try cursor.readU32());
        const start_line: u32 = if (header.format_version >= 2) try cursor.readU32() else 0;
        const end_line: u32 = if (header.format_version >= 2) try cursor.readU32() else 0;
        const required_labels_length: usize = if (header.format_version >= 3)
            try castU64ToUsize(try cursor.readU32())
        else
            0;
        var chunker_index: u16 = 0;
        var section_depth: u16 = 0;
        var heading_line: u32 = 0;
        var source_doc_index: u32 = hybrid.no_source_doc;
        var section_path_length: usize = 0;
        if (header.format_version >= 4) {
            chunker_index = try cursor.readU16();
            section_depth = try cursor.readU16();
            heading_line = try cursor.readU32();
            source_doc_index = try cursor.readU32();
            section_path_length = try castU64ToUsize(try cursor.readU32());
        }
        if (vector_length != 0 and vector_length != header.vector_dimensions) return error.InvalidVectorDimensions;

        const id = try cursor.take(id_length);
        const path = try cursor.take(path_length);
        const text = try cursor.take(text_length);
        const required_labels = try cursor.take(required_labels_length);
        validateDecodedCitation(path, start_line, end_line) catch return error.InvalidCitation;
        validateDecodedRequiredLabels(required_labels) catch return error.InvalidRequiredLabels;
        const vector_end = try decodeCheckedAdd(vector_offset, vector_length);
        if (vector_end > vector_output.len) return error.VectorCapacityTooSmall;
        for (vector_output[vector_offset..vector_end]) |*value| value.* = @bitCast(try cursor.readU32());
        const section_path = try cursor.take(section_path_length);
        validateSection(section_depth, heading_line, start_line, section_path) catch return error.InvalidSection;
        document.* = .{
            .id = id,
            .text = text,
            .vector = vector_output[vector_offset..vector_end],
            .path = path,
            .start_line = start_line,
            .end_line = end_line,
            .required_labels = required_labels,
            .chunker_index = chunker_index,
            .section_depth = section_depth,
            .heading_line = heading_line,
            .source_doc_index = source_doc_index,
            .section_path = section_path,
        };
        vector_offset = vector_end;
    }
    if (cursor.offset != encoded.len) return error.TrailingData;
    return document_output[0..header.document_count];
}

fn vectorDimensions(documents: []const hybrid.Document) EncodeError!usize {
    var dimensions: usize = 0;
    for (documents) |document| {
        if (document.vector.len == 0) continue;
        if (dimensions == 0) dimensions = document.vector.len;
        if (document.vector.len != dimensions) return error.VectorDimensionsInconsistent;
        if (dimensions > std.math.maxInt(u32)) return error.FieldTooLarge;
    }
    return dimensions;
}

fn validateFieldLength(length: usize) EncodeError!void {
    if (length > std.math.maxInt(u32)) return error.FieldTooLarge;
}

fn validateCitation(path: []const u8, start_line: u32, end_line: u32) EncodeError!void {
    if (path.len == 0) {
        if (start_line != 0 or end_line != 0) return error.InvalidCitation;
        return;
    }
    if (start_line == 0 or end_line < start_line) return error.InvalidCitation;
}

fn validateDecodedCitation(path: []const u8, start_line: u32, end_line: u32) DecodeError!void {
    if (path.len == 0) {
        if (start_line != 0 or end_line != 0) return error.InvalidCitation;
        return;
    }
    if (start_line == 0 or end_line < start_line) return error.InvalidCitation;
}

/// A section path has exactly `depth` U+001F-separated entries (none for
/// depth 0), and a heading line, when present, is at or above the chunk.
fn validateSection(depth: u16, heading_line: u32, start_line: u32, section_path: []const u8) error{InvalidSection}!void {
    if (depth == 0) {
        if (section_path.len != 0) return error.InvalidSection;
    } else if (std.mem.count(u8, section_path, "\x1f") + 1 != depth) return error.InvalidSection;
    if (heading_line != 0 and heading_line > start_line) return error.InvalidSection;
    if (depth != 0 and heading_line == 0) return error.InvalidSection;
}

fn validateRequiredLabels(encoded_labels: []const u8) EncodeError!void {
    validatePackedRequiredLabels(encoded_labels) catch return error.InvalidRequiredLabels;
}

fn validateDecodedRequiredLabels(encoded_labels: []const u8) DecodeError!void {
    validatePackedRequiredLabels(encoded_labels) catch return error.InvalidRequiredLabels;
}

fn validatePackedRequiredLabels(encoded_labels: []const u8) error{InvalidRequiredLabels}!void {
    if (encoded_labels.len == 0) return;
    var labels = std.mem.splitScalar(u8, encoded_labels, '\n');
    var previous: ?[]const u8 = null;
    while (labels.next()) |label| {
        if (label.len == 0 or std.mem.indexOfAny(u8, label, "\x00\r") != null) {
            return error.InvalidRequiredLabels;
        }
        if (previous) |value| {
            if (std.mem.order(u8, value, label) != .lt) return error.InvalidRequiredLabels;
        }
        previous = label;
    }
}

fn checkedAdd(left: usize, right: usize) EncodeError!usize {
    return std.math.add(usize, left, right) catch error.SizeOverflow;
}

fn checkedMultiply(left: usize, right: usize) EncodeError!usize {
    return std.math.mul(usize, left, right) catch error.SizeOverflow;
}

fn decodeCheckedAdd(left: usize, right: usize) DecodeError!usize {
    return std.math.add(usize, left, right) catch error.SizeOverflow;
}

fn castU64ToUsize(value: anytype) DecodeError!usize {
    return std.math.cast(usize, value) orelse error.SizeOverflow;
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

    fn take(cursor: *Cursor, length: usize) DecodeError![]const u8 {
        const end = try decodeCheckedAdd(cursor.offset, length);
        if (end > cursor.bytes.len) return error.Truncated;
        defer cursor.offset = end;
        return cursor.bytes[cursor.offset..end];
    }

    fn readU16(cursor: *Cursor) DecodeError!u16 {
        const bytes = try cursor.take(2);
        return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
    }

    fn readU32(cursor: *Cursor) DecodeError!u32 {
        const bytes = try cursor.take(4);
        var value: u32 = 0;
        inline for (0..4) |index| value |= @as(u32, bytes[index]) << @intCast(index * 8);
        return value;
    }

    fn readU64(cursor: *Cursor) DecodeError!u64 {
        const bytes = try cursor.take(8);
        var value: u64 = 0;
        inline for (0..8) |index| value |= @as(u64, bytes[index]) << @intCast(index * 8);
        return value;
    }
};

test "segment round trip preserves documents and vectors" {
    const documents = [_]hybrid.Document{
        .{ .id = "one", .text = "lexical text", .vector = &.{ 1, 0 }, .path = "guides/one.md", .start_line = 3, .end_line = 5, .required_labels = "group:search\ntenant:acme" },
        .{ .id = "two", .text = "semantic text", .vector = &.{ 0.25, 0.75 } },
        .{ .id = "three", .text = "text without an embedding" },
    };
    var encoded: [512]u8 = undefined;
    const bytes = try encode(&documents, &encoded);
    const header = try inspect(bytes);
    try std.testing.expectEqual(documents.len, header.document_count);
    try std.testing.expectEqual(@as(usize, 2), header.vector_dimensions);

    var decoded_storage: [documents.len]hybrid.Document = undefined;
    var vector_storage: [4]f32 = undefined;
    const decoded = try decode(bytes, &decoded_storage, &vector_storage);
    try std.testing.expectEqualStrings("one", decoded[0].id);
    try std.testing.expectEqualStrings("lexical text", decoded[0].text);
    try std.testing.expectEqualSlices(f32, &.{ 1, 0 }, decoded[0].vector);
    try std.testing.expectEqualStrings("guides/one.md", decoded[0].path);
    try std.testing.expectEqual(@as(u32, 3), decoded[0].start_line);
    try std.testing.expectEqual(@as(u32, 5), decoded[0].end_line);
    try std.testing.expectEqualStrings("group:search\ntenant:acme", decoded[0].required_labels);
    try std.testing.expectEqualSlices(f32, &.{ 0.25, 0.75 }, decoded[1].vector);
    try std.testing.expectEqual(@as(usize, 0), decoded[2].vector.len);
}

test "segment rejects noncanonical required labels" {
    const documents = [_]hybrid.Document{.{
        .id = "one",
        .text = "search evidence",
        .required_labels = "tenant:acme\ngroup:search",
    }};
    var encoded: [256]u8 = undefined;
    try std.testing.expectError(error.InvalidRequiredLabels, encode(&documents, &encoded));
}

test "segment checksum detects payload corruption" {
    const documents = [_]hybrid.Document{.{ .id = "one", .text = "search evidence" }};
    var encoded: [128]u8 = undefined;
    const bytes = try encode(&documents, &encoded);
    bytes[bytes.len - 1] ^= 0xff;
    try std.testing.expectError(error.ChecksumMismatch, inspect(bytes));
}

test "segment checksum detects metadata corruption" {
    const documents = [_]hybrid.Document{.{ .id = "one", .text = "search evidence" }};
    var encoded: [128]u8 = undefined;
    const bytes = try encode(&documents, &encoded);
    bytes[12] = 0; // First byte of document count in the header.
    try std.testing.expectError(error.ChecksumMismatch, inspect(bytes));
}

test "segment rejects inconsistent vector dimensions and small buffers" {
    const inconsistent = [_]hybrid.Document{
        .{ .id = "one", .text = "one", .vector = &.{ 1, 0 } },
        .{ .id = "two", .text = "two", .vector = &.{1} },
    };
    var output: [16]u8 = undefined;
    try std.testing.expectError(error.VectorDimensionsInconsistent, encode(&inconsistent, &output));

    const valid = [_]hybrid.Document{.{ .id = "one", .text = "one" }};
    try std.testing.expectError(error.BufferTooSmall, encode(&valid, &output));
}

test "segment decode validates output capacities" {
    const documents = [_]hybrid.Document{.{ .id = "one", .text = "one", .vector = &.{ 1, 0 } }};
    var encoded: [128]u8 = undefined;
    const bytes = try encode(&documents, &encoded);

    var no_documents: [0]hybrid.Document = .{};
    var vectors: [2]f32 = undefined;
    try std.testing.expectError(error.DocumentCapacityTooSmall, decode(bytes, &no_documents, &vectors));

    var decoded: [1]hybrid.Document = undefined;
    var no_vectors: [0]f32 = .{};
    try std.testing.expectError(error.VectorCapacityTooSmall, decode(bytes, &decoded, &no_vectors));
}

test "segment round trip preserves hybrid query results" {
    const documents = [_]hybrid.Document{
        .{ .id = "both", .text = "hybrid retrieval combines ranks", .vector = &.{ 0.8, 0.2 } },
        .{ .id = "lexical", .text = "hybrid hybrid exact", .vector = &.{ 0, 1 } },
        .{ .id = "semantic", .text = "meaning based result", .vector = &.{ 1, 0 } },
    };
    var before_workspace: [documents.len]hybrid.Result = undefined;
    const before = try hybrid.search("hybrid", &.{ 1, 0 }, &documents, &before_workspace, .{});

    var encoded: [512]u8 = undefined;
    const bytes = try encode(&documents, &encoded);
    var decoded_storage: [documents.len]hybrid.Document = undefined;
    var vector_storage: [documents.len * 2]f32 = undefined;
    const decoded = try decode(bytes, &decoded_storage, &vector_storage);
    var after_workspace: [documents.len]hybrid.Result = undefined;
    const after = try hybrid.search("hybrid", &.{ 1, 0 }, decoded, &after_workspace, .{});

    try std.testing.expectEqual(before.len, after.len);
    for (before, after) |before_result, after_result| {
        try std.testing.expectEqualStrings(before_result.document_id, after_result.document_id);
        try std.testing.expectEqual(before_result.lexical_rank, after_result.lexical_rank);
        try std.testing.expectEqual(before_result.semantic_rank, after_result.semantic_rank);
        try std.testing.expectApproxEqAbs(before_result.fused_score, after_result.fused_score, 0.000001);
    }
}

test "segment rejects inconsistent citation metadata" {
    const missing_lines = [_]hybrid.Document{.{ .id = "one", .text = "one", .path = "one.md" }};
    var encoded: [128]u8 = undefined;
    try std.testing.expectError(error.InvalidCitation, encode(&missing_lines, &encoded));

    const missing_path = [_]hybrid.Document{.{ .id = "one", .text = "one", .start_line = 1, .end_line = 1 }};
    try std.testing.expectError(error.InvalidCitation, encode(&missing_path, &encoded));
}

test "segment v2 reader remains compatible with v1 records" {
    const legacy_document = hybrid.Document{ .id = "legacy", .text = "legacy stored text", .vector = &.{ 0.25, 0.75 } };
    var encoded_storage: [256]u8 = undefined;
    const encoded = try encodeV1ForTest(legacy_document, &encoded_storage);
    const header = try inspect(encoded);
    try std.testing.expectEqual(@as(u16, 1), header.format_version);

    var decoded_storage: [1]hybrid.Document = undefined;
    var vector_storage: [2]f32 = undefined;
    const decoded = try decode(encoded, &decoded_storage, &vector_storage);
    try std.testing.expectEqualStrings("legacy", decoded[0].id);
    try std.testing.expectEqualStrings("legacy stored text", decoded[0].text);
    try std.testing.expectEqual(@as(usize, 0), decoded[0].path.len);
    try std.testing.expectEqual(@as(u32, 0), decoded[0].start_line);
    try std.testing.expectEqualSlices(f32, &.{ 0.25, 0.75 }, decoded[0].vector);
}

fn encodeV1ForTest(document: hybrid.Document, output: []u8) EncodeError![]u8 {
    const required = header_length + 12 + document.id.len + document.text.len + document.vector.len * @sizeOf(f32);
    if (output.len < required) return error.BufferTooSmall;
    @memcpy(output[0..magic.len], magic);
    var header_offset: usize = magic.len;
    writeU16(output, &header_offset, 1);
    writeU16(output, &header_offset, 0);
    writeU32(output, &header_offset, 1);
    writeU32(output, &header_offset, @intCast(document.vector.len));
    writeU64(output, &header_offset, @intCast(required - header_length));
    const checksum_offset = header_offset;
    writeU64(output, &header_offset, 0);

    var payload_offset = header_length;
    writeU32(output, &payload_offset, @intCast(document.id.len));
    writeU32(output, &payload_offset, @intCast(document.text.len));
    writeU32(output, &payload_offset, @intCast(document.vector.len));
    @memcpy(output[payload_offset .. payload_offset + document.id.len], document.id);
    payload_offset += document.id.len;
    @memcpy(output[payload_offset .. payload_offset + document.text.len], document.text);
    payload_offset += document.text.len;
    for (document.vector) |value| writeU32(output, &payload_offset, @bitCast(value));

    var checksum_write_offset = checksum_offset;
    writeU64(output, &checksum_write_offset, checksum.compute(.fnv1a64, output[0..checksum_offset], output[header_length..required]));
    return output[0..required];
}

test "segment v4 round trip keeps section, chunker and source fields" {
    const documents = [_]hybrid.Document{
        .{ .id = "md", .text = "beta", .path = "week.md", .start_line = 8, .end_line = 9, .chunker_index = 1, .section_depth = 2, .heading_line = 7, .source_doc_index = 0, .section_path = "Week 7\x1fDates" },
        .{ .id = "txt", .text = "plain", .path = "a.txt", .start_line = 1, .end_line = 1, .source_doc_index = 1, .required_labels = "group:a" },
        .{ .id = "none", .text = "no source", .path = "b.txt", .start_line = 2, .end_line = 3 },
    };
    var encoded_storage: [1024]u8 = undefined;
    const encoded = try encodeV4(&documents, &encoded_storage);
    try std.testing.expectEqual(try encodedLengthV4(&documents), encoded.len);
    try std.testing.expectEqual(@as(u16, 4), (try inspect(encoded)).format_version);
    var decoded_storage: [3]hybrid.Document = undefined;
    var vectors: [0]f32 = .{};
    const decoded = try decode(encoded, &decoded_storage, &vectors);
    try std.testing.expectEqual(@as(u16, 1), decoded[0].chunker_index);
    try std.testing.expectEqual(@as(u16, 2), decoded[0].section_depth);
    try std.testing.expectEqual(@as(u32, 7), decoded[0].heading_line);
    try std.testing.expectEqual(@as(u32, 0), decoded[0].source_doc_index);
    try std.testing.expectEqualStrings("Week 7\x1fDates", decoded[0].section_path);
    try std.testing.expectEqualStrings("beta", decoded[0].text);
    try std.testing.expectEqual(@as(u32, 1), decoded[1].source_doc_index);
    try std.testing.expectEqualStrings("group:a", decoded[1].required_labels);
    try std.testing.expectEqual(hybrid.no_source_doc, decoded[2].source_doc_index);
    try std.testing.expectEqual(@as(usize, 0), decoded[2].section_path.len);
}

test "segment v3 writer is unchanged and refuses v4 fields" {
    const plain = [_]hybrid.Document{.{ .id = "one", .text = "lexical text", .path = "a.md", .start_line = 1, .end_line = 2 }};
    var storage: [256]u8 = undefined;
    const encoded = try encode(&plain, &storage);
    try std.testing.expectEqual(@as(u16, 3), (try inspect(encoded)).format_version);
    try std.testing.expectEqual(header_length + 28 + 3 + 4 + 12, encoded.len);
    var decoded_storage: [1]hybrid.Document = undefined;
    var vectors: [0]f32 = .{};
    const decoded = try decode(encoded, &decoded_storage, &vectors);
    try std.testing.expectEqual(hybrid.no_source_doc, decoded[0].source_doc_index);
    try std.testing.expectEqual(@as(u16, 0), decoded[0].section_depth);

    const sectioned = [_]hybrid.Document{.{ .id = "one", .text = "t", .path = "a.md", .start_line = 2, .end_line = 2, .section_depth = 1, .heading_line = 1, .section_path = "A" }};
    try std.testing.expectError(error.RequiresVersion4, encode(&sectioned, &storage));
}

test "segment v4 rejects inconsistent section metadata" {
    var storage: [256]u8 = undefined;
    const wrong_depth = [_]hybrid.Document{.{ .id = "x", .text = "t", .path = "a.md", .start_line = 3, .end_line = 3, .section_depth = 1, .heading_line = 1, .section_path = "A\x1fB" }};
    try std.testing.expectError(error.InvalidSection, encodeV4(&wrong_depth, &storage));
    const heading_below = [_]hybrid.Document{.{ .id = "x", .text = "t", .path = "a.md", .start_line = 3, .end_line = 3, .section_depth = 1, .heading_line = 4, .section_path = "A" }};
    try std.testing.expectError(error.InvalidSection, encodeV4(&heading_below, &storage));
    const path_without_depth = [_]hybrid.Document{.{ .id = "x", .text = "t", .path = "a.md", .start_line = 3, .end_line = 3, .section_path = "A" }};
    try std.testing.expectError(error.InvalidSection, encodeV4(&path_without_depth, &storage));
}

test "segment v4 checksum covers the new fields" {
    const documents = [_]hybrid.Document{.{ .id = "md", .text = "beta", .path = "w.md", .start_line = 2, .end_line = 2, .chunker_index = 1, .section_depth = 1, .heading_line = 1, .source_doc_index = 0, .section_path = "W" }};
    var storage: [256]u8 = undefined;
    const encoded = try encodeV4(&documents, &storage);
    // Byte 28 of the record is the low byte of chunker_index.
    encoded[header_length + 28] ^= 0x01;
    try std.testing.expectError(error.ChecksumMismatch, inspect(encoded));
}
