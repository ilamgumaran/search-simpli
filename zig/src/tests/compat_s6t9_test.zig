//! S6-T9: manifest v2.6, the state section `HYBSTA03` (bit 8) and the
//! file-name catalog record v6 (bit 9), against the indexes written before
//! it.
//!
//! - `tests/fixtures/index-lex4-s6t8/` is `fixtures/family-folder/home` as
//!   `main` writes it before S6-T9 (manifest v2.5; fa56ee9 and a019f22 write
//!   the same bytes, their engines being the same); `index-v5-s6t7/` as
//!   62324f9 wrote it (before S6-T8), `index-v3-s6t4/` as a534678 wrote it
//!   (before S6-T7), `index-98c4a2b/` as 98c4a2b wrote it (before S6-T4).
//!   Each must open and answer under this library exactly as a fresh index
//!   of the same folder, its bytes untouched; its first update publishes one
//!   whole v2.6 generation whose sections are a fresh index's byte for byte;
//!   a crash between writing and publishing leaves one whole generation, old
//!   or new.
//! - `tests/fixtures/index-refs-s6t9/` is this writer's output for the same
//!   folder (`tests/fixtures/gen_index_refs_s6t9.sh`): the writer still gives
//!   these bytes, and a library before v2.6 (flags 0 to 7) refuses its
//!   manifest at the flags before reading any section (the runs of `main`'s
//!   own `searchd` and C library are in
//!   `docs/evidence/s6-t9/old-library.txt`).
//! - The catalog's rules C1 to C3 (`docs/filename-catalog-format-v6.md`)
//!   at the eager open and lazily at the first file-name query, for the
//!   first, a middle and the last record. The state's rules are in
//!   `state_v3_test.zig`.
const std = @import("std");
const apply = @import("core").apply;
const checksum = @import("core").checksum;
const cli = @import("interfaces").cli;
const compat = @import("compat_98c4a2b_test.zig");
const hybrid = @import("core").hybrid;
const incremental_state = @import("core").incremental_state;
const manifest = @import("core").manifest;
const publication = @import("core").publication;
const segment = @import("core").segment;
const snapshot_open = @import("core").snapshot_open;
const service_module = @import("operations").service;

const io = std.testing.io;
const fixture_main = "../tests/fixtures/index-lex4-s6t8";
const fixture_before_s6t8 = "../tests/fixtures/index-v5-s6t7";
const fixture_before_s6t7 = "../tests/fixtures/index-v3-s6t4";
const fixture_before_s6t4 = "../tests/fixtures/index-98c4a2b";
const fixture_new = "../tests/fixtures/index-refs-s6t9";
const folder = "../fixtures/family-folder/home";
const files = [_][]const u8{ "MANIFEST", "INDEX-STATE.json", "documents-1.hybseg", "lexical-1.hyblex", "source-1.hybsrc", "state-1.hybstate", "filenames-1.hybseg", "filename-lexical-1.hyblex" };
const olds = [_][]const u8{ fixture_main, fixture_before_s6t8, fixture_before_s6t7, fixture_before_s6t4 };
const shed =
    \\{"changes":[{"op":"add","root_id":"r-legacy","path":"shed.txt","content_base64":"VGhlIHNoZWQgbmVlZHMgYSBuZXcgbG9jay4K"}]}
;
const lexical_options = hybrid.SearchOptions{ .retrieval_mode = .lexical, .top_k = 5, .candidate_k = 10 };

/// The generation in `dir` is v2.6: bits 8 and 9, a `HYBSTA03` state whose
/// every retained file is referenced, a record v6 catalog.
fn expectV26(a: std.mem.Allocator, dir: std.Io.Dir) !manifest.Manifest {
    const metadata = try manifest.decode(try dir.readFileAlloc(io, publication.current_manifest_file, a, .unlimited));
    try std.testing.expect(metadata.state_v3 and metadata.catalog_v6 and metadata.lexical_v4);
    const state = try dir.readFileAlloc(io, metadata.state.?.file, a, .unlimited);
    try std.testing.expectEqualStrings("HYBSTA03", state[0..8]);
    const catalog = try dir.readFileAlloc(io, metadata.filename.?.catalog_file, a, .unlimited);
    try std.testing.expectEqual(segment.version_catalog_v6, (try segment.inspectCatalog(catalog)).format_version);
    return metadata;
}

