//! Documents record v5 (S6-T7, `docs/documents-v5-source-v2-format.md`):
//! `HYBSEG01` version 5, a front-coded file table (each path once, the
//! chunk count and the retained bit per file) and compact records (a flags
//! varint, raw ids, varint fields). `segment.inspect` parses the 56-byte
//! header; `decode` fills the same `hybrid.Document` array a v4 section
//! decodes to, with one block of decoded paths and one of hex ids from the
//! caller's allocator. The folder writer (`apply.buildGeneration`) writes it
//! with `encodeAlloc`.
const std = @import("std");
const checksum = @import("checksum.zig");
const hybrid = @import("hybrid.zig");
const segment = @import("segment.zig");

pub const version: u16 = 5;
pub const header_length: usize = 56;
/// The most bytes a file-table entry shares with the previous path.
pub const shared_cap: usize = 255;
const raw_id_bytes: usize = 10;
const hex_id_bytes: usize = 20;

const flag_id_inline: u32 = 1;
const flag_has_vector: u32 = 2;
const flag_has_labels: u32 = 4;

pub const EncodeError = segment.EncodeError || std.mem.Allocator.Error || error{
    /// S6-T7 ruling 9: a record v5 cannot code (an empty path or line 0).
    RecordNotEncodableV5,
    /// The records are not grouped by file in strictly increasing path
    /// order, or the retained paths are not strictly sorted.
    UnsortedPaths,
    /// A record's `source_doc_index` is not its file's retained ordinal.
    SourceIndexMismatch,
};

/// The v5 header fields beyond `segment.Header`'s.
pub const Counts = struct {
    file_count: usize = 0,
    table_bytes: usize = 0,
    records_bytes: usize = 0,
    path_bytes: usize = 0,
};

// ------------------------------------------------------------------ varints

pub fn varintLength(value: u64) usize {
    var length: usize = 1;
    var rest = value >> 7;
    while (rest != 0) : (rest >>= 7) length += 1;
    return length;
}

pub fn putVarint(out: []u8, at: *usize, value: u64) void {
    var rest = value;
    while (rest >= 0x80) : (rest >>= 7) {
        out[at.*] = @as(u8, @truncate(rest)) | 0x80;
        at.* += 1;
    }
    out[at.*] = @truncate(rest);
    at.* += 1;
}

/// A cursor over one area. `varint32`: at most 5 bytes and a value below
/// 2^32; `varint64`: at most 10 bytes. Overlong forms are accepted (as
/// `postings.readVarint`); a varint that runs past the area, has too many
/// bytes or is out of range is `error_value`.
pub fn Reader(comptime E: type, comptime error_value: E) type {
    return struct {
        bytes: []const u8,
        at: usize,
        const Self = @This();

        pub fn varint64(r: *Self, max_bytes: usize) E!u64 {
            var value: u64 = 0;
            var shift: u7 = 0;
            var count: usize = 0;
            while (true) {
                if (r.at >= r.bytes.len or count == max_bytes) return error_value;
                const byte = r.bytes[r.at];
                r.at += 1;
                count += 1;
                const part: u64 = byte & 0x7f;
                if (shift >= 64 or (shift > 0 and part >> @intCast(64 - shift) != 0)) return error_value;
                value |= part << @intCast(shift);
                if (byte & 0x80 == 0) return value;
                shift += 7;
            }
        }

        pub fn varint32(r: *Self) E!u32 {
            const value = try r.varint64(5);
            return std.math.cast(u32, value) orelse error_value;
        }

        pub fn take(r: *Self, length: usize) E![]const u8 {
            if (length > r.bytes.len - r.at) return error_value;
            defer r.at += length;
            return r.bytes[r.at..][0..length];
        }
    };
}

const TableReader = Reader(segment.DecodeError, error.InvalidFileTable);
const RecordReader = Reader(segment.DecodeError, error.InvalidRecord);

// ------------------------------------------------------------------ writer

fn isRawId(id: []const u8) bool {
    if (id.len != hex_id_bytes) return false;
    for (id) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

fn commonPrefix(a: []const u8, b: []const u8) usize {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n and a[i] == b[i]) i += 1;
    return i;
}

const File = struct { path: []const u8, chunks: u32, retained: bool };

