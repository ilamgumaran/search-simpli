//! S6-T8: section 5 of `HYBLEX04` at one byte per token
//! (`docs/lexical-segment-format-v4.md`).
//!
//! - The format document's worked example, byte for byte.
//! - The boundary values through the real tokenizer, writer and reader:
//!   field values 14, 15 and 16 in the gap field (gaps 7, -8 and 8: a
//!   negative gap comes from an NFC region holding two tokens) and in the
//!   length field; a chunk with no token and one with one; highlights read
//!   from section 5 equal highlights re-tokenized from the text.
//! - Every validity rule of section 5, violated with the checksum
//!   recomputed, refused with that rule's own error, at the open (eager
//!   validation) and lazily (the first `find`'s validation), each at the
//!   last element where the rule has one; rule 11 (an offset past the text)
//!   through a published index and `find`, on a one-token chunk and (S6-T10)
//!   in the first, a middle and the last span of a five-token chunk.
//! - The manifest's bit 7 binds `HYBLEX04` both ways.
const std = @import("std");
const analysis = @import("analysis.zig");
const checksum = @import("checksum.zig");
const cli = @import("cli.zig");
const find = @import("find.zig");
const hybrid = @import("hybrid.zig");
const indexer = @import("indexer.zig");
const lexical_build = @import("lexical_build.zig");
const lexical_segment = @import("lexical_segment.zig");
const manifest = @import("manifest.zig");
const ops = @import("ops.zig");
const postings = @import("postings.zig");
const publication = @import("publication.zig");
const snapshot_open = @import("snapshot_open.zig");

const io = std.testing.io;

fn tokensOf(a: std.mem.Allocator, texts: []const []const u8) ![]const []const analysis.PositionedToken {
    const lists = try a.alloc([]const analysis.PositionedToken, texts.len);
    for (texts, lists) |text, *list| list.* = try indexer.tokenizePositioned(a, .v2, text);
    return lists;
}

fn buildOf(a: std.mem.Allocator, texts: []const []const u8) !postings.Index {
    const documents = try a.alloc(hybrid.Document, texts.len);
    for (texts, documents, 0..) |text, *d, i| d.* = .{ .id = try std.fmt.allocPrint(a, "d{d}", .{i}), .text = text };
    return lexical_build.buildPositional(a, documents, try tokensOf(a, texts));
}

// ------------------------------------------------------------ worked example

const example_texts = [_][]const u8{
    "Ah        incomprehensibilities ok",
    "x                    y abcdefghijklmnopq",
    "a\u{037E}\u{2126}",
    "!!!",
};

test "S6-T8: the format document's worked example is the writer's section 5, byte for byte" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const index = try buildOf(a, &example_texts);
    const sections = index.positions.?;
    try std.testing.expectEqual(postings.OffsetsCoding.one_byte, sections.coding);
    const expected = [_]u8{
        0x03, 0x20, 0xFF, 0x10, 0x15, 0x22,
        0x03, 0x10, 0x1F, 0x28, 0xF2, 0x11,
        0x02, 0x30, 0x35,
        0x00,
    };
    try std.testing.expectEqualSlices(u8, &expected, sections.offsets);
    // The spans the document's table lists.
    const want = [_][]const postings.TokenSpan{
        &.{ .{ .start = 0, .length = 2 }, .{ .start = 10, .length = 21 }, .{ .start = 32, .length = 2 } },
        &.{ .{ .start = 0, .length = 1 }, .{ .start = 21, .length = 1 }, .{ .start = 23, .length = 17 } },
        &.{ .{ .start = 0, .length = 3 }, .{ .start = 0, .length = 3 } },
        &.{},
    };
    const tables = try postings.buildPositionTables(a, index);
    for (want, 0..) |spans, d| {
        var out: [4]postings.TokenSpan = undefined;
        try std.testing.expectEqualSlices(postings.TokenSpan, spans, postings.readTokenSpans(index, tables, d, &out));
    }
    // v2's coding of the same spans takes 32 bytes.
    try std.testing.expectEqual(@as(usize, 32), (try postings.withOffsetsCoding(a, index, .pairs)).positions.?.offsets.len);
    try postings.validateOneByteOffsets(sections.offsets, index.document_lengths);
    // Written: `HYBLEX04`, flags exactly 3, and it reads back.
    const encoded = try lexical_segment.encodeV3Alloc(a, index);
    try std.testing.expectEqualStrings(lexical_segment.magic_v4, encoded[0..8]);
    try std.testing.expectEqual(@as(u16, 4), std.mem.readInt(u16, encoded[8..10], .little));
    try std.testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, encoded[10..12], .little));
    try std.testing.expectEqualSlices(u8, &expected, encoded[encoded.len - expected.len ..]);
}

test "S6-T8: zigzag and the escape threshold" {
    const pairs = [_]struct { i64, u64 }{ .{ 0, 0 }, .{ -1, 1 }, .{ 1, 2 }, .{ -2, 3 }, .{ 7, 14 }, .{ -8, 15 }, .{ 8, 16 }, .{ -2147483648, 4294967295 } };
    for (pairs) |p| {
        try std.testing.expectEqual(p[1], postings.zigzag(p[0]));
        try std.testing.expectEqual(p[0], postings.unzigzag(p[1]));
    }
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Values 14, 15 and 16 in each field: 14 in the nibble, 15 and 16 as
    // a nibble of 15 and the whole value after it, the gap's first.
    const cases = [_]struct { start: u32, length: u32, bytes: []const u8 }{
        .{ .start = 7, .length = 1, .bytes = &.{0x1E} },
        .{ .start = 8, .length = 1, .bytes = &.{ 0x1F, 0x10 } },
        .{ .start = 0, .length = 14, .bytes = &.{0xE0} },
        .{ .start = 0, .length = 15, .bytes = &.{ 0xF0, 0x0F } },
        .{ .start = 0, .length = 16, .bytes = &.{ 0xF0, 0x10 } },
        .{ .start = 8, .length = 16, .bytes = &.{ 0xFF, 0x10, 0x10 } },
    };
    for (cases) |c| {
        var list = std.ArrayList(u8).empty;
        try postings.appendOneByteToken(&list, a, 0, c.start, c.length);
        try std.testing.expectEqualSlices(u8, c.bytes, list.items);
    }
    // A gap of -8 (z 15) after a token ending at 8.
    var list = std.ArrayList(u8).empty;
    try postings.appendOneByteToken(&list, a, 8, 0, 8);
    try std.testing.expectEqualSlices(u8, &.{ 0x8F, 0x0F }, list.items);
}

// ------------------------------------------------------- boundary fixtures

const File = struct { name: []const u8, text: []const u8 };

/// One file per boundary value, each one chunk (`line-window-v1`).
const boundary_files = [_]File{
    .{ .name = "gap14.txt", .text = "aa       bb\n" }, // gap 7, z 14
    .{ .name = "gap15.txt", .text = "a\u{037E}\u{037E}\u{037E}\u{037E}\u{037E}\u{037E}\u{2126} omega\n" }, // gap -8, z 15
    .{ .name = "gap16.txt", .text = "aa        bb\n" }, // gap 8, z 16
    .{ .name = "len14.txt", .text = "abcdefghijklmn x\n" },
    .{ .name = "len15.txt", .text = "abcdefghijklmno x\n" },
    .{ .name = "len16.txt", .text = "abcdefghijklmnop x\n" },
    .{ .name = "none.txt", .text = "!!! ???\n" },
    .{ .name = "one.txt", .text = "solo\n" },
    .{ .name = "tamil.txt", .text = "பள்ளி விடுமுறை e\u{0301}cole\n" },
};

/// Each token's raw fields in a v4 section 5: the nibbles and, when they
/// escape, the values after them (independent of the library's reader).
const RawToken = struct { g_nibble: u8, l_nibble: u8, z: u64, length: u64 };

fn rawTokens(a: std.mem.Allocator, offsets: []const u8, document_lengths: []const u32) ![][]RawToken {
    const out = try a.alloc([]RawToken, document_lengths.len);
    var at: usize = 0;
    for (document_lengths, out) |length, *list| {
        const count = try uleb(offsets, &at);
        try std.testing.expectEqual(@as(u64, length), count);
        list.* = try a.alloc(RawToken, length);
        for (list.*) |*token| {
            const byte = offsets[at];
            at += 1;
            token.* = .{ .g_nibble = byte & 0x0F, .l_nibble = byte >> 4, .z = byte & 0x0F, .length = byte >> 4 };
            if (token.g_nibble == 15) token.z = try uleb(offsets, &at);
            if (token.l_nibble == 15) token.length = try uleb(offsets, &at);
        }
    }
    try std.testing.expectEqual(offsets.len, at);
    return out;
}

