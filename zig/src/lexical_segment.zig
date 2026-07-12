const postings = @import("postings.zig");
const std = @import("std");

pub const magic = "HYBLEX01";
pub const version: u16 = 1;
pub const header_length: usize = 64;
const term_record_length: usize = 24;
const posting_record_length: usize = 8;

pub const EncodeError = error{
    BufferTooSmall,
    CountOverflow,
    FieldTooLarge,
    SizeOverflow,
    InvalidAverageDocumentLength,
    InvalidTerm,
    DuplicateTerm,
    InvalidPostingRange,
    DocumentFrequencyMismatch,
    InvalidPosting,
};

pub const DecodeError = error{
    BadMagic,
    UnsupportedVersion,
    UnsupportedFlags,
    Truncated,
    ChecksumMismatch,
    TrailingData,
    InvalidSectionLength,
    InvalidAverageDocumentLength,
    TermCapacityTooSmall,
    PostingCapacityTooSmall,
    DocumentLengthCapacityTooSmall,
    InvalidTerm,
    DuplicateTerm,
    InvalidPostingRange,
    DocumentFrequencyMismatch,
    InvalidPosting,
    SizeOverflow,
};

pub const Header = struct {
    document_count: usize,
    term_count: usize,
    posting_count: usize,
    average_document_length: f32,
    document_lengths_bytes: usize,
    dictionary_bytes: usize,
    postings_bytes: usize,
    checksum: u64,
};

pub fn encodedLength(index: postings.Index) EncodeError!usize {
    try validateIndex(index);
    var dictionary_bytes: usize = 0;
    for (index.terms) |entry| {
        dictionary_bytes = try checkedAdd(dictionary_bytes, term_record_length);
        dictionary_bytes = try checkedAdd(dictionary_bytes, entry.term.len);
    }
    var length = header_length;
    length = try checkedAdd(length, try checkedMultiply(index.document_lengths.len, @sizeOf(u32)));
    length = try checkedAdd(length, dictionary_bytes);
    length = try checkedAdd(length, try checkedMultiply(index.postings.len, posting_record_length));
    return length;
}

pub fn encode(index: postings.Index, output: []u8) EncodeError![]u8 {
    const required = try encodedLength(index);
    if (output.len < required) return error.BufferTooSmall;

    var dictionary_bytes: usize = 0;
    for (index.terms) |entry| {
        dictionary_bytes = try checkedAdd(dictionary_bytes, term_record_length + entry.term.len);
    }
    const document_lengths_bytes = try checkedMultiply(index.document_lengths.len, @sizeOf(u32));
    const postings_bytes = try checkedMultiply(index.postings.len, posting_record_length);

    @memcpy(output[0..magic.len], magic);
    var header_offset: usize = magic.len;
    writeU16(output, &header_offset, version);
    writeU16(output, &header_offset, 0);
    writeU32(output, &header_offset, @intCast(index.document_lengths.len));
    writeU32(output, &header_offset, @intCast(index.terms.len));
    writeU64(output, &header_offset, @intCast(index.postings.len));
    writeU32(output, &header_offset, @bitCast(index.average_document_length));
    writeU64(output, &header_offset, @intCast(document_lengths_bytes));
    writeU64(output, &header_offset, @intCast(dictionary_bytes));
    writeU64(output, &header_offset, @intCast(postings_bytes));
    const checksum_offset = header_offset;
    writeU64(output, &header_offset, 0);
    std.debug.assert(header_offset == header_length);

    var payload_offset = header_length;
    for (index.document_lengths) |document_length| writeU32(output, &payload_offset, document_length);
    for (index.terms) |entry| {
        writeU32(output, &payload_offset, @intCast(entry.term.len));
        writeU32(output, &payload_offset, entry.document_frequency);
        writeU64(output, &payload_offset, @intCast(entry.postings_start));
        writeU64(output, &payload_offset, @intCast(entry.postings_length));
        @memcpy(output[payload_offset .. payload_offset + entry.term.len], entry.term);
        payload_offset += entry.term.len;
    }
    for (index.postings) |posting| {
        writeU32(output, &payload_offset, posting.document_index);
        writeU32(output, &payload_offset, posting.term_frequency);
    }
    std.debug.assert(payload_offset == required);

    var checksum_write_offset = checksum_offset;
    writeU64(output, &checksum_write_offset, sectionChecksum(output[0..checksum_offset], output[header_length..required]));
    return output[0..required];
}