/// Encode `documents` (each file's records together, files in strictly
/// increasing path order, every record with a path and line ≥ 1) with the
/// file table built from them and `retained_paths` (strictly sorted: every
/// file whose bytes the generation's source section holds, chunked or not).
/// A record's `source_doc_index` must be its file's position among the
/// retained paths, or `no_source_doc` when its file is not retained.
pub fn encodeAlloc(
    allocator: std.mem.Allocator,
    documents: []const hybrid.Document,
    retained_paths: []const []const u8,
) EncodeError![]u8 {
    if (documents.len > std.math.maxInt(u32)) return error.DocumentCountOverflow;
    // The files: a merge of the records' runs and the retained paths.
    var files = std.ArrayList(File).empty;
    defer files.deinit(allocator);
    var dimensions: usize = 0;
    {
        var doc: usize = 0;
        var kept: usize = 0;
        while (doc < documents.len or kept < retained_paths.len) {
            const run_path: ?[]const u8 = if (doc < documents.len) documents[doc].path else null;
            const kept_path: ?[]const u8 = if (kept < retained_paths.len) retained_paths[kept] else null;
            if (kept_path) |p| if (kept > 0 and std.mem.order(u8, retained_paths[kept - 1], p) != .lt) return error.UnsortedPaths;
            const order: std.math.Order = if (run_path == null) .gt else if (kept_path == null) .lt else std.mem.order(u8, run_path.?, kept_path.?);
            const path = if (order == .gt) kept_path.? else run_path.?;
            if (path.len == 0) return error.RecordNotEncodableV5;
            if (path.len > std.math.maxInt(u32)) return error.FieldTooLarge;
            if (files.items.len > 0 and std.mem.order(u8, files.items[files.items.len - 1].path, path) != .lt) return error.UnsortedPaths;
            const retained = order != .lt;
            if (retained) kept += 1;
            const sdi: u32 = if (retained) @intCast(kept - 1) else hybrid.no_source_doc;
            var chunks: usize = 0;
            if (order != .gt) while (doc < documents.len and std.mem.eql(u8, documents[doc].path, path)) : (doc += 1) {
                const d = documents[doc];
                if (d.start_line == 0) return error.RecordNotEncodableV5;
                if (d.end_line < d.start_line) return error.InvalidCitation;
                if (d.source_doc_index != sdi) return error.SourceIndexMismatch;
                if (d.id.len > std.math.maxInt(u32) or d.text.len > std.math.maxInt(u32) or
                    d.required_labels.len > std.math.maxInt(u32) or d.section_path.len > std.math.maxInt(u32)) return error.FieldTooLarge;
                segmentValidateLabels(d.required_labels) catch return error.InvalidRequiredLabels;
                segmentValidateSection(d.section_depth, d.heading_line, d.start_line, d.section_path) catch return error.InvalidSection;
                if (d.vector.len != 0) {
                    if (dimensions == 0) dimensions = d.vector.len;
                    if (d.vector.len != dimensions) return error.VectorDimensionsInconsistent;
                    if (dimensions > std.math.maxInt(u32)) return error.FieldTooLarge;
                }
                chunks += 1;
            };
            if (chunks > std.math.maxInt(u31)) return error.FieldTooLarge;
            try files.append(allocator, .{ .path = path, .chunks = @intCast(chunks), .retained = retained });
        }
    }
    if (files.items.len > std.math.maxInt(u32)) return error.DocumentCountOverflow;

    // Sizes.
    var table_bytes: usize = 0;
    var path_bytes: usize = 0;
    var previous: []const u8 = "";
    for (files.items) |f| {
        const shared = @min(commonPrefix(previous, f.path), shared_cap);
        const suffix = f.path.len - shared;
        table_bytes += varintLength(shared) + varintLength(suffix) + suffix + varintLength((@as(u64, f.chunks) << 1) | @intFromBool(f.retained));
        path_bytes += f.path.len;
        previous = f.path;
    }
    var records_bytes: usize = 0;
    for (documents) |d| records_bytes = try add(records_bytes, recordLength(d));
    const total = try add(try add(header_length, table_bytes), records_bytes);
    const out = try allocator.alloc(u8, total);

    // Header.
    @memcpy(out[0..8], segment.magic);
    std.mem.writeInt(u16, out[8..10], version, .little);
    std.mem.writeInt(u16, out[10..12], checksum.flag_xxh3, .little);
    std.mem.writeInt(u32, out[12..16], @intCast(documents.len), .little);
    std.mem.writeInt(u32, out[16..20], @intCast(dimensions), .little);
    std.mem.writeInt(u32, out[20..24], @intCast(files.items.len), .little);
    std.mem.writeInt(u64, out[24..32], table_bytes, .little);
    std.mem.writeInt(u64, out[32..40], records_bytes, .little);
    std.mem.writeInt(u64, out[40..48], path_bytes, .little);
    var at: usize = header_length;
    previous = "";
    for (files.items) |f| {
        const shared = @min(commonPrefix(previous, f.path), shared_cap);
        putVarint(out, &at, shared);
        putVarint(out, &at, f.path.len - shared);
        @memcpy(out[at..][0 .. f.path.len - shared], f.path[shared..]);
        at += f.path.len - shared;
        putVarint(out, &at, (@as(u64, f.chunks) << 1) | @intFromBool(f.retained));
        previous = f.path;
    }
    std.debug.assert(at == header_length + table_bytes);
    for (documents) |d| writeRecord(out, &at, d);
    std.debug.assert(at == total);
    std.mem.writeInt(u64, out[48..56], checksum.compute(.xxh3_64, out[0..48], out[header_length..]), .little);
    return out;
}

