//! Source section v2 (S6-T7, `HYBSRC02`, `docs/documents-v5-source-v2-format.md`):
//! no paths, one record per retained file bound by order to the documents
//! section's file table (record v5), each with the file's SHA-256, flags
//! (BOM, kept whole), length, line count and, unless kept whole, a recipe:
//! one varint per chunk (an even value a gap of v/2 residual bytes before
//! the whole chunk, an odd one an overlap of (v+1)/2 bytes). Line maps as
//! v1's. A residual area of each file's gaps and tail, or all its bytes
//! when kept whole. `read_span`/`outline` rebuild a file from its chunks'
//! text (resident with the documents) and its residual run, and check the
//! SHA-256 at every read (`fileBytes`).
const std = @import("std");
const builtin = @import("builtin");
const checksum_mod = @import("checksum.zig");
const hybrid = @import("hybrid.zig");
const segment = @import("segment.zig");
const segment_v5 = @import("segment_v5.zig");
const source = @import("source.zig");

pub const magic = "HYBSRC02";
pub const version: u16 = 2;

const flag_bom: u32 = 1;
const flag_whole: u32 = 2;
const sha_bytes: usize = 32;

/// The documents section a v2 source section is bound to: its bytes (the
/// file table is walked again at the source's first use) and its decoded
/// records (the chunk text a file is rebuilt from).
pub const Bound = struct {
    documents_encoded: []const u8,
    documents: []const hybrid.Document,
};

/// One retained file, as the first-use walk found it.
pub const File = struct {
    path: []const u8,
    /// Its records in `State.documents`.
    first: u32,
    chunks: u32,
    /// Offsets of its record (records area), its line map (maps area) and
    /// its residual run (residual area).
    record: usize,
    map: usize,
    residual: u64,
};

pub const State = struct {
    files: []const File,
    documents: []const hybrid.Document,
};

const Records = segment_v5.Reader(source.DecodeError, error.InvalidFileTable);

/// A record's fields. `recipe` is the raw varints (`chunks` of them).
pub const Parsed = struct {
    sha256: [32]u8,
    bom: bool,
    whole: bool,
    length: u64,
    line_count: u32,
    recipe: []const u8,
    /// Offset just past the record.
    end: usize,
};

/// The record at `at` of a file with `chunks` records in the documents.
pub fn parseRecord(records: []const u8, at: usize, chunks: u32) source.DecodeError!Parsed {
    var r = Records{ .bytes = records, .at = at };
    var parsed: Parsed = undefined;
    @memcpy(&parsed.sha256, try r.take(sha_bytes));
    const flags = try r.varint32();
    if (flags & ~(flag_bom | flag_whole) != 0) return error.InvalidFileTable;
    parsed.bom = flags & flag_bom != 0;
    parsed.whole = flags & flag_whole != 0;
    parsed.length = try r.varint64(10);
    parsed.line_count = try r.varint32();
    if (chunks == 0 and !parsed.whole) return error.InvalidFileTable;
    parsed.recipe = &.{};
    if (!parsed.whole) {
        if (try r.varint32() != chunks) return error.InvalidFileTable;
        const recipe_start = r.at;
        for (0..chunks) |_| _ = try r.varint32();
        parsed.recipe = records[recipe_start..r.at];
    }
    parsed.end = r.at;
    return parsed;
}

/// S6-T9: the SHA-256 and text length of the record at `at` (one the walk
/// validated), without its recipe: what a `HYBSTA03` reference reads.
pub const Head = struct { sha256: [32]u8, length: u64 };

pub fn recordHead(records: []const u8, at: usize) source.DecodeError!Head {
    var r = Records{ .bytes = records, .at = at };
    var head: Head = undefined;
    @memcpy(&head.sha256, try r.take(sha_bytes));
    _ = try r.varint32();
    head.length = try r.varint64(10);
    return head;
}

