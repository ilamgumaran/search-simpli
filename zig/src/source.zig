//! Source section v1 (`HYBSRC01`, S3-T1 ruling 4, `docs/source-section-v1.md`):
//! the original bytes of every retained file, a line map per file over its
//! original line terminators, and a sha256 per file, bound to a generation by
//! the manifest (`manifest.zig`, v2). `readSpan` returns lines byte for byte
//! (lines a..b are the bytes from the start of line a to the start of line
//! b+1, so every terminator stays as written, CRLF included) and `outline`
//! returns a Markdown file's headings and front matter; both answer from one
//! file and never load more (CAP-19 NFR-13).
//!
//! Lines are `str.splitlines` lines of the original bytes, the same lines the
//! chunkers number: LF, CR, CRLF (one terminator), VT, FF, FS, GS, RS, NEL,
//! LS and PS each end a line. A leading UTF-8 BOM is not part of line 1.
const std = @import("std");
const chunker = @import("chunker.zig");
const chunker_md = @import("chunker_md.zig");

pub const magic = "HYBSRC01";
pub const version: u16 = 1;
pub const header_length: usize = 48;
const record_fixed_length: usize = 68;

pub const max_span_lines: usize = 400;
pub const max_span_bytes: usize = 256 * 1024;
pub const max_context_lines: u32 = 20;
pub const source_absent_message = "re-index required: source absent";

pub const Encoding = enum(u8) {
    /// UTF-8, line 1 starts at byte 0.
    utf8 = 0,
    /// UTF-8 with a byte order mark: line 1 starts at byte 3.
    utf8_bom = 1,
};

pub const InputFile = struct {
    path: []const u8,
    bytes: []const u8,
};

pub const EncodeError = error{
    OutOfMemory,
    InvalidUtf8,
    UnsortedPaths,
    InvalidPath,
    FieldTooLarge,
};

pub const DecodeError = error{
    BadMagic,
    UnsupportedVersion,
    UnsupportedFlags,
    Truncated,
    TrailingData,
    ChecksumMismatch,
    SizeOverflow,
    InvalidFileTable,
    InvalidLineMap,
    UnsortedPaths,
    InvalidPath,
};

pub const FileEntry = struct {
    path: []const u8,
    /// The file's original bytes (BOM included).
    bytes: []const u8,
    line_count: u32,
    line_map: []const u8,
    sha256: [32]u8,
    encoding: Encoding,
    /// S3-T4: this file's sparse line index (one checkpoint per
    /// `checkpoint_interval` lines), when the section was opened with
    /// `openIndexed`; empty otherwise (the map is then decoded from line 1).
    checkpoints: []const Checkpoint = &.{},
};

/// S3-T4 (sparse line index, built at open, no format change): every
/// `checkpoint_interval`-th varint of a file's delta-coded line map, so a
/// line's offset is found by decoding at most `checkpoint_interval` varints
/// instead of every one from line 1.
pub const checkpoint_interval: u32 = 256;

pub const Checkpoint = struct {
    /// Byte offset in the file's line map of varint `k * checkpoint_interval`
    /// (the start of line `k * checkpoint_interval + 1`).
    map_offset: usize,
    /// The absolute value accumulated before that varint is read.
    value: u64,
};

pub const Section = struct {
    encoded: []const u8,
    file_count: usize,
    checksum: u64,
    files_table: []const u8,
    line_maps: []const u8,
    text: []const u8,
    /// Byte offset of each file record in `files_table`, when the section
    /// was opened with `openIndexed`; `find` then binary-searches.
    record_offsets: []const usize = &.{},
    /// S3-T4: every file's checkpoints, in table order, and where each
    /// file's run starts (`file_count + 1` entries), when opened with
    /// `openIndexed`.
    checkpoints: []const Checkpoint = &.{},
    checkpoint_starts: []const usize = &.{},

    fn withCheckpoints(section: Section, index: usize, entry: FileEntry) FileEntry {
        if (section.checkpoint_starts.len != section.file_count + 1) return entry;
        var copy = entry;
        copy.checkpoints = section.checkpoints[section.checkpoint_starts[index]..section.checkpoint_starts[index + 1]];
        return copy;
    }

    /// The `index`-th file (0-based, path order).
    pub fn file(section: Section, index: usize) FileEntry {
        if (section.record_offsets.len == section.file_count) {
            var direct = Cursor{ .bytes = section.files_table, .offset = section.record_offsets[index] };
            return section.withCheckpoints(index, readRecord(&direct, section) catch unreachable);
        }
        var cursor = Cursor{ .bytes = section.files_table };
        var position: usize = 0;
        while (true) : (position += 1) {
            const entry = readRecord(&cursor, section) catch unreachable; // validated by `open`
            if (position == index) return entry;
        }
    }

    /// The file with this path, or null. Binary search over `record_offsets`
    /// when present (paths are strictly sorted by bytes), else a linear scan
    /// of the table that touches only fixed fields and paths.
    pub fn find(section: Section, path: []const u8) ?FileEntry {
        if (section.record_offsets.len == section.file_count and section.file_count > 0) {
            var low: usize = 0;
            var high: usize = section.file_count;
            while (low < high) {
                const middle = low + (high - low) / 2;
                var probe = Cursor{ .bytes = section.files_table, .offset = section.record_offsets[middle] };
                const entry = readRecord(&probe, section) catch unreachable;
                switch (std.mem.order(u8, entry.path, path)) {
                    .eq => return section.withCheckpoints(middle, entry),
                    .lt => low = middle + 1,
                    .gt => high = middle,
                }
            }
            return null;
        }
        var cursor = Cursor{ .bytes = section.files_table };
        var remaining = section.file_count;
        while (remaining > 0) : (remaining -= 1) {
            const entry = readRecord(&cursor, section) catch unreachable;
            switch (std.mem.order(u8, entry.path, path)) {
                .eq => return entry,
                .gt => return null,
                .lt => {},
            }
        }
        return null;
    }
};