/// A library before v2.6 refuses the manifest at its flags: magic, version
/// 2, then any flag outside bits 0 to 7 is `UnsupportedFlags`.
fn refusedBeforeV26(manifest_bytes: []const u8) bool {
    const known_before: u16 = 0xff;
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

/// Every bound section of the current generations of `a_dir` and `b_dir`,
/// the state aside (it names its generation), is the same bytes.
fn expectSameSections(a: std.mem.Allocator, a_dir: std.Io.Dir, b_dir: std.Io.Dir) !void {
    const x = try manifest.decode(try a_dir.readFileAlloc(io, publication.current_manifest_file, a, .unlimited));
    const y = try manifest.decode(try b_dir.readFileAlloc(io, publication.current_manifest_file, a, .unlimited));
    const names_x = [_][]const u8{ x.documents_file, x.lexical_file, x.source_file, x.filename.?.catalog_file, x.filename.?.lexical_file };
    const names_y = [_][]const u8{ y.documents_file, y.lexical_file, y.source_file, y.filename.?.catalog_file, y.filename.?.lexical_file };
    for (names_x, names_y) |nx, ny| {
        try std.testing.expectEqualSlices(u8, try a_dir.readFileAlloc(io, nx, a, .unlimited), try b_dir.readFileAlloc(io, ny, a, .unlimited));
    }
}

/// The two states decode to the same files (the generation aside).
fn expectSameStateFiles(a: std.mem.Allocator, a_dir: std.Io.Dir, b_dir: std.Io.Dir) !void {
    const x = (try incremental_state.loadBound(a, io, a_dir)).?;
    const y = (try incremental_state.loadBound(a, io, b_dir)).?;
    var y2 = y;
    y2.generation = x.generation;
    try std.testing.expectEqualSlices(u8, try incremental_state.encodeSection(a, x), try incremental_state.encodeSection(a, y2));
}

test "S6-T9: the committed v2.6 fixture is this writer's output, and a library before v2.6 refuses it at the flags" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var committed = try std.Io.Dir.cwd().openDir(io, fixture_new, .{});
    defer committed.close(io);
    _ = try expectV26(a, committed);
    const committed_manifest = try committed.readFileAlloc(io, publication.current_manifest_file, a, .unlimited);
    try std.testing.expect(refusedBeforeV26(committed_manifest));
    try std.testing.expectEqual(manifest.flag_state_v3 | manifest.flag_catalog_v6, std.mem.readInt(u16, committed_manifest[10..12], .little) & ~@as(u16, 0xff));
    for (olds) |old_path| {
        var old = try std.Io.Dir.cwd().openDir(io, old_path, .{});
        defer old.close(io);
        try std.testing.expect(!refusedBeforeV26(try old.readFileAlloc(io, publication.current_manifest_file, a, .unlimited)));
    }
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var fresh = try compat.freshIndex(a, tmp, "fresh");
    defer fresh.close(io);
    for (files) |name| {
        try std.testing.expectEqualSlices(u8, try committed.readFileAlloc(io, name, a, .unlimited), try fresh.readFileAlloc(io, name, a, .unlimited));
    }
    // Against main's fixture: the documents, content lexical, source and
    // file-name lexical sections are the same bytes; the state and the
    // catalog are the same content (re-encoded in v2.5's forms, the same
    // bytes); the manifest differs.
    var main_fixture = try std.Io.Dir.cwd().openDir(io, fixture_main, .{});
    defer main_fixture.close(io);
    for ([_][]const u8{ "documents-1.hybseg", "lexical-1.hyblex", "source-1.hybsrc", "filename-lexical-1.hyblex", "INDEX-STATE.json" }) |name| {
        try std.testing.expectEqualSlices(u8, try main_fixture.readFileAlloc(io, name, a, .unlimited), try committed.readFileAlloc(io, name, a, .unlimited));
    }
    for ([_][]const u8{ "state-1.hybstate", "filenames-1.hybseg" }) |name| try compat.expectSameAsBeforeV26(a, main_fixture, committed, name);
    // And smaller.
    for ([_][]const u8{ "state-1.hybstate", "filenames-1.hybseg" }) |name| {
        try std.testing.expect((try committed.readFileAlloc(io, name, a, .unlimited)).len < (try main_fixture.readFileAlloc(io, name, a, .unlimited)).len);
    }
}

