//! `apply_changes`: host-fed changes in the core (S3-T3 ruling 2, CAP-19
//! FR-20/FR-21, `docs/folder-knowledge-implementation.md` section 6,
//! `docs/incremental-indexing.md`). One request names roots and a batch of
//! changes (`add | change | remove | move | pending | remove_root`); the
//! engine validates the whole request, applies the changes in array order
//! per `(root_id, path)`, pairs equal-content removes and adds into moves,
//! and publishes exactly one new generation through the existing atomic path
//! (`lifecycle.publishLeasedKeepingWithSource`: documents, lexical and source
//! sections bound by the manifest), then writes `INDEX-STATE.json` v2.
//!
//! `index_folder` (`indexer.zig`) is a walk that builds a batch of `walk`
//! changes for its one `local` root and calls `applyBatch`, so one code path
//! writes every generation.
//!
//! Whole-request refusals publish nothing and leave every file untouched:
//! `invalid_argument` for a malformed request (unknown field, a forged
//! `principal_labels`, an unsafe path, a bad root, content fields that are
//! not exactly one strict `content_base64` or one confined `file`), a stale
//! `expect_generation` (`"stale: generation is M"`, checked before anything
//! else), a `file` outside its declared local root, under a symlink, or with
//! file reads disabled; `capacity` for more than 10,000 changes or more than
//! `max_total_bytes` of content. Per-change outcomes are reported and the
//! rest of the batch is published: `rejected` (`hash_mismatch`,
//! `size_mismatch`, `invalid_utf8`, `move_source_unknown`, `root_removed`,
//! `path_collides_with_root`), `too_large` (the file's chunks are dropped,
//! S1-T4), `unreadable` and `budget_exhausted` (its previous chunks are kept).
const std = @import("std");
const chunker = @import("chunker.zig");
const engine_module = @import("engine.zig");
const generation_alloc = @import("generation_alloc.zig");
const hybrid = @import("hybrid.zig");
const incremental_state = @import("incremental_state.zig");
const indexer = @import("indexer.zig");
const lexical_segment = @import("lexical_segment.zig");
const lifecycle = @import("lifecycle.zig");
const manifest = @import("manifest.zig");
const postings = @import("postings.zig");
const publication = @import("publication.zig");
const scope = @import("scope.zig");
const segment = @import("segment.zig");
const source = @import("source.zig");

pub const max_changes: usize = 10_000;
pub const default_max_file_bytes: u64 = 10 * 1024 * 1024;
pub const default_max_total_bytes: u64 = 512 * 1024 * 1024;
pub const max_path_bytes: usize = 4096;
pub const max_root_id_bytes: usize = 64;
pub const max_labels: usize = 64;
pub const max_label_bytes: usize = 256;

pub const Op = enum { add, change, remove, move, pending, remove_root };

pub const Content = union(enum) {
    none,
    /// Decoded `content_base64`.
    bytes: []const u8,
    /// An absolute path under the change's declared `local` root.
    file: []const u8,
    /// `index_folder`'s walk: a path relative to the walked folder (trusted:
    /// it came from the engine's own directory walk).
    walk: struct { dir: std.Io.Dir, sub_path: []const u8 },
};

pub const Change = struct {
    op: Op,
    root_id: []const u8,
    path: []const u8 = "",
    moved_from: ?[]const u8 = null,
    size: ?u64 = null,
    mtime_ms: ?i64 = null,
    /// Lowercase hex, when the host supplied one.
    sha256: ?[64]u8 = null,
    content: Content = .none,
    required_labels: []const []const u8 = &.{},
};

pub const RootDecl = struct {
    root_id: []const u8,
    label: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    required_labels: ?[]const []const u8 = null,
    retain_source: ?bool = null,
    /// The absolute folder of a `local` root, required for `file` changes.
    path: ?[]const u8 = null,
};

pub const Batch = struct {
    expect_generation: ?u64 = null,
    roots: []const RootDecl = &.{},
    changes: []const Change = &.{},
};

pub const Options = struct {
    analyzer: indexer.AnalyzerId = .v2,
    max_chars: usize = chunker.default_max_chars,
    overlap_lines: usize = chunker.default_overlap_lines,
    max_file_bytes: u64 = default_max_file_bytes,
    max_total_bytes: u64 = default_max_total_bytes,
    /// `file` changes are refused unless the engine was opened with file
    /// reads enabled (`--allow-file-reads`, section 6).
    allow_file_reads: bool = false,
    keep_generations: ?usize = null,
    /// `origin` written for roots this request declares.
    origin: []const u8 = "host",
    /// `index_folder`'s walk sets the next four.
    /// `.reject`: content over `max_total_bytes` refuses the request
    /// (section 6). `.exhaust`: files past the budget are left for a later
    /// run and reported `budget_exhausted` (S1-T5).
    budget: enum { reject, exhaust } = .reject,
    detect_renames: bool = true,
    /// The batch names every file of this root: a file of it that no
    /// change names is removed (`index_folder`'s walk).
    complete_root: ?[]const u8 = null,
    /// Ignore the current generation and state (a full rebuild).
    fresh: bool = false,
    generation: ?u64 = null,
    /// Test hook (ruling 4, crash recovery): fail after the manifest is
    /// published and before `INDEX-STATE.json` is written.
    fail_after_publish: bool = false,
};

pub const PathRef = struct { root_id: []const u8, path: []const u8 };
pub const Rejected = struct { root_id: []const u8, path: []const u8, reason: []const u8 };
pub const Conflict = struct { root_id: []const u8, path: []const u8, replaced: Op, by: Op };
pub const MovePair = struct { from: []const u8, to: []const u8 };
pub const AmbiguousMove = struct {
    root_id: []const u8,
    sha256: []const u8,
    from: []const []const u8,
    to: []const []const u8,
    pairs: []const MovePair,
};

pub const Report = struct {
    generation: u64,
    analyzer_id: []const u8,
    added: usize = 0,
    changed: usize = 0,
    removed: usize = 0,
    moved: usize = 0,
    pending: usize = 0,
    unchanged: usize = 0,
    too_large_paths: []const PathRef = &.{},
    unreadable_paths: []const PathRef = &.{},
    budget_exhausted_paths: []const PathRef = &.{},
    rejected: []const Rejected = &.{},
    conflicts: []const Conflict = &.{},
    ambiguous_moves: []const AmbiguousMove = &.{},
    roots_removed: usize = 0,
    bytes_read: u64 = 0,
    ms: u64 = 0,
    documents: usize = 0,
    terms: usize = 0,
    postings: usize = 0,
    pruned_files: usize = 0,
    prune_failures: usize = 0,
    recovered: ?[]const u8 = null,
};

pub const Outcome = union(enum) {
    ok: Report,
    failed: source.Failure,
};

pub const ParseResult = union(enum) {
    ok: Batch,
    failed: source.Failure,
};

fn failure(allocator: std.mem.Allocator, code: source.Code, comptime format: []const u8, args: anytype) !source.Failure {
    return .{ .code = code, .message = try std.fmt.allocPrint(allocator, format, args) };
}

// ------------------------------------------------------------ validation ---

pub fn validRootId(id: []const u8) bool {
    if (id.len == 0 or id.len > max_root_id_bytes) return false;
    if (std.mem.eql(u8, id, ".") or std.mem.eql(u8, id, "..")) return false;
    for (id) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.')) return false;
    }
    return true;
}

/// Section 5: root-relative POSIX, no `..` (nor `.` or empty component), no
/// leading or trailing `/`, no NUL, no line break, valid UTF-8, bounded.
pub fn validRelativePath(path: []const u8) bool {
    if (path.len == 0 or path.len > max_path_bytes) return false;
    if (!std.unicode.utf8ValidateSlice(path)) return false;
    if (std.mem.indexOfAny(u8, path, "\x00\r\n") != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

fn validLabels(labels: []const []const u8) bool {
    if (labels.len > max_labels) return false;
    for (labels, 0..) |label, index| {
        if (label.len == 0 or label.len > max_label_bytes or std.mem.indexOfAny(u8, label, "\x00\r\n") != null) return false;
        if (!std.unicode.utf8ValidateSlice(label)) return false;
        for (labels[0..index]) |earlier| if (std.mem.eql(u8, earlier, label)) return false;
    }
    return true;
}

fn validKind(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "local") or std.mem.eql(u8, kind, "icloud") or std.mem.eql(u8, kind, "host");
}

/// Section 4's per-kind default: retained for `host` and `icloud` roots, not
/// for `local` roots the engine may re-open.
pub fn defaultRetain(kind: []const u8) bool {
    return !std.mem.eql(u8, kind, "local");
}

// --------------------------------------------------------------- parsing ---

const request_fields = [_][]const u8{ "expect_generation", "roots", "changes" };
const root_fields = [_][]const u8{ "root_id", "label", "kind", "required_labels", "retain_source", "path" };

fn fieldAllowed(name: []const u8, allowed: []const []const u8) bool {
    for (allowed) |candidate| if (std.mem.eql(u8, candidate, name)) return true;
    return false;
}

fn opFields(op: Op) []const []const u8 {
    return switch (op) {
        .add, .change => &.{ "op", "root_id", "path", "size", "mtime_ms", "sha256", "content_base64", "file", "required_labels" },
        .remove => &.{ "op", "root_id", "path" },
        .move => &.{ "op", "root_id", "path", "moved_from", "size", "mtime_ms" },
        .pending => &.{ "op", "root_id", "path", "size", "mtime_ms", "required_labels" },
        .remove_root => &.{ "op", "root_id" },
    };
}

fn checkFields(allocator: std.mem.Allocator, object: std.json.ObjectMap, allowed: []const []const u8, where: []const u8) !?source.Failure {
    var it = object.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (std.mem.eql(u8, name, "principal_labels")) {
            return try failure(allocator, .invalid_argument, "principal_labels are not accepted in {s}: the scope comes from the trusted caller", .{where});
        }
        if (!fieldAllowed(name, allowed)) return try failure(allocator, .invalid_argument, "unknown field in {s}: {s}", .{ where, name });
    }
    return null;
}

