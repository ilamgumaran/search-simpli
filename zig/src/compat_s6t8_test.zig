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
const ops = @import("ops.zig");

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

// ------------------- the ruling after the Second Verdict, F3: the tables the first publish drops

/// A v2 rule broken in the table of a document the first publish drops.
/// The first five are the rules `postings.checkPairsTable` enforces on a
/// dropped table; the table walk (`apply.offsetTableStarts`) finds a byte
/// left over before any table is checked.
const DroppedRule = enum { zero_length, count_not_length, end_past_u32, varint_sixth_byte, varint_fifth_byte_high, leftover_byte };
const DroppedAt = enum { first, middle, last };

/// `rule` broken in one document's table, the section's first, a middle or
/// its last, on a copy of `main`'s fixture; then that document's file
/// removed through `apply_changes`, so its table is dropped, not carried:
/// the old reader refuses the section, and so does the first publish, with
/// the rule's error, leaving generation 1 and every file byte-identical.
fn expectDroppedDamageRefused(rule: DroppedRule, where: DroppedAt) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const name = try std.fmt.allocPrint(a, "dropped-{s}-{s}", .{ @tagName(rule), @tagName(where) });
    var dir = try copyOf(a, tmp, fixture_main, name);
    defer dir.close(io);
    const engine = try snapshot_open.open(a, io, dir);
    const base = try v2Tables(a, dir);
    try std.testing.expectEqual(engine.documents.len, base.docs.len);
    // The document: the section's first or last exactly, or the first
    // with a token from the middle on.
    const k = switch (where) {
        .first => 0,
        .last => base.docs.len - 1,
        .middle => blk: {
            var m = base.docs.len / 2;
            while (base.docs[m].tokens.len == 0) m += 1;
            break :blk m;
        },
    };
    try std.testing.expect(base.docs[k].tokens.len > 0);
    try std.testing.expect(k + 1 < base.docs.len or where == .last);
    const docs = try a.dupe(V2Doc, base.docs);
    docs[k].tokens = try a.dupe(V2Token, docs[k].tokens);
    const tail = &docs[k].tokens[docs[k].tokens.len - 1];
    var expected: anyerror = error.InvalidPositions;
    var offsets: []const u8 = undefined;
    switch (rule) {
        .zero_length => tail.length = &.{0},
        .count_not_length => docs[k].count += 1,
        .end_past_u32 => tail.delta = try v2Varint(a, std.math.maxInt(u32)),
        .varint_sixth_byte => tail.length = &.{ 0x81, 0x80, 0x80, 0x80, 0x80, 0x00 },
        .varint_fifth_byte_high => tail.length = &.{ 0x81, 0x80, 0x80, 0x80, 0x10 },
        .leftover_byte => expected = error.InvalidLexicalSection,
    }
    if (rule == .leftover_byte) {
        offsets = try std.mem.concat(a, u8, &.{ try v2Emit(a, docs[0 .. k + 1]), &.{0}, try v2Emit(a, docs[k + 1 ..]) });
    } else offsets = try v2Emit(a, docs);
    try v2Reseal(a, dir, base.good, offsets);
    try std.testing.expectError(error.InvalidPositions, oldReaderVerdict(a, dir));
    const before = try snapshotFiles(a, dir);
    const remove = try std.fmt.allocPrint(a, "{{\"changes\":[{{\"op\":\"remove\",\"root_id\":\"r-legacy\",\"path\":\"{s}\"}}]}}", .{engine.documents[k].path});
    const got = if (apply.applyChanges(a, io, dir, remove, .{})) |outcome| switch (outcome) {
        .ok => error.TestUnexpectedResult,
        .failed => error.RefusedAsFailure,
    } else |err| err;
    if (got != expected) {
        std.debug.print("S6-T8 F3: {s} at the {s} document ({d} of {d}): the first publish gave {s}, expected {s}\n", .{ @tagName(rule), @tagName(where), k, base.docs.len, @errorName(got), @errorName(expected) });
        return error.TestUnexpectedError;
    }
    try expectSameFiles(before, try snapshotFiles(a, dir));
    const metadata = try manifest.decode(try dir.readFileAlloc(io, publication.current_manifest_file, a, .unlimited));
    try std.testing.expectEqual(@as(u64, 1), metadata.generation);
    try std.testing.expect(!metadata.lexical_v4);
}

