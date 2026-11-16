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
/// S6-T4 (`docs/lexical-segment-format-v3.md`): `HYBLEX03`, what the folder
/// writers publish. Varint document lengths, a front-coded dictionary
/// (shared prefix, suffix, df, the term's coded postings length), postings
/// as `(gap << 1) | (tf == 1)` varints with a tf varint when tf > 1;
/// sections 4 and 5 byte for byte `HYBLEX02`'s. 88-byte header: v2's 80
/// with the decoded term text length before the checksum. Decoded whole at
/// open into the same arrays as v1 and v2 (the S6-T4 ruling on Phase 1).
pub const magic_v3 = "HYBLEX03";
pub const version_v3: u16 = 3;
pub const header_length_v3: usize = 88;
/// v3 flags bit 1: sections 4 and 5 present (the content section).
pub const flag_positions_v3: u16 = 2;
/// v3: the longest shared prefix a dictionary entry records. A writer caps
/// longer common prefixes here (the suffix carries the rest); a reader
/// refuses more. It bounds the decoded term text by the section's size.
pub const max_shared_v3: usize = 255;
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
    /// v3: flags bit 1.
    positions_flag: bool = false,
    /// v3: the decoded dictionary's term bytes.
    term_text_bytes: usize = 0,

    pub fn hasPositions(header: Header) bool {
        return header.version == version_v2 or (header.version == version_v3 and header.positions_flag);
    }

    pub fn length(header: Header) usize {
        return headerLength(header.version);
    }
};

/// The section's length for `index`, after `validateIndex` (once).
pub fn encodedLength(index: postings.Index) EncodeError!usize {
    try validateIndex(index);
    return (try sizes(index)).total;
}

/// `encodeAllocMarked` and `validateIndexMarked` without marks.
pub const NoMarks = struct {
    pub fn mark(_: NoMarks, comptime _: []const u8) void {}
};

/// Write `index` as `HYBLEX01`, or as `HYBLEX02` when it carries positions
/// (its dictionary must then be sorted, its term ranges contiguous in
/// dictionary order and sections 4/5 valid: `validateIndex` checks), into
/// `output`. S4-T12 ruling 2: `validateIndex` runs once, here, not again
/// through `encodedLength`; an invalid index is refused before any byte is
/// written.
pub fn encode(index: postings.Index, output: []u8) EncodeError![]u8 {
    try validateIndex(index);
    const sized = try sizes(index);
    if (output.len < sized.total) return error.BufferTooSmall;
    return writeSized(index, sized, output);
}

/// S4-T12 ruling 2: `encode` into a buffer of exactly the section's length
/// from `allocator` (the returned slice is the whole allocation), with one
/// `validateIndex`: the writers' call (`apply`, `filename_field.build`,
/// `importer`), instead of `encodedLength` then `encode`, which validated
/// the index twice.
pub fn encodeAlloc(allocator: std.mem.Allocator, index: postings.Index) EncodeError![]u8 {
    return encodeAllocMarked(allocator, index, NoMarks{});
}

/// `encodeAlloc`, calling `marks.mark(name)` after each pass of
/// `validateIndex` (S4-T12 ruling 1: the writer's stage profile).
pub fn encodeAllocMarked(allocator: std.mem.Allocator, index: postings.Index, marks: anytype) EncodeError![]u8 {
    try validateIndexMarked(index, marks);
    const sized = try sizes(index);
    return writeSized(index, sized, try allocator.alloc(u8, sized.total));
}

/// The byte counts of the sections `writeSized` writes and their total,
/// with checked arithmetic; no validation (the callers run it first).
const Sizes = struct {
    document_lengths: usize,
    dictionary: usize,
    postings: usize,
    total: usize,
};

fn sizes(index: postings.Index) EncodeError!Sizes {
    var dictionary_bytes: usize = 0;
    for (index.terms) |entry| {
        dictionary_bytes = try checkedAdd(dictionary_bytes, term_record_length);
        dictionary_bytes = try checkedAdd(dictionary_bytes, entry.term.len);
    }
    const document_lengths_bytes = try checkedMultiply(index.document_lengths.len, @sizeOf(u32));
    const postings_bytes = try checkedMultiply(index.postings.len, posting_record_length);
    var length = if (index.positions == null) header_length else header_length_v2;
    length = try checkedAdd(length, document_lengths_bytes);
    length = try checkedAdd(length, dictionary_bytes);
    length = try checkedAdd(length, postings_bytes);
    if (index.positions) |sections| {
        length = try checkedAdd(length, sections.positions.len);
        length = try checkedAdd(length, sections.offsets.len);
    }
    return .{ .document_lengths = document_lengths_bytes, .dictionary = dictionary_bytes, .postings = postings_bytes, .total = length };
}