fn isBreakAt(bytes: []const u8, index: usize) usize {
    const byte = bytes[index];
    switch (byte) {
        0x0a, 0x0b, 0x0c, 0x1c, 0x1d, 0x1e => return 1,
        0x0d => return if (index + 1 < bytes.len and bytes[index + 1] == 0x0a) 2 else 1,
        0xc2 => return if (index + 1 < bytes.len and bytes[index + 1] == 0x85) 2 else 0,
        0xe2 => return if (index + 2 < bytes.len and bytes[index + 1] == 0x80 and
            (bytes[index + 2] == 0xa8 or bytes[index + 2] == 0xa9)) 3 else 0,
        else => return 0,
    }
}

/// Byte offset of each line start, then the end offset. Appends to `out`.
pub fn lineStarts(allocator: std.mem.Allocator, bytes: []const u8, out: *std.ArrayList(u64)) !void {
    var index: usize = if (std.mem.startsWith(u8, bytes, "\xef\xbb\xbf")) 3 else 0;
    var line_open = false;
    while (index < bytes.len) {
        if (!line_open) {
            try out.append(allocator, index);
            line_open = true;
        }
        const width = isBreakAt(bytes, index);
        if (width != 0) {
            index += width;
            line_open = false;
        } else {
            index += 1;
        }
    }
    try out.append(allocator, bytes.len);
}

fn writeLeb128(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64) !void {
    var remaining = value;
    while (true) {
        const byte: u8 = @intCast(remaining & 0x7f);
        remaining >>= 7;
        if (remaining == 0) {
            try list.append(allocator, byte);
            return;
        }
        try list.append(allocator, byte | 0x80);
    }
}