fn expectDroppedDamageRefusedEverywhere(rule: DroppedRule) !void {
    for ([_]DroppedAt{ .first, .middle, .last }) |where| try expectDroppedDamageRefused(rule, where);
}

test "S6-T8 F3, dropped table: a length of 0 in the first, a middle or the last document's table, that file removed, is refused by the first publish" {
    try expectDroppedDamageRefusedEverywhere(.zero_length);
}

test "S6-T8 F3, dropped table: a count other than the document's length in the first, a middle or the last table, that file removed, is refused by the first publish" {
    try expectDroppedDamageRefusedEverywhere(.count_not_length);
}

test "S6-T8 F3, dropped table: an end past a u32 in the first, a middle or the last table, that file removed, is refused by the first publish" {
    try expectDroppedDamageRefusedEverywhere(.end_past_u32);
}

test "S6-T8 F3, dropped table: a varint with a sixth byte in the first, a middle or the last table, that file removed, is refused by the first publish" {
    try expectDroppedDamageRefusedEverywhere(.varint_sixth_byte);
}

test "S6-T8 F3, dropped table: a varint whose fifth byte is above 0x0F in the first, a middle or the last table, that file removed, is refused by the first publish" {
    try expectDroppedDamageRefusedEverywhere(.varint_fifth_byte_high);
}

test "S6-T8 F3, dropped table: a byte left over after the first, a middle or the last table, that file removed, is refused by the first publish (the table walk)" {
    try expectDroppedDamageRefusedEverywhere(.leftover_byte);
}

// ------------------- the ruling after the Third Verdict: every refusal site, both paths, three documents

/// Where the damaged table goes: through the first publish as a carried
/// table (an unrelated file added, every old document carried), or as the
/// table of a document whose file that publish removes.
const TablePath = enum { carried, dropped };

/// The section's first document, a middle one (the first with a token from
/// the middle on) or its last; the first and last exactly, so a check
/// skipped for either end is seen.
fn tablePosition(docs_len: usize, where: DroppedAt, has_tokens: anytype) usize {
    return switch (where) {
        .first => 0,
        .last => docs_len - 1,
        .middle => blk: {
            var m = docs_len / 2;
            while (!has_tokens.at(m)) m += 1;
            break :blk m;
        },
    };
}

fn v2Value(raw: []const u8) u64 {
    var value: u64 = 0;
    for (raw, 0..) |byte, i| value |= @as(u64, byte & 0x7F) << @intCast(7 * i);
    return value;
}

/// `value` as a varint of exactly `n` bytes (continuation bits padded with
/// zero groups): six bytes is v2's sixth-byte rule broken with the value
/// itself unchanged, so a reader that let a sixth byte through would read
/// the table's own value and publish.
fn v2Padded(a: std.mem.Allocator, value: u64, n: usize) ![]const u8 {
    const out = try a.alloc(u8, n);
    var rest = value;
    for (out, 0..) |*byte, i| {
        byte.* = @as(u8, @truncate(rest)) & 0x7F;
        if (i + 1 < n) byte.* |= 0x80;
        rest >>= 7;
    }
    return out;
}

/// The refusal sites of `checkPairsTable` and `transcodePairsTable` that a
/// table of an old index reaches (the Report's site table): each broken in
/// one table, the bad value chosen at the bound, so that a site loosened by
/// one step (a sixth byte let through, a fifth byte cut to 32 bits instead
/// of refused, an end of exactly 2^32, a gap of exactly 2^31) changes the
/// outcome.
const V2Site = enum {
    count_not_length,
    /// The count one less than the document's length (the boundary sweep:
    /// the count's other side).
    count_one_less,
    start_sixth_byte,
    start_fifth_byte_high,
    length_sixth_byte,
    length_fifth_byte_high,
    /// A varint of exactly 2^32 (the boundary sweep: `readVarint`'s value
    /// bound at its first value past a u32).
    start_exactly_2p32,
    length_exactly_2p32,
    zero_length,
    end_exactly_2p32,
    /// Valid v2 (the old reader accepts it), refused by the transcode only
    /// (`GapNotRepresentable`): carried tables only.
    gap_exactly_2p31,
    /// One byte after the table: the walk (`apply.offsetTableStarts`) ends
    /// off the section's end (`InvalidLexicalSection`), the v2 side of its
    /// last check (the ruling after the Fourth Verdict).
    leftover_byte,
};