fn keep(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    return allocator.dupe(u8, text);
}

fn stringValue(value: ?std.json.Value) ?[]const u8 {
    const v = value orelse return null;
    return if (v == .string) v.string else null;
}

fn parseLabelArray(allocator: std.mem.Allocator, value: std.json.Value) !?[]const []const u8 {
    if (value != .array) return null;
    const labels = try allocator.alloc([]const u8, value.array.items.len);
    for (value.array.items, labels) |item, *label| {
        if (item != .string) return null;
        label.* = try keep(allocator, item.string);
    }
    if (!validLabels(labels)) return null;
    return labels;
}

fn parseHex(text: []const u8) ?[64]u8 {
    if (text.len != 64) return null;
    var out: [64]u8 = undefined;
    for (text, &out) |byte, *slot| {
        slot.* = switch (byte) {
            '0'...'9', 'a'...'f' => byte,
            'A'...'F' => byte + 32,
            else => return null,
        };
    }
    return out;
}

/// Strict base64 (RFC 4648 standard alphabet, padded, no whitespace,
/// canonical trailing bits): the input must equal the encoding of what it
/// decodes to.
pub fn decodeStrictBase64(allocator: std.mem.Allocator, text: []const u8) !?[]u8 {
    const decoder = std.base64.standard.Decoder;
    if (text.len % 4 != 0) return null;
    const size = decoder.calcSizeForSlice(text) catch return null;
    const out = try allocator.alloc(u8, size);
    decoder.decode(out, text) catch {
        allocator.free(out);
        return null;
    };
    const again = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(size));
    defer allocator.free(again);
    if (!std.mem.eql(u8, std.base64.standard.Encoder.encode(again, out), text)) {
        allocator.free(out);
        return null;
    }
    return out;
}

/// The decoded size of a strict base64 string of this length, for the batch
/// cap check before anything is decoded (an upper bound; exact when padded).
fn decodedSizeBound(text: []const u8) u64 {
    return std.base64.standard.Decoder.calcSizeForSlice(text) catch (text.len / 4) * 3;
}

/// Parse a request (section 6). A JSON syntax error fails at once; every
/// other refusal is returned through `Parsed.deferred` so that the caller
/// can check `expect_generation` first.
pub const Parsed = struct {
    batch: Batch,
    deferred: ?source.Failure = null,
};

pub const ParseOutcome = union(enum) {
    ok: Parsed,
    failed: source.Failure,
};

pub fn parseRequest(allocator: std.mem.Allocator, request_json: []const u8, options: Options) !ParseOutcome {
    // The JSON tree lives in its own arena, released before the batch is
    // applied: every string the batch keeps is copied out (`keep`) and the
    // content is decoded into `allocator` (NFR-12's memory bound).
    var tree_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer tree_arena.deinit();
    const value = std.json.parseFromSliceLeaky(std.json.Value, tree_arena.allocator(), request_json, .{ .duplicate_field_behavior = .@"error" }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failed = try failure(allocator, .invalid_argument, "request is not valid JSON: {s}", .{@errorName(err)}) },
    };
    if (value != .object) return .{ .failed = try failure(allocator, .invalid_argument, "request must be a JSON object", .{}) };
    var parsed = Parsed{ .batch = .{} };
    const object = value.object;
    if (object.get("expect_generation")) |g| {
        switch (g) {
            .integer => |n| if (n >= 0) {
                parsed.batch.expect_generation = @intCast(n);
            } else {
                return .{ .failed = try failure(allocator, .invalid_argument, "expect_generation must be a non-negative integer", .{}) };
            },
            .null => {},
            else => return .{ .failed = try failure(allocator, .invalid_argument, "expect_generation must be a non-negative integer", .{}) },
        }
    }
    parsed.deferred = try parseBody(allocator, object, options, &parsed.batch);
    return .{ .ok = parsed };
}

fn parseBody(allocator: std.mem.Allocator, object: std.json.ObjectMap, options: Options, batch: *Batch) !?source.Failure {
    if (try checkFields(allocator, object, &request_fields, "the request")) |f| return f;
    const changes_value = object.get("changes") orelse return try failure(allocator, .invalid_argument, "changes is required", .{});
    if (changes_value != .array) return try failure(allocator, .invalid_argument, "changes must be an array", .{});
    if (changes_value.array.items.len > max_changes) {
        return try failure(allocator, .capacity, "{d} changes is over the {d}-change batch cap", .{ changes_value.array.items.len, max_changes });
    }

    var roots = std.ArrayList(RootDecl).empty;
    if (object.get("roots")) |roots_value| {
        if (roots_value != .array) return try failure(allocator, .invalid_argument, "roots must be an array", .{});
        for (roots_value.array.items, 0..) |item, index| {
            if (item != .object) return try failure(allocator, .invalid_argument, "roots[{d}] must be an object", .{index});
            if (try checkFields(allocator, item.object, &root_fields, "a root")) |f| return f;
            const id = stringValue(item.object.get("root_id")) orelse return try failure(allocator, .invalid_argument, "roots[{d}].root_id is required", .{index});
            if (!validRootId(id)) return try failure(allocator, .invalid_argument, "invalid root_id: {s}", .{id});
            if (scope.isLegacy(id)) return try failure(allocator, .invalid_argument, "root_id {s} is reserved for index_folder", .{id});
            var decl = RootDecl{ .root_id = try keep(allocator, id) };
            if (item.object.get("label")) |v| {
                const text = stringValue(v) orelse return try failure(allocator, .invalid_argument, "roots[{d}].label must be a string", .{index});
                if (text.len == 0 or text.len > max_label_bytes or std.mem.indexOfAny(u8, text, "\x00\r\n") != null)
                    return try failure(allocator, .invalid_argument, "invalid label for root {s}", .{id});
                decl.label = try keep(allocator, text);
            }
            if (item.object.get("kind")) |v| {
                const text = stringValue(v) orelse "";
                if (!validKind(text)) return try failure(allocator, .invalid_argument, "kind of root {s} must be local, icloud or host", .{id});
                decl.kind = try keep(allocator, text);
            }
            if (item.object.get("required_labels")) |v| {
                decl.required_labels = (try parseLabelArray(allocator, v)) orelse
                    return try failure(allocator, .invalid_argument, "invalid required_labels for root {s}", .{id});
            }
            if (item.object.get("retain_source")) |v| {
                if (v != .bool) return try failure(allocator, .invalid_argument, "retain_source of root {s} must be a boolean", .{id});
                decl.retain_source = v.bool;
            }
            if (item.object.get("path")) |v| {
                const text = stringValue(v) orelse return try failure(allocator, .invalid_argument, "path of root {s} must be a string", .{id});
                if (!validAbsolutePath(text)) return try failure(allocator, .invalid_argument, "path of root {s} must be an absolute path without . or .. components", .{id});
                decl.path = try keep(allocator, text);
            }
            for (roots.items) |earlier| if (std.mem.eql(u8, earlier.root_id, id))
                return try failure(allocator, .invalid_argument, "root {s} is declared twice", .{id});
            try roots.append(allocator, decl);
        }
    }
    batch.roots = try roots.toOwnedSlice(allocator);

    var total: u64 = 0;
    const changes = try allocator.alloc(Change, changes_value.array.items.len);
    for (changes_value.array.items, changes, 0..) |item, *change, index| {
        if (item != .object) return try failure(allocator, .invalid_argument, "changes[{d}] must be an object", .{index});
        const o = item.object;
        const op_text = stringValue(o.get("op")) orelse return try failure(allocator, .invalid_argument, "changes[{d}].op is required", .{index});
        const op = std.meta.stringToEnum(Op, op_text) orelse return try failure(allocator, .invalid_argument, "changes[{d}].op is not one of add, change, remove, move, pending, remove_root: {s}", .{ index, op_text });
        if (try checkFields(allocator, o, opFields(op), "a change")) |f| return f;
        const root_id = stringValue(o.get("root_id")) orelse return try failure(allocator, .invalid_argument, "changes[{d}].root_id is required", .{index});
        if (!validRootId(root_id)) return try failure(allocator, .invalid_argument, "invalid root_id: {s}", .{root_id});
        change.* = .{ .op = op, .root_id = try keep(allocator, root_id) };
        if (op != .remove_root) {
            const path = stringValue(o.get("path")) orelse return try failure(allocator, .invalid_argument, "changes[{d}].path is required", .{index});
            if (!validRelativePath(path)) return try failure(allocator, .invalid_argument, "changes[{d}].path is not a safe root-relative path", .{index});
            change.path = try keep(allocator, path);
        }
        if (o.get("size")) |v| {
            if (v != .integer or v.integer < 0) return try failure(allocator, .invalid_argument, "changes[{d}].size must be a non-negative integer", .{index});
            change.size = @intCast(v.integer);
        }
        if (o.get("mtime_ms")) |v| switch (v) {
            .integer => |n| change.mtime_ms = n,
            .null => {},
            else => return try failure(allocator, .invalid_argument, "changes[{d}].mtime_ms must be an integer", .{index}),
        };
        if (o.get("required_labels")) |v| {
            change.required_labels = (try parseLabelArray(allocator, v)) orelse
                return try failure(allocator, .invalid_argument, "changes[{d}].required_labels is invalid", .{index});
        }
        switch (op) {
            .move => {
                const from = stringValue(o.get("moved_from")) orelse return try failure(allocator, .invalid_argument, "changes[{d}].moved_from is required", .{index});
                if (!validRelativePath(from)) return try failure(allocator, .invalid_argument, "changes[{d}].moved_from is not a safe root-relative path", .{index});
                if (std.mem.eql(u8, from, change.path)) return try failure(allocator, .invalid_argument, "changes[{d}] moves a path onto itself", .{index});
                change.moved_from = try keep(allocator, from);
            },
            .add, .change => {
                const has_content = o.get("content_base64") != null;
                const has_file = o.get("file") != null;
                if (has_content == has_file) return try failure(allocator, .invalid_argument, "changes[{d}] needs exactly one of content_base64 or file", .{index});
                if (o.get("sha256")) |v| {
                    const text = stringValue(v) orelse "";
                    change.sha256 = parseHex(text) orelse return try failure(allocator, .invalid_argument, "changes[{d}].sha256 must be 64 hex digits", .{index});
                }
                if (has_content) {
                    const text = stringValue(o.get("content_base64")) orelse return try failure(allocator, .invalid_argument, "changes[{d}].content_base64 must be a string", .{index});
                    const bound = decodedSizeBound(text);
                    // A file over max_file_bytes is not decoded: it is reported too_large.
                    if (bound <= options.max_file_bytes) {
                        total += bound;
                        if (total > options.max_total_bytes) {
                            return try failure(allocator, .capacity, "content over the {d}-byte batch cap", .{options.max_total_bytes});
                        }
                    }
                    const decoded = (try decodeStrictBase64(allocator, text)) orelse
                        return try failure(allocator, .invalid_argument, "changes[{d}].content_base64 is not strict base64", .{index});
                    change.content = .{ .bytes = decoded };
                } else {
                    if (!options.allow_file_reads) return try failure(allocator, .invalid_argument, "changes[{d}] uses file, but file reads are not enabled", .{index});
                    const text = stringValue(o.get("file")) orelse return try failure(allocator, .invalid_argument, "changes[{d}].file must be a string", .{index});
                    if (!validAbsolutePath(text)) return try failure(allocator, .invalid_argument, "changes[{d}].file must be an absolute path without . or .. components", .{index});
                    if (change.sha256 == null) return try failure(allocator, .invalid_argument, "changes[{d}].sha256 is required with file", .{index});
                    change.content = .{ .file = try keep(allocator, text) };
                }
            },
            else => {},
        }
    }
    batch.changes = changes;
    return null;
}

