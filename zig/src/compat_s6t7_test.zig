//! S6-T7: text once (documents record v5, source `HYBSRC02`, manifest
//! v2.4) against the indexes written before it.
//!
//! `tests/fixtures/index-v3-s6t4/` is `fixtures/family-folder/home` as
//! `main` at a534678 writes it (manifest v2.3: record v4 documents,
//! `HYBSRC01`, `HYBLEX03`). It must open and answer under this library
//! exactly as a fresh index of the same folder; its first update publishes
//! the new format, whose sections are a fresh index's byte for byte, and
//! still answers the same; a crash between writing and publishing leaves
//! one whole generation, old or new.
//!
//! `tests/fixtures/index-v5-s6t7/` is this writer's output for the same
//! folder (`tests/fixtures/gen_index_v5_s6t7.sh`), its reference: the
//! writer still gives these bytes, and a library before v2.4 (flags 0 to 5)
//! refuses its manifest at the flags before reading any section (the run
//! of a534678's own `searchd` and C library is in
//! `docs/evidence/s6-t7/old-library-phase2.txt`).
const std = @import("std");
const apply = @import("apply.zig");
const cli = @import("cli.zig");
const compat = @import("compat_98c4a2b_test.zig");
const manifest = @import("manifest.zig");
const publication = @import("publication.zig");
const segment = @import("segment.zig");
const source_v2 = @import("source_v2.zig");

const io = std.testing.io;
const fixture_old = "../tests/fixtures/index-v3-s6t4";
const fixture_new = "../tests/fixtures/index-v5-s6t7";
const folder = "../fixtures/family-folder/home";
const files = [_][]const u8{ "MANIFEST", "INDEX-STATE.json", "documents-1.hybseg", "lexical-1.hyblex", "source-1.hybsrc", "state-1.hybstate", "filenames-1.hybseg", "filename-lexical-1.hyblex" };
const shed =
    \\{"changes":[{"op":"add","root_id":"r-legacy","path":"shed.txt","content_base64":"VGhlIHNoZWQgbmVlZHMgYSBuZXcgbG9jay4K"}]}
;

/// The generation in `dir` is the text-once format: the flag, record v5
/// and `HYBSRC02`.
fn expectTextOnce(a: std.mem.Allocator, dir: std.Io.Dir) !manifest.Manifest {
    const metadata = try manifest.decode(try dir.readFileAlloc(io, publication.current_manifest_file, a, .unlimited));
    try std.testing.expect(metadata.text_once and metadata.lexical_v3);
    const documents = try dir.readFileAlloc(io, metadata.documents_file, a, .unlimited);
    try std.testing.expectEqual(segment.version_v5, (try segment.inspect(documents)).format_version);
    try std.testing.expectEqualStrings(source_v2.magic, try compat.magicOf(a, dir, metadata.source_file));
    return metadata;
}

/// A library before v2.4 refuses the manifest at its flags: magic, version
/// 2, then any flag outside bits 0 to 5 is `UnsupportedFlags`.
fn refusedBeforeTextOnce(manifest_bytes: []const u8) bool {
    const known_before: u16 = 0x3f;
    if (manifest_bytes.len < 12 or !std.mem.eql(u8, manifest_bytes[0..8], "HYBMAN02")) return false;
    if (std.mem.readInt(u16, manifest_bytes[8..10], .little) != 2) return false;
    return std.mem.readInt(u16, manifest_bytes[10..12], .little) & ~known_before != 0;
}

fn oldIndex(a: std.mem.Allocator, tmp: std.testing.TmpDir, name: []const u8) !std.Io.Dir {
    try tmp.dir.createDir(io, name, .default_dir);
    const dir = try tmp.dir.openDir(io, name, .{ .iterate = true });
    try compat.copyFixture(a, fixture_old, dir);
    return dir;
}