fn uleb(bytes: []const u8, at: *usize) !u64 {
    var value: u64 = 0;
    var shift: u6 = 0;
    while (true) {
        if (at.* >= bytes.len) return error.TestUnexpectedResult;
        const byte = bytes[at.*];
        at.* += 1;
        value |= @as(u64, byte & 0x7f) << shift;
        if (byte < 0x80) return value;
        shift += 7;
    }
}

fn publishBoundaries(a: std.mem.Allocator, tmp: std.testing.TmpDir) !std.Io.Dir {
    return publishFiles(a, tmp, &boundary_files);
}

/// `files` indexed by `searchd index` (a v4-coded content section).
fn publishFiles(a: std.mem.Allocator, tmp: std.testing.TmpDir, files: []const File) !std.Io.Dir {
    try tmp.dir.createDir(io, "src", .default_dir);
    var src = try tmp.dir.openDir(io, "src", .{});
    defer src.close(io);
    for (files) |f| try src.writeFile(io, .{ .sub_path = f.name, .data = f.text });
    var sink: std.Io.Writer.Allocating = .init(a);
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try cli.runIndex(io, a, try std.fmt.allocPrint(a, "{s}/src", .{base}), try std.fmt.allocPrint(a, "{s}/idx", .{base}), .{}, &sink.writer);
    return tmp.dir.openDir(io, "idx", .{ .iterate = true });
}

test "S6-T8: boundary values 14, 15 and 16 in each field, zero and one token, through the writer, the reader and find" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var dir = try publishBoundaries(a, tmp);
    defer dir.close(io);
    const metadata = try manifest.decode(try dir.readFileAlloc(io, publication.current_manifest_file, a, .unlimited));
    try std.testing.expect(metadata.lexical_v4);
    const engine = try snapshot_open.open(a, io, dir);
    const index = engine.lexical_index;
    const sections = index.positions.?;
    try std.testing.expectEqual(postings.OffsetsCoding.one_byte, sections.coding);
    const raw = try rawTokens(a, sections.offsets, index.document_lengths);

    // Which field values occur, and how they are written.
    var seen_z = [_]bool{false} ** 3;
    var seen_length = [_]bool{false} ** 3;
    var zero_docs: usize = 0;
    var one_docs: usize = 0;
    var negative = false;
    for (engine.documents, raw, 0..) |document, tokens, d| {
        if (tokens.len == 0) zero_docs += 1;
        if (tokens.len == 1) one_docs += 1;
        // Every token's fields agree with the tokenizer's spans.
        const fresh = try indexer.tokenizePositioned(a, .v2, document.text);
        try std.testing.expectEqual(fresh.len, tokens.len);
        var previous_end: i64 = 0;
        var previous_start: u32 = 0;
        var spans: [16]postings.TokenSpan = undefined;
        const read = postings.readTokenSpans(index, engine.position_tables.?, d, &spans);
        for (tokens, fresh, read) |token, want, got| {
            const start = @max(want.start, previous_start);
            const gap = @as(i64, start) - previous_end;
            if (gap < 0) negative = true;
            try std.testing.expectEqual(postings.zigzag(gap), token.z);
            try std.testing.expectEqual(@as(u64, @max(want.length, 1)), token.length);
            try std.testing.expectEqual(@as(u8, @intCast(@min(token.z, 15))), token.g_nibble);
            try std.testing.expectEqual(@as(u8, @intCast(@min(token.length, 15))), token.l_nibble);
            try std.testing.expectEqual(postings.TokenSpan{ .start = start, .length = @max(want.length, 1) }, got);
            for (14..17) |v| {
                if (token.z == v) seen_z[v - 14] = true;
                if (token.length == v) seen_length[v - 14] = true;
            }
            previous_start = start;
            previous_end = @as(i64, start) + @max(want.length, 1);
        }
    }
    try std.testing.expect(seen_z[0] and seen_z[1] and seen_z[2]);
    try std.testing.expect(seen_length[0] and seen_length[1] and seen_length[2]);
    try std.testing.expect(negative);
    try std.testing.expectEqual(@as(usize, 1), zero_docs);
    try std.testing.expect(one_docs >= 1);

    // Highlights read from section 5 equal highlights re-tokenized, hit for
    // hit, in every mode, the first and last token of a chunk included.
    const root_ids = [_][]const u8{"r-legacy"};
    const queries = [_]struct { q: []const u8, mode: find.Mode }{
        .{ .q = "aa", .mode = .words },       .{ .q = "bb", .mode = .words },
        .{ .q = "omega", .mode = .words },    .{ .q = "ω", .mode = .words },
        .{ .q = "a", .mode = .words },        .{ .q = "x", .mode = .words },
        .{ .q = "abcdefghijklmnop", .mode = .words }, .{ .q = "abcdefghijklm*", .mode = .prefix },
        .{ .q = "solo", .mode = .words },     .{ .q = "பள்ளி விடுமுறை", .mode = .phrase },
        .{ .q = "école", .mode = .words },    .{ .q = "aa bb", .mode = .phrase },
    };
    var hits: usize = 0;
    for (queries) |item| {
        const stored = (try find.find(a, engine, .{ .query = item.q, .mode = item.mode, .page_size = 100, .root_ids = &root_ids })).ok;
        const recomputed = (try find.find(a, engine, .{ .query = item.q, .mode = item.mode, .page_size = 100, .root_ids = &root_ids, .recompute_offsets = true })).ok;
        try std.testing.expectEqual(stored.hits.len, recomputed.hits.len);
        for (stored.hits, recomputed.hits) |left, right| {
            try std.testing.expectEqualStrings(left.chunk_id, right.chunk_id);
            try std.testing.expectEqualSlices(find.Range, left.match_offsets, right.match_offsets);
            try std.testing.expectEqualSlices(find.Range, left.snippet_offsets, right.snippet_offsets);
            try std.testing.expectEqualStrings(left.snippet, right.snippet);
        }
        hits += stored.hits.len;
    }
    try std.testing.expect(hits >= queries.len);
}

// ----------------------------------------------------------------- damage

/// A v4 section 5 as tokens of raw bytes, re-emitted after an edit.
const Tok = struct { byte: u8, esc_g: []const u8 = &.{}, esc_l: []const u8 = &.{} };
const Doc = struct { count: []const u8, tokens: []Tok };

fn varintBytes(a: std.mem.Allocator, value: u64) ![]u8 {
    var list = std.ArrayList(u8).empty;
    var rest = value;
    while (rest >= 0x80) : (rest >>= 7) try list.append(a, @as(u8, @truncate(rest)) | 0x80);
    try list.append(a, @truncate(rest));
    return list.items;
}

fn parseDocs(a: std.mem.Allocator, offsets: []const u8, lengths: []const u32) ![]Doc {
    const docs = try a.alloc(Doc, lengths.len);
    var at: usize = 0;
    for (lengths, docs) |length, *doc| {
        const before = at;
        _ = try uleb(offsets, &at);
        doc.count = offsets[before..at];
        doc.tokens = try a.alloc(Tok, length);
        for (doc.tokens) |*tok| {
            tok.* = .{ .byte = offsets[at] };
            at += 1;
            if (tok.byte & 0x0F == 15) {
                const s = at;
                _ = try uleb(offsets, &at);
                tok.esc_g = offsets[s..at];
            }
            if (tok.byte >> 4 == 15) {
                const s = at;
                _ = try uleb(offsets, &at);
                tok.esc_l = offsets[s..at];
            }
        }
    }
    try std.testing.expectEqual(offsets.len, at);
    return docs;
}

/// Token `i`'s start in `doc` (each gap from the previous token's end).
fn tokenStart(doc: Doc, i: usize) u64 {
    var previous_end: i64 = 0;
    var start: i64 = 0;
    for (doc.tokens[0 .. i + 1]) |tok| {
        var at: usize = 0;
        const g: u64 = if (tok.byte & 0x0F == 15) uleb(tok.esc_g, &at) catch unreachable else tok.byte & 0x0F;
        at = 0;
        const l: u64 = if (tok.byte >> 4 == 15) uleb(tok.esc_l, &at) catch unreachable else tok.byte >> 4;
        start = previous_end + postings.unzigzag(g);
        previous_end = start + @as(i64, @intCast(l));
    }
    return @intCast(start);
}