fn expectV2SiteRefused(site: V2Site, where: DroppedAt, path: TablePath) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const name = try std.fmt.allocPrint(a, "v2site-{s}-{s}-{s}", .{ @tagName(site), @tagName(where), @tagName(path) });
    var dir = try copyOf(a, tmp, fixture_main, name);
    defer dir.close(io);
    const engine = try snapshot_open.open(a, io, dir);
    const base = try v2Tables(a, dir);
    try std.testing.expectEqual(engine.documents.len, base.docs.len);
    const k = tablePosition(base.docs.len, where, struct {
        docs: []const V2Doc,
        fn at(self: @This(), i: usize) bool {
            return self.docs[i].tokens.len > 0;
        }
    }{ .docs = base.docs });
    try std.testing.expect(base.docs[k].tokens.len > 0);
    const docs = try a.dupe(V2Doc, base.docs);
    docs[k].tokens = try a.dupe(V2Token, docs[k].tokens);
    const tokens = docs[k].tokens;
    const tail = &tokens[tokens.len - 1];
    // The tail token's start before it, from the deltas.
    var before_tail: u64 = 0;
    for (tokens[0 .. tokens.len - 1]) |token| before_tail += v2Value(token.delta);
    var expected: anyerror = error.InvalidPositions;
    var old_reader_refuses = true;
    switch (site) {
        .count_not_length => docs[k].count += 1,
        .count_one_less => docs[k].count -= 1,
        .start_sixth_byte => tail.delta = try v2Padded(a, v2Value(tail.delta), 6),
        .start_fifth_byte_high => tail.delta = try v2Varint(a, v2Value(tail.delta) + (1 << 32)),
        .length_sixth_byte => tail.length = try v2Padded(a, v2Value(tail.length), 6),
        .length_fifth_byte_high => tail.length = try v2Varint(a, v2Value(tail.length) + (1 << 32)),
        .start_exactly_2p32 => tail.delta = try v2Varint(a, 1 << 32),
        .length_exactly_2p32 => tail.length = try v2Varint(a, 1 << 32),
        .zero_length => tail.length = &.{0},
        .end_exactly_2p32 => tail.delta = try v2Varint(a, (1 << 32) - before_tail - v2Value(tail.length)),
        .gap_exactly_2p31 => {
            // The first token 2^31 codepoints after the table's start (the
            // previous end 0): zigzag 2^32. Every later start moves with it
            // and stays within a u32.
            tokens[0].delta = try v2Varint(a, 1 << 31);
            expected = error.InvalidLexicalSection;
            old_reader_refuses = false;
        },
        .leftover_byte => expected = error.InvalidLexicalSection,
    }
    const offsets = if (site == .leftover_byte)
        try std.mem.concat(a, u8, &.{ try v2Emit(a, docs[0 .. k + 1]), &.{0}, try v2Emit(a, docs[k + 1 ..]) })
    else
        try v2Emit(a, docs);
    try v2Reseal(a, dir, base.good, offsets);
    if (old_reader_refuses) {
        try std.testing.expectError(error.InvalidPositions, oldReaderVerdict(a, dir));
    } else try oldReaderVerdict(a, dir);
    const before = try snapshotFiles(a, dir);
    const change = switch (path) {
        .carried => shed,
        .dropped => try std.fmt.allocPrint(a, "{{\"changes\":[{{\"op\":\"remove\",\"root_id\":\"r-legacy\",\"path\":\"{s}\"}}]}}", .{engine.documents[k].path}),
    };
    const got = if (apply.applyChanges(a, io, dir, change, .{})) |outcome| switch (outcome) {
        .ok => error.TestUnexpectedResult,
        .failed => error.RefusedAsFailure,
    } else |err| err;
    if (got != expected) {
        std.debug.print("S6-T8 sites: v2 {s}, {s} table at the {s} document ({d} of {d}): the first publish gave {s}, expected {s}\n", .{ @tagName(site), @tagName(path), @tagName(where), k, base.docs.len, @errorName(got), @errorName(expected) });
        return error.TestUnexpectedError;
    }
    try expectSameFiles(before, try snapshotFiles(a, dir));
    const metadata = try manifest.decode(try dir.readFileAlloc(io, publication.current_manifest_file, a, .unlimited));
    try std.testing.expectEqual(@as(u64, 1), metadata.generation);
    try std.testing.expect(!metadata.lexical_v4);
}