test "S6-T7: the committed text-once fixture is 62324f9's writer output (this writer's but for HYBLEX04), and a library before v2.4 refuses it at the flags" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var committed = try std.Io.Dir.cwd().openDir(io, fixture_new, .{});
    defer committed.close(io);
    _ = try expectTextOnce(a, committed);
    const committed_manifest = try committed.readFileAlloc(io, publication.current_manifest_file, a, .unlimited);
    try std.testing.expect(refusedBeforeTextOnce(committed_manifest));
    try std.testing.expectEqual(manifest.flag_text_once, std.mem.readInt(u16, committed_manifest[10..12], .little) & ~@as(u16, 0x3f));
    var old = try std.Io.Dir.cwd().openDir(io, fixture_old, .{});
    defer old.close(io);
    try std.testing.expect(!refusedBeforeTextOnce(try old.readFileAlloc(io, publication.current_manifest_file, a, .unlimited)));
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var fresh = try compat.freshIndex(a, tmp, "fresh");
    defer fresh.close(io);
    // S6-T8: since v2.5 the content section is `HYBLEX04` and the manifest
    // sets bit 7; every other section is still this fixture's, and the
    // content section is the fixture's `HYBLEX03` with section 5 recoded.
    // `compat_s6t8_test.zig` holds v2.5's reference.
    for (files) |name| {
        if (std.mem.eql(u8, name, "INDEX-STATE.json") or std.mem.eql(u8, name, "MANIFEST") or std.mem.eql(u8, name, "lexical-1.hyblex")) continue;
        try std.testing.expectEqualSlices(u8, try committed.readFileAlloc(io, name, a, .unlimited), try fresh.readFileAlloc(io, name, a, .unlimited));
    }
    try compat.expectSameLexicalAsV3(a, try committed.readFileAlloc(io, "lexical-1.hyblex", a, .unlimited), try fresh.readFileAlloc(io, "lexical-1.hyblex", a, .unlimited));
    // The old fixture's sections that did not change format are the new
    // fixture's, byte for byte.
    for ([_][]const u8{ "lexical-1.hyblex", "filenames-1.hybseg", "filename-lexical-1.hyblex", "state-1.hybstate" }) |name| {
        try std.testing.expectEqualSlices(u8, try old.readFileAlloc(io, name, a, .unlimited), try committed.readFileAlloc(io, name, a, .unlimited));
    }
}

test "S6-T7: an index from a534678 opens and answers exactly as a fresh text-once index of the same folder" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var old = try oldIndex(a, tmp, "old");
    defer old.close(io);
    const old_metadata = try manifest.decode(try old.readFileAlloc(io, publication.current_manifest_file, a, .unlimited));
    try std.testing.expect(!old_metadata.text_once);
    var fresh = try compat.freshIndex(a, tmp, "fresh");
    defer fresh.close(io);
    _ = try expectTextOnce(a, fresh);
    const want = try compat.answers(a, fresh);
    try std.testing.expect(want.len > 150);
    try compat.expectSameAnswers(want, try compat.answers(a, old));
    // Opening and answering left the old index's bytes as they were.
    var pristine = try std.Io.Dir.cwd().openDir(io, fixture_old, .{});
    defer pristine.close(io);
    for (files) |name| try std.testing.expectEqualSlices(u8, try pristine.readFileAlloc(io, name, a, .unlimited), try old.readFileAlloc(io, name, a, .unlimited));
}

