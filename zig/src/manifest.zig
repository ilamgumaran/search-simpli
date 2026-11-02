const hybrid = @import("hybrid.zig");
const lexical_segment = @import("lexical_segment.zig");
const postings = @import("postings.zig");
const segment = @import("segment.zig");
const source_section = @import("source.zig");
const std = @import("std");

pub const magic = "HYBMAN01";
pub const version: u16 = 1;
pub const header_length: usize = 88;

/// Manifest v2 (S3-T1, `docs/manifest-format-v2.md`): flags `has_source` and
/// `has_positions`, a bound source section (count, filename, byte length,
/// checksum) and a `meta` JSON object naming the chunkers and roots. The v1
/// header fields keep their offsets; the source length and checksum are
/// inserted at 76 and 84, so the header is 104 bytes.
pub const magic_v2 = "HYBMAN02";
pub const version_v2: u16 = 2;
pub const header_length_v2: usize = 104;
pub const flag_has_source: u16 = 1;
pub const flag_has_positions: u16 = 2;
/// S4-T1 (`docs/manifest-format-v2.md` v2.1): at least one bound section
/// carries an XXH3-64 checksum (`checksum.zig`). Readers before v2.1 refuse
/// the manifest on this bit (`UnsupportedFlags`) instead of failing later on
/// a section; a reader since v2.1 refuses an XXH3 section under a manifest
/// that does not set it. The manifest's own checksum stays FNV-1a 64.
pub const flag_xxh3_sections: u16 = 4;

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
    /// 1 or 2. Version 1 has none of the fields below.
    format_version: u16 = version,
    has_positions: bool = false,
    /// v2.1 (S4-T1): `flag_xxh3_sections`; set by the writer exactly when
    /// one of the bound sections' headers selects XXH3-64.
    xxh3_sections: bool = false,
    /// Empty when the generation binds no source section.
    source_file: []const u8 = "",
    source_bytes: usize = 0,
    source_checksum: u64 = 0,
    /// v2: a UTF-8 JSON object (`manifest_meta`, `chunkers`, `roots`,
    /// `source_section_version`); parse with `parseMeta`.
    meta: []const u8 = "",

    pub fn hasSource(value: Manifest) bool {
        return value.source_file.len != 0;
    }
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
    InvalidMeta,
    InvalidSourceSection,
    SourceSectionMissing,
    SourceSectionUnexpected,
    SourceSectionSizeMismatch,
    SourceSectionChecksumMismatch,
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
    const value = try sectionFields(generation, analyzer_id, embedding_model_id, documents_file, lexical_file, documents_encoded, lexical_encoded);
    // S3-T2: a v1 manifest cannot say `has_positions`, so it cannot bind a
    // `HYBLEX02` section (`createV2` can).
    if (value.has_positions) return error.UnsupportedVersion;
    try validateFields(value);
    return value;
}

/// The fields every manifest version takes from its two sections.
/// `has_positions` is set exactly when the lexical section is `HYBLEX02`.
fn sectionFields(
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
    return .{
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
        .has_positions = lexical_header.hasPositions(),
        .xxh3_sections = document_header.checksum_kind == .xxh3_64 or lexical_header.checksum_kind == .xxh3_64,
    };
}

/// A v2 manifest over the three sections (`source_encoded` null and
/// `source_file` empty when the generation retains no source bytes).
pub fn createV2(
    generation: u64,
    analyzer_id: []const u8,
    embedding_model_id: []const u8,
    documents_file: []const u8,
    lexical_file: []const u8,
    source_file: []const u8,
    meta: []const u8,
    documents_encoded: []const u8,
    lexical_encoded: []const u8,
    source_encoded: ?[]const u8,
) ManifestError!Manifest {
    var value = try sectionFields(generation, analyzer_id, embedding_model_id, documents_file, lexical_file, documents_encoded, lexical_encoded);
    value.format_version = version_v2;
    value.meta = meta;
    if (source_encoded) |bytes| {
        const header = source_section.inspect(bytes) catch return error.InvalidSourceSection;
        value.source_file = source_file;
        value.source_bytes = bytes.len;
        value.source_checksum = header.checksum;
        if (header.checksum_kind == .xxh3_64) value.xxh3_sections = true;
    } else if (source_file.len != 0) return error.SourceSectionMissing;
    try validateFields(value);
    return value;
}

fn payloadStrings(value: Manifest) [6][]const u8 {
    return .{ value.analyzer_id, value.embedding_model_id, value.documents_file, value.lexical_file, value.source_file, value.meta };
}

