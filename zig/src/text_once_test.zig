//! S6-T7 (`docs/documents-v5-source-v2-format.md`): documents record v5
//! and source section v2 (`HYBSRC02`).
//!
//! - Ruling 3: every kind of file the format document names (CR LF, a lone
//!   CR, no final newline, a BOM, an empty file, a file with no chunk, VT,
//!   FF, NEL, LS and PS inside lines) is rebuilt to its exact bytes, with
//!   `HYBSRC01`'s line map, SHA-256, `read_span` and `outline`.
//! - Ruling 11: every validity rule of both sections violated with the
//!   checksum recomputed, on sections where every multi-byte last element
//!   occurs (the last file-table entry's `shared`, suffix length and value;
//!   the last record's text length and start; the last source record's
//!   length, line count, chunk count and recipe value; the last map's last
//!   delta), each refused with the error the format document names.
//! - Ruling 9: a record v5 cannot code fails the encode with a named error.
//! - The manifest's `text_once` flag binds both sections.
const std = @import("std");
const checksum = @import("checksum.zig");
const chunker = @import("chunker.zig");
const hybrid = @import("hybrid.zig");
const indexer = @import("indexer.zig");
const manifest = @import("manifest.zig");
const segment = @import("segment.zig");
const segment_v5 = @import("segment_v5.zig");
const service_module = @import("service.zig");
const snapshot_open = @import("snapshot_open.zig");
const source = @import("source.zig");
const source_v2 = @import("source_v2.zig");

const io = std.testing.io;

// ------------------------------------------------------------------ corpus

const deep_a = "a" ** 150;
const deep_b = "b" ** 150;
const last_dir = "zz-last/" ++ ("c" ** 150) ++ "/";
const last_before = last_dir ++ ("d" ** 130) ++ ".txt";
const last_path = last_dir ++ ("e" ** 140) ++ ".txt";

const Kind = struct { path: []const u8, bytes: []const u8 };

/// Ruling 3's files, with names that say what they are.
const ruling3 = [_]Kind{
    .{ .path = "a-crlf.md", .bytes = "# Title\r\n\r\nline one of the body\r\nline two of the body\r\n\r\n## Second\r\n\r\nmore text here\r\n" },
    .{ .path = "a-crlf-short.txt", .bytes = "one line with crlf\r\n" },
    .{ .path = "b-lone-cr.txt", .bytes = "first part\rsecond part\rthird part\nfourth line\n" },
    .{ .path = "c-no-final-newline.txt", .bytes = "alpha line\nbeta line\ngamma line without newline" },
    .{ .path = "d-bom.md", .bytes = "\xEF\xBB\xBF# Bom heading\n\nbody text under it\n" },
    .{ .path = "e-empty.txt", .bytes = "" },
    .{ .path = "f-blank.txt", .bytes = "   \n\n \t \n" },
    .{ .path = "g-controls.txt", .bytes = "one\x0Btwo\x0Cthree\xC2\x85four\xE2\x80\xA8five\xE2\x80\xA9six\nnext line\nlast\x1Cfile sep\n" },
    .{ .path = "h-blank-lines.md", .bytes = "# H\n\n\n\nafter three blank lines\n\n\n## H2\n\n\ntext\n" },
    // A short chunk, then a long one (where an overlap of the bytes emitted
    // so far plus one is still shorter than the chunk).
    .{ .path = "i-short-then-long.md", .bytes = "# A\n\nx\n\n# B\n\n" ++ ("long section text " ** 20) ++ "\n" },
};

fn longFile(a: std.mem.Allocator, lines: usize, width: usize, last_width: usize) ![]u8 {
    var out = std.ArrayList(u8).empty;
    for (0..lines) |line| {
        const w = if (line + 1 == lines) last_width else width;
        try out.print(a, "{d:0>6} ", .{line});
        for (7..w) |k| try out.append(a, "abcdefghij klmnopqrst uvwxyz"[(line + k) % 28]);
        try out.append(a, '\n');
    }
    return out.items;
}

/// The corpus: ruling 3's files, paths sharing more than 255 bytes, and
/// last two files whose every field is a multi-byte varint.
fn writeCorpus(a: std.mem.Allocator, dir: std.Io.Dir) ![]const Kind {
    var all = std.ArrayList(Kind).empty;
    for (ruling3) |kind| try all.append(a, kind);
    for (0..12) |k| try all.append(a, .{
        .path = try std.fmt.allocPrint(a, "deep/{s}/{s}/note-{d:0>3}.txt", .{ deep_a, deep_b, k }),
        .bytes = try std.fmt.allocPrint(a, "deep note {d}\nwith a second line\n", .{k}),
    });
    try all.append(a, .{ .path = last_before, .bytes = try longFile(a, 40, 60, 60) });
    try all.append(a, .{ .path = last_path, .bytes = try longFile(a, 3500, 60, 300) });
    for (all.items) |kind| {
        if (std.fs.path.dirname(kind.path)) |parent| try dir.createDirPath(io, parent);
        try dir.writeFile(io, .{ .sub_path = kind.path, .data = kind.bytes });
    }
    return all.items;
}

const Indexed = struct {
    tmp: std.testing.TmpDir,
    root: std.Io.Dir,
    out: std.Io.Dir,
    files: []const Kind,

    fn init(a: std.mem.Allocator) !Indexed {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        try tmp.dir.createDirPath(io, "root");
        try tmp.dir.createDirPath(io, "out");
        const root = try tmp.dir.openDir(io, "root", .{ .iterate = true });
        const out = try tmp.dir.openDir(io, "out", .{ .iterate = true });
        const files = try writeCorpus(a, root);
        _ = try indexer.indexFolderIncremental(a, io, root, out, .v2, chunker.default_max_chars, chunker.default_overlap_lines, .{});
        return .{ .tmp = tmp, .root = root, .out = out, .files = files };
    }

    /// An index of exactly `files`.
    fn initFiles(a: std.mem.Allocator, files: []const Kind) !Indexed {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        try tmp.dir.createDirPath(io, "root");
        try tmp.dir.createDirPath(io, "out");
        const root = try tmp.dir.openDir(io, "root", .{ .iterate = true });
        const out = try tmp.dir.openDir(io, "out", .{ .iterate = true });
        for (files) |kind| try root.writeFile(io, .{ .sub_path = kind.path, .data = kind.bytes });
        _ = try indexer.indexFolderIncremental(a, io, root, out, .v2, chunker.default_max_chars, chunker.default_overlap_lines, .{});
        return .{ .tmp = tmp, .root = root, .out = out, .files = files };
    }

    fn deinit(indexed: *Indexed) void {
        indexed.root.close(io);
        indexed.out.close(io);
        indexed.tmp.cleanup();
    }

    fn sections(indexed: Indexed, a: std.mem.Allocator) !struct { metadata: manifest.Manifest, documents: []u8, source: []u8, lexical: []u8 } {
        const metadata = try manifest.decode(try indexed.out.readFileAlloc(io, "MANIFEST", a, .unlimited));
        return .{
            .metadata = metadata,
            .documents = try indexed.out.readFileAlloc(io, metadata.documents_file, a, .unlimited),
            .source = try indexed.out.readFileAlloc(io, metadata.source_file, a, .unlimited),
            .lexical = try indexed.out.readFileAlloc(io, metadata.lexical_file, a, .unlimited),
        };
    }
};

fn decodeDocuments(a: std.mem.Allocator, bytes: []const u8, has_source: bool) ![]hybrid.Document {
    const header = try segment.inspect(bytes);
    const documents = try a.alloc(hybrid.Document, header.document_count);
    const vectors = try a.alloc(f32, header.document_count * header.vector_dimensions);
    return segment.decodeInspectedWith(bytes, header, documents, vectors, a, has_source);
}

fn boundOf(a: std.mem.Allocator, documents_bytes: []const u8) !source.Bound {
    return .{ .documents_encoded = documents_bytes, .documents = try decodeDocuments(a, documents_bytes, true) };
}

