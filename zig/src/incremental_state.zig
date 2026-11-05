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
//!
//! Version 3 (S4-T4 ruling 2) is a **pointer**: once a generation binds its
//! state as the section `state-N.hybstate` (manifest v2.2, flag bit 4), the
//! file is only `{"state_version":3,"generation":N,"analyzer_id":"…",
//! "state_file":"state-N.hybstate"}`, and `load` reads the named section,
//! checked against the current `MANIFEST` as the writer checks it. A pointer
//! the `MANIFEST` does not bind (or no `MANIFEST`) loads as `null`, never as a
//! partial state; a writer always prefers the bound section to this file.
const manifest = @import("manifest.zig");
const publication = @import("publication.zig");
const state_section = @import("state_section.zig");
const std = @import("std");

pub const state_file = "INDEX-STATE.json";
pub const state_version: u32 = 2;
/// `INDEX-STATE.json` as a pointer to the generation's bound state section.
pub const pointer_version: u32 = 3;
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

/// Read `INDEX-STATE.json` from `dir` and return the state it holds or, for
/// a version 3 pointer, the state of the section it names (`resolvePointer`).
/// All returned memory (including every string) is allocated from
/// `allocator`. Returns `null` if the file does not exist, and for a pointer
/// the current `MANIFEST` does not bind.
pub fn load(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !?State {
    const bytes = (try readStateFile(allocator, io, dir)) orelse return null;
    if (parsePointer(allocator, bytes)) |pointer| return resolvePointer(allocator, io, dir, pointer);
    return try parse(allocator, bytes);
}

/// The generation `INDEX-STATE.json` names, whatever its version, without
/// reading a section (`generation_alloc`: a lost `MANIFEST` must not make the
/// counter start over). `null` when the file is absent or unreadable.
pub fn recordedGeneration(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) ?u64 {
    const bytes = (readStateFile(allocator, io, dir) catch return null) orelse return null;
    if (parsePointer(allocator, bytes)) |pointer| return pointer.generation;
    const state = parse(allocator, bytes) catch return null;
    return state.generation;
}

fn readStateFile(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !?[]u8 {
    var file = dir.openFile(io, state_file, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const stat = try file.stat(io);
    file.close(io);
    const size = std.math.cast(usize, stat.size) orelse return error.StateTooLarge;
    const buffer = try allocator.alloc(u8, size);
    return try dir.readFile(io, state_file, buffer);
}

pub const Pointer = struct {
    generation: u64,
    analyzer_id: []const u8,
    /// The section's file name, `state-N.hybstate`.
    state_file: []const u8,
};

const WirePointer = struct {
    state_version: u32,
    generation: u64,
    analyzer_id: []const u8,
    state_file: []const u8,
};

/// A version 3 pointer, exactly its four fields; `null` for anything else
/// (a version 1 or 2 state, which fails at its first other field, or bytes
/// that are not a pointer).
pub fn parsePointer(allocator: std.mem.Allocator, bytes: []const u8) ?Pointer {
    const wire = std.json.parseFromSliceLeaky(WirePointer, allocator, bytes, .{ .ignore_unknown_fields = false }) catch return null;
    if (wire.state_version != pointer_version) return null;
    return .{ .generation = wire.generation, .analyzer_id = wire.analyzer_id, .state_file = wire.state_file };
}

/// The state a pointer names, checked as the writer checks a bound section:
/// the current `MANIFEST` must bind `pointer.state_file` for the pointer's
/// generation and analyzer (else `null`), and the section must pass
/// `manifest.validateState` (size, header, checksum) and decode to that same
/// generation and analyzer (else `error.InvalidState`).
pub fn resolvePointer(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, pointer: Pointer) LoadError!?State {
    const manifest_bytes = readNamed(allocator, io, dir, publication.current_manifest_file) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    const metadata = manifest.decode(manifest_bytes) catch return null;
    const bound = metadata.state orelse return null;
    if (!std.mem.eql(u8, bound.file, pointer.state_file) or metadata.generation != pointer.generation or
        !std.mem.eql(u8, metadata.analyzer_id, pointer.analyzer_id)) return null;
    const section = readNamed(allocator, io, dir, bound.file) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    manifest.validateState(metadata, section) catch return error.InvalidState;
    const state = try decodeSection(allocator, section);
    if (state.generation != metadata.generation or !std.mem.eql(u8, state.analyzer_id, metadata.analyzer_id)) return error.InvalidState;
    return state;
}

fn readNamed(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8) ![]u8 {
    const stat = try dir.statFile(io, name, .{});
    const size = std.math.cast(usize, stat.size) orelse return error.StateTooLarge;
    const buffer = try allocator.alloc(u8, size);
    return dir.readFile(io, name, buffer);
}

/// The state a recovery-state section carries (`state_section.inspect`
/// already accepted it): the JSON of `HYBSTA01` (S4-T2) or the binary state
/// of `HYBSTA02` (S4-T4).
pub fn decodeSection(allocator: std.mem.Allocator, section: []const u8) LoadError!State {
    return switch (state_section.formOf(section)) {
        .json => parseCommitted(allocator, state_section.payload(section)),
        .binary => decodeBinary(allocator, state_section.payload(section)),
    };
}

/// The `HYBSTA02` section of `state` (S4-T4 ruling 3), as writers publish it.
pub fn encodeSection(allocator: std.mem.Allocator, state: State) ![]u8 {
    return state_section.encodeBinary(allocator, try encodeBinary(allocator, state));
}

// --- the binary state (HYBSTA02 payload, docs/state-section-format-v2.md) ---

/// Payload header bytes, root record bytes, file record bytes.
pub const binary_header_length: usize = 40;
pub const binary_root_length: usize = 24;
pub const binary_file_length: usize = 76;

const file_has_size: u32 = 1 << 0;
const file_has_mtime: u32 = 1 << 1;
const file_has_sha256: u32 = 1 << 2;
const file_pending: u32 = 1 << 3;
const file_has_moved_from: u32 = 1 << 4;
const file_has_chunker: u32 = 1 << 5;
const file_known_flags: u32 = (1 << 6) - 1;
const root_retain_source: u32 = 1 << 0;

/// Shared strings (root ids, labels, kinds, origins, chunker ids, the
/// analyzer) once each, in first-use order.
const StringTable = struct {
    index: std.StringHashMapUnmanaged(u32) = .empty,
    items: std.ArrayList([]const u8) = .empty,

    fn ref(table: *StringTable, allocator: std.mem.Allocator, text: []const u8) !u32 {
        const slot = try table.index.getOrPut(allocator, text);
        if (!slot.found_existing) {
            slot.value_ptr.* = std.math.cast(u32, table.items.items.len) orelse return error.StateTooLarge;
            try table.items.append(allocator, text);
        }
        return slot.value_ptr.*;
    }
};

fn rawHash(hash: []const u8) ?[32]u8 {
    if (hash.len != 64) return null;
    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hash) catch return null;
    return out;
}

fn put32(out: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, out[at..][0..4], value, .little);
}

fn put64(out: []u8, at: usize, value: u64) void {
    std.mem.writeInt(u64, out[at..][0..8], value, .little);
}

fn count32(value: usize) !u32 {
    return std.math.cast(u32, value) orelse error.StateTooLarge;
}

/// The binary state of `state` (`docs/state-section-format-v2.md`): one
/// string table for the shared strings, fixed-width little-endian records,
/// each hash as 32 raw bytes. A hash that is not 64 hex digits is stored as
/// unknown (`sha256` absent): no writer of this engine records one.
pub fn encodeBinary(allocator: std.mem.Allocator, state: State) ![]u8 {
    var strings = StringTable{};
    defer strings.index.deinit(allocator);
    defer strings.items.deinit(allocator);
    const legacy = [_]Root{.{ .root_id = legacy_root_id, .label = "folder", .kind = "local", .retain_source = true, .origin = "folder" }};
    const roots: []const Root = if (state.roots.len == 0) &legacy else state.roots;
    const analyzer = try strings.ref(allocator, state.analyzer_id);
    var label_refs = std.ArrayList(u32).empty;
    defer label_refs.deinit(allocator);
    var text_bytes: usize = 0;
    const root_refs = try allocator.alloc([4]u32, roots.len);
    defer allocator.free(root_refs);
    for (roots, root_refs) |root, *refs| {
        refs.* = .{ try strings.ref(allocator, root.root_id), try strings.ref(allocator, root.label), try strings.ref(allocator, root.kind), try strings.ref(allocator, root.origin) };
        for (root.required_labels) |label| try label_refs.append(allocator, try strings.ref(allocator, label));
    }
    const file_refs = try allocator.alloc([2]u32, state.files.len);
    defer allocator.free(file_refs);
    for (state.files, file_refs) |entry, *refs| {
        refs.* = .{ try strings.ref(allocator, entry.root_id), if (entry.chunker) |c| try strings.ref(allocator, c) else 0 };
        for (entry.required_labels) |label| try label_refs.append(allocator, try strings.ref(allocator, label));
        text_bytes += entry.path.len + (if (entry.moved_from) |m| m.len else 0);
    }
    var string_bytes: usize = 0;
    for (strings.items.items) |text| string_bytes += text.len;
    const total = binary_header_length + 4 * strings.items.items.len + string_bytes + binary_root_length * roots.len +
        binary_file_length * state.files.len + 4 * label_refs.items.len + text_bytes;
    const out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);
    @memset(out, 0);
    put32(out, 0, state_version);
    put64(out, 8, state.generation);
    put32(out, 16, analyzer);
    put32(out, 20, try count32(strings.items.items.len));
    put32(out, 24, try count32(roots.len));
    put32(out, 28, try count32(state.files.len));
    put32(out, 32, try count32(label_refs.items.len));
    var at: usize = binary_header_length;
    for (strings.items.items) |text| {
        put32(out, at, try count32(text.len));
        at += 4;
    }
    for (strings.items.items) |text| {
        @memcpy(out[at..][0..text.len], text);
        at += text.len;
    }
    for (roots, root_refs) |root, refs| {
        for (refs, 0..) |ref, i| put32(out, at + 4 * i, ref);
        put32(out, at + 16, if (root.retain_source) root_retain_source else 0);
        put32(out, at + 20, try count32(root.required_labels.len));
        at += binary_root_length;
    }
    for (state.files, file_refs) |entry, refs| {
        var flags: u32 = 0;
        if (entry.status == .pending) flags |= file_pending;
        put32(out, at, refs[0]);
        if (entry.size) |size| {
            flags |= file_has_size;
            put64(out, at + 8, size);
        }
        if (entry.mtime_ms) |mtime| {
            flags |= file_has_mtime;
            put64(out, at + 16, @bitCast(mtime));
        }
        put32(out, at + 24, entry.chunks);
        if (entry.chunker != null) {
            flags |= file_has_chunker;
            put32(out, at + 28, refs[1]);
        }
        put32(out, at + 32, try count32(entry.required_labels.len));
        put32(out, at + 36, try count32(entry.path.len));
        if (entry.moved_from) |moved| {
            flags |= file_has_moved_from;
            put32(out, at + 40, try count32(moved.len));
        }
        if (rawHash(entry.hash)) |raw| {
            flags |= file_has_sha256;
            @memcpy(out[at + 44 ..][0..32], &raw);
        }
        put32(out, at + 4, flags);
        at += binary_file_length;
    }
    for (label_refs.items) |ref| {
        put32(out, at, ref);
        at += 4;
    }
    for (state.files) |entry| {
        @memcpy(out[at..][0..entry.path.len], entry.path);
        at += entry.path.len;
        if (entry.moved_from) |moved| {
            @memcpy(out[at..][0..moved.len], moved);
            at += moved.len;
        }
    }
    std.debug.assert(at == total);
    return out;
}