fn stringCount(value: Manifest) usize {
    return if (value.format_version >= version_v2) 6 else 4;
}

fn headerLengthOf(value: Manifest) usize {
    return if (value.format_version >= version_v2) header_length_v2 else header_length;
}

pub fn encodedLength(value: Manifest) ManifestError!usize {
    try validateFields(value);
    var payload_length: usize = 0;
    const strings = payloadStrings(value);
    for (strings[0..stringCount(value)]) |field| {
        payload_length = try checkedAdd(payload_length, @sizeOf(u32));
        payload_length = try checkedAdd(payload_length, field.len);
    }
    return checkedAdd(headerLengthOf(value), payload_length);
}

pub fn encode(value: Manifest, output: []u8) ManifestError![]u8 {
    if (value.format_version >= version_v2) return encodeV2(value, output);
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

fn encodeV2(value: Manifest, output: []u8) ManifestError![]u8 {
    const required = try encodedLength(value);
    if (output.len < required) return error.BufferTooSmall;
    const payload_length = required - header_length_v2;
    var flags: u16 = 0;
    if (value.hasSource()) flags |= flag_has_source;
    if (value.has_positions) flags |= flag_has_positions;
    if (value.xxh3_sections) flags |= flag_xxh3_sections;

    @memcpy(output[0..magic_v2.len], magic_v2);
    var header_offset: usize = magic_v2.len;
    writeU16(output, &header_offset, version_v2);
    writeU16(output, &header_offset, flags);
    writeU64(output, &header_offset, value.generation);
    writeU32(output, &header_offset, @intCast(value.document_count));
    writeU32(output, &header_offset, @intCast(value.vector_dimensions));
    writeU32(output, &header_offset, @intCast(value.term_count));
    writeU32(output, &header_offset, if (value.hasSource()) 1 else 0);
    writeU64(output, &header_offset, @intCast(value.posting_count));
    writeU64(output, &header_offset, @intCast(value.documents_bytes));
    writeU64(output, &header_offset, value.documents_checksum);
    writeU64(output, &header_offset, @intCast(value.lexical_bytes));
    writeU64(output, &header_offset, value.lexical_checksum);
    writeU64(output, &header_offset, @intCast(value.source_bytes));
    writeU64(output, &header_offset, value.source_checksum);
    writeU32(output, &header_offset, @intCast(payload_length));
    const checksum_offset = header_offset;
    writeU64(output, &header_offset, 0);
    std.debug.assert(header_offset == header_length_v2);

    var payload_offset = header_length_v2;
    for (payloadStrings(value)) |field| {
        writeU32(output, &payload_offset, @intCast(field.len));
        @memcpy(output[payload_offset .. payload_offset + field.len], field);
        payload_offset += field.len;
    }
    std.debug.assert(payload_offset == required);

    var checksum_write_offset = checksum_offset;
    writeU64(output, &checksum_write_offset, manifestChecksum(output[0..checksum_offset], output[header_length_v2..required]));
    return output[0..required];
}

fn decodeV2(encoded: []const u8) ManifestError!Manifest {
    var cursor = Cursor{ .bytes = encoded, .offset = magic_v2.len };
    if (try cursor.readU16() != version_v2) return error.UnsupportedVersion;
    const flags = try cursor.readU16();
    if (flags & ~(flag_has_source | flag_has_positions | flag_xxh3_sections) != 0) return error.UnsupportedFlags;
    const generation = try cursor.readU64();
    const document_count = try castToUsize(try cursor.readU32());
    const vector_dimensions = try castToUsize(try cursor.readU32());
    const term_count = try castToUsize(try cursor.readU32());
    const source_count = try cursor.readU32();
    const posting_count = try castToUsize(try cursor.readU64());
    const documents_bytes = try castToUsize(try cursor.readU64());
    const documents_checksum = try cursor.readU64();
    const lexical_bytes = try castToUsize(try cursor.readU64());
    const lexical_checksum = try cursor.readU64();
    const source_bytes = try castToUsize(try cursor.readU64());
    const source_checksum = try cursor.readU64();
    const payload_length = try castToUsize(try cursor.readU32());
    const expected_checksum = try cursor.readU64();
    std.debug.assert(cursor.offset == header_length_v2);

    const expected_total = try checkedAdd(header_length_v2, payload_length);
    if (encoded.len < expected_total) return error.Truncated;
    if (encoded.len > expected_total) return error.TrailingData;
    if (manifestChecksum(encoded[0 .. header_length_v2 - @sizeOf(u64)], encoded[header_length_v2..]) != expected_checksum) {
        return error.ChecksumMismatch;
    }

    var payload = Cursor{ .bytes = encoded[header_length_v2..] };
    const analyzer_id = try readString(&payload);
    const embedding_model_id = try readString(&payload);
    const documents_file = try readString(&payload);
    const lexical_file = try readString(&payload);
    const source_file = try readString(&payload);
    const meta = try readString(&payload);
    if (payload.offset != payload.bytes.len) return error.TrailingData;
    const has_source = flags & flag_has_source != 0;
    if (has_source != (source_count == 1) or source_count > 1 or has_source != (source_file.len != 0)) return error.InvalidSourceSection;
    if (!has_source and (source_bytes != 0 or source_checksum != 0)) return error.InvalidSourceSection;
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
        .format_version = version_v2,
        .has_positions = flags & flag_has_positions != 0,
        .xxh3_sections = flags & flag_xxh3_sections != 0,
        .source_file = source_file,
        .source_bytes = source_bytes,
        .source_checksum = source_checksum,
        .meta = meta,
    };
    try validateFields(value);
    return value;
}