test "S6-T7 ruling 3: every kind of file is rebuilt to its exact bytes, with HYBSRC01's map, SHA-256, read_span and outline" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var indexed = try Indexed.init(a);
    defer indexed.deinit();
    const s = try indexed.sections(a);
    try std.testing.expect(s.metadata.text_once);
    try std.testing.expectEqualStrings(source_v2.magic, s.source[0..8]);
    try std.testing.expectEqual(segment.version_v5, std.mem.readInt(u16, s.documents[8..10], .little));
    const bound = try boundOf(a, s.documents);
    const resident = try source.openIndexedBound(a, s.source, bound);
    var file = try indexed.out.openFile(io, s.metadata.source_file, .{});
    defer file.close(io);
    const streamed = (try source.openStreamedBound(a, a, io, file, s.source.len, bound)).section;

    // The same files as `HYBSRC01` (sorted by path, as the writer orders them).
    const sorted = try a.dupe(Kind, indexed.files);
    std.mem.sort(Kind, sorted, {}, struct {
        fn less(_: void, x: Kind, y: Kind) bool {
            return std.mem.order(u8, x.path, y.path) == .lt;
        }
    }.less);
    const inputs = try a.alloc(source.InputFile, sorted.len);
    for (sorted, inputs) |kind, *input| input.* = .{ .path = kind.path, .bytes = kind.bytes };
    const v1 = try source.openIndexed(a, try source.encode(a, inputs));
    try std.testing.expectEqual(v1.file_count, resident.file_count);

    var whole = std.ArrayList(u8).empty;
    var spans: usize = 0;
    for (sorted) |kind| {
        const old = v1.find(kind.path).?;
        for ([_]source.Section{ resident, streamed }) |section| {
            const entry = section.find(kind.path) orelse {
                std.debug.print("S6-T7: not retained: {s}\n", .{kind.path});
                return error.TestUnexpectedResult;
            };
            try std.testing.expectEqualSlices(u8, kind.bytes, try source.entryBytes(section, a, entry));
            try std.testing.expectEqual(old.line_count, entry.line_count);
            try std.testing.expectEqualSlices(u8, &old.sha256, &entry.sha256);
            try std.testing.expectEqual(old.encoding, entry.encoding);
            try std.testing.expectEqualSlices(u8, (try source.carriedRecord(old, true)).line_map, (try source.carriedRecord(entry, true)).line_map);
        }
        const entry = resident.find(kind.path).?;
        if (entry.v2_whole) try whole.print(a, " {s}", .{kind.path});
        // read_span: the whole file in 400-line pieces, every line alone
        // with two lines of context (small files), and across every chunk
        // boundary; outline. Each equal to HYBSRC01's answer.
        var ranges = std.ArrayList([3]u32).empty;
        var line: u32 = 1;
        while (line <= entry.line_count) : (line += 400) try ranges.append(a, .{ line, @min(entry.line_count, line + 399), 0 });
        if (entry.line_count < 50) {
            var each: u32 = 1;
            while (each <= entry.line_count) : (each += 1) try ranges.append(a, .{ each, each, 2 });
        }
        for (entry.v2_chunks) |chunk| {
            const before = if (chunk.start_line > 1) chunk.start_line - 1 else 1;
            try ranges.append(a, .{ before, @min(entry.line_count, chunk.start_line + 1), 1 });
            try ranges.append(a, .{ chunk.start_line, @min(entry.line_count, chunk.end_line), 0 });
        }
        for (ranges.items) |range| for ([_]source.Section{ resident, streamed }) |section| {
            const want = try source.readSpan(a, v1, kind.path, range[0], range[1], range[2]);
            const got = try source.readSpan(a, section, kind.path, range[0], range[1], range[2]);
            try expectSameSpan(a, want, got);
            spans += 1;
        };
        for ([_]source.Section{ resident, streamed }) |section| {
            const want = try source.outline(a, v1, kind.path);
            const got = try source.outline(a, section, kind.path);
            try std.testing.expectEqualStrings(try outlineJson(a, want), try outlineJson(a, got));
        }
    }
    // Kept whole: no chunk (empty, blank) or a chunk that is not an exact
    // run of the bytes (a CR LF file's multi-line chunks).
    for ([_][]const u8{ "a-crlf.md", "e-empty.txt", "f-blank.txt" }) |path| try std.testing.expect(resident.find(path).?.v2_whole);
    for ([_][]const u8{ "a-crlf-short.txt", "c-no-final-newline.txt", "d-bom.md", last_path, last_before }) |path| try std.testing.expect(!resident.find(path).?.v2_whole);
    std.debug.print("S6-T7 ruling 3: {d} files rebuilt exactly (resident and streamed); kept whole:{s}; {d} read_span ranges equal HYBSRC01's\n", .{ sorted.len, whole.items, spans });
}

/// Overlaps of 1 and 2 bytes and of the whole previous chunk
/// (`line-window-v1`, 1,600 characters, 3 lines of overlap): a window ends
/// on a short line after two blank ones, and the next window starts with
/// that line; or a window starts on a blank line, so the next one, a line
/// later, holds all of it.
const overlaps = [_]Kind{
    .{ .path = "k-overlap-1.txt", .bytes = ("p" ** 1590) ++ "\n\n\ny\n" ++ ("q" ** 1590) ++ "\ntail\n" },
    .{ .path = "k-overlap-2.txt", .bytes = ("p" ** 1590) ++ "\n\n\nyy\n" ++ ("q" ** 1590) ++ "\ntail\n" },
    .{ .path = "k-overlap-whole.txt", .bytes = "\nz\n" ++ ("w" ** 1595) ++ "\nw\nend line\n" },
};

test "S6-T7 Verdict finding 1: overlaps of 1 and 2 bytes and of the whole previous chunk are rebuilt exactly, through read_span and outline" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var indexed = try Indexed.initFiles(a, &overlaps);
    defer indexed.deinit();
    const s = try indexed.sections(a);
    try std.testing.expect(s.metadata.text_once);
    const bound = try boundOf(a, s.documents);
    const resident = try source.openIndexedBound(a, s.source, bound);
    var file = try indexed.out.openFile(io, s.metadata.source_file, .{});
    defer file.close(io);
    const streamed = (try source.openStreamedBound(a, a, io, file, s.source.len, bound)).section;
    const raw = try Src.parse(a, s.source);
    try std.testing.expectEqual(overlaps.len, raw.files.len);

    // The recipes hold what this test is for (the files are in path order).
    var one = false;
    var two = false;
    var whole = false;
    for (overlaps, raw.files) |kind, f| {
        const entry = resident.find(kind.path).?;
        try std.testing.expect(!entry.v2_whole);
        for (f.recipe, 0..) |v, i| {
            if (v == 1) one = true;
            if (v == 3) two = true;
            if (i > 0 and v & 1 == 1 and (v + 1) / 2 == entry.v2_chunks[i - 1].text.len) whole = true;
        }
    }
    try std.testing.expect(one and two and whole);

    const inputs = try a.alloc(source.InputFile, overlaps.len);
    for (overlaps, inputs) |kind, *input| input.* = .{ .path = kind.path, .bytes = kind.bytes };
    const v1 = try source.openIndexed(a, try source.encode(a, inputs));
    var spans: usize = 0;
    for (overlaps) |kind| {
        const entry = resident.find(kind.path).?;
        for ([_]source.Section{ resident, streamed }) |section| {
            try std.testing.expectEqualSlices(u8, kind.bytes, try source.entryBytes(section, a, section.find(kind.path).?));
            // Every range of lines, with and without context.
            var first: u32 = 1;
            while (first <= entry.line_count) : (first += 1) {
                var last: u32 = first;
                while (last <= entry.line_count) : (last += 1) for ([_]u32{ 0, 1 }) |context| {
                    const want = try source.readSpan(a, v1, kind.path, first, last, context);
                    const got = try source.readSpan(a, section, kind.path, first, last, context);
                    try expectSameSpan(a, want, got);
                    spans += 1;
                };
            }
            try std.testing.expectEqualStrings(try outlineJson(a, try source.outline(a, v1, kind.path)), try outlineJson(a, try source.outline(a, section, kind.path)));
        }
    }
    std.debug.print("S6-T7 overlaps: recipe values 1 and 3 and an overlap of the whole previous chunk rebuilt exactly; {d} read_span ranges equal HYBSRC01's\n", .{spans});
}