fn add(a: usize, b: usize) error{SizeOverflow}!usize {
    return std.math.add(usize, a, b) catch error.SizeOverflow;
}

fn recordFlags(d: hybrid.Document) u32 {
    var flags: u32 = 0;
    if (!isRawId(d.id)) flags |= flag_id_inline;
    if (d.vector.len != 0) flags |= flag_has_vector;
    if (d.required_labels.len != 0) flags |= flag_has_labels;
    return flags;
}

fn headingBack(d: hybrid.Document) u32 {
    return if (d.heading_line == 0) 0 else d.start_line - d.heading_line + 1;
}

fn recordLength(d: hybrid.Document) usize {
    const flags = recordFlags(d);
    var length: usize = varintLength(flags);
    length += if (flags & flag_id_inline != 0) varintLength(d.id.len) + d.id.len else raw_id_bytes;
    length += varintLength(d.text.len) + varintLength(d.start_line) + varintLength(d.end_line - d.start_line);
    length += varintLength(d.chunker_index) + varintLength(d.section_depth) + varintLength(headingBack(d));
    if (d.section_depth > 0) length += varintLength(d.section_path.len);
    if (flags & flag_has_labels != 0) length += varintLength(d.required_labels.len) + d.required_labels.len;
    length += 4 * d.vector.len + d.text.len + d.section_path.len;
    return length;
}

fn writeRecord(out: []u8, at: *usize, d: hybrid.Document) void {
    const flags = recordFlags(d);
    putVarint(out, at, flags);
    if (flags & flag_id_inline != 0) {
        putVarint(out, at, d.id.len);
        @memcpy(out[at.*..][0..d.id.len], d.id);
        at.* += d.id.len;
    } else {
        for (0..raw_id_bytes) |k| out[at.* + k] = (hexValue(d.id[2 * k]) << 4) | hexValue(d.id[2 * k + 1]);
        at.* += raw_id_bytes;
    }
    putVarint(out, at, d.text.len);
    putVarint(out, at, d.start_line);
    putVarint(out, at, d.end_line - d.start_line);
    putVarint(out, at, d.chunker_index);
    putVarint(out, at, d.section_depth);
    putVarint(out, at, headingBack(d));
    if (d.section_depth > 0) putVarint(out, at, d.section_path.len);
    if (flags & flag_has_labels != 0) {
        putVarint(out, at, d.required_labels.len);
        @memcpy(out[at.*..][0..d.required_labels.len], d.required_labels);
        at.* += d.required_labels.len;
    }
    for (d.vector) |value| {
        std.mem.writeInt(u32, out[at.*..][0..4], @bitCast(value), .little);
        at.* += 4;
    }
    @memcpy(out[at.*..][0..d.text.len], d.text);
    at.* += d.text.len;
    @memcpy(out[at.*..][0..d.section_path.len], d.section_path);
    at.* += d.section_path.len;
}

fn hexValue(c: u8) u8 {
    return if (c <= '9') c - '0' else c - 'a' + 10;
}

// ------------------------------------------------------------------ header

/// The v5 header after the magic and version (`segment.inspect`): flags,
/// counts, the declared total against `length`, and the checksum.
pub fn parseHeader(encoded: []const u8) segment.DecodeError!segment.Header {
    const header = try headerFields(encoded);
    if (checksum.compute(.xxh3_64, encoded[0..48], encoded[header_length..]) != header.checksum) return error.ChecksumMismatch;
    return header;
}