fn validPath(path: []const u8) bool {
    if (path.len == 0 or path.len > std.math.maxInt(u32)) return false;
    if (path[0] == '/') return false;
    for (path) |byte| if (byte == 0 or byte == '\n' or byte == '\r') return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

/// Encode a source section. `files` must be strictly sorted by path bytes
/// and every file valid UTF-8 (a leading BOM allowed). The result is owned
/// by `allocator`.
pub fn encode(allocator: std.mem.Allocator, files: []const InputFile) EncodeError![]u8 {
    if (files.len > std.math.maxInt(u32)) return error.FieldTooLarge;
    var table = std.ArrayList(u8).empty;
    defer table.deinit(allocator);
    var maps = std.ArrayList(u8).empty;
    defer maps.deinit(allocator);
    var starts = std.ArrayList(u64).empty;
    defer starts.deinit(allocator);
    var text_length: u64 = 0;

    for (files, 0..) |input, position| {
        if (!validPath(input.path)) return error.InvalidPath;
        if (position > 0 and std.mem.order(u8, files[position - 1].path, input.path) != .lt) return error.UnsortedPaths;
        if (!std.unicode.utf8ValidateSlice(input.bytes)) return error.InvalidUtf8;
        starts.clearRetainingCapacity();
        try lineStarts(allocator, input.bytes, &starts);
        const line_count = starts.items.len - 1;
        if (line_count > std.math.maxInt(u32)) return error.FieldTooLarge;
        const map_offset: u64 = maps.items.len;
        var previous: u64 = 0;
        for (starts.items) |offset| {
            try writeLeb128(&maps, allocator, offset - previous);
            previous = offset;
        }
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(input.bytes, &digest, .{});

        var record: [record_fixed_length]u8 = undefined;
        var offset: usize = 0;
        putU32(&record, &offset, @intCast(input.path.len));
        putU64(&record, &offset, text_length);
        putU64(&record, &offset, input.bytes.len);
        putU32(&record, &offset, @intCast(line_count));
        putU64(&record, &offset, map_offset);
        @memcpy(record[offset .. offset + 32], &digest);
        offset += 32;
        record[offset] = @intFromEnum(if (std.mem.startsWith(u8, input.bytes, "\xef\xbb\xbf")) Encoding.utf8_bom else Encoding.utf8);
        record[offset + 1] = 0;
        record[offset + 2] = 0;
        record[offset + 3] = 0;
        offset += 4;
        std.debug.assert(offset == record_fixed_length);
        try table.appendSlice(allocator, &record);
        try table.appendSlice(allocator, input.path);
        text_length += input.bytes.len;
    }

    const total = header_length + table.items.len + maps.items.len + text_length;
    const out = try allocator.alloc(u8, total);
    var offset: usize = 0;
    @memcpy(out[0..magic.len], magic);
    offset = magic.len;
    putU16(out, &offset, version);
    putU16(out, &offset, 0);
    putU32(out, &offset, @intCast(files.len));
    putU64(out, &offset, table.items.len);
    putU64(out, &offset, maps.items.len);
    putU64(out, &offset, text_length);
    const checksum_offset = offset;
    putU64(out, &offset, 0);
    std.debug.assert(offset == header_length);
    @memcpy(out[offset .. offset + table.items.len], table.items);
    offset += table.items.len;
    @memcpy(out[offset .. offset + maps.items.len], maps.items);
    offset += maps.items.len;
    for (files) |input| {
        @memcpy(out[offset .. offset + input.bytes.len], input.bytes);
        offset += input.bytes.len;
    }
    std.debug.assert(offset == total);
    var write_offset = checksum_offset;
    putU64(out, &write_offset, checksumOf(out[0..checksum_offset], out[header_length..]));
    return out;
}

pub const Header = struct {
    file_count: usize,
    files_bytes: usize,
    maps_bytes: usize,
    text_bytes: usize,
    checksum: u64,
};

/// Validate the header, the declared size and the checksum only.
pub fn inspect(encoded: []const u8) DecodeError!Header {
    var cursor = Cursor{ .bytes = encoded };
    if (!std.mem.eql(u8, try cursor.take(magic.len), magic)) return error.BadMagic;
    if (try cursor.readU16() != version) return error.UnsupportedVersion;
    if (try cursor.readU16() != 0) return error.UnsupportedFlags;
    const file_count: usize = try cast(try cursor.readU32());
    const files_bytes: usize = try cast(try cursor.readU64());
    const maps_bytes: usize = try cast(try cursor.readU64());
    const text_bytes: usize = try cast(try cursor.readU64());
    const checksum = try cursor.readU64();
    std.debug.assert(cursor.offset == header_length);
    var expected = try add(header_length, files_bytes);
    expected = try add(expected, maps_bytes);
    expected = try add(expected, text_bytes);
    if (encoded.len < expected) return error.Truncated;
    if (encoded.len > expected) return error.TrailingData;
    if (checksumOf(encoded[0 .. header_length - 8], encoded[header_length..]) != checksum) return error.ChecksumMismatch;
    return .{ .file_count = file_count, .files_bytes = files_bytes, .maps_bytes = maps_bytes, .text_bytes = text_bytes, .checksum = checksum };
}

/// Validate a whole section (header, checksum, file table, paths, every line
/// map) and return a borrowing view of it.
pub fn open(encoded: []const u8) DecodeError!Section {
    return openWith(encoded, null);
}

/// `open`, plus a record-offset table so `find` is O(log n), and (S3-T4) a
/// sparse line index collected while the line maps are validated, so
/// `readSpan` decodes at most `checkpoint_interval` varints per line it
/// looks up. Two allocations from `allocator`: `file_count` words, and the
/// checkpoints (at most `file_count + line maps bytes / checkpoint_interval`
/// of them) with their per-file starts.
pub fn openIndexed(allocator: std.mem.Allocator, encoded: []const u8) (DecodeError || error{OutOfMemory})!Section {
    const header = try inspect(encoded);
    var index = Index{
        .offsets = try allocator.alloc(usize, header.file_count),
        .starts = try allocator.alloc(usize, header.file_count + 1),
        // A line costs at least one varint byte, so a file of n lines holds
        // n / interval + 1 checkpoints and the maps hold at least n bytes.
        .checkpoints = try allocator.alloc(Checkpoint, header.file_count + header.maps_bytes / checkpoint_interval + 1),
    };
    var section = try openWith(encoded, &index);
    section.record_offsets = index.offsets;
    section.checkpoint_starts = index.starts;
    section.checkpoints = index.checkpoints[0..index.used];
    return section;
}

const Index = struct {
    offsets: []usize,
    starts: []usize,
    checkpoints: []Checkpoint,
    used: usize = 0,

    fn add(index: *Index, reader: MapReader) DecodeError!void {
        return addCheckpoint(index, reader);
    }
};

fn openWith(encoded: []const u8, index: ?*Index) DecodeError!Section {
    const header = try inspect(encoded);
    const files_start = header_length;
    const maps_start = files_start + header.files_bytes;
    const text_start = maps_start + header.maps_bytes;
    const section = Section{
        .encoded = encoded,
        .file_count = header.file_count,
        .checksum = header.checksum,
        .files_table = encoded[files_start..maps_start],
        .line_maps = encoded[maps_start..text_start],
        .text = encoded[text_start..],
    };
    var cursor = Cursor{ .bytes = section.files_table };
    var previous_path: ?[]const u8 = null;
    var expected_text_offset: usize = 0;
    var expected_map_offset: usize = 0;
    var position: usize = 0;
    while (position < header.file_count) : (position += 1) {
        const record_start = cursor.offset;
        const entry = try readRecord(&cursor, section);
        if (!validPath(entry.path)) return error.InvalidPath;
        if (previous_path) |previous| {
            if (std.mem.order(u8, previous, entry.path) != .lt) return error.UnsortedPaths;
        }
        previous_path = entry.path;
        // Text and maps are laid out in table order without gaps.
        var fields = Cursor{ .bytes = section.files_table, .offset = record_start + 4 };
        if (try fields.readU64() != expected_text_offset) return error.InvalidFileTable;
        _ = try fields.readU64();
        _ = try fields.readU32();
        if (try fields.readU64() != expected_map_offset) return error.InvalidFileTable;
        expected_text_offset += entry.bytes.len;
        if (index) |built| {
            built.offsets[position] = record_start;
            built.starts[position] = built.used;
        }
        const map_length = try validateLineMap(entry, index);
        expected_map_offset += map_length;
    }
    if (index) |built| built.starts[header.file_count] = built.used;
    if (cursor.offset != section.files_table.len) return error.TrailingData;
    if (expected_text_offset != section.text.len) return error.InvalidFileTable;
    if (expected_map_offset != section.line_maps.len) return error.InvalidLineMap;
    return section;
}

fn readRecord(cursor: *Cursor, section: Section) DecodeError!FileEntry {
    const path_length: usize = try cast(try cursor.readU32());
    const text_offset: usize = try cast(try cursor.readU64());
    const text_length: usize = try cast(try cursor.readU64());
    const line_count = try cursor.readU32();
    const map_offset: usize = try cast(try cursor.readU64());
    const digest = try cursor.take(32);
    const encoding_byte = (try cursor.take(4))[0];
    const path = try cursor.take(path_length);
    const text_end = try add(text_offset, text_length);
    if (text_end > section.text.len or map_offset > section.line_maps.len) return error.InvalidFileTable;
    const encoding: Encoding = switch (encoding_byte) {
        0 => .utf8,
        1 => .utf8_bom,
        else => return error.InvalidFileTable,
    };
    var sha: [32]u8 = undefined;
    @memcpy(&sha, digest);
    return .{
        .path = path,
        .bytes = section.text[text_offset..text_end],
        .line_count = line_count,
        .line_map = section.line_maps[map_offset..],
        .sha256 = sha,
        .encoding = encoding,
    };
}

/// Check that a file's line map is exactly the line starts of its own bytes
/// (`lineStarts`, recomputed without allocating) and that the encoding byte
/// matches the BOM. Returns the map's byte length. With `sparse`, records a
/// checkpoint before every `checkpoint_interval`-th varint (the end offset's
/// included when it falls on one).
fn validateLineMap(entry: FileEntry, sparse: ?*Index) DecodeError!usize {
    if ((entry.encoding == .utf8_bom) != std.mem.startsWith(u8, entry.bytes, "\xef\xbb\xbf")) return error.InvalidLineMap;
    var reader = MapReader{ .bytes = entry.line_map };
    var count: u64 = 0;
    var index: usize = if (entry.encoding == .utf8_bom) 3 else 0;
    var line_open = false;
    while (index < entry.bytes.len) {
        if (!line_open) {
            if (sparse) |built| if (count % checkpoint_interval == 0) try built.add(reader);
            if (try reader.next() != index) return error.InvalidLineMap;
            count += 1;
            line_open = true;
        }
        const width = isBreakAt(entry.bytes, index);
        if (width != 0) {
            index += width;
            line_open = false;
        } else index += 1;
    }
    if (sparse) |built| if (count % checkpoint_interval == 0) try built.add(reader);
    if (try reader.next() != entry.bytes.len) return error.InvalidLineMap;
    if (count != entry.line_count) return error.InvalidLineMap;
    return reader.offset;
}

fn addCheckpoint(index: *Index, reader: MapReader) DecodeError!void {
    // The bound in `openIndexed` holds for any map `validateLineMap`
    // accepts; a map that would overflow it is not one.
    if (index.used == index.checkpoints.len) return error.InvalidLineMap;
    index.checkpoints[index.used] = .{ .map_offset = reader.offset, .value = reader.value };
    index.used += 1;
}

/// Absolute offsets from a delta-coded LEB128 line map.
const MapReader = struct {
    bytes: []const u8,
    offset: usize = 0,
    value: u64 = 0,
    /// Varints decoded so far (the sparse index's test counts them).
    decoded: usize = 0,

    fn next(reader: *MapReader) DecodeError!u64 {
        reader.decoded += 1;
        var delta: u64 = 0;
        var shift: u7 = 0;
        while (true) {
            if (reader.offset >= reader.bytes.len) return error.InvalidLineMap;
            const byte = reader.bytes[reader.offset];
            reader.offset += 1;
            if (shift > 63) return error.InvalidLineMap;
            delta |= @as(u64, byte & 0x7f) << @intCast(shift);
            if (byte & 0x80 == 0) break;
            shift += 7;
        }
        reader.value = std.math.add(u64, reader.value, delta) catch return error.InvalidLineMap;
        return reader.value;
    }
};

/// A reader positioned so that its next `next()` returns the start of
/// `line` (1-based; `line_count + 1` is the end offset): from the nearest
/// checkpoint at or before it when the file has a sparse index, else from
/// line 1. Returns the line the reader will produce next.
fn seek(entry: FileEntry, line: u32, reader: *MapReader) u32 {
    const varint = line - 1;
    if (entry.checkpoints.len == 0) {
        reader.* = .{ .bytes = entry.line_map, .decoded = reader.decoded };
        return 1;
    }
    const block = varint / checkpoint_interval;
    const checkpoint = entry.checkpoints[block];
    reader.* = .{ .bytes = entry.line_map, .offset = checkpoint.map_offset, .value = checkpoint.value, .decoded = reader.decoded };
    return block * checkpoint_interval + 1;
}

const LineOffsets = struct { first: usize, stop: usize, decoded: usize };

/// Byte offsets of the starts of lines `first` and `stop` (1-based; `stop`
/// may be `line_count + 1`, the end of the file; `first <= stop`).
fn lineOffsets(entry: FileEntry, first: u32, stop: u32) LineOffsets {
    var reader = MapReader{ .bytes = entry.line_map };
    var line = seek(entry, first, &reader);
    while (line < first) : (line += 1) _ = reader.next() catch unreachable; // validated by `open`
    const first_offset = reader.next() catch unreachable;
    line += 1;
    if (stop == first) return .{ .first = @intCast(first_offset), .stop = @intCast(first_offset), .decoded = reader.decoded };
    // Jump again when `stop` lies in a later block than the reader.
    if (entry.checkpoints.len != 0 and (stop - 1) / checkpoint_interval > (line - 1) / checkpoint_interval) line = seek(entry, stop, &reader);
    while (line < stop) : (line += 1) _ = reader.next() catch unreachable;
    const stop_offset = reader.next() catch unreachable;
    return .{ .first = @intCast(first_offset), .stop = @intCast(stop_offset), .decoded = reader.decoded };
}

pub const Span = struct {
    start_line: u32,
    end_line: u32,
    text: []const u8,
    context_before: []const u8,
    context_after: []const u8,
    sha256: [32]u8,
};

pub const Code = enum {
    invalid_argument,
    not_found,
    capacity,

    /// The C ABI's `SS_ERR_*` value for this refusal (`abi.zig`).
    pub fn ssError(code: Code) i64 {
        return switch (code) {
            .invalid_argument => -1,
            .capacity => -4,
            .not_found => -6,
        };
    }

    /// The `SS_ERR_*` name, as the C ABI's `ss_last_error()` spells it (S3-T4).
    pub fn ssName(code: Code) []const u8 {
        return switch (code) {
            .invalid_argument => "SS_ERR_INVALID_ARGUMENT",
            .capacity => "SS_ERR_CAPACITY",
            .not_found => "SS_ERR_NOT_FOUND",
        };
    }
};

pub const Failure = struct { code: Code, message: []const u8 };

pub const SpanResult = union(enum) {
    ok: Span,
    failed: Failure,
};

/// `read_span` (CAP-19 FR-22): lines `start_line..end_line` (1-based,
/// inclusive; `end_line` is clamped to the last line) plus up to
/// `context_lines` (≤ 20) on each side, byte for byte. Refused with
/// `capacity` when the lines including context exceed 400 or the bytes
/// 256 KiB, and with `capacity` "re-index required: source absent" when the
/// generation has no source section. `allocator` only formats messages.
pub fn readSpan(
    allocator: std.mem.Allocator,
    section: ?Section,
    path: []const u8,
    start_line: u32,
    end_line: u32,
    context_lines: u32,
) !SpanResult {
    const present = section orelse return .{ .failed = .{ .code = .capacity, .message = source_absent_message } };
    if (context_lines > max_context_lines) return fail(allocator, .invalid_argument, "context_lines must be 0..{d}", .{max_context_lines});
    const entry = present.find(path) orelse return fail(allocator, .not_found, "not indexed or not retained: {s}", .{path});
    if (start_line < 1 or end_line < start_line) return fail(allocator, .invalid_argument, "need 1 <= start_line <= end_line", .{});
    if (start_line > entry.line_count) return fail(allocator, .invalid_argument, "start_line {d} is past the last line {d}", .{ start_line, entry.line_count });
    const last_line = @min(end_line, entry.line_count);
    const first = if (start_line > context_lines) start_line - context_lines else 1;
    const last = @min(entry.line_count, last_line + context_lines);
    const lines: usize = last - first + 1;
    const outer = lineOffsets(entry, first, last + 1);
    const size = outer.stop - outer.first;
    if (lines > max_span_lines or size > max_span_bytes) {
        return fail(allocator, .capacity, "span of {d} lines and {d} bytes is over the {d}-line or {d}-byte limit", .{ lines, size, max_span_lines, max_span_bytes });
    }
    const inner = lineOffsets(entry, start_line, last_line + 1);
    const text = entry.bytes[inner.first..inner.stop];
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    return .{ .ok = .{
        .start_line = start_line,
        .end_line = last_line,
        .text = text,
        .context_before = entry.bytes[outer.first..inner.first],
        .context_after = entry.bytes[inner.stop..outer.stop],
        .sha256 = digest,
    } };
}

fn fail(allocator: std.mem.Allocator, code: Code, comptime format: []const u8, args: anytype) !SpanResult {
    return .{ .failed = .{ .code = code, .message = try std.fmt.allocPrint(allocator, format, args) } };
}

/// The §8 `read_span` result object for a successful span.
pub fn writeSpanJson(json: *std.json.Stringify, span: Span) !void {
    try json.beginObject();
    try writeSpanFields(json, span);
    try json.endObject();
}

/// `writeSpanJson`'s fields without the braces (S3-T4, `ops.zig`).
pub fn writeSpanFields(json: *std.json.Stringify, span: Span) !void {
    try json.objectField("start_line");
    try json.write(span.start_line);
    try json.objectField("end_line");
    try json.write(span.end_line);
    try json.objectField("text");
    try json.write(span.text);
    try json.objectField("context_before");
    try json.write(span.context_before);
    try json.objectField("context_after");
    try json.write(span.context_after);
    try json.objectField("byte_exact");
    try json.write(true);
    try json.objectField("sha256");
    const hex = std.fmt.bytesToHex(span.sha256, .lower);
    try json.write(&hex);
}

pub const OutlineData = struct {
    chunker: chunker.Kind,
    lines: u32,
    markdown: ?chunker_md.Outline,
};

pub const OutlineResult = union(enum) {
    ok: OutlineData,
    failed: Failure,
};

/// `outline` (S3-T1 ruling 5): for a Markdown file its headings with level,
/// text, line and end line, its front matter range and fields; for any
/// file its line count and chunker. Reads only that file's bytes.
pub fn outline(allocator: std.mem.Allocator, section: ?Section, path: []const u8) !OutlineResult {
    const present = section orelse return .{ .failed = .{ .code = .capacity, .message = source_absent_message } };
    const entry = present.find(path) orelse return .{ .failed = .{
        .code = .not_found,
        .message = try std.fmt.allocPrint(allocator, "not indexed or not retained: {s}", .{path}),
    } };
    const kind = chunker.kindForPath(path);
    if (kind == .md_section) {
        const parsed = try chunker_md.outline(allocator, entry.bytes);
        return .{ .ok = .{ .chunker = kind, .lines = entry.line_count, .markdown = parsed } };
    }
    return .{ .ok = .{ .chunker = kind, .lines = entry.line_count, .markdown = null } };
}

/// The §8 `outline` result object.
pub fn writeOutlineJson(json: *std.json.Stringify, data: OutlineData) !void {
    try json.beginObject();
    try writeOutlineFields(json, data);
    try json.endObject();
}

/// `writeOutlineJson`'s fields without the braces (S3-T4, `ops.zig`).
pub fn writeOutlineFields(json: *std.json.Stringify, data: OutlineData) !void {
    try json.objectField("front_matter");
    const front = if (data.markdown) |markdown| markdown.front_matter else null;
    if (front) |value| {
        try json.beginObject();
        try json.objectField("start_line");
        try json.write(value.start + 1);
        try json.objectField("end_line");
        try json.write(value.end + 1);
        try json.objectField("fields");
        try json.beginObject();
        for (value.fields) |field| {
            try json.objectField(field.key);
            try json.write(field.value);
        }
        try json.endObject();
        if (!value.valid) {
            try json.objectField("raw");
            try json.write(value.raw);
        }
        try json.endObject();
    } else try json.write(null);
    try json.objectField("headings");
    try json.beginArray();
    if (data.markdown) |markdown| {
        for (markdown.headings) |heading| {
            try json.beginObject();
            try json.objectField("level");
            try json.write(heading.level);
            try json.objectField("text");
            try json.write(heading.text);
            try json.objectField("line");
            try json.write(heading.line);
            try json.objectField("end_line");
            try json.write(heading.end_line);
            try json.endObject();
        }
    }
    try json.endArray();
    try json.objectField("lines");
    try json.write(data.lines);
    try json.objectField("chunker");
    try json.write(data.chunker.id());
}

fn checksumOf(header_without_checksum: []const u8, payload: []const u8) u64 {
    var value: u64 = 14_695_981_039_346_656_037;
    for (header_without_checksum) |byte| {
        value ^= byte;
        value *%= 1_099_511_628_211;
    }
    for (payload) |byte| {
        value ^= byte;
        value *%= 1_099_511_628_211;
    }
    return value;
}

fn add(left: usize, right: usize) DecodeError!usize {
    return std.math.add(usize, left, right) catch error.SizeOverflow;
}

fn cast(value: anytype) DecodeError!usize {
    return std.math.cast(usize, value) orelse error.SizeOverflow;
}

fn putU16(out: []u8, offset: *usize, value: u16) void {
    out[offset.*] = @truncate(value);
    out[offset.* + 1] = @truncate(value >> 8);
    offset.* += 2;
}

fn putU32(out: []u8, offset: *usize, value: u32) void {
    inline for (0..4) |index| out[offset.* + index] = @truncate(value >> @intCast(index * 8));
    offset.* += 4;
}

fn putU64(out: []u8, offset: *usize, value: u64) void {
    inline for (0..8) |index| out[offset.* + index] = @truncate(value >> @intCast(index * 8));
    offset.* += 8;
}

const Cursor = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn take(cursor: *Cursor, length: usize) DecodeError![]const u8 {
        const end = try add(cursor.offset, length);
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

// ------------------------------------------------------------------ tests ---

fn spanOk(result: SpanResult) !Span {
    return switch (result) {
        .ok => |span| span,
        .failed => |failure| {
            std.debug.print("unexpected failure: {s}\n", .{failure.message});
            return error.TestUnexpectedResult;
        },
    };
}

test "source section round trip keeps original bytes, hashes and line counts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const files = [_]InputFile{
        .{ .path = "a/crlf.md", .bytes = "one\r\ntwo\r\nthree\r\n" },
        .{ .path = "a/lf.txt", .bytes = "one\ntwo\nthree" },
        .{ .path = "b/bom.md", .bytes = "\xef\xbb\xbf# T\nbody\n" },
        .{ .path = "b/cr.md", .bytes = "one\rtwo\rthree\r" },
        .{ .path = "c/empty.txt", .bytes = "" },
    };
    const encoded = try encode(arena, &files);
    const section = try open(encoded);
    try std.testing.expectEqual(@as(usize, 5), section.file_count);
    for (files, 0..) |input, index| {
        const entry = section.find(input.path).?;
        try std.testing.expectEqualStrings(input.bytes, entry.bytes);
        try std.testing.expectEqualStrings(input.path, section.file(index).path);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(input.bytes, &digest, .{});
        try std.testing.expectEqualSlices(u8, &digest, &entry.sha256);
    }
    try std.testing.expectEqual(@as(u32, 3), section.find("a/crlf.md").?.line_count);
    try std.testing.expectEqual(@as(u32, 3), section.find("a/lf.txt").?.line_count);
    try std.testing.expectEqual(@as(u32, 2), section.find("b/bom.md").?.line_count);
    try std.testing.expectEqual(Encoding.utf8_bom, section.find("b/bom.md").?.encoding);
    try std.testing.expectEqual(@as(u32, 3), section.find("b/cr.md").?.line_count);
    try std.testing.expectEqual(@as(u32, 0), section.find("c/empty.txt").?.line_count);
    try std.testing.expect(section.find("a/missing.md") == null);
}