/// The section's bytes for a validated `index` into `output`, at least
/// `sized.total` long (`sizes(index)`).
fn writeSized(index: postings.Index, sized: Sizes, output: []u8) []u8 {
    const required = sized.total;
    const v2 = index.positions != null;
    const fixed_length = if (v2) header_length_v2 else header_length;
    const dictionary_bytes = sized.dictionary;
    const document_lengths_bytes = sized.document_lengths;
    const postings_bytes = sized.postings;

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

pub fn headerLength(found_version: u16) usize {
    return switch (found_version) {
        version_v3 => header_length_v3,
        version_v2 => header_length_v2,
        else => header_length,
    };
}

/// The header length of the section `encoded` (by its magic), for readers
/// of the stored checksum; 0 when it is too short or unknown.
pub fn headerLengthOfBytes(encoded: []const u8) usize {
    if (encoded.len < 8) return 0;
    if (std.mem.eql(u8, encoded[0..8], magic_v3)) return header_length_v3;
    if (std.mem.eql(u8, encoded[0..8], magic_v2)) return header_length_v2;
    if (std.mem.eql(u8, encoded[0..8], magic)) return header_length;
    return 0;
}

pub fn inspect(encoded: []const u8) DecodeError!Header {
    if (encoded.len >= 8 and std.mem.eql(u8, encoded[0..8], magic_v3)) return inspectV3(encoded);
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
    /// S6-T4 (v3): where the front-coded dictionary's terms are written, at
    /// least the header's `term_text_bytes` long. Without it a v3 decode
    /// allocates exactly that from `term_text_allocator` once the header is
    /// inspected (checksum and bounds first); without either it is
    /// `TermCapacityTooSmall`. v1 and v2 terms are slices of the section and
    /// use neither.
    term_text: ?[]u8 = null,
    term_text_allocator: ?std.mem.Allocator = null,
};

pub fn decodeWith(
    encoded: []const u8,
    term_output: []postings.TermEntry,
    posting_output: []postings.Posting,
    document_length_output: []u32,
    options: DecodeOptions,
) DecodeError!postings.Index {
    const header = options.inspected orelse try inspect(encoded);
    if (header.version == version_v3) return decodeV3(encoded, header, term_output, posting_output, document_length_output, options);
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
    return validateIndexMarked(index, NoMarks{});
}

fn validateIndexMarked(index: postings.Index, marks: anytype) EncodeError!void {
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
    //
    // S4-T12 ruling 3: an index with positions (`HYBLEX02`) must have a
    // strictly sorted dictionary, so its duplicates are adjacent: one pass
    // of neighbours names an equal pair `DuplicateTerm` and proves the order
    // (the `sorted_terms` flag is not read). Only a dictionary with a
    // descending pair, refused below as `UnsortedTerms` unless it also holds
    // a duplicate, falls back to the hash set from the start, so every input
    // gets the name it got before; a sorted dictionary (every writer's)
    // never builds one. `HYBLEX01` (no positions) keeps the hash set.
    var sorted = false;
    if (index.positions != null) {
        sorted = true;
        for (index.terms, 0..) |entry, position| {
            if (entry.term.len == 0 or entry.term.len > std.math.maxInt(u32)) return error.InvalidTerm;
            if (position == 0) continue;
            switch (std.mem.order(u8, index.terms[position - 1].term, entry.term)) {
                .lt => {},
                .eq => return error.DuplicateTerm,
                .gt => {
                    sorted = false;
                    break;
                },
            }
        }
    }
    if (!sorted) {
        var seen = std.StringHashMap(void).init(std.heap.page_allocator);
        defer seen.deinit();
        for (index.terms) |entry| {
            if (entry.term.len == 0 or entry.term.len > std.math.maxInt(u32)) return error.InvalidTerm;
            const duplicate = seen.getOrPut(entry.term) catch return error.OutOfMemory;
            if (duplicate.found_existing) return error.DuplicateTerm;
        }
    }
    marks.mark("dictionary");
    for (index.terms) |entry| {
        const postings_end = std.math.add(usize, entry.postings_start, entry.postings_length) catch
            return error.InvalidPostingRange;
        if (postings_end > index.postings.len) return error.InvalidPostingRange;
        if (entry.document_frequency != entry.postings_length) return error.DocumentFrequencyMismatch;
    }
    marks.mark("term_ranges");
    for (index.postings) |posting| {
        if (posting.document_index >= index.document_lengths.len or posting.term_frequency == 0) {
            return error.InvalidPosting;
        }
    }
    marks.mark("postings");
    validatePostingOrder(index.terms, index.postings) catch return error.InvalidPosting;
    marks.mark("posting_order");
    if (index.positions) |sections| {
        // The dictionary pass proved the order, or found a descending pair
        // (no duplicate, or the hash set would have named it).
        if (!sorted) return error.UnsortedTerms;
        validatePositions(index.terms, index.postings, index.document_lengths, sections) catch |err| return switch (err) {
            error.UnsortedTerms => error.UnsortedTerms,
            else => error.InvalidPositions,
        };
        marks.mark("positions");
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

/// S4-T12: a minimal valid `HYBLEX02` index by hand: one token per
/// document, one term per document, `terms` in the given order (each term's
/// one posting is its own document).
fn handPositional(terms: []postings.TermEntry, values: []postings.Posting, lengths: []u32, positions: []u8, offsets: []u8, names: []const []const u8) postings.Index {
    for (names, 0..) |name, i| {
        terms[i] = .{ .term = name, .document_frequency = 1, .postings_start = i, .postings_length = 1 };
        values[i] = .{ .document_index = @intCast(i), .term_frequency = 1 };
        lengths[i] = 1;
        positions[i] = 0;
        @memcpy(offsets[i * 6 ..][0..6], &[_]u8{ 1, 0, 0, 0, 0, 1 });
    }
    return .{
        .terms = terms[0..names.len],
        .postings = values[0..names.len],
        .document_lengths = lengths[0..names.len],
        .average_document_length = 1,
        .positions = .{ .positions = positions[0..names.len], .offsets = offsets[0 .. names.len * 6] },
        .sorted_terms = true,
    };
}

/// S4-T12 ruling 2: `expected` through each public call a writer or a
/// caller uses: `encodedLength`, `encode` and `encodeAlloc`.
fn expectRefusedEverywhere(expected: EncodeError, index: postings.Index) !void {
    var out: [1024]u8 = undefined;
    try std.testing.expectError(expected, encodedLength(index));
    try std.testing.expectError(expected, encode(index, &out));
    try std.testing.expectError(expected, encodeAlloc(std.testing.allocator, index));
    try std.testing.expectError(expected, encodeAllocMarked(std.testing.allocator, index, NoMarks{}));
}

test "S4-T12 ruling 2: every refusal keeps its name through encodedLength, encode and encodeAlloc" {
    var terms: [3]postings.TermEntry = undefined;
    var values: [3]postings.Posting = undefined;
    var lengths: [3]u32 = undefined;
    var positions: [3]u8 = undefined;
    var offsets: [18]u8 = undefined;
    const valid = handPositional(&terms, &values, &lengths, &positions, &offsets, &.{ "alpha", "beta" });
    var v1 = valid;
    v1.positions = null;
    v1.sorted_terms = false;

    // Both valid indexes encode, and the three calls agree byte for byte.
    for ([_]postings.Index{ valid, v1 }) |index| {
        var out: [1024]u8 = undefined;
        const fixed = try encode(index, &out);
        try std.testing.expectEqual(fixed.len, try encodedLength(index));
        const owned = try encodeAlloc(std.testing.allocator, index);
        defer std.testing.allocator.free(owned);
        try std.testing.expectEqualSlices(u8, fixed, owned);
    }

    // CountOverflow: 2^32 document lengths (a slice over one u32, never read:
    // the length is refused first).
    const one = [_]u32{1};
    var huge = v1;
    huge.document_lengths = @as([*]const u32, &one)[0 .. @as(usize, std.math.maxInt(u32)) + 1];
    try expectRefusedEverywhere(error.CountOverflow, huge);

    for ([_]f32{ std.math.nan(f32), -1, std.math.inf(f32) }) |average| {
        var bad = valid;
        bad.average_document_length = average;
        try expectRefusedEverywhere(error.InvalidAverageDocumentLength, bad);
    }

    // InvalidTerm: an empty term, v1 and v2.
    var term_copy: [3]postings.TermEntry = undefined;
    for ([_]postings.Index{ valid, v1 }) |base| {
        @memcpy(term_copy[0..2], base.terms);
        term_copy[1].term = "";
        var bad = base;
        bad.terms = term_copy[0..2];
        try expectRefusedEverywhere(error.InvalidTerm, bad);
    }

    // DuplicateTerm: v1 with a non-adjacent duplicate, v2 with an adjacent one.
    {
        var t: [3]postings.TermEntry = undefined;
        var p: [3]postings.Posting = undefined;
        var l: [3]u32 = undefined;
        var s4: [3]u8 = undefined;
        var s5: [18]u8 = undefined;
        var bad = handPositional(&t, &p, &l, &s4, &s5, &.{ "alpha", "beta", "alpha" });
        bad.positions = null;
        bad.sorted_terms = false;
        try expectRefusedEverywhere(error.DuplicateTerm, bad);
        const adjacent = handPositional(&t, &p, &l, &s4, &s5, &.{ "alpha", "alpha" });
        try expectRefusedEverywhere(error.DuplicateTerm, adjacent);
    }

    // InvalidPostingRange: a range past the postings.
    @memcpy(term_copy[0..2], valid.terms);
    term_copy[1].postings_length = 2;
    term_copy[1].document_frequency = 2;
    var bad_range = valid;
    bad_range.terms = term_copy[0..2];
    try expectRefusedEverywhere(error.InvalidPostingRange, bad_range);

    // DocumentFrequencyMismatch.
    @memcpy(term_copy[0..2], valid.terms);
    term_copy[0].document_frequency = 2;
    var bad_frequency = valid;
    bad_frequency.terms = term_copy[0..2];
    try expectRefusedEverywhere(error.DocumentFrequencyMismatch, bad_frequency);

    // InvalidPosting: a document out of range, a zero term frequency, and a
    // term's postings out of document order.
    var posting_copy: [3]postings.Posting = undefined;
    @memcpy(posting_copy[0..2], valid.postings);
    posting_copy[1].document_index = 2;
    var bad_document = valid;
    bad_document.postings = posting_copy[0..2];
    try expectRefusedEverywhere(error.InvalidPosting, bad_document);
    @memcpy(posting_copy[0..2], valid.postings);
    posting_copy[0].term_frequency = 0;
    var bad_tf = valid;
    bad_tf.postings = posting_copy[0..2];
    try expectRefusedEverywhere(error.InvalidPosting, bad_tf);
    const one_term = [_]postings.TermEntry{.{ .term = "alpha", .document_frequency = 2, .postings_start = 0, .postings_length = 2 }};
    const descending = [_]postings.Posting{ .{ .document_index = 1, .term_frequency = 1 }, .{ .document_index = 0, .term_frequency = 1 } };
    var bad_order = v1;
    bad_order.terms = &one_term;
    bad_order.postings = &descending;
    try expectRefusedEverywhere(error.InvalidPosting, bad_order);

    // UnsortedTerms: descending terms, and sorted terms whose ranges are not
    // in dictionary order.
    @memcpy(term_copy[0..2], valid.terms);
    std.mem.swap([]const u8, &term_copy[0].term, &term_copy[1].term);
    var unsorted = valid;
    unsorted.terms = term_copy[0..2];
    try expectRefusedEverywhere(error.UnsortedTerms, unsorted);
    @memcpy(term_copy[0..2], valid.terms);
    term_copy[0].postings_start = 1;
    term_copy[1].postings_start = 0;
    var crossed = valid;
    crossed.terms = term_copy[0..2];
    try expectRefusedEverywhere(error.UnsortedTerms, crossed);

    // InvalidPositions: an ordinal past its document's length, and a byte
    // left over in section 4.
    const past = [_]u8{ 0, 1 };
    var bad_ordinal = valid;
    bad_ordinal.positions = .{ .positions = &past, .offsets = valid.positions.?.offsets };
    try expectRefusedEverywhere(error.InvalidPositions, bad_ordinal);
    const left_over = [_]u8{ 0, 0, 0 };
    var bad_tail = valid;
    bad_tail.positions = .{ .positions = &left_over, .offsets = valid.positions.?.offsets };
    try expectRefusedEverywhere(error.InvalidPositions, bad_tail);

    // BufferTooSmall: `encode` only (the others size their own buffer).
    var short: [1024]u8 = undefined;
    const needed = try encodedLength(valid);
    try std.testing.expectError(error.BufferTooSmall, encode(valid, short[0 .. needed - 1]));
}

fn ruling3Index(storage: anytype, names: []const []const u8, claimed: bool) postings.Index {
    var index = handPositional(&storage.terms, &storage.values, &storage.lengths, &storage.positions, &storage.offsets, names);
    index.sorted_terms = claimed;
    return index;
}

const Ruling3Storage = struct {
    terms: [3]postings.TermEntry = undefined,
    values: [3]postings.Posting = undefined,
    lengths: [3]u32 = undefined,
    positions: [3]u8 = undefined,
    offsets: [18]u8 = undefined,
};

test "S4-T12 ruling 3: a positional index with an adjacent duplicate is DuplicateTerm, whatever sorted_terms says" {
    var storage = Ruling3Storage{};
    for ([_]bool{ true, false }) |claimed| {
        try expectRefusedEverywhere(error.DuplicateTerm, ruling3Index(&storage, &.{ "alpha", "alpha", "beta" }, claimed));
        // The fallback: a descending pair plus a duplicate that is not
        // adjacent (`beta`, `alpha`, `beta`) is `DuplicateTerm`, as the hash
        // set named it before S4-T12.
        try expectRefusedEverywhere(error.DuplicateTerm, ruling3Index(&storage, &.{ "beta", "alpha", "beta" }, claimed));
    }
}

test "S4-T12 ruling 3: a positional index claiming sorted but descending is UnsortedTerms; a sorted one encodes" {
    var storage = Ruling3Storage{};
    for ([_]bool{ true, false }) |claimed| {
        try expectRefusedEverywhere(error.UnsortedTerms, ruling3Index(&storage, &.{ "beta", "alpha" }, claimed));
        try expectRefusedEverywhere(error.UnsortedTerms, ruling3Index(&storage, &.{ "alpha", "gamma", "beta" }, claimed));
        const owned = try encodeAlloc(std.testing.allocator, ruling3Index(&storage, &.{ "alpha", "beta", "gamma" }, claimed));
        std.testing.allocator.free(owned);
    }
}


// ===================================================================== v3 ==

fn inspectV3(encoded: []const u8) DecodeError!Header {
    var cursor = Cursor{ .bytes = encoded, .offset = magic_v3.len };
    if (try cursor.readU16() != version_v3) return error.UnsupportedVersion;
    const flags = try cursor.readU16();
    // Bit 0 (XXH3-64) is required, bit 1 names sections 4 and 5.
    if (flags & ~(checksum.flag_xxh3 | flag_positions_v3) != 0 or flags & checksum.flag_xxh3 == 0) return error.UnsupportedFlags;
    const document_count = try castToUsize(try cursor.readU32());
    const term_count = try castToUsize(try cursor.readU32());
    const posting_count = try castToUsize(try cursor.readU64());
    const average_document_length: f32 = @bitCast(try cursor.readU32());
    if (!std.math.isFinite(average_document_length) or average_document_length < 0) return error.InvalidAverageDocumentLength;
    const document_lengths_bytes = try castToUsize(try cursor.readU64());
    const dictionary_bytes = try castToUsize(try cursor.readU64());
    const postings_bytes = try castToUsize(try cursor.readU64());
    const positions_bytes = try castToUsize(try cursor.readU64());
    const offsets_bytes = try castToUsize(try cursor.readU64());
    const term_text_bytes = try castToUsize(try cursor.readU64());
    const expected_checksum = try cursor.readU64();
    std.debug.assert(cursor.offset == header_length_v3);
    var expected_total = try decodeCheckedAdd(header_length_v3, document_lengths_bytes);
    expected_total = try decodeCheckedAdd(expected_total, dictionary_bytes);
    expected_total = try decodeCheckedAdd(expected_total, postings_bytes);
    expected_total = try decodeCheckedAdd(expected_total, positions_bytes);
    expected_total = try decodeCheckedAdd(expected_total, offsets_bytes);
    if (encoded.len < expected_total) return error.Truncated;
    if (encoded.len > expected_total) return error.TrailingData;
    const actual_checksum = checksum.compute(.xxh3_64, encoded[0 .. header_length_v3 - 8], encoded[header_length_v3..]);
    if (actual_checksum != expected_checksum) return error.ChecksumMismatch;
    const positions_flag = flags & flag_positions_v3 != 0;
    // Bounds every count implies: a varint is 1 to 5 bytes, a posting at
    // least one byte, a term at least one byte of text and four of entry.
    if (!positions_flag and (positions_bytes != 0 or offsets_bytes != 0)) return error.InvalidSectionLength;
    if (document_count > std.math.maxInt(u32) / 2) return error.InvalidSectionLength;
    if (document_lengths_bytes < document_count or document_lengths_bytes > try decodeCheckedMultiply(document_count, 5)) return error.InvalidSectionLength;
    if (postings_bytes < posting_count or term_text_bytes < term_count or dictionary_bytes < try decodeCheckedMultiply(term_count, 5)) return error.InvalidSectionLength;
    if (posting_count < term_count) return error.InvalidSectionLength;
    // The shared-prefix cap bounds the decoded text by the section: every
    // term is at most `max_shared_v3` bytes from its predecessor plus its
    // suffix, which is in the dictionary.
    if (term_text_bytes > try decodeCheckedAdd(try decodeCheckedMultiply(term_count, max_shared_v3), dictionary_bytes)) return error.InvalidSectionLength;
    return .{
        .version = version_v3,
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
        .checksum_kind = .xxh3_64,
        .positions_flag = positions_flag,
        .term_text_bytes = term_text_bytes,
    };
}

fn decodeV3(
    encoded: []const u8,
    header: Header,
    term_output: []postings.TermEntry,
    posting_output: []postings.Posting,
    document_length_output: []u32,
    options: DecodeOptions,
) DecodeError!postings.Index {
    if (term_output.len < header.term_count) return error.TermCapacityTooSmall;
    if (posting_output.len < header.posting_count) return error.PostingCapacityTooSmall;
    if (document_length_output.len < header.document_count) return error.DocumentLengthCapacityTooSmall;
    const term_text = options.term_text orelse if (options.term_text_allocator) |a| try a.alloc(u8, header.term_text_bytes) else return error.TermCapacityTooSmall;
    if (term_text.len < header.term_text_bytes) return error.TermCapacityTooSmall;
    const document_count: u32 = @intCast(header.document_count);

    var payload = Cursor{ .bytes = encoded, .offset = header_length_v3 };
    const document_length_bytes = try payload.take(header.document_lengths_bytes);
    const dictionary_bytes = try payload.take(header.dictionary_bytes);
    const posting_bytes = try payload.take(header.postings_bytes);
    const positions_bytes = try payload.take(header.positions_bytes);
    const offsets_bytes = try payload.take(header.offsets_bytes);
    if (payload.offset != encoded.len) return error.TrailingData;

    // Section 1: one varint per document.
    var at: usize = 0;
    for (document_length_output[0..header.document_count]) |*length| {
        length.* = postings.readVarint(document_length_bytes, &at) orelse return error.InvalidSectionLength;
    }
    if (at != document_length_bytes.len) return error.InvalidSectionLength;

    // Sections 2 and 3: front-coded terms in strictly increasing byte order,
    // each followed by its list.
    at = 0;
    var text_at: usize = 0;
    var previous: []const u8 = &.{};
    var posting_start: usize = 0;
    var coded_start: usize = 0;
    for (term_output[0..header.term_count], 0..) |*entry, term_index| {
        const shared = postings.readVarint(dictionary_bytes, &at) orelse return error.InvalidTerm;
        const suffix_length = postings.readVarint(dictionary_bytes, &at) orelse return error.InvalidTerm;
        if (shared > previous.len or shared > max_shared_v3 or suffix_length == 0) return error.InvalidTerm;
        if (dictionary_bytes.len - at < suffix_length) return error.InvalidTerm;
        const suffix = dictionary_bytes[at..][0..suffix_length];
        at += suffix_length;
        const term_length = @as(usize, shared) + suffix_length;
        if (header.term_text_bytes - text_at < term_length) return error.InvalidSectionLength;
        const term = term_text[text_at..][0..term_length];
        std.mem.copyForwards(u8, term[0..shared], previous[0..shared]);
        @memcpy(term[shared..], suffix);
        text_at += term_length;
        // Strictly after the previous term, and `shared` its whole common
        // prefix unless capped: below the cap and the previous length, the
        // next byte must rise; at the cap, the whole terms are compared.
        if (term_index != 0) {
            if (shared < previous.len and shared < max_shared_v3) {
                if (suffix[0] <= previous[shared]) return error.UnsortedTerms;
            } else if (shared == max_shared_v3 and shared < previous.len) {
                if (std.mem.order(u8, previous, term) != .lt) return error.UnsortedTerms;
            }
        }
        const document_frequency = postings.readVarint(dictionary_bytes, &at) orelse return error.InvalidTerm;
        const coded_length = postings.readVarint(dictionary_bytes, &at) orelse return error.InvalidTerm;
        if (document_frequency == 0 or document_frequency > document_count) return error.DocumentFrequencyMismatch;
        if (coded_length < document_frequency) return error.InvalidPostingRange;
        if (header.posting_count - posting_start < document_frequency) return error.InvalidPostingRange;
        if (posting_bytes.len - coded_start < coded_length) return error.InvalidPostingRange;
        entry.* = .{
            .term = term,
            .document_frequency = document_frequency,
            .postings_start = posting_start,
            .postings_length = document_frequency,
        };
        postings.decodeList(posting_bytes[coded_start..][0..coded_length], document_frequency, document_count, posting_output[posting_start..][0..document_frequency]) catch return error.InvalidPosting;
        posting_start += document_frequency;
        coded_start += coded_length;
        previous = term;
    }
    if (at != dictionary_bytes.len or text_at != header.term_text_bytes) return error.InvalidSectionLength;
    if (posting_start != header.posting_count or coded_start != posting_bytes.len) return error.InvalidPostingRange;

    const index = postings.Index{
        .terms = term_output[0..header.term_count],
        .postings = posting_output[0..header.posting_count],
        .document_lengths = document_length_output[0..header.document_count],
        .average_document_length = header.average_document_length,
        .positions = if (header.positions_flag) .{ .positions = positions_bytes, .offsets = offsets_bytes } else null,
        .sorted_terms = true,
    };
    if (header.positions_flag and options.validate_positions) try validatePositions(index.terms, index.postings, index.document_lengths, index.positions.?);
    return index;
}

const ByteList = std.ArrayList(u8);

/// Write `index` as `HYBLEX03` (positions when it carries them). Needs a
/// strictly sorted dictionary with term ranges contiguous in dictionary
/// order, every df >= 1 and fewer than 2^31 documents.
pub fn encodeV3Alloc(allocator: std.mem.Allocator, index: postings.Index) EncodeError![]u8 {
    return encodeV3AllocMarked(allocator, index, NoMarks{});
}

pub fn encodeV3AllocMarked(allocator: std.mem.Allocator, index: postings.Index, marks: anytype) EncodeError![]u8 {
    try validateIndexMarked(index, marks);
    if (index.document_lengths.len > std.math.maxInt(u32) / 2) return error.CountOverflow;
    var expected_start: usize = 0;
    for (index.terms, 0..) |entry, i| {
        if (i != 0 and std.mem.order(u8, index.terms[i - 1].term, entry.term) != .lt) return error.UnsortedTerms;
        if (entry.postings_start != expected_start or entry.postings_length == 0) return error.UnsortedTerms;
        expected_start += entry.postings_length;
    }
    if (expected_start != index.postings.len) return error.UnsortedTerms;

    var lengths = ByteList.empty;
    defer lengths.deinit(allocator);
    try lengths.ensureTotalCapacity(allocator, index.document_lengths.len + 16);
    for (index.document_lengths) |length| try postings.appendVarint(&lengths, allocator, length);

    var coded = ByteList.empty;
    defer coded.deinit(allocator);
    try coded.ensureTotalCapacity(allocator, index.postings.len * 2 + 16);
    var dictionary = ByteList.empty;
    defer dictionary.deinit(allocator);
    try dictionary.ensureTotalCapacity(allocator, index.terms.len * 8 + 16);
    var previous: []const u8 = &.{};
    var term_text: usize = 0;
    for (index.terms) |entry| {
        const before = coded.items.len;
        var last: u32 = 0;
        for (index.postings[entry.postings_start..][0..entry.postings_length], 0..) |posting, k| {
            const delta: u32 = if (k == 0) posting.document_index else posting.document_index - last;
            last = posting.document_index;
            const one: u32 = @intFromBool(posting.term_frequency == 1);
            try postings.appendVarint(&coded, allocator, (delta << 1) | one);
            if (one == 0) try postings.appendVarint(&coded, allocator, posting.term_frequency);
        }
        // The common prefix, capped at `max_shared_v3` (the suffix then
        // carries the rest of the term; nothing is truncated).
        var shared: usize = 0;
        const limit = @min(previous.len, entry.term.len, max_shared_v3);
        while (shared < limit and previous[shared] == entry.term[shared]) shared += 1;
        try postings.appendVarint(&dictionary, allocator, @intCast(shared));
        try postings.appendVarint(&dictionary, allocator, @intCast(entry.term.len - shared));
        try dictionary.appendSlice(allocator, entry.term[shared..]);
        try postings.appendVarint(&dictionary, allocator, entry.document_frequency);
        try postings.appendVarint(&dictionary, allocator, @intCast(coded.items.len - before));
        term_text += entry.term.len;
        previous = entry.term;
    }
    const positions_len = if (index.positions) |p| p.positions.len else 0;
    const offsets_len = if (index.positions) |p| p.offsets.len else 0;
    var total = header_length_v3;
    total = try checkedAdd(total, lengths.items.len);
    total = try checkedAdd(total, dictionary.items.len);
    total = try checkedAdd(total, coded.items.len);
    total = try checkedAdd(total, positions_len);
    total = try checkedAdd(total, offsets_len);
    const output = try allocator.alloc(u8, total);
    @memcpy(output[0..8], magic_v3);
    var o: usize = 8;
    writeU16(output, &o, version_v3);
    writeU16(output, &o, checksum.flag_xxh3 | (if (index.positions != null) flag_positions_v3 else 0));
    writeU32(output, &o, @intCast(index.document_lengths.len));
    writeU32(output, &o, @intCast(index.terms.len));
    writeU64(output, &o, @intCast(index.postings.len));
    writeU32(output, &o, @bitCast(index.average_document_length));
    writeU64(output, &o, @intCast(lengths.items.len));
    writeU64(output, &o, @intCast(dictionary.items.len));
    writeU64(output, &o, @intCast(coded.items.len));
    writeU64(output, &o, @intCast(positions_len));
    writeU64(output, &o, @intCast(offsets_len));
    writeU64(output, &o, @intCast(term_text));
    const checksum_at = o;
    writeU64(output, &o, 0);
    std.debug.assert(o == header_length_v3);
    for ([_][]const u8{ lengths.items, dictionary.items, coded.items }) |part| {
        @memcpy(output[o..][0..part.len], part);
        o += part.len;
    }
    if (index.positions) |p| {
        @memcpy(output[o..][0..p.positions.len], p.positions);
        o += p.positions.len;
        @memcpy(output[o..][0..p.offsets.len], p.offsets);
        o += p.offsets.len;
    }
    std.debug.assert(o == total);
    var c = checksum_at;
    writeU64(output, &c, checksum.compute(.xxh3_64, output[0..checksum_at], output[header_length_v3..]));
    return output;
}

/// `index` (a `lexical_build.build` index: first-seen dictionary order) with
/// its dictionary sorted by bytes and its postings term-major in that order,
/// for the v3 writer. Term bytes are not copied.
pub fn sortedForV3(allocator: std.mem.Allocator, index: postings.Index) !postings.Index {
    if (index.sorted_terms) return index;
    const order = try allocator.alloc(u32, index.terms.len);
    defer allocator.free(order);
    for (order, 0..) |*slot, i| slot.* = @intCast(i);
    std.mem.sort(u32, order, index.terms, struct {
        fn less(terms: []const postings.TermEntry, a: u32, b: u32) bool {
            return std.mem.order(u8, terms[a].term, terms[b].term) == .lt;
        }
    }.less);
    const terms = try allocator.alloc(postings.TermEntry, index.terms.len);
    const values = try allocator.alloc(postings.Posting, index.postings.len);
    var at: usize = 0;
    for (order, terms) |old, *entry| {
        const source = index.terms[old];
        @memcpy(values[at..][0..source.postings_length], index.postings[source.postings_start..][0..source.postings_length]);
        entry.* = .{ .term = source.term, .document_frequency = source.document_frequency, .postings_start = at, .postings_length = source.postings_length };
        at += source.postings_length;
    }
    var out = index;
    out.terms = terms;
    out.postings = values;
    out.sorted_terms = true;
    return out;
}

// ============================================================ v3 tests ==

fn v3Fixture(arena: std.mem.Allocator) !postings.Index {
    // Three documents; "alpha" in 0 (tf 1) and 2 (tf 3), "alps" in 1,
    // "beta" in all three: gaps, tf 1 and tf > 1, a shared prefix.
    const terms = try arena.alloc(postings.TermEntry, 3);
    terms[0] = .{ .term = "alpha", .document_frequency = 2, .postings_start = 0, .postings_length = 2 };
    terms[1] = .{ .term = "alps", .document_frequency = 1, .postings_start = 2, .postings_length = 1 };
    terms[2] = .{ .term = "beta", .document_frequency = 3, .postings_start = 3, .postings_length = 3 };
    const values = try arena.dupe(postings.Posting, &.{
        .{ .document_index = 0, .term_frequency = 1 }, .{ .document_index = 2, .term_frequency = 3 },
        .{ .document_index = 1, .term_frequency = 1 },
        .{ .document_index = 0, .term_frequency = 1 }, .{ .document_index = 1, .term_frequency = 2 }, .{ .document_index = 2, .term_frequency = 1 },
    });
    const lengths = try arena.dupe(u32, &.{ 2, 3, 5 });
    return .{ .terms = terms, .postings = values, .document_lengths = lengths, .average_document_length = 10.0 / 3.0, .sorted_terms = true };
}

fn rechecksumV3(encoded: []u8) void {
    var offset: usize = header_length_v3 - 8;
    writeU64(encoded, &offset, checksum.compute(.xxh3_64, encoded[0 .. header_length_v3 - 8], encoded[header_length_v3..]));
}

const V3Buffers = struct {
    terms: [64]postings.TermEntry = undefined,
    values: [64]postings.Posting = undefined,
    lengths: [16]u32 = undefined,
    text: [1024]u8 = undefined,
};

fn decodeV3Test(encoded: []const u8, buffers: *V3Buffers) DecodeError!postings.Index {
    const header = try inspect(encoded);
    if (header.term_text_bytes > buffers.text.len or header.term_count > buffers.terms.len or header.posting_count > buffers.values.len or header.document_count > buffers.lengths.len) return error.TermCapacityTooSmall;
    return decodeWith(encoded, &buffers.terms, &buffers.values, &buffers.lengths, .{ .inspected = header, .term_text = &buffers.text });
}

test "S6-T4: HYBLEX03 round trip, with and without positions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_]postings.Index{ try v3Fixture(arena), try positionalFixture(arena) }) |index| {
        const encoded = try encodeV3Alloc(arena, index);
        try std.testing.expectEqualStrings(magic_v3, encoded[0..8]);
        var buffers: V3Buffers = .{};
        const decoded = try decodeV3Test(encoded, &buffers);
        try std.testing.expectEqual(index.positions != null, decoded.positions != null);
        try std.testing.expectEqualSlices(u32, index.document_lengths, decoded.document_lengths);
        try std.testing.expectEqualSlices(postings.Posting, index.postings, decoded.postings);
        try std.testing.expectEqual(index.terms.len, decoded.terms.len);
        for (index.terms, decoded.terms) |a, b| {
            try std.testing.expectEqualStrings(a.term, b.term);
            try std.testing.expectEqual(a.document_frequency, b.document_frequency);
            try std.testing.expectEqual(a.postings_start, b.postings_start);
        }
        if (index.positions) |p| {
            try std.testing.expectEqualSlices(u8, p.positions, decoded.positions.?.positions);
            try validatePositionSections(decoded);
        }
    }
}

test "S6-T4: HYBLEX03 damage is refused (checksum, truncation, zero gap, prefix, counts)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const good = try encodeV3Alloc(arena, try v3Fixture(arena));
    const header = try inspect(good);
    var buffers: V3Buffers = .{};
    const dictionary_at = header_length_v3 + header.document_lengths_bytes;
    const postings_at = dictionary_at + header.dictionary_bytes;

    // A flipped payload byte without a new checksum.
    var bytes = try arena.dupe(u8, good);
    bytes[postings_at] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, decodeV3Test(bytes, &buffers));
    // Truncated and extended.
    try std.testing.expectError(error.Truncated, decodeV3Test(good[0 .. good.len - 1], &buffers));
    try std.testing.expectError(error.Truncated, decodeV3Test(good[0..40], &buffers));
    // "alpha": postings (0<<1|1) then (2<<1|0) tf 3; make the second gap 0.
    bytes = try arena.dupe(u8, good);
    try std.testing.expectEqual(@as(u8, 1), bytes[postings_at]);
    try std.testing.expectEqual(@as(u8, 4), bytes[postings_at + 1]);
    bytes[postings_at + 1] = 0;
    rechecksumV3(bytes);
    try std.testing.expectError(error.InvalidPosting, decodeV3Test(bytes, &buffers));
    // A document past the count: gap 3 from document 0.
    bytes = try arena.dupe(u8, good);
    bytes[postings_at + 1] = 6;
    rechecksumV3(bytes);
    try std.testing.expectError(error.InvalidPosting, decodeV3Test(bytes, &buffers));
    // tf 1 stored explicitly (low bit 0, then tf varint 1).
    bytes = try arena.dupe(u8, good);
    bytes[postings_at + 2] = 1;
    rechecksumV3(bytes);
    try std.testing.expectError(error.InvalidPosting, decodeV3Test(bytes, &buffers));
    // "alps" shares 3 bytes with "alpha"; claim 6 (longer than "alpha").
    bytes = try arena.dupe(u8, good);
    const second_entry = dictionary_at + 2 + 5 + 2;
    try std.testing.expectEqual(@as(u8, 3), bytes[second_entry]);
    bytes[second_entry] = 6;
    rechecksumV3(bytes);
    try std.testing.expectError(error.InvalidTerm, decodeV3Test(bytes, &buffers));
    // Claim 2 shared bytes: "al" + "s" < "alpha", out of order.
    bytes = try arena.dupe(u8, good);
    bytes[second_entry] = 2;
    rechecksumV3(bytes);
    try std.testing.expect(std.meta.isError(decodeV3Test(bytes, &buffers)));
    // A posting count too large, a term count too large.
    bytes = try arena.dupe(u8, good);
    bytes[20] += 1;
    rechecksumV3(bytes);
    try std.testing.expect(std.meta.isError(decodeV3Test(bytes, &buffers)));
    bytes = try arena.dupe(u8, good);
    bytes[16] += 1;
    rechecksumV3(bytes);
    try std.testing.expect(std.meta.isError(decodeV3Test(bytes, &buffers)));
    // An unknown flag, and the XXH3 flag cleared.
    bytes = try arena.dupe(u8, good);
    bytes[10] |= 4;
    rechecksumV3(bytes);
    try std.testing.expectError(error.UnsupportedFlags, decodeV3Test(bytes, &buffers));
    bytes[10] = 0;
    rechecksumV3(bytes);
    try std.testing.expectError(error.UnsupportedFlags, decodeV3Test(bytes, &buffers));
}