fn cloneDocs(a: std.mem.Allocator, docs: []const Doc) ![]Doc {
    const out = try a.dupe(Doc, docs);
    for (out) |*doc| doc.tokens = try a.dupe(Tok, doc.tokens);
    return out;
}

fn emitDocs(a: std.mem.Allocator, docs: []const Doc, tail: []const u8) ![]u8 {
    var list = std.ArrayList(u8).empty;
    for (docs) |doc| {
        try list.appendSlice(a, doc.count);
        for (doc.tokens) |tok| {
            try list.append(a, tok.byte);
            try list.appendSlice(a, tok.esc_g);
            try list.appendSlice(a, tok.esc_l);
        }
    }
    try list.appendSlice(a, tail);
    return list.items;
}

/// `good` (a `HYBLEX04` section) with section 5 replaced by `offsets`, the
/// header's offsets length and the checksum recomputed.
fn withOffsets(a: std.mem.Allocator, good: []const u8, offsets: []const u8) ![]u8 {
    const old_len = std.mem.readInt(u64, good[64..72], .little);
    const keep = good.len - old_len;
    const out = try a.alloc(u8, keep + offsets.len);
    @memcpy(out[0..keep], good[0..keep]);
    @memcpy(out[keep..], offsets);
    std.mem.writeInt(u64, out[64..72], offsets.len, .little);
    std.mem.writeInt(u64, out[80..88], checksum.compute(.xxh3_64, out[0..80], out[88..]), .little);
    return out;
}

const Buffers = struct {
    terms: []postings.TermEntry,
    values: []postings.Posting,
    lengths: []u32,
};

fn decodeBoth(a: std.mem.Allocator, encoded: []const u8, eager: bool) !postings.Index {
    const header = try lexical_segment.inspect(encoded);
    const b = Buffers{ .terms = try a.alloc(postings.TermEntry, header.term_count), .values = try a.alloc(postings.Posting, header.posting_count), .lengths = try a.alloc(u32, header.document_count) };
    const index = try lexical_segment.decodeWith(encoded, b.terms, b.values, b.lengths, .{ .validate_positions = eager, .term_text_allocator = a });
    if (!eager) try lexical_segment.validatePositionSections(index);
    return index;
}

var refused_rules: usize = 0;

fn expectRefused(a: std.mem.Allocator, good: []const u8, offsets: []const u8, expected: anyerror, what: []const u8) !void {
    const damaged = try withOffsets(a, good, offsets);
    // The checksum is right: only the rule under test is broken.
    _ = try lexical_segment.inspect(damaged);
    for ([_]bool{ true, false }) |eager| {
        if (decodeBoth(a, damaged, eager)) |_| {
            std.debug.print("S6-T8 damage: {s} was accepted (eager {})\n", .{ what, eager });
            return error.TestUnexpectedResult;
        } else |err| if (err != expected) {
            std.debug.print("S6-T8 damage: {s} gave {s}, expected {s} (eager {})\n", .{ what, @errorName(err), @errorName(expected), eager });
            return error.TestUnexpectedError;
        }
    }
    refused_rules += 1;
}

/// The damage base: the worked example's documents and one more whose last
/// token escapes in both fields (the section's last element is two escape
/// varints), the last document's count two bytes long.
fn damageBase(a: std.mem.Allocator) !struct { good: []const u8, docs: []Doc, lengths: []const u32 } {
    var long = std.ArrayList(u8).empty;
    for (0..130) |k| try long.appendSlice(a, if (k % 2 == 0) "w " else "q ");
    try long.appendSlice(a, "Ah        incomprehensibilities");
    const texts = [_][]const u8{ example_texts[0], example_texts[1], example_texts[2], example_texts[3], long.items };
    const index = try buildOf(a, &texts);
    const good = try lexical_segment.encodeV3Alloc(a, index);
    _ = try decodeBoth(a, good, true);
    const docs = try parseDocs(a, index.positions.?.offsets, index.document_lengths);
    const last = docs[docs.len - 1];
    try std.testing.expect(last.count.len == 2);
    const tail = last.tokens[last.tokens.len - 1];
    try std.testing.expect(tail.esc_g.len == 1 and tail.esc_l.len == 1);
    return .{ .good = good, .docs = docs, .lengths = index.document_lengths };
}