test "line maps follow CRLF, CR, LF and the other splitlines terminators" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var starts = std.ArrayList(u64).empty;
    try lineStarts(arena, "a\r\nb\rc\nd\x0be\x0cf\x1cg\xc2\x85h\xe2\x80\xa8i\xe2\x80\xa9j", &starts);
    try std.testing.expectEqualSlices(u64, &.{ 0, 3, 5, 7, 9, 11, 13, 16, 20, 24, 25 }, starts.items);
    starts.clearRetainingCapacity();
    try lineStarts(arena, "\xef\xbb\xbfx\n\ny", &starts);
    try std.testing.expectEqualSlices(u64, &.{ 3, 5, 6, 7 }, starts.items);
    starts.clearRetainingCapacity();
    try lineStarts(arena, "", &starts);
    try std.testing.expectEqualSlices(u64, &.{0}, starts.items);
}

test "read_span is byte exact with terminators, context and clamping" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const files = [_]InputFile{
        .{ .path = "crlf.md", .bytes = "l1\r\nl2\r\nl3\r\nl4\r\n" },
        .{ .path = "tail.txt", .bytes = "l1\nl2\nl3" },
    };
    const section = try openIndexed(arena, try encode(arena, &files));
    const crlf = try spanOk(try readSpan(arena, section, "crlf.md", 2, 3, 1));
    try std.testing.expectEqualStrings("l2\r\nl3\r\n", crlf.text);
    try std.testing.expectEqualStrings("l1\r\n", crlf.context_before);
    try std.testing.expectEqualStrings("l4\r\n", crlf.context_after);
    const tail = try spanOk(try readSpan(arena, section, "tail.txt", 2, 9, 0));
    try std.testing.expectEqualStrings("l2\nl3", tail.text);
    try std.testing.expectEqual(@as(u32, 3), tail.end_line);

    try std.testing.expectEqual(Code.invalid_argument, (try readSpan(arena, section, "tail.txt", 4, 4, 0)).failed.code);
    try std.testing.expectEqual(Code.invalid_argument, (try readSpan(arena, section, "tail.txt", 2, 1, 0)).failed.code);
    try std.testing.expectEqual(Code.invalid_argument, (try readSpan(arena, section, "tail.txt", 1, 1, 21)).failed.code);
    try std.testing.expectEqual(Code.not_found, (try readSpan(arena, section, "nope.txt", 1, 1, 0)).failed.code);
    const absent = (try readSpan(arena, null, "tail.txt", 1, 1, 0)).failed;
    try std.testing.expectEqual(Code.capacity, absent.code);
    try std.testing.expectEqualStrings("re-index required: source absent", absent.message);
    try std.testing.expectEqual(@as(i64, -4), absent.code.ssError());
}