test "S6-T7: the first update of an a534678 index publishes the text-once format, a fresh index's sections, and answers the same" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var old = try oldIndex(a, tmp, "old");
    defer old.close(io);
    // The same folder unchanged: `index --update` re-reads every file, finds
    // none changed and publishes generation 2 in the new format (the record
    // v4 documents re-encoded as v5, the `HYBSRC01` records' maps and
    // digests carried and each file's chunks located in its bytes).
    var sink: std.Io.Writer.Allocating = .init(a);
    try cli.runIndex(io, a, folder, try compat.tmpPath(a, tmp, "old"), .{ .update = true, .caps = .{ .filename_index = true } }, &sink.writer);
    const metadata = try expectTextOnce(a, old);
    try std.testing.expectEqual(@as(u64, 2), metadata.generation);
    var fresh = try compat.freshIndex(a, tmp, "fresh");
    defer fresh.close(io);
    try compat.expectSameAnswers(try compat.answers(a, fresh), try compat.answers(a, old));
    const fresh_metadata = try manifest.decode(try fresh.readFileAlloc(io, publication.current_manifest_file, a, .unlimited));
    try std.testing.expectEqualSlices(u8, try fresh.readFileAlloc(io, fresh_metadata.documents_file, a, .unlimited), try old.readFileAlloc(io, metadata.documents_file, a, .unlimited));
    try std.testing.expectEqualSlices(u8, try fresh.readFileAlloc(io, fresh_metadata.source_file, a, .unlimited), try old.readFileAlloc(io, metadata.source_file, a, .unlimited));
    try std.testing.expectEqualSlices(u8, try fresh.readFileAlloc(io, fresh_metadata.lexical_file, a, .unlimited), try old.readFileAlloc(io, metadata.lexical_file, a, .unlimited));
    // A second update (a new file) carries every other file's source
    // record and publishes the new format again.
    _ = switch (try apply.applyChanges(a, io, old, shed, .{})) {
        .ok => |r| r,
        .failed => return error.TestUnexpectedResult,
    };
    const third = try expectTextOnce(a, old);
    try std.testing.expectEqual(@as(u64, 3), third.generation);
}

test "S6-T7: a crash during the first publish from a534678's format leaves the whole old generation, or after the manifest the whole new one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var before = try oldIndex(a, tmp, "before");
    defer before.close(io);
    var after = try oldIndex(a, tmp, "after");
    defer after.close(io);
    var plain = try oldIndex(a, tmp, "plain");
    defer plain.close(io);
    const want_old = try compat.answers(a, plain);
    // After the manifest is replaced (the writer's own crash hook): the new
    // generation is whole and current.
    try std.testing.expectError(error.SimulatedCrash, apply.applyChanges(a, io, after, shed, .{ .fail_after_publish = true }));
    try std.testing.expectEqual(@as(u64, 2), (try expectTextOnce(a, after)).generation);
    const new_answers = try compat.answers(a, after);
    // Before the manifest: every section of generation 2 written and linked
    // (the files the crashed publish left), `MANIFEST` still generation 1,
    // whose sections are untouched.
    var listing = after.iterate();
    while (try listing.next(io)) |entry| {
        if (std.mem.indexOf(u8, entry.name, "-2.") == null) continue;
        try before.writeFile(io, .{ .sub_path = entry.name, .data = try after.readFileAlloc(io, entry.name, a, .unlimited) });
    }
    const still = try manifest.decode(try before.readFileAlloc(io, publication.current_manifest_file, a, .unlimited));
    try std.testing.expectEqual(@as(u64, 1), still.generation);
    try std.testing.expect(!still.text_once);
    var pristine = try std.Io.Dir.cwd().openDir(io, fixture_old, .{});
    defer pristine.close(io);
    for (files) |name| {
        if (std.mem.eql(u8, name, "INDEX-STATE.json")) continue;
        try std.testing.expectEqualSlices(u8, try pristine.readFileAlloc(io, name, a, .unlimited), try before.readFileAlloc(io, name, a, .unlimited));
    }
    try compat.expectSameAnswers(want_old, try compat.answers(a, before));
    // The next update over the leftovers publishes a whole new generation
    // that answers as the crashed one did (generation 3: the leftover
    // number 2 is not reused).
    _ = switch (try apply.applyChanges(a, io, before, shed, .{})) {
        .ok => |r| r,
        .failed => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(u64, 3), (try expectTextOnce(a, before)).generation);
    try compat.expectSameAnswers(new_answers, try compat.answers(a, before));
}