fn expectV2SiteRefusedEverywhere(site: V2Site, paths: []const TablePath) !void {
    for (paths) |path| for ([_]DroppedAt{ .first, .middle, .last }) |where| try expectV2SiteRefused(site, where, path);
}

const both_paths = [_]TablePath{ .carried, .dropped };

test "S6-T8 sites: a count other than the document's length, carried or dropped, at the first, a middle and the last table" {
    try expectV2SiteRefusedEverywhere(.count_not_length, &both_paths);
}

test "S6-T8 sites: a count one less than the document's length, carried or dropped, at three tables" {
    try expectV2SiteRefusedEverywhere(.count_one_less, &both_paths);
}

test "S6-T8 sites: a start delta with a sixth byte (its value unchanged), carried or dropped, at three tables" {
    try expectV2SiteRefusedEverywhere(.start_sixth_byte, &both_paths);
}

test "S6-T8 sites: a start delta whose fifth byte is above 0x0F (its value plus 2^32), carried or dropped, at three tables" {
    try expectV2SiteRefusedEverywhere(.start_fifth_byte_high, &both_paths);
}

test "S6-T8 sites: a length with a sixth byte (its value unchanged), carried or dropped, at three tables" {
    try expectV2SiteRefusedEverywhere(.length_sixth_byte, &both_paths);
}

test "S6-T8 sites: a length whose fifth byte is above 0x0F (its value plus 2^32), carried or dropped, at three tables" {
    try expectV2SiteRefusedEverywhere(.length_fifth_byte_high, &both_paths);
}

test "S6-T8 sites: a start delta and a length of exactly 2^32, carried or dropped, at three tables" {
    try expectV2SiteRefusedEverywhere(.start_exactly_2p32, &both_paths);
    try expectV2SiteRefusedEverywhere(.length_exactly_2p32, &both_paths);
}

test "S6-T8 sites: a length of 0, carried or dropped, at three tables" {
    try expectV2SiteRefusedEverywhere(.zero_length, &both_paths);
}

test "S6-T8 sites: an end of exactly 2^32, carried or dropped, at three tables" {
    try expectV2SiteRefusedEverywhere(.end_exactly_2p32, &both_paths);
}

test "S6-T8 sites: a gap of exactly 2^31 (valid v2, zigzag 2^32) in a carried table is refused at three tables; a dropped one is not checked for it" {
    try expectV2SiteRefusedEverywhere(.gap_exactly_2p31, &.{.carried});
}

// The v4 table walk (`postings.oneByteTableEnd`, `skipOneVarint`) at a later
// update: structure only, so its refusals are a section that ends inside a
// table. A section can only end once, so the damage cuts the section inside
// the chosen document's table and the documents after it lose their bytes.

const V4Token = struct { byte: u8, esc_g: []const u8, esc_l: []const u8 };
const V4Doc = struct { count: []const u8, tokens: []V4Token };

fn v4Tables(a: std.mem.Allocator, dir: std.Io.Dir) !struct { good: []const u8, docs: []V4Doc, paths: []const []const u8 } {
    const metadata = try manifest.decode(try dir.readFileAlloc(io, publication.current_manifest_file, a, .unlimited));
    try std.testing.expect(metadata.lexical_v4);
    const good = try dir.readFileAlloc(io, metadata.lexical_file, a, .unlimited);
    const engine = try snapshot_open.open(a, io, dir);
    const sections = engine.lexical_index.positions.?;
    try std.testing.expectEqual(postings.OffsetsCoding.one_byte, sections.coding);
    const offsets = sections.offsets;
    const docs = try a.alloc(V4Doc, engine.lexical_index.document_lengths.len);
    const paths = try a.alloc([]const u8, docs.len);
    var at: usize = 0;
    for (engine.lexical_index.document_lengths, docs, paths, engine.documents) |length, *doc, *path, document| {
        path.* = document.path;
        doc.count = v2Raw(offsets, &at);
        doc.tokens = try a.alloc(V4Token, length);
        for (doc.tokens) |*token| {
            token.* = .{ .byte = offsets[at], .esc_g = &.{}, .esc_l = &.{} };
            at += 1;
            if (token.byte & 0x0F == postings.offsets_escape) token.esc_g = v2Raw(offsets, &at);
            if (token.byte >> 4 == postings.offsets_escape) token.esc_l = v2Raw(offsets, &at);
        }
    }
    try std.testing.expectEqual(offsets.len, at);
    return .{ .good = good, .docs = docs, .paths = paths };
}