pub fn inspect(encoded: []const u8) DecodeError!Header {
    var cursor = Cursor{ .bytes = encoded };
    if (!std.mem.eql(u8, try cursor.take(magic.len), magic)) return error.BadMagic;
    if (try cursor.readU16() != version) return error.UnsupportedVersion;
    if (try cursor.readU16() != 0) return error.UnsupportedFlags;
    const document_count = try castToUsize(try cursor.readU32());
    const term_count = try castToUsize(try cursor.readU32());
    const posting_count = try castToUsize(try cursor.readU64());
    const average_document_length: f32 = @bitCast(try cursor.readU32());
    if (!std.math.isFinite(average_document_length) or average_document_length < 0) {
        return error.InvalidAverageDocumentLength;
    }
    const document_lengths_bytes = try castToUsize(try cursor.readU64());
    const dictionary_bytes = try castToUsize(try cursor.readU64());
    const postings_bytes = try castToUsize(try cursor.readU64());
    const expected_checksum = try cursor.readU64();
    std.debug.assert(cursor.offset == header_length);

    var expected_total = try decodeCheckedAdd(header_length, document_lengths_bytes);
    expected_total = try decodeCheckedAdd(expected_total, dictionary_bytes);
    expected_total = try decodeCheckedAdd(expected_total, postings_bytes);
    if (encoded.len < expected_total) return error.Truncated;
    if (encoded.len > expected_total) return error.TrailingData;
    const actual_checksum = sectionChecksum(encoded[0 .. header_length - @sizeOf(u64)], encoded[header_length..]);
    if (actual_checksum != expected_checksum) return error.ChecksumMismatch;
    const expected_document_lengths_bytes = try decodeCheckedMultiply(document_count, @sizeOf(u32));
    const expected_postings_bytes = try decodeCheckedMultiply(posting_count, posting_record_length);
    if (document_lengths_bytes != expected_document_lengths_bytes or postings_bytes != expected_postings_bytes) {
        return error.InvalidSectionLength;
    }
    return .{
        .document_count = document_count,
        .term_count = term_count,
        .posting_count = posting_count,
        .average_document_length = average_document_length,
        .document_lengths_bytes = document_lengths_bytes,
        .dictionary_bytes = dictionary_bytes,
        .postings_bytes = postings_bytes,
        .checksum = expected_checksum,
    };
}

pub fn decode(
    encoded: []const u8,
    term_output: []postings.TermEntry,
    posting_output: []postings.Posting,
    document_length_output: []u32,
) DecodeError!postings.Index {
    const header = try inspect(encoded);
    if (term_output.len < header.term_count) return error.TermCapacityTooSmall;
    if (posting_output.len < header.posting_count) return error.PostingCapacityTooSmall;
    if (document_length_output.len < header.document_count) return error.DocumentLengthCapacityTooSmall;

    var payload = Cursor{ .bytes = encoded, .offset = header_length };
    const document_length_bytes = try payload.take(header.document_lengths_bytes);
    const dictionary_bytes = try payload.take(header.dictionary_bytes);
    const posting_bytes = try payload.take(header.postings_bytes);
    if (payload.offset != encoded.len) return error.TrailingData;

    var lengths_cursor = Cursor{ .bytes = document_length_bytes };
    for (document_length_output[0..header.document_count]) |*length| length.* = try lengths_cursor.readU32();
    if (lengths_cursor.offset != document_length_bytes.len) return error.InvalidSectionLength;

    var dictionary_cursor = Cursor{ .bytes = dictionary_bytes };
    for (term_output[0..header.term_count], 0..) |*entry, term_index| {
        const term_length = try castToUsize(try dictionary_cursor.readU32());
        const document_frequency = try dictionary_cursor.readU32();
        const postings_start = try castToUsize(try dictionary_cursor.readU64());
        const postings_length = try castToUsize(try dictionary_cursor.readU64());
        const term = try dictionary_cursor.take(term_length);
        if (term.len == 0) return error.InvalidTerm;
        if (postings.findTerm(term_output[0..term_index], term) != null) return error.DuplicateTerm;
        const postings_end = try decodeCheckedAdd(postings_start, postings_length);
        if (postings_end > header.posting_count) return error.InvalidPostingRange;
        if (document_frequency != postings_length) return error.DocumentFrequencyMismatch;
        entry.* = .{
            .term = term,
            .document_frequency = document_frequency,
            .postings_start = postings_start,
            .postings_length = postings_length,
        };
    }
    if (dictionary_cursor.offset != dictionary_bytes.len) return error.InvalidSectionLength;

    var posting_cursor = Cursor{ .bytes = posting_bytes };
    for (posting_output[0..header.posting_count]) |*posting| {
        posting.* = .{
            .document_index = try posting_cursor.readU32(),
            .term_frequency = try posting_cursor.readU32(),
        };
        if (posting.document_index >= header.document_count or posting.term_frequency == 0) return error.InvalidPosting;
    }
    if (posting_cursor.offset != posting_bytes.len) return error.InvalidSectionLength;
    try validatePostingOrder(term_output[0..header.term_count], posting_output[0..header.posting_count]);

    return .{
        .terms = term_output[0..header.term_count],
        .postings = posting_output[0..header.posting_count],
        .document_lengths = document_length_output[0..header.document_count],
        .average_document_length = header.average_document_length,
    };
}