/// A leading byte-order mark, per chunker (S6-T7 Second Verdict, R1).
const marks = [_]Kind{
    .{ .path = "m-bom-only.md", .bytes = "\xef\xbb\xbf" },
    .{ .path = "m-bom-text.md", .bytes = "\xef\xbb\xbf\n\n# Title\n\nbody text\n" },
    .{ .path = "m-bom-text.txt", .bytes = "\xef\xbb\xbfplain text\nsecond line\n" },
};

test "S6-T7 Second Verdict R1: a byte-order mark is a gap in Markdown and keeps any other file whole; every file read back exactly" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var indexed = try Indexed.initFiles(a, &marks);
    defer indexed.deinit();
    const s = try indexed.sections(a);
    try std.testing.expect(s.metadata.text_once);
    const bound = try boundOf(a, s.documents);
    const resident = try source.openIndexedBound(a, s.source, bound);
    var file = try indexed.out.openFile(io, s.metadata.source_file, .{});
    defer file.close(io);
    const streamed = (try source.openStreamedBound(a, a, io, file, s.source.len, bound)).section;
    const raw = try Src.parse(a, s.source);
    try std.testing.expectEqual(marks.len, raw.files.len);
    for (raw.files) |f| try std.testing.expect(f.flags & 1 != 0); // `bom` set on all three

    // Markdown, mark only: no chunk, kept whole.
    const only = resident.find("m-bom-only.md").?;
    try std.testing.expect(only.v2_whole);
    try std.testing.expectEqual(@as(usize, 0), only.v2_chunks.len);
    // Markdown, mark then text: rebuilt; the chunk text does not hold the
    // mark, which is in the gap before the first chunk.
    const md = resident.find("m-bom-text.md").?;
    try std.testing.expect(!md.v2_whole);
    for (md.v2_chunks) |chunk| try std.testing.expect(!std.mem.startsWith(u8, chunk.text, "\xef\xbb\xbf"));
    try std.testing.expectEqual(@as(u64, 2 * 5), raw.files[1].recipe[0]); // the mark and two line feeds
    // Any other file, mark then text: the first chunk holds the mark; kept whole.
    const txt = resident.find("m-bom-text.txt").?;
    try std.testing.expect(txt.v2_whole);
    try std.testing.expect(std.mem.startsWith(u8, txt.v2_chunks[0].text, "\xef\xbb\xbf"));

    const inputs = try a.alloc(source.InputFile, marks.len);
    for (marks, inputs) |kind, *input| input.* = .{ .path = kind.path, .bytes = kind.bytes };
    const v1 = try source.openIndexed(a, try source.encode(a, inputs));
    var spans: usize = 0;
    for (marks) |kind| {
        const entry = resident.find(kind.path).?;
        for ([_]source.Section{ resident, streamed }) |section| {
            try std.testing.expectEqualSlices(u8, kind.bytes, try source.entryBytes(section, a, section.find(kind.path).?));
            var first: u32 = 1;
            while (first <= entry.line_count) : (first += 1) {
                var last: u32 = first;
                while (last <= entry.line_count) : (last += 1) for ([_]u32{ 0, 1 }) |context| {
                    try expectSameSpan(a, try source.readSpan(a, v1, kind.path, first, last, context), try source.readSpan(a, section, kind.path, first, last, context));
                    spans += 1;
                };
            }
            try std.testing.expectEqualStrings(try outlineJson(a, try source.outline(a, v1, kind.path)), try outlineJson(a, try source.outline(a, section, kind.path)));
        }
    }
    std.debug.print("S6-T7 byte-order mark: m-bom-only.md kept whole (no chunk), m-bom-text.md rebuilt (mark in the gap), m-bom-text.txt kept whole (mark in its chunk); {d} read_span ranges equal HYBSRC01's\n", .{spans});
}

fn expectSameSpan(a: std.mem.Allocator, want: source.SpanResult, got: source.SpanResult) !void {
    try std.testing.expectEqualStrings(try spanJson(a, want), try spanJson(a, got));
}

fn spanJson(a: std.mem.Allocator, result: source.SpanResult) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    var json = std.json.Stringify{ .writer = &out.writer };
    switch (result) {
        .ok => |span| try source.writeSpanJson(&json, span),
        .failed => |failure| try json.write(failure),
    }
    return out.written();
}

fn outlineJson(a: std.mem.Allocator, result: source.OutlineResult) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    var json = std.json.Stringify{ .writer = &out.writer };
    switch (result) {
        .ok => |data| try source.writeOutlineJson(&json, data),
        .failed => |failure| try json.write(failure),
    }
    return out.written();
}

// ------------------------------------------------- raw sections for rules

fn put(list: *std.ArrayList(u8), a: std.mem.Allocator, value: u64) !void {
    var buffer: [10]u8 = undefined;
    var at: usize = 0;
    segment_v5.putVarint(&buffer, &at, value);
    try list.appendSlice(a, buffer[0..at]);
}

const RawReader = struct {
    bytes: []const u8,
    at: usize,
    fn varint(r: *RawReader) u64 {
        var value: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            const byte = r.bytes[r.at];
            r.at += 1;
            value |= @as(u64, byte & 0x7f) << shift;
            if (byte & 0x80 == 0) return value;
            shift += 7;
        }
    }
    fn take(r: *RawReader, n: usize) []const u8 {
        defer r.at += n;
        return r.bytes[r.at..][0..n];
    }
};

const Entry = struct { shared: u64, suffix_length: u64, suffix: []const u8, value: u64 };
const Record = struct {
    flags: u64,
    id: []const u8,
    text_length: u64,
    start: u64,
    span: u64,
    chunker: u64,
    depth: u64,
    back: u64,
    section_length: u64,
    labels_length: u64,
    labels: []const u8,
    vector: []const u8,
    text: []const u8,
    section_path: []const u8,
};