test "read_span caps: 400 lines including context and 256 KiB" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var many = std.ArrayList(u8).empty;
    for (0..1000) |_| try many.appendSlice(arena, "x\n");
    var wide = std.ArrayList(u8).empty;
    for (0..3) |_| {
        try wide.appendNTimes(arena, 'w', 100 * 1024);
        try wide.append(arena, '\n');
    }
    const files = [_]InputFile{ .{ .path = "many.txt", .bytes = many.items }, .{ .path = "wide.txt", .bytes = wide.items } };
    const section = try open(try encode(arena, &files));
    _ = try spanOk(try readSpan(arena, section, "many.txt", 1, 400, 0));
    _ = try spanOk(try readSpan(arena, section, "many.txt", 21, 380, 20));
    const over = (try readSpan(arena, section, "many.txt", 21, 381, 20)).failed;
    try std.testing.expectEqual(Code.capacity, over.code);
    try std.testing.expect(std.mem.indexOf(u8, over.message, "401 lines") != null);
    try std.testing.expectEqual(Code.capacity, (try readSpan(arena, section, "many.txt", 1, 401, 0)).failed.code);
    _ = try spanOk(try readSpan(arena, section, "wide.txt", 1, 2, 0));
    try std.testing.expectEqual(Code.capacity, (try readSpan(arena, section, "wide.txt", 1, 3, 0)).failed.code);
    try std.testing.expectEqual(Code.capacity, (try readSpan(arena, section, "wide.txt", 2, 2, 1)).failed.code);
}