pub fn decode(encoded: []const u8) ManifestError!Manifest {
    var cursor = Cursor{ .bytes = encoded };
    const actual_magic = try cursor.take(magic.len);
    if (std.mem.eql(u8, actual_magic, magic_v2)) return decodeV2(encoded);
    if (!std.mem.eql(u8, actual_magic, magic)) return error.BadMagic;
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
    _ = try validateSnapshotHeaders(value, documents_encoded, lexical_encoded);
}

/// The two section headers `validateSnapshotHeaders` checked (each
/// section's checksum computed once, against its bytes).
pub const SnapshotHeaders = struct {
    documents: segment.Header,
    lexical: lexical_segment.Header,
};

/// `validateSnapshot`, returning the headers it inspected so a decoder can
/// skip a second checksum pass (S4-T1: `snapshot_open` computes each
/// section's checksum once; it used to compute it three times).
pub fn validateSnapshotHeaders(
    value: Manifest,
    documents_encoded: []const u8,
    lexical_encoded: []const u8,
) ManifestError!SnapshotHeaders {
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
    // S3-T2: the flag and the section agree (`HYBLEX02` exactly when set).
    if (lexical_header.hasPositions() != value.has_positions) return error.InvalidLexicalSection;
    // S4-T1: an XXH3 section only under a manifest that says so.
    if (!value.xxh3_sections) {
        if (document_header.checksum_kind != .fnv1a64) return error.InvalidDocumentSection;
        if (lexical_header.checksum_kind != .fnv1a64) return error.InvalidLexicalSection;
    }
    return .{ .documents = document_header, .lexical = lexical_header };
}

/// Check the source section bytes a generation names (null when the
/// manifest binds none) against the manifest's length and checksum.
pub fn validateSource(value: Manifest, source_encoded: ?[]const u8) ManifestError!void {
    if (!value.hasSource()) {
        if (source_encoded != null) return error.SourceSectionUnexpected;
        return;
    }
    const bytes = source_encoded orelse return error.SourceSectionMissing;
    if (bytes.len != value.source_bytes) return error.SourceSectionSizeMismatch;
    const header = source_section.inspect(bytes) catch return error.InvalidSourceSection;
    if (header.checksum != value.source_checksum) return error.SourceSectionChecksumMismatch;
    if (!value.xxh3_sections and header.checksum_kind != .fnv1a64) return error.InvalidSourceSection;
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
    if (value.format_version < version_v2) {
        if (value.format_version != version or value.hasSource() or value.meta.len != 0 or value.has_positions or value.xxh3_sections)
            return error.UnsupportedVersion;
        return;
    }
    if (value.format_version != version_v2) return error.UnsupportedVersion;
    if (value.hasSource()) {
        try validateFilename(value.source_file);
        if (std.mem.eql(u8, value.source_file, value.documents_file) or std.mem.eql(u8, value.source_file, value.lexical_file))
            return error.SameFilename;
    } else if (value.source_bytes != 0 or value.source_checksum != 0) return error.InvalidSourceSection;
    if (value.meta.len < 2 or value.meta.len > std.math.maxInt(u32) or value.meta[0] != '{' or value.meta[value.meta.len - 1] != '}' or
        !std.unicode.utf8ValidateSlice(value.meta) or std.mem.indexOfScalar(u8, value.meta, 0) != null)
        return error.InvalidMeta;
}

