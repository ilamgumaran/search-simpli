//! Persisted per-file state beside `MANIFEST`/`WRITER.LOCK`: `INDEX-STATE.json`
//! (S1-T3; version 2 since S3-T3, `docs/folder-knowledge-implementation.md`
//! section 5). Written with the same create-temp/sync/atomic-replace pattern
//! `publication.zig` uses for `MANIFEST` (`publication.writeAtomicFile`, a
//! named temp file plus rename -- never `Dir.createFileAtomic`'s `O_TMPFILE`
//! path; see that function's doc comment and `docs/publication-recovery.md`).
//!
//! This file is deliberately *not* part of the manifest format and is not
//! required for reading a snapshot: `ss_open`/`searchd query`/`serve` never
//! look at it. It feeds the next `apply_changes` / `index_folder` run: each
//! file's root, path, size, mtime, sha256, status, chunker, chunk count and
//! own labels. It is written *after* a generation publishes, so a crash
//! between the publication and this write leaves the previous state file in
//! place; `apply.zig` then sees `generation` disagree with `MANIFEST` and
//! rebuilds the file table from the generation itself (documents, the source
//! section's hashes, the manifest's roots and pending list) instead of
//! trusting it (`docs/publication-recovery.md`).
//!
//! Version 1 (no `state_version`; entries `{path, hash, size}`) still loads:
//! its files belong to one root `r-legacy` (`kind: local`, `origin: folder`).
const publication = @import("publication.zig");
const std = @import("std");

pub const state_file = "INDEX-STATE.json";
pub const state_version: u32 = 2;
pub const legacy_root_id = "r-legacy";

/// `indexed`: the file's chunks are in the generation. `pending`: named by
/// the host, bytes not arrived, no chunks (listed by name). The report-only
/// outcomes `too_large`, `unreadable` and `budget_exhausted` are not stored:
/// a too-large file is tombstoned and a left-over or unreadable file keeps
/// its previous entry (S1-T4), so the state names exactly the files the
/// generation names.
pub const Status = enum { indexed, pending };

pub const Root = struct {
    root_id: []const u8,
    label: []const u8,
    kind: []const u8,
    required_labels: []const []const u8 = &.{},
    retain_source: bool,
    origin: []const u8,
};

pub const Entry = struct {
    root_id: []const u8 = legacy_root_id,
    /// Root-relative POSIX path.
    path: []const u8,
    /// Lowercase hex SHA-256 of the file's raw bytes, 64 characters; empty
    /// when unknown (a pending file, or a file whose bytes were not retained
    /// when the state had to be rebuilt from the generation).
    hash: []const u8,
    size: ?u64,
    mtime_ms: ?i64 = null,
    status: Status = .indexed,
    chunker: ?[]const u8 = null,
    chunks: u32 = 0,
    moved_from: ?[]const u8 = null,
    /// The file's own required labels (the root's are added to them in the
    /// document records).
    required_labels: []const []const u8 = &.{},
};

pub const State = struct {
    generation: u64,
    analyzer_id: []const u8,
    /// Empty for a version 1 file (its files belong to `r-legacy`).
    roots: []const Root = &.{},
    files: []const Entry,
    /// 1 when loaded from a version 1 file.
    version: u32 = state_version,
};

pub const LoadError = error{ InvalidState, StateTooLarge, OutOfMemory };

/// Read and parse `INDEX-STATE.json` from `dir`, if present. All returned
/// memory (including every string) is allocated from `allocator`. Returns
/// `null` if the file does not exist.
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
    return try parse(allocator, bytes);
}

const WireRoot = struct {
    root_id: []const u8,
    label: []const u8,
    kind: []const u8,
    required_labels: []const []const u8 = &.{},
    retain_source: bool,
    origin: []const u8,
};

/// Both versions' entries: version 1 has `hash` and `size` only.
const WireFile = struct {
    root_id: ?[]const u8 = null,
    path: []const u8,
    hash: ?[]const u8 = null,
    sha256: ?[]const u8 = null,
    size: ?u64 = null,
    mtime_ms: ?i64 = null,
    status: ?[]const u8 = null,
    chunker: ?[]const u8 = null,
    chunks: ?u32 = null,
    moved_from: ?[]const u8 = null,
    required_labels: []const []const u8 = &.{},
};

const WireState = struct {
    state_version: ?u32 = null,
    generation: u64,
    analyzer_id: []const u8,
    roots: ?[]const WireRoot = null,
    files: []const WireFile,
};