test "source section rejects corruption, unsorted paths and bad line maps" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const files = [_]InputFile{ .{ .path = "a.md", .bytes = "# A\nx\n" }, .{ .path = "b.md", .bytes = "y\n" } };
    const encoded = try encode(arena, &files);
    for ([_]usize{ 12, header_length + 10, encoded.len - 1 }) |at| {
        const copy = try arena.dupe(u8, encoded);
        copy[at] ^= 0x01;
        try std.testing.expectError(error.ChecksumMismatch, open(copy));
    }
    try std.testing.expectError(error.Truncated, open(encoded[0 .. encoded.len - 1]));
    const unsorted = [_]InputFile{ files[1], files[0] };
    try std.testing.expectError(error.UnsortedPaths, encode(arena, &unsorted));
    try std.testing.expectError(error.InvalidPath, encode(arena, &.{.{ .path = "../x", .bytes = "" }}));
    try std.testing.expectError(error.InvalidUtf8, encode(arena, &.{.{ .path = "x", .bytes = "\xff" }}));
}

test "outline reports headings for Markdown and only lines for other files" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const files = [_]InputFile{
        .{ .path = "n.md", .bytes = "---\ntitle: N\n---\n# One\na\n## Two\nb\n" },
        .{ .path = "t.txt", .bytes = "# not markdown\n" },
    };
    const section = try open(try encode(arena, &files));
    const md = (try outline(arena, section, "n.md")).ok;
    try std.testing.expectEqual(@as(u32, 7), md.lines);
    try std.testing.expectEqual(@as(usize, 2), md.markdown.?.headings.len);
    var out: std.Io.Writer.Allocating = .init(arena);
    var json = std.json.Stringify{ .writer = &out.writer };
    try writeOutlineJson(&json, md);
    try std.testing.expectEqualStrings(
        "{\"front_matter\":{\"start_line\":1,\"end_line\":3,\"fields\":{\"title\":\"N\"}},\"headings\":[{\"level\":1,\"text\":\"One\",\"line\":4,\"end_line\":7},{\"level\":2,\"text\":\"Two\",\"line\":6,\"end_line\":7}],\"lines\":7,\"chunker\":\"md-section-v1\"}",
        out.written(),
    );
    const txt = (try outline(arena, section, "t.txt")).ok;
    try std.testing.expect(txt.markdown == null);
    try std.testing.expectEqual(chunker.Kind.line_window, txt.chunker);
    const absent = (try outline(arena, null, "n.md")).failed;
    try std.testing.expectEqualStrings(source_absent_message, absent.message);
}