fn validAbsolutePath(path: []const u8) bool {
    if (path.len < 2 or path[0] != '/' or path.len > max_path_bytes) return false;
    if (std.mem.indexOfAny(u8, path, "\x00\r\n") != null) return false;
    var parts = std.mem.splitScalar(u8, path[1..], '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

// ----------------------------------------------------------- the working table ---

const Cause = enum { removed, too_large, moved, root };

const File = struct {
    root_id: []const u8,
    rel: []const u8,
    record: []const u8,
    status: incremental_state.Status,
    hash: []const u8,
    size: ?u64,
    mtime_ms: ?i64,
    labels: []const []const u8,
    chunker: ?[]const u8,
    /// Set by a move in this batch: the root-relative source path.
    moved_from: ?[]const u8 = null,
    /// `moved_from` as the state recorded it (kept while the file is not
    /// changed again).
    recorded_moved_from: ?[]const u8 = null,
    /// The previous generation's record path whose chunks (and retained
    /// bytes) this file carries; null when it has none to carry.
    prev_record: ?[]const u8,
    /// Bytes to chunk afresh (an add/change whose content changed).
    fresh: ?[]const u8 = null,
    /// Bytes read this run for a file whose content did not change, kept as
    /// the retained source.
    read: ?[]const u8 = null,
    /// The change in this batch set it pending.
    pending_set: bool = false,
    /// Carried because its change could not be applied (unreadable, budget).
    carried_after_failure: bool = false,
    /// Came from an add/change (rename-detection candidate when new).
    from_content: bool = false,
};

const Initial = struct { status: incremental_state.Status, hash: []const u8, root_id: []const u8, rel: []const u8 };

const WorkRoot = struct {
    entry: manifest.RootEntry,
    local_path: ?[]const u8 = null,
    declared: bool = false,
};

const Work = struct {
    allocator: std.mem.Allocator,
    roots: std.ArrayList(WorkRoot) = .empty,
    files: std.StringHashMapUnmanaged(File) = .empty,
    initial: std.StringHashMapUnmanaged(Initial) = .empty,
    gone: std.StringHashMapUnmanaged(Cause) = .empty,
    touched: std.StringHashMapUnmanaged(Op) = .empty,
    removed_roots: std.StringHashMapUnmanaged(void) = .empty,

    fn rootIndex(work: *const Work, root_id: []const u8) ?usize {
        for (work.roots.items, 0..) |root, index| if (std.mem.eql(u8, root.entry.root_id, root_id)) return index;
        return null;
    }

    fn rootLabels(work: *const Work, root_id: []const u8) []const []const u8 {
        const index = work.rootIndex(root_id) orelse return &.{};
        return work.roots.items[index].entry.required_labels;
    }

    fn hasLegacy(work: *const Work) bool {
        return work.rootIndex(scope.legacy_root_id) != null;
    }

    /// A legacy path whose first component is another root's id would make
    /// record paths ambiguous (`scope.zig`).
    fn legacyCollides(work: *const Work, rel: []const u8) bool {
        const slash = std.mem.indexOfScalar(u8, rel, '/') orelse return false;
        const first = rel[0..slash];
        for (work.roots.items) |root| {
            if (!scope.isLegacy(root.entry.root_id) and std.mem.eql(u8, root.entry.root_id, first)) return true;
        }
        return false;
    }
};

fn hashHex(content: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn nowNs(io: std.Io) u64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

/// Parse and apply a request in `dir` (an index directory). See the file
/// comment for the refusals. `allocator` should be an arena.
pub fn applyChanges(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, request_json: []const u8, options: Options) !Outcome {
    const parsed = switch (try parseRequest(allocator, request_json, options)) {
        .ok => |p| p,
        .failed => |f| return .{ .failed = f },
    };
    return applyParsed(allocator, io, dir, parsed, options);
}

/// Apply an already parsed batch (`index_folder`'s walk has no deferred
/// refusal).
pub fn applyBatch(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, batch: Batch, options: Options) !Outcome {
    return applyParsed(allocator, io, dir, .{ .batch = batch }, options);
}

fn applyParsed(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, parsed: Parsed, options: Options) !Outcome {
    const started = nowNs(io);
    if (options.keep_generations) |count| if (count == 0) return error.InvalidKeepGenerations;
    // One writer: the lease is held from the generation check through the
    // publication, so no other writer can publish in between.
    var lease = (try lifecycle.tryAcquireWriter(dir, io)) orelse return error.WriterBusy;
    defer lease.release(io);

    const current = try generation_alloc.currentGeneration(allocator, io, dir);
    if (parsed.batch.expect_generation) |expected| {
        if (expected != current) return .{ .failed = try failure(allocator, .invalid_argument, "stale: generation is {d}", .{current}) };
    }
    if (parsed.deferred) |f| return .{ .failed = f };
    const batch = parsed.batch;

    // --- the previous generation --------------------------------------
    var recovered: ?[]const u8 = null;
    var previous_engine: ?engine_module.Engine = null;
    var previous_meta: ?manifest.Meta = null;
    var previous_source: ?source.Section = null;
    var previous_state: ?incremental_state.State = null;
    if (!options.fresh) {
        const opened_previous: ?Previous = openPrevious(allocator, io, dir) catch |err| switch (err) {
            error.FileNotFound, error.AccessDenied, error.InputOutput => blk: {
                const manifest_present = if (dir.statFile(io, publication.current_manifest_file, .{})) |_| true else |_| false;
                if (!manifest_present) {
                    const state_present = if (dir.statFile(io, incremental_state.state_file, .{})) |_| true else |_| false;
                    if (state_present) recovered = "missing_manifest";
                } else recovered = "missing_section";
                break :blk null;
            },
            else => return err,
        };
        if (opened_previous) |opened| {
            previous_engine = opened.engine;
            previous_source = opened.source;
            if (opened.metadata.meta.len != 0) previous_meta = try manifest.parseMeta(allocator, opened.metadata.meta);
        }
        if (previous_engine) |prev| {
            if (!std.mem.eql(u8, prev.analyzer_id, options.analyzer.label())) return error.AnalyzerMismatch;
            // INDEX-STATE.json is trusted only when it describes this very
            // generation; after a crash between the manifest and the state
            // write it names the one before, and the table is rebuilt from
            // the generation itself.
            if (incremental_state.load(allocator, io, dir) catch null) |state| {
                if (state.generation == prev.generation and std.mem.eql(u8, state.analyzer_id, prev.analyzer_id)) previous_state = state;
            }
        }
    }

    var work = Work{ .allocator = allocator };
    var previous_docs = std.StringHashMapUnmanaged(std.ArrayList(usize)).empty;
    if (previous_engine) |prev| {
        try loadPrevious(allocator, &work, prev, previous_meta, previous_source, previous_state, &previous_docs);
    }

    // --- roots this request declares ----------------------------------
    for (batch.roots) |decl| {
        const kind = decl.kind;
        if (work.rootIndex(decl.root_id)) |index| {
            const root = &work.roots.items[index];
            if (decl.label) |v| root.entry.label = v;
            if (kind) |v| root.entry.kind = v;
            if (decl.required_labels) |v| root.entry.required_labels = v;
            if (decl.retain_source) |v| root.entry.retain_source = v;
            root.local_path = decl.path;
            root.declared = true;
        } else {
            const k = kind orelse return .{ .failed = try failure(allocator, .invalid_argument, "new root {s} needs a kind", .{decl.root_id}) };
            if (work.hasLegacy() and !scope.isLegacy(decl.root_id)) {
                var it = work.files.iterator();
                while (it.next()) |entry| {
                    const file = entry.value_ptr.*;
                    if (scope.isLegacy(file.root_id) and std.mem.startsWith(u8, file.rel, decl.root_id) and
                        file.rel.len > decl.root_id.len and file.rel[decl.root_id.len] == '/')
                    {
                        return .{ .failed = try failure(allocator, .invalid_argument, "root_id {s} collides with a folder path of root {s}", .{ decl.root_id, scope.legacy_root_id }) };
                    }
                }
            }
            try work.roots.append(allocator, .{
                .entry = .{
                    .root_id = decl.root_id,
                    .label = decl.label orelse decl.root_id,
                    .kind = k,
                    .required_labels = decl.required_labels orelse &.{},
                    .retain_source = decl.retain_source orelse defaultRetain(k),
                    .origin = options.origin,
                },
                .local_path = decl.path,
                .declared = true,
            });
        }
        const root = work.roots.items[work.rootIndex(decl.root_id).?];
        if (decl.path != null and !std.mem.eql(u8, root.entry.kind, "local")) {
            return .{ .failed = try failure(allocator, .invalid_argument, "root {s} has a path but is not kind local", .{decl.root_id}) };
        }
    }

    // --- whole-request checks against the roots, before any read ---------
    var file_sizes = try allocator.alloc(?u64, batch.changes.len);
    @memset(file_sizes, null);
    var planned: u64 = 0;
    for (batch.changes, 0..) |change, index| {
        // `remove_root` of a root the index does not hold removes nothing.
        const known = change.op == .remove_root or work.rootIndex(change.root_id) != null or rootDeclaredLater(batch, change.root_id);
        if (!known) return .{ .failed = try failure(allocator, .invalid_argument, "changes[{d}] names an undeclared root: {s}", .{ index, change.root_id }) };
        switch (change.content) {
            .file => |abs| {
                const root_index = work.rootIndex(change.root_id).?;
                const root = work.roots.items[root_index];
                if (!std.mem.eql(u8, root.entry.kind, "local") or root.local_path == null) {
                    return .{ .failed = try failure(allocator, .invalid_argument, "changes[{d}].file needs root {s} declared in this request with kind local and a path", .{ index, change.root_id }) };
                }
                switch (try confineFile(allocator, io, root.local_path.?, abs)) {
                    .outside => return .{ .failed = try failure(allocator, .invalid_argument, "changes[{d}].file is outside root {s}", .{ index, change.root_id }) },
                    .symlink => return .{ .failed = try failure(allocator, .invalid_argument, "changes[{d}].file passes through a symlink (refused)", .{index}) },
                    .missing => {},
                    .size => |size| {
                        file_sizes[index] = size;
                        if (size <= options.max_file_bytes) planned += size;
                    },
                }
            },
            .bytes => |bytes| if (bytes.len <= options.max_file_bytes) {
                planned += bytes.len;
            },
            else => {},
        }
    }
    if (options.budget == .reject and planned > options.max_total_bytes) {
        return .{ .failed = try failure(allocator, .capacity, "{d} bytes of content is over the {d}-byte batch cap", .{ planned, options.max_total_bytes }) };
    }

    // --- apply in array order -----------------------------------------
    var too_large = std.ArrayList(PathRef).empty;
    var unreadable = std.ArrayList(PathRef).empty;
    var exhausted = std.ArrayList(PathRef).empty;
    var rejected = std.ArrayList(Rejected).empty;
    var conflicts = std.ArrayList(Conflict).empty;
    var roots_removed: usize = 0;
    var bytes_read: u64 = 0;
    var budget_spent: u64 = 0;
    var over_budget = false;

    for (batch.changes, 0..) |change, change_index| {
        if (change.op == .remove_root) {
            if (work.rootIndex(change.root_id)) |root_index| {
                var doomed = std.ArrayList([]const u8).empty;
                var it = work.files.iterator();
                while (it.next()) |entry| if (std.mem.eql(u8, entry.value_ptr.root_id, change.root_id)) try doomed.append(allocator, entry.key_ptr.*);
                for (doomed.items) |record| {
                    _ = work.files.remove(record);
                    try work.gone.put(allocator, record, .root);
                }
                _ = work.roots.orderedRemove(root_index);
                try work.removed_roots.put(allocator, change.root_id, {});
                roots_removed += 1;
            }
            continue;
        }
        // A root removed earlier in this batch comes back only if this
        // request declares it.
        if (work.rootIndex(change.root_id) == null) {
            const decl = declaredRoot(batch, change.root_id) orelse {
                try rejected.append(allocator, .{ .root_id = change.root_id, .path = change.path, .reason = "root_removed" });
                continue;
            };
            try work.roots.append(allocator, .{
                .entry = .{
                    .root_id = decl.root_id,
                    .label = decl.label orelse decl.root_id,
                    .kind = decl.kind orelse "host",
                    .required_labels = decl.required_labels orelse &.{},
                    .retain_source = decl.retain_source orelse defaultRetain(decl.kind orelse "host"),
                    .origin = options.origin,
                },
                .local_path = decl.path,
                .declared = true,
            });
        }
        const record = try scope.recordPath(allocator, change.root_id, change.path);
        if (scope.isLegacy(change.root_id) and work.legacyCollides(change.path) and change.op != .remove) {
            if (change.content == .walk) {
                try unreadable.append(allocator, .{ .root_id = change.root_id, .path = change.path });
            } else {
                try rejected.append(allocator, .{ .root_id = change.root_id, .path = change.path, .reason = "path_collides_with_root" });
            }
            continue;
        }
        try noteTouch(allocator, &work, &conflicts, change.root_id, change.path, record, change.op);

        switch (change.op) {
            .remove => {
                if (work.files.fetchRemove(record)) |_| try work.gone.put(allocator, record, .removed);
            },
            .pending => {
                const previous = work.files.get(record);
                try work.files.put(allocator, record, .{
                    .root_id = change.root_id,
                    .rel = change.path,
                    .record = record,
                    .status = .pending,
                    .hash = "",
                    .size = change.size,
                    .mtime_ms = change.mtime_ms,
                    .labels = change.required_labels,
                    .chunker = null,
                    .prev_record = null,
                    .pending_set = true,
                });
                _ = previous;
                _ = work.gone.remove(record);
            },
            .move => {
                const from_record = try scope.recordPath(allocator, change.root_id, change.moved_from.?);
                try noteTouch(allocator, &work, &conflicts, change.root_id, change.moved_from.?, from_record, change.op);
                const moving = work.files.fetchRemove(from_record) orelse {
                    try rejected.append(allocator, .{ .root_id = change.root_id, .path = change.path, .reason = "move_source_unknown" });
                    continue;
                };
                try work.gone.put(allocator, from_record, .moved);
                var file = moving.value;
                file.rel = change.path;
                file.record = record;
                file.moved_from = change.moved_from.?;
                if (change.mtime_ms) |m| file.mtime_ms = m;
                try work.files.put(allocator, record, file);
                _ = work.gone.remove(record);
            },
            .add, .change => {
                const existing = work.files.get(record);
                // Read or take the bytes.
                var bytes: []const u8 = undefined;
                switch (change.content) {
                    .bytes => |b| {
                        if (b.len > options.max_file_bytes) {
                            try tombstone(allocator, &work, &too_large, change, record);
                            continue;
                        }
                        bytes = b;
                    },
                    .file, .walk => {
                        const size = switch (change.content) {
                            .file => file_sizes[change_index],
                            .walk => |w| blk: {
                                const stat = w.dir.statFile(io, w.sub_path, .{}) catch break :blk null;
                                break :blk stat.size;
                            },
                            else => unreachable,
                        };
                        const known_size = size orelse {
                            try unreadable.append(allocator, .{ .root_id = change.root_id, .path = change.path });
                            markCarried(&work, record);
                            continue;
                        };
                        if (known_size > options.max_file_bytes) {
                            try tombstone(allocator, &work, &too_large, change, record);
                            continue;
                        }
                        if (options.budget == .exhaust and (over_budget or budget_spent + known_size > options.max_total_bytes)) {
                            over_budget = true;
                            try exhausted.append(allocator, .{ .root_id = change.root_id, .path = change.path });
                            markCarried(&work, record);
                            continue;
                        }
                        const length = std.math.cast(usize, known_size) orelse {
                            try unreadable.append(allocator, .{ .root_id = change.root_id, .path = change.path });
                            markCarried(&work, record);
                            continue;
                        };
                        const read = readContent(allocator, io, change.content, work, change.root_id, length) catch null;
                        const got = read orelse {
                            try unreadable.append(allocator, .{ .root_id = change.root_id, .path = change.path });
                            markCarried(&work, record);
                            continue;
                        };
                        if (!std.unicode.utf8ValidateSlice(got)) {
                            try unreadable.append(allocator, .{ .root_id = change.root_id, .path = change.path });
                            markCarried(&work, record);
                            continue;
                        }
                        budget_spent += got.len;
                        bytes = got;
                    },
                    .none => unreachable,
                }
                bytes_read += bytes.len;
                if (change.content == .bytes and !std.unicode.utf8ValidateSlice(bytes)) {
                    try rejected.append(allocator, .{ .root_id = change.root_id, .path = change.path, .reason = "invalid_utf8" });
                    continue;
                }
                const digest = hashHex(bytes);
                if (change.sha256) |claimed| if (!std.mem.eql(u8, &claimed, &digest)) {
                    try rejected.append(allocator, .{ .root_id = change.root_id, .path = change.path, .reason = "hash_mismatch" });
                    continue;
                };
                if (change.size) |claimed| if (claimed != bytes.len) {
                    try rejected.append(allocator, .{ .root_id = change.root_id, .path = change.path, .reason = "size_mismatch" });
                    continue;
                };
                const hash = try allocator.dupe(u8, &digest);
                const kind = chunker.kindForPath(change.path);
                var file = File{
                    .root_id = change.root_id,
                    .rel = change.path,
                    .record = record,
                    .status = .indexed,
                    .hash = hash,
                    .size = bytes.len,
                    .mtime_ms = change.mtime_ms,
                    .labels = change.required_labels,
                    .chunker = kind.id(),
                    .prev_record = null,
                    .from_content = true,
                };
                if (existing) |old| {
                    if (old.status == .indexed and old.prev_record != null and old.fresh == null and
                        std.mem.eql(u8, old.hash, hash) and old.chunker != null and std.mem.eql(u8, old.chunker.?, kind.id()))
                    {
                        // Same bytes, same chunker: carried, not re-chunked.
                        file.prev_record = old.prev_record;
                        file.moved_from = old.moved_from;
                        file.recorded_moved_from = old.recorded_moved_from;
                        file.read = bytes;
                        file.from_content = false;
                        try work.files.put(allocator, record, file);
                        _ = work.gone.remove(record);
                        continue;
                    }
                }
                file.fresh = bytes;
                try work.files.put(allocator, record, file);
                _ = work.gone.remove(record);
            },
            .remove_root => unreachable,
        }
    }

    if (options.complete_root) |complete| {
        var doomed = std.ArrayList([]const u8).empty;
        var it = work.files.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.root_id, complete) and !work.touched.contains(entry.key_ptr.*))
                try doomed.append(allocator, entry.key_ptr.*);
        }
        for (doomed.items) |record| {
            _ = work.files.remove(record);
            try work.gone.put(allocator, record, .removed);
        }
    }

    // --- rename detection (section 6, FR-21) ---------------------------
    var ambiguous = std.ArrayList(AmbiguousMove).empty;
    if (options.detect_renames) try detectRenames(allocator, &work, &previous_docs, previous_engine, previous_meta, &ambiguous);

    // --- counts -------------------------------------------------------
    var report = Report{ .generation = 0, .analyzer_id = options.analyzer.label() };
    {
        var it = work.files.iterator();
        while (it.next()) |entry| {
            const file = entry.value_ptr.*;
            // `index_folder` reports on its own root only (S1 fields).
            if (options.complete_root) |only| if (!std.mem.eql(u8, file.root_id, only)) continue;
            const initial = work.initial.get(file.record);
            if (file.moved_from != null) {
                report.moved += 1;
            } else if (file.status == .pending) {
                if (file.pending_set) report.pending += 1;
            } else if (initial == null or initial.?.status != .indexed) {
                report.added += 1;
            } else if (file.fresh != null) {
                report.changed += 1;
            } else if (!file.carried_after_failure) {
                report.unchanged += 1;
            }
        }
        var gone = work.gone.iterator();
        while (gone.next()) |entry| {
            if (entry.value_ptr.* != .removed) continue;
            if (work.files.contains(entry.key_ptr.*)) continue;
            if (work.initial.get(entry.key_ptr.*)) |_| report.removed += 1;
        }
    }

    // --- build the generation -----------------------------------------
    const generation = options.generation orelse try generation_alloc.nextFreeGeneration(allocator, io, dir);
    const built = buildGeneration(allocator, &work, previous_engine, previous_meta, previous_source, &previous_docs, options, generation) catch |err| switch (err) {
        error.TooManyLabels => return .{ .failed = try failure(allocator, .invalid_argument, "a file would require more than {d} labels (its root's and its own)", .{max_labels}) },
        else => return err,
    };
    const prune = try lifecycle.publishLeasedKeepingWithSource(allocator, dir, io, built.manifest, built.documents, built.lexical, built.source, options.keep_generations);
    if (options.fail_after_publish) return error.SimulatedCrash;
    // Only after the generation is published (`docs/publication-recovery.md`).
    try incremental_state.save(io, dir, allocator, .{
        .generation = generation,
        .analyzer_id = options.analyzer.label(),
        .roots = built.state_roots,
        .files = built.state_files,
    });

    report.generation = generation;
    report.too_large_paths = try too_large.toOwnedSlice(allocator);
    report.unreadable_paths = try unreadable.toOwnedSlice(allocator);
    report.budget_exhausted_paths = try exhausted.toOwnedSlice(allocator);
    report.rejected = try rejected.toOwnedSlice(allocator);
    report.conflicts = try conflicts.toOwnedSlice(allocator);
    report.ambiguous_moves = try ambiguous.toOwnedSlice(allocator);
    report.roots_removed = roots_removed;
    report.bytes_read = bytes_read;
    report.documents = built.document_count;
    report.terms = built.term_count;
    report.postings = built.posting_count;
    report.pruned_files = prune.deleted;
    report.prune_failures = prune.failed;
    report.recovered = recovered;
    report.ms = (nowNs(io) - started) / std.time.ns_per_ms;
    return .{ .ok = report };
}