fn v4Append(list: *std.ArrayList(u8), a: std.mem.Allocator, docs: []const V4Doc) !void {
    for (docs) |doc| {
        try list.appendSlice(a, doc.count);
        for (doc.tokens) |token| {
            try list.append(a, token.byte);
            try list.appendSlice(a, token.esc_g);
            try list.appendSlice(a, token.esc_l);
        }
    }
}

/// The refusal sites of `oneByteTableEnd` and `skipOneVarint`, each by a
/// section that ends there inside the chosen document's table.
const V4Site = enum {
    /// Inside the count varint (its last byte given the continuation bit).
    count_cut,
    /// Before the table's last token byte.
    token_cut,
    /// Right after a last token byte whose gap nibble is the escape.
    gap_escape_cut,
    /// Right after a last token byte whose length nibble is the escape (and
    /// after its gap escape, if it has one).
    length_escape_cut,
    /// Not a cut: one byte after the section's last table, the section
    /// otherwise whole. The walk ends off the section's end
    /// (`InvalidLexicalSection`), the v4 side of `apply.offsetTableStarts`'
    /// last check (the Fourth Verdict's F5).
    leftover_byte,
};

const empty_file =
    \\{"changes":[{"op":"add","root_id":"r-legacy","path":"zzz-marks.txt","content_base64":"LS0gKiAtLQo="}]}
;
const second_shed =
    \\{"changes":[{"op":"add","root_id":"r-legacy","path":"shed2.txt","content_base64":"QSBzZWNvbmQgc2hlZCBob2xkcyB0aGUgdG9vbHMuCg=="}]}
;

/// `main`'s fixture published once under this library (generation 2,
/// `HYBLEX04`), its section 5 cut by `site` inside one table, then a later
/// update: an unrelated file added (every table carried) or that table's
/// file removed. The walk refuses the section (`InvalidLexicalSection`),
/// generation 2 stays, every file byte-identical. `with_empty_last` first
/// adds a file with no token, so the section's last table holds a count
/// and nothing else.
fn expectV4SiteRefused(site: V4Site, where: DroppedAt, path: TablePath, with_empty_last: bool) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const name = try std.fmt.allocPrint(a, "v4site-{s}-{s}-{s}-{}", .{ @tagName(site), @tagName(where), @tagName(path), with_empty_last });
    var dir = try copyOf(a, tmp, fixture_main, name);
    defer dir.close(io);
    switch (try apply.applyChanges(a, io, dir, if (with_empty_last) empty_file else shed, .{})) {
        .ok => {},
        .failed => return error.TestUnexpectedResult,
    }
    const base = try v4Tables(a, dir);
    const k = tablePosition(base.docs.len, where, struct {
        docs: []const V4Doc,
        fn at(self: @This(), i: usize) bool {
            return self.docs[i].tokens.len > 0;
        }
    }{ .docs = base.docs });
    if (with_empty_last) {
        try std.testing.expectEqual(DroppedAt.last, where);
        try std.testing.expectEqual(@as(usize, 0), base.docs[k].tokens.len);
    } else try std.testing.expect(base.docs[k].tokens.len > 0);
    var list = std.ArrayList(u8).empty;
    try v4Append(&list, a, base.docs[0..k]);
    const doc = base.docs[k];
    switch (site) {
        .count_cut => {
            try list.appendSlice(a, doc.count[0 .. doc.count.len - 1]);
            try list.append(a, doc.count[doc.count.len - 1] | 0x80);
        },
        .token_cut, .gap_escape_cut, .length_escape_cut => {
            try list.appendSlice(a, doc.count);
            const last = doc.tokens[doc.tokens.len - 1];
            try v4Append(&list, a, &.{.{ .count = &.{}, .tokens = doc.tokens[0 .. doc.tokens.len - 1] }});
            switch (site) {
                .gap_escape_cut => try list.append(a, last.byte | 0x0F),
                .length_escape_cut => {
                    try list.append(a, last.byte | 0xF0);
                    try list.appendSlice(a, last.esc_g);
                },
                else => {},
            }
        },
        .leftover_byte => {
            try v4Append(&list, a, base.docs[k .. k + 1]);
            try list.append(a, 0);
            try v4Append(&list, a, base.docs[k + 1 ..]);
        },
    }
    try v2Reseal(a, dir, base.good, list.items);
    if (site == .leftover_byte) {
        // The reader refuses it at the first `find`: after the last table,
        // with v4's rule 12 (`OffsetsTrailingData`).
        const opened = try snapshot_open.openScoped(a, io, dir);
        defer opened.folder.close();
        const service = @import("service.zig").Service{ .engine = opened.engine, .folder = opened.folder };
        const query = switch (try ops.parseObject(a, "{\"query\":\"the\"}")) {
            .ok => |map| map,
            .failed => return error.TestUnexpectedResult,
        };
        if (ops.find(a, service, query, cli.cli_caller)) |_| {
            return error.TestUnexpectedResult;
        } else |err| if (where == .last) try std.testing.expectEqual(error.OffsetsTrailingData, err);
    }
    const before = try snapshotFiles(a, dir);
    const change = switch (path) {
        .carried => second_shed,
        .dropped => try std.fmt.allocPrint(a, "{{\"changes\":[{{\"op\":\"remove\",\"root_id\":\"r-legacy\",\"path\":\"{s}\"}}]}}", .{base.paths[k]}),
    };
    const got = if (apply.applyChanges(a, io, dir, change, .{})) |outcome| switch (outcome) {
        .ok => error.TestUnexpectedResult,
        .failed => error.RefusedAsFailure,
    } else |err| err;
    if (got != error.InvalidLexicalSection) {
        std.debug.print("S6-T8 sites: v4 {s}, {s} table at the {s} document ({d} of {d}): the update gave {s}, expected InvalidLexicalSection\n", .{ @tagName(site), @tagName(path), @tagName(where), k, base.docs.len, @errorName(got) });
        return error.TestUnexpectedError;
    }
    try expectSameFiles(before, try snapshotFiles(a, dir));
    const metadata = try manifest.decode(try dir.readFileAlloc(io, publication.current_manifest_file, a, .unlimited));
    try std.testing.expectEqual(@as(u64, 2), metadata.generation);
    try std.testing.expect(metadata.lexical_v4);
}