/// Reads the binary state front to back; any inconsistency is
/// `InvalidState`.
const Reader = struct {
    bytes: []const u8,
    at: usize = 0,

    fn take(reader: *Reader, length: usize) LoadError![]const u8 {
        if (length > reader.bytes.len - reader.at) return error.InvalidState;
        const out = reader.bytes[reader.at..][0..length];
        reader.at += length;
        return out;
    }
};

fn read32(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}

fn read64(bytes: []const u8, at: usize) u64 {
    return std.mem.readInt(u64, bytes[at..][0..8], .little);
}

fn stringAt(strings: []const []const u8, ref: u32) LoadError![]const u8 {
    if (ref >= strings.len) return error.InvalidState;
    return strings[ref];
}

fn utf8Text(text: []const u8) LoadError![]const u8 {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidState;
    return text;
}

/// The state of a `HYBSTA02` payload. Strings and paths are slices of
/// `bytes`, which must outlive the result (callers keep the section in the
/// same arena); the label lists and hex hashes are allocated.
pub fn decodeBinary(allocator: std.mem.Allocator, bytes: []const u8) LoadError!State {
    var reader = Reader{ .bytes = bytes };
    const header = try reader.take(binary_header_length);
    if (read32(header, 0) != state_version or read32(header, 4) != 0 or read32(header, 36) != 0) return error.InvalidState;
    const generation = read64(header, 8);
    const string_count = read32(header, 20);
    const root_count = read32(header, 24);
    const file_count = read32(header, 28);
    const label_ref_count = read32(header, 32);
    // Every count is bounded by the bytes it needs before anything is
    // allocated for it.
    const fixed = @as(u128, 4) * string_count + @as(u128, binary_root_length) * root_count + @as(u128, binary_file_length) * file_count + @as(u128, 4) * label_ref_count;
    if (fixed > bytes.len - reader.at) return error.InvalidState;
    const lengths = try reader.take(4 * @as(usize, string_count));
    const strings = try allocator.alloc([]const u8, string_count);
    for (strings, 0..) |*text, i| text.* = try utf8Text(try reader.take(read32(lengths, 4 * i)));
    const analyzer_id = try stringAt(strings, read32(header, 16));
    const root_records = try reader.take(binary_root_length * @as(usize, root_count));
    const file_records = try reader.take(binary_file_length * @as(usize, file_count));
    const label_bytes = try reader.take(4 * @as(usize, label_ref_count));
    const labels = try allocator.alloc([]const u8, label_ref_count);
    for (labels, 0..) |*label, i| label.* = try stringAt(strings, read32(label_bytes, 4 * i));
    var next_label: usize = 0;
    const roots = try allocator.alloc(Root, root_count);
    for (roots, 0..) |*root, i| {
        const record = root_records[binary_root_length * i ..][0..binary_root_length];
        const flags = read32(record, 16);
        if (flags & ~root_retain_source != 0) return error.InvalidState;
        const label_count = read32(record, 20);
        if (label_count > labels.len - next_label) return error.InvalidState;
        root.* = .{
            .root_id = try stringAt(strings, read32(record, 0)),
            .label = try stringAt(strings, read32(record, 4)),
            .kind = try stringAt(strings, read32(record, 8)),
            .origin = try stringAt(strings, read32(record, 12)),
            .retain_source = flags & root_retain_source != 0,
            .required_labels = labels[next_label..][0..label_count],
        };
        next_label += label_count;
    }
    const files = try allocator.alloc(Entry, file_count);
    const hashes = try allocator.alloc(u8, 64 * @as(usize, file_count));
    for (files, 0..) |*entry, i| {
        const record = file_records[binary_file_length * i ..][0..binary_file_length];
        const flags = read32(record, 4);
        if (flags & ~file_known_flags != 0) return error.InvalidState;
        const label_count = read32(record, 32);
        if (label_count > labels.len - next_label) return error.InvalidState;
        const raw = record[44..76];
        const hash: []const u8 = if (flags & file_has_sha256 != 0) blk: {
            const hex = hashes[64 * i ..][0..64];
            hex.* = std.fmt.bytesToHex(raw[0..32].*, .lower);
            break :blk hex;
        } else "";
        // An absent field is stored as zeros: anything else is not this format.
        if (flags & file_has_sha256 == 0 and !std.mem.allEqual(u8, raw, 0)) return error.InvalidState;
        if (flags & file_has_size == 0 and read64(record, 8) != 0) return error.InvalidState;
        if (flags & file_has_mtime == 0 and read64(record, 16) != 0) return error.InvalidState;
        if (flags & file_has_chunker == 0 and read32(record, 28) != 0) return error.InvalidState;
        if (flags & file_has_moved_from == 0 and read32(record, 40) != 0) return error.InvalidState;
        // The text area holds each file's path, then its `moved_from`.
        const path = try utf8Text(try reader.take(read32(record, 36)));
        const moved_from: ?[]const u8 = if (flags & file_has_moved_from != 0) try utf8Text(try reader.take(read32(record, 40))) else null;
        entry.* = .{
            .root_id = try stringAt(strings, read32(record, 0)),
            .path = path,
            .hash = hash,
            .size = if (flags & file_has_size != 0) read64(record, 8) else null,
            .mtime_ms = if (flags & file_has_mtime != 0) @bitCast(read64(record, 16)) else null,
            .status = if (flags & file_pending != 0) .pending else .indexed,
            .chunker = if (flags & file_has_chunker != 0) try stringAt(strings, read32(record, 28)) else null,
            .chunks = read32(record, 24),
            .moved_from = moved_from,
            .required_labels = labels[next_label..][0..label_count],
        };
        next_label += label_count;
    }
    if (next_label != labels.len or reader.at != bytes.len) return error.InvalidState;
    return .{ .generation = generation, .analyzer_id = analyzer_id, .roots = roots, .files = files };
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
/// published. Since S4-T4 the writers publish a bound state section and call
/// `savePointer` instead; a version 2 file still loads.
pub fn save(io: std.Io, dir: std.Io.Dir, allocator: std.mem.Allocator, state: State) !void {
    const encoded = try encode(allocator, state);
    defer allocator.free(encoded);
    try publication.writeAtomicFile(dir, io, state_file, encoded, true);
}

/// The version 3 pointer's JSON.
pub fn encodePointer(allocator: std.mem.Allocator, pointer: Pointer) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var json = std.json.Stringify{ .writer = &out.writer };
    try json.beginObject();
    try json.objectField("state_version");
    try json.write(pointer_version);
    try json.objectField("generation");
    try json.write(pointer.generation);
    try json.objectField("analyzer_id");
    try json.write(pointer.analyzer_id);
    try json.objectField("state_file");
    try json.write(pointer.state_file);
    try json.endObject();
    return out.toOwnedSlice();
}