test "S6-T9: indexes from main (v2.5), 62324f9, a534678 and 98c4a2b open and answer exactly as a fresh v2.6 index, their bytes untouched" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var fresh = try compat.freshIndex(a, tmp, "fresh");
    defer fresh.close(io);
    _ = try expectV26(a, fresh);
    const want = try compat.answers(a, fresh);
    try std.testing.expect(want.len > 150);
    for (olds, 0..) |old_path, k| {
        var old = try copyOf(a, tmp, old_path, try std.fmt.allocPrint(a, "old{d}", .{k}));
        defer old.close(io);
        const metadata = try manifest.decode(try old.readFileAlloc(io, publication.current_manifest_file, a, .unlimited));
        try std.testing.expect(!metadata.state_v3 and !metadata.catalog_v6);
        try compat.expectSameAnswers(want, try compat.answers(a, old));
        // The state of an older generation still resolves (no table needed).
        _ = (try incremental_state.load(a, io, old)).?;
        var pristine = try std.Io.Dir.cwd().openDir(io, old_path, .{});
        defer pristine.close(io);
        for (files) |name| try std.testing.expectEqualSlices(u8, try pristine.readFileAlloc(io, name, a, .unlimited), try old.readFileAlloc(io, name, a, .unlimited));
    }
}

test "S6-T9: the first update of each older index plans no work, publishes one whole v2.6 generation, a fresh index's sections, and answers the same" {
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
        const metadata = try expectV26(a, old);
        try std.testing.expectEqual(@as(u64, 2), metadata.generation);
        try expectSameSections(a, fresh, old);
        try expectSameStateFiles(a, fresh, old);
        try compat.expectSameAnswers(want, try compat.answers(a, old));
        // A second publish (a new file) through `apply_changes` keeps the
        // format.
        _ = switch (try apply.applyChanges(a, io, old, shed, .{})) {
            .ok => |r| r,
            .failed => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(@as(u64, 3), (try expectV26(a, old)).generation);
    }
}

test "S6-T9: the first publish over main's v2.5 format through apply_changes equals the same change over v2.6" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var old = try copyOf(a, tmp, fixture_main, "old");
    defer old.close(io);
    var new = try copyOf(a, tmp, fixture_new, "new");
    defer new.close(io);
    for ([_]std.Io.Dir{ old, new }) |dir| _ = switch (try apply.applyChanges(a, io, dir, shed, .{})) {
        .ok => |r| r,
        .failed => return error.TestUnexpectedResult,
    };
    _ = try expectV26(a, old);
    _ = try expectV26(a, new);
    try expectSameSections(a, new, old);
    const x = try manifest.decode(try old.readFileAlloc(io, publication.current_manifest_file, a, .unlimited));
    const y = try manifest.decode(try new.readFileAlloc(io, publication.current_manifest_file, a, .unlimited));
    try std.testing.expectEqualSlices(u8, try new.readFileAlloc(io, y.state.?.file, a, .unlimited), try old.readFileAlloc(io, x.state.?.file, a, .unlimited));
    try std.testing.expectEqualSlices(u8, try new.readFileAlloc(io, publication.current_manifest_file, a, .unlimited), try old.readFileAlloc(io, publication.current_manifest_file, a, .unlimited));
    try compat.expectSameAnswers(try compat.answers(a, new), try compat.answers(a, old));
}

test "S6-T9: a crash during the first publish from main's v2.5 format leaves the whole old generation, or after the manifest the whole new one" {
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
    try std.testing.expectEqual(@as(u64, 2), (try expectV26(a, after)).generation);
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
    try std.testing.expect(!still.state_v3 and !still.catalog_v6);
    var pristine = try std.Io.Dir.cwd().openDir(io, fixture_main, .{});
    defer pristine.close(io);
    for (files) |name| {
        if (std.mem.eql(u8, name, "INDEX-STATE.json")) continue;
        try std.testing.expectEqualSlices(u8, try pristine.readFileAlloc(io, name, a, .unlimited), try before.readFileAlloc(io, name, a, .unlimited));
    }
    try compat.expectSameAnswers(want_old, try compat.answers(a, before));
    // The pointer resolves generation 1's state (HYBSTA02, no table).
    _ = (try incremental_state.load(a, io, before)).?;
    _ = switch (try apply.applyChanges(a, io, before, shed, .{})) {
        .ok => |r| r,
        .failed => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(u64, 3), (try expectV26(a, before)).generation);
    try compat.expectSameAnswers(new_answers, try compat.answers(a, before));
}