test "S6-T4: flipping any byte of a small HYBLEX03 section never crashes the reader" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var refused: usize = 0;
    var accepted: usize = 0;
    var unsealed: usize = 0;
    for ([_]postings.Index{ try v3Fixture(arena), try positionalFixture(arena), try sharedPrefixFixture(arena, 300) }) |index| {
        const good = try encodeV3Alloc(arena, index);
        const bytes = try arena.dupe(u8, good);
        for (0..good.len) |at| {
            for ([_]u8{ 0x01, 0x02, 0x10, 0x80, 0xff }) |mask| {
                @memcpy(bytes, good);
                bytes[at] ^= mask;
                var buffers: V3Buffers = .{};
                // Without a new checksum every flip is refused.
                if (decodeV3Test(bytes, &buffers)) |_| unsealed += 1 else |_| {}
                if (at >= header_length_v3 - 8 and at < header_length_v3) continue;
                rechecksumV3(bytes);
                if (decodeV3Test(bytes, &buffers)) |decoded| {
                    // An accepted flip is another well-formed section (a
                    // changed tf, letter or length): it re-encodes to exactly
                    // these bytes, so nothing was read that is not there.
                    if (decoded.positions != null) validatePositionSections(decoded) catch {};
                    try std.testing.expectEqualSlices(u8, bytes, try encodeV3Alloc(arena, decoded));
                    accepted += 1;
                } else |_| refused += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), unsealed);
    try std.testing.expect(refused > 0 and accepted > 0);
    std.debug.print("S6-T4 byte flips: {d} resealed flips, {d} refused, {d} accepted (each re-encodes to its own bytes); every unsealed flip refused\n", .{ refused + accepted, refused, accepted });
}