/// `parseHeader` without computing the checksum: for bytes whose header
/// was already inspected (the source section's first use, bound to the
/// documents section the open checked).
pub fn headerFields(encoded: []const u8) segment.DecodeError!segment.Header {
    if (encoded.len < 10 or !std.mem.eql(u8, encoded[0..8], segment.magic) or std.mem.readInt(u16, encoded[8..10], .little) != version) return error.UnsupportedVersion;
    if (encoded.len < header_length) return error.Truncated;
    const flags = std.mem.readInt(u16, encoded[10..12], .little);
    if (flags != checksum.flag_xxh3) return error.UnsupportedFlags;
    const document_count: usize = std.mem.readInt(u32, encoded[12..16], .little);
    const dimensions: usize = std.mem.readInt(u32, encoded[16..20], .little);
    const file_count: usize = std.mem.readInt(u32, encoded[20..24], .little);
    const table_bytes = std.math.cast(usize, std.mem.readInt(u64, encoded[24..32], .little)) orelse return error.SizeOverflow;
    const records_bytes = std.math.cast(usize, std.mem.readInt(u64, encoded[32..40], .little)) orelse return error.SizeOverflow;
    const path_bytes = std.math.cast(usize, std.mem.readInt(u64, encoded[40..48], .little)) orelse return error.SizeOverflow;
    const stored = std.mem.readInt(u64, encoded[48..56], .little);
    const total = add(add(header_length, table_bytes) catch return error.SizeOverflow, records_bytes) catch return error.SizeOverflow;
    if (encoded.len < total) return error.Truncated;
    if (encoded.len > total) return error.TrailingData;
    return .{
        .format_version = version,
        .document_count = document_count,
        .vector_dimensions = dimensions,
        .payload_length = total - header_length,
        .checksum = stored,
        .checksum_kind = .xxh3_64,
        .v5 = .{ .file_count = file_count, .table_bytes = table_bytes, .records_bytes = records_bytes, .path_bytes = path_bytes },
    };
}

/// The bounds the counts imply, checked before anything is allocated.
fn checkBounds(header: segment.Header) segment.DecodeError!void {
    const c = header.v5;
    if (c.table_bytes / 4 < c.file_count) return error.InvalidFileTable;
    if (c.path_bytes < c.file_count) return error.InvalidFileTable;
    const most_paths = std.math.add(usize, std.math.mul(usize, shared_cap, c.file_count) catch return error.InvalidFileTable, c.table_bytes) catch return error.InvalidFileTable;
    if (c.path_bytes > most_paths) return error.InvalidFileTable;
    if (c.records_bytes / 8 < header.document_count) return error.InvalidRecord;
}

// ------------------------------------------------------------------ reader

/// One file-table entry, decoded.
pub const Entry = struct { shared: usize, suffix: []const u8, chunks: u32, retained: bool };

