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

/// What `error.NoFreeGeneration` was about: the file (name only, never the
/// directory) that supplied the highest generation, and that generation. Set
/// by `nextFreeGeneration` just before it returns the error; read by the CLI
/// and the ABI to say which file to delete (S1-T18).
threadlocal var cause_name_buffer: [128]u8 = undefined;
threadlocal var cause_name_len: usize = 0;
threadlocal var cause_generation: u64 = 0;

fn recordCause(name: []const u8, generation: u64) void {
    const n = @min(name.len, cause_name_buffer.len);
    @memcpy(cause_name_buffer[0..n], name[0..n]);
    cause_name_len = n;
    cause_generation = generation;
}

/// One line for `error.NoFreeGeneration`, formatted into `buffer`.
pub fn describeNoFreeGeneration(buffer: []u8) []const u8 {
    return std.fmt.bufPrint(
        buffer,
        "NoFreeGeneration: no generation number above {d} (read from {s}); delete or rename that file to publish here",
        .{ cause_generation, cause_name_buffer[0..cause_name_len] },
    ) catch "NoFreeGeneration";
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
    _ = dir.statFile(io, name, .{}) catch |err| switch (err) {
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
    var highest = try currentGeneration(allocator, io, dir);
    recordCause(publication.current_manifest_file, highest);
    if (incremental_state.load(allocator, io, dir) catch null) |state| {
        if (state.generation > highest) recordCause("INDEX-STATE.json", state.generation);
        highest = @max(highest, state.generation);
    }
    var iterable = try dir.openDir(io, ".", .{ .iterate = true });
    defer iterable.close(io);
    var iterator = iterable.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (lifecycle.sectionGeneration(entry.name)) |number| {
            if (number > highest) recordCause(entry.name, number);
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
            recordCause(if (lexical_taken) lexical_name else documents_name, candidate);
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