/// Atomically write `INDEX-STATE.json` as a version 3 pointer to the bound
/// state section of the generation just published (S4-T4 ruling 2).
pub fn savePointer(io: std.Io, dir: std.Io.Dir, allocator: std.mem.Allocator, pointer: Pointer) !void {
    const encoded = try encodePointer(allocator, pointer);
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

test "S4-T4: the version 3 pointer round-trips and is told apart from a version 1 or 2 state" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const encoded = try encodePointer(a, .{ .generation = 12, .analyzer_id = "analyzer-v2", .state_file = "state-12.hybstate" });
    try std.testing.expectEqualStrings("{\"state_version\":3,\"generation\":12,\"analyzer_id\":\"analyzer-v2\",\"state_file\":\"state-12.hybstate\"}", encoded);
    const back = parsePointer(a, encoded).?;
    try std.testing.expectEqual(@as(u64, 12), back.generation);
    try std.testing.expectEqualStrings("state-12.hybstate", back.state_file);
    // Not a pointer: a version 2 state, a field more or less, another version.
    const v2 = try encode(a, .{ .generation = 12, .analyzer_id = "analyzer-v2", .files = &.{} });
    try std.testing.expect(parsePointer(a, v2) == null);
    try std.testing.expect(parsePointer(a, "{\"state_version\":3,\"generation\":1,\"analyzer_id\":\"a\",\"state_file\":\"state-1.hybstate\",\"files\":[]}") == null);
    try std.testing.expect(parsePointer(a, "{\"state_version\":3,\"generation\":1,\"analyzer_id\":\"a\"}") == null);
    try std.testing.expect(parsePointer(a, "{\"state_version\":2,\"generation\":1,\"analyzer_id\":\"a\",\"state_file\":\"state-1.hybstate\"}") == null);
    // The version 2 parser never takes a pointer for a state.
    try std.testing.expectError(error.InvalidState, parse(a, encoded));
}