/// The file table read entry by entry with every rule of the format
/// document (step 4 of its documents validation). `path` is rebuilt into
/// `buffer` when given (the caller's block of decoded paths), else into a
/// scratch the caller owns via `scratch`.
pub const TableWalk = struct {
    reader: TableReader,
    file_count: usize,
    document_count: usize,
    path_bytes: usize,
    has_source: bool,
    index: usize = 0,
    decoded: usize = 0,
    chunks_seen: usize = 0,
    retained_seen: usize = 0,
    previous: []const u8 = "",

    pub fn init(encoded: []const u8, header: segment.Header, has_source: bool) TableWalk {
        return .{
            .reader = .{ .bytes = encoded[0 .. header_length + header.v5.table_bytes], .at = header_length },
            .file_count = header.v5.file_count,
            .document_count = header.document_count,
            .path_bytes = header.v5.path_bytes,
            .has_source = has_source,
        };
    }

    /// The next entry, its path written at `into[0..]` (which must hold the
    /// previous path's first `shared` bytes at its start, as a path block
    /// laid out end to end does not: so the caller copies them, see
    /// `nextInto`). Returns null after the last entry, once the "no byte
    /// left over" and total rules have passed.
    pub fn next(walk: *TableWalk) segment.DecodeError!?Entry {
        if (walk.index == walk.file_count) {
            if (walk.reader.at != walk.reader.bytes.len) return error.TrailingData;
            if (walk.decoded != walk.path_bytes or walk.chunks_seen != walk.document_count) return error.InvalidFileTable;
            return null;
        }
        const shared = try walk.reader.varint32();
        if (shared > shared_cap or shared > walk.previous.len or (walk.index == 0 and shared != 0)) return error.InvalidFileTable;
        const suffix_length = try walk.reader.varint32();
        if (suffix_length == 0) return error.InvalidFileTable;
        const suffix = try walk.reader.take(suffix_length);
        if (walk.index > 0 and shared < walk.previous.len) {
            if (shared < shared_cap) {
                if (suffix[0] <= walk.previous[shared]) return error.UnsortedPaths;
            } else if (std.mem.order(u8, suffix, walk.previous[shared..]) != .gt) return error.UnsortedPaths;
        }
        walk.decoded = add(walk.decoded, add(shared, suffix_length) catch return error.InvalidFileTable) catch return error.InvalidFileTable;
        if (walk.decoded > walk.path_bytes) return error.InvalidFileTable;
        const value = try walk.reader.varint32();
        const chunks = value >> 1;
        const retained = value & 1 == 1;
        if (chunks == 0 and !retained) return error.InvalidFileTable;
        if (retained and !walk.has_source) return error.InvalidFileTable;
        walk.chunks_seen += chunks;
        if (walk.chunks_seen > walk.document_count) return error.InvalidFileTable;
        if (retained) walk.retained_seen += 1;
        walk.index += 1;
        return .{ .shared = shared, .suffix = suffix, .chunks = chunks, .retained = retained };
    }

    /// `next`, the path rebuilt at `block[at..]` from the previous path (a
    /// slice the walk keeps) and the suffix; `at` advances by its length.
    pub fn nextInto(walk: *TableWalk, block: []u8, at: *usize) segment.DecodeError!?struct { entry: Entry, path: []const u8 } {
        const entry = (try walk.next()) orelse return null;
        const length = entry.shared + entry.suffix.len;
        const path = block[at.*..][0..length];
        std.mem.copyForwards(u8, path[0..entry.shared], walk.previous[0..entry.shared]);
        @memcpy(path[entry.shared..], entry.suffix);
        at.* += length;
        walk.previous = path;
        return .{ .entry = entry, .path = path };
    }
};

/// Decode a v5 section whose header `segment.inspect` returned (checksum
/// checked) into `document_output` and `vector_output`, allocating the
/// decoded paths (`path_bytes`) and the hex ids (20 bytes per raw id) from
/// `allocator`. `has_source`: the manifest binds a source section (a
/// retained bit is refused without one).
pub fn decode(
    encoded: []const u8,
    header: segment.Header,
    document_output: []hybrid.Document,
    vector_output: []f32,
    allocator: std.mem.Allocator,
    has_source: bool,
) (segment.DecodeError || std.mem.Allocator.Error)![]hybrid.Document {
    if (document_output.len < header.document_count) return error.DocumentCapacityTooSmall;
    try checkBounds(header);
    const path_block = try allocator.alloc(u8, header.v5.path_bytes);
    const id_block = try allocator.alloc(u8, hex_id_bytes * header.document_count);
    var walk = TableWalk.init(encoded, header, has_source);
    var records = RecordReader{ .bytes = encoded, .at = header_length + header.v5.table_bytes };
    var path_at: usize = 0;
    var doc: usize = 0;
    var vector_at: usize = 0;
    var id_at: usize = 0;
    var retained: u32 = 0;
    const digits = "0123456789abcdef";
    while (try walk.nextInto(path_block, &path_at)) |item| {
        const sdi: u32 = if (item.entry.retained) retained else hybrid.no_source_doc;
        if (item.entry.retained) retained += 1;
        for (document_output[doc..][0..item.entry.chunks]) |*d| {
            const flags = try records.varint32();
            if (flags & ~(flag_id_inline | flag_has_vector | flag_has_labels) != 0) return error.UnsupportedFlags;
            const id: []const u8 = if (flags & flag_id_inline != 0) try records.take(try records.varint32()) else blk: {
                const raw = try records.take(raw_id_bytes);
                const hex = id_block[id_at..][0..hex_id_bytes];
                for (raw, 0..) |byte, k| {
                    hex[2 * k] = digits[byte >> 4];
                    hex[2 * k + 1] = digits[byte & 15];
                }
                id_at += hex_id_bytes;
                break :blk hex;
            };
            const text_length = try records.varint32();
            const start = try records.varint32();
            const span = try records.varint32();
            const chunker_index = try records.varint32();
            const depth = try records.varint32();
            const back = try records.varint32();
            if (start == 0 or @as(u64, start) + span > std.math.maxInt(u32)) return error.InvalidCitation;
            if (chunker_index > std.math.maxInt(u16) or depth > std.math.maxInt(u16) or back > start) return error.InvalidSection;
            const section_path_length: u32 = if (depth > 0) try records.varint32() else 0;
            var labels: []const u8 = "";
            if (flags & flag_has_labels != 0) {
                const n = try records.varint32();
                if (n == 0) return error.InvalidRequiredLabels;
                labels = try records.take(n);
                segmentValidateLabels(labels) catch return error.InvalidRequiredLabels;
            }
            var vector: []const f32 = &.{};
            if (flags & flag_has_vector != 0) {
                if (header.vector_dimensions == 0) return error.InvalidVectorDimensions;
                const raw = try records.take(4 * header.vector_dimensions);
                if (vector_output.len - vector_at < header.vector_dimensions) return error.VectorCapacityTooSmall;
                const out = vector_output[vector_at..][0..header.vector_dimensions];
                for (out, 0..) |*value, k| value.* = @bitCast(std.mem.readInt(u32, raw[4 * k ..][0..4], .little));
                vector = out;
                vector_at += header.vector_dimensions;
            }
            const text = try records.take(text_length);
            const section_path = try records.take(section_path_length);
            const heading: u32 = if (back == 0) 0 else start - back + 1;
            segmentValidateSection(@intCast(depth), heading, start, section_path) catch return error.InvalidSection;
            d.* = .{
                .id = id,
                .text = text,
                .vector = vector,
                .path = item.path,
                .start_line = start,
                .end_line = start + span,
                .required_labels = labels,
                .chunker_index = @intCast(chunker_index),
                .section_depth = @intCast(depth),
                .heading_line = heading,
                .source_doc_index = sdi,
                .section_path = section_path,
            };
        }
        doc += item.entry.chunks;
    }
    if (records.at != encoded.len) return error.TrailingData;
    return document_output[0..header.document_count];
}