/// A record v5 section as fields, emitted with its sizes and checksum
/// recomputed unless overridden.
const V5 = struct {
    flags: u16 = checksum.flag_xxh3,
    document_count: u32,
    dimensions: u32,
    file_count: u32,
    path_bytes: u64,
    table_bytes: ?u64 = null,
    records_bytes: ?u64 = null,
    entries: []Entry,
    records: []Record,
    table_tail: []const u8 = "",
    records_tail: []const u8 = "",
    records_cut: usize = 0,
    total_cut: usize = 0,
    total_tail: []const u8 = "",
    checksum_delta: u64 = 0,

    fn parse(a: std.mem.Allocator, bytes: []const u8) !V5 {
        var v = V5{
            .document_count = std.mem.readInt(u32, bytes[12..16], .little),
            .dimensions = std.mem.readInt(u32, bytes[16..20], .little),
            .file_count = std.mem.readInt(u32, bytes[20..24], .little),
            .path_bytes = std.mem.readInt(u64, bytes[40..48], .little),
            .entries = undefined,
            .records = undefined,
        };
        const table_bytes = std.mem.readInt(u64, bytes[24..32], .little);
        var r = RawReader{ .bytes = bytes, .at = segment_v5.header_length };
        v.entries = try a.alloc(Entry, v.file_count);
        for (v.entries) |*e| {
            e.shared = r.varint();
            e.suffix_length = r.varint();
            e.suffix = r.take(e.suffix_length);
            e.value = r.varint();
        }
        try std.testing.expectEqual(segment_v5.header_length + table_bytes, r.at);
        v.records = try a.alloc(Record, v.document_count);
        for (v.records) |*rec| {
            rec.flags = r.varint();
            if (rec.flags & 1 != 0) rec.id = r.take(r.varint()) else rec.id = r.take(10);
            rec.text_length = r.varint();
            rec.start = r.varint();
            rec.span = r.varint();
            rec.chunker = r.varint();
            rec.depth = r.varint();
            rec.back = r.varint();
            rec.section_length = if (rec.depth > 0) r.varint() else 0;
            rec.labels_length = 0;
            rec.labels = "";
            if (rec.flags & 4 != 0) {
                rec.labels_length = r.varint();
                rec.labels = r.take(rec.labels_length);
            }
            rec.vector = if (rec.flags & 2 != 0) r.take(4 * v.dimensions) else "";
            rec.text = r.take(rec.text_length);
            rec.section_path = r.take(rec.section_length);
        }
        try std.testing.expectEqual(bytes.len, r.at);
        return v;
    }

    fn clone(v: V5, a: std.mem.Allocator) !V5 {
        var copy = v;
        copy.entries = try a.dupe(Entry, v.entries);
        copy.records = try a.dupe(Record, v.records);
        return copy;
    }

    fn emit(v: V5, a: std.mem.Allocator) ![]u8 {
        var table = std.ArrayList(u8).empty;
        for (v.entries) |e| {
            try put(&table, a, e.shared);
            try put(&table, a, e.suffix_length);
            try table.appendSlice(a, e.suffix);
            try put(&table, a, e.value);
        }
        try table.appendSlice(a, v.table_tail);
        var records = std.ArrayList(u8).empty;
        for (v.records) |rec| {
            try put(&records, a, rec.flags);
            if (rec.flags & 1 != 0) try put(&records, a, rec.id.len);
            try records.appendSlice(a, rec.id);
            for ([_]u64{ rec.text_length, rec.start, rec.span, rec.chunker, rec.depth, rec.back }) |field| try put(&records, a, field);
            if (rec.depth > 0) try put(&records, a, rec.section_length);
            if (rec.flags & 4 != 0) {
                try put(&records, a, rec.labels_length);
                try records.appendSlice(a, rec.labels);
            }
            try records.appendSlice(a, rec.vector);
            try records.appendSlice(a, rec.text);
            try records.appendSlice(a, rec.section_path);
        }
        try records.appendSlice(a, v.records_tail);
        records.shrinkRetainingCapacity(records.items.len - v.records_cut);
        var out = std.ArrayList(u8).empty;
        try out.appendSlice(a, segment.magic);
        try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u16, segment_v5.version)));
        try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u16, v.flags)));
        for ([_]u32{ v.document_count, v.dimensions, v.file_count }) |field| try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u32, field)));
        for ([_]u64{ v.table_bytes orelse table.items.len, v.records_bytes orelse records.items.len, v.path_bytes, 0 }) |field| try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u64, field)));
        try out.appendSlice(a, table.items);
        try out.appendSlice(a, records.items);
        try out.appendSlice(a, v.total_tail);
        out.shrinkRetainingCapacity(out.items.len - v.total_cut);
        const bytes = out.items;
        if (bytes.len >= segment_v5.header_length) {
            const sum = checksum.compute(.xxh3_64, bytes[0..48], bytes[segment_v5.header_length..]) +% v.checksum_delta;
            std.mem.writeInt(u64, bytes[48..56], sum, .little);
        }
        return bytes;
    }
};

const SrcFile = struct { sha: [32]u8, flags: u64, length: u64, line_count: u64, chunk_count: u64, recipe: []u64 };

/// A `HYBSRC02` section as fields, likewise.
const Src = struct {
    magic: [8]u8 = source_v2.magic.*,
    version: u16 = source_v2.version,
    flags: u16 = checksum.flag_xxh3,
    file_count: u32,
    files: []SrcFile,
    maps: []const u8,
    residual: []const u8,
    records_tail: []const u8 = "",
    records_cut: usize = 0,
    maps_tail: []const u8 = "",
    maps_cut: usize = 0,
    residual_cut: usize = 0,
    total_cut: usize = 0,
    total_tail: []const u8 = "",
    checksum_delta: u64 = 0,

    fn parse(a: std.mem.Allocator, bytes: []const u8) !Src {
        const file_count = std.mem.readInt(u32, bytes[12..16], .little);
        const records_bytes: usize = @intCast(std.mem.readInt(u64, bytes[16..24], .little));
        const maps_bytes: usize = @intCast(std.mem.readInt(u64, bytes[24..32], .little));
        var r = RawReader{ .bytes = bytes[0 .. source.header_length + records_bytes], .at = source.header_length };
        const files = try a.alloc(SrcFile, file_count);
        for (files) |*f| {
            @memcpy(&f.sha, r.take(32));
            f.flags = r.varint();
            f.length = r.varint();
            f.line_count = r.varint();
            f.chunk_count = 0;
            f.recipe = &.{};
            if (f.flags & 2 == 0) {
                f.chunk_count = r.varint();
                f.recipe = try a.alloc(u64, f.chunk_count);
                for (f.recipe) |*value| value.* = r.varint();
            }
        }
        try std.testing.expectEqual(r.bytes.len, r.at);
        const maps_start = source.header_length + records_bytes;
        return .{ .file_count = file_count, .files = files, .maps = bytes[maps_start..][0..maps_bytes], .residual = bytes[maps_start + maps_bytes ..] };
    }

    fn clone(s: Src, a: std.mem.Allocator) !Src {
        var copy = s;
        copy.files = try a.dupe(SrcFile, s.files);
        for (copy.files) |*f| f.recipe = try a.dupe(u64, f.recipe);
        return copy;
    }

    fn emit(s: Src, a: std.mem.Allocator) ![]u8 {
        var records = std.ArrayList(u8).empty;
        for (s.files) |f| {
            try records.appendSlice(a, &f.sha);
            for ([_]u64{ f.flags, f.length, f.line_count }) |field| try put(&records, a, field);
            if (f.flags & 2 == 0) {
                try put(&records, a, f.chunk_count);
                for (f.recipe) |value| try put(&records, a, value);
            }
        }
        try records.appendSlice(a, s.records_tail);
        records.shrinkRetainingCapacity(records.items.len - s.records_cut);
        var maps = std.ArrayList(u8).empty;
        try maps.appendSlice(a, s.maps);
        try maps.appendSlice(a, s.maps_tail);
        maps.shrinkRetainingCapacity(maps.items.len - s.maps_cut);
        const residual = s.residual[0 .. s.residual.len - s.residual_cut];
        var out = std.ArrayList(u8).empty;
        try out.appendSlice(a, &s.magic);
        try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u16, s.version)));
        try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u16, s.flags)));
        try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u32, s.file_count)));
        for ([_]u64{ records.items.len, maps.items.len, residual.len, 0 }) |field| try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u64, field)));
        try out.appendSlice(a, records.items);
        try out.appendSlice(a, maps.items);
        try out.appendSlice(a, residual);
        try out.appendSlice(a, s.total_tail);
        out.shrinkRetainingCapacity(out.items.len - s.total_cut);
        const bytes = out.items;
        if (bytes.len >= source.header_length) {
            const sum = checksum.compute(.xxh3_64, bytes[0..40], bytes[source.header_length..]) +% s.checksum_delta;
            std.mem.writeInt(u64, bytes[40..48], sum, .little);
        }
        return bytes;
    }
};

/// Rules refused so far in the running test (counted by the two helpers).
var refused_rules: usize = 0;

fn expectDocumentsError(a: std.mem.Allocator, expected: anyerror, v: V5, has_source: bool, label: []const u8) !void {
    refused_rules += 1;
    const bytes = try v.emit(a);
    if (decodeDocuments(a, bytes, has_source)) |_| {
        std.debug.print("S6-T7 documents rule \"{s}\": accepted, want {s}\n", .{ label, @errorName(expected) });
        return error.TestUnexpectedResult;
    } else |err| {
        if (err != expected) {
            std.debug.print("S6-T7 documents rule \"{s}\": {s}, want {s}\n", .{ label, @errorName(err), @errorName(expected) });
            return error.TestUnexpectedResult;
        }
    }
}