test "S4-T4: a pointer without a MANIFEST loads as null and still names its generation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try savePointer(io, tmp.dir, a, .{ .generation = 5, .analyzer_id = "analyzer-v2", .state_file = "state-5.hybstate" });
    try std.testing.expect((try load(a, io, tmp.dir)) == null);
    try std.testing.expectEqual(@as(?u64, 5), recordedGeneration(a, io, tmp.dir));
    try tmp.dir.writeFile(io, .{ .sub_path = state_file, .data = "not json" });
    try std.testing.expectEqual(@as(?u64, null), recordedGeneration(a, io, tmp.dir));
}

test "S4-T4: the binary state round-trips every field, and equals what the JSON form carries" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const roots = [_]Root{
        .{ .root_id = "r-6f1a", .label = "School", .kind = "icloud", .required_labels = &.{ "cloud-ok", "family" }, .retain_source = true, .origin = "host" },
        .{ .root_id = "r-legacy", .label = "", .kind = "local", .retain_source = false, .origin = "folder" },
    };
    const files = [_]Entry{
        .{ .root_id = "r-6f1a", .path = "week-07.md", .hash = "c" ** 64, .size = 4211, .mtime_ms = 1761900000000, .chunker = "md-section-v1", .chunks = 3, .moved_from = "week-7.md", .required_labels = &.{"family"} },
        .{ .root_id = "r-6f1a", .path = "week-08.md", .hash = "", .size = 3900, .status = .pending },
        .{ .root_id = "r-legacy", .path = "notes/\u{e9}t\u{e9}.txt", .hash = "0123456789abcdef" ** 4, .size = 0, .mtime_ms = -5, .chunker = "line-window-v1", .chunks = 0, .required_labels = &.{ "family", "z" } },
        .{ .root_id = "r-legacy", .path = "unknown-size.md", .hash = "", .size = null, .chunker = null, .chunks = 1 },
    };
    const state = State{ .generation = 17, .analyzer_id = "analyzer-v2", .roots = &roots, .files = &files };
    const binary = try encodeBinary(a, state);
    const back = try decodeBinary(a, binary);
    const json_back = try parseCommitted(a, try encode(a, state));
    for ([_]State{ back, json_back }) |got| {
        try std.testing.expectEqual(@as(u64, 17), got.generation);
        try std.testing.expectEqualStrings("analyzer-v2", got.analyzer_id);
        try std.testing.expectEqual(roots.len, got.roots.len);
        for (roots, got.roots) |want, have| {
            try std.testing.expectEqualStrings(want.root_id, have.root_id);
            try std.testing.expectEqualStrings(want.label, have.label);
            try std.testing.expectEqualStrings(want.kind, have.kind);
            try std.testing.expectEqualStrings(want.origin, have.origin);
            try std.testing.expectEqual(want.retain_source, have.retain_source);
            try std.testing.expectEqual(want.required_labels.len, have.required_labels.len);
            for (want.required_labels, have.required_labels) |x, y| try std.testing.expectEqualStrings(x, y);
        }
        try std.testing.expectEqual(files.len, got.files.len);
        for (files, got.files) |want, have| {
            try std.testing.expectEqualStrings(want.root_id, have.root_id);
            try std.testing.expectEqualStrings(want.path, have.path);
            try std.testing.expectEqualStrings(want.hash, have.hash);
            try std.testing.expectEqual(want.size, have.size);
            try std.testing.expectEqual(want.mtime_ms, have.mtime_ms);
            try std.testing.expectEqual(want.status, have.status);
            try std.testing.expectEqual(want.chunks, have.chunks);
            try std.testing.expectEqual(want.chunker == null, have.chunker == null);
            if (want.chunker) |c| try std.testing.expectEqualStrings(c, have.chunker.?);
            try std.testing.expectEqual(want.moved_from == null, have.moved_from == null);
            if (want.moved_from) |m| try std.testing.expectEqualStrings(m, have.moved_from.?);
            try std.testing.expectEqual(want.required_labels.len, have.required_labels.len);
            for (want.required_labels, have.required_labels) |x, y| try std.testing.expectEqualStrings(x, y);
        }
    }
    // Shared strings are stored once; a hash is 32 raw bytes.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, binary, "md-section-v1"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, binary, "r-6f1a"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, binary, "c" ** 64));
    // No roots: the legacy root, as the JSON form writes it.
    const legacy = try decodeBinary(a, try encodeBinary(a, .{ .generation = 1, .analyzer_id = "analyzer-v2", .files = &.{} }));
    try std.testing.expectEqual(@as(usize, 1), legacy.roots.len);
    try std.testing.expectEqualStrings(legacy_root_id, legacy.roots[0].root_id);
    // A hash that is not 64 hex digits is stored as unknown; upper case is
    // read back in lower case.
    const odd = [_]Entry{ .{ .path = "a.md", .hash = "not a hash", .size = 1 }, .{ .path = "b.md", .hash = "ABCDEF0123456789" ** 4, .size = 1 } };
    const odd_back = try decodeBinary(a, try encodeBinary(a, .{ .generation = 2, .analyzer_id = "analyzer-v2", .files = &odd }));
    try std.testing.expectEqualStrings("", odd_back.files[0].hash);
    try std.testing.expectEqualStrings("abcdef0123456789" ** 4, odd_back.files[1].hash);
    // Through the section: HYBSTA02, decoded by `decodeSection`.
    const section = try encodeSection(a, state);
    try std.testing.expectEqualStrings(state_section.magic_v2, section[0..8]);
    _ = try state_section.inspect(section);
    try std.testing.expectEqual(@as(usize, 4), (try decodeSection(a, section)).files.len);
    const json_section = try state_section.encode(a, try encode(a, state));
    try std.testing.expectEqual(@as(usize, 4), (try decodeSection(a, json_section)).files.len);
}