/// Parse either version (see the file comment). A typed parse (no JSON
/// object maps): the state of a 10k-file index is read on every
/// `apply_changes` call.
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) LoadError!State {
    const wire = std.json.parseFromSliceLeaky(WireState, allocator, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidState,
    };
    return normalizeWire(allocator, wire);
}

fn normalizeWire(allocator: std.mem.Allocator, wire: WireState) LoadError!State {
    const files = try allocator.alloc(Entry, wire.files.len);
    if (wire.state_version == null) {
        for (wire.files, files) |item, *entry| {
            entry.* = .{
                .path = item.path,
                .hash = item.hash orelse return error.InvalidState,
                .size = item.size orelse return error.InvalidState,
            };
        }
        return .{ .generation = wire.generation, .analyzer_id = wire.analyzer_id, .files = files, .version = 1 };
    }
    if (wire.state_version.? != state_version) return error.InvalidState;
    const wire_roots = wire.roots orelse return error.InvalidState;
    const roots = try allocator.alloc(Root, wire_roots.len);
    for (wire_roots, roots) |item, *root| root.* = .{
        .root_id = item.root_id,
        .label = item.label,
        .kind = item.kind,
        .required_labels = item.required_labels,
        .retain_source = item.retain_source,
        .origin = item.origin,
    };
    for (wire.files, files) |item, *entry| {
        const status_text = item.status orelse return error.InvalidState;
        entry.* = .{
            .root_id = item.root_id orelse return error.InvalidState,
            .path = item.path,
            .hash = item.sha256 orelse "",
            .size = item.size,
            .mtime_ms = item.mtime_ms,
            .status = std.meta.stringToEnum(Status, status_text) orelse return error.InvalidState,
            .chunker = item.chunker,
            .chunks = item.chunks orelse return error.InvalidState,
            .moved_from = item.moved_from,
            .required_labels = item.required_labels,
        };
    }
    return .{ .generation = wire.generation, .analyzer_id = wire.analyzer_id, .roots = roots, .files = files };
}

/// The state a generation's bound recovery-state section carries
/// (`state_section.payload`, S4-T2 R3): typed, strict (an unknown field is
/// `InvalidState`) and version 2 only, since only writers since v2.2 write
/// the section.
pub fn parseCommitted(allocator: std.mem.Allocator, payload: []const u8) LoadError!State {
    const wire = std.json.parseFromSliceLeaky(WireState, allocator, payload, .{ .ignore_unknown_fields = false }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidState,
    };
    if (wire.state_version == null) return error.InvalidState;
    return normalizeWire(allocator, wire);
}

fn writeLabels(json: *std.json.Stringify, labels: []const []const u8) !void {
    try json.beginArray();
    for (labels) |label| try json.write(label);
    try json.endArray();
}

test "committed state uses typed decoding and rejects null, version 1 or unknown state fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.InvalidState, parseCommitted(a, "null"));
    try std.testing.expectError(error.InvalidState, parseCommitted(a, "{\"generation\":1,\"analyzer_id\":\"a\",\"files\":[]}"));
    try std.testing.expectError(error.InvalidState, parseCommitted(a, "{\"state_version\":2,\"generation\":1,\"analyzer_id\":\"a\",\"roots\":[],\"files\":[],\"extra\":true}"));
    const committed = try encode(a, .{ .generation = 7, .analyzer_id = "analyzer-v2", .files = &.{} });
    try std.testing.expectEqual(@as(u64, 7), (try parseCommitted(a, committed)).generation);
}