test "S6-T8: every section 5 rule, violated with the checksum recomputed, is refused with its own error, at the open and lazily" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const base = try damageBase(a);
    const good = base.good;
    const n = base.docs.len;
    const last_doc = n - 1;
    const last_tok = base.docs[last_doc].tokens.len - 1;
    // The base re-emits to its own section 5.
    try std.testing.expectEqualSlices(u8, good[good.len - std.mem.readInt(u64, good[64..72], .little) ..], try emitDocs(a, base.docs, &.{}));
    refused_rules = 0;

    // Rule 1: the count, a complete varint.
    var v = try cloneDocs(a, base.docs);
    v[last_doc].count = base.docs[last_doc].count[0..1]; // a continuation byte, then the section ends
    v[last_doc].tokens = &.{};
    try expectRefused(a, good, try emitDocs(a, v, &.{}), error.OffsetsTruncated, "the last count cut inside its varint");
    v = try cloneDocs(a, base.docs);
    v[last_doc].count = &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01 };
    try expectRefused(a, good, try emitDocs(a, v, &.{}), error.OffsetsVarintOverflow, "a six-byte count");
    v = try cloneDocs(a, base.docs);
    v[last_doc].count = &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0x1F };
    try expectRefused(a, good, try emitDocs(a, v, &.{}), error.OffsetsVarintOverflow, "a count of 2^32 or more");
    v = try cloneDocs(a, base.docs);
    v[last_doc].count = &.{ 0x80, 0x80, 0x80, 0x80, 0x10 };
    try expectRefused(a, good, try emitDocs(a, v, &.{}), error.OffsetsVarintOverflow, "a count of exactly 2^32");
    // Rule 2: the count equals the document's length.
    v = try cloneDocs(a, base.docs);
    v[last_doc].count = try varintBytes(a, base.lengths[last_doc] + 1);
    try expectRefused(a, good, try emitDocs(a, v, &.{}), error.OffsetsCountMismatch, "the last count one more");
    v = try cloneDocs(a, base.docs);
    v[0].count = try varintBytes(a, base.lengths[0] - 1);
    try expectRefused(a, good, try emitDocs(a, v, &.{}), error.OffsetsCountMismatch, "the first count one less");
    // ... and the last one less: a count that let it through would read one
    // token fewer and end before the section (rule 12's error, not rule 2's).
    v = try cloneDocs(a, base.docs);
    v[last_doc].count = try varintBytes(a, base.lengths[last_doc] - 1);
    try expectRefused(a, good, try emitDocs(a, v, &.{}), error.OffsetsCountMismatch, "the last count one less");
    v = try cloneDocs(a, base.docs);
    v[3].count = &.{0x01}; // the document with no token
    try expectRefused(a, good, try emitDocs(a, v, &.{}), error.OffsetsCountMismatch, "a count of 1 on a document with no token");
    // Rule 3: every token's byte.
    v = try cloneDocs(a, base.docs);
    v[last_doc].tokens = v[last_doc].tokens[0..last_tok];
    try expectRefused(a, good, try emitDocs(a, v, &.{}), error.OffsetsTruncated, "the last token's byte missing");
    // Rule 4: an escape that overruns (the last element).
    v = try cloneDocs(a, base.docs);
    v[last_doc].tokens[last_tok].esc_l = &.{};
    try expectRefused(a, good, try emitDocs(a, v, &.{}), error.OffsetsTruncated, "the last length escape missing");
    v = try cloneDocs(a, base.docs);
    v[last_doc].tokens[last_tok].esc_l = &.{0x95};
    try expectRefused(a, good, try emitDocs(a, v, &.{}), error.OffsetsTruncated, "the last length escape cut inside its varint");
    v = try cloneDocs(a, base.docs);
    v[last_doc].tokens[last_tok].esc_g = &.{0x90};
    v[last_doc].tokens[last_tok].esc_l = &.{};
    try expectRefused(a, good, try emitDocs(a, v, &.{}), error.OffsetsTruncated, "the last gap escape cut inside its varint");
    // Rule 5: a malformed escape.
    v = try cloneDocs(a, base.docs);
    v[last_doc].tokens[last_tok].esc_g = &.{ 0x90, 0x80, 0x80, 0x80, 0x80, 0x00 };
    try expectRefused(a, good, try emitDocs(a, v, &.{}), error.OffsetsVarintOverflow, "a six-byte gap escape");
    v = try cloneDocs(a, base.docs);
    v[last_doc].tokens[last_tok].esc_l = &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0x1F };
    try expectRefused(a, good, try emitDocs(a, v, &.{}), error.OffsetsVarintOverflow, "a length escape of 2^32 or more");
    v = try cloneDocs(a, base.docs);
    v[last_doc].tokens[last_tok].esc_l = &.{ 0x80, 0x80, 0x80, 0x80, 0x10 };
    try expectRefused(a, good, try emitDocs(a, v, &.{}), error.OffsetsVarintOverflow, "a length escape of exactly 2^32");
    // Rule 6: an escape below 15 (each field; 14, the last value a nibble
    // holds, and 0).
    for ([_][]const u8{ &.{0x0E}, &.{0x00} }) |small| {
        v = try cloneDocs(a, base.docs);
        v[last_doc].tokens[last_tok].esc_g = small;
        try expectRefused(a, good, try emitDocs(a, v, &.{}), error.OffsetsNonCanonicalEscape, "a gap escape below 15");
        v = try cloneDocs(a, base.docs);
        v[last_doc].tokens[last_tok].esc_l = small;
        try expectRefused(a, good, try emitDocs(a, v, &.{}), error.OffsetsNonCanonicalEscape, "a length escape below 15");
    }
    // Rule 7: a length of 0 (the last token, its escapes dropped).
    v = try cloneDocs(a, base.docs);
    v[last_doc].tokens[last_tok] = .{ .byte = 0x02 };
    try expectRefused(a, good, try emitDocs(a, v, &.{}), error.OffsetsZeroLength, "the last token's length nibble 0");
    // Rule 8: a start before the chunk (the last document's first token,
    // gap -1).
    v = try cloneDocs(a, base.docs);
    v[last_doc].tokens[0] = .{ .byte = (v[last_doc].tokens[0].byte & 0xF0) | 0x01 };
    try expectRefused(a, good, try emitDocs(a, v, &.{}), error.OffsetsStartBeforeChunk, "a first token at -1");
    // ... and a negative gap reaching past the start from a later token:
    // doc 2's second token, gap -4 after (0, 3).
    v = try cloneDocs(a, base.docs);
    v[2].tokens[1] = .{ .byte = 0x37 };
    try expectRefused(a, good, try emitDocs(a, v, &.{}), error.OffsetsStartBeforeChunk, "a later token reaching before the chunk");
    // Rule 9: a start below the previous token's start (doc 0's last
    // token, gap -22 after (10, 21): start 9).
    v = try cloneDocs(a, base.docs);
    v[0].tokens[2] = .{ .byte = 0x2F, .esc_g = try varintBytes(a, postings.zigzag(-22)) };
    try expectRefused(a, good, try emitDocs(a, v, &.{}), error.OffsetsStartDecreases, "a start below the previous start");
    // Rule 10: an end past a u32. At the boundary (the Fifth Verdict's F6):
    // the last token's length 2^32 minus its start, an end of exactly 2^32;
    // and well past it (a length of 2^32 - 1 after a start of at least 2).
    const last_start = tokenStart(base.docs[last_doc], last_tok);
    try std.testing.expect(last_start >= 2);
    v = try cloneDocs(a, base.docs);
    v[last_doc].tokens[last_tok].esc_l = try varintBytes(a, (@as(u64, 1) << 32) - last_start);
    try expectRefused(a, good, try emitDocs(a, v, &.{}), error.OffsetsEndOverflow, "an end of exactly 2^32");
    v = try cloneDocs(a, base.docs);
    v[last_doc].tokens[last_tok].esc_l = &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0x0F };
    try expectRefused(a, good, try emitDocs(a, v, &.{}), error.OffsetsEndOverflow, "an end past 2^32");
    // Rule 12: no byte left over (a zero byte, and a whole valid-looking
    // token after the last document).
    try expectRefused(a, good, try emitDocs(a, base.docs, &.{0x00}), error.OffsetsTrailingData, "a byte left over");
    try expectRefused(a, good, try emitDocs(a, base.docs, &.{0x22}), error.OffsetsTrailingData, "a token byte left over");

    // Accepted, as documented: an overlong escape (15 as `8F 00`), and a
    // gap nibble of 0 (a token starting where the previous one ends).
    v = try cloneDocs(a, base.docs);
    v[0].tokens[1].esc_l = &.{ 0x95, 0x00 };
    _ = try decodeBoth(a, try withOffsets(a, good, try emitDocs(a, v, &.{})), true);
    // ... and rule 10's last end allowed: exactly 2^32 - 1 (rule 11 is
    // `find`'s, with the text).
    v = try cloneDocs(a, base.docs);
    v[last_doc].tokens[last_tok].esc_l = try varintBytes(a, (@as(u64, 1) << 32) - 1 - last_start);
    for ([_]bool{ true, false }) |eager| _ = try decodeBoth(a, try withOffsets(a, good, try emitDocs(a, v, &.{})), eager);
    std.debug.print("S6-T8: {d} damaged sections 5 refused with their rules' errors (rules 1-10 and 12), eager and lazy; an overlong escape and an end of 2^32 - 1 accepted\n", .{refused_rules});
    try std.testing.expectEqual(@as(usize, 27), refused_rules);
}

test "S6-T8: the header of HYBLEX04: version 4 and flags exactly 3" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const good = try lexical_segment.encodeV3Alloc(a, try buildOf(a, &example_texts));
    for ([_]u16{ 1, 0, 0x0007, 0x8003 }) |flags| {
        const bad = try a.dupe(u8, good);
        std.mem.writeInt(u16, bad[10..12], flags, .little);
        std.mem.writeInt(u64, bad[80..88], checksum.compute(.xxh3_64, bad[0..80], bad[88..]), .little);
        try std.testing.expectError(error.UnsupportedFlags, lexical_segment.inspect(bad));
    }
    for ([_]u16{ 3, 5 }) |version| {
        const bad = try a.dupe(u8, good);
        std.mem.writeInt(u16, bad[8..10], version, .little);
        try std.testing.expectError(error.UnsupportedVersion, lexical_segment.inspect(bad));
    }
    // `HYBLEX02` cannot hold section 5 in v4's coding.
    const index = try buildOf(a, &example_texts);
    try std.testing.expectError(error.InvalidPositions, lexical_segment.encodedLength(index));
}

// ------------------------------------------------- rule 11 through find

/// The published index in `dir` with its content section's section 5
/// edited by `edit`, the section's checksum and the manifest resealed.
fn rewriteOffsets(a: std.mem.Allocator, dir: std.Io.Dir, comptime edit: fn ([]Doc, []const hybrid.Document) void) !void {
    const engine = try snapshot_open.open(a, io, dir);
    const docs = try cloneDocs(a, try parseDocs(a, engine.lexical_index.positions.?.offsets, engine.lexical_index.document_lengths));
    edit(docs, engine.documents);
    try writeOffsets(a, dir, docs);
}

/// The published index in `dir` with its content section's section 5
/// replaced by `docs`, the section's checksum and the manifest resealed.
fn writeOffsets(a: std.mem.Allocator, dir: std.Io.Dir, docs: []const Doc) !void {
    var metadata = try manifest.decode(try dir.readFileAlloc(io, publication.current_manifest_file, a, .unlimited));
    const good = try dir.readFileAlloc(io, metadata.lexical_file, a, .unlimited);
    const damaged = try withOffsets(a, good, try emitDocs(a, docs, &.{}));
    try dir.writeFile(io, .{ .sub_path = metadata.lexical_file, .data = damaged });
    metadata.lexical_bytes = damaged.len;
    metadata.lexical_checksum = std.mem.readInt(u64, damaged[80..88], .little);
    const encoded = try manifest.encode(metadata, try a.alloc(u8, try manifest.encodedLength(metadata)));
    try dir.writeFile(io, .{ .sub_path = publication.current_manifest_file, .data = encoded });
}

fn params(a: std.mem.Allocator, text: []const u8) !std.json.ObjectMap {
    return switch (try ops.parseObject(a, text)) {
        .ok => |map| map,
        .failed => error.TestUnexpectedResult,
    };
}