/// The source section refused by both opens (resident and streamed).
fn expectSourceError(a: std.mem.Allocator, dir: std.Io.Dir, expected: anyerror, bytes: []const u8, bound: source.Bound, label: []const u8) !void {
    refused_rules += 1;
    if (source.openIndexedBound(a, bytes, bound)) |_| {
        std.debug.print("S6-T7 source rule \"{s}\": accepted (resident), want {s}\n", .{ label, @errorName(expected) });
        return error.TestUnexpectedResult;
    } else |err| if (err != expected) {
        std.debug.print("S6-T7 source rule \"{s}\": {s} (resident), want {s}\n", .{ label, @errorName(err), @errorName(expected) });
        return error.TestUnexpectedResult;
    }
    try dir.writeFile(io, .{ .sub_path = "rule.hybsrc", .data = bytes });
    var file = try dir.openFile(io, "rule.hybsrc", .{});
    defer file.close(io);
    if (source.openStreamedBound(a, a, io, file, bytes.len, bound)) |_| {
        std.debug.print("S6-T7 source rule \"{s}\": accepted (streamed), want {s}\n", .{ label, @errorName(expected) });
        return error.TestUnexpectedResult;
    } else |err| if (err != expected) {
        std.debug.print("S6-T7 source rule \"{s}\": {s} (streamed), want {s}\n", .{ label, @errorName(err), @errorName(expected) });
        return error.TestUnexpectedResult;
    }
}

/// The format document's walk of one recipe over its chunks' lengths, in
/// the test: the end position and the gap bytes, or null where a position
/// passes `length` or (with `overlap_rule`) an overlap k exceeds the bytes
/// emitted so far.
fn refWalk(recipe: []const u64, lengths: []const u64, length: u64, overlap_rule: bool) ?struct { end: u64, gaps: u64 } {
    var pos: u64 = 0;
    var gaps: u64 = 0;
    for (recipe, lengths) |v, chunk_length| {
        if (v & 1 == 0) {
            gaps += v / 2;
            pos += v / 2 + chunk_length;
        } else {
            const k = (v + 1) / 2;
            if (overlap_rule and k > pos) return null;
            if (k < chunk_length) pos += chunk_length - k;
        }
        if (pos > length) return null;
    }
    return .{ .end = pos, .gaps = gaps };
}

fn refResidual(recipe: []const u64, lengths: []const u64, length: u64, overlap_rule: bool) ?u64 {
    const walked = refWalk(recipe, lengths, length, overlap_rule) orelse return null;
    return walked.gaps + (length - walked.end);
}

fn varintBytes(value: u64) usize {
    return segment_v5.varintLength(value);
}

