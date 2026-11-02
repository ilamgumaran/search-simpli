const checksum = @import("checksum.zig");
const postings = @import("postings.zig");
const std = @import("std");

pub const magic = "HYBLEX01";
pub const version: u16 = 1;
pub const header_length: usize = 64;
/// S3-T2 (`docs/lexical-segment-format-v2.md`): `HYBLEX02` adds sections 4
/// (token ordinals) and 5 (token offsets), sorts the dictionary by term
/// bytes and grows the header to 80 bytes (two section lengths before the
/// checksum). `encode` writes v2 exactly when the index carries positions.
pub const magic_v2 = "HYBLEX02";
pub const version_v2: u16 = 2;
pub const header_length_v2: usize = 80;
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
    /// v2: the dictionary is not strictly sorted by bytes, the term ranges are
    /// not contiguous in dictionary order, or sections 4/5 break a rule.
    UnsortedTerms,
    InvalidPositions,
    // S1-T3 (docs/tasks/S1-T3.md criterion 4): `validateIndex`'s duplicate-term
    // check now uses a hash set (page allocator, scoped to that one check)
    // instead of an O(terms^2) linear scan, so it can now fail with
    // OutOfMemory like any other allocating operation.
    OutOfMemory,
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
    UnsortedTerms,
    InvalidPositions,
    SizeOverflow,
    // S1-T3 (docs/tasks/S1-T3.md criterion 4): see EncodeError.OutOfMemory
    // above -- `decode`'s duplicate-term check was the same O(terms^2)
    // linear scan, on the hot path of every snapshot open, not just every
    // publish.
    OutOfMemory,
};

pub const Header = struct {
    version: u16 = version,
    document_count: usize,
    term_count: usize,
    posting_count: usize,
    average_document_length: f32,
    document_lengths_bytes: usize,
    dictionary_bytes: usize,
    postings_bytes: usize,
    positions_bytes: usize = 0,
    offsets_bytes: usize = 0,
    checksum: u64,
    /// S4-T1: header flags bit 0 (`checksum.flag_xxh3`).
    checksum_kind: checksum.Kind = .fnv1a64,

    pub fn hasPositions(header: Header) bool {
        return header.version == version_v2;
    }
};

pub fn encodedLength(index: postings.Index) EncodeError!usize {
    try validateIndex(index);
    var dictionary_bytes: usize = 0;
    for (index.terms) |entry| {
        dictionary_bytes = try checkedAdd(dictionary_bytes, term_record_length);
        dictionary_bytes = try checkedAdd(dictionary_bytes, entry.term.len);
    }
    var length = if (index.positions == null) header_length else header_length_v2;
    length = try checkedAdd(length, try checkedMultiply(index.document_lengths.len, @sizeOf(u32)));
    length = try checkedAdd(length, dictionary_bytes);
    length = try checkedAdd(length, try checkedMultiply(index.postings.len, posting_record_length));
    if (index.positions) |sections| {
        length = try checkedAdd(length, sections.positions.len);
        length = try checkedAdd(length, sections.offsets.len);
    }
    return length;
}

