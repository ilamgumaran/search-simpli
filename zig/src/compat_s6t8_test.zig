//! S6-T8: the content lexical section `HYBLEX04` (section 5 at one byte per
//! token, manifest v2.5 bit 7) against the indexes written before it.
//!
//! - `tests/fixtures/index-v5-s6t7/` is `fixtures/family-folder/home` as
//!   `main` at 62324f9 writes it (manifest v2.4, `HYBLEX03`);
//!   `tests/fixtures/index-v3-s6t4/` as a534678 wrote it (before S6-T7,
//!   record v4 and `HYBSRC01`); `tests/fixtures/index-98c4a2b/` as 98c4a2b
//!   wrote it (before S6-T4, `HYBLEX02`). Each must open and answer under
//!   this library exactly as a fresh index of the same folder, its bytes
//!   untouched; its first update publishes one whole v2.5 generation whose
//!   sections are a fresh index's byte for byte, and still answers the
//!   same; a crash between writing and publishing leaves one whole
//!   generation, old or new.
//! - `tests/fixtures/index-lex4-s6t8/` is this writer's output for the same
//!   folder (`tests/fixtures/gen_index_lex4_s6t8.sh`): the writer still
//!   gives these bytes, and a library before v2.5 (flags 0 to 6) refuses
//!   its manifest at the flags before reading any section (the runs of
//!   62324f9's own `searchd` and C library are in
//!   `docs/evidence/s6-t8/old-library.txt`).
const std = @import("std");
const apply = @import("apply.zig");
const cli = @import("cli.zig");
const compat = @import("compat_98c4a2b_test.zig");
const lexical_segment = @import("lexical_segment.zig");
const manifest = @import("manifest.zig");
const publication = @import("publication.zig");
const snapshot_open = @import("snapshot_open.zig");

const io = std.testing.io;
const fixture_main = "../tests/fixtures/index-v5-s6t7";
const fixture_before_s6t7 = "../tests/fixtures/index-v3-s6t4";
const fixture_before_s6t4 = "../tests/fixtures/index-98c4a2b";
const fixture_new = "../tests/fixtures/index-lex4-s6t8";
const folder = "../fixtures/family-folder/home";
const files = [_][]const u8{ "MANIFEST", "INDEX-STATE.json", "documents-1.hybseg", "lexical-1.hyblex", "source-1.hybsrc", "state-1.hybstate", "filenames-1.hybseg", "filename-lexical-1.hyblex" };
const olds = [_][]const u8{ fixture_main, fixture_before_s6t7, fixture_before_s6t4 };
const shed =
    \\{"changes":[{"op":"add","root_id":"r-legacy","path":"shed.txt","content_base64":"VGhlIHNoZWQgbmVlZHMgYSBuZXcgbG9jay4K"}]}
;

/// The generation in `dir` is v2.5: bits 5, 6 and 7, the content section
/// `HYBLEX04` and the file-name section `HYBLEX03`.
fn expectV25(a: std.mem.Allocator, dir: std.Io.Dir) !manifest.Manifest {
    const metadata = try manifest.decode(try dir.readFileAlloc(io, publication.current_manifest_file, a, .unlimited));
    try std.testing.expect(metadata.lexical_v4 and metadata.lexical_v3 and metadata.text_once and metadata.has_positions);
    try std.testing.expectEqualStrings(lexical_segment.magic_v4, try compat.magicOf(a, dir, metadata.lexical_file));
    try std.testing.expectEqualStrings(lexical_segment.magic_v3, try compat.magicOf(a, dir, metadata.filename.?.lexical_file));
    return metadata;
}

/// A library before v2.5 refuses the manifest at its flags: magic, version
/// 2, then any flag outside bits 0 to 6 is `UnsupportedFlags`.
fn refusedBeforeV25(manifest_bytes: []const u8) bool {
    const known_before: u16 = 0x7f;
    if (manifest_bytes.len < 12 or !std.mem.eql(u8, manifest_bytes[0..8], "HYBMAN02")) return false;
    if (std.mem.readInt(u16, manifest_bytes[8..10], .little) != 2) return false;
    return std.mem.readInt(u16, manifest_bytes[10..12], .little) & ~known_before != 0;
}