/// Two terms that share `shared` bytes ("x" repeated, then "a" and "b"),
/// each in its own document.
fn sharedPrefixFixture(arena: std.mem.Allocator, shared: usize) !postings.Index {
    const first = try arena.alloc(u8, shared + 1);
    @memset(first, 'x');
    first[shared] = 'a';
    const second = try arena.dupe(u8, first);
    second[shared] = 'b';
    const terms = try arena.alloc(postings.TermEntry, 2);
    terms[0] = .{ .term = first, .document_frequency = 1, .postings_start = 0, .postings_length = 1 };
    terms[1] = .{ .term = second, .document_frequency = 1, .postings_start = 1, .postings_length = 1 };
    const values = try arena.dupe(postings.Posting, &.{ .{ .document_index = 0, .term_frequency = 1 }, .{ .document_index = 1, .term_frequency = 1 } });
    return .{ .terms = terms, .postings = values, .document_lengths = try arena.dupe(u32, &.{ 1, 1 }), .average_document_length = 1, .sorted_terms = true };
}

test "S6-T4 ruling 3: the writer caps a shared prefix at 255 bytes and never truncates a term" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_]usize{ 254, 255, 256, 300 }) |shared| {
        const index = try sharedPrefixFixture(arena, shared);
        const encoded = try encodeV3Alloc(arena, index);
        const header = try inspect(encoded);
        try std.testing.expectEqual(@as(usize, 2 * (shared + 1)), header.term_text_bytes);
        // The second entry: `shared` capped at 255, the suffix the rest.
        const dictionary = encoded[header_length_v3 + header.document_lengths_bytes ..][0..header.dictionary_bytes];
        var at: usize = 0;
        _ = postings.readVarint(dictionary, &at);
        const first_suffix = postings.readVarint(dictionary, &at).?;
        at += first_suffix + 2;
        try std.testing.expectEqual(@as(u32, @intCast(@min(shared, max_shared_v3))), postings.readVarint(dictionary, &at).?);
        try std.testing.expectEqual(@as(u32, @intCast(shared + 1 - @min(shared, max_shared_v3))), postings.readVarint(dictionary, &at).?);
        var buffers: V3Buffers = .{};
        const decoded = try decodeV3Test(encoded, &buffers);
        for (index.terms, decoded.terms) |a, b| try std.testing.expectEqualStrings(a.term, b.term);
        try std.testing.expectEqualSlices(postings.Posting, index.postings, decoded.postings);
    }
}