// ------------------------------------------------------------------ meta ---

pub const ChunkerEntry = struct {
    id: []const u8,
    max_chars: usize,
    overlap_lines: usize,
};

pub const RootEntry = struct {
    root_id: []const u8,
    label: []const u8,
    kind: []const u8,
    /// S3-T3: labels every document of the root also requires (they add to
    /// each document's own labels, `docs/authorization.md`).
    required_labels: []const []const u8 = &.{},
    retain_source: bool,
    /// S3-T3: where the root came from: `folder` (`index_folder`'s walk) or
    /// `host` (`apply_changes`). Absent in S3-T1 metas: read as `folder`.
    origin: []const u8 = "folder",
};

/// S3-T3: a file the host named but whose bytes have not arrived
/// (`apply_changes` op `pending`): listed by name in the generation so a
/// reader can count it without `INDEX-STATE.json`.
pub const PendingEntry = struct {
    root_id: []const u8,
    path: []const u8,
    size: ?u64 = null,
    required_labels: []const []const u8 = &.{},
    /// `skipped` entries only: `too_large`, `unreadable` or `budget_exhausted`.
    reason: ?[]const u8 = null,
};

pub const Meta = struct {
    chunkers: []ChunkerEntry,
    roots: []RootEntry,
    source_section_version: u32,
    pending: []PendingEntry = &.{},
    /// S3-T3: indexed files that produced no chunk (an empty or blank file),
    /// listed so a reader can list them and knows their labels.
    unchunked: []PendingEntry = &.{},
    /// S3-T3: files a writer was given but could not index in full (too
    /// large: absent; unreadable or over the run's byte budget: their
    /// previous chunks, if any, kept), until a later change of the path. A
    /// result over a scope holding one says `truncated`.
    skipped: []PendingEntry = &.{},

    /// The chunker id a record's `chunker_index` names, or null.
    pub fn chunkerId(meta: Meta, index: u16) ?[]const u8 {
        if (index >= meta.chunkers.len) return null;
        return meta.chunkers[index].id;
    }
};

/// Write the `meta` object (keys in the order of
/// `docs/manifest-format-v2.md`). Owned by `allocator`.
pub fn writeMeta(
    allocator: std.mem.Allocator,
    chunkers: []const ChunkerEntry,
    roots: []const RootEntry,
    source_section_version: u32,
) error{OutOfMemory}![]u8 {
    return writeMetaPending(allocator, chunkers, roots, &.{}, &.{}, &.{}, source_section_version);
}

/// `writeMeta` plus the generation's pending files (S3-T3), written as
/// `pending` after `roots` only when there is at least one.
pub fn writeMetaPending(
    allocator: std.mem.Allocator,
    chunkers: []const ChunkerEntry,
    roots: []const RootEntry,
    pending: []const PendingEntry,
    unchunked: []const PendingEntry,
    skipped: []const PendingEntry,
    source_section_version: u32,
) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var json = std.json.Stringify{ .writer = &out.writer };
    writeMetaJson(&json, chunkers, roots, pending, unchunked, skipped, source_section_version) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch error.OutOfMemory;
}

fn writeLabels(json: *std.json.Stringify, labels: []const []const u8) !void {
    try json.beginArray();
    for (labels) |label| try json.write(label);
    try json.endArray();
}

fn writeFileList(json: *std.json.Stringify, name: []const u8, entries: []const PendingEntry) !void {
    if (entries.len == 0) return;
    try json.objectField(name);
    try json.beginArray();
    for (entries) |entry| {
        try json.beginObject();
        try json.objectField("root_id");
        try json.write(entry.root_id);
        try json.objectField("path");
        try json.write(entry.path);
        try json.objectField("size");
        try json.write(entry.size);
        try json.objectField("required_labels");
        try writeLabels(json, entry.required_labels);
        if (entry.reason) |reason| {
            try json.objectField("reason");
            try json.write(reason);
        }
        try json.endObject();
    }
    try json.endArray();
}