/// Write `index` as `HYBLEX01`, or as `HYBLEX02` when it carries positions
/// (its dictionary must then be sorted, its term ranges contiguous in
/// dictionary order and sections 4/5 valid: `validateIndex` checks).
pub fn encode(index: postings.Index, output: []u8) EncodeError![]u8 {
    const required = try encodedLength(index);
    if (output.len < required) return error.BufferTooSmall;
    const v2 = index.positions != null;
    const fixed_length = if (v2) header_length_v2 else header_length;

    var dictionary_bytes: usize = 0;
    for (index.terms) |entry| {
        dictionary_bytes = try checkedAdd(dictionary_bytes, term_record_length + entry.term.len);
    }
    const document_lengths_bytes = try checkedMultiply(index.document_lengths.len, @sizeOf(u32));
    const postings_bytes = try checkedMultiply(index.postings.len, posting_record_length);

    @memcpy(output[0..magic.len], if (v2) magic_v2 else magic);
    var header_offset: usize = magic.len;
    writeU16(output, &header_offset, if (v2) version_v2 else version);
    // Flags: bit 0 (S4-T1) = XXH3-64 checksum, set on `HYBLEX02` (the
    // folder writers); `HYBLEX01` (`import-json`) stays FNV-1a, flags zero.
    const kind: checksum.Kind = if (v2) .xxh3_64 else .fnv1a64;
    writeU16(output, &header_offset, checksum.flagsOf(kind));
    writeU32(output, &header_offset, @intCast(index.document_lengths.len));
    writeU32(output, &header_offset, @intCast(index.terms.len));
    writeU64(output, &header_offset, @intCast(index.postings.len));
    writeU32(output, &header_offset, @bitCast(index.average_document_length));
    writeU64(output, &header_offset, @intCast(document_lengths_bytes));
    writeU64(output, &header_offset, @intCast(dictionary_bytes));
    writeU64(output, &header_offset, @intCast(postings_bytes));
    if (index.positions) |sections| {
        writeU64(output, &header_offset, @intCast(sections.positions.len));
        writeU64(output, &header_offset, @intCast(sections.offsets.len));
    }
    const checksum_offset = header_offset;
    writeU64(output, &header_offset, 0);
    std.debug.assert(header_offset == fixed_length);

    var payload_offset = fixed_length;
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
    if (index.positions) |sections| {
        @memcpy(output[payload_offset .. payload_offset + sections.positions.len], sections.positions);
        payload_offset += sections.positions.len;
        @memcpy(output[payload_offset .. payload_offset + sections.offsets.len], sections.offsets);
        payload_offset += sections.offsets.len;
    }
    std.debug.assert(payload_offset == required);

    var checksum_write_offset = checksum_offset;
    writeU64(output, &checksum_write_offset, checksum.compute(kind, output[0..checksum_offset], output[fixed_length..required]));
    return output[0..required];
}

pub fn inspect(encoded: []const u8) DecodeError!Header {
    var cursor = Cursor{ .bytes = encoded };
    const found_magic = try cursor.take(magic.len);
    const v2 = std.mem.eql(u8, found_magic, magic_v2);
    if (!v2 and !std.mem.eql(u8, found_magic, magic)) return error.BadMagic;
    const found_version = try cursor.readU16();
    if (found_version != (if (v2) version_v2 else version)) return error.UnsupportedVersion;
    // Flags: zero, or (S4-T1, `HYBLEX02` only) bit 0 for XXH3-64.
    const flags = try cursor.readU16();
    if (flags & ~(if (v2) checksum.flag_xxh3 else 0) != 0) return error.UnsupportedFlags;
    const kind = checksum.kindOfFlags(flags);
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
    const positions_bytes = if (v2) try castToUsize(try cursor.readU64()) else 0;
    const offsets_bytes = if (v2) try castToUsize(try cursor.readU64()) else 0;
    const expected_checksum = try cursor.readU64();
    const fixed_length = if (v2) header_length_v2 else header_length;
    std.debug.assert(cursor.offset == fixed_length);

    var expected_total = try decodeCheckedAdd(fixed_length, document_lengths_bytes);
    expected_total = try decodeCheckedAdd(expected_total, dictionary_bytes);
    expected_total = try decodeCheckedAdd(expected_total, postings_bytes);
    expected_total = try decodeCheckedAdd(expected_total, positions_bytes);
    expected_total = try decodeCheckedAdd(expected_total, offsets_bytes);
    if (encoded.len < expected_total) return error.Truncated;
    if (encoded.len > expected_total) return error.TrailingData;
    const actual_checksum = checksum.compute(kind, encoded[0 .. fixed_length - @sizeOf(u64)], encoded[fixed_length..]);
    if (actual_checksum != expected_checksum) return error.ChecksumMismatch;
    const expected_document_lengths_bytes = try decodeCheckedMultiply(document_count, @sizeOf(u32));
    const expected_postings_bytes = try decodeCheckedMultiply(posting_count, posting_record_length);
    if (document_lengths_bytes != expected_document_lengths_bytes or postings_bytes != expected_postings_bytes) {
        return error.InvalidSectionLength;
    }
    return .{
        .version = if (v2) version_v2 else version,
        .document_count = document_count,
        .term_count = term_count,
        .posting_count = posting_count,
        .average_document_length = average_document_length,
        .document_lengths_bytes = document_lengths_bytes,
        .dictionary_bytes = dictionary_bytes,
        .postings_bytes = postings_bytes,
        .positions_bytes = positions_bytes,
        .offsets_bytes = offsets_bytes,
        .checksum = expected_checksum,
        .checksum_kind = kind,
    };
}