test "S6-T8 rule 11: a highlight past its chunk's text is refused by find (OffsetsPastText), never returned" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var dir = try publishBoundaries(a, tmp);
    defer dir.close(io);
    // `solo` is one.txt's only token, 4 codepoints of a 4-codepoint chunk:
    // a length of 5 ends one past the text, which every other rule allows.
    try rewriteOffsets(a, dir, struct {
        fn edit(docs: []Doc, documents: []const hybrid.Document) void {
            for (documents, docs) |d, *doc| if (std.mem.eql(u8, d.text, "solo")) {
                doc.tokens[0] = .{ .byte = 0x50 };
            };
        }
    }.edit);
    const opened = try snapshot_open.openScoped(a, io, dir);
    defer opened.folder.close();
    const service = @import("service.zig").Service{ .engine = opened.engine, .folder = opened.folder };
    // The lazy validation passes (rules 1-10, 12): only the text shows it.
    _ = try opened.folder.positionTables();
    try std.testing.expectError(error.OffsetsPastText, ops.find(a, service, try params(a, "{\"query\":\"solo\"}"), cli.cli_caller));
    // A find whose hits do not include that chunk still answers.
    _ = try ops.find(a, service, try params(a, "{\"query\":\"omega\"}"), cli.cli_caller);
    // The end exactly at the text's end is the writer's own section.
    var tmp2 = std.testing.tmpDir(.{ .iterate = true });
    defer tmp2.cleanup();
    var clean = try publishBoundaries(a, tmp2);
    defer clean.close(io);
    const clean_opened = try snapshot_open.openScoped(a, io, clean);
    defer clean_opened.folder.close();
    _ = try ops.find(a, .{ .engine = clean_opened.engine, .folder = clean_opened.folder }, try params(a, "{\"query\":\"solo\"}"), cli.cli_caller);
}

// ------------------------- rule 11 in a chunk of several spans (S6-T10)

/// One chunk of five tokens (`line-window-v1`), and a file without them:
/// rule 11 on a v4-coded index with several spans in a chunk (S6-T8's
/// Sixth Verdict, note I6). A two-byte letter in the first and the middle
/// token and a Tamil last token (the Verdict's F2): the chunk's bytes
/// outnumber its codepoints before each checked span, so a check against
/// the byte length would let an end one codepoint past the text through.
/// U+1F33F (outside the BMP, not a token) before the last token (the Second
/// Verdict's F4): its UTF-16 units outnumber its codepoints too.
const span_files = [_]File{
    .{ .name = "five.txt", .text = "\u{00E9}lan bravo caf\u{00E9} delta \u{1F33F} \u{0BAA}\u{0BB3}\u{0BCD}\u{0BB3}\u{0BBF}\n" },
    .{ .name = "other.txt", .text = "omega\n" },
};

const SpanAt = enum { first, middle, last };

/// The v4 token for `gap` and `length`, written from the format document
/// (the two nibbles, then the whole value of each escaping field, the gap's
/// first), independent of the library's writer.
fn tokOf(a: std.mem.Allocator, gap: i64, length: u64) !Tok {
    const z: u64 = if (gap >= 0) @as(u64, @intCast(gap)) * 2 else @as(u64, @intCast(-gap)) * 2 - 1;
    const g: u8 = @intCast(@min(z, 15));
    const l: u8 = @intCast(@min(length, 15));
    return .{
        .byte = g | (l << 4),
        .esc_g = if (z >= 15) try varintBytes(a, z) else &.{},
        .esc_l = if (length >= 15) try varintBytes(a, length) else &.{},
    };
}

fn tokLength(tok: Tok) u64 {
    var at: usize = 0;
    return if (tok.byte >> 4 == 15) uleb(tok.esc_l, &at) catch unreachable else tok.byte >> 4;
}

/// `five.txt`'s starts and lengths, read from the section's bytes, and its
/// chunk text's codepoints (as `find` counts them for rule 11).
fn fiveSpans(a: std.mem.Allocator, dir: std.Io.Dir) !struct { docs: []Doc, at: usize, starts: []u64, lengths: []u64, codepoints: u64 } {
    const engine = try snapshot_open.open(a, io, dir);
    try std.testing.expectEqual(postings.OffsetsCoding.one_byte, engine.lexical_index.positions.?.coding);
    const docs = try cloneDocs(a, try parseDocs(a, engine.lexical_index.positions.?.offsets, engine.lexical_index.document_lengths));
    var found: ?usize = null;
    for (engine.documents, 0..) |d, i| {
        if (std.mem.indexOf(u8, d.text, " bravo caf") != null) found = i;
    }
    const doc = docs[found.?];
    const starts = try a.alloc(u64, doc.tokens.len);
    const lengths = try a.alloc(u64, doc.tokens.len);
    for (doc.tokens, starts, lengths, 0..) |tok, *start, *length, i| {
        start.* = tokenStart(doc, i);
        length.* = tokLength(tok);
    }
    return .{ .docs = docs, .at = found.?, .starts = starts, .lengths = lengths, .codepoints = analysis.codepointCount(engine.documents[found.?].text) };
}

/// `five.txt`'s span at `where` made to end `past` codepoints after its
/// chunk's text, every other span's start and length kept (the next token's
/// gap goes negative to keep its start), the section and manifest resealed.
/// Every rule but 11 still holds; checked here from the bytes written.
fn spanEndsPast(a: std.mem.Allocator, dir: std.Io.Dir, where: SpanAt, past: u64) !void {
    const base = try fiveSpans(a, dir);
    const n = base.starts.len;
    try std.testing.expectEqual(@as(usize, 5), n);
    const codepoints = base.codepoints;
    const k: usize = switch (where) {
        .first => 0,
        .middle => n / 2,
        .last => n - 1,
    };
    for (base.starts, base.lengths) |start, length| try std.testing.expect(start + length <= codepoints);
    // The text has more bytes and more UTF-16 units than codepoints: an end
    // one codepoint past the text still lies within either count.
    const text = (try snapshot_open.open(a, io, dir)).documents[base.at].text;
    try std.testing.expect(codepoints + past < text.len);
    try std.testing.expect(codepoints + past <= try std.unicode.calcUtf16LeLen(text));
    const lengths = try a.dupe(u64, base.lengths);
    lengths[k] = codepoints + past - base.starts[k];
    var previous_end: i64 = 0;
    for (base.docs[base.at].tokens, base.starts, lengths) |*tok, start, length| {
        tok.* = try tokOf(a, @as(i64, @intCast(start)) - previous_end, length);
        previous_end = @intCast(start + length);
    }
    try writeOffsets(a, dir, base.docs);
    // Read back: the same starts, only span k's length moved; rules 7-10
    // hold, and only span k ends past the text (rule 11), by `past`.
    const got = try fiveSpans(a, dir);
    try std.testing.expectEqualSlices(u64, base.starts, got.starts);
    try std.testing.expectEqualSlices(u64, lengths, got.lengths);
    for (got.starts, got.lengths, 0..) |start, length, i| {
        try std.testing.expect(length >= 1);
        if (i > 0) try std.testing.expect(start >= got.starts[i - 1]);
        try std.testing.expect(start + length <= std.math.maxInt(u32));
        try std.testing.expectEqual(i == k and past > 0, start + length > codepoints);
    }
    try std.testing.expectEqual(codepoints + past, got.starts[k] + got.lengths[k]);
}

test "S6-T10 rule 11 on a v4-coded index, five spans in a chunk: an end past the text in the first, a middle or the last span is each refused by find (OffsetsPastText); an end at the text's end answers" {
    for ([_]SpanAt{ .first, .middle, .last }) |where| for ([_]u64{ 1, 0 }) |past| {
        errdefer std.debug.print("S6-T10 rule 11: the {s} span ending {d} past the text\n", .{ @tagName(where), past });
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        var dir = try publishFiles(a, tmp, &span_files);
        defer dir.close(io);
        const metadata = try manifest.decode(try dir.readFileAlloc(io, publication.current_manifest_file, a, .unlimited));
        try std.testing.expect(metadata.lexical_v4);
        try spanEndsPast(a, dir, where, past);
        const opened = try snapshot_open.openScoped(a, io, dir);
        defer opened.folder.close();
        const service = @import("service.zig").Service{ .engine = opened.engine, .folder = opened.folder };
        // The lazy validation passes (rules 1-10, 12): only the text shows it.
        _ = try opened.folder.positionTables();
        // A hit on the chunk, whichever of its words matched (the first, the
        // middle and the last).
        for ([_][]const u8{ "{\"query\":\"\u{00E9}lan\"}", "{\"query\":\"caf\u{00E9}\"}", "{\"query\":\"\u{0BAA}\u{0BB3}\u{0BCD}\u{0BB3}\u{0BBF}\"}" }) |query| {
            const got = ops.find(a, service, try params(a, query), cli.cli_caller);
            if (past > 0) try std.testing.expectError(error.OffsetsPastText, got) else _ = try got;
        }
        // A find whose hits do not include that chunk still answers.
        _ = try ops.find(a, service, try params(a, "{\"query\":\"omega\"}"), cli.cli_caller);
    };
}