fn writeMetaJson(json: *std.json.Stringify, chunkers: []const ChunkerEntry, roots: []const RootEntry, pending: []const PendingEntry, unchunked: []const PendingEntry, skipped: []const PendingEntry, source_section_version: u32) !void {
    try json.beginObject();
    try json.objectField("manifest_meta");
    try json.write(@as(u32, 2));
    try json.objectField("chunkers");
    try json.beginArray();
    for (chunkers) |entry| {
        try json.beginObject();
        try json.objectField("id");
        try json.write(entry.id);
        try json.objectField("params");
        try json.beginObject();
        try json.objectField("max_chars");
        try json.write(entry.max_chars);
        try json.objectField("overlap_lines");
        try json.write(entry.overlap_lines);
        if (std.mem.eql(u8, entry.id, "md-section-v1")) {
            try json.objectField("front_matter");
            try json.write("yaml-v1");
        }
        try json.endObject();
        try json.endObject();
    }
    try json.endArray();
    try json.objectField("roots");
    try json.beginArray();
    for (roots) |root| {
        try json.beginObject();
        try json.objectField("root_id");
        try json.write(root.root_id);
        try json.objectField("label");
        try json.write(root.label);
        try json.objectField("kind");
        try json.write(root.kind);
        try json.objectField("required_labels");
        try writeLabels(json, root.required_labels);
        try json.objectField("retain_source");
        try json.write(root.retain_source);
        try json.objectField("origin");
        try json.write(root.origin);
        try json.endObject();
    }
    try json.endArray();
    try writeFileList(json, "pending", pending);
    try writeFileList(json, "unchunked", unchunked);
    try writeFileList(json, "skipped", skipped);
    try json.objectField("source_section_version");
    try json.write(source_section_version);
    try json.endObject();
}

/// Parse a v2 manifest's `meta` (strings borrow from the parse arena).
pub fn parseMeta(allocator: std.mem.Allocator, meta: []const u8) error{ OutOfMemory, InvalidMeta }!Meta {
    const value = std.json.parseFromSliceLeaky(std.json.Value, allocator, meta, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidMeta,
    };
    if (value != .object) return error.InvalidMeta;
    const object = value.object;
    const marker = object.get("manifest_meta") orelse return error.InvalidMeta;
    if (marker != .integer or marker.integer != 2) return error.InvalidMeta;
    const chunker_values = object.get("chunkers") orelse return error.InvalidMeta;
    if (chunker_values != .array) return error.InvalidMeta;
    const chunkers = try allocator.alloc(ChunkerEntry, chunker_values.array.items.len);
    for (chunker_values.array.items, chunkers) |item, *entry| {
        if (item != .object) return error.InvalidMeta;
        const id = item.object.get("id") orelse return error.InvalidMeta;
        const params = item.object.get("params") orelse return error.InvalidMeta;
        if (id != .string or id.string.len == 0 or params != .object) return error.InvalidMeta;
        entry.* = .{
            .id = id.string,
            .max_chars = try positiveField(params.object, "max_chars"),
            .overlap_lines = try nonNegativeField(params.object, "overlap_lines"),
        };
    }
    const root_values = object.get("roots") orelse return error.InvalidMeta;
    if (root_values != .array) return error.InvalidMeta;
    const roots = try allocator.alloc(RootEntry, root_values.array.items.len);
    for (root_values.array.items, roots) |item, *entry| {
        if (item != .object) return error.InvalidMeta;
        const root_id = item.object.get("root_id") orelse return error.InvalidMeta;
        const label = item.object.get("label") orelse return error.InvalidMeta;
        const kind = item.object.get("kind") orelse return error.InvalidMeta;
        if (root_id != .string or root_id.string.len == 0 or label != .string or kind != .string) return error.InvalidMeta;
        const retain = item.object.get("retain_source") orelse std.json.Value{ .bool = false };
        if (retain != .bool) return error.InvalidMeta;
        const origin = item.object.get("origin") orelse std.json.Value{ .string = "folder" };
        if (origin != .string or origin.string.len == 0) return error.InvalidMeta;
        entry.* = .{
            .root_id = root_id.string,
            .label = label.string,
            .kind = kind.string,
            .required_labels = try parseLabels(allocator, item.object.get("required_labels")),
            .retain_source = retain.bool,
            .origin = origin.string,
        };
    }
    for (roots, 0..) |root, index| {
        for (roots[0..index]) |earlier| if (std.mem.eql(u8, earlier.root_id, root.root_id)) return error.InvalidMeta;
    }
    const pending = try parseFileList(allocator, object.get("pending"));
    const unchunked = try parseFileList(allocator, object.get("unchunked"));
    const skipped = try parseFileList(allocator, object.get("skipped"));
    const source_version = object.get("source_section_version") orelse std.json.Value{ .integer = 0 };
    if (source_version != .integer or source_version.integer < 0 or source_version.integer > 1) return error.InvalidMeta;
    return .{
        .chunkers = chunkers,
        .roots = roots,
        .source_section_version = @intCast(source_version.integer),
        .pending = pending,
        .unchunked = unchunked,
        .skipped = skipped,
    };
}