// ------------------------------------------------------ catalog rules ---

const CatalogRecord = struct {
    id: []const u8,
    path: []const u8,
    text: []const u8,
    start_line: u32,
    end_line: u32,
    labels: []const u8,
};

fn readU32(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}

/// The records of a v3 or v6 catalog.
fn catalogRecords(a: std.mem.Allocator, bytes: []const u8) ![]CatalogRecord {
    const count = readU32(bytes, 12);
    const out = try a.alloc(CatalogRecord, count);
    var at: usize = segment.header_length;
    for (out) |*record| {
        const id_length = readU32(bytes, at);
        const path_length = readU32(bytes, at + 4);
        const text_length = readU32(bytes, at + 8);
        record.start_line = readU32(bytes, at + 16);
        record.end_line = readU32(bytes, at + 20);
        const labels_length = readU32(bytes, at + 24);
        at += 28;
        record.id = bytes[at..][0..id_length];
        at += id_length;
        record.path = bytes[at..][0..path_length];
        at += path_length;
        record.text = bytes[at..][0..text_length];
        at += text_length;
        record.labels = bytes[at..][0..labels_length];
        at += labels_length;
    }
    try std.testing.expectEqual(bytes.len, at);
    return out;
}

/// A catalog of `records` under `version`, sealed with XXH3-64 as the
/// writer seals it.
fn catalogBytes(a: std.mem.Allocator, version: u16, records: []const CatalogRecord) ![]u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendNTimes(a, 0, segment.header_length);
    for (records) |r| {
        for ([_]usize{ r.id.len, r.path.len, r.text.len, 0, r.start_line, r.end_line, r.labels.len }) |value| {
            var word: [4]u8 = undefined;
            std.mem.writeInt(u32, &word, @intCast(value), .little);
            try out.appendSlice(a, &word);
        }
        try out.appendSlice(a, r.id);
        try out.appendSlice(a, r.path);
        try out.appendSlice(a, r.text);
        try out.appendSlice(a, r.labels);
    }
    const bytes = out.items;
    @memcpy(bytes[0..8], "HYBSEG01");
    std.mem.writeInt(u16, bytes[8..10], version, .little);
    std.mem.writeInt(u16, bytes[10..12], 1, .little);
    std.mem.writeInt(u32, bytes[12..16], @intCast(records.len), .little);
    std.mem.writeInt(u32, bytes[16..20], 0, .little);
    std.mem.writeInt(u64, bytes[20..28], bytes.len - segment.header_length, .little);
    std.mem.writeInt(u64, bytes[28..36], checksum.compute(.xxh3_64, bytes[0..28], bytes[segment.header_length..]), .little);
    return bytes;
}

/// `catalog` written over the generation's catalog and bound by its
/// manifest; bit 9 set as `catalog_v6` says (null: as the catalog's
/// version says).
fn bindCatalog(a: std.mem.Allocator, dir: std.Io.Dir, catalog: []const u8, catalog_v6: ?bool) !void {
    var metadata = try manifest.decode(try dir.readFileAlloc(io, publication.current_manifest_file, a, .unlimited));
    const f = metadata.filename.?;
    try dir.writeFile(io, .{ .sub_path = f.catalog_file, .data = catalog });
    metadata = try manifest.withFilename(metadata, f.catalog_file, f.lexical_file, catalog, try dir.readFileAlloc(io, f.lexical_file, a, .unlimited));
    if (catalog_v6) |bit| metadata.catalog_v6 = bit;
    const buffer = try a.alloc(u8, try manifest.encodedLength(metadata));
    try publication.writeAtomicFile(dir, io, publication.current_manifest_file, try manifest.encode(metadata, buffer), true);
}

/// The eager open refuses the generation with `want`; the lazy open opens
/// it, answers content, and refuses the first file-name and `both` query
/// with `want`.
fn expectCatalogRefused(a: std.mem.Allocator, dir: std.Io.Dir, want: anyerror) !void {
    try std.testing.expectError(want, snapshot_open.open(a, io, dir));
    const opened = try snapshot_open.openScoped(a, io, dir);
    defer opened.folder.close();
    try std.testing.expect((try opened.engine.queryFields(a, "garden", .content, lexical_options)).len > 0);
    try std.testing.expectError(want, opened.engine.queryFields(a, "garden", .filename, lexical_options));
    try std.testing.expectError(want, opened.engine.queryFields(a, "garden", .both, lexical_options));
    try std.testing.expect((try opened.engine.queryFields(a, "garden", .content, lexical_options)).len > 0);
}