pub fn decode(
    encoded: []const u8,
    term_output: []postings.TermEntry,
    posting_output: []postings.Posting,
    document_length_output: []u32,
) DecodeError!postings.Index {
    return decodeWith(encoded, term_output, posting_output, document_length_output, .{});
}

pub const DecodeOptions = struct {
    /// S4-T1: walk every varint of sections 4 and 5 now. A lazy reader
    /// (`snapshot_open.openScoped`) passes false and calls
    /// `validatePositionSections` before the first use of positions or
    /// offsets (`scope.Folder.positionTables`); until then nothing may read
    /// them. The term-contiguity rule (cheap, needed by every reader) is
    /// always checked here.
    validate_positions: bool = true,
    /// S4-T1: the header `inspect` already returned for these bytes (its
    /// checksum computed then), so it is not computed a second time.
    inspected: ?Header = null,
};

pub fn decodeWith(
    encoded: []const u8,
    term_output: []postings.TermEntry,
    posting_output: []postings.Posting,
    document_length_output: []u32,
    options: DecodeOptions,
) DecodeError!postings.Index {
    const header = options.inspected orelse try inspect(encoded);
    if (term_output.len < header.term_count) return error.TermCapacityTooSmall;
    if (posting_output.len < header.posting_count) return error.PostingCapacityTooSmall;
    if (document_length_output.len < header.document_count) return error.DocumentLengthCapacityTooSmall;

    const v2 = header.hasPositions();
    var payload = Cursor{ .bytes = encoded, .offset = if (v2) header_length_v2 else header_length };
    const document_length_bytes = try payload.take(header.document_lengths_bytes);
    const dictionary_bytes = try payload.take(header.dictionary_bytes);
    const posting_bytes = try payload.take(header.postings_bytes);
    const positions_bytes = try payload.take(header.positions_bytes);
    const offsets_bytes = try payload.take(header.offsets_bytes);
    if (payload.offset != encoded.len) return error.TrailingData;

    var lengths_cursor = Cursor{ .bytes = document_length_bytes };
    for (document_length_output[0..header.document_count]) |*length| length.* = try lengths_cursor.readU32();
    if (lengths_cursor.offset != document_length_bytes.len) return error.InvalidSectionLength;

    var dictionary_cursor = Cursor{ .bytes = dictionary_bytes };
    // Same O(terms^2) -> O(terms) fix as `validateIndex` above: a
    // page-allocator hash set scoped to this one loop, not threaded through
    // `decode`'s own allocation-free signature.
    // v2 needs no hash set: a strictly sorted dictionary has no duplicates.
    var seen_terms = std.StringHashMap(void).init(std.heap.page_allocator);
    defer seen_terms.deinit();
    var previous_term: ?[]const u8 = null;
    for (term_output[0..header.term_count]) |*entry| {
        const term_length = try castToUsize(try dictionary_cursor.readU32());
        const document_frequency = try dictionary_cursor.readU32();
        const postings_start = try castToUsize(try dictionary_cursor.readU64());
        const postings_length = try castToUsize(try dictionary_cursor.readU64());
        const term = try dictionary_cursor.take(term_length);
        if (term.len == 0) return error.InvalidTerm;
        if (v2) {
            if (previous_term) |earlier| if (std.mem.order(u8, earlier, term) != .lt) return error.UnsortedTerms;
            previous_term = term;
        } else {
            const duplicate = seen_terms.getOrPut(term) catch return error.OutOfMemory;
            if (duplicate.found_existing) return error.DuplicateTerm;
        }
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

    const sections: ?postings.PositionSections = if (v2) .{ .positions = positions_bytes, .offsets = offsets_bytes } else null;
    if (sections) |present| {
        try validateTermRanges(term_output[0..header.term_count], posting_output[0..header.posting_count]);
        if (options.validate_positions) try validatePositions(
            term_output[0..header.term_count],
            posting_output[0..header.posting_count],
            document_length_output[0..header.document_count],
            present,
        );
    }
    return .{
        .terms = term_output[0..header.term_count],
        .postings = posting_output[0..header.posting_count],
        .document_lengths = document_length_output[0..header.document_count],
        .average_document_length = header.average_document_length,
        .positions = sections,
        .sorted_terms = v2,
    };
}

/// Term ranges contiguous in dictionary order (posting order is term-major,
/// so a term's ordinals are one run of section 4).
fn validateTermRanges(terms: []const postings.TermEntry, values: []const postings.Posting) DecodeError!void {
    var expected_start: usize = 0;
    for (terms) |entry| {
        if (entry.postings_start != expected_start) return error.UnsortedTerms;
        expected_start += entry.postings_length;
    }
    if (expected_start != values.len) return error.UnsortedTerms;
}

/// S4-T1: the deferred half of `decode` for an index decoded with
/// `validate_positions = false`: sections 4 and 5 against the decoded
/// postings and document lengths. A no-op without positions.
pub fn validatePositionSections(index: postings.Index) DecodeError!void {
    const sections = index.positions orelse return;
    return validatePositions(index.terms, index.postings, index.document_lengths, sections);
}

/// The v2 rules of sections 4 and 5 (`docs/lexical-segment-format-v2.md`):
/// term ranges contiguous in dictionary order (posting order is term-major,
/// so a term's ordinals are one run of section 4); per posting exactly
/// `term_frequency` well-formed varints whose ordinals strictly increase and
/// stay below the document's length; per document a token count equal to its
/// length and two varints per token, every length >= 1 and every end within
/// u32; no byte left over in either section. Allocation-free.
fn validatePositions(
    terms: []const postings.TermEntry,
    values: []const postings.Posting,
    document_lengths: []const u32,
    sections: postings.PositionSections,
) DecodeError!void {
    try validateTermRanges(terms, values);
    var at: usize = 0;
    for (values) |posting| {
        const length = document_lengths[posting.document_index];
        var ordinal: u64 = 0;
        for (0..posting.term_frequency) |k| {
            const value = postings.readVarint(sections.positions, &at) orelse return error.InvalidPositions;
            if (k == 0) {
                ordinal = value;
            } else {
                if (value == 0) return error.InvalidPositions;
                ordinal += value;
            }
            if (ordinal >= length) return error.InvalidPositions;
        }
    }
    if (at != sections.positions.len) return error.InvalidPositions;

    at = 0;
    for (document_lengths) |length| {
        if (sections.offsets.len - at < 4) return error.InvalidPositions;
        const count = std.mem.readInt(u32, sections.offsets[at..][0..4], .little);
        at += 4;
        if (count != length) return error.InvalidPositions;
        var start: u64 = 0;
        for (0..count) |_| {
            start += postings.readVarint(sections.offsets, &at) orelse return error.InvalidPositions;
            const token_length = postings.readVarint(sections.offsets, &at) orelse return error.InvalidPositions;
            if (token_length == 0 or start + token_length > std.math.maxInt(u32)) return error.InvalidPositions;
        }
    }
    if (at != sections.offsets.len) return error.InvalidPositions;
}

fn validateIndex(index: postings.Index) EncodeError!void {
    if (index.document_lengths.len > std.math.maxInt(u32) or index.terms.len > std.math.maxInt(u32)) {
        return error.CountOverflow;
    }
    if (!std.math.isFinite(index.average_document_length) or index.average_document_length < 0) {
        return error.InvalidAverageDocumentLength;
    }
    // Duplicate-term detection used to be an O(terms^2) linear scan
    // (`postings.findTerm` re-scanning every term seen so far for every
    // term) -- fine for a handful of terms, but the dominant cost of every
    // publish once a realistic-vocabulary corpus is indexed (S1-T3,
    // docs/tasks/S1-T3.md criterion 4: the same "superlinear in vocabulary"
    // class of bug the round-A verdict found in `lexical_build.build`,
    // just one layer further down the publish path). A hash set scoped to
    // this one check -- this function's own signature stays
    // allocation-free, matching `encode`/`encodedLength`'s existing
    // fixed-buffer/no-allocator contract used throughout the test suite --
    // makes it linear instead.
    {
        var seen = std.StringHashMap(void).init(std.heap.page_allocator);
        defer seen.deinit();
        for (index.terms) |entry| {
            if (entry.term.len == 0 or entry.term.len > std.math.maxInt(u32)) return error.InvalidTerm;
            const duplicate = seen.getOrPut(entry.term) catch return error.OutOfMemory;
            if (duplicate.found_existing) return error.DuplicateTerm;
        }
    }
    for (index.terms) |entry| {
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
    if (index.positions) |sections| {
        for (index.terms[0..index.terms.len -| 1], 1..) |entry, next| {
            if (std.mem.order(u8, entry.term, index.terms[next].term) != .lt) return error.UnsortedTerms;
        }
        validatePositions(index.terms, index.postings, index.document_lengths, sections) catch |err| return switch (err) {
            error.UnsortedTerms => error.UnsortedTerms,
            else => error.InvalidPositions,
        };
    }
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

fn positionalFixture(arena: std.mem.Allocator) !postings.Index {
    const analyzer_v2 = @import("analyzer_v2.zig");
    const hybrid = @import("hybrid.zig");
    const lexical_build = @import("lexical_build.zig");
    const documents = [_]hybrid.Document{
        .{ .id = "a", .text = "count me in, count me in" },
        .{ .id = "b", .text = "the the dough rests" },
        .{ .id = "c", .text = "பள்ளி விடுமுறை" },
    };
    var lists: [documents.len][]const @import("analysis.zig").PositionedToken = undefined;
    for (documents, 0..) |document, i| lists[i] = try analyzer_v2.tokenizePositioned(arena, document.text);
    return lexical_build.buildPositional(arena, &documents, &lists);
}

fn rechecksum(encoded: []u8) void {
    const v2 = std.mem.eql(u8, encoded[0..8], magic_v2);
    const fixed = if (v2) header_length_v2 else header_length;
    const kind: checksum.Kind = if (v2) .xxh3_64 else .fnv1a64;
    var offset = fixed - 8;
    writeU64(encoded, &offset, checksum.compute(kind, encoded[0 .. fixed - 8], encoded[fixed..]));
}

test "HYBLEX02 round trip keeps positions, offsets and sorted terms (S3-T2)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const index = try positionalFixture(arena_state.allocator());
    var storage: [4096]u8 = undefined;
    const encoded = try encode(index, &storage);
    const header = try inspect(encoded);
    try std.testing.expect(header.hasPositions());
    try std.testing.expectEqual(index.positions.?.positions.len, header.positions_bytes);
    try std.testing.expectEqual(index.positions.?.offsets.len, header.offsets_bytes);
    try std.testing.expectEqual(header_length_v2 + 3 * 4 + header.dictionary_bytes + header.postings_bytes + header.positions_bytes + header.offsets_bytes, encoded.len);

    var terms: [16]postings.TermEntry = undefined;
    var values: [16]postings.Posting = undefined;
    var lengths: [3]u32 = undefined;
    const decoded = try decode(encoded, &terms, &values, &lengths);
    try std.testing.expect(decoded.sorted_terms);
    try std.testing.expectEqualSlices(u8, index.positions.?.positions, decoded.positions.?.positions);
    try std.testing.expectEqualSlices(u8, index.positions.?.offsets, decoded.positions.?.offsets);
    // Zero-copy term slices, as in v1.
    const first = decoded.terms[0].term;
    try std.testing.expect(@intFromPtr(first.ptr) >= @intFromPtr(encoded.ptr) and @intFromPtr(first.ptr) < @intFromPtr(encoded.ptr) + encoded.len);

    const tables = try postings.buildPositionTables(std.testing.allocator, decoded);
    defer std.testing.allocator.free(tables.term_starts);
    defer std.testing.allocator.free(tables.document_starts);
    var spans: [8]postings.TokenSpan = undefined;
    const doc_spans = postings.readTokenSpans(decoded, tables, 0, &spans);
    try std.testing.expectEqual(@as(usize, 6), doc_spans.len);
    try std.testing.expectEqual(postings.TokenSpan{ .start = 13, .length = 5 }, doc_spans[3]);
    const tamil = postings.readTokenSpans(decoded, tables, 2, &spans);
    try std.testing.expectEqual(postings.TokenSpan{ .start = 6, .length = 8 }, tamil[1]);

    // A v1 section still decodes, without positions.
    var v1_index = index;
    v1_index.positions = null;
    v1_index.sorted_terms = false;
    var v1_storage: [4096]u8 = undefined;
    const v1 = try encode(v1_index, &v1_storage);
    try std.testing.expectEqualStrings(magic, v1[0..8]);
    try std.testing.expect(!(try inspect(v1)).hasPositions());
    const v1_decoded = try decode(v1, &terms, &values, &lengths);
    try std.testing.expect(v1_decoded.positions == null);
}

test "HYBLEX02 corruption: checksum first, then every section 4/5 rule (S3-T2)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const index = try positionalFixture(arena_state.allocator());
    var pristine: [4096]u8 = undefined;
    const good = try encode(index, &pristine);
    var terms: [16]postings.TermEntry = undefined;
    var values: [16]postings.Posting = undefined;
    var lengths: [3]u32 = undefined;
    const positions_at = good.len - index.positions.?.offsets.len - index.positions.?.positions.len;
    const offsets_at = good.len - index.positions.?.offsets.len;

    // Header fields 56 and 64 and the payload of both sections are covered.
    for ([_]usize{ 56, 64, positions_at, offsets_at, good.len - 1 }) |at| {
        var copy: [4096]u8 = undefined;
        @memcpy(copy[0..good.len], good);
        copy[at] ^= 0x01;
        const result = inspect(copy[0..good.len]);
        if (at == 56 or at == 64) {
            try std.testing.expect(std.meta.isError(result));
        } else {
            try std.testing.expectError(error.ChecksumMismatch, result);
        }
    }

    // With the checksum recomputed, the structural rules still refuse.
    var copy: [4096]u8 = undefined;
    @memcpy(copy[0..good.len], good);
    copy[positions_at] = 0x7F; // an ordinal past the document's length
    rechecksum(copy[0..good.len]);
    try std.testing.expectError(error.InvalidPositions, decode(copy[0..good.len], &terms, &values, &lengths));

    @memcpy(copy[0..good.len], good);
    copy[offsets_at] +%= 1; // token count != document length
    rechecksum(copy[0..good.len]);
    try std.testing.expectError(error.InvalidPositions, decode(copy[0..good.len], &terms, &values, &lengths));

    @memcpy(copy[0..good.len], good);
    copy[good.len - 1] = 0x80; // a last varint that never ends
    rechecksum(copy[0..good.len]);
    try std.testing.expectError(error.InvalidPositions, decode(copy[0..good.len], &terms, &values, &lengths));

    // Unsorted dictionary: swap the first byte of the first two terms' text.
    @memcpy(copy[0..good.len], good);
    const first_term = header_length_v2 + 3 * 4 + term_record_length;
    copy[first_term] = 0xFF;
    rechecksum(copy[0..good.len]);
    try std.testing.expectError(error.UnsortedTerms, decode(copy[0..good.len], &terms, &values, &lengths));

    // The writer refuses an unsorted positional index.
    var unsorted = index;
    var swapped: [16]postings.TermEntry = undefined;
    @memcpy(swapped[0..index.terms.len], index.terms);
    std.mem.swap(postings.TermEntry, &swapped[0], &swapped[1]);
    unsorted.terms = swapped[0..index.terms.len];
    var out: [4096]u8 = undefined;
    try std.testing.expectError(error.UnsortedTerms, encode(unsorted, &out));
}