fn expectV4SiteRefusedEverywhere(site: V4Site) !void {
    for (both_paths) |path| for ([_]DroppedAt{ .first, .middle, .last }) |where| try expectV4SiteRefused(site, where, path, false);
}

test "S6-T8 sites: a v4 section that ends inside a count varint is refused at a later update, carried or dropped, at three tables and at an empty last table" {
    try expectV4SiteRefusedEverywhere(.count_cut);
    for (both_paths) |path| try expectV4SiteRefused(.count_cut, .last, path, true);
}

test "S6-T8 sites: a v4 section that ends before a table's last token byte is refused at a later update, carried or dropped, at three tables" {
    try expectV4SiteRefusedEverywhere(.token_cut);
}

test "S6-T8 sites: a v4 section that ends where a gap escape varint should follow is refused at a later update, carried or dropped, at three tables" {
    try expectV4SiteRefusedEverywhere(.gap_escape_cut);
}

test "S6-T8 sites: a v4 section that ends where a length escape varint should follow is refused at a later update, carried or dropped, at three tables" {
    try expectV4SiteRefusedEverywhere(.length_escape_cut);
}

test "S6-T8 sites: one byte after a v2 table is refused by the walk at the first publish, carried or dropped, at three tables" {
    try expectV2SiteRefusedEverywhere(.leftover_byte, &both_paths);
}

// Only after the last table: a byte after an inner v4 table is read as the
// next table's count, which the walk does not compare, so the walk need not
// end off the section's end there (the encode's v4 rules then refuse a
// carried table); that is not the walk's last check.
test "S6-T8 sites: one byte after a v4 section's last table is refused by find and by the walk at a later update, a file added or the last document's file removed" {
    for (both_paths) |path| try expectV4SiteRefused(.leftover_byte, .last, path, false);
}

// The Fifth Verdict: value damage in a carried v4 table (F6's boundary
// among it) and a stray byte after an inner v4 table, each at a later
// update over `main`'s fixture published once (generation 2, `HYBLEX04`).