const Previous = struct {
    engine: engine_module.Engine,
    metadata: manifest.Manifest,
    source: ?source.Section,
};

fn readWhole(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8) ![]u8 {
    const stat = try dir.statFile(io, name, .{});
    const size = std.math.cast(usize, stat.size) orelse return error.IndexTooLarge;
    const buffer = try allocator.alloc(u8, size);
    return dir.readFile(io, name, buffer);
}

/// The current generation, read once: each section's checksum is computed
/// once (by `Engine.open`'s validation and the decoders, and by the source
/// section's `openIndexed`), where `snapshot_open.open` plus `openSource`
/// recompute the document and lexical checksums three times and the source
/// checksum twice. A writer reads the whole previous generation on every
/// call, so this is NFR-12's one-changed-file cost. Same errors as
/// `snapshot_open.open` for a lost file (`error.FileNotFound`: a missing
/// section, healed by a full re-index).
fn openPrevious(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !Previous {
    const manifest_encoded = try readWhole(allocator, io, dir, publication.current_manifest_file);
    const metadata = try manifest.decode(manifest_encoded);
    const documents_encoded = try readWhole(allocator, io, dir, metadata.documents_file);
    const lexical_encoded = try readWhole(allocator, io, dir, metadata.lexical_file);
    var section: ?source.Section = null;
    if (metadata.hasSource()) {
        const bytes = try readWhole(allocator, io, dir, metadata.source_file);
        if (bytes.len != metadata.source_bytes) return error.SourceSectionSizeMismatch;
        const opened = try source.openIndexed(allocator, bytes);
        if (opened.checksum != metadata.source_checksum) return error.SourceSectionChecksumMismatch;
        section = opened;
    }
    // The checks of `manifest.validateSnapshot`, with the document section's
    // checksum computed once (by `segment.decode`, against the stored value
    // that must equal the manifest's).
    if (documents_encoded.len != metadata.documents_bytes) return error.DocumentSectionSizeMismatch;
    if (lexical_encoded.len != metadata.lexical_bytes) return error.LexicalSectionSizeMismatch;
    if (storedChecksum(documents_encoded, segment.header_length) != metadata.documents_checksum) return error.DocumentSectionChecksumMismatch;
    const lexical_header = try lexical_segment.inspect(lexical_encoded);
    if (lexical_header.checksum != metadata.lexical_checksum) return error.LexicalSectionChecksumMismatch;
    if (lexical_header.term_count != metadata.term_count) return error.TermCountMismatch;
    if (lexical_header.posting_count != metadata.posting_count) return error.PostingCountMismatch;
    const vector_count = std.math.mul(usize, metadata.document_count, metadata.vector_dimensions) catch return error.IndexTooLarge;
    const documents = try segment.decode(documents_encoded, try allocator.alloc(hybrid.Document, metadata.document_count), try allocator.alloc(f32, vector_count));
    const lexical_index = try lexical_segment.decode(lexical_encoded, try allocator.alloc(postings.TermEntry, metadata.term_count), try allocator.alloc(postings.Posting, metadata.posting_count), try allocator.alloc(u32, metadata.document_count));
    if (documents.len != metadata.document_count or lexical_index.document_lengths.len != documents.len) return error.DocumentCountMismatch;
    var labeled = false;
    for (documents) |document| if (document.required_labels.len != 0) {
        labeled = true;
    };
    return .{ .engine = .{
        .generation = metadata.generation,
        .analyzer_id = metadata.analyzer_id,
        .embedding_model_id = metadata.embedding_model_id,
        .vector_dimensions = metadata.vector_dimensions,
        .documents = documents,
        .lexical_index = lexical_index,
        .labeled_documents = labeled,
    }, .metadata = metadata, .source = section };
}

/// The checksum a section stores as the last eight bytes of its header
/// (`segment-format-v4.md`, `source-section-v1.md`); the decoder that reads
/// the section verifies it against the bytes.
fn storedChecksum(encoded: []const u8, header_length: usize) u64 {
    if (encoded.len < header_length) return 0;
    return std.mem.readInt(u64, encoded[header_length - 8 ..][0..8], .little);
}

fn rootDeclaredLater(batch: Batch, root_id: []const u8) bool {
    return declaredRoot(batch, root_id) != null;
}

fn declaredRoot(batch: Batch, root_id: []const u8) ?RootDecl {
    for (batch.roots) |decl| if (std.mem.eql(u8, decl.root_id, root_id)) return decl;
    return null;
}

fn noteTouch(allocator: std.mem.Allocator, work: *Work, conflicts: *std.ArrayList(Conflict), root_id: []const u8, path: []const u8, record: []const u8, op: Op) !void {
    const gop = try work.touched.getOrPut(allocator, record);
    if (gop.found_existing) try conflicts.append(allocator, .{ .root_id = root_id, .path = path, .replaced = gop.value_ptr.*, .by = op });
    gop.value_ptr.* = op;
}

fn tombstone(allocator: std.mem.Allocator, work: *Work, too_large: *std.ArrayList(PathRef), change: Change, record: []const u8) !void {
    try too_large.append(allocator, .{ .root_id = change.root_id, .path = change.path });
    if (work.files.fetchRemove(record)) |_| try work.gone.put(allocator, record, .too_large);
}

fn markCarried(work: *Work, record: []const u8) void {
    if (work.files.getPtr(record)) |file| file.carried_after_failure = true;
}

fn readContent(allocator: std.mem.Allocator, io: std.Io, content: Content, work: Work, root_id: []const u8, length: usize) !?[]const u8 {
    _ = work;
    _ = root_id;
    const buffer = try allocator.alloc(u8, length);
    switch (content) {
        .walk => |w| return try w.dir.readFile(io, w.sub_path, buffer),
        .file => |abs| {
            var file = try std.Io.Dir.openFileAbsolute(io, abs, .{ .follow_symlinks = false });
            defer file.close(io);
            const stat = try file.stat(io);
            if (stat.size != length) return null;
            var reader = file.reader(io, &.{});
            try reader.interface.readSliceAll(buffer);
            return buffer;
        },
        else => unreachable,
    }
}

const Confinement = union(enum) { outside, symlink, missing, size: u64 };

/// Whether absolute `file` lies under `root_path` with no symlink below the
/// root (each component is checked without following links), and its size.
fn confineFile(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8, file: []const u8) !Confinement {
    const base = std.mem.trimEnd(u8, root_path, "/");
    if (file.len <= base.len + 1 or !std.mem.startsWith(u8, file, base) or file[base.len] != '/') return .outside;
    const rest = file[base.len + 1 ..];
    if (!validRelativePath(rest)) return .outside;
    var root_dir = std.Io.Dir.openDirAbsolute(io, if (base.len == 0) "/" else base, .{}) catch return .missing;
    defer root_dir.close(io);
    var end: usize = 0;
    while (end <= rest.len) {
        const next = std.mem.indexOfScalarPos(u8, rest, end, '/') orelse rest.len;
        const prefix = rest[0..next];
        const stat = root_dir.statFile(io, prefix, .{ .follow_symlinks = false }) catch return .missing;
        if (stat.kind == .sym_link) return .symlink;
        if (next == rest.len) {
            if (stat.kind != .file) return .missing;
            return .{ .size = stat.size };
        }
        if (stat.kind != .directory) return .missing;
        end = next + 1;
    }
    _ = allocator;
    return .missing;
}

// ------------------------------------------------- the previous generation ---

fn loadPrevious(
    allocator: std.mem.Allocator,
    work: *Work,
    prev: engine_module.Engine,
    meta: ?manifest.Meta,
    section: ?source.Section,
    state: ?incremental_state.State,
    previous_docs: *std.StringHashMapUnmanaged(std.ArrayList(usize)),
) !void {
    const roots: []const manifest.RootEntry = if (meta) |m| m.roots else &scope.legacy_roots;
    for (roots) |root| try work.roots.append(allocator, .{ .entry = root });
    for (prev.documents, 0..) |document, index| {
        const gop = try previous_docs.getOrPut(allocator, document.path);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(allocator, index);
    }
    const meta_chunkers: ?manifest.Meta = meta;

    if (state) |s| {
        for (s.files) |entry| {
            if (work.rootIndex(entry.root_id) == null) continue;
            const record = try scope.recordPath(allocator, entry.root_id, entry.path);
            const has_docs = previous_docs.contains(record);
            try work.files.put(allocator, record, .{
                .root_id = entry.root_id,
                .rel = entry.path,
                .record = record,
                .status = entry.status,
                .hash = entry.hash,
                .size = entry.size,
                .mtime_ms = entry.mtime_ms,
                .labels = entry.required_labels,
                .chunker = entry.chunker orelse if (has_docs) chunkerOf(prev, meta_chunkers, previous_docs.get(record).?.items) else null,
                .prev_record = if (entry.status == .indexed) record else null,
                .recorded_moved_from = entry.moved_from,
            });
        }
    } else if (meta) |m| {
        for (m.pending) |entry| {
            if (work.rootIndex(entry.root_id) == null) continue;
            const record = try scope.recordPath(allocator, entry.root_id, entry.path);
            try work.files.put(allocator, record, .{ .root_id = entry.root_id, .rel = entry.path, .record = record, .status = .pending, .hash = "", .size = entry.size, .mtime_ms = null, .labels = entry.required_labels, .chunker = null, .prev_record = null });
        }
        for (m.unchunked) |entry| {
            if (work.rootIndex(entry.root_id) == null) continue;
            const record = try scope.recordPath(allocator, entry.root_id, entry.path);
            const retained = if (section) |sec| sec.find(record) else null;
            try work.files.put(allocator, record, .{
                .root_id = entry.root_id,
                .rel = entry.path,
                .record = record,
                .status = .indexed,
                .hash = if (retained) |r| try allocator.dupe(u8, &std.fmt.bytesToHex(r.sha256, .lower)) else "",
                .size = entry.size,
                .mtime_ms = null,
                .labels = entry.required_labels,
                .chunker = chunker.kindForPath(entry.path).id(),
                .prev_record = record,
            });
        }
    }
    // Records the state does not name (no trusted state, or a state that
    // missed them): rebuilt from the generation (the source section's hash
    // when the bytes were retained).
    var it = previous_docs.iterator();
    while (it.next()) |entry| {
        const record = entry.key_ptr.*;
        if (work.files.contains(record)) continue;
        const root_index = scope.rootOfPath(roots, record) orelse continue;
        const root = roots[root_index];
        const first = prev.documents[entry.value_ptr.items[0]];
        const retained = if (section) |sec| sec.find(record) else null;
        try work.files.put(allocator, record, .{
            .root_id = root.root_id,
            .rel = scope.relativePath(root, record),
            .record = record,
            .status = .indexed,
            .hash = if (retained) |r| try allocator.dupe(u8, &std.fmt.bytesToHex(r.sha256, .lower)) else "",
            .size = if (retained) |r| r.bytes.len else null,
            .mtime_ms = null,
            .labels = try scope.fileLabels(allocator, first.required_labels, root.required_labels),
            .chunker = chunkerOf(prev, meta_chunkers, entry.value_ptr.items),
            .prev_record = record,
        });
    }
    var files = work.files.iterator();
    while (files.next()) |entry| {
        const file = entry.value_ptr.*;
        try work.initial.put(allocator, file.record, .{ .status = file.status, .hash = file.hash, .root_id = file.root_id, .rel = file.rel });
    }
}

/// The chunker id that made a file's previous chunks (a v1 manifest has no
/// meta: `line-window-v1`), or null when they disagree.
fn chunkerOf(prev: engine_module.Engine, meta: ?manifest.Meta, indices: []const usize) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (indices) |index| {
        const chunker_index = prev.documents[index].chunker_index;
        const id = if (meta) |m| (m.chunkerId(chunker_index) orelse return null) else chunker.chunker_id;
        if (found) |f| {
            if (!std.mem.eql(u8, f, id)) return null;
        } else found = id;
    }
    return found;
}