test "S6-T7 ruling 11: every documents v5 rule, violated with the checksum recomputed, is refused with its error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var indexed = try Indexed.init(a);
    defer indexed.deinit();
    const s = try indexed.sections(a);
    const base = try V5.parse(a, s.documents);
    // The base re-emits to its own bytes, and its last elements are
    // multi-byte varints.
    try std.testing.expectEqualSlices(u8, s.documents, try base.emit(a));
    const last_entry = base.entries[base.entries.len - 1];
    const last_record = base.records[base.records.len - 1];
    try std.testing.expect(varintBytes(last_entry.shared) > 1 and varintBytes(last_entry.suffix_length) > 1 and varintBytes(last_entry.value) > 1);
    try std.testing.expect(varintBytes(last_record.text_length) > 1 and varintBytes(last_record.start) > 1);
    // Some entry shares the cap of 255 bytes.
    var capped: ?usize = null;
    for (base.entries, 0..) |e, k| if (e.shared == segment_v5.shared_cap) {
        capped = k;
    };
    try std.testing.expect(capped != null);
    _ = try decodeDocuments(a, s.documents, true);
    refused_rules = 0;

    // 1. Header.
    var v = try base.clone(a);
    {
        const bytes = try v.emit(a);
        if (decodeDocuments(a, bytes[0..40], true)) |_| return error.TestUnexpectedResult else |err| try std.testing.expectEqual(error.Truncated, err);
        refused_rules += 1;
    }
    v.flags = 0;
    try expectDocumentsError(a, error.UnsupportedFlags, v, true, "flags 0");
    v.flags = 3;
    try expectDocumentsError(a, error.UnsupportedFlags, v, true, "flags 3");
    v = try base.clone(a);
    v.total_tail = "x";
    try expectDocumentsError(a, error.TrailingData, v, true, "a byte past the declared total");
    v = try base.clone(a);
    v.total_cut = 1;
    try expectDocumentsError(a, error.Truncated, v, true, "a byte short of the declared total");
    v = try base.clone(a);
    v.table_bytes = std.math.maxInt(u64);
    try expectDocumentsError(a, error.SizeOverflow, v, true, "table bytes overflow");
    // 2. Checksum.
    v = try base.clone(a);
    v.checksum_delta = 1;
    try expectDocumentsError(a, error.ChecksumMismatch, v, true, "checksum");
    // 3. Bounds.
    v = try base.clone(a);
    v.file_count = @intCast(s.documents.len); // table bytes < 4 x file count
    try expectDocumentsError(a, error.InvalidFileTable, v, true, "table bytes < 4 x file count");
    v = try base.clone(a);
    v.path_bytes = v.file_count - 1;
    try expectDocumentsError(a, error.InvalidFileTable, v, true, "path bytes < file count");
    v = try base.clone(a);
    v.path_bytes = 255 * @as(u64, v.file_count) + (try base.emit(a)).len;
    try expectDocumentsError(a, error.InvalidFileTable, v, true, "path bytes > 255 x file count + table bytes");
    v = try base.clone(a);
    {
        const records_bytes = (try base.emit(a)).len; // larger than the records area
        v.document_count = @intCast(records_bytes / 8 + 1);
    }
    try expectDocumentsError(a, error.InvalidRecord, v, true, "records bytes < 8 x document count");
    // 4. File table.
    v = try base.clone(a);
    v.entries[capped.?].shared = 256;
    try expectDocumentsError(a, error.InvalidFileTable, v, true, "shared 256");
    {
        // The cap on its own (S6-T7 Verdict, finding 3): the capped entry's
        // two paths share more than 255 bytes, so `shared` 256 with the
        // suffix one byte shorter decodes the same path, in order, with the
        // same path bytes; only "shared at most 255" refuses it. The same
        // entry at exactly 255 is the base, which decodes (above).
        const e = base.entries[capped.?];
        try std.testing.expect(std.mem.eql(u8, (try fullPath(a, base, capped.? - 1))[0..256], (try fullPath(a, base, capped.?))[0..256]));
        v = try base.clone(a);
        v.entries[capped.?].shared = 256;
        v.entries[capped.?].suffix = e.suffix[1..];
        v.entries[capped.?].suffix_length = e.suffix_length - 1;
        try std.testing.expectEqualStrings(try fullPath(a, base, capped.?), try fullPath(a, v, capped.?));
        try expectDocumentsError(a, error.InvalidFileTable, v, true, "shared 256 on a common prefix over 255, the path unchanged");
    }
    v = try base.clone(a);
    v.entries[1].shared = v.entries[0].suffix_length + 1;
    try expectDocumentsError(a, error.InvalidFileTable, v, true, "shared past the previous path");
    v = try base.clone(a);
    v.entries[0].shared = 1;
    try expectDocumentsError(a, error.InvalidFileTable, v, true, "entry 0 shares");
    v = try base.clone(a);
    v.entries[2].suffix_length = 0;
    v.entries[2].suffix = "";
    try expectDocumentsError(a, error.InvalidFileTable, v, true, "empty suffix");
    v = try base.clone(a);
    v.table_bytes = null;
    v.entries[v.entries.len - 1].suffix_length += 1000;
    try expectDocumentsError(a, error.InvalidFileTable, v, true, "suffix past the area");
    {
        // Two neighbours swapped: out of order.
        v = try base.clone(a);
        var swap: usize = 1;
        while (v.entries[swap].shared != 0 or v.entries[swap - 1].shared != 0) swap += 1;
        const first = v.entries[swap - 1];
        v.entries[swap - 1] = v.entries[swap];
        v.entries[swap] = first;
        try expectDocumentsError(a, error.UnsortedPaths, v, true, "two paths swapped");
        // A shorter `shared` than the paths have in common: not canonical.
        v = try base.clone(a);
        var k: usize = 1;
        while (v.entries[k].shared == 0 or v.entries[k].shared >= segment_v5.shared_cap) k += 1;
        const e = v.entries[k];
        const prev_full = try fullPath(a, base, k - 1);
        v.entries[k] = .{ .shared = e.shared - 1, .suffix_length = e.suffix_length + 1, .suffix = try std.mem.concat(a, u8, &.{ prev_full[e.shared - 1 ..][0..1], e.suffix }), .value = e.value };
        try expectDocumentsError(a, error.UnsortedPaths, v, true, "shared one short (not canonical)");
        // At the cap, the same path twice.
        v = try base.clone(a);
        const c = capped.?;
        const capped_full = try fullPath(a, base, c);
        v.entries[c + 1] = .{ .shared = 255, .suffix_length = capped_full.len - 255, .suffix = capped_full[255..], .value = v.entries[c + 1].value };
        try expectDocumentsError(a, error.UnsortedPaths, v, true, "a path repeated at the cap");
    }
    v = try base.clone(a);
    v.path_bytes -= 1;
    try expectDocumentsError(a, error.InvalidFileTable, v, true, "decoded paths pass the header's");
    v = try base.clone(a);
    v.document_count -= 1;
    v.records_cut = 0;
    try expectDocumentsError(a, error.InvalidFileTable, v, true, "chunk counts pass the document count");
    v = try base.clone(a);
    {
        var k: usize = 0;
        while (v.entries[k].value >> 1 == 0) k += 1;
        v.entries[k].value = 0;
    }
    try expectDocumentsError(a, error.InvalidFileTable, v, true, "no chunk, not retained");
    try expectDocumentsError(a, error.InvalidFileTable, base, false, "retained without a source section");
    v = try base.clone(a);
    v.table_tail = "\x00";
    try expectDocumentsError(a, error.TrailingData, v, true, "a byte left in the file table");
    v = try base.clone(a);
    v.path_bytes += 1;
    try expectDocumentsError(a, error.InvalidFileTable, v, true, "decoded paths short of the header's");
    v = try base.clone(a);
    v.document_count += 1;
    try expectDocumentsError(a, error.InvalidFileTable, v, true, "chunk counts short of the document count");
    // 5. Records.
    const n = base.records.len - 1;
    v = try base.clone(a);
    v.records[n].flags |= 8;
    try expectDocumentsError(a, error.UnsupportedFlags, v, true, "unknown record flag");
    v = try base.clone(a);
    {
        // The records area ends inside the last record's text length varint.
        const rec = v.records[n];
        const after_length = rec.text.len + rec.section_path.len + rec.vector.len + rec.labels.len +
            (if (rec.flags & 4 != 0) varintBytes(rec.labels_length) else 0) + (if (rec.depth > 0) varintBytes(rec.section_length) else 0) +
            varintBytes(rec.back) + varintBytes(rec.depth) + varintBytes(rec.chunker) + varintBytes(rec.span) + varintBytes(rec.start);
        v.records_cut = after_length + varintBytes(rec.text_length) - 1;
    }
    try expectDocumentsError(a, error.InvalidRecord, v, true, "a varint past the area");
    v = try base.clone(a);
    v.records[n].start = 0;
    try expectDocumentsError(a, error.InvalidCitation, v, true, "start line 0");
    v = try base.clone(a);
    v.records[n].span = std.math.maxInt(u32);
    try expectDocumentsError(a, error.InvalidCitation, v, true, "span past u32");
    v = try base.clone(a);
    v.records[n].chunker = 65536;
    try expectDocumentsError(a, error.InvalidSection, v, true, "chunker 65536");
    v = try base.clone(a);
    v.records[n].depth = 65536;
    v.records[n].section_length = 0;
    try expectDocumentsError(a, error.InvalidSection, v, true, "depth 65536");
    v = try base.clone(a);
    v.records[n].back = v.records[n].start + 1;
    try expectDocumentsError(a, error.InvalidSection, v, true, "heading back past start");
    v = try base.clone(a);
    v.records[n].depth = 2;
    v.records[n].back = 1;
    v.records[n].section_length = 0;
    try expectDocumentsError(a, error.InvalidSection, v, true, "depth 2, no section path");
    v = try base.clone(a);
    v.records[n].flags |= 4;
    v.records[n].labels_length = 0;
    try expectDocumentsError(a, error.InvalidRequiredLabels, v, true, "labels of length 0");
    v = try base.clone(a);
    v.records[n].flags |= 4;
    v.records[n].labels_length = 3;
    v.records[n].labels = "b\na";
    try expectDocumentsError(a, error.InvalidRequiredLabels, v, true, "labels out of order");
    v = try base.clone(a);
    v.records[n].flags |= 2;
    try expectDocumentsError(a, error.InvalidVectorDimensions, v, true, "a vector with dimensions 0");
    v = try base.clone(a);
    v.records[n].text_length += 1000;
    try expectDocumentsError(a, error.InvalidRecord, v, true, "text past the area");
    v = try base.clone(a);
    v.records_tail = "\x00";
    try expectDocumentsError(a, error.TrailingData, v, true, "a byte after the last record");

    // Ruling 5: an overlong varint is accepted (and decodes the same).
    {
        var bytes = std.ArrayList(u8).empty;
        const good = try base.emit(a);
        // Entry 0's `shared` (0) written as 0x80 0x00, the table one byte longer.
        try bytes.appendSlice(a, good[0..segment_v5.header_length]);
        try bytes.appendSlice(a, "\x80\x00");
        try bytes.appendSlice(a, good[segment_v5.header_length + 1 ..]);
        const table_bytes = std.mem.readInt(u64, good[24..32], .little) + 1;
        std.mem.writeInt(u64, bytes.items[24..32], table_bytes, .little);
        std.mem.writeInt(u64, bytes.items[48..56], checksum.compute(.xxh3_64, bytes.items[0..48], bytes.items[56..]), .little);
        const want = try decodeDocuments(a, good, true);
        const got = try decodeDocuments(a, bytes.items, true);
        for (want, got) |w, g| {
            try std.testing.expectEqualStrings(w.path, g.path);
            try std.testing.expectEqualStrings(w.id, g.id);
        }
    }
    std.debug.print("S6-T7 ruling 11: {d} documents v5 rules refused with their errors; an overlong varint accepted\n", .{refused_rules});
}

/// A read refused by the SHA-256 check, with v1's error and wording.
fn expectShaRefused(result: source.BytesResult) !void {
    switch (result) {
        .failed => |failure| try std.testing.expectEqualStrings(source.unavailable_prefix ++ " (" ++ source.sha256_mismatch_name ++ ")", failure.message),
        .ok => {
            std.debug.print("S6-T7 every read: a changed file was returned, not refused by its SHA-256\n", .{});
            return error.TestUnexpectedResult;
        },
    }
}

fn expectRead(result: source.BytesResult) !void {
    switch (result) {
        .ok => {},
        .failed => |failure| {
            std.debug.print("S6-T7 every read: an unchanged file refused: {s}\n", .{failure.message});
            return error.TestUnexpectedResult;
        },
    }
}

fn fullPath(a: std.mem.Allocator, v: V5, index: usize) ![]const u8 {
    var path = std.ArrayList(u8).empty;
    for (v.entries[0 .. index + 1]) |e| {
        path.shrinkRetainingCapacity(e.shared);
        try path.appendSlice(a, e.suffix);
    }
    return path.items;
}