/// The error of the first `find` on `dir` (the open, or the query), or
/// null where both succeed.
fn firstFindError(a: std.mem.Allocator, dir: std.Io.Dir) ?anyerror {
    const opened = snapshot_open.openScoped(a, io, dir) catch |err| return err;
    defer opened.folder.close();
    const service = @import("service.zig").Service{ .engine = opened.engine, .folder = opened.folder };
    const query = switch (ops.parseObject(a, "{\"query\":\"the\"}") catch |err| return err) {
        .ok => |map| map,
        .failed => return error.TestUnexpectedResult,
    };
    _ = ops.find(a, service, query, cli.cli_caller) catch |err| return err;
    return null;
}

/// v4 token `token`'s start, gap from the previous token's end.
fn v4Start(tokens: []const V4Token, token: usize) u64 {
    var previous_end: i64 = 0;
    var start: i64 = 0;
    for (tokens[0 .. token + 1]) |t| {
        const g: u64 = if (t.byte & 0x0F == postings.offsets_escape) v2Value(t.esc_g) else t.byte & 0x0F;
        const l: u64 = if (t.byte >> 4 == postings.offsets_escape) v2Value(t.esc_l) else t.byte >> 4;
        start = previous_end + postings.unzigzag(g);
        previous_end = start + @as(i64, @intCast(l));
    }
    return @intCast(start);
}

const V4Damage = enum {
    /// The table's last token ends at exactly 2^32 (rule 10's boundary).
    end_exactly_2p32,
    /// ... and at 2^32 + 1.
    end_past_2p32,
    /// The table's last token's length 0 (rule 7).
    zero_length,
    /// One byte 0x00 after the table, an inner one: read as the next
    /// table's count.
    inner_stray_byte,
};

/// `damage` in one table (the first, a middle or the last; an inner stray
/// byte, the first or a middle), every checksum resealed. The first `find`
/// refuses it with `find_error`; a later update, an unrelated file added
/// (`.carried`, every table carried) or that table's file removed
/// (`.dropped`), refuses it with `update_error`, generation 2 staying and
/// every file byte-identical.
fn expectV4DamageRefused(damage: V4Damage, where: DroppedAt, path: TablePath, find_error: anyerror, update_error: anyerror) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const name = try std.fmt.allocPrint(a, "v4damage-{s}-{s}-{s}", .{ @tagName(damage), @tagName(where), @tagName(path) });
    var dir = try copyOf(a, tmp, fixture_main, name);
    defer dir.close(io);
    switch (try apply.applyChanges(a, io, dir, shed, .{})) {
        .ok => {},
        .failed => return error.TestUnexpectedResult,
    }
    const base = try v4Tables(a, dir);
    const k = tablePosition(base.docs.len, where, struct {
        docs: []const V4Doc,
        fn at(self: @This(), i: usize) bool {
            return self.docs[i].tokens.len > 0;
        }
    }{ .docs = base.docs });
    try std.testing.expect(base.docs[k].tokens.len > 0);
    const docs = try a.dupe(V4Doc, base.docs);
    docs[k].tokens = try a.dupe(V4Token, base.docs[k].tokens);
    const last = docs[k].tokens.len - 1;
    const token = &docs[k].tokens[last];
    var list = std.ArrayList(u8).empty;
    switch (damage) {
        .end_exactly_2p32, .end_past_2p32 => {
            const start = v4Start(docs[k].tokens, last);
            const end: u64 = if (damage == .end_exactly_2p32) @as(u64, 1) << 32 else (@as(u64, 1) << 32) + 1;
            token.byte |= 0xF0;
            token.esc_l = try v2Varint(a, end - start);
            try v4Append(&list, a, docs);
        },
        .zero_length => {
            token.byte &= 0x0F;
            token.esc_l = &.{};
            try v4Append(&list, a, docs);
        },
        .inner_stray_byte => {
            try std.testing.expect(where != .last);
            try v4Append(&list, a, docs[0 .. k + 1]);
            try list.append(a, 0);
            try v4Append(&list, a, docs[k + 1 ..]);
        },
    }
    try v2Reseal(a, dir, base.good, list.items);
    const read = firstFindError(a, dir);
    const before = try snapshotFiles(a, dir);
    const change = switch (path) {
        .carried => second_shed,
        .dropped => try std.fmt.allocPrint(a, "{{\"changes\":[{{\"op\":\"remove\",\"root_id\":\"r-legacy\",\"path\":\"{s}\"}}]}}", .{base.paths[k]}),
    };
    const got = if (apply.applyChanges(a, io, dir, change, .{})) |outcome| switch (outcome) {
        .ok => error.TestUnexpectedResult,
        .failed => error.RefusedAsFailure,
    } else |err| err;
    const read_as_expected = if (read) |e| e == find_error else false;
    if (!read_as_expected or got != update_error) {
        std.debug.print("S6-T8 v4 damage: {s}, {s} table at the {s} document ({d} of {d}): find gave {s} (expected {s}), the update {s} (expected {s})\n", .{ @tagName(damage), @tagName(path), @tagName(where), k, base.docs.len, if (read) |e| @errorName(e) else "no error", @errorName(find_error), @errorName(got), @errorName(update_error) });
        return error.TestUnexpectedError;
    }
    try expectSameFiles(before, try snapshotFiles(a, dir));
    const metadata = try manifest.decode(try dir.readFileAlloc(io, publication.current_manifest_file, a, .unlimited));
    try std.testing.expectEqual(@as(u64, 2), metadata.generation);
    try std.testing.expect(metadata.lexical_v4);
}