/// Where a document of the new generation gets its terms: a fresh chunk's
/// tokens, or a carried document's index in the previous generation.
const DocSource = union(enum) {
    fresh: []const []const u8,
    carried: u32,
};

const TermCount = struct { term: u32, frequency: u32 };

/// The lexical index of the new generation (S1-T3: rebuilt whole every
/// generation). A fresh document is counted exactly as `lexical_build.build`
/// counts it (a per-document hash map, terms numbered on first sight, so a
/// generation of fresh documents only is byte-identical to that builder's);
/// a carried document's (term, frequency) pairs are read straight from the
/// previous generation's postings, so an unchanged file costs no hashing of
/// its tokens and no token list (NFR-12's one-changed-file cost). Postings
/// are filled in document order, so each term's list is strictly increasing.
fn buildLexical(allocator: std.mem.Allocator, previous: ?postings.Index, sources: []const DocSource) !postings.Index {
    if (sources.len > std.math.maxInt(u32)) return error.DocumentCountOverflow;
    // The previous postings transposed to per-document (term, frequency) lists.
    var old_offsets: []usize = &.{};
    var old_pairs: []TermCount = &.{};
    var previous_to_new: []u32 = &.{};
    if (previous) |index| {
        const document_count = index.document_lengths.len;
        old_offsets = try allocator.alloc(usize, document_count + 1);
        @memset(old_offsets, 0);
        for (index.postings) |posting| old_offsets[posting.document_index + 1] += 1;
        for (1..old_offsets.len) |i| old_offsets[i] += old_offsets[i - 1];
        old_pairs = try allocator.alloc(TermCount, index.postings.len);
        const fill = try allocator.alloc(usize, document_count);
        defer allocator.free(fill);
        @memcpy(fill, old_offsets[0..document_count]);
        for (index.terms, 0..) |entry, term_index| {
            for (index.postings[entry.postings_start .. entry.postings_start + entry.postings_length]) |posting| {
                old_pairs[fill[posting.document_index]] = .{ .term = @intCast(term_index), .frequency = posting.term_frequency };
                fill[posting.document_index] += 1;
            }
        }
        previous_to_new = try allocator.alloc(u32, index.terms.len);
        @memset(previous_to_new, std.math.maxInt(u32));
    }

    var terms = std.ArrayList(postings.TermEntry).empty;
    var term_ids = std.StringHashMap(usize).init(allocator);
    defer term_ids.deinit();
    var pairs = std.ArrayList(TermCount).empty;
    const pair_start = try allocator.alloc(usize, sources.len + 1);
    const document_lengths = try allocator.alloc(u32, sources.len);
    var total_length: usize = 0;

    for (sources, 0..) |item, document_index| {
        pair_start[document_index] = pairs.items.len;
        switch (item) {
            .carried => |old| {
                const index = previous.?;
                document_lengths[document_index] = index.document_lengths[old];
                for (old_pairs[old_offsets[old]..old_offsets[old + 1]]) |pair| {
                    var id = previous_to_new[pair.term];
                    if (id == std.math.maxInt(u32)) {
                        const gop = try term_ids.getOrPut(index.terms[pair.term].term);
                        if (!gop.found_existing) {
                            try terms.append(allocator, .{ .term = index.terms[pair.term].term, .document_frequency = 0, .postings_start = 0, .postings_length = 0 });
                            gop.value_ptr.* = terms.items.len - 1;
                        }
                        id = @intCast(gop.value_ptr.*);
                        previous_to_new[pair.term] = id;
                    }
                    terms.items[id].document_frequency += 1;
                    try pairs.append(allocator, .{ .term = id, .frequency = pair.frequency });
                }
            },
            .fresh => |tokens| {
                document_lengths[document_index] = @intCast(tokens.len);
                var counts = std.StringHashMap(u32).init(allocator);
                defer counts.deinit();
                for (tokens) |token| {
                    const gop = try counts.getOrPut(token);
                    if (gop.found_existing) gop.value_ptr.* += 1 else gop.value_ptr.* = 1;
                }
                var it = counts.iterator();
                while (it.next()) |entry| {
                    const gop = try term_ids.getOrPut(entry.key_ptr.*);
                    if (!gop.found_existing) {
                        try terms.append(allocator, .{ .term = entry.key_ptr.*, .document_frequency = 0, .postings_start = 0, .postings_length = 0 });
                        gop.value_ptr.* = terms.items.len - 1;
                    }
                    const id: u32 = @intCast(gop.value_ptr.*);
                    terms.items[id].document_frequency += 1;
                    try pairs.append(allocator, .{ .term = id, .frequency = entry.value_ptr.* });
                }
            },
        }
        total_length += document_lengths[document_index];
    }
    pair_start[sources.len] = pairs.items.len;
    if (terms.items.len > std.math.maxInt(u32)) return error.TermCountOverflow;

    var start: usize = 0;
    for (terms.items) |*entry| {
        entry.postings_start = start;
        entry.postings_length = entry.document_frequency;
        start += entry.document_frequency;
    }
    const all_postings = try allocator.alloc(postings.Posting, start);
    const cursor = try allocator.alloc(usize, terms.items.len);
    defer allocator.free(cursor);
    for (terms.items, cursor) |entry, *slot| slot.* = entry.postings_start;
    for (0..sources.len) |document_index| {
        for (pairs.items[pair_start[document_index]..pair_start[document_index + 1]]) |pair| {
            all_postings[cursor[pair.term]] = .{ .document_index = @intCast(document_index), .term_frequency = pair.frequency };
            cursor[pair.term] += 1;
        }
    }
    const average: f32 = if (sources.len == 0) 0 else @as(f32, @floatFromInt(total_length)) / @as(f32, @floatFromInt(sources.len));
    return .{
        .terms = try terms.toOwnedSlice(allocator),
        .postings = all_postings,
        .document_lengths = document_lengths,
        .average_document_length = average,
    };
}