test "S6-T7 ruling 11: every HYBSRC02 rule, violated with the checksum recomputed, is refused with its error (resident and streamed)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var indexed = try Indexed.init(a);
    defer indexed.deinit();
    const s = try indexed.sections(a);
    const bound = try boundOf(a, s.documents);
    const base = try Src.parse(a, s.source);
    try std.testing.expectEqualSlices(u8, s.source, try base.emit(a));
    const last = base.files[base.files.len - 1];
    try std.testing.expect(last.flags & 2 == 0);
    try std.testing.expect(varintBytes(last.length) > 1 and varintBytes(last.line_count) > 1 and varintBytes(last.chunk_count) > 1 and varintBytes(last.recipe[last.recipe.len - 1]) > 1);
    {
        // The last map's last delta (the 300-byte last line) is multi-byte.
        const section = try source.openIndexedBound(a, s.source, bound);
        const entry = section.file(section.file_count - 1);
        const map = (try source.carriedRecord(entry, true)).line_map;
        try std.testing.expect(map.len >= 2 and map[map.len - 2] & 0x80 != 0);
    }
    _ = try source.openIndexedBound(a, s.source, bound);
    const dir = indexed.tmp.dir;
    refused_rules = 0;
    const whole_index = blk: {
        for (base.files, 0..) |f, k| if (f.flags & 2 != 0 and f.length > 0) break :blk k;
        unreachable;
    };
    const empty_index = blk: {
        for (base.files, 0..) |f, k| if (f.length == 0) break :blk k;
        unreachable;
    };

    // 1. Header.
    try expectSourceError(a, dir, error.Truncated, s.source[0..40], bound, "shorter than the header");
    var x = try base.clone(a);
    x.magic = "HYBSRC03".*;
    try expectSourceError(a, dir, error.BadMagic, try x.emit(a), bound, "magic");
    x = try base.clone(a);
    x.version = 3;
    try expectSourceError(a, dir, error.UnsupportedVersion, try x.emit(a), bound, "version 3");
    x = try base.clone(a);
    x.flags = 0;
    try expectSourceError(a, dir, error.UnsupportedFlags, try x.emit(a), bound, "flags 0 (FNV-1a)");
    x.flags = 3;
    try expectSourceError(a, dir, error.UnsupportedFlags, try x.emit(a), bound, "flags 3");
    x = try base.clone(a);
    x.total_tail = "x";
    try expectSourceError(a, dir, error.TrailingData, try x.emit(a), bound, "a byte past the declared total");
    x = try base.clone(a);
    x.total_cut = 1;
    try expectSourceError(a, dir, error.Truncated, try x.emit(a), bound, "a byte short of the declared total");
    // 2. Checksum.
    x = try base.clone(a);
    x.checksum_delta = 1;
    try expectSourceError(a, dir, error.ChecksumMismatch, try x.emit(a), bound, "checksum");
    // 3. File count.
    x = try base.clone(a);
    x.file_count += 1;
    try expectSourceError(a, dir, error.SourceFileCountMismatch, try x.emit(a), bound, "file count one more than retained");
    // A section with no documents to bind it.
    if (source.openIndexedBound(a, s.source, null)) |_| return error.TestUnexpectedResult else |err| try std.testing.expectEqual(error.SourceNeedsDocuments, err);
    refused_rules += 1;
    // 4. Bounds.
    x = try base.clone(a);
    {
        const records_len = (try x.emit(a)).len - source.header_length - x.maps.len - x.residual.len;
        x.records_cut = records_len - (35 * x.file_count - 1);
    }
    try expectSourceError(a, dir, error.InvalidFileTable, try x.emit(a), bound, "records bytes < 35 x file count");
    x = try base.clone(a);
    x.maps_cut = x.maps.len - (x.file_count - 1);
    try expectSourceError(a, dir, error.InvalidFileTable, try x.emit(a), bound, "maps bytes < file count");
    // 5. Records.
    {
        // A path the documents section holds that v1's path rule refuses.
        const text = "hello there\n";
        const documents = [_]hybrid.Document{.{ .id = "0123456789abcdef0123", .text = text, .path = "x/../ok.txt", .start_line = 1, .end_line = 1, .source_doc_index = 0 }};
        const bad_documents = try segment_v5.encodeAlloc(a, &documents, &.{"x/../ok.txt"});
        var good_documents_list = documents;
        good_documents_list[0].path = "ok.txt";
        const one = try source_v2.encodeMarked(a, &.{.{ .path = "ok.txt", .bytes = text, .first_chunk = 0, .chunk_count = 1 }}, &good_documents_list, source.NoMarks{});
        try expectSourceError(a, dir, error.InvalidPath, one, try boundOf(a, bad_documents), "a path v1's rule refuses");
    }
    x = try base.clone(a);
    x.files[0].flags |= 4;
    try expectSourceError(a, dir, error.InvalidFileTable, try x.emit(a), bound, "unknown record flag");
    x = try base.clone(a);
    x.files[empty_index].flags &= ~@as(u64, 2);
    x.files[empty_index].chunk_count = 0;
    try expectSourceError(a, dir, error.InvalidFileTable, try x.emit(a), bound, "no chunk, not whole");
    x = try base.clone(a);
    {
        const f = &x.files[x.files.len - 1];
        f.chunk_count -= 1;
        f.recipe = f.recipe[0 .. f.recipe.len - 1];
    }
    try expectSourceError(a, dir, error.InvalidFileTable, try x.emit(a), bound, "chunk count one short of the documents'");
    x = try base.clone(a);
    x.files[x.files.len - 1].recipe[0] = 1;
    try expectSourceError(a, dir, error.InvalidFileTable, try x.emit(a), bound, "an overlap past what was emitted");
    {
        // The rule on its own (S6-T7 Verdict, finding 2): an overlap k one
        // byte longer than the bytes emitted before a later chunk, with the
        // record's length lowered so the residual total, every position
        // bound and every other rule still hold. Only "k > pos" refuses it
        // (the walk), before any read's SHA-256.
        const section = try source.openIndexedBound(a, s.source, bound);
        var placed: ?struct { file: usize, recipe: []u64, length: u64 } = null;
        search: for (base.files, 0..) |f, n| {
            if (f.flags & 2 != 0) continue;
            const chunks = section.file(n).v2_chunks;
            const lengths = try a.alloc(u64, chunks.len);
            for (chunks, lengths) |chunk, *length| length.* = chunk.text.len;
            const want = refResidual(f.recipe, lengths, f.length, true).?;
            var pos: u64 = 0;
            for (f.recipe, lengths, 0..) |value, length, i| {
                if (i > 0 and pos + 1 < length) {
                    const recipe = try a.dupe(u64, f.recipe);
                    recipe[i] = 2 * (pos + 1) - 1;
                    // Residual = gaps + length - end position: solve for length.
                    const loose = refWalk(recipe, lengths, std.math.maxInt(u64), false).?;
                    if (want + loose.end >= loose.gaps) {
                        const new_length = want + loose.end - loose.gaps;
                        if (refResidual(recipe, lengths, new_length, false)) |got| if (got == want and refResidual(recipe, lengths, new_length, true) == null) {
                            placed = .{ .file = n, .recipe = recipe, .length = new_length };
                            break :search;
                        };
                    }
                }
                if (value & 1 == 0) pos += value / 2 + length else {
                    const k = (value + 1) / 2;
                    if (k < length) pos += length - k;
                }
            }
        }
        x = try base.clone(a);
        x.files[placed.?.file].recipe = placed.?.recipe;
        x.files[placed.?.file].length = placed.?.length;
        try expectSourceError(a, dir, error.InvalidFileTable, try x.emit(a), bound, "an overlap one byte past what was emitted, the residual total kept");
    }
    x = try base.clone(a);
    x.files[x.files.len - 1].recipe[0] = 2 * (last.length + 1);
    try expectSourceError(a, dir, error.InvalidFileTable, try x.emit(a), bound, "a gap past the file's length");
    x = try base.clone(a);
    x.residual_cut = 1;
    try expectSourceError(a, dir, error.InvalidFileTable, try x.emit(a), bound, "a residual run past the area");
    x = try base.clone(a);
    x.files[x.files.len - 1].line_count += 1;
    try expectSourceError(a, dir, error.InvalidLineMap, try x.emit(a), bound, "a map past the maps area");
    // 6. After the last record.
    x = try base.clone(a);
    x.records_tail = "\x00";
    try expectSourceError(a, dir, error.TrailingData, try x.emit(a), bound, "a byte after the last record");
    x = try base.clone(a);
    x.maps_tail = "\x00";
    try expectSourceError(a, dir, error.InvalidLineMap, try x.emit(a), bound, "a byte after the last map");
    x = try base.clone(a);
    x.residual = try std.mem.concat(a, u8, &.{ x.residual, "z" });
    try expectSourceError(a, dir, error.InvalidFileTable, try x.emit(a), bound, "a residual byte left over");

    // Every read: a residual byte of a kept-whole file changed (re-sealed):
    // that file answers the SHA-256 check, every other reads.
    {
        x = try base.clone(a);
        var residual_at: usize = 0;
        const section = try source.openIndexedBound(a, s.source, bound);
        const victim = section.file(whole_index);
        residual_at = victim.text_offset;
        const changed = try a.dupe(u8, x.residual);
        changed[residual_at] ^= 0x01;
        x.residual = changed;
        const bytes = try x.emit(a);
        try dir.writeFile(io, .{ .sub_path = "read.hybsrc", .data = bytes });
        var file = try dir.openFile(io, "read.hybsrc", .{});
        defer file.close(io);
        const streamed = (try source.openStreamedBound(a, a, io, file, bytes.len, bound)).section;
        for ([_]source.Section{ try source.openIndexedBound(a, bytes, bound), streamed }) |opened| {
            for (0..opened.file_count) |k| {
                const result = try opened.fileBytes(a, opened.file(k));
                if (k == whole_index) {
                    try expectShaRefused(result);
                } else try expectRead(result);
            }
        }
        refused_rules += 1;
    }
    // Every read: a chunk's text changed in the documents section
    // (re-sealed): the file it rebuilds answers the SHA-256 check.
    {
        var docs = try V5.parse(a, s.documents);
        const section = try source.openIndexedBound(a, s.source, bound);
        const target = section.find("c-no-final-newline.txt").?;
        try std.testing.expect(!target.v2_whole);
        var k: usize = 0;
        while (docs.records[k].text.ptr != target.v2_chunks[0].text.ptr) k += 1;
        const text = try a.dupe(u8, docs.records[k].text);
        text[0] ^= 0x20;
        docs.records[k].text = text;
        const changed = try docs.emit(a);
        const changed_bound = try boundOf(a, changed);
        const opened = try source.openIndexedBound(a, s.source, changed_bound);
        try expectShaRefused(try opened.fileBytes(a, opened.find("c-no-final-newline.txt").?));
        try expectRead(try opened.fileBytes(a, opened.find("d-bom.md").?));
        refused_rules += 1;
    }
    std.debug.print("S6-T7 ruling 11: {d} HYBSRC02 rules refused with their errors, resident and streamed (two of them at a read)\n", .{refused_rules});
}