/// The residual length of a rebuilt file: its recipe walked over its
/// chunks' lengths (an overlap longer than the bytes emitted, or a
/// position past the file's length, is `InvalidFileTable`).
fn residualLength(parsed: Parsed, chunks: []const hybrid.Document) source.DecodeError!u64 {
    if (parsed.whole) return parsed.length;
    var r = Records{ .bytes = parsed.recipe, .at = 0 };
    var pos: u64 = 0;
    var gaps: u64 = 0;
    for (chunks) |chunk| {
        const v = try r.varint32();
        const length: u64 = chunk.text.len;
        if (v & 1 == 0) {
            gaps += v / 2;
            pos += v / 2 + length;
        } else {
            const k: u64 = (@as(u64, v) + 1) / 2;
            if (k > pos) return error.InvalidFileTable;
            if (k < length) pos += length - k;
        }
        if (pos > parsed.length) return error.InvalidFileTable;
    }
    return gaps + (parsed.length - pos);
}

/// The first-use walk of a v2 section whose areas `section` names
/// (`files_table` the records area, `line_maps`, `text_length` the residual
/// bytes): every rule of the format document's source validation, steps
/// 3 to 6. The per-file array comes from `allocator`.
pub fn walk(allocator: std.mem.Allocator, section: *source.Section, bound: Bound) (source.DecodeError || std.mem.Allocator.Error)!void {
    const documents_header = segment_v5.headerFields(bound.documents_encoded) catch return error.SourceFileCountMismatch;
    const retained = segment_v5.retainedFiles(allocator, bound.documents_encoded, documents_header, bound.documents) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SourceFileCountMismatch,
    };
    if (retained.len != section.file_count) return error.SourceFileCountMismatch;
    if (section.files_table.len / 35 < section.file_count or section.line_maps.len < section.file_count) return error.InvalidFileTable;
    const files = try allocator.alloc(File, retained.len);
    var at: usize = 0;
    var map_at: usize = 0;
    var residual_at: u64 = 0;
    for (retained, files) |rf, *file| {
        if (!source.validPath(rf.path)) return error.InvalidPath;
        const parsed = try parseRecord(section.files_table, at, rf.chunks);
        const residual = try residualLength(parsed, bound.documents[rf.first..][0..rf.chunks]);
        const map_end = source.varintsEnd(section.line_maps, map_at, @as(usize, parsed.line_count) + 1) orelse return error.InvalidLineMap;
        if (residual > section.text_length - residual_at) return error.InvalidFileTable;
        file.* = .{ .path = rf.path, .first = rf.first, .chunks = rf.chunks, .record = at, .map = map_at, .residual = residual_at };
        at = parsed.end;
        map_at = map_end;
        residual_at += residual;
    }
    if (at != section.files_table.len) return error.TrailingData;
    if (map_at != section.line_maps.len) return error.InvalidLineMap;
    if (residual_at != section.text_length) return error.InvalidFileTable;
    const state = try allocator.create(State);
    state.* = .{ .files = files, .documents = bound.documents };
    section.v2 = state;
    section.record_offsets = &.{};
    const words = try allocator.alloc(std.atomic.Value(usize), (files.len + source.word_bits - 1) / source.word_bits);
    @memset(words, .init(0));
    section.checked = words;
}

/// The `index`-th retained file's entry (the walk validated it).
pub fn entry(section: source.Section, index: usize) source.FileEntry {
    const state = section.v2.?;
    const file = state.files[index];
    const parsed = parseRecord(section.files_table, file.record, file.chunks) catch unreachable;
    const chunks = state.documents[file.first..][0..file.chunks];
    const residual = residualLength(parsed, chunks) catch unreachable;
    return .{
        .path = file.path,
        .bytes = &.{},
        .text_offset = @intCast(file.residual),
        .text_length = @intCast(parsed.length),
        .line_map_offset = file.map,
        .line_count = parsed.line_count,
        .line_map = section.line_maps[file.map..],
        .sha256 = parsed.sha256,
        .encoding = if (parsed.bom) .utf8_bom else .utf8,
        .position = index,
        .v2_whole = parsed.whole,
        .v2_recipe = parsed.recipe,
        .v2_residual_length = @intCast(residual),
        .v2_chunks = chunks,
        .v2_record_end = parsed.end,
        .v2_record = file.record,
    };
}

