//! Picks a generation number that will not collide with an existing
//! `documents-N.hybseg`/`lexical-N.hyblex` pair when publishing into a
//! directory that already holds a snapshot (S1-T3, `docs/tasks/S1-T3.md`
//! criterion 5: `searchd index --out <existing dir>` must re-publish, not
//! fail with `PathAlreadyExists`).
//!
//! Also the recovery half of S1-T3's crash-mid-publication story: a process
//! that crashes between linking an immutable generation file and replacing
//! `MANIFEST` (see `docs/publication-recovery.md`'s crash-visibility matrix)
//! leaves an orphan `documents-K.hybseg`/`lexical-K.hyblex` on disk for the
//! generation it was trying to publish. `lifecycle.scan` already gives an
//! operator visibility into that orphan; `nextFreeGeneration` gives the next
//! automated indexing run a way to route around it instead of failing again
//! with the exact same `PathAlreadyExists`.
const std = @import("std");
const manifest = @import("manifest.zig");
const publication = @import("publication.zig");
const lifecycle = @import("lifecycle.zig");
const incremental_state = @import("incremental_state.zig");

/// Canonical trace kinds at the highest generation. Kept thread-local because
/// the CLI and ABI read the diagnostic immediately after allocation fails.
const Cause = enum(u4) {
    manifest = 1,
    index_state = 2,
    documents = 4,
    lexical = 8,
};

threadlocal var cause_mask: u4 = 0;
threadlocal var cause_generation: u64 = 0;

fn resetCause() void {
    cause_mask = 0;
    cause_generation = 0;
}

fn recordCause(cause: Cause, generation: u64) void {
    if (generation > cause_generation) {
        cause_generation = generation;
        cause_mask = 0;
    }
    if (generation == cause_generation) cause_mask |= @intFromEnum(cause);
}

fn appendGeneratedCauseName(buffer: []u8, used: *usize, comptime pattern: []const u8) void {
    if (used.* != 0) {
        @memcpy(buffer[used.* .. used.* + 2], ", ");
        used.* += 2;
    }
    const name = std.fmt.bufPrint(buffer[used.*..], pattern, .{cause_generation}) catch return;
    used.* += name.len;
}

/// One line for `error.NoFreeGeneration`, formatted into `buffer`.
pub fn describeNoFreeGeneration(buffer: []u8) []const u8 {
    var names_buffer: [160]u8 = undefined;
    var names_len: usize = 0;
    if (cause_mask & 1 != 0) appendLiteralCauseName(&names_buffer, &names_len, "MANIFEST");
    if (cause_mask & 2 != 0) appendLiteralCauseName(&names_buffer, &names_len, "INDEX-STATE.json");
    if (cause_mask & 4 != 0) appendGeneratedCauseName(&names_buffer, &names_len, "documents-{d}.hybseg");
    if (cause_mask & 8 != 0) appendGeneratedCauseName(&names_buffer, &names_len, "lexical-{d}.hyblex");
    return std.fmt.bufPrint(
        buffer,
        "NoFreeGeneration: no generation number above {d} (traces: {s}); use a fresh output directory; inspect listed traces before repair",
        .{ cause_generation, names_buffer[0..names_len] },
    ) catch "NoFreeGeneration";
}

fn appendLiteralCauseName(buffer: []u8, used: *usize, name: []const u8) void {
    if (used.* != 0) {
        @memcpy(buffer[used.* .. used.* + 2], ", ");
        used.* += 2;
    }
    @memcpy(buffer[used.* .. used.* + name.len], name);
    used.* += name.len;
}

