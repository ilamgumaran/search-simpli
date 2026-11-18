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
//!   through a published index and `find`.
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

/// One file per boundary value, each one chunk (`line-window-v1`).
const boundary_files = [_]struct { name: []const u8, text: []const u8 }{
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
    try tmp.dir.createDir(io, "src", .default_dir);
    var src = try tmp.dir.openDir(io, "src", .{});
    defer src.close(io);
    for (boundary_files) |f| try src.writeFile(io, .{ .sub_path = f.name, .data = f.text });
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
    // Rule 2: the count equals the document's length.
    v = try cloneDocs(a, base.docs);
    v[last_doc].count = try varintBytes(a, base.lengths[last_doc] + 1);
    try expectRefused(a, good, try emitDocs(a, v, &.{}), error.OffsetsCountMismatch, "the last count one more");
    v = try cloneDocs(a, base.docs);
    v[0].count = try varintBytes(a, base.lengths[0] - 1);
    try expectRefused(a, good, try emitDocs(a, v, &.{}), error.OffsetsCountMismatch, "the first count one less");
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
    // Rule 10: an end past a u32 (the last token's length 2^32 - 1).
    v = try cloneDocs(a, base.docs);
    v[last_doc].tokens[last_tok].esc_l = &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0x0F };
    try expectRefused(a, good, try emitDocs(a, v, &.{}), error.OffsetsEndOverflow, "an end past 2^32 - 1");
    // Rule 12: no byte left over (a zero byte, and a whole valid-looking
    // token after the last document).
    try expectRefused(a, good, try emitDocs(a, base.docs, &.{0x00}), error.OffsetsTrailingData, "a byte left over");
    try expectRefused(a, good, try emitDocs(a, base.docs, &.{0x22}), error.OffsetsTrailingData, "a token byte left over");

    // Accepted, as documented: an overlong escape (15 as `8F 00`), and a
    // gap nibble of 0 (a token starting where the previous one ends).
    v = try cloneDocs(a, base.docs);
    v[0].tokens[1].esc_l = &.{ 0x95, 0x00 };
    _ = try decodeBoth(a, try withOffsets(a, good, try emitDocs(a, v, &.{})), true);
    std.debug.print("S6-T8: {d} damaged sections 5 refused with their rules' errors (rules 1-10 and 12), eager and lazy; an overlong escape accepted\n", .{refused_rules});
    try std.testing.expectEqual(@as(usize, 23), refused_rules);
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
    var metadata = try manifest.decode(try dir.readFileAlloc(io, publication.current_manifest_file, a, .unlimited));
    const good = try dir.readFileAlloc(io, metadata.lexical_file, a, .unlimited);
    const engine = try snapshot_open.open(a, io, dir);
    const docs = try cloneDocs(a, try parseDocs(a, engine.lexical_index.positions.?.offsets, engine.lexical_index.document_lengths));
    edit(docs, engine.documents);
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

test "S6-T8 rule 9 through find: a damaged section 5 fails the first find and every later one with the rule's error" {
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