/// Binary search by path (the files are in path order).
pub fn find(section: source.Section, path: []const u8) ?source.FileEntry {
    const files = section.v2.?.files;
    var low: usize = 0;
    var high: usize = files.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (std.mem.order(u8, files[middle].path, path)) {
            .eq => return entry(section, middle),
            .lt => low = middle + 1,
            .gt => high = middle,
        }
    }
    return null;
}

/// A file's bytes rebuilt from its chunks and its residual run (read
/// positionally when the residual area is streamed), checked against the
/// record's length and SHA-256 at every call, and (the first time on the
/// handle) its line map and BOM flag against them.
pub fn fileBytes(section: source.Section, allocator: std.mem.Allocator, file: source.FileEntry) error{OutOfMemory}!source.BytesResult {
    const out = switch (try rebuildChecked(section, allocator, file)) {
        .ok => |bytes| bytes,
        .failed => |failure| return .{ .failed = failure },
    };
    if (!section.mapChecked(file)) {
        if (builtin.is_test) _ = source.test_map_checks.fetchAdd(1, .monotonic);
        var with_bytes = file;
        with_bytes.bytes = out;
        _ = source.validateLineMapPub(with_bytes) catch |err| return source.unavailablePub(allocator, @errorName(err));
        source.markCheckedPub(section, file);
    }
    return .{ .ok = out };
}

/// The rebuild and its length and SHA-256 checks, without the line map's
/// (the writer, which carries a map as it is: `source.carriedRecord`).
pub fn rebuildChecked(section: source.Section, allocator: std.mem.Allocator, file: source.FileEntry) error{OutOfMemory}!source.BytesResult {
    const residual: []const u8 = if (section.text_file) |text| blk: {
        const buffer = try allocator.alloc(u8, file.v2_residual_length);
        const read = text.file.readPositionalAll(text.io, buffer, text.offset + file.text_offset) catch |err| return source.unavailablePub(allocator, @errorName(err));
        if (read != buffer.len) return source.unavailablePub(allocator, "SourceSectionSizeMismatch");
        break :blk buffer;
    } else section.text[file.text_offset..][0..file.v2_residual_length];
    const out = try allocator.alloc(u8, file.text_length);
    const length = rebuildInto(out, residual, file) orelse return source.unavailablePub(allocator, "SourceFileLengthMismatch");
    if (length != out.len) return source.unavailablePub(allocator, "SourceFileLengthMismatch");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(out, &digest, .{});
    if (!std.mem.eql(u8, &digest, &file.sha256)) return source.unavailablePub(allocator, source.sha256_mismatch_name);
    return .{ .ok = out };
}

/// The rebuild: chunks in order with their gaps from `residual`, then the
/// tail. Null when the parts do not fit `out` (a section the walk accepted
/// cannot do that; the guard costs a compare per part).
pub fn rebuildInto(out: []u8, residual: []const u8, file: source.FileEntry) ?usize {
    if (file.v2_whole) {
        if (residual.len != out.len) return null;
        @memcpy(out, residual);
        return out.len;
    }
    var r = Records{ .bytes = file.v2_recipe, .at = 0 };
    var n: usize = 0;
    var at: usize = 0;
    for (file.v2_chunks) |chunk| {
        const v = r.varint32() catch return null;
        const text = chunk.text;
        if (v & 1 == 0) {
            const gap: usize = v / 2;
            if (gap > residual.len - at or gap + text.len > out.len - n) return null;
            @memcpy(out[n..][0..gap], residual[at..][0..gap]);
            at += gap;
            n += gap;
            @memcpy(out[n..][0..text.len], text);
            n += text.len;
        } else {
            const k: usize = (@as(usize, v) + 1) / 2;
            if (k < text.len) {
                if (text.len - k > out.len - n) return null;
                @memcpy(out[n..][0 .. text.len - k], text[k..]);
                n += text.len - k;
            }
        }
    }
    const tail = residual.len - at;
    if (tail > out.len - n) return null;
    @memcpy(out[n..][0..tail], residual[at..]);
    return n + tail;
}

// ------------------------------------------------------------------ writer

/// What a carried file (bytes and chunks unchanged) copies from the
/// previous v2 section: its record, line map and residual run, byte for
/// byte.
pub const Carried = struct {
    record: []const u8,
    line_map: []const u8,
    residual: []const u8,
    chunks: u32,
};

