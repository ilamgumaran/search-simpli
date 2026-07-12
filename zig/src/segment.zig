const hybrid = @import("hybrid.zig");
const std = @import("std");

pub const magic = "HYBSEG01";
pub const version: u16 = 3;
pub const minimum_supported_version: u16 = 1;
pub const header_length: usize = 36;

pub const EncodeError = error{
    BufferTooSmall,
    DocumentCountOverflow,
    FieldTooLarge,
    SizeOverflow,
    VectorDimensionsInconsistent,
    InvalidCitation,
    InvalidRequiredLabels,
};

pub const DecodeError = error{
    BadMagic,
    UnsupportedVersion,
    Truncated,
    ChecksumMismatch,
    TrailingData,
    DocumentCapacityTooSmall,
    VectorCapacityTooSmall,
    InvalidVectorDimensions,
    InvalidCitation,
    InvalidRequiredLabels,
    SizeOverflow,
};

pub const Header = struct {
    format_version: u16,
    document_count: usize,
    vector_dimensions: usize,
    payload_length: usize,
    checksum: u64,
};

/// Return the exact number of bytes required by encode.
pub fn encodedLength(documents: []const hybrid.Document) EncodeError!usize {
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
        length = try checkedAdd(length, 28);
        length = try checkedAdd(length, document.id.len);
        length = try checkedAdd(length, document.path.len);
        length = try checkedAdd(length, document.text.len);
        length = try checkedAdd(length, document.required_labels.len);
        length = try checkedAdd(length, try checkedMultiply(document.vector.len, @sizeOf(f32)));
    }
    return length;
}

/// Encode one immutable segment into caller-owned memory.
pub fn encode(documents: []const hybrid.Document, output: []u8) EncodeError![]u8 {
    const required = try encodedLength(documents);
    if (output.len < required) return error.BufferTooSmall;
    const dimensions = try vectorDimensions(documents);

    @memcpy(output[0..magic.len], magic);
    var header_offset: usize = magic.len;
    writeU16(output, &header_offset, version);
    writeU16(output, &header_offset, 0); // Reserved flags.
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
        @memcpy(output[payload_offset .. payload_offset + document.id.len], document.id);
        payload_offset += document.id.len;
        @memcpy(output[payload_offset .. payload_offset + document.path.len], document.path);
        payload_offset += document.path.len;
        @memcpy(output[payload_offset .. payload_offset + document.text.len], document.text);
        payload_offset += document.text.len;
        @memcpy(output[payload_offset .. payload_offset + document.required_labels.len], document.required_labels);
        payload_offset += document.required_labels.len;
        for (document.vector) |value| writeU32(output, &payload_offset, @bitCast(value));
    }
    std.debug.assert(payload_offset == required);

    var checksum_write_offset = checksum_offset;
    writeU64(output, &checksum_write_offset, segmentChecksum(output[0..checksum_offset], output[header_length..required]));
    return output[0..required];
}

/// Read and validate only the segment header and payload checksum.
pub fn inspect(encoded: []const u8) DecodeError!Header {
    var cursor = Cursor{ .bytes = encoded };
    const actual_magic = try cursor.take(magic.len);
    if (!std.mem.eql(u8, actual_magic, magic)) return error.BadMagic;
    const actual_version = try cursor.readU16();
    if (actual_version < minimum_supported_version or actual_version > version) return error.UnsupportedVersion;
    _ = try cursor.readU16(); // Reserved flags.
    const document_count: usize = try castU64ToUsize(try cursor.readU32());
    const dimensions: usize = try castU64ToUsize(try cursor.readU32());
    const payload_length: usize = try castU64ToUsize(try cursor.readU64());
    const expected_checksum = try cursor.readU64();
    std.debug.assert(cursor.offset == header_length);

    const expected_total = try decodeCheckedAdd(header_length, payload_length);
    if (encoded.len < expected_total) return error.Truncated;
    if (encoded.len > expected_total) return error.TrailingData;
    const actual_checksum = segmentChecksum(encoded[0 .. header_length - @sizeOf(u64)], encoded[header_length..]);
    if (actual_checksum != expected_checksum) return error.ChecksumMismatch;
    return .{
        .format_version = actual_version,
        .document_count = document_count,
        .vector_dimensions = dimensions,
        .payload_length = payload_length,
        .checksum = expected_checksum,
    };
}

/// Decode zero-copy ids/text and copied, aligned f32 vectors into caller-owned
/// workspaces. The returned document slices borrow both encoded and vectors.
pub fn decode(
    encoded: []const u8,
    document_output: []hybrid.Document,
    vector_output: []f32,
) DecodeError![]hybrid.Document {
    const header = try inspect(encoded);
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
        document.* = .{
            .id = id,
            .text = text,
            .vector = vector_output[vector_offset..vector_end],
            .path = path,
            .start_line = start_line,
            .end_line = end_line,
            .required_labels = required_labels,
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

/// FNV-1a is used as an accidental-corruption checksum, not a cryptographic
/// authenticity mechanism. A future manifest may add a cryptographic digest.
fn segmentChecksum(header_without_checksum: []const u8, payload: []const u8) u64 {
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
    writeU64(output, &checksum_write_offset, segmentChecksum(output[0..checksum_offset], output[header_length..required]));
    return output[0..required];
}