// -------------------------------------------------------- rename detection ---

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn detectRenames(
    allocator: std.mem.Allocator,
    work: *Work,
    previous_docs: *std.StringHashMapUnmanaged(std.ArrayList(usize)),
    prev: ?engine_module.Engine,
    meta: ?manifest.Meta,
    ambiguous: *std.ArrayList(AmbiguousMove),
) !void {
    _ = previous_docs;
    _ = prev;
    _ = meta;
    // Removed: indexed before, gone by a `remove` in this batch, hash known.
    // Added: absent (or not indexed) before, new content in this batch.
    const Key = struct { root_id: []const u8, hash: []const u8 };
    var removed = std.StringHashMapUnmanaged(std.ArrayList([]const u8)).empty;
    var added = std.StringHashMapUnmanaged(std.ArrayList([]const u8)).empty;
    var keys = std.ArrayList(Key).empty;
    var gone = work.gone.iterator();
    while (gone.next()) |entry| {
        if (entry.value_ptr.* != .removed or work.files.contains(entry.key_ptr.*)) continue;
        const initial = work.initial.get(entry.key_ptr.*) orelse continue;
        if (initial.status != .indexed or initial.hash.len == 0) continue;
        const key = try std.mem.concat(allocator, u8, &.{ initial.root_id, "\x00", initial.hash });
        const gop = try removed.getOrPut(allocator, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
            try keys.append(allocator, .{ .root_id = initial.root_id, .hash = initial.hash });
        }
        try gop.value_ptr.append(allocator, entry.key_ptr.*);
    }
    var files = work.files.iterator();
    while (files.next()) |entry| {
        const file = entry.value_ptr.*;
        if (!file.from_content or file.moved_from != null or file.status != .indexed) continue;
        if (work.initial.get(file.record)) |initial| if (initial.status == .indexed) continue;
        const key = try std.mem.concat(allocator, u8, &.{ file.root_id, "\x00", file.hash });
        const gop = try added.getOrPut(allocator, key);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(allocator, file.record);
    }
    std.mem.sort(Key, keys.items, {}, struct {
        fn lessThan(_: void, a: Key, b: Key) bool {
            const order = std.mem.order(u8, a.root_id, b.root_id);
            if (order != .eq) return order == .lt;
            return std.mem.order(u8, a.hash, b.hash) == .lt;
        }
    }.lessThan);
    for (keys.items) |key| {
        const joined = try std.mem.concat(allocator, u8, &.{ key.root_id, "\x00", key.hash });
        const from = removed.get(joined).?.items;
        const to_list = added.get(joined) orelse continue;
        const to = to_list.items;
        std.mem.sort([]const u8, from, {}, lessThanString);
        std.mem.sort([]const u8, to, {}, lessThanString);
        const count = @min(from.len, to.len);
        const pairs = try allocator.alloc(MovePair, count);
        for (0..count) |i| {
            const source_record = from[i];
            const target = work.files.getPtr(to[i]).?;
            const initial = work.initial.get(source_record).?;
            target.moved_from = initial.rel;
            target.from_content = false;
            // Copy the chunks (re-keyed) when the chunker is the same; a
            // different extension re-chunks the bytes it already has.
            if (chunker.kindForPath(initial.rel) == chunker.kindForPath(target.rel)) {
                target.prev_record = source_record;
                target.read = target.fresh;
                target.fresh = null;
            }
            try work.gone.put(allocator, source_record, .moved);
            pairs[i] = .{ .from = initial.rel, .to = target.rel };
        }
        if (from.len > 1 or to.len > 1) {
            const from_rel = try allocator.alloc([]const u8, from.len);
            for (from, from_rel) |record, *rel| rel.* = work.initial.get(record).?.rel;
            const to_rel = try allocator.alloc([]const u8, to.len);
            for (to, to_rel) |record, *rel| rel.* = work.files.get(record).?.rel;
            try ambiguous.append(allocator, .{ .root_id = key.root_id, .sha256 = key.hash, .from = from_rel, .to = to_rel, .pairs = pairs });
        }
    }
}