fn copyOf(a: std.mem.Allocator, tmp: std.testing.TmpDir, from: []const u8, name: []const u8) !std.Io.Dir {
    try tmp.dir.createDir(io, name, .default_dir);
    const dir = try tmp.dir.openDir(io, name, .{ .iterate = true });
    try compat.copyFixture(a, from, dir);
    return dir;
}

/// Every bound section of the current generations of `a_dir` and `b_dir`
/// is the same bytes.
fn expectSameSections(a: std.mem.Allocator, a_dir: std.Io.Dir, b_dir: std.Io.Dir) !void {
    const x = try manifest.decode(try a_dir.readFileAlloc(io, publication.current_manifest_file, a, .unlimited));
    const y = try manifest.decode(try b_dir.readFileAlloc(io, publication.current_manifest_file, a, .unlimited));
    const names_x = [_][]const u8{ x.documents_file, x.lexical_file, x.source_file, x.filename.?.catalog_file, x.filename.?.lexical_file };
    const names_y = [_][]const u8{ y.documents_file, y.lexical_file, y.source_file, y.filename.?.catalog_file, y.filename.?.lexical_file };
    for (names_x, names_y) |nx, ny| {
        try std.testing.expectEqualSlices(u8, try a_dir.readFileAlloc(io, nx, a, .unlimited), try b_dir.readFileAlloc(io, ny, a, .unlimited));
    }
}

test "S6-T8: the committed v2.5 fixture is this writer's output, and a library before v2.5 refuses it at the flags" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var committed = try std.Io.Dir.cwd().openDir(io, fixture_new, .{});
    defer committed.close(io);
    _ = try expectV25(a, committed);
    const committed_manifest = try committed.readFileAlloc(io, publication.current_manifest_file, a, .unlimited);
    try std.testing.expect(refusedBeforeV25(committed_manifest));
    try std.testing.expectEqual(manifest.flag_lexical_v4, std.mem.readInt(u16, committed_manifest[10..12], .little) & ~@as(u16, 0x7f));
    for (olds) |old_path| {
        var old = try std.Io.Dir.cwd().openDir(io, old_path, .{});
        defer old.close(io);
        try std.testing.expect(!refusedBeforeV25(try old.readFileAlloc(io, publication.current_manifest_file, a, .unlimited)));
    }
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var fresh = try compat.freshIndex(a, tmp, "fresh");
    defer fresh.close(io);
    for (files) |name| {
        if (std.mem.eql(u8, name, "INDEX-STATE.json")) continue;
        try std.testing.expectEqualSlices(u8, try committed.readFileAlloc(io, name, a, .unlimited), try fresh.readFileAlloc(io, name, a, .unlimited));
    }
    // Against 62324f9's fixture only the content section and the manifest
    // differ, and the content section only in section 5.
    var main_fixture = try std.Io.Dir.cwd().openDir(io, fixture_main, .{});
    defer main_fixture.close(io);
    for ([_][]const u8{ "documents-1.hybseg", "source-1.hybsrc", "state-1.hybstate", "filenames-1.hybseg", "filename-lexical-1.hyblex" }) |name| {
        try std.testing.expectEqualSlices(u8, try main_fixture.readFileAlloc(io, name, a, .unlimited), try committed.readFileAlloc(io, name, a, .unlimited));
    }
    try compat.expectSameLexicalAsV3(a, try main_fixture.readFileAlloc(io, "lexical-1.hyblex", a, .unlimited), try committed.readFileAlloc(io, "lexical-1.hyblex", a, .unlimited));
}

test "S6-T8: indexes from 62324f9, a534678 and 98c4a2b open and answer exactly as a fresh v2.5 index, their bytes untouched" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var fresh = try compat.freshIndex(a, tmp, "fresh");
    defer fresh.close(io);
    _ = try expectV25(a, fresh);
    const want = try compat.answers(a, fresh);
    try std.testing.expect(want.len > 150);
    for (olds, 0..) |old_path, k| {
        var old = try copyOf(a, tmp, old_path, try std.fmt.allocPrint(a, "old{d}", .{k}));
        defer old.close(io);
        try std.testing.expect(!(try manifest.decode(try old.readFileAlloc(io, publication.current_manifest_file, a, .unlimited))).lexical_v4);
        try compat.expectSameAnswers(want, try compat.answers(a, old));
        var pristine = try std.Io.Dir.cwd().openDir(io, old_path, .{});
        defer pristine.close(io);
        for (files) |name| try std.testing.expectEqualSlices(u8, try pristine.readFileAlloc(io, name, a, .unlimited), try old.readFileAlloc(io, name, a, .unlimited));
    }
}