test "S6-T4 ruling 3: the reader refuses a shared length above 255 or above the previous term's length" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Two terms sharing 300 bytes: the second entry says shared 255 (varint
    // FF 01) and a 46-byte suffix. Rewrite it as shared 256 (80 02) with the
    // 45-byte suffix that makes the same term, so only the cap is broken.
    const good = try encodeV3Alloc(arena, try sharedPrefixFixture(arena, 300));
    const header = try inspect(good);
    const dictionary_at = header_length_v3 + header.document_lengths_bytes;
    // The first entry: shared 0, suffix length 301 (AD 02), 301 bytes, df,
    // list bytes.
    const second = dictionary_at + 1 + 2 + 301 + 2;
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0x01, 46 }, good[second..][0..3]);
    var bytes = try arena.alloc(u8, good.len - 1);
    @memcpy(bytes[0..second], good[0..second]);
    bytes[second] = 0x80;
    bytes[second + 1] = 0x02;
    bytes[second + 2] = 45;
    @memcpy(bytes[second + 3 ..], good[second + 4 ..]);
    var offset: usize = 40;
    writeU64(bytes, &offset, header.dictionary_bytes - 1);
    rechecksumV3(bytes);
    var buffers: V3Buffers = .{};
    try std.testing.expectError(error.InvalidTerm, decodeV3Test(bytes, &buffers));
    // Shared 255 is still fine with the same bytes otherwise.
    try std.testing.expect(!std.meta.isError(decodeV3Test(good, &buffers)));
    // Shared longer than the previous term (301 bytes): 302.
    bytes = try arena.dupe(u8, good);
    bytes[second] = 0xae; // 302 = 0xAE 0x02
    bytes[second + 1] = 0x02;
    rechecksumV3(bytes);
    try std.testing.expectError(error.InvalidTerm, decodeV3Test(bytes, &buffers));
    // A header claiming more term text than the cap allows is refused
    // before anything is allocated or decoded.
    bytes = try arena.dupe(u8, good);
    offset = 72;
    writeU64(bytes, &offset, 2 * max_shared_v3 + header.dictionary_bytes + 1);
    rechecksumV3(bytes);
    try std.testing.expectError(error.InvalidSectionLength, inspect(bytes));
}