// --------------------------------------------------------- the generation ---

const Built = struct {
    manifest: []const u8,
    documents: []const u8,
    lexical: []const u8,
    source: ?[]const u8,
    state_roots: []const incremental_state.Root,
    state_files: []const incremental_state.Entry,
    document_count: usize,
    term_count: usize,
    posting_count: usize,
};

fn lessThanFileRecord(_: void, a: *const File, b: *const File) bool {
    return std.mem.order(u8, a.record, b.record) == .lt;
}

fn chunkerIndex(kind: chunker.Kind) u16 {
    return switch (kind) {
        .line_window => 0,
        .md_section => 1,
    };
}

fn buildGeneration(
    allocator: std.mem.Allocator,
    work: *Work,
    prev: ?engine_module.Engine,
    prev_meta: ?manifest.Meta,
    prev_source: ?source.Section,
    previous_docs: *std.StringHashMapUnmanaged(std.ArrayList(usize)),
    options: Options,
    generation: u64,
) !Built {
    // Sorted by record path; pointers, not the (large) structs, are sorted.
    var files = std.ArrayList(*const File).empty;
    var it = work.files.iterator();
    while (it.next()) |entry| try files.append(allocator, entry.value_ptr);
    std.mem.sort(*const File, files.items, {}, lessThanFileRecord);

    var documents = std.ArrayList(hybrid.Document).empty;
    var sources = std.ArrayList(DocSource).empty;
    var retained = std.ArrayList(source.InputFile).empty;
    var pending = std.ArrayList(manifest.PendingEntry).empty;
    var unchunked = std.ArrayList(manifest.PendingEntry).empty;
    var state_files = std.ArrayList(incremental_state.Entry).empty;
    var any_retain = false;
    for (work.roots.items) |root| if (root.entry.retain_source) {
        any_retain = true;
    };

    // Fresh chunks are tokenized in a scratch arena reset per chunk and their
    // tokens interned (one copy per distinct term), so the token lists the
    // lexical build needs hold slices, not a copy of every token.
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    var interned = std.StringHashMapUnmanaged(void).empty;

    for (files.items) |file_pointer| {
        const file = file_pointer.*;
        const root_index = work.rootIndex(file.root_id).?;
        const root = work.roots.items[root_index].entry;
        if (file.status == .pending) {
            try pending.append(allocator, .{ .root_id = file.root_id, .path = file.rel, .size = file.size, .required_labels = file.labels });
            try state_files.append(allocator, .{
                .root_id = file.root_id,
                .path = file.rel,
                .hash = "",
                .size = file.size,
                .mtime_ms = file.mtime_ms,
                .status = .pending,
                .moved_from = file.moved_from orelse file.recorded_moved_from,
                .required_labels = file.labels,
            });
            continue;
        }
        const labels = try scope.packLabels(allocator, root.required_labels, file.labels);
        // A record may require at most 64 labels (the principal side is
        // bounded to 64 too, `rpc.zig`): the root's and the file's together.
        if (std.mem.count(u8, labels, "\n") + 1 > max_labels and labels.len != 0) return error.TooManyLabels;
        // Bytes to retain: read this run, or the previous source section's.
        var bytes: ?[]const u8 = file.fresh orelse file.read;
        if (bytes == null) if (file.prev_record) |pr| if (prev_source) |section| if (section.find(pr)) |entry| {
            bytes = entry.bytes;
        };
        var source_doc_index: u32 = hybrid.no_source_doc;
        if (root.retain_source) if (bytes) |b| {
            source_doc_index = @intCast(retained.items.len);
            try retained.append(allocator, .{ .path = file.record, .bytes = b });
        };
        const first_document = documents.items.len;
        var chunker_id: ?[]const u8 = file.chunker;
        if (file.fresh) |content| {
            const kind = chunker.kindForPath(file.rel);
            chunker_id = kind.id();
            const spans = chunker.chunkForPath(allocator, file.rel, content, options.max_chars, options.overlap_lines) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => &.{},
            };
            for (spans) |span| {
                var id_hex: [20]u8 = undefined;
                chunker.chunkId(&id_hex, file.record, span.start_line, span.end_line, span.text);
                try documents.append(allocator, .{
                    .id = try allocator.dupe(u8, &id_hex),
                    .text = span.text,
                    .vector = &.{},
                    .path = file.record,
                    .start_line = span.start_line,
                    .end_line = span.end_line,
                    .required_labels = labels,
                    .chunker_index = chunkerIndex(kind),
                    .section_depth = span.section_depth,
                    .heading_line = span.heading_line,
                    .source_doc_index = source_doc_index,
                    .section_path = span.section_path,
                });
                _ = scratch.reset(.retain_capacity);
                const raw = try indexer.tokenize(scratch.allocator(), options.analyzer, span.text);
                const tokens = try allocator.alloc([]const u8, raw.len);
                for (raw, tokens) |token, *slot| {
                    const gop = try interned.getOrPut(allocator, token);
                    if (!gop.found_existing) gop.key_ptr.* = try allocator.dupe(u8, token);
                    slot.* = gop.key_ptr.*;
                }
                try sources.append(allocator, .{ .fresh = tokens });
            }
        } else if (file.prev_record) |pr| {
            if (prev) |engine| if (previous_docs.get(pr)) |indices| {
                const rekey = !std.mem.eql(u8, pr, file.record);
                for (indices.items) |old_index| {
                    var document = engine.documents[old_index];
                    if (rekey) {
                        var id_hex: [20]u8 = undefined;
                        chunker.chunkId(&id_hex, file.record, document.start_line, document.end_line, document.text);
                        document.id = try allocator.dupe(u8, &id_hex);
                        document.path = file.record;
                    }
                    // Chunker index: re-expressed in this generation's
                    // chunker table (line-window-v1 0, md-section-v1 1).
                    const id = if (prev_meta) |m| (m.chunkerId(document.chunker_index) orelse chunker.chunker_id) else chunker.chunker_id;
                    document.chunker_index = if (std.mem.eql(u8, id, chunker.Kind.md_section.id())) 1 else 0;
                    document.required_labels = labels;
                    document.source_doc_index = source_doc_index;
                    try documents.append(allocator, document);
                    try sources.append(allocator, .{ .carried = @intCast(old_index) });
                }
            };
        }
        const chunks = documents.items.len - first_document;
        if (chunks == 0) try unchunked.append(allocator, .{ .root_id = file.root_id, .path = file.rel, .size = file.size, .required_labels = file.labels });
        try state_files.append(allocator, .{
            .root_id = file.root_id,
            .path = file.rel,
            .hash = file.hash,
            .size = file.size,
            .mtime_ms = file.mtime_ms,
            .status = .indexed,
            .chunker = chunker_id,
            .chunks = @intCast(chunks),
            .moved_from = file.moved_from orelse file.recorded_moved_from,
            .required_labels = file.labels,
        });
    }

    const lexical_index = try buildLexical(allocator, if (prev) |engine| engine.lexical_index else null, sources.items);
    const documents_buffer = try allocator.alloc(u8, try segment.encodedLengthV4(documents.items));
    const documents_encoded = try segment.encodeV4(documents.items, documents_buffer);
    const lexical_buffer = try allocator.alloc(u8, try lexical_segment.encodedLength(lexical_index));
    const lexical_encoded = try lexical_segment.encode(lexical_index, lexical_buffer);
    const source_encoded: ?[]const u8 = if (any_retain) try source.encode(allocator, retained.items) else null;

    var uses_markdown = false;
    for (documents.items) |document| if (document.chunker_index == 1) {
        uses_markdown = true;
    };
    const all_chunkers = [_]manifest.ChunkerEntry{
        .{ .id = chunker.chunker_id, .max_chars = options.max_chars, .overlap_lines = options.overlap_lines },
        .{ .id = chunker.Kind.md_section.id(), .max_chars = options.max_chars, .overlap_lines = options.overlap_lines },
    };
    const meta_roots = try allocator.alloc(manifest.RootEntry, work.roots.items.len);
    const state_roots = try allocator.alloc(incremental_state.Root, work.roots.items.len);
    for (work.roots.items, meta_roots, state_roots) |root, *meta_root, *state_root| {
        meta_root.* = root.entry;
        state_root.* = .{
            .root_id = root.entry.root_id,
            .label = root.entry.label,
            .kind = root.entry.kind,
            .required_labels = root.entry.required_labels,
            .retain_source = root.entry.retain_source,
            .origin = root.entry.origin,
        };
    }
    const meta = try manifest.writeMetaPending(
        allocator,
        all_chunkers[0..if (uses_markdown) 2 else 1],
        meta_roots,
        pending.items,
        unchunked.items,
        if (source_encoded != null) source.version else 0,
    );
    const documents_file = try std.fmt.allocPrint(allocator, "documents-{d}.hybseg", .{generation});
    const lexical_file = try std.fmt.allocPrint(allocator, "lexical-{d}.hyblex", .{generation});
    const source_file = if (source_encoded != null) try std.fmt.allocPrint(allocator, "source-{d}.hybsrc", .{generation}) else "";
    // `manifest.createV2` without re-reading the sections: the encoders just
    // wrote each checksum into its header, and `publication.publishWithSource`
    // validates every one against the bytes before anything is linked.
    const metadata = manifest.Manifest{
        .format_version = manifest.version_v2,
        .generation = generation,
        .document_count = documents.items.len,
        .vector_dimensions = 0,
        .term_count = lexical_index.terms.len,
        .posting_count = lexical_index.postings.len,
        .documents_bytes = documents_encoded.len,
        .documents_checksum = storedChecksum(documents_encoded, segment.header_length),
        .lexical_bytes = lexical_encoded.len,
        .lexical_checksum = (try lexical_segment.inspect(lexical_encoded)).checksum,
        .analyzer_id = options.analyzer.label(),
        .embedding_model_id = "none",
        .documents_file = documents_file,
        .lexical_file = lexical_file,
        .source_file = source_file,
        .source_bytes = if (source_encoded) |bytes| bytes.len else 0,
        .source_checksum = if (source_encoded) |bytes| storedChecksum(bytes, source.header_length) else 0,
        .meta = meta,
    };
    const manifest_buffer = try allocator.alloc(u8, try manifest.encodedLength(metadata));
    const manifest_encoded = try manifest.encode(metadata, manifest_buffer);
    return .{
        .manifest = manifest_encoded,
        .documents = documents_encoded,
        .lexical = lexical_encoded,
        .source = source_encoded,
        .state_roots = state_roots,
        .state_files = try state_files.toOwnedSlice(allocator),
        .document_count = documents.items.len,
        .term_count = lexical_index.terms.len,
        .posting_count = lexical_index.postings.len,
    };
}