test "S6-T8 rule 7 through find: a damaged section 5 fails the first find and every later one with the rule's error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var dir = try publishBoundaries(a, tmp);
    defer dir.close(io);
    try rewriteOffsets(a, dir, struct {
        fn edit(docs: []Doc, _: []const hybrid.Document) void {
            const doc = &docs[docs.len - 1];
            doc.tokens[doc.tokens.len - 1].byte &= 0x0F; // length nibble 0
            doc.tokens[doc.tokens.len - 1].esc_l = &.{};
        }
    }.edit);
    const opened = try snapshot_open.openScoped(a, io, dir);
    defer opened.folder.close();
    const service = @import("service.zig").Service{ .engine = opened.engine, .folder = opened.folder };
    for (0..2) |_| try std.testing.expectError(error.OffsetsZeroLength, ops.find(a, service, try params(a, "{\"query\":\"solo\"}"), cli.cli_caller));
}

// ------------------------------------------------------- manifest bit 7

test "S6-T8: the manifest's bit 7 binds HYBLEX04 both ways, and only with bit 5" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var dir = try publishBoundaries(a, tmp);
    defer dir.close(io);
    const metadata = try manifest.decode(try dir.readFileAlloc(io, publication.current_manifest_file, a, .unlimited));
    const documents = try dir.readFileAlloc(io, metadata.documents_file, a, .unlimited);
    const lexical = try dir.readFileAlloc(io, metadata.lexical_file, a, .unlimited);
    try std.testing.expect(metadata.lexical_v4 and metadata.lexical_v3);
    _ = try manifest.validateSnapshotHeaders(metadata, documents, lexical);
    var off = metadata;
    off.lexical_v4 = false;
    try std.testing.expectError(error.InvalidLexicalSection, manifest.validateSnapshotHeaders(off, documents, lexical));
    var without_v3 = metadata;
    without_v3.lexical_v3 = false;
    try std.testing.expectError(error.InvalidLexicalSection, manifest.validateSnapshotHeaders(without_v3, documents, lexical));
    // A `HYBLEX03` content section under bit 7.
    const engine = try snapshot_open.open(a, io, dir);
    const v3 = try lexical_segment.encodeV3Alloc(a, try postings.withOffsetsCoding(a, engine.lexical_index, .pairs));
    try std.testing.expectEqualStrings(lexical_segment.magic_v3, v3[0..8]);
    var on = metadata;
    on.lexical_bytes = v3.len;
    on.lexical_checksum = std.mem.readInt(u64, v3[80..88], .little);
    try std.testing.expectError(error.InvalidLexicalSection, manifest.validateSnapshotHeaders(on, documents, v3));
    on.lexical_v4 = false;
    _ = try manifest.validateSnapshotHeaders(on, documents, v3);
    // Encoded: the flag round-trips, and a library before v2.5 (flags 0 to
    // 6) refuses it.
    const encoded = try manifest.encode(metadata, try a.alloc(u8, try manifest.encodedLength(metadata)));
    try std.testing.expectEqual(manifest.flag_lexical_v4, std.mem.readInt(u16, encoded[10..12], .little) & manifest.flag_lexical_v4);
    try std.testing.expect(std.mem.readInt(u16, encoded[10..12], .little) & ~@as(u16, 0x7f) != 0);
}

// ---------------------------- the writer's carry (rulings on the Report, 1b)

const source = @import("source.zig");

/// The walk `apply.offsetTableStarts` did per v4 table before item 1b: the
/// count varint, then per token its byte and one varint per escape nibble.
fn referenceOneByteTableEnd(bytes: []const u8, at_start: usize, length: u32) ?usize {
    var at = source.varintsEnd(bytes, at_start, 1) orelse return null;
    for (0..length) |_| {
        if (at >= bytes.len) return null;
        const byte = bytes[at];
        at += 1;
        const escapes = @as(usize, @intFromBool(byte & 0x0F == postings.offsets_escape)) + @intFromBool(byte >> 4 == postings.offsets_escape);
        at = source.varintsEnd(bytes, at, escapes) orelse return null;
    }
    return at;
}

fn randomVarint(list: *std.ArrayList(u8), a: std.mem.Allocator, random: std.Random) !void {
    const value: u32 = switch (random.uintLessThan(u8, 4)) {
        0 => random.uintLessThan(u32, 0x80),
        1 => random.uintLessThan(u32, 0x4000),
        2 => random.uintLessThan(u32, 0x20_0000),
        else => random.int(u32),
    };
    try postings.appendVarint(list, a, value);
}

test "S6-T8 item 1b: oneByteTableEnd ends where the per-token walk ends, or fails where it fails" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var prng = std.Random.DefaultPrng.init(0x5618_0001);
    const random = prng.random();
    var compared: usize = 0;
    var walked_fast: usize = 0;
    for (0..3000) |trial| {
        var list = std.ArrayList(u8).empty;
        for (0..random.uintLessThan(usize, 4)) |_| try list.append(a, random.int(u8));
        const at_start = list.items.len;
        // Escape density from none to every token.
        const densities = [_]u32{ 0, 0, 5, 50, 300, 1000 };
        const escape_per_mille = densities[trial % densities.len];
        const count: u32 = if (trial % 7 == 0) random.uintLessThan(u32, 400) else random.uintLessThan(u32, 70);
        try postings.appendVarint(&list, a, count);
        for (0..count) |_| {
            var g: u8 = random.uintLessThan(u8, 15);
            var l: u8 = random.uintLessThan(u8, 15);
            if (random.uintLessThan(u32, 1000) < escape_per_mille) g = 15;
            if (random.uintLessThan(u32, 1000) < escape_per_mille) l = 15;
            try list.append(a, g | (l << 4));
            if (g == 15) try randomVarint(&list, a, random);
            if (l == 15) try randomVarint(&list, a, random);
        }
        for (0..random.uintLessThan(usize, 20)) |_| try list.append(a, random.int(u8));
        const whole = list.items;
        // The true count, one off each way, and cuts of the section.
        for ([_]u32{ count, count +| 1, count -| 1, count +| 17 }) |length| {
            var cut = whole.len;
            while (true) {
                const bytes = whole[0..cut];
                const want = referenceOneByteTableEnd(bytes, at_start, length);
                try std.testing.expectEqual(want, postings.oneByteTableEnd(bytes, at_start, length));
                compared += 1;
                if (want != null and length >= 16) walked_fast += 1;
                if (cut <= at_start) break;
                cut -= @min(cut - at_start, 1 + random.uintLessThan(usize, @max(1, whole.len / 6)));
            }
        }
    }
    // Random bytes, no structure.
    for (0..3000) |_| {
        const bytes = try a.alloc(u8, random.uintLessThan(usize, 120));
        random.bytes(bytes);
        const length = random.uintLessThan(u32, 120);
        try std.testing.expectEqual(referenceOneByteTableEnd(bytes, 0, length), postings.oneByteTableEnd(bytes, 0, length));
        compared += 1;
    }
    try std.testing.expect(compared > 20_000 and walked_fast > 1000);
}