fn parseFileList(allocator: std.mem.Allocator, value: ?std.json.Value) error{ OutOfMemory, InvalidMeta }![]PendingEntry {
    var entries: []PendingEntry = &.{};
    if (value) |list| {
        if (list != .array) return error.InvalidMeta;
        entries = try allocator.alloc(PendingEntry, list.array.items.len);
        for (list.array.items, entries) |item, *entry| {
            if (item != .object) return error.InvalidMeta;
            const root_id = item.object.get("root_id") orelse return error.InvalidMeta;
            const path = item.object.get("path") orelse return error.InvalidMeta;
            if (root_id != .string or path != .string or path.string.len == 0) return error.InvalidMeta;
            const size_value = item.object.get("size") orelse std.json.Value.null;
            const size: ?u64 = switch (size_value) {
                .null => null,
                .integer => |n| std.math.cast(u64, n) orelse return error.InvalidMeta,
                else => return error.InvalidMeta,
            };
            entry.* = .{
                .root_id = root_id.string,
                .path = path.string,
                .size = size,
                .required_labels = try parseLabels(allocator, item.object.get("required_labels")),
                .reason = if (item.object.get("reason")) |r| (if (r == .string) r.string else return error.InvalidMeta) else null,
            };
        }
    }
    return entries;
}

fn parseLabels(allocator: std.mem.Allocator, value: ?std.json.Value) error{ OutOfMemory, InvalidMeta }![]const []const u8 {
    const present = value orelse return &.{};
    if (present != .array) return error.InvalidMeta;
    const labels = try allocator.alloc([]const u8, present.array.items.len);
    for (present.array.items, labels) |item, *label| {
        if (item != .string or item.string.len == 0) return error.InvalidMeta;
        label.* = item.string;
    }
    return labels;
}

fn positiveField(object: std.json.ObjectMap, name: []const u8) error{InvalidMeta}!usize {
    const value = try nonNegativeField(object, name);
    if (value == 0) return error.InvalidMeta;
    return value;
}

fn nonNegativeField(object: std.json.ObjectMap, name: []const u8) error{InvalidMeta}!usize {
    const value = object.get(name) orelse return error.InvalidMeta;
    if (value != .integer or value.integer < 0) return error.InvalidMeta;
    return std.math.cast(usize, value.integer) orelse error.InvalidMeta;
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

fn v2Meta(allocator: std.mem.Allocator) ![]u8 {
    return writeMeta(allocator, &.{
        .{ .id = "line-window-v1", .max_chars = 1600, .overlap_lines = 3 },
        .{ .id = "md-section-v1", .max_chars = 1600, .overlap_lines = 3 },
    }, &.{.{ .root_id = "r-legacy", .label = "folder", .kind = "local", .retain_source = true }}, 1);
}

test "S3-T3: meta keeps root labels and origin, pending and unchunked files" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const meta = try writeMetaPending(
        arena,
        &.{.{ .id = "line-window-v1", .max_chars = 1600, .overlap_lines = 3 }},
        &.{
            .{ .root_id = "r-6f1a", .label = "School", .kind = "icloud", .required_labels = &.{"cloud-ok"}, .retain_source = true, .origin = "host" },
            .{ .root_id = "r-legacy", .label = "folder", .kind = "local", .retain_source = false },
        },
        &.{.{ .root_id = "r-6f1a", .path = "week-08.md", .size = 3900, .required_labels = &.{"family"} }},
        &.{.{ .root_id = "r-legacy", .path = "empty.txt", .size = 0 }},
        &.{.{ .root_id = "r-6f1a", .path = "huge.md", .size = 99, .reason = "too_large" }},
        0,
    );
    try std.testing.expect(std.mem.indexOf(u8, meta, "\"required_labels\":[\"cloud-ok\"],\"retain_source\":true,\"origin\":\"host\"") != null);
    const parsed = try parseMeta(arena, meta);
    try std.testing.expectEqual(@as(usize, 2), parsed.roots.len);
    try std.testing.expectEqualStrings("cloud-ok", parsed.roots[0].required_labels[0]);
    try std.testing.expectEqualStrings("host", parsed.roots[0].origin);
    try std.testing.expectEqualStrings("folder", parsed.roots[1].origin);
    try std.testing.expectEqualStrings("week-08.md", parsed.pending[0].path);
    try std.testing.expectEqual(@as(?u64, 3900), parsed.pending[0].size);
    try std.testing.expectEqualStrings("family", parsed.pending[0].required_labels[0]);
    try std.testing.expectEqualStrings("empty.txt", parsed.unchunked[0].path);
    try std.testing.expectEqualStrings("too_large", parsed.skipped[0].reason.?);
    // An S3-T1 meta (no origin, no labels, no lists) still parses.
    const old = try parseMeta(arena, "{\"manifest_meta\":2,\"chunkers\":[],\"roots\":[{\"root_id\":\"r-legacy\",\"label\":\"folder\",\"kind\":\"local\",\"required_labels\":[],\"retain_source\":true}],\"source_section_version\":0}");
    try std.testing.expectEqualStrings("folder", old.roots[0].origin);
    try std.testing.expectEqual(@as(usize, 0), old.pending.len);
    try std.testing.expectError(error.InvalidMeta, parseMeta(arena, "{\"manifest_meta\":2,\"chunkers\":[],\"roots\":[{\"root_id\":\"a\",\"label\":\"A\",\"kind\":\"host\"},{\"root_id\":\"a\",\"label\":\"A\",\"kind\":\"host\"}]}"));
    try std.testing.expectError(error.InvalidMeta, parseMeta(arena, "{\"manifest_meta\":2,\"chunkers\":[],\"roots\":[],\"pending\":[{\"root_id\":\"a\",\"path\":\"\"}]}"));
}