// ------------------------------------------------------------------ report ---

/// The section 6 report as JSON (paths as `{root_id, path}` objects).
pub fn writeReportJson(json: *std.json.Stringify, report: Report) !void {
    try json.beginObject();
    try json.objectField("generation");
    try json.write(report.generation);
    try json.objectField("analyzer_id");
    try json.write(report.analyzer_id);
    inline for (.{ "added", "changed", "removed", "moved", "pending", "unchanged" }) |name| {
        try json.objectField(name);
        try json.write(@field(report, name));
    }
    try json.objectField("too_large");
    try json.write(report.too_large_paths.len);
    try json.objectField("too_large_paths");
    try json.write(report.too_large_paths);
    try json.objectField("unreadable");
    try json.write(report.unreadable_paths.len);
    try json.objectField("unreadable_paths");
    try json.write(report.unreadable_paths);
    try json.objectField("rejected");
    try json.write(report.rejected);
    try json.objectField("conflicts");
    try json.write(report.conflicts);
    try json.objectField("ambiguous_moves");
    try json.write(report.ambiguous_moves);
    try json.objectField("roots_removed");
    try json.write(report.roots_removed);
    try json.objectField("budget_exhausted");
    try json.write(report.budget_exhausted_paths.len);
    try json.objectField("budget_exhausted_paths");
    try json.write(report.budget_exhausted_paths);
    try json.objectField("bytes_read");
    try json.write(report.bytes_read);
    try json.objectField("ms");
    try json.write(report.ms);
    try json.objectField("documents");
    try json.write(report.documents);
    try json.objectField("terms");
    try json.write(report.terms);
    try json.objectField("postings");
    try json.write(report.postings);
    if (report.recovered) |value| {
        try json.objectField("recovered");
        try json.write(value);
    }
    try json.endObject();
}