test "S6-T9 catalog C1 and C2: an id or a text in a v6 record is refused at the eager open and at the first file-name query, first, middle and last record" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var fresh = try compat.freshIndex(a, tmp, "fresh");
    defer fresh.close(io);
    const metadata = try expectV26(a, fresh);
    const good = try fresh.readFileAlloc(io, metadata.filename.?.catalog_file, a, .unlimited);
    const records = try catalogRecords(a, good);
    try std.testing.expect(records.len > 10);
    // The writer's catalog, rebuilt by this helper, is the same bytes.
    try std.testing.expectEqualSlices(u8, good, try catalogBytes(a, segment.version_catalog_v6, records));
    // The derived values, written in: an id of 1 byte (the bound: 0 is
    // read) and the record's own 20-byte id; a text of 1 byte and the stem.
    const v3 = try catalogRecords(a, try compat.catalogAsV3(a, fresh));
    for ([_]usize{ 0, records.len / 2, records.len - 1 }, 0..) |k, n| {
        const cases = [_]struct { id: []const u8, text: []const u8, err: anyerror }{
            .{ .id = "x", .text = "", .err = error.FilenameCatalogIdPresent },
            .{ .id = v3[k].id, .text = "", .err = error.FilenameCatalogIdPresent },
            .{ .id = "", .text = "x", .err = error.FilenameCatalogTextPresent },
            .{ .id = "", .text = v3[k].text, .err = error.FilenameCatalogTextPresent },
            .{ .id = v3[k].id, .text = v3[k].text, .err = error.FilenameCatalogIdPresent },
        };
        for (cases, 0..) |case, c| {
            var dir = try copyOf(a, tmp, fixture_new, try std.fmt.allocPrint(a, "c{d}-{d}", .{ n, c }));
            defer dir.close(io);
            const damaged = try a.dupe(CatalogRecord, records);
            damaged[k].id = case.id;
            damaged[k].text = case.text;
            try bindCatalog(a, dir, try catalogBytes(a, segment.version_catalog_v6, damaged), null);
            try expectCatalogRefused(a, dir, case.err);
        }
    }
}

test "S6-T9 catalog C3 (M4): a v6 catalog without bit 9, or a v3 catalog under it, is refused at the eager open and at the first file-name query" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    {
        var dir = try copyOf(a, tmp, fixture_new, "v6-without");
        defer dir.close(io);
        const metadata = try manifest.decode(try dir.readFileAlloc(io, publication.current_manifest_file, a, .unlimited));
        try bindCatalog(a, dir, try dir.readFileAlloc(io, metadata.filename.?.catalog_file, a, .unlimited), false);
        try expectCatalogRefused(a, dir, error.FilenameCatalogVersionMismatch);
    }
    {
        var dir = try copyOf(a, tmp, fixture_new, "v3-under");
        defer dir.close(io);
        try bindCatalog(a, dir, try compat.catalogAsV3(a, dir), true);
        try expectCatalogRefused(a, dir, error.FilenameCatalogVersionMismatch);
    }
    // The same v3 catalog without bit 9 (as before v2.6) answers as fresh.
    {
        var fresh = try copyOf(a, tmp, fixture_new, "fresh");
        defer fresh.close(io);
        var dir = try copyOf(a, tmp, fixture_new, "v3-without");
        defer dir.close(io);
        try bindCatalog(a, dir, try compat.catalogAsV3(a, dir), null);
        try std.testing.expect(!(try manifest.decode(try dir.readFileAlloc(io, publication.current_manifest_file, a, .unlimited))).catalog_v6);
        try compat.expectSameAnswers(try compat.answers(a, fresh), try compat.answers(a, dir));
    }
    // A catalog version 5 (a documents version) is refused by the catalog
    // inspect; a documents section of version 6 by the documents inspect.
    {
        var dir = try copyOf(a, tmp, fixture_new, "v5");
        defer dir.close(io);
        const metadata = try manifest.decode(try dir.readFileAlloc(io, publication.current_manifest_file, a, .unlimited));
        const records = try catalogRecords(a, try dir.readFileAlloc(io, metadata.filename.?.catalog_file, a, .unlimited));
        const v5 = try catalogBytes(a, 5, records);
        try std.testing.expectError(error.UnsupportedVersion, segment.inspectCatalog(v5));
        try std.testing.expectError(error.UnsupportedVersion, segment.inspect(try catalogBytes(a, 6, records)));
        try std.testing.expectError(error.InvalidFilenameCatalog, manifest.withFilename(metadata, metadata.filename.?.catalog_file, metadata.filename.?.lexical_file, v5, try dir.readFileAlloc(io, metadata.filename.?.lexical_file, a, .unlimited)));
    }
}