test "indexed and linear lookups agree" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var files = std.ArrayList(InputFile).empty;
    for (0..50) |n| try files.append(arena, .{ .path = try std.fmt.allocPrint(arena, "d/{d:0>3}.txt", .{n}), .bytes = try std.fmt.allocPrint(arena, "file {d}\n", .{n}) });
    const encoded = try encode(arena, files.items);
    const linear = try open(encoded);
    const indexed = try openIndexed(arena, encoded);
    for (files.items) |input| {
        try std.testing.expectEqualStrings(input.bytes, linear.find(input.path).?.bytes);
        try std.testing.expectEqualStrings(input.bytes, indexed.find(input.path).?.bytes);
    }
    try std.testing.expect(indexed.find("d/0505.txt") == null);
    try std.testing.expect(indexed.find("a") == null);
    try std.testing.expect(indexed.find("z") == null);
}

test "S3-T4: the sparse line index finds any line by decoding at most one block" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // 15,500 lines of varying width (the S3-T1 deep-file case), one CRLF
    // stretch, no final newline; plus a file of exactly 512 lines.
    var long = std.ArrayList(u8).empty;
    for (0..15_500) |n| {
        try long.appendNTimes(arena, 'a' + @as(u8, @intCast(n % 26)), n % 37);
        if (n + 1 == 15_500) break;
        try long.appendSlice(arena, if (n >= 7000 and n < 7100) "\r\n" else "\n");
    }
    var exact = std.ArrayList(u8).empty;
    for (0..512) |_| try exact.appendSlice(arena, "x\n");
    const files = [_]InputFile{ .{ .path = "deep.txt", .bytes = long.items }, .{ .path = "exact.txt", .bytes = exact.items } };
    const encoded = try encode(arena, &files);
    const indexed = try openIndexed(arena, encoded);
    const linear = try open(encoded);
    for (files) |input| {
        var starts = std.ArrayList(u64).empty;
        try lineStarts(arena, input.bytes, &starts);
        const fast = indexed.find(input.path).?;
        const slow = linear.find(input.path).?;
        try std.testing.expectEqual(@as(usize, fast.line_count / checkpoint_interval + 1), fast.checkpoints.len);
        try std.testing.expectEqual(@as(usize, 0), slow.checkpoints.len);
        var line: u32 = 1;
        while (line <= fast.line_count) : (line += 1) {
            for ([_]u32{ line, @min(line + 1, fast.line_count + 1), @min(line + 300, fast.line_count + 1), fast.line_count + 1 }) |stop| {
                const got = lineOffsets(fast, line, stop);
                try std.testing.expectEqual(starts.items[line - 1], got.first);
                try std.testing.expectEqual(starts.items[stop - 1], got.stop);
                // At most one partial block per looked-up line.
                try std.testing.expect(got.decoded <= 2 * checkpoint_interval);
                const old = lineOffsets(slow, line, stop);
                try std.testing.expectEqual(old.first, got.first);
                try std.testing.expectEqual(old.stop, got.stop);
            }
        }
    }
    // Without the index, a line deep in the file decodes every varint before it.
    try std.testing.expectEqual(@as(usize, 15_401), lineOffsets(linear.find("deep.txt").?, 15_400, 15_401).decoded);
    try std.testing.expect(lineOffsets(indexed.find("deep.txt").?, 15_400, 15_401).decoded <= checkpoint_interval + 1);
    // The spans themselves are unchanged.
    try std.testing.expectEqualStrings(
        (try spanOk(try readSpan(arena, linear, "deep.txt", 15_390, 15_500, 5))).text,
        (try spanOk(try readSpan(arena, indexed, "deep.txt", 15_390, 15_500, 5))).text,
    );
    try std.testing.expectEqualStrings(indexed.file(0).path, "deep.txt");
    try std.testing.expectEqual(@as(usize, 3), indexed.file(1).checkpoints.len);
}