test "S6-T7 ruling 9: a record v5 cannot code fails the encode with a named error" {
    const a = std.testing.allocator;
    const no_path = [_]hybrid.Document{.{ .id = "0123456789abcdef0123", .text = "x\n", .path = "", .start_line = 1, .end_line = 1 }};
    try std.testing.expectError(error.RecordNotEncodableV5, segment_v5.encodeAlloc(a, &no_path, &.{}));
    const line_zero = [_]hybrid.Document{.{ .id = "0123456789abcdef0123", .text = "x\n", .path = "a.txt", .start_line = 0, .end_line = 0 }};
    try std.testing.expectError(error.RecordNotEncodableV5, segment_v5.encodeAlloc(a, &line_zero, &.{}));
    try std.testing.expectError(error.RecordNotEncodableV5, segment_v5.encodeAlloc(a, &.{}, &.{""}));
    // Records out of path order, and an ordinal that is not the retained one.
    const unsorted = [_]hybrid.Document{
        .{ .id = "0123456789abcdef0123", .text = "x\n", .path = "b.txt", .start_line = 1, .end_line = 1 },
        .{ .id = "0123456789abcdef0124", .text = "y\n", .path = "a.txt", .start_line = 1, .end_line = 1 },
    };
    try std.testing.expectError(error.UnsortedPaths, segment_v5.encodeAlloc(a, &unsorted, &.{}));
    const wrong_ordinal = [_]hybrid.Document{.{ .id = "0123456789abcdef0123", .text = "x\n", .path = "a.txt", .start_line = 1, .end_line = 1, .source_doc_index = 1 }};
    try std.testing.expectError(error.SourceIndexMismatch, segment_v5.encodeAlloc(a, &wrong_ordinal, &.{"a.txt"}));
}

test "S6-T7: the manifest's text_once flag binds record v5 and HYBSRC02 both ways" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var indexed = try Indexed.init(a);
    defer indexed.deinit();
    const s = try indexed.sections(a);
    _ = try manifest.validateSnapshotHeaders(s.metadata, s.documents, s.lexical);
    try manifest.validateSource(s.metadata, s.source);
    var off = s.metadata;
    off.text_once = false;
    try std.testing.expectError(error.InvalidDocumentSection, manifest.validateSnapshotHeaders(off, s.documents, s.lexical));
    try std.testing.expectError(error.InvalidSourceSection, manifest.validateSource(off, s.source));
    // A `HYBSRC01` section under the flag.
    const files = [_]source.InputFile{.{ .path = "a.txt", .bytes = "x\n" }};
    const old = try source.encode(a, &files);
    var on = s.metadata;
    on.source_bytes = old.len;
    on.source_checksum = std.mem.readInt(u64, old[40..48], .little);
    try std.testing.expectError(error.InvalidSourceSection, manifest.validateSource(on, old));
    // A library before v2.4 (flags 0 to 5) refuses the manifest at its flags.
    const encoded = try indexed.out.readFileAlloc(io, "MANIFEST", a, .unlimited);
    // (S6-T8: a writer since v2.5 also sets bit 7, `lexical_v4`.)
    try std.testing.expect(std.mem.readInt(u16, encoded[10..12], .little) & ~@as(u16, 0x3f) == manifest.flag_text_once | manifest.flag_lexical_v4);
}

test "S6-T7: an update carries unchanged files' records, maps and residual runs byte for byte, and the result is a fresh index's" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var indexed = try Indexed.init(a);
    defer indexed.deinit();
    // One file changes; the update must equal a fresh index of the result.
    try indexed.root.writeFile(io, .{ .sub_path = "c-no-final-newline.txt", .data = "alpha line\nbeta line changed\ngamma\n" });
    _ = try indexer.indexFolderIncremental(a, io, indexed.root, indexed.out, .v2, chunker.default_max_chars, chunker.default_overlap_lines, .{});
    const updated = try indexed.sections(a);
    try std.testing.expectEqual(@as(u64, 2), updated.metadata.generation);
    try indexed.tmp.dir.createDirPath(io, "fresh");
    var fresh_dir = try indexed.tmp.dir.openDir(io, "fresh", .{ .iterate = true });
    defer fresh_dir.close(io);
    _ = try indexer.indexFolderIncremental(a, io, indexed.root, fresh_dir, .v2, chunker.default_max_chars, chunker.default_overlap_lines, .{});
    const fresh_metadata = try manifest.decode(try fresh_dir.readFileAlloc(io, "MANIFEST", a, .unlimited));
    try std.testing.expectEqualSlices(u8, try fresh_dir.readFileAlloc(io, fresh_metadata.documents_file, a, .unlimited), updated.documents);
    try std.testing.expectEqualSlices(u8, try fresh_dir.readFileAlloc(io, fresh_metadata.source_file, a, .unlimited), updated.source);
    try std.testing.expectEqualSlices(u8, try fresh_dir.readFileAlloc(io, fresh_metadata.lexical_file, a, .unlimited), updated.lexical);
}