/// The reference for one carried v2 table (the ruling after the Verdict,
/// F1): v2's validation of that table as `lexical_segment.validatePositions`
/// states it (a `u32` count equal to the document's length, two varints per
/// token, every length at least 1, every end within a `u32`, the table
/// ending at `end`), null where it refuses; else the bytes
/// `appendOffsetsTable(.one_byte, ...)` writes for the same starts and
/// lengths. (Before the Verdict this reference read with a checked reader
/// that let a length of 0 through and the append then wrote 1: it pinned the
/// repair F1 names.)
fn referenceTranscode(a: std.mem.Allocator, offsets: []const u8, at_start: usize, end: usize, count: u32) !?[]const u8 {
    const bytes = offsets[0..end];
    if (bytes.len < at_start or bytes.len - at_start < 4) return null;
    if (std.mem.readInt(u32, bytes[at_start..][0..4], .little) != count) return null;
    var at = at_start + 4;
    const spans = try a.alloc(postings.TokenSpan, count);
    var start: u64 = 0;
    for (spans) |*span| {
        start += postings.readVarint(bytes, &at) orelse return null;
        const length = postings.readVarint(bytes, &at) orelse return null;
        if (length == 0 or start + length > std.math.maxInt(u32)) return null;
        span.* = .{ .start = @intCast(start), .length = length };
    }
    if (at != end) return null;
    var list = std.ArrayList(u8).empty;
    try postings.appendOffsetsTable(&list, a, .one_byte, spans);
    return list.items;
}

test "S6-T8 item 1b and F1: transcodePairsTable writes the bytes of v2's read and v4's append, and refuses with v2's error what v2's validation refuses" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var prng = std.Random.DefaultPrng.init(0x5618_0002);
    const random = prng.random();
    var equal: usize = 0;
    var refused: usize = 0;
    for (0..4000) |trial| {
        var list = std.ArrayList(u8).empty;
        for (0..random.uintLessThan(usize, 5)) |_| try list.append(a, random.int(u8));
        const at_start = list.items.len;
        const count: u32 = if (trial % 9 == 0) random.uintLessThan(u32, 300) else random.uintLessThan(u32, 40);
        var count_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &count_bytes, count, .little);
        try list.appendSlice(a, &count_bytes);
        for (0..count) |_| {
            const delta: u32 = switch (random.uintLessThan(u8, 8)) {
                0 => 0,
                1 => random.intRangeAtMost(u32, 12, 20),
                2 => random.uintLessThan(u32, 0x4000),
                3 => random.uintLessThan(u32, 0x10_0000),
                else => random.uintLessThan(u32, 12),
            };
            // A length of 0 (v2 refuses it) about once in 200 tokens.
            const length: u32 = switch (random.uintLessThan(u8, 8)) {
                0 => if (random.uintLessThan(u8, 25) == 0) 0 else 7,
                1 => random.intRangeAtMost(u32, 13, 17),
                2 => random.uintLessThan(u32, 400),
                else => 1 + random.uintLessThan(u32, 12),
            };
            // A varint with a needless continuation byte now and then,
            // which v2's reader accepts.
            if (random.uintLessThan(u8, 50) == 0 and delta < 0x80) {
                try list.appendSlice(a, &.{ @as(u8, @intCast(delta)) | 0x80, 0x00 });
            } else try postings.appendVarint(&list, a, delta);
            try postings.appendVarint(&list, a, length);
        }
        var end = list.items.len;
        var document_length = count;
        switch (trial % 10) {
            0 => end -= @min(end - at_start, 1 + random.uintLessThan(usize, 4)),
            1 => {
                try list.append(a, random.int(u8));
                end += 1;
            },
            2 => document_length = count +% 1,
            3 => if (count > 0) {
                document_length = count - 1;
            },
            else => {},
        }
        for (0..random.uintLessThan(usize, 6)) |_| try list.append(a, random.int(u8));
        const want = try referenceTranscode(a, list.items, at_start, end, document_length);
        var got = std.ArrayList(u8).empty;
        try got.appendSlice(a, "prefix");
        if (want) |bytes| {
            try postings.transcodePairsTable(&got, a, list.items, at_start, end, document_length);
            try std.testing.expectEqualStrings("prefix", got.items[0..6]);
            try std.testing.expectEqualSlices(u8, bytes, got.items[6..]);
            equal += 1;
        } else {
            try std.testing.expectError(error.InvalidPositions, postings.transcodePairsTable(&got, a, list.items, at_start, end, document_length));
            try std.testing.expectEqualStrings("prefix", got.items);
            refused += 1;
        }
    }
    if (!(equal > 2000 and refused > 1000)) std.debug.print("S6-T8 item 1b transcode: equal {d}, refused {d}\n", .{ equal, refused });
    try std.testing.expect(equal > 2000 and refused > 1000);
    // F1: a length of 0 anywhere in the table is refused, never written as 1.
    for (0..3) |position| {
        var zero = std.ArrayList(u8).empty;
        try zero.appendSlice(a, &.{ 3, 0, 0, 0 });
        for (0..3) |k| {
            try postings.appendVarint(&zero, a, 2);
            try postings.appendVarint(&zero, a, if (k == position) 0 else 4);
        }
        var out = std.ArrayList(u8).empty;
        try std.testing.expectEqual(@as(?[]const u8, null), try referenceTranscode(a, zero.items, 0, zero.items.len, 3));
        try std.testing.expectError(error.InvalidPositions, postings.transcodePairsTable(&out, a, zero.items, 0, zero.items.len, 3));
        try std.testing.expectEqual(@as(usize, 0), out.items.len);
    }
    // A gap whose zigzag does not fit a u32 is valid v2 that v4 cannot hold
    // (rule 5): refused apart, nothing written.
    var big = std.ArrayList(u8).empty;
    try big.appendSlice(a, &.{ 1, 0, 0, 0 });
    try postings.appendVarint(&big, a, 0xFFFF_FFF0);
    try postings.appendVarint(&big, a, 5);
    var out = std.ArrayList(u8).empty;
    try std.testing.expectError(error.GapNotRepresentable, postings.transcodePairsTable(&out, a, big.items, 0, big.items.len, 1));
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "S6-T8 item 1b: every table of a built index, coded as v2 and transcoded, is the fresh v4 section" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var texts = std.ArrayList([]const u8).empty;
    try texts.appendSlice(a, &example_texts);
    for (boundary_files) |f| try texts.append(a, f.text);
    const index = try buildOf(a, texts.items);
    const v2 = try postings.withOffsetsCoding(a, index, .pairs);
    const old = v2.positions.?.offsets;
    var out = std.ArrayList(u8).empty;
    var at: usize = 0;
    for (index.document_lengths) |length| {
        const end = source.varintsEnd(old, at + 4, @as(usize, length) * 2) orelse return error.TestUnexpectedResult;
        try postings.transcodePairsTable(&out, a, old, at, end, length);
        at = end;
    }
    try std.testing.expectEqual(old.len, at);
    try std.testing.expectEqualSlices(u8, index.positions.?.offsets, out.items);
    // And the fast walk finds each fresh table where the reference does.
    var fresh_at: usize = 0;
    for (index.document_lengths) |length| {
        const want = referenceOneByteTableEnd(index.positions.?.offsets, fresh_at, length).?;
        try std.testing.expectEqual(want, postings.oneByteTableEnd(index.positions.?.offsets, fresh_at, length).?);
        fresh_at = want;
    }
    try std.testing.expectEqual(index.positions.?.offsets.len, fresh_at);
}

// ------------------------------------- the boundary sweep (the Fifth Verdict)

/// A v2 table: `count_field` as its u32 count, then each token's start
/// delta and length as varints (each given as its value, or as raw bytes
/// where `raw` is set), then `tail`.
fn pairsTable(a: std.mem.Allocator, count_field: u32, tokens: []const [2]u64, tail: []const u8) ![]u8 {
    var list = std.ArrayList(u8).empty;
    var count_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &count_bytes, count_field, .little);
    try list.appendSlice(a, &count_bytes);
    for (tokens) |token| for (token) |value| try list.appendSlice(a, try varintBytes(a, value));
    try list.appendSlice(a, tail);
    return list.items;
}