test "S6-T9 catalog: the writer does not read the previous catalog (as since S4-T13); an update over a catalog damaged by C1 publishes a catalog built from the documents" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var dir = try copyOf(a, tmp, fixture_new, "damaged");
    defer dir.close(io);
    var clean = try copyOf(a, tmp, fixture_new, "clean");
    defer clean.close(io);
    const metadata = try manifest.decode(try dir.readFileAlloc(io, publication.current_manifest_file, a, .unlimited));
    const damaged = try catalogRecords(a, try dir.readFileAlloc(io, metadata.filename.?.catalog_file, a, .unlimited));
    damaged[0].id = "x";
    try bindCatalog(a, dir, try catalogBytes(a, segment.version_catalog_v6, damaged), null);
    try expectCatalogRefused(a, dir, error.FilenameCatalogIdPresent);
    for ([_]std.Io.Dir{ dir, clean }) |d| _ = switch (try apply.applyChanges(a, io, d, shed, .{})) {
        .ok => |r| r,
        .failed => return error.TestUnexpectedResult,
    };
    try expectSameSections(a, clean, dir);
}

test "S6-T9 state v3 S2 at the writer: a HYBSTA03 state over a HYBSRC01 source (bit 8 without bit 6, which no writer produces) is StateReferenceWithoutSource at the next write and at the pointer, the files untouched" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var dir = try copyOf(a, tmp, fixture_before_s6t7, "v1-source");
    defer dir.close(io);
    var metadata = try manifest.decode(try dir.readFileAlloc(io, publication.current_manifest_file, a, .unlimited));
    try std.testing.expect(metadata.hasSource() and !metadata.text_once);
    // The fixture's state, every file re-encoded as a reference to a record
    // of its own (ordinals 0, 1, ...): `HYBSTA03` with bit 8.
    const state_name = metadata.state.?.file;
    const state = try incremental_state.decodeSection(a, try dir.readFileAlloc(io, state_name, a, .unlimited));
    const refs = try a.alloc(?incremental_state.SourceRef, state.files.len);
    var n: u32 = 0;
    for (state.files, refs) |entry, *ref| {
        ref.* = null;
        if (entry.status != .indexed or entry.hash.len != 64 or entry.size == null) continue;
        var sha: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&sha, entry.hash);
        const path = if (std.mem.eql(u8, entry.root_id, incremental_state.legacy_root_id)) entry.path else try std.fmt.allocPrint(a, "{s}/{s}", .{ entry.root_id, entry.path });
        ref.* = .{ .ordinal = n, .path = path, .sha256 = sha, .length = entry.size.? };
        n += 1;
    }
    try std.testing.expect(n > 2);
    const section = try incremental_state.encodeSectionRefs(a, state, refs);
    try std.testing.expectEqualStrings("HYBSTA03", section[0..8]);
    try dir.writeFile(io, .{ .sub_path = state_name, .data = section });
    metadata = try manifest.withState(metadata, state_name, section);
    try std.testing.expect(metadata.state_v3);
    const buffer = try a.alloc(u8, try manifest.encodedLength(metadata));
    try publication.writeAtomicFile(dir, io, publication.current_manifest_file, try manifest.encode(metadata, buffer), true);
    var before: [files.len][]const u8 = undefined;
    for (files, &before) |name, *bytes| bytes.* = try dir.readFileAlloc(io, name, a, .unlimited);
    try std.testing.expectError(error.StateReferenceWithoutSource, apply.applyChanges(a, io, dir, shed, .{}));
    try std.testing.expectError(error.StateReferenceWithoutSource, incremental_state.loadBound(a, io, dir));
    for (files, before) |name, bytes| try std.testing.expectEqualSlices(u8, bytes, try dir.readFileAlloc(io, name, a, .unlimited));
}