test "S4-T4: the binary state refuses every truncation, trailing bytes, unknown flags and out-of-range references" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const roots = [_]Root{.{ .root_id = "home", .label = "Home", .kind = "host", .required_labels = &.{"family"}, .retain_source = false, .origin = "host" }};
    const files = [_]Entry{
        .{ .root_id = "home", .path = "a.md", .hash = "a" ** 64, .size = 3, .mtime_ms = 9, .chunker = "md-section-v1", .chunks = 1, .moved_from = "old.md", .required_labels = &.{"own"} },
        .{ .root_id = "home", .path = "b.md", .hash = "", .size = 2, .status = .pending },
    };
    const binary = try encodeBinary(a, .{ .generation = 4, .analyzer_id = "analyzer-v2", .roots = &roots, .files = &files });
    _ = try decodeBinary(a, binary);
    for (0..binary.len) |cut| try std.testing.expectError(error.InvalidState, decodeBinary(a, binary[0..cut]));
    try std.testing.expectError(error.InvalidState, decodeBinary(a, try std.mem.concat(a, u8, &.{ binary, "x" })));
    // Every single-bit flip either decodes (a value changed: the section's
    // checksum is what catches that) or is refused; it never reads outside
    // the bytes or crashes.
    for (0..binary.len) |at| for (0..8) |bit| {
        const copy = try a.dupe(u8, binary);
        copy[at] ^= @as(u8, 1) << @intCast(bit);
        _ = decodeBinary(a, copy) catch |err| try std.testing.expectEqual(error.InvalidState, err);
    };
    const string_count = std.mem.readInt(u32, binary[20..24], .little);
    var bad = try a.dupe(u8, binary);
    std.mem.writeInt(u32, bad[0..4], 3, .little); // state_version
    try std.testing.expectError(error.InvalidState, decodeBinary(a, bad));
    bad = try a.dupe(u8, binary);
    std.mem.writeInt(u32, bad[16..20], string_count, .little); // analyzer out of range
    try std.testing.expectError(error.InvalidState, decodeBinary(a, bad));
    bad = try a.dupe(u8, binary);
    std.mem.writeInt(u32, bad[28..32], 0xffff_ffff, .little); // a file count the bytes cannot hold
    try std.testing.expectError(error.InvalidState, decodeBinary(a, bad));
}