test "S6-T8 F6: an end of exactly 2^32, and one past it, in a carried v4 table: find refuses it and a later update refuses it in the encode, at three tables" {
    for ([_]V4Damage{ .end_exactly_2p32, .end_past_2p32 }) |damage| for ([_]DroppedAt{ .first, .middle, .last }) |where|
        try expectV4DamageRefused(damage, where, .carried, error.OffsetsEndOverflow, error.InvalidPositions);
}

test "S6-T8 Fifth Verdict: value damage (a length of 0) in a carried v4 table: find refuses it and a later update refuses it in the encode, at three tables" {
    for ([_]DroppedAt{ .first, .middle, .last }) |where|
        try expectV4DamageRefused(.zero_length, where, .carried, error.OffsetsZeroLength, error.InvalidPositions);
}

test "S6-T8 Fifth Verdict: a stray byte after an inner v4 table: find refuses it (the next count) and a later update refuses it, a file added or that table's file removed" {
    for ([_]DroppedAt{ .first, .middle }) |where| for (both_paths) |path|
        try expectV4DamageRefused(.inner_stray_byte, where, path, error.OffsetsCountMismatch, error.InvalidPositions);
}

/// `main`'s fixture (v2-coded section 5), every chunk's last token ending
/// `past` codepoints after its text's end, every checksum resealed.
fn v2EndsPastText(a: std.mem.Allocator, tmp: std.testing.TmpDir, name: []const u8, past: u64) !std.Io.Dir {
    const dir = try copyOf(a, tmp, fixture_main, name);
    const engine = try snapshot_open.open(a, io, dir);
    const base = try v2Tables(a, dir);
    try std.testing.expectEqual(engine.documents.len, base.docs.len);
    var moved: usize = 0;
    for (base.docs, engine.documents) |*doc, document| {
        if (doc.tokens.len == 0) continue;
        var start: u64 = 0;
        for (doc.tokens) |token| start += v2Value(token.delta);
        // As `find` counts them (its `codepoints`).
        const codepoints: u64 = @intCast(@import("analysis.zig").codepointCount(document.text));
        const tail = &doc.tokens[doc.tokens.len - 1];
        try std.testing.expect(start + v2Value(tail.length) <= codepoints);
        tail.length = try v2Varint(a, codepoints + past - start);
        moved += 1;
    }
    try std.testing.expect(moved > 0);
    try v2Reseal(a, dir, base.good, try v2Emit(a, base.docs));
    // v2's own rules hold: only the text shows it.
    try oldReaderVerdict(a, dir);
    return dir;
}

test "S6-T8 boundary sweep, rule 11 on a v2-coded index: a highlight one past its chunk's text is refused by find; one ending at the text's end answers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var past = try v2EndsPastText(a, tmp, "r11-v2-past", 1);
    defer past.close(io);
    try std.testing.expectEqual(@as(?anyerror, error.OffsetsPastText), firstFindError(a, past));
    var at_end = try v2EndsPastText(a, tmp, "r11-v2-at-end", 0);
    defer at_end.close(io);
    try std.testing.expectEqual(@as(?anyerror, null), firstFindError(a, at_end));
}
