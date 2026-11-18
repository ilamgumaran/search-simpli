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