test "manifest v2 round trip binds the source section and the meta" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try SnapshotFixture.init();
    const documents_encoded = fixture.documentsEncoded();
    const lexical_encoded = fixture.lexicalEncoded();
    const source_encoded = try source_section.encode(arena, &.{.{ .path = "a.md", .bytes = "# A\r\nbody\r\n" }});
    const meta = try v2Meta(arena);
    const value = try createV2(9, "analyzer-v2", "none", "documents-9.hybseg", "lexical-9.hyblex", "source-9.hybsrc", meta, documents_encoded, lexical_encoded, source_encoded);
    var storage: [1024]u8 = undefined;
    const encoded = try encode(value, &storage);
    try std.testing.expectEqualStrings(magic_v2, encoded[0..8]);
    try std.testing.expectEqual(header_length_v2 + 6 * 4 + "analyzer-v2".len + "none".len + "documents-9.hybseg".len + "lexical-9.hyblex".len + "source-9.hybsrc".len + meta.len, encoded.len);
    const decoded = try decode(encoded);
    try std.testing.expectEqual(@as(u16, 2), decoded.format_version);
    try std.testing.expect(decoded.hasSource());
    try std.testing.expect(!decoded.has_positions);
    try std.testing.expectEqualStrings("source-9.hybsrc", decoded.source_file);
    try std.testing.expectEqual(source_encoded.len, decoded.source_bytes);
    try std.testing.expectEqualStrings(meta, decoded.meta);
    try validateSnapshot(decoded, documents_encoded, lexical_encoded);
    try validateSource(decoded, source_encoded);
    try std.testing.expectError(error.SourceSectionMissing, validateSource(decoded, null));
    try std.testing.expectError(error.SourceSectionSizeMismatch, validateSource(decoded, source_encoded[0 .. source_encoded.len - 1]));

    const parsed = try parseMeta(arena, decoded.meta);
    try std.testing.expectEqual(@as(usize, 2), parsed.chunkers.len);
    try std.testing.expectEqualStrings("md-section-v1", parsed.chunkerId(1).?);
    try std.testing.expect(parsed.chunkerId(2) == null);
    try std.testing.expectEqual(@as(usize, 1600), parsed.chunkers[1].max_chars);
    try std.testing.expectEqualStrings("r-legacy", parsed.roots[0].root_id);
    try std.testing.expect(parsed.roots[0].retain_source);
    try std.testing.expectEqual(@as(u32, 1), parsed.source_section_version);
}