test "S6-T8: the first update of each older index publishes one whole v2.5 generation, a fresh index's sections, and answers the same" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var fresh = try compat.freshIndex(a, tmp, "fresh");
    defer fresh.close(io);
    const want = try compat.answers(a, fresh);
    for (olds, 0..) |old_path, k| {
        const name = try std.fmt.allocPrint(a, "old{d}", .{k});
        var old = try copyOf(a, tmp, old_path, name);
        defer old.close(io);
        // The folder unchanged: `index --update` publishes generation 2 in
        // the new format, every document carried.
        var sink: std.Io.Writer.Allocating = .init(a);
        try cli.runIndex(io, a, folder, try compat.tmpPath(a, tmp, name), .{ .update = true, .caps = .{ .filename_index = true } }, &sink.writer);
        const metadata = try expectV25(a, old);
        try std.testing.expectEqual(@as(u64, 2), metadata.generation);
        try expectSameSections(a, fresh, old);
        try compat.expectSameAnswers(want, try compat.answers(a, old));
        // A second publish (a new file) through `apply_changes` keeps the
        // format.
        _ = switch (try apply.applyChanges(a, io, old, shed, .{})) {
            .ok => |r| r,
            .failed => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(@as(u64, 3), (try expectV25(a, old)).generation);
    }
}

test "S6-T8: the first publish over 62324f9's format through apply_changes equals a fresh index of the result" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var old = try copyOf(a, tmp, fixture_main, "old");
    defer old.close(io);
    var new = try copyOf(a, tmp, fixture_new, "new");
    defer new.close(io);
    // The same change over the old format and over the new: one carry
    // transcodes section 5, the other copies it; the sections agree.
    for ([_]std.Io.Dir{ old, new }) |dir| _ = switch (try apply.applyChanges(a, io, dir, shed, .{})) {
        .ok => |r| r,
        .failed => return error.TestUnexpectedResult,
    };
    _ = try expectV25(a, old);
    _ = try expectV25(a, new);
    try expectSameSections(a, new, old);
    try compat.expectSameAnswers(try compat.answers(a, new), try compat.answers(a, old));
}

test "S6-T8: a crash during the first publish from 62324f9's format leaves the whole old generation, or after the manifest the whole new one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var before = try copyOf(a, tmp, fixture_main, "before");
    defer before.close(io);
    var after = try copyOf(a, tmp, fixture_main, "after");
    defer after.close(io);
    var plain = try copyOf(a, tmp, fixture_main, "plain");
    defer plain.close(io);
    const want_old = try compat.answers(a, plain);
    try std.testing.expectError(error.SimulatedCrash, apply.applyChanges(a, io, after, shed, .{ .fail_after_publish = true }));
    try std.testing.expectEqual(@as(u64, 2), (try expectV25(a, after)).generation);
    const new_answers = try compat.answers(a, after);
    // Before the manifest: every section of generation 2 written and
    // linked, `MANIFEST` still generation 1, whose sections are untouched.
    var listing = after.iterate();
    while (try listing.next(io)) |entry| {
        if (std.mem.indexOf(u8, entry.name, "-2.") == null) continue;
        try before.writeFile(io, .{ .sub_path = entry.name, .data = try after.readFileAlloc(io, entry.name, a, .unlimited) });
    }
    const still = try manifest.decode(try before.readFileAlloc(io, publication.current_manifest_file, a, .unlimited));
    try std.testing.expectEqual(@as(u64, 1), still.generation);
    try std.testing.expect(!still.lexical_v4);
    var pristine = try std.Io.Dir.cwd().openDir(io, fixture_main, .{});
    defer pristine.close(io);
    for (files) |name| {
        if (std.mem.eql(u8, name, "INDEX-STATE.json")) continue;
        try std.testing.expectEqualSlices(u8, try pristine.readFileAlloc(io, name, a, .unlimited), try before.readFileAlloc(io, name, a, .unlimited));
    }
    try compat.expectSameAnswers(want_old, try compat.answers(a, before));
    _ = switch (try apply.applyChanges(a, io, before, shed, .{})) {
        .ok => |r| r,
        .failed => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(u64, 3), (try expectV25(a, before)).generation);
    try compat.expectSameAnswers(new_answers, try compat.answers(a, before));
}