/// The current generation recorded by `MANIFEST` in `dir`, or `0` if `dir`
/// has no manifest yet (a fresh output directory).
pub fn currentGeneration(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !u64 {
    var file = dir.openFile(io, publication.current_manifest_file, .{}) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    const stat = try file.stat(io);
    file.close(io);
    const size = std.math.cast(usize, stat.size) orelse return error.IndexTooLarge;
    const buffer = try allocator.alloc(u8, size);
    const encoded = try dir.readFile(io, publication.current_manifest_file, buffer);
    const metadata = try manifest.decode(encoded);
    return metadata.generation;
}

fn pathExists(dir: std.Io.Dir, io: std.Io, name: []const u8) !bool {
    // Publication reserves the filename itself, including a symlink whose
    // target is missing or loops back to the link.
    _ = dir.statFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

/// The highest generation number the directory has any trace of: the
/// `MANIFEST`'s, any canonical `documents-N.hybseg` / `lexical-N.hyblex`
/// present (complete or not), and the one `INDEX-STATE.json` names. `0` for
/// a fresh directory. A lost `MANIFEST` therefore cannot make the counter
/// start over (S2-T14).
pub fn highestGenerationOnDisk(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !u64 {
    resetCause();
    var highest = try currentGeneration(allocator, io, dir);
    if (highest != 0) recordCause(.manifest, highest);
    if (incremental_state.load(allocator, io, dir) catch null) |state| {
        recordCause(.index_state, state.generation);
        highest = @max(highest, state.generation);
    }
    var iterable = try dir.openDir(io, ".", .{ .iterate = true });
    defer iterable.close(io);
    var iterator = iterable.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (lifecycle.sectionGeneration(entry.name)) |number| {
            if (std.mem.startsWith(u8, entry.name, "documents-")) {
                recordCause(.documents, number);
            } else {
                recordCause(.lexical, number);
            }
            highest = @max(highest, number);
        }
    }
    return highest;
}

/// The smallest generation number strictly greater than everything
/// `highestGenerationOnDisk` finds whose `documents-*.hybseg` /
/// `lexical-*.hyblex` filenames are both free. `allocator` is used only for
/// transient reads; an arena is fine. At `u64` max there is no next number:
/// `error.NoFreeGeneration` (previously an integer-overflow panic).
pub fn nextFreeGeneration(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !u64 {
    const highest = try highestGenerationOnDisk(allocator, io, dir);
    var candidate = std.math.add(u64, highest, 1) catch return error.NoFreeGeneration;
    var attempts: usize = 0;
    while (attempts < 1_000_000) : (attempts += 1) {
        var name_buffer: [64]u8 = undefined;
        const documents_name = try std.fmt.bufPrint(&name_buffer, "documents-{d}.hybseg", .{candidate});
        const documents_taken = try pathExists(dir, io, documents_name);
        var lexical_buffer: [64]u8 = undefined;
        const lexical_name = try std.fmt.bufPrint(&lexical_buffer, "lexical-{d}.hyblex", .{candidate});
        const lexical_taken = try pathExists(dir, io, lexical_name);
        if (!documents_taken and !lexical_taken) return candidate;
        if (std.math.add(u64, candidate, 1)) |next| {
            candidate = next;
        } else |_| {
            // The exhausted candidate itself is blocked by these taken
            // sections, even when the previous highest generation was lower.
            cause_generation = candidate;
            cause_mask = 0;
            if (documents_taken) cause_mask |= @intFromEnum(Cause.documents);
            if (lexical_taken) cause_mask |= @intFromEnum(Cause.lexical);
            return error.NoFreeGeneration;
        }
    }
    return error.NoFreeGeneration;
}

test "nextFreeGeneration is 1 for a fresh directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const generation = try nextFreeGeneration(std.testing.allocator, std.testing.io, tmp.dir);
    try std.testing.expectEqual(@as(u64, 1), generation);
}

test "nextFreeGeneration skips a crash orphan past the current generation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    // Simulate a manifest at generation 1 by writing raw MANIFEST bytes is
    // more setup than needed here; instead simulate "current=0, but
    // generation 1's files already exist" (a crash before any manifest was
    // ever published, on the very first publish attempt).
    try tmp.dir.writeFile(io, .{ .sub_path = "documents-1.hybseg", .data = "orphan" });
    const generation = try nextFreeGeneration(std.testing.allocator, io, tmp.dir);
    try std.testing.expectEqual(@as(u64, 2), generation);
}

test "nextFreeGeneration skips dangling and looping section links without changing them" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    const documents = "documents-1.hybseg";
    const lexical = "lexical-2.hyblex";
    try tmp.dir.symLink(io, "missing-target", documents, .{});
    try tmp.dir.symLink(io, lexical, lexical, .{});
    try std.testing.expectEqual(@as(u64, 3), try nextFreeGeneration(std.testing.allocator, io, tmp.dir));
    var target: [64]u8 = undefined;
    const documents_len = try tmp.dir.readLink(io, documents, &target);
    try std.testing.expectEqualStrings("missing-target", target[0..documents_len]);
    const lexical_len = try tmp.dir.readLink(io, lexical, &target);
    try std.testing.expectEqualStrings(lexical, target[0..lexical_len]);
}

test "nextFreeGeneration reports exhaustion when max candidate is a dangling link" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const io = std.testing.io;
    const name = "documents-18446744073709551615.hybseg";
    try writeManifestGeneration(io, tmp.dir, std.math.maxInt(u64) - 1);
    try tmp.dir.symLink(io, "missing-target", name, .{});
    try std.testing.expectError(error.NoFreeGeneration, nextFreeGeneration(arena_state.allocator(), io, tmp.dir));
    var buffer: [256]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, describeNoFreeGeneration(&buffer), name) != null);
    var target: [64]u8 = undefined;
    const len = try tmp.dir.readLink(io, name, &target);
    try std.testing.expectEqualStrings("missing-target", target[0..len]);
}

test "nextFreeGeneration numbers above a lone higher section file and above INDEX-STATE" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "lexical-7.hyblex", .data = "half" });
    try std.testing.expectEqual(@as(u64, 8), try nextFreeGeneration(arena_state.allocator(), io, tmp.dir));
    try tmp.dir.writeFile(io, .{ .sub_path = "INDEX-STATE.json", .data = "{\"generation\":11,\"analyzer_id\":\"analyzer-v2\",\"files\":[]}" });
    try std.testing.expectEqual(@as(u64, 12), try nextFreeGeneration(arena_state.allocator(), io, tmp.dir));
}