fn validateIndex(index: postings.Index) EncodeError!void {
    if (index.document_lengths.len > std.math.maxInt(u32) or index.terms.len > std.math.maxInt(u32)) {
        return error.CountOverflow;
    }
    if (!std.math.isFinite(index.average_document_length) or index.average_document_length < 0) {
        return error.InvalidAverageDocumentLength;
    }
    for (index.terms, 0..) |entry, term_index| {
        if (entry.term.len == 0 or entry.term.len > std.math.maxInt(u32)) return error.InvalidTerm;
        if (postings.findTerm(index.terms[0..term_index], entry.term) != null) return error.DuplicateTerm;
        const postings_end = std.math.add(usize, entry.postings_start, entry.postings_length) catch
            return error.InvalidPostingRange;
        if (postings_end > index.postings.len) return error.InvalidPostingRange;
        if (entry.document_frequency != entry.postings_length) return error.DocumentFrequencyMismatch;
    }
    for (index.postings) |posting| {
        if (posting.document_index >= index.document_lengths.len or posting.term_frequency == 0) {
            return error.InvalidPosting;
        }
    }
    validatePostingOrder(index.terms, index.postings) catch return error.InvalidPosting;
}

fn validatePostingOrder(terms: []const postings.TermEntry, values: []const postings.Posting) DecodeError!void {
    for (terms) |entry| {
        const range = values[entry.postings_start .. entry.postings_start + entry.postings_length];
        var previous: ?u32 = null;
        for (range) |posting| {
            if (previous != null and posting.document_index <= previous.?) return error.InvalidPosting;
            previous = posting.document_index;
        }
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

fn decodeCheckedMultiply(left: usize, right: usize) DecodeError!usize {
    return std.math.mul(usize, left, right) catch error.SizeOverflow;
}

fn castToUsize(value: anytype) DecodeError!usize {
    return std.math.cast(usize, value) orelse error.SizeOverflow;
}

fn sectionChecksum(header_without_checksum: []const u8, payload: []const u8) u64 {
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

test "lexical segment round trip preserves BM25 scores" {
    const hybrid = @import("hybrid.zig");
    const documents = [_]hybrid.Document{
        .{ .id = "engine", .text = "postings postings store identifiers for lexical retrieval" },
        .{ .id = "orchard", .text = "apples and pears grow here" },
        .{ .id = "other", .text = "retrieval finds useful evidence" },
    };
    var terms: [24]postings.TermEntry = undefined;
    var posting_storage: [32]postings.Posting = undefined;
    var lengths: [documents.len]u32 = undefined;
    var fills: [24]usize = undefined;
    const source = try postings.build(&documents, &terms, &posting_storage, &lengths, &fills);
    var expected_scores_storage: [documents.len]f32 = undefined;
    const expected_scores = try postings.scoreQuery(source, "postings retrieval", &expected_scores_storage, .{});

    var encoded_storage: [2048]u8 = undefined;
    const encoded = try encode(source, &encoded_storage);
    const header = try inspect(encoded);
    try std.testing.expectEqual(source.terms.len, header.term_count);
    try std.testing.expectEqual(source.postings.len, header.posting_count);

    var decoded_terms: [24]postings.TermEntry = undefined;
    var decoded_postings: [32]postings.Posting = undefined;
    var decoded_lengths: [documents.len]u32 = undefined;
    const decoded = try decode(encoded, &decoded_terms, &decoded_postings, &decoded_lengths);
    var actual_scores_storage: [documents.len]f32 = undefined;
    const actual_scores = try postings.scoreQuery(decoded, "postings retrieval", &actual_scores_storage, .{});
    for (expected_scores, actual_scores) |expected, actual| {
        try std.testing.expectApproxEqAbs(expected, actual, 0.000001);
    }
}

test "persisted lexical index preserves hybrid ordering" {
    const hybrid = @import("hybrid.zig");
    const documents = [_]hybrid.Document{
        .{ .id = "both", .text = "hybrid retrieval combines ranks", .vector = &.{ 0.8, 0.2 } },
        .{ .id = "lexical", .text = "hybrid hybrid exact", .vector = &.{ 0, 1 } },
        .{ .id = "semantic", .text = "meaning based result", .vector = &.{ 1, 0 } },
    };
    var terms: [24]postings.TermEntry = undefined;
    var posting_storage: [32]postings.Posting = undefined;
    var lengths: [documents.len]u32 = undefined;
    var fills: [24]usize = undefined;
    const source = try postings.build(&documents, &terms, &posting_storage, &lengths, &fills);
    var source_score_storage: [documents.len]f32 = undefined;
    const source_scores = try postings.scoreQuery(source, "hybrid", &source_score_storage, .{});
    var expected_workspace: [documents.len]hybrid.Result = undefined;
    const expected = try hybrid.searchWithLexicalScores(&.{ 1, 0 }, &documents, source_scores, &expected_workspace, .{});

    var encoded_storage: [2048]u8 = undefined;
    const encoded = try encode(source, &encoded_storage);
    var decoded_terms: [24]postings.TermEntry = undefined;
    var decoded_postings: [32]postings.Posting = undefined;
    var decoded_lengths: [documents.len]u32 = undefined;
    const decoded = try decode(encoded, &decoded_terms, &decoded_postings, &decoded_lengths);
    var decoded_score_storage: [documents.len]f32 = undefined;
    const decoded_scores = try postings.scoreQuery(decoded, "hybrid", &decoded_score_storage, .{});
    var actual_workspace: [documents.len]hybrid.Result = undefined;
    const actual = try hybrid.searchWithLexicalScores(&.{ 1, 0 }, &documents, decoded_scores, &actual_workspace, .{});

    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_result, actual_result| {
        try std.testing.expectEqualStrings(expected_result.document_id, actual_result.document_id);
        try std.testing.expectEqual(expected_result.lexical_rank, actual_result.lexical_rank);
        try std.testing.expectEqual(expected_result.semantic_rank, actual_result.semantic_rank);
        try std.testing.expectApproxEqAbs(expected_result.fused_score, actual_result.fused_score, 0.000001);
    }
}

test "lexical segment checksum covers metadata and payload" {
    const empty_index = postings.Index{
        .terms = &.{},
        .postings = &.{},
        .document_lengths = &.{0},
        .average_document_length = 0,
    };
    var header_corruption_storage: [128]u8 = undefined;
    const header_corruption = try encode(empty_index, &header_corruption_storage);
    header_corruption[12] = 2;
    try std.testing.expectError(error.ChecksumMismatch, inspect(header_corruption));

    var payload_corruption_storage: [128]u8 = undefined;
    const payload_corruption = try encode(empty_index, &payload_corruption_storage);
    payload_corruption[payload_corruption.len - 1] ^= 0xff;
    try std.testing.expectError(error.ChecksumMismatch, inspect(payload_corruption));
}

test "lexical segment validates caller capacities" {
    const index = postings.Index{
        .terms = &.{.{ .term = "search", .document_frequency = 1, .postings_start = 0, .postings_length = 1 }},
        .postings = &.{.{ .document_index = 0, .term_frequency = 1 }},
        .document_lengths = &.{1},
        .average_document_length = 1,
    };
    var encoded_storage: [256]u8 = undefined;
    const encoded = try encode(index, &encoded_storage);

    var no_terms: [0]postings.TermEntry = .{};
    var posting_storage: [1]postings.Posting = undefined;
    var lengths: [1]u32 = undefined;
    try std.testing.expectError(error.TermCapacityTooSmall, decode(encoded, &no_terms, &posting_storage, &lengths));

    var term_storage: [1]postings.TermEntry = undefined;
    var no_postings: [0]postings.Posting = .{};
    try std.testing.expectError(error.PostingCapacityTooSmall, decode(encoded, &term_storage, &no_postings, &lengths));

    var no_lengths: [0]u32 = .{};
    try std.testing.expectError(error.DocumentLengthCapacityTooSmall, decode(encoded, &term_storage, &posting_storage, &no_lengths));
}

test "lexical segment rejects inconsistent index metadata" {
    const bad_frequency = postings.Index{
        .terms = &.{.{ .term = "search", .document_frequency = 2, .postings_start = 0, .postings_length = 1 }},
        .postings = &.{.{ .document_index = 0, .term_frequency = 1 }},
        .document_lengths = &.{1},
        .average_document_length = 1,
    };
    var encoded_storage: [256]u8 = undefined;
    try std.testing.expectError(error.DocumentFrequencyMismatch, encode(bad_frequency, &encoded_storage));

    const duplicate_posting = postings.Index{
        .terms = &.{.{ .term = "search", .document_frequency = 2, .postings_start = 0, .postings_length = 2 }},
        .postings = &.{
            .{ .document_index = 0, .term_frequency = 1 },
            .{ .document_index = 0, .term_frequency = 2 },
        },
        .document_lengths = &.{1},
        .average_document_length = 1,
    };
    try std.testing.expectError(error.InvalidPosting, encode(duplicate_posting, &encoded_storage));
}