// ------------------- the ruling after the Verdict, F1: v2 damage at the first publish

const checksum = @import("checksum.zig");
const postings = @import("postings.zig");

/// One v2 token of section 5 as its raw varints (delta from the previous
/// start, length), re-emitted after an edit.
const V2Token = struct { delta: []const u8, length: []const u8 };
const V2Doc = struct { count: u32, tokens: []V2Token };

fn v2Varint(a: std.mem.Allocator, value: u64) ![]const u8 {
    var list = std.ArrayList(u8).empty;
    var rest = value;
    while (rest >= 0x80) : (rest >>= 7) try list.append(a, @as(u8, @truncate(rest)) | 0x80);
    try list.append(a, @truncate(rest));
    return list.items;
}

fn v2Raw(bytes: []const u8, at: *usize) []const u8 {
    const from = at.*;
    while (bytes[at.*] >= 0x80) at.* += 1;
    at.* += 1;
    return bytes[from..at.*];
}

/// The previous generation's content lexical section (v2-coded section 5)
/// in `dir`: its bytes, its document lengths and its tables.
fn v2Tables(a: std.mem.Allocator, dir: std.Io.Dir) !struct { good: []const u8, docs: []V2Doc } {
    const metadata = try manifest.decode(try dir.readFileAlloc(io, publication.current_manifest_file, a, .unlimited));
    const good = try dir.readFileAlloc(io, metadata.lexical_file, a, .unlimited);
    const header = try lexical_segment.inspect(good);
    const index = try lexical_segment.decodeWith(good, try a.alloc(postings.TermEntry, header.term_count), try a.alloc(postings.Posting, header.posting_count), try a.alloc(u32, header.document_count), .{ .validate_positions = true, .term_text_allocator = a });
    const sections = index.positions.?;
    try std.testing.expectEqual(postings.OffsetsCoding.pairs, sections.coding);
    const docs = try a.alloc(V2Doc, index.document_lengths.len);
    var at: usize = 0;
    for (index.document_lengths, docs) |length, *doc| {
        doc.count = std.mem.readInt(u32, sections.offsets[at..][0..4], .little);
        at += 4;
        doc.tokens = try a.alloc(V2Token, length);
        for (doc.tokens) |*token| token.* = .{ .delta = v2Raw(sections.offsets, &at), .length = v2Raw(sections.offsets, &at) };
    }
    try std.testing.expectEqual(sections.offsets.len, at);
    return .{ .good = good, .docs = docs };
}

fn v2Emit(a: std.mem.Allocator, docs: []const V2Doc) ![]u8 {
    var list = std.ArrayList(u8).empty;
    for (docs) |doc| {
        var count: [4]u8 = undefined;
        std.mem.writeInt(u32, &count, doc.count, .little);
        try list.appendSlice(a, &count);
        for (doc.tokens) |token| {
            try list.appendSlice(a, token.delta);
            try list.appendSlice(a, token.length);
        }
    }
    return list.items;
}