/// One retained file as the source section v2 binds it: its path, and its
/// records in the documents array.
pub const RetainedFile = struct { path: []const u8, first: u32, chunks: u32 };

/// The retained files of a v5 section in table order (the source section's
/// record order), from the table walked again (`decode` checked it).
/// Paths of files with chunks are their records' paths; a file without
/// chunks has its path copied into `allocator`.
pub fn retainedFiles(
    allocator: std.mem.Allocator,
    encoded: []const u8,
    header: segment.Header,
    documents: []const hybrid.Document,
) (segment.DecodeError || std.mem.Allocator.Error)![]RetainedFile {
    var walk = TableWalk.init(encoded, header, true);
    // First pass: how many are retained, and the bytes of the unchunked paths.
    var count: usize = 0;
    var loose_bytes: usize = 0;
    {
        var scan = walk;
        var buffer = std.ArrayList(u8).empty;
        defer buffer.deinit(allocator);
        while (try scan.next()) |entry| {
            if (entry.retained) count += 1;
            buffer.shrinkRetainingCapacity(entry.shared);
            try buffer.appendSlice(allocator, entry.suffix);
            if (entry.retained and entry.chunks == 0) loose_bytes += buffer.items.len;
            // `scan.previous` must point at the full path for the next entry.
            scan.previous = buffer.items;
        }
    }
    const out = try allocator.alloc(RetainedFile, count);
    const loose = try allocator.alloc(u8, loose_bytes);
    var loose_at: usize = 0;
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);
    var first: usize = 0;
    var r: usize = 0;
    while (try walk.next()) |entry| {
        buffer.shrinkRetainingCapacity(entry.shared);
        try buffer.appendSlice(allocator, entry.suffix);
        walk.previous = buffer.items;
        if (first + entry.chunks > documents.len) return error.InvalidFileTable;
        if (entry.retained) {
            const path: []const u8 = if (entry.chunks > 0) documents[first].path else blk: {
                const copy = loose[loose_at..][0..buffer.items.len];
                @memcpy(copy, buffer.items);
                loose_at += copy.len;
                break :blk copy;
            };
            out[r] = .{ .path = path, .first = @intCast(first), .chunks = entry.chunks };
            r += 1;
        }
        first += entry.chunks;
    }
    return out;
}

fn segmentValidateLabels(labels: []const u8) error{InvalidRequiredLabels}!void {
    return segment.validatePackedRequiredLabelsPub(labels);
}

fn segmentValidateSection(depth: u16, heading_line: u32, start_line: u32, section_path: []const u8) error{InvalidSection}!void {
    return segment.validateSectionPub(depth, heading_line, start_line, section_path);
}