test "manifest v2 without a source section and v1 still decode" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try SnapshotFixture.init();
    const meta = try writeMeta(arena, &.{.{ .id = "line-window-v1", .max_chars = 1600, .overlap_lines = 3 }}, &.{}, 0);
    const value = try createV2(2, "analyzer-v2", "none", "documents-2.hybseg", "lexical-2.hyblex", "", meta, fixture.documentsEncoded(), fixture.lexicalEncoded(), null);
    var storage: [1024]u8 = undefined;
    const decoded = try decode(try encode(value, &storage));
    try std.testing.expect(!decoded.hasSource());
    try validateSource(decoded, null);
    try std.testing.expectError(error.SourceSectionUnexpected, validateSource(decoded, "x"));

    const legacy = try create(3, "analyzer-v2", "none", "documents-3.hybseg", "lexical-3.hyblex", fixture.documentsEncoded(), fixture.lexicalEncoded());
    var legacy_storage: [512]u8 = undefined;
    const legacy_encoded = try encode(legacy, &legacy_storage);
    try std.testing.expectEqualStrings(magic, legacy_encoded[0..8]);
    try std.testing.expectEqual(@as(usize, header_length + 4 * 4 + 11 + 4 + 18 + 16), legacy_encoded.len);
    const legacy_decoded = try decode(legacy_encoded);
    try std.testing.expectEqual(@as(u16, 1), legacy_decoded.format_version);
    try std.testing.expect(!legacy_decoded.hasSource());
    try std.testing.expect(!legacy_decoded.has_positions);
    try std.testing.expectEqual(@as(usize, 0), legacy_decoded.meta.len);
}

test "manifest v2 checksum detects corruption of the new fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try SnapshotFixture.init();
    const source_encoded = try source_section.encode(arena, &.{.{ .path = "a.md", .bytes = "x\n" }});
    const value = try createV2(4, "analyzer-v2", "none", "documents-4.hybseg", "lexical-4.hyblex", "source-4.hybsrc", try v2Meta(arena), fixture.documentsEncoded(), fixture.lexicalEncoded(), source_encoded);
    var storage: [1024]u8 = undefined;
    const encoded = try encode(value, &storage);
    // flags, source count, source length, source checksum, the source
    // filename and the last byte of meta.
    const meta_end = encoded.len - 1;
    const name_at = std.mem.indexOf(u8, encoded, "source-4.hybsrc").?;
    for ([_]usize{ 10, 32, 76, 84, name_at, meta_end }) |at| {
        const copy = try arena.dupe(u8, encoded);
        copy[at] ^= 0x01;
        try std.testing.expectError(error.ChecksumMismatch, decode(copy));
    }
    try std.testing.expectError(error.Truncated, decode(encoded[0 .. encoded.len - 1]));
}

test "manifest v2 rejects bad meta, unsafe source names and stray flags" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fixture = try SnapshotFixture.init();
    const source_encoded = try source_section.encode(arena, &.{.{ .path = "a.md", .bytes = "x\n" }});
    const meta = try v2Meta(arena);
    try std.testing.expectError(error.InvalidMeta, createV2(1, "a", "none", "d", "l", "", "not json", fixture.documentsEncoded(), fixture.lexicalEncoded(), null));
    try std.testing.expectError(error.UnsafeFilename, createV2(1, "a", "none", "d", "l", "../s", meta, fixture.documentsEncoded(), fixture.lexicalEncoded(), source_encoded));
    try std.testing.expectError(error.SameFilename, createV2(1, "a", "none", "d", "l", "d", meta, fixture.documentsEncoded(), fixture.lexicalEncoded(), source_encoded));
    try std.testing.expectError(error.SourceSectionMissing, createV2(1, "a", "none", "d", "l", "s", meta, fixture.documentsEncoded(), fixture.lexicalEncoded(), null));
    try std.testing.expectError(error.InvalidMeta, parseMeta(arena, "{\"manifest_meta\":1,\"chunkers\":[],\"roots\":[]}"));
    try std.testing.expectError(error.InvalidMeta, parseMeta(arena, "{\"manifest_meta\":2,\"chunkers\":[{\"id\":\"x\",\"params\":{\"max_chars\":0,\"overlap_lines\":3}}],\"roots\":[]}"));

    const value = try createV2(1, "a", "none", "d", "l", "", meta, fixture.documentsEncoded(), fixture.lexicalEncoded(), null);
    var storage: [1024]u8 = undefined;
    const encoded = try encode(value, &storage);
    // A stray flag bit with a recomputed checksum is refused as unsupported.
    encoded[10] = 8;
    var checksum_offset: usize = header_length_v2 - 8;
    writeU64(encoded, &checksum_offset, manifestChecksum(encoded[0 .. header_length_v2 - 8], encoded[header_length_v2..]));
    try std.testing.expectError(error.UnsupportedFlags, decode(encoded));
}