/// `dir`'s content lexical section with section 5 replaced by `offsets`,
/// the header's length, the section's checksum and the manifest resealed:
/// only the rule under test is broken.
fn v2Reseal(a: std.mem.Allocator, dir: std.Io.Dir, good: []const u8, offsets: []const u8) !void {
    const old_len = std.mem.readInt(u64, good[64..72], .little);
    const keep = good.len - old_len;
    const damaged = try a.alloc(u8, keep + offsets.len);
    @memcpy(damaged[0..keep], good[0..keep]);
    @memcpy(damaged[keep..], offsets);
    std.mem.writeInt(u64, damaged[64..72], offsets.len, .little);
    std.mem.writeInt(u64, damaged[80..88], checksum.compute(.xxh3_64, damaged[0..80], damaged[88..]), .little);
    var metadata = try manifest.decode(try dir.readFileAlloc(io, publication.current_manifest_file, a, .unlimited));
    try dir.writeFile(io, .{ .sub_path = metadata.lexical_file, .data = damaged });
    metadata.lexical_bytes = damaged.len;
    metadata.lexical_checksum = std.mem.readInt(u64, damaged[80..88], .little);
    try dir.writeFile(io, .{ .sub_path = publication.current_manifest_file, .data = try manifest.encode(metadata, try a.alloc(u8, try manifest.encodedLength(metadata))) });
}

const V2Damage = enum {
    zero_length_first,
    zero_length_last,
    end_past_u32,
    count_not_length,
    varint_sixth_byte,
    varint_fifth_byte_high,
    ends_inside_last_table,
    ends_inside_last_count,
    leftover_byte,
};

/// The v2 rules of section 5 (`lexical_segment.validatePositions`), each
/// broken once, at the section's last table where the rule has a last
/// element; the error the first publish refuses it with.
fn v2Damaged(a: std.mem.Allocator, docs_in: []const V2Doc, damage: V2Damage) !struct { offsets: []const u8, publish_error: anyerror } {
    const docs = try a.dupe(V2Doc, docs_in);
    for (docs) |*doc| doc.tokens = try a.dupe(V2Token, doc.tokens);
    var first: usize = 0;
    while (docs[first].tokens.len == 0) first += 1;
    var last: usize = docs.len - 1;
    while (docs[last].tokens.len == 0) last -= 1;
    const tail = &docs[last].tokens[docs[last].tokens.len - 1];
    var publish_error: anyerror = error.InvalidPositions;
    var cut: usize = 0;
    var extra: []const u8 = &.{};
    switch (damage) {
        .zero_length_first => docs[first].tokens[0].length = &.{0},
        .zero_length_last => tail.length = &.{0},
        .end_past_u32 => tail.delta = try v2Varint(a, std.math.maxInt(u32)),
        .count_not_length => docs[last].count += 1,
        .varint_sixth_byte => tail.length = &.{ 0x81, 0x80, 0x80, 0x80, 0x80, 0x00 },
        .varint_fifth_byte_high => tail.length = &.{ 0x81, 0x80, 0x80, 0x80, 0x10 },
        // The walk to each table's start (`apply.offsetTableStarts`) finds
        // these before any table is transcoded.
        .ends_inside_last_table => {
            cut = 1;
            publish_error = error.InvalidLexicalSection;
        },
        .ends_inside_last_count => {
            docs[docs.len - 1].tokens = &.{};
            cut = 2;
            publish_error = error.InvalidLexicalSection;
        },
        .leftover_byte => {
            extra = &.{0};
            publish_error = error.InvalidLexicalSection;
        },
    }
    var offsets = try v2Emit(a, docs);
    offsets = offsets[0 .. offsets.len - cut];
    return .{ .offsets = try std.mem.concat(a, u8, &.{ offsets, extra }), .publish_error = publish_error };
}

/// Every file of `dir` by name (`WRITER.LOCK` left out: a writer creates it
/// empty before it reads the manifest).
const Files = struct { names: [][]const u8, data: [][]const u8 };

fn snapshotFiles(a: std.mem.Allocator, dir: std.Io.Dir) !Files {
    var names = std.ArrayList([]const u8).empty;
    var listing = dir.iterate();
    while (try listing.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, "WRITER.LOCK")) continue;
        try names.append(a, try a.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lessThan);
    const data = try a.alloc([]const u8, names.items.len);
    for (names.items, data) |name, *bytes| bytes.* = try dir.readFileAlloc(io, name, a, .unlimited);
    return .{ .names = names.items, .data = data };
}

fn expectSameFiles(before: Files, after: Files) !void {
    try std.testing.expectEqual(before.names.len, after.names.len);
    for (before.names, after.names, before.data, after.data) |nx, ny, dx, dy| {
        try std.testing.expectEqualStrings(nx, ny);
        try std.testing.expectEqualSlices(u8, dx, dy);
    }
}

