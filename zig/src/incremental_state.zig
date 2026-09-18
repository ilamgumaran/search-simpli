//! Persisted per-file content-hash state for `indexer.indexFolderIncremental`
//! (S1-T3, `docs/tasks/S1-T3.md`). Lives beside `MANIFEST`/`WRITER.LOCK` as a
//! fixed-name JSON file, `INDEX-STATE.json`, written with the same
//! create-temp/sync/atomic-replace pattern `publication.zig` uses for
//! `MANIFEST` (`publication.writeAtomicFile`, a named temp file plus
//! rename -- never `Dir.createFileAtomic`'s `O_TMPFILE` path; see that
//! function's doc comment and `docs/publication-recovery.md`).
//!
//! This file is deliberately *not* part of the manifest format (v1,
//! `HYBMAN01`, `docs/manifest-format-v1.md`) and is not required for reading
//! a snapshot: `ss_open`/`searchd query`/`serve` never look at it. It only
//! feeds the next incremental indexing run. It is written *after* a
//! generation publishes successfully, so a crash between publication and
//! this write leaves the previous (still valid) state file in place -- the
//! next incremental run just re-hashes and re-chunks every candidate file
//! once more (falls back to correct, only loses the skip optimization for
//! that one run), rather than risking any inconsistency with what was
//! actually published.
const publication = @import("publication.zig");
const std = @import("std");

pub const state_file = "INDEX-STATE.json";

pub const Entry = struct {
    path: []const u8,
    /// Lowercase hex SHA-256 of the file's raw bytes, 64 characters.
    hash: []const u8,
    size: u64,
};

pub const State = struct {
    generation: u64,
    analyzer_id: []const u8,
    files: []const Entry,
};

const WireEntry = struct {
    path: []const u8,
    hash: []const u8,
    size: u64,
};

const WireState = struct {
    generation: u64,
    analyzer_id: []const u8,
    files: []const WireEntry,
};

/// Read and parse `INDEX-STATE.json` from `dir`, if present. All returned
/// memory (including every string) is allocated from `allocator`. Returns
/// `null` if the file does not exist (first-ever index, or a directory
/// published only by the non-incremental path, which never writes this
/// file).
pub fn load(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !?State {
    var file = dir.openFile(io, state_file, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const stat = try file.stat(io);
    file.close(io);
    const size = std.math.cast(usize, stat.size) orelse return error.StateTooLarge;
    const buffer = try allocator.alloc(u8, size);
    const bytes = try dir.readFile(io, state_file, buffer);

    const parsed = try std.json.parseFromSliceLeaky(WireState, allocator, bytes, .{});
    const files = try allocator.alloc(Entry, parsed.files.len);
    for (parsed.files, 0..) |entry, i| {
        files[i] = .{ .path = entry.path, .hash = entry.hash, .size = entry.size };
    }
    return .{ .generation = parsed.generation, .analyzer_id = parsed.analyzer_id, .files = files };
}

/// Atomically (write-temp, sync, replace) write `INDEX-STATE.json` in `dir`.
/// Intended to be called only after the generation it describes has already
/// been published through `lifecycle.publishSerialized`.
pub fn save(io: std.Io, dir: std.Io.Dir, allocator: std.mem.Allocator, state: State) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json = std.json.Stringify{ .writer = &out.writer };
    try json.beginObject();
    try json.objectField("generation");
    try json.write(state.generation);
    try json.objectField("analyzer_id");
    try json.write(state.analyzer_id);
    try json.objectField("files");
    try json.beginArray();
    for (state.files) |entry| {
        try json.beginObject();
        try json.objectField("path");
        try json.write(entry.path);
        try json.objectField("hash");
        try json.write(entry.hash);
        try json.objectField("size");
        try json.write(entry.size);
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
    const encoded = out.written();
    try publication.writeAtomicFile(dir, io, state_file, encoded, true);
}

test "state round-trips through save/load" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    const before = try load(arena, io, tmp.dir);
    try std.testing.expect(before == null);

    const entries = [_]Entry{
        .{ .path = "a.md", .hash = "a" ** 64, .size = 12 },
        .{ .path = "dir/b.md", .hash = "b" ** 64, .size = 34 },
    };
    try save(io, tmp.dir, arena, .{ .generation = 3, .analyzer_id = "analyzer-v2", .files = &entries });

    const loaded = (try load(arena, io, tmp.dir)).?;
    try std.testing.expectEqual(@as(u64, 3), loaded.generation);
    try std.testing.expectEqualStrings("analyzer-v2", loaded.analyzer_id);
    try std.testing.expectEqual(@as(usize, 2), loaded.files.len);
    try std.testing.expectEqualStrings("a.md", loaded.files[0].path);
    try std.testing.expectEqualStrings("a" ** 64, loaded.files[0].hash);
    try std.testing.expectEqual(@as(u64, 12), loaded.files[0].size);
    try std.testing.expectEqualStrings("dir/b.md", loaded.files[1].path);
}