/// The version 2 JSON of `state` (keys in the order of section 5). When
/// `state.roots` is empty (a caller that only knows the one folder root), the
/// legacy root is written.
pub fn encode(allocator: std.mem.Allocator, state: State) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var json = std.json.Stringify{ .writer = &out.writer };
    try json.beginObject();
    try json.objectField("state_version");
    try json.write(state_version);
    try json.objectField("generation");
    try json.write(state.generation);
    try json.objectField("analyzer_id");
    try json.write(state.analyzer_id);
    try json.objectField("roots");
    try json.beginArray();
    const legacy = [_]Root{.{ .root_id = legacy_root_id, .label = "folder", .kind = "local", .retain_source = true, .origin = "folder" }};
    const roots: []const Root = if (state.roots.len == 0) &legacy else state.roots;
    for (roots) |root| {
        try json.beginObject();
        try json.objectField("root_id");
        try json.write(root.root_id);
        try json.objectField("label");
        try json.write(root.label);
        try json.objectField("kind");
        try json.write(root.kind);
        try json.objectField("required_labels");
        try writeLabels(&json, root.required_labels);
        try json.objectField("retain_source");
        try json.write(root.retain_source);
        try json.objectField("origin");
        try json.write(root.origin);
        try json.endObject();
    }
    try json.endArray();
    try json.objectField("files");
    try json.beginArray();
    for (state.files) |entry| {
        try json.beginObject();
        try json.objectField("root_id");
        try json.write(entry.root_id);
        try json.objectField("path");
        try json.write(entry.path);
        try json.objectField("size");
        try json.write(entry.size);
        try json.objectField("mtime_ms");
        try json.write(entry.mtime_ms);
        try json.objectField("sha256");
        if (entry.hash.len == 0) try json.write(null) else try json.write(entry.hash);
        try json.objectField("status");
        try json.write(@tagName(entry.status));
        try json.objectField("chunker");
        try json.write(entry.chunker);
        try json.objectField("chunks");
        try json.write(entry.chunks);
        try json.objectField("moved_from");
        try json.write(entry.moved_from);
        try json.objectField("required_labels");
        try writeLabels(&json, entry.required_labels);
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
    return out.toOwnedSlice();
}

/// Atomically (write-temp, sync, replace) write `INDEX-STATE.json` (version
/// 2) in `dir`. Called only after the generation it describes has been
/// published.
pub fn save(io: std.Io, dir: std.Io.Dir, allocator: std.mem.Allocator, state: State) !void {
    const encoded = try encode(allocator, state);
    defer allocator.free(encoded);
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
    try std.testing.expectEqual(@as(?u64, 12), loaded.files[0].size);
    try std.testing.expectEqualStrings("dir/b.md", loaded.files[1].path);
    try std.testing.expectEqualStrings(legacy_root_id, loaded.files[1].root_id);
    try std.testing.expectEqual(@as(usize, 1), loaded.roots.len);
}

test "state v2 keeps roots, statuses, labels and moves; v1 loads as r-legacy" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const roots = [_]Root{.{ .root_id = "r-6f1a", .label = "School", .kind = "icloud", .required_labels = &.{"cloud-ok"}, .retain_source = true, .origin = "host" }};
    const files = [_]Entry{
        .{ .root_id = "r-6f1a", .path = "week-07.md", .hash = "c" ** 64, .size = 4211, .mtime_ms = 1761900000000, .chunker = "md-section-v1", .chunks = 3, .moved_from = "week-7.md", .required_labels = &.{"family"} },
        .{ .root_id = "r-6f1a", .path = "week-08.md", .hash = "", .size = 3900, .status = .pending },
    };
    const encoded = try encode(arena, .{ .generation = 17, .analyzer_id = "analyzer-v2", .roots = &roots, .files = &files });
    try std.testing.expect(std.mem.startsWith(u8, encoded, "{\"state_version\":2,\"generation\":17,"));
    const back = try parse(arena, encoded);
    try std.testing.expectEqual(@as(u32, 2), back.version);
    try std.testing.expectEqualStrings("cloud-ok", back.roots[0].required_labels[0]);
    try std.testing.expectEqualStrings("host", back.roots[0].origin);
    try std.testing.expectEqual(Status.pending, back.files[1].status);
    try std.testing.expectEqualStrings("", back.files[1].hash);
    try std.testing.expectEqualStrings("week-7.md", back.files[0].moved_from.?);
    try std.testing.expectEqualStrings("family", back.files[0].required_labels[0]);
    try std.testing.expectEqual(@as(?i64, 1761900000000), back.files[0].mtime_ms);

    const v1 = try parse(arena, "{\"generation\":4,\"analyzer_id\":\"analyzer-v2\",\"files\":[{\"path\":\"a.md\",\"hash\":\"" ++ "d" ** 64 ++ "\",\"size\":5}]}");
    try std.testing.expectEqual(@as(u32, 1), v1.version);
    try std.testing.expectEqualStrings(legacy_root_id, v1.files[0].root_id);
    try std.testing.expectEqual(Status.indexed, v1.files[0].status);
    try std.testing.expectError(error.InvalidState, parse(arena, "{\"state_version\":3,\"generation\":1,\"analyzer_id\":\"a\",\"files\":[]}"));
    try std.testing.expectError(error.InvalidState, parse(arena, "[]"));
}