/// The old reader's verdict on `dir`'s current generation: v2's validation
/// of sections 4 and 5, as the first `find` runs it.
fn oldReaderVerdict(a: std.mem.Allocator, dir: std.Io.Dir) !void {
    const metadata = try manifest.decode(try dir.readFileAlloc(io, publication.current_manifest_file, a, .unlimited));
    const bytes = try dir.readFileAlloc(io, metadata.lexical_file, a, .unlimited);
    const header = try lexical_segment.inspect(bytes);
    const index = try lexical_segment.decodeWith(bytes, try a.alloc(postings.TermEntry, header.term_count), try a.alloc(postings.Posting, header.posting_count), try a.alloc(u32, header.document_count), .{ .validate_positions = false, .term_text_allocator = a });
    return lexical_segment.validatePositionSections(index);
}

fn publishError(a: std.mem.Allocator, tmp: std.testing.TmpDir, name: []const u8, dir: std.Io.Dir, through_apply: bool) anyerror {
    if (through_apply) {
        const outcome = apply.applyChanges(a, io, dir, shed, .{}) catch |err| return err;
        return switch (outcome) {
            .ok => error.TestUnexpectedResult,
            .failed => error.RefusedAsFailure,
        };
    }
    var sink: std.Io.Writer.Allocating = .init(a);
    const path = compat.tmpPath(a, tmp, name) catch |err| return err;
    cli.runIndex(io, a, folder, path, .{ .update = true, .caps = .{ .filename_index = true } }, &sink.writer) catch |err| return err;
    return error.TestUnexpectedResult;
}

test "S6-T8 F1: a length of 0 in one v2 token (the verifier's v2_first_publish case) is refused at the first publish, the old generation whole and byte-identical" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    for ([_]bool{ false, true }, [_][]const u8{ "zero-index", "zero-apply" }) |through_apply, name| {
        var dir = try copyOf(a, tmp, fixture_main, name);
        defer dir.close(io);
        const base = try v2Tables(a, dir);
        // One token in the middle of the section, as the verifier's case.
        const middle = base.docs.len / 2;
        var docs = try a.dupe(V2Doc, base.docs);
        var k = middle;
        while (docs[k].tokens.len < 2) k += 1;
        docs[k].tokens = try a.dupe(V2Token, docs[k].tokens);
        docs[k].tokens[1].length = &.{0};
        try v2Reseal(a, dir, base.good, try v2Emit(a, docs));
        // The old reader refuses it before any publish.
        try std.testing.expectError(error.InvalidPositions, oldReaderVerdict(a, dir));
        const before = try snapshotFiles(a, dir);
        try std.testing.expectEqual(error.InvalidPositions, publishError(a, tmp, name, dir, through_apply));
        // Nothing published: the same files, byte for byte, generation 1,
        // and the old reader still refuses it (no repaired highlight).
        try expectSameFiles(before, try snapshotFiles(a, dir));
        const metadata = try manifest.decode(try dir.readFileAlloc(io, publication.current_manifest_file, a, .unlimited));
        try std.testing.expectEqual(@as(u64, 1), metadata.generation);
        try std.testing.expect(!metadata.lexical_v4);
        try std.testing.expectError(error.InvalidPositions, oldReaderVerdict(a, dir));
    }
}