/// Both v2 table readers refuse `offsets[at_start..end]` (`count` tokens)
/// with v2's error, and the transcode writes nothing.
fn expectPairsRefused(a: std.mem.Allocator, offsets: []const u8, at_start: usize, end: usize, count: u32, what: []const u8) !void {
    errdefer std.debug.print("S6-T8 sweep: {s} was not refused\n", .{what});
    try std.testing.expectError(error.InvalidPositions, postings.checkPairsTable(offsets, at_start, end, count));
    var out = std.ArrayList(u8).empty;
    try std.testing.expectError(error.InvalidPositions, postings.transcodePairsTable(&out, a, offsets, at_start, end, count));
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

/// Both accept it, and the transcode writes the reference's bytes.
fn expectPairsAccepted(a: std.mem.Allocator, offsets: []const u8, count: u32, what: []const u8) !void {
    errdefer std.debug.print("S6-T8 sweep: {s} was not accepted as v2 reads it\n", .{what});
    try postings.checkPairsTable(offsets, 0, offsets.len, count);
    var out = std.ArrayList(u8).empty;
    try postings.transcodePairsTable(&out, a, offsets, 0, offsets.len, count);
    try std.testing.expectEqualSlices(u8, (try referenceTranscode(a, offsets, 0, offsets.len, count)).?, out.items);
}

test "S6-T8 boundary sweep: checkPairsTable and transcodePairsTable refuse at each bound and accept one inside it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const two = [_][2]u64{ .{ 2, 3 }, .{ 4, 5 } };
    // The count's 4 bytes: 3 left, and a start one past the end.
    try expectPairsRefused(a, &.{ 0, 0, 0 }, 0, 3, 0, "a table of 3 bytes");
    const empty = try pairsTable(a, 0, &.{}, &.{});
    try std.testing.expectEqual(@as(usize, 4), empty.len);
    try expectPairsAccepted(a, empty, 0, "a table of exactly 4 bytes, no token");
    try expectPairsRefused(a, empty, empty.len + 1, empty.len, 0, "a table starting one past its end");
    // The count, one either side of the document's length.
    try expectPairsRefused(a, try pairsTable(a, 1, &two, &.{}), 0, (try pairsTable(a, 1, &two, &.{})).len, 2, "a count one less");
    try expectPairsRefused(a, try pairsTable(a, 3, &two, &.{}), 0, (try pairsTable(a, 3, &two, &.{})).len, 2, "a count one more");
    try expectPairsAccepted(a, try pairsTable(a, 2, &two, &.{}), 2, "the count equal");
    // One byte between the last token and the table's end.
    const left = try pairsTable(a, 2, &two, &.{0x00});
    try expectPairsRefused(a, left, 0, left.len, 2, "one byte left over");
    // The last varint cut: the delta's one byte only.
    const cut = try pairsTable(a, 1, &.{.{ 2, 3 }}, &.{});
    try expectPairsRefused(a, cut, 0, cut.len - 1, 1, "the length missing");
    // A varint of exactly 2^32, and 2^32 - 1.
    for ([_]usize{ 0, 1 }) |field| {
        var token = [2]u64{ 0, 1 };
        token[field] = @as(u64, 1) << 32;
        const big = try pairsTable(a, 1, &.{token}, &.{});
        try expectPairsRefused(a, big, 0, big.len, 1, if (field == 0) "a delta of exactly 2^32" else "a length of exactly 2^32");
    }
    // The end: exactly 2^32 refused, 2^32 - 1 accepted.
    const at_bound = try pairsTable(a, 1, &.{.{ 10, (@as(u64, 1) << 32) - 10 }}, &.{});
    try expectPairsRefused(a, at_bound, 0, at_bound.len, 1, "an end of exactly 2^32");
    try expectPairsAccepted(a, try pairsTable(a, 1, &.{.{ 10, (@as(u64, 1) << 32) - 11 }}, &.{}), 1, "an end of 2^32 - 1");
    // A length of 1 accepted, 0 refused.
    try expectPairsAccepted(a, try pairsTable(a, 1, &.{.{ 0, 1 }}, &.{}), 1, "a length of 1");
    const zero = try pairsTable(a, 1, &.{.{ 0, 0 }}, &.{});
    try expectPairsRefused(a, zero, 0, zero.len, 1, "a length of 0");
    // The transcode's fast path at a varint whose first byte is 0x80 (128 is
    // `80 01`), and its escapes at 14, 15 and 16 (a gap's zigzag and a
    // length).
    try expectPairsAccepted(a, try pairsTable(a, 3, &.{ .{ 128, 128 }, .{ 0, 128 }, .{ 256, 2 } }, &.{}), 3, "deltas and lengths of 128 and 256");
    for ([_]u64{ 14, 15, 16 }) |value| {
        // After (0, 20): the gap whose zigzag is `value`, and a length of `value`.
        const start: u64 = @intCast(20 + postings.unzigzag(value));
        try expectPairsAccepted(a, try pairsTable(a, 2, &.{ .{ 0, 20 }, .{ start, value } }, &.{}), 2, "a zigzag gap and a length of 14, 15 and 16");
    }
    // A gap's zigzag of exactly 2^32 (a start 2^31 after the previous end):
    // refused apart; 2^32 - 2 (2^31 - 1) accepted.
    var out = std.ArrayList(u8).empty;
    const far = try pairsTable(a, 1, &.{.{ @as(u64, 1) << 31, 1 }}, &.{});
    try std.testing.expectError(error.GapNotRepresentable, postings.transcodePairsTable(&out, a, far, 0, far.len, 1));
    try expectPairsAccepted(a, try pairsTable(a, 1, &.{.{ (@as(u64, 1) << 31) - 1, 1 }}, &.{}), 1, "a gap of 2^31 - 1");
}

test "S6-T8 boundary sweep: readVarint, source.varintsEnd and oneByteTableEnd at each bound" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // readVarint: 2^32 - 1 in five bytes; 2^32; a sixth byte; the end.
    var at: usize = 0;
    try std.testing.expectEqual(@as(?u32, std.math.maxInt(u32)), postings.readVarint(&.{ 0xFF, 0xFF, 0xFF, 0xFF, 0x0F }, &at));
    try std.testing.expectEqual(@as(usize, 5), at);
    at = 0;
    try std.testing.expectEqual(@as(?u32, null), postings.readVarint(&.{ 0x80, 0x80, 0x80, 0x80, 0x10 }, &at));
    try std.testing.expectEqual(@as(?u32, null), postings.readVarint(&.{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 }, &at));
    try std.testing.expectEqual(@as(?u32, null), postings.readVarint(&.{ 0x80, 0x80 }, &at));
    try std.testing.expectEqual(@as(?u32, null), postings.readVarint(&.{}, &at));
    try std.testing.expectEqual(@as(usize, 0), at);

    // varintsEnd: sixteen two-byte varints starting 0x80 (the block counts
    // end bytes only); exactly fifteen bytes for sixteen varints; fifteen
    // varints in sixteen bytes; a start at and one past the end.
    var twos = std.ArrayList(u8).empty;
    for (0..16) |_| try twos.appendSlice(a, &.{ 0x80, 0x01 });
    try std.testing.expectEqual(@as(?usize, 32), source.varintsEnd(twos.items, 0, 16));
    const zeros = [_]u8{0} ** 16;
    try std.testing.expectEqual(@as(?usize, null), source.varintsEnd(zeros[0..15], 0, 16));
    try std.testing.expectEqual(@as(?usize, 15), source.varintsEnd(&zeros, 0, 15));
    try std.testing.expectEqual(@as(?usize, 16), source.varintsEnd(&zeros, 0, 16));
    try std.testing.expectEqual(@as(?usize, null), source.varintsEnd(&zeros, zeros.len + 1, 16));
    try std.testing.expectEqual(@as(?usize, null), source.varintsEnd(&zeros, zeros.len, 1));
    try std.testing.expectEqual(@as(?usize, zeros.len), source.varintsEnd(&zeros, zeros.len, 0));

    // oneByteTableEnd: fifteen tokens with sixteen bytes after the count;
    // sixteen tokens with fifteen; a count of 128 (`80 01`) and 128 tokens;
    // a count cut at the end; a token byte missing.
    const plain = [_]u8{0x11} ** 17;
    try std.testing.expectEqual(@as(?usize, 16), postings.oneByteTableEnd(&plain, 0, 15));
    try std.testing.expectEqual(@as(?usize, null), postings.oneByteTableEnd(plain[0..16], 0, 16));
    try std.testing.expectEqual(@as(?usize, 17), postings.oneByteTableEnd(&plain, 0, 16));
    var long = std.ArrayList(u8).empty;
    try long.appendSlice(a, &.{ 0x80, 0x01 });
    try long.appendNTimes(a, 0x11, 128);
    try std.testing.expectEqual(@as(?usize, 130), postings.oneByteTableEnd(long.items, 0, 128));
    try std.testing.expectEqual(@as(?usize, null), postings.oneByteTableEnd(&.{0x80}, 0, 0));
    try std.testing.expectEqual(@as(?usize, null), postings.oneByteTableEnd(&.{0x01}, 0, 1));
    // An escape varint of 128 (`80 01`) after a token byte.
    try std.testing.expectEqual(@as(?usize, 4), postings.oneByteTableEnd(&.{ 0x01, 0xF1, 0x80, 0x01, 0x22 }, 0, 1));
}