/// `file`'s record, map and residual run from a resident v2 section (the
/// writer's open of its previous generation).
pub fn carried(section: source.Section, file: source.FileEntry) source.DecodeError!Carried {
    const map_end = source.varintsEnd(file.line_map, 0, @as(usize, file.line_count) + 1) orelse return error.InvalidLineMap;
    return .{
        .record = section.files_table[file.v2_record..file.v2_record_end],
        .line_map = file.line_map[0..map_end],
        .residual = section.text[file.text_offset..][0..file.v2_residual_length],
        .chunks = @intCast(file.v2_chunks.len),
    };
}

pub const EncodeError = source.EncodeError || error{CarriedRecordMismatch};

/// Encode a v2 section. `files` strictly sorted by path, each with its
/// records `documents[first_chunk..][0..chunk_count]` (the documents the
/// generation's v5 section holds, in its order). A file with `carried_v2`
/// copies its record, map and residual run; any other is located: each
/// chunk's text found in the file's bytes inside its own lines (the first
/// occurrence from the start of its start line that ends by the end of its
/// end line), the gaps and tail kept as residual bytes, or the whole file
/// kept when a chunk is not found or a recipe value would not fit a u32.
pub fn encodeMarked(allocator: std.mem.Allocator, files: []const source.InputFile, documents: []const hybrid.Document, marks: anytype) EncodeError![]u8 {
    if (files.len > std.math.maxInt(u32)) return error.FieldTooLarge;
    var records = std.ArrayList(u8).empty;
    defer records.deinit(allocator);
    var maps = std.ArrayList(u8).empty;
    defer maps.deinit(allocator);
    var runs = std.ArrayList([]const u8).empty;
    defer runs.deinit(allocator);
    var starts = std.ArrayList(u64).empty;
    defer starts.deinit(allocator);
    var recipe = std.ArrayList(u32).empty;
    defer recipe.deinit(allocator);
    var residual_bytes: usize = 0;
    var scratch: [10]u8 = undefined;

    for (files, 0..) |input, position| {
        if (!source.validPath(input.path)) return error.InvalidPath;
        if (position > 0 and std.mem.order(u8, files[position - 1].path, input.path) != .lt) return error.UnsortedPaths;
        if (input.carried_v2) |c| {
            if (c.chunks != input.chunk_count) return error.CarriedRecordMismatch;
            try records.appendSlice(allocator, c.record);
            try maps.appendSlice(allocator, c.line_map);
            if (c.residual.len != 0) try runs.append(allocator, c.residual);
            residual_bytes += c.residual.len;
            continue;
        }
        const bytes = input.bytes;
        // UTF-8, the line starts and the map (`source.encodeMarked`'s rules).
        starts.clearRetainingCapacity();
        var line_count: u32 = undefined;
        if (input.carried) |record| {
            if (!record.bytes_from_section and !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
            try maps.appendSlice(allocator, record.line_map);
            line_count = record.line_count;
            var reader = source.MapReaderPub{ .bytes = record.line_map };
            for (0..@as(usize, line_count) + 1) |_| try starts.append(allocator, reader.next() catch return error.InvalidUtf8);
        } else {
            if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
            try source.lineStarts(allocator, bytes, &starts);
            if (starts.items.len - 1 > std.math.maxInt(u32)) return error.FieldTooLarge;
            line_count = @intCast(starts.items.len - 1);
            var previous: u64 = 0;
            for (starts.items) |offset| {
                var at: usize = 0;
                segment_v5.putVarint(&scratch, &at, offset - previous);
                try maps.appendSlice(allocator, scratch[0..at]);
                previous = offset;
            }
        }
        var digest: [32]u8 = undefined;
        if (input.carried) |record| digest = record.sha256 else std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const bom = if (input.carried) |record| record.encoding == .utf8_bom else std.mem.startsWith(u8, bytes, "\xef\xbb\xbf");
        const chunks = documents[input.first_chunk..][0..input.chunk_count];
        const whole = !try locate(allocator, bytes, starts.items, line_count, chunks, &recipe);
        try records.appendSlice(allocator, &digest);
        var flags: u32 = 0;
        if (bom) flags |= flag_bom;
        if (whole) flags |= flag_whole;
        try appendVarint(allocator, &records, flags);
        try appendVarint(allocator, &records, bytes.len);
        try appendVarint(allocator, &records, line_count);
        if (whole) {
            if (bytes.len != 0) try runs.append(allocator, bytes);
            residual_bytes += bytes.len;
            continue;
        }
        try appendVarint(allocator, &records, chunks.len);
        var pos: usize = 0;
        for (recipe.items, chunks) |v, chunk| {
            try appendVarint(allocator, &records, v);
            if (v & 1 == 0) {
                const gap: usize = v / 2;
                if (gap != 0) try runs.append(allocator, bytes[pos..][0..gap]);
                residual_bytes += gap;
                pos += gap + chunk.text.len;
            } else {
                const k: usize = (@as(usize, v) + 1) / 2;
                if (k < chunk.text.len) pos += chunk.text.len - k;
            }
        }
        if (pos < bytes.len) try runs.append(allocator, bytes[pos..]);
        residual_bytes += bytes.len - pos;
    }
    marks.mark("source_line_maps");
    marks.mark("source_sha256");

    const total = source.header_length + records.items.len + maps.items.len + residual_bytes;
    const out = try allocator.alloc(u8, total);
    @memcpy(out[0..8], magic);
    std.mem.writeInt(u16, out[8..10], version, .little);
    std.mem.writeInt(u16, out[10..12], checksum_mod.flag_xxh3, .little);
    std.mem.writeInt(u32, out[12..16], @intCast(files.len), .little);
    std.mem.writeInt(u64, out[16..24], records.items.len, .little);
    std.mem.writeInt(u64, out[24..32], maps.items.len, .little);
    std.mem.writeInt(u64, out[32..40], residual_bytes, .little);
    var at: usize = source.header_length;
    @memcpy(out[at..][0..records.items.len], records.items);
    at += records.items.len;
    @memcpy(out[at..][0..maps.items.len], maps.items);
    at += maps.items.len;
    for (runs.items) |run| {
        @memcpy(out[at..][0..run.len], run);
        at += run.len;
    }
    std.debug.assert(at == total);
    marks.mark("source_copy");
    std.mem.writeInt(u64, out[40..48], checksum_mod.compute(.xxh3_64, out[0..40], out[source.header_length..]), .little);
    marks.mark("source_checksum");
    return out;
}

fn appendVarint(allocator: std.mem.Allocator, list: *std.ArrayList(u8), value: u64) error{OutOfMemory}!void {
    var buffer: [10]u8 = undefined;
    var at: usize = 0;
    segment_v5.putVarint(&buffer, &at, value);
    try list.appendSlice(allocator, buffer[0..at]);
}

/// Each chunk's position in `bytes` and the recipe from them, into
/// `recipe`. False (the file is kept whole) when a chunk is not found
/// inside its own lines or a value would not fit a u32. A file with no
/// chunk is kept whole.
fn locate(allocator: std.mem.Allocator, bytes: []const u8, starts: []const u64, line_count: u32, chunks: []const hybrid.Document, recipe: *std.ArrayList(u32)) error{OutOfMemory}!bool {
    recipe.clearRetainingCapacity();
    if (chunks.len == 0) return false;
    var pos: usize = 0;
    for (chunks) |chunk| {
        if (chunk.start_line == 0 or chunk.start_line > line_count) return false;
        const lo: usize = @intCast(starts[chunk.start_line - 1]);
        const hi: usize = @intCast(starts[@min(chunk.end_line, line_count)]);
        if (hi < lo or chunk.text.len > hi - lo) return false;
        const found = std.mem.indexOfPos(u8, bytes[0..hi], lo, chunk.text) orelse return false;
        const value: u64 = if (found >= pos) 2 * @as(u64, found - pos) else 2 * @as(u64, pos - found) - 1;
        if (value > std.math.maxInt(u32)) return false;
        try recipe.append(allocator, @intCast(value));
        pos = @max(pos, found + chunk.text.len);
    }
    return true;
}