/// One v2 rule of section 5 broken once on a copy of `main`'s fixture
/// (the re-emitted tables checked first to be the fixture's own bytes): v2's
/// reader refuses it, and so does the first publish (`index --update`),
/// with `case.publish_error`, leaving every file byte-identical.
fn expectV2DamageRefused(damage: V2Damage) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var pristine = try copyOf(a, tmp, fixture_main, "pristine");
    defer pristine.close(io);
    const base = try v2Tables(a, pristine);
    try v2Reseal(a, pristine, base.good, try v2Emit(a, base.docs));
    try std.testing.expectEqualSlices(u8, base.good, try pristine.readFileAlloc(io, "lexical-1.hyblex", a, .unlimited));
    const name = try std.fmt.allocPrint(a, "v2-{s}", .{@tagName(damage)});
    var dir = try copyOf(a, tmp, fixture_main, name);
    defer dir.close(io);
    const case = try v2Damaged(a, base.docs, damage);
    try v2Reseal(a, dir, base.good, case.offsets);
    try std.testing.expectError(error.InvalidPositions, oldReaderVerdict(a, dir));
    const before = try snapshotFiles(a, dir);
    const got = publishError(a, tmp, name, dir, false);
    if (got != case.publish_error) {
        std.debug.print("S6-T8 F1: {s}: the first publish gave {s}, expected {s}\n", .{ @tagName(damage), @errorName(got), @errorName(case.publish_error) });
        return error.TestUnexpectedError;
    }
    try expectSameFiles(before, try snapshotFiles(a, dir));
    try std.testing.expectError(error.InvalidPositions, oldReaderVerdict(a, dir));
}

test "S6-T8 F1, v2 rule: a length of 0 in the first token is refused by the first publish" {
    try expectV2DamageRefused(.zero_length_first);
}

test "S6-T8 F1, v2 rule: a length of 0 in the last token is refused by the first publish" {
    try expectV2DamageRefused(.zero_length_last);
}

test "S6-T8 F1, v2 rule: an end past a u32 is refused by the first publish" {
    try expectV2DamageRefused(.end_past_u32);
}

test "S6-T8 F1, v2 rule: a count other than the document's length is refused by the first publish" {
    try expectV2DamageRefused(.count_not_length);
}

test "S6-T8 F1, v2 rule: a varint with a sixth byte is refused by the first publish" {
    try expectV2DamageRefused(.varint_sixth_byte);
}

test "S6-T8 F1, v2 rule: a varint whose fifth byte is above 0x0F is refused by the first publish" {
    try expectV2DamageRefused(.varint_fifth_byte_high);
}

test "S6-T8 F1, v2 rule: a section that ends inside the last table is refused by the first publish" {
    try expectV2DamageRefused(.ends_inside_last_table);
}

test "S6-T8 F1, v2 rule: a section that ends inside the last count is refused by the first publish" {
    try expectV2DamageRefused(.ends_inside_last_count);
}

test "S6-T8 F1, v2 rule: a byte after the last table is refused by the first publish" {
    try expectV2DamageRefused(.leftover_byte);
}

test "S6-T8 F1: a length of 0 in a table the first publish drops (its file removed) is refused too, the old generation byte-identical" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var dir = try copyOf(a, tmp, fixture_main, "dropped");
    defer dir.close(io);
    // The file of the middle document, and its documents.
    const engine = try snapshot_open.open(a, io, dir);
    const path = engine.documents[engine.documents.len / 2].path;
    const base = try v2Tables(a, dir);
    try std.testing.expectEqual(engine.documents.len, base.docs.len);
    const docs = try a.dupe(V2Doc, base.docs);
    var damaged: usize = 0;
    for (engine.documents, docs) |document, *doc| {
        if (!std.mem.eql(u8, document.path, path) or doc.tokens.len == 0) continue;
        doc.tokens = try a.dupe(V2Token, doc.tokens);
        doc.tokens[0].length = &.{0};
        damaged += 1;
    }
    try std.testing.expect(damaged > 0);
    try v2Reseal(a, dir, base.good, try v2Emit(a, docs));
    try std.testing.expectError(error.InvalidPositions, oldReaderVerdict(a, dir));
    const before = try snapshotFiles(a, dir);
    const remove = try std.fmt.allocPrint(a, "{{\"changes\":[{{\"op\":\"remove\",\"root_id\":\"r-legacy\",\"path\":\"{s}\"}}]}}", .{path});
    const got = if (apply.applyChanges(a, io, dir, remove, .{})) |outcome| switch (outcome) {
        .ok => error.TestUnexpectedResult,
        .failed => |failure| blk: {
            std.debug.print("S6-T8 F1 dropped: refused as a failure: {s}\n", .{failure.message});
            break :blk error.RefusedAsFailure;
        },
    } else |err| err;
    try std.testing.expectEqual(error.InvalidPositions, got);
    try expectSameFiles(before, try snapshotFiles(a, dir));
}