test "nextFreeGeneration at u64 max is an error, not a panic" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "documents-18446744073709551615.hybseg", .data = "x" });
    try std.testing.expectError(error.NoFreeGeneration, nextFreeGeneration(arena_state.allocator(), io, tmp.dir));
}

test "NoFreeGeneration names the file and the generation read from it" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "lexical-18446744073709551615.hyblex", .data = "x" });
    try std.testing.expectError(error.NoFreeGeneration, nextFreeGeneration(arena_state.allocator(), io, tmp.dir));
    var buffer: [256]u8 = undefined;
    const line = describeNoFreeGeneration(&buffer);
    try std.testing.expect(std.mem.indexOf(u8, line, "lexical-18446744073709551615.hyblex") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "18446744073709551615") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, line, '\n') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, line, '/') == null);
}

fn writeManifestGeneration(io: std.Io, dir: std.Io.Dir, generation: u64) !void {
    const value = manifest.Manifest{
        .generation = generation,
        .document_count = 0,
        .vector_dimensions = 0,
        .term_count = 0,
        .posting_count = 0,
        .documents_bytes = 0,
        .documents_checksum = 0,
        .lexical_bytes = 0,
        .lexical_checksum = 0,
        .analyzer_id = "analyzer-v2",
        .embedding_model_id = "test-model",
        .documents_file = "documents-test.hybseg",
        .lexical_file = "lexical-test.hyblex",
    };
    var encoded: [256]u8 = undefined;
    try dir.writeFile(io, .{ .sub_path = publication.current_manifest_file, .data = try manifest.encode(value, &encoded) });
}

test "NoFreeGeneration lists all tied canonical traces in fixed order" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const io = std.testing.io;
    const max = std.math.maxInt(u64);
    const documents_name = "documents-18446744073709551615.hybseg";
    const lexical_name = "lexical-18446744073709551615.hyblex";
    try writeManifestGeneration(io, tmp.dir, max);
    try tmp.dir.writeFile(io, .{ .sub_path = "INDEX-STATE.json", .data = "{\"generation\":18446744073709551615,\"analyzer_id\":\"analyzer-v2\",\"files\":[]}" });
    try tmp.dir.writeFile(io, .{ .sub_path = documents_name, .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = lexical_name, .data = "x" });
    // These parse as lower or noncanonical names and must not enter the list.
    try tmp.dir.writeFile(io, .{ .sub_path = "documents-9.hybseg", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "lexical-018446744073709551615.hyblex", .data = "x" });
    try tmp.dir.createDir(io, "documents-77.hybseg", .default_dir);

    try std.testing.expectError(error.NoFreeGeneration, nextFreeGeneration(arena_state.allocator(), io, tmp.dir));
    var buffer: [256]u8 = undefined;
    const line = describeNoFreeGeneration(&buffer);
    try std.testing.expectEqualStrings(
        "NoFreeGeneration: no generation number above 18446744073709551615 (traces: MANIFEST, INDEX-STATE.json, documents-18446744073709551615.hybseg, lexical-18446744073709551615.hyblex); use a fresh output directory; inspect listed traces before repair",
        line,
    );

    // A second scan in this thread must replace the previous scan's ties.
    try tmp.dir.deleteFile(io, "MANIFEST");
    try tmp.dir.deleteFile(io, "INDEX-STATE.json");
    try tmp.dir.deleteFile(io, documents_name);
    try tmp.dir.deleteFile(io, lexical_name);
    try tmp.dir.deleteDir(io, "documents-77.hybseg");
    try tmp.dir.writeFile(io, .{ .sub_path = lexical_name, .data = "x" });
    try std.testing.expectError(error.NoFreeGeneration, nextFreeGeneration(arena_state.allocator(), io, tmp.dir));
    try std.testing.expectEqualStrings(
        "NoFreeGeneration: no generation number above 18446744073709551615 (traces: lexical-18446744073709551615.hyblex); use a fresh output directory; inspect listed traces before repair",
        describeNoFreeGeneration(&buffer),
    );
}

test "NoFreeGeneration lists a tied section subset above a lower manifest" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const io = std.testing.io;
    const max = std.math.maxInt(u64);
    const max_minus_one = max - 1;
    try writeManifestGeneration(io, tmp.dir, max_minus_one);
    try tmp.dir.writeFile(io, .{ .sub_path = "documents-18446744073709551615.hybseg", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "lexical-18446744073709551615.hyblex", .data = "x" });
    try std.testing.expectError(error.NoFreeGeneration, nextFreeGeneration(arena_state.allocator(), io, tmp.dir));
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "NoFreeGeneration: no generation number above 18446744073709551615 (traces: documents-18446744073709551615.hybseg, lexical-18446744073709551615.hyblex); use a fresh output directory; inspect listed traces before repair",
        describeNoFreeGeneration(&buffer),
    );
}
