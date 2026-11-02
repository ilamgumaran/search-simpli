//! The folder-knowledge operations as canonical JSON (S3-T4, CAP-19 FR-22,
//! `docs/folder-knowledge-implementation.md` sections 7 to 9): `find`,
//! `outline`, `read_span`, `list_files`, `roots`, the scoped `index_status`
//! and `evidence`, and `apply_changes`. The C ABI (`abi.zig`), the CLI
//! (`cli.zig`) and the RPC server (`rpc.zig`) all answer through these
//! functions, so a request gives byte-identical JSON on every surface (the
//! parity test in the Dart package compares them).
//!
//! **Requests** are JSON objects; an unknown field anywhere is refused
//! (`INVALID_ARGUMENT`). Every read operation takes an optional `roots`
//! (root ids; it narrows the caller's roots, it never widens them).
//! `principal_labels` is accepted only from a caller that is itself trusted
//! with the scope (`Caller.request_labels`: the C ABI, whose caller is the
//! host app, and the raw RPC service started without `--labels`), bounded as
//! the RPC service has always bounded it; elsewhere the scope's labels come
//! from the command line and a request that states them is refused.
//!
//! **Results** share one envelope (section 8):
//! `{"request":{…echo, defaults filled in…},"generation":N,"scope":{"roots":[…],"labels_applied":true},"warnings":[…], …}`
//! where `scope.roots` lists the roots the request could see (in the
//! generation's order) and `labels_applied` is always true (the scope's
//! labels, possibly none, filtered before any candidate). `index_status`
//! and `evidence` keep their v1 shapes and only add fields.
//!
//! **S3-T6:** CAP-13's three other operations, `search_knowledge`,
//! `read_chunk` and `list_sources`, moved here from `rpc.zig` (unchanged
//! JSON), so the RPC server and the MCP server (`mcp.zig`) answer every tool
//! through this file; `search_knowledge` items gain `root_id` and
//! `section_path`, and its result `truncated` and `pending_files`, when the
//! service has its scope data (every opened index). A refusal names its
//! reason ("Invalid params: <reason>" on the RPC server).
//!
//! Memory: everything comes from the caller's `allocator`, an arena released
//! after the result is written out.
const filename_field = @import("filename_field.zig");
const filename_response = @import("filename_response.zig");
const std = @import("std");
const apply = @import("apply.zig");
const engine_module = @import("engine.zig");
const find_module = @import("find.zig");
const hybrid = @import("hybrid.zig");
const query_report = @import("report.zig");
const scoring = @import("scoring.zig");
const scope = @import("scope.zig");
const service_module = @import("service.zig");
const source = @import("source.zig");

pub const Failure = source.Failure;
pub const Code = source.Code;

pub const Result = union(enum) {
    /// The canonical JSON (owned by the allocator passed in).
    ok: []const u8,
    failed: Failure,
};

/// At most this many root ids in a request's `roots`.
pub const max_named_roots: usize = 64;
/// The RPC service's long-standing bounds on `principal_labels`.
pub const max_principal_labels: usize = 64;
pub const max_label_bytes: usize = 256;
/// `list_files` paging.
pub const default_list_page_size: usize = 100;
pub const max_list_page_size: usize = 1000;
/// `evidence`: at most this many ids per call.
pub const max_evidence_ids: usize = 1000;

/// Who asks, and with which trusted scope.
pub const Caller = struct {
    /// The outer bound on roots (the server's `--roots`); null = every root.
    roots: ?[]const []const u8 = null,
    /// The trusted labels (the server's `--labels`).
    labels: []const []const u8 = &.{},
    /// Whether a request may state its own `principal_labels` (replacing
    /// `labels`): the C ABI, and the raw RPC service without `--labels`.
    request_labels: bool = false,
};

pub const Warning = struct { code: []const u8, message: []const u8 };

const Error = error{ Invalid, OutOfMemory };

/// Field-by-field reader of one request object; the first problem is kept
/// in `message` (an `INVALID_ARGUMENT`).
const Reader = struct {
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    message: []const u8 = "",

    fn fail(reader: *Reader, comptime format: []const u8, args: anytype) Error {
        reader.message = try std.fmt.allocPrint(reader.allocator, format, args);
        return error.Invalid;
    }

    fn only(reader: *Reader, allowed: []const []const u8) Error!void {
        var iterator = reader.object.iterator();
        while (iterator.next()) |entry| {
            const name = entry.key_ptr.*;
            for (allowed) |known| {
                if (std.mem.eql(u8, known, name)) break;
            } else return reader.fail("unknown field \"{s}\"", .{name});
        }
    }

    fn optionalString(reader: *Reader, name: []const u8) Error!?[]const u8 {
        const value = reader.object.get(name) orelse return null;
        return switch (value) {
            .null => null,
            .string => |text| text,
            else => reader.fail("{s} must be a string", .{name}),
        };
    }

    fn requiredString(reader: *Reader, name: []const u8) Error![]const u8 {
        if (reader.object.get(name) == null) return reader.fail("{s} is required", .{name});
        return (try reader.optionalString(name)) orelse reader.fail("{s} must be a string", .{name});
    }

    fn optionalInteger(reader: *Reader, name: []const u8) Error!?u64 {
        const value = reader.object.get(name) orelse return null;
        return switch (value) {
            .null => null,
            .integer => |number| if (number >= 0) @intCast(number) else reader.fail("{s} must be a non-negative integer", .{name}),
            else => reader.fail("{s} must be a non-negative integer", .{name}),
        };
    }

    /// An integer >= 1, `default` when absent (`null` is not absent).
    fn positiveInteger(reader: *Reader, name: []const u8, default: usize) Error!usize {
        const value = reader.object.get(name) orelse return default;
        return switch (value) {
            .integer => |number| if (number > 0) std.math.cast(usize, number) orelse reader.fail("{s} is too large", .{name}) else reader.fail("{s} must be a positive integer", .{name}),
            else => reader.fail("{s} must be a positive integer", .{name}),
        };
    }

    fn requiredInteger(reader: *Reader, name: []const u8) Error!u64 {
        if (reader.object.get(name) == null) return reader.fail("{s} is required", .{name});
        return (try reader.optionalInteger(name)) orelse reader.fail("{s} must be a non-negative integer", .{name});
    }

    fn stringList(reader: *Reader, name: []const u8, limit: usize) Error!?[]const []const u8 {
        const value = reader.object.get(name) orelse return null;
        const items = switch (value) {
            .null => return null,
            .array => |array| array.items,
            else => return reader.fail("{s} must be an array of strings", .{name}),
        };
        if (items.len > limit) return reader.fail("{s} holds more than {d} entries", .{ name, limit });
        const list = try reader.allocator.alloc([]const u8, items.len);
        for (items, list) |item, *slot| slot.* = switch (item) {
            .string => |text| text,
            else => return reader.fail("{s} must be an array of strings", .{name}),
        };
        return list;
    }

    /// The effective scope: `roots` narrows the caller's roots;
    /// `principal_labels` only from a caller trusted with them.
    fn scopeOf(reader: *Reader, caller: Caller) Error!scope.Request {
        const named = try reader.stringList("roots", max_named_roots);
        if (named) |ids| for (ids) |id| if (id.len == 0) return reader.fail("roots must not hold an empty id", .{});
        var labels = caller.labels;
        if (reader.object.get("principal_labels")) |value| {
            if (!caller.request_labels) return reader.fail("principal_labels comes from the trusted caller (the server's --labels), not from a request", .{});
            labels = try reader.labelList(value);
        }
        return .{ .roots = try effectiveRoots(reader.allocator, caller.roots, named), .principal_labels = labels };
    }

    fn labelList(reader: *Reader, value: std.json.Value) Error![]const []const u8 {
        const items = switch (value) {
            .null => return &.{},
            .array => |array| array.items,
            else => return reader.fail("principal_labels must be an array of strings", .{}),
        };
        if (items.len > max_principal_labels) return reader.fail("principal_labels holds more than {d} labels", .{max_principal_labels});
        const labels = try reader.allocator.alloc([]const u8, items.len);
        for (items, labels, 0..) |item, *slot, index| {
            const label = switch (item) {
                .string => |text| text,
                else => return reader.fail("principal_labels must be an array of strings", .{}),
            };
            if (label.len == 0 or label.len > max_label_bytes or std.mem.indexOfAny(u8, label, "\x00\r\n") != null)
                return reader.fail("a principal label must be 1..{d} bytes without NUL or line breaks", .{max_label_bytes});
            for (labels[0..index]) |earlier| if (std.mem.eql(u8, earlier, label)) return reader.fail("principal_labels repeats a label", .{});
            slot.* = label;
        }
        return labels;
    }

    fn failure(reader: Reader) Result {
        return .{ .failed = .{ .code = .invalid_argument, .message = reader.message } };
    }
};

/// The roots both `outer` and `named` allow, in `named`'s order (one of
/// them is set).
fn intersect(allocator: std.mem.Allocator, outer: ?[]const []const u8, named: ?[]const []const u8) ![]const []const u8 {
    const want = named orelse return outer.?;
    const bound = outer orelse return want;
    var kept = std.ArrayList([]const u8).empty;
    for (want) |id| {
        for (bound) |allowed| if (std.mem.eql(u8, allowed, id)) {
            try kept.append(allocator, id);
            break;
        };
    }
    return kept.items;
}

/// `intersect` with "no bound on either side" kept as null (every root).
fn effectiveRoots(allocator: std.mem.Allocator, outer: ?[]const []const u8, named: ?[]const []const u8) !?[]const []const u8 {
    if (outer == null and named == null) return null;
    return try intersect(allocator, outer, named);
}

/// Parse `text` as one JSON object for the readers below (`NULL`/empty is
/// `{}`). Owned by `allocator`.
pub fn parseObject(allocator: std.mem.Allocator, text: []const u8) !union(enum) { ok: std.json.ObjectMap, failed: Failure } {
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return .{ .ok = .empty };
    const value = std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failed = .{ .code = .invalid_argument, .message = "the request is not valid JSON" } },
    };
    return switch (value) {
        .object => |object| .{ .ok = object },
        else => .{ .failed = .{ .code = .invalid_argument, .message = "the request must be a JSON object" } },
    };
}

fn newReader(allocator: std.mem.Allocator, params: std.json.ObjectMap) Reader {
    return .{ .allocator = allocator, .object = params };
}

fn scopedOf(service: service_module.Service) service_module.ScopedService {
    return .{ .service = service };
}

// ------------------------------------------------------------ envelope ---

fn writeRoots(json: *std.json.Stringify, roots: ?[]const []const u8) !void {
    if (roots) |ids| try json.write(ids) else try json.write(null);
}

/// `generation`, `scope` and `warnings`, after the request echo.
fn writeCommon(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    service: service_module.Service,
    request: scope.Request,
    warnings: []const Warning,
) !void {
    try json.objectField("generation");
    try json.write(service.engine.generation);
    try json.objectField("scope");
    try json.beginObject();
    try json.objectField("roots");
    try json.beginArray();
    const resolved = try service_module.resolve(service, allocator, request);
    defer resolved.deinit(allocator);
    for (resolved.folder.roots, resolved.allowed) |root, allowed| if (allowed) try json.write(root.root_id);
    try json.endArray();
    try json.objectField("labels_applied");
    try json.write(true);
    try json.endObject();
    try json.objectField("warnings");
    try json.beginArray();
    for (warnings) |warning| try json.write(warning);
    try json.endArray();
}

// ---------------------------------------------------------------- find ---

const find_fields = [_][]const u8{ "query", "mode", "roots", "path_prefix", "page_size", "cursor", "principal_labels" };

/// `find` (section 8): `{query, mode?, roots?, path_prefix?, page_size?, cursor?}`.
pub fn find(allocator: std.mem.Allocator, service: service_module.Service, params: std.json.ObjectMap, caller: Caller) !Result {
    var reader = newReader(allocator, params);
    const parsed = parseFind(&reader, caller) catch |err| switch (err) {
        error.Invalid => return reader.failure(),
        error.OutOfMemory => return error.OutOfMemory,
    };
    const answer = switch (try scopedOf(service).find(allocator, parsed.request, parsed.scope)) {
        .ok => |answer| answer,
        .failed => |failure| return .{ .failed = failure },
    };
    var out: std.Io.Writer.Allocating = .init(allocator);
    var json = std.json.Stringify{ .writer = &out.writer };
    try json.beginObject();
    try json.objectField("request");
    try json.beginObject();
    try json.objectField("query");
    try json.write(answer.query);
    try json.objectField("mode");
    try json.write(answer.mode.label());
    try json.objectField("roots");
    try writeRoots(&json, parsed.named);
    try json.objectField("path_prefix");
    try json.write(answer.path_prefix);
    try json.objectField("page_size");
    try json.write(answer.page_size);
    try json.objectField("cursor");
    try json.write(answer.cursor);
    try json.endObject();
    try writeCommon(allocator, &json, service, parsed.scope, &.{});
    try find_module.writeFields(&json, answer);
    try json.endObject();
    return .{ .ok = out.written() };
}

const ParsedFind = struct { request: find_module.Request, scope: scope.Request, named: ?[]const []const u8 };

fn parseFind(reader: *Reader, caller: Caller) Error!ParsedFind {
    try reader.only(&find_fields);
    const query = try reader.requiredString("query");
    const mode_text = try reader.optionalString("mode");
    const mode: find_module.Mode = if (mode_text) |text| find_module.Mode.parse(text) orelse
        return reader.fail("mode must be words, phrase or prefix", .{}) else .words;
    const page_size = try reader.optionalInteger("page_size");
    const request_scope = try reader.scopeOf(caller);
    return .{
        .request = .{
            .query = query,
            .mode = mode,
            .path_prefix = try reader.optionalString("path_prefix"),
            .page_size = if (page_size) |size| std.math.cast(usize, size) orelse std.math.maxInt(usize) else find_module.default_page_size,
            .cursor = try reader.optionalString("cursor"),
        },
        .scope = request_scope,
        .named = try reader.stringList("roots", max_named_roots),
    };
}

// ------------------------------------------------------------- outline ---

/// `outline` (section 8): `{root_id, path, roots?}`.
pub fn outline(allocator: std.mem.Allocator, service: service_module.Service, params: std.json.ObjectMap, caller: Caller) !Result {
    var reader = newReader(allocator, params);
    const parsed = parseFile(&reader, caller, &.{ "root_id", "path", "roots", "principal_labels" }) catch |err| switch (err) {
        error.Invalid => return reader.failure(),
        error.OutOfMemory => return error.OutOfMemory,
    };
    const data = switch (try scopedOf(service).outline(allocator, parsed.scope, parsed.root_id, parsed.path)) {
        .ok => |data| data,
        .failed => |failure| return .{ .failed = failure },
    };
    var out: std.Io.Writer.Allocating = .init(allocator);
    var json = std.json.Stringify{ .writer = &out.writer };
    try json.beginObject();
    try json.objectField("request");
    try json.beginObject();
    try json.objectField("root_id");
    try json.write(parsed.root_id);
    try json.objectField("path");
    try json.write(parsed.path);
    try json.objectField("roots");
    try writeRoots(&json, parsed.named);
    try json.endObject();
    try writeCommon(allocator, &json, service, parsed.scope, &.{});
    try source.writeOutlineFields(&json, data);
    try json.endObject();
    return .{ .ok = out.written() };
}

const ParsedFile = struct { root_id: []const u8, path: []const u8, scope: scope.Request, named: ?[]const []const u8 };

fn parseFile(reader: *Reader, caller: Caller, fields: []const []const u8) Error!ParsedFile {
    try reader.only(fields);
    const root_id = try reader.requiredString("root_id");
    const path = try reader.requiredString("path");
    return .{ .root_id = root_id, .path = path, .scope = try reader.scopeOf(caller), .named = try reader.stringList("roots", max_named_roots) };
}

// ----------------------------------------------------------- read_span ---

/// `read_span` (sections 4 and 8): `{root_id, path, start_line, end_line,
/// context_lines?, roots?}`; at most 400 lines including context and
/// 256 KiB, `context_lines` at most 20, `end_line` past the last line
/// clamped (with an `end_line_clamped` warning).
pub fn readSpan(allocator: std.mem.Allocator, service: service_module.Service, params: std.json.ObjectMap, caller: Caller) !Result {
    var reader = newReader(allocator, params);
    const fields = [_][]const u8{ "root_id", "path", "start_line", "end_line", "context_lines", "roots", "principal_labels" };
    var start_line: u32 = 0;
    var end_line: u32 = 0;
    var context_lines: u32 = 0;
    const parsed = blk: {
        const file = parseFile(&reader, caller, &fields) catch |err| switch (err) {
            error.Invalid => return reader.failure(),
            error.OutOfMemory => return error.OutOfMemory,
        };
        start_line = lineNumber(&reader, "start_line", true) catch |err| switch (err) {
            error.Invalid => return reader.failure(),
            error.OutOfMemory => return error.OutOfMemory,
        };
        end_line = lineNumber(&reader, "end_line", true) catch |err| switch (err) {
            error.Invalid => return reader.failure(),
            error.OutOfMemory => return error.OutOfMemory,
        };
        context_lines = lineNumber(&reader, "context_lines", false) catch |err| switch (err) {
            error.Invalid => return reader.failure(),
            error.OutOfMemory => return error.OutOfMemory,
        };
        break :blk file;
    };
    const span = switch (try scopedOf(service).readSpan(allocator, parsed.scope, parsed.root_id, parsed.path, start_line, end_line, context_lines)) {
        .ok => |span| span,
        .failed => |failure| return .{ .failed = failure },
    };
    var warnings = std.ArrayList(Warning).empty;
    if (span.end_line < end_line) try warnings.append(allocator, .{
        .code = "end_line_clamped",
        .message = try std.fmt.allocPrint(allocator, "end_line {d} is past the last line {d}", .{ end_line, span.end_line }),
    });
    var out: std.Io.Writer.Allocating = .init(allocator);
    var json = std.json.Stringify{ .writer = &out.writer };
    try json.beginObject();
    try json.objectField("request");
    try json.beginObject();
    try json.objectField("root_id");
    try json.write(parsed.root_id);
    try json.objectField("path");
    try json.write(parsed.path);
    try json.objectField("start_line");
    try json.write(start_line);
    try json.objectField("end_line");
    try json.write(end_line);
    try json.objectField("context_lines");
    try json.write(context_lines);
    try json.objectField("roots");
    try writeRoots(&json, parsed.named);
    try json.endObject();
    try writeCommon(allocator, &json, service, parsed.scope, warnings.items);
    try source.writeSpanFields(&json, span);
    try json.endObject();
    return .{ .ok = out.written() };
}

/// A line number or count that fits u32 (`required`: the field must be there).
fn lineNumber(reader: *Reader, name: []const u8, required: bool) Error!u32 {
    const value = if (required) try reader.requiredInteger(name) else (try reader.optionalInteger(name)) orelse 0;
    return std.math.cast(u32, value) orelse reader.fail("{s} is too large", .{name});
}

// ---------------------------------------------------------- list_files ---

/// `list_files` (section 8): `{root_id?, path_prefix?, status?, page_size?,
/// cursor?, roots?}`, ordered by root then path; `size` is the retained
/// bytes' length (or a pending file's announced size), `mtime_ms` is null
/// (a generation does not record it; INDEX-STATE is the writer's file).
pub fn listFiles(allocator: std.mem.Allocator, service: service_module.Service, params: std.json.ObjectMap, caller: Caller) !Result {
    var reader = newReader(allocator, params);
    const parsed = parseList(&reader, caller) catch |err| switch (err) {
        error.Invalid => return reader.failure(),
        error.OutOfMemory => return error.OutOfMemory,
    };
    const generation = service.engine.generation;
    const offset: usize = if (parsed.cursor) |cursor| switch (parseCursor(cursor, generation)) {
        .offset => |value| value,
        .malformed => return .{ .failed = .{ .code = .invalid_argument, .message = "malformed cursor" } },
        .stale => return .{ .failed = .{ .code = .invalid_argument, .message = find_module.stale_cursor_message } },
    } else 0;
    const all = try scopedOf(service).listFiles(allocator, parsed.scope, parsed.root_id, parsed.path_prefix);
    var kept = std.ArrayList(service_module.FileListing).empty;
    for (all) |file| {
        if (parsed.status) |wanted| if (!std.mem.eql(u8, wanted, file.status)) continue;
        try kept.append(allocator, file);
    }
    const start = @min(offset, kept.items.len);
    const end = @min(start + parsed.page_size, kept.items.len);
    const folder = service.folder.?;

    var out: std.Io.Writer.Allocating = .init(allocator);
    var json = std.json.Stringify{ .writer = &out.writer };
    try json.beginObject();
    try json.objectField("request");
    try json.beginObject();
    try json.objectField("root_id");
    try json.write(parsed.root_id);
    try json.objectField("path_prefix");
    try json.write(parsed.path_prefix);
    try json.objectField("status");
    try json.write(parsed.status);
    try json.objectField("page_size");
    try json.write(parsed.page_size);
    try json.objectField("cursor");
    try json.write(parsed.cursor);
    try json.objectField("roots");
    try writeRoots(&json, parsed.named);
    try json.endObject();
    try writeCommon(allocator, &json, service, parsed.scope, &.{});
    try json.objectField("files");
    try json.beginArray();
    for (kept.items[start..end]) |file| {
        try json.beginObject();
        try json.objectField("root_id");
        try json.write(file.root_id);
        try json.objectField("path");
        try json.write(file.path);
        try json.objectField("size");
        try json.write(try fileSize(allocator, folder.*, file));
        try json.objectField("mtime_ms");
        try json.write(null);
        try json.objectField("status");
        try json.write(file.status);
        try json.objectField("chunks");
        try json.write(file.chunks);
        try json.objectField("chunker");
        try json.write(file.chunker);
        try json.endObject();
    }
    try json.endArray();
    try json.objectField("total");
    try json.write(kept.items.len);
    try json.objectField("next_cursor");
    if (end < kept.items.len) try json.write(try std.fmt.allocPrint(allocator, "{d}:{d}", .{ generation, end })) else try json.write(null);
    try json.endObject();
    return .{ .ok = out.written() };
}

const ParsedList = struct {
    root_id: ?[]const u8,
    path_prefix: ?[]const u8,
    status: ?[]const u8,
    page_size: usize,
    cursor: ?[]const u8,
    scope: scope.Request,
    named: ?[]const []const u8,
};

fn parseList(reader: *Reader, caller: Caller) Error!ParsedList {
    try reader.only(&.{ "root_id", "path_prefix", "status", "page_size", "cursor", "roots", "principal_labels" });
    const status = try reader.optionalString("status");
    if (status) |text| if (!std.mem.eql(u8, text, "indexed") and !std.mem.eql(u8, text, "pending"))
        return reader.fail("status must be indexed or pending", .{});
    const page_size = (try reader.optionalInteger("page_size")) orelse default_list_page_size;
    if (page_size < 1 or page_size > max_list_page_size) return reader.fail("page_size must be 1..{d}", .{max_list_page_size});
    return .{
        .root_id = try reader.optionalString("root_id"),
        .path_prefix = try reader.optionalString("path_prefix"),
        .status = status,
        .page_size = @intCast(page_size),
        .cursor = try reader.optionalString("cursor"),
        .scope = try reader.scopeOf(caller),
        .named = try reader.stringList("roots", max_named_roots),
    };
}

fn fileSize(allocator: std.mem.Allocator, folder: scope.Folder, file: service_module.FileListing) !?u64 {
    if (std.mem.eql(u8, file.status, "pending")) {
        for (folder.pending) |entry| {
            if (std.mem.eql(u8, entry.root_id, file.root_id) and std.mem.eql(u8, entry.path, file.path)) return entry.size;
        }
        return null;
    }
    const section = (try folder.sourceSection()) orelse return null;
    const record = try scope.recordPath(allocator, file.root_id, file.path);
    const entry = section.find(record) orelse return null;
    return entry.bytes.len;
}

const CursorParse = union(enum) { offset: usize, malformed, stale };

/// `"<generation>:<offset>"`, as `find`'s cursors.
fn parseCursor(cursor: []const u8, generation: u64) CursorParse {
    const colon = std.mem.indexOfScalar(u8, cursor, ':') orelse return .malformed;
    const cursor_generation = std.fmt.parseInt(u64, cursor[0..colon], 10) catch return .malformed;
    const value = std.fmt.parseInt(usize, cursor[colon + 1 ..], 10) catch return .malformed;
    if (cursor_generation != generation) return .stale;
    return .{ .offset = value };
}

// --------------------------------------------------------------- roots ---

/// `roots` (`ss_roots`): `{roots?}` → the visible roots with their file,
/// document and pending counts over the scope.
pub fn visibleRoots(allocator: std.mem.Allocator, service: service_module.Service, params: std.json.ObjectMap, caller: Caller) !Result {
    var reader = newReader(allocator, params);
    var named: ?[]const []const u8 = null;
    const request_scope = blk: {
        reader.only(&.{ "roots", "principal_labels" }) catch |err| switch (err) {
            error.Invalid => return reader.failure(),
            error.OutOfMemory => return error.OutOfMemory,
        };
        named = reader.stringList("roots", max_named_roots) catch |err| switch (err) {
            error.Invalid => return reader.failure(),
            error.OutOfMemory => return error.OutOfMemory,
        };
        break :blk reader.scopeOf(caller) catch |err| switch (err) {
            error.Invalid => return reader.failure(),
            error.OutOfMemory => return error.OutOfMemory,
        };
    };
    const status = try scopedOf(service).indexStatus(allocator, request_scope);
    var out: std.Io.Writer.Allocating = .init(allocator);
    var json = std.json.Stringify{ .writer = &out.writer };
    try json.beginObject();
    try json.objectField("request");
    try json.beginObject();
    try json.objectField("roots");
    try writeRoots(&json, named);
    try json.endObject();
    try writeCommon(allocator, &json, service, request_scope, &.{});
    try json.objectField("roots");
    try json.beginArray();
    for (status.roots) |root| try json.write(root);
    try json.endArray();
    try json.endObject();
    return .{ .ok = out.written() };
}

// -------------------------------------------------------- index_status ---

/// The scoped `index_status` (`ss_status`, RPC `index_status`): the v1
/// fields first, unchanged in order, then section 8's additions, all over
/// the scope `{roots?}` names (S3-T3 finding: no whole-index counts).
pub fn indexStatus(allocator: std.mem.Allocator, service: service_module.Service, params: std.json.ObjectMap, caller: Caller) !Result {
    var reader = newReader(allocator, params);
    const request_scope = blk: {
        reader.only(&.{ "roots", "principal_labels" }) catch |err| switch (err) {
            error.Invalid => return reader.failure(),
            error.OutOfMemory => return error.OutOfMemory,
        };
        break :blk reader.scopeOf(caller) catch |err| switch (err) {
            error.Invalid => return reader.failure(),
            error.OutOfMemory => return error.OutOfMemory,
        };
    };
    const status = try scopedOf(service).indexStatus(allocator, request_scope);
    var out: std.Io.Writer.Allocating = .init(allocator);
    var json = std.json.Stringify{ .writer = &out.writer };
    try service_module.writeScopedStatusJson(&json, status);
    if (service.engine.filename_index_enabled) {
        const bytes = out.written();
        return .{ .ok = try std.fmt.allocPrint(allocator, "{s},\"filename_policy_id\":\"filename-field-v1\"}}", .{bytes[0..bytes.len - 1]}) };
    }
    return .{ .ok = out.written() };
}

// ------------------------------------------------------------ evidence ---

/// `evidence` by chunk id (`ss_evidence`), through the scope (S3-T3
/// finding 2): `{ids, path_prefix?, roots?}` → one entry per id, in order:
/// the v1 chunk fields (`chunk_id`, `citation`, `content`) plus `root_id`,
/// `section_path` and `neighbours {prev, next}` (the adjacent chunks of the
/// same file by start line, or null), or `{chunk_id, found: false}` for an
/// unknown or hidden id alike. `path_prefix` applies to the citation path,
/// as in v1.
pub fn evidence(allocator: std.mem.Allocator, service: service_module.Service, params: std.json.ObjectMap, caller: Caller) !Result {
    var reader = newReader(allocator, params);
    const Parsed = struct { ids: []const []const u8, prefix: ?[]const u8, scope: scope.Request };
    const parsed: Parsed = blk: {
        const value = parseEvidence(&reader, caller) catch |err| switch (err) {
            error.Invalid => return reader.failure(),
            error.OutOfMemory => return error.OutOfMemory,
        };
        break :blk .{ .ids = value.ids, .prefix = value.prefix, .scope = value.scope };
    };
    const resolved = try service_module.resolve(service, allocator, parsed.scope);
    defer resolved.deinit(allocator);
    const documents = service.engine.documents;
    const folder = resolved.folder;

    var by_id = std.StringHashMapUnmanaged(usize).empty;
    defer by_id.deinit(allocator);
    if (parsed.ids.len > 4) {
        for (documents, 0..) |document, index| try by_id.put(allocator, document.id, index);
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    var json = std.json.Stringify{ .writer = &out.writer };
    try json.beginArray();
    for (parsed.ids) |id| {
        const found: ?usize = blk: {
            const index = if (parsed.ids.len > 4) by_id.get(id) orelse break :blk null else lookup: {
                for (documents, 0..) |document, index| if (std.mem.eql(u8, document.id, id)) break :lookup index;
                break :blk null;
            };
            if (!resolved.documentVisible(documents, index)) break :blk null;
            if (!hybrid.matchesPath(documents[index].path, parsed.prefix)) break :blk null;
            break :blk index;
        };
        try json.beginObject();
        if (found) |index| {
            const document = documents[index];
            try json.objectField("chunk_id");
            try json.write(document.id);
            try json.objectField("citation");
            try json.beginObject();
            try json.objectField("path");
            try json.write(document.path);
            try json.objectField("start_line");
            try json.write(document.start_line);
            try json.objectField("end_line");
            try json.write(document.end_line);
            try json.endObject();
            try json.objectField("content");
            try json.write(document.text);
            try json.objectField("root_id");
            const root = folder.document_roots[index];
            try json.write(if (root < folder.roots.len) folder.roots[root].root_id else scope.legacy_root_id);
            try json.objectField("section_path");
            try json.beginArray();
            if (document.section_path.len != 0) {
                var parts = std.mem.splitScalar(u8, document.section_path, 0x1F);
                while (parts.next()) |part| try json.write(part);
            }
            try json.endArray();
            try json.objectField("neighbours");
            const around = neighbours(documents, index);
            try json.beginObject();
            try json.objectField("prev");
            try writeNeighbour(&json, documents, around.prev);
            try json.objectField("next");
            try writeNeighbour(&json, documents, around.next);
            try json.endObject();
        } else {
            try json.objectField("chunk_id");
            try json.write(id);
            try json.objectField("found");
            try json.write(false);
        }
        try json.endObject();
    }
    try json.endArray();
    return .{ .ok = out.written() };
}

fn parseEvidence(reader: *Reader, caller: Caller) Error!struct { ids: []const []const u8, prefix: ?[]const u8, scope: scope.Request } {
    try reader.only(&.{ "ids", "path_prefix", "roots", "principal_labels" });
    if (reader.object.get("ids") == null) return reader.fail("ids is required", .{});
    const ids = (try reader.stringList("ids", max_evidence_ids)) orelse return reader.fail("ids must be an array of strings", .{});
    return .{ .ids = ids, .prefix = try reader.optionalString("path_prefix"), .scope = try reader.scopeOf(caller) };
}

const Around = struct { prev: ?usize, next: ?usize };

/// The chunks of the same file just before and after `index` by start line
/// (all chunks of a file share its labels and root, so they are visible
/// whenever `index` is).
pub fn neighbours(documents: []const hybrid.Document, index: usize) Around {
    const self = documents[index];
    var around = Around{ .prev = null, .next = null };
    for (documents, 0..) |document, other| {
        if (other == index or !std.mem.eql(u8, document.path, self.path)) continue;
        if (before(document, other, self, index)) {
            if (around.prev == null or before(documents[around.prev.?], around.prev.?, document, other)) around.prev = other;
        } else {
            if (around.next == null or before(document, other, documents[around.next.?], around.next.?)) around.next = other;
        }
    }
    return around;
}

fn before(a: hybrid.Document, a_index: usize, b: hybrid.Document, b_index: usize) bool {
    if (a.start_line != b.start_line) return a.start_line < b.start_line;
    if (a.end_line != b.end_line) return a.end_line < b.end_line;
    return a_index < b_index;
}

fn writeNeighbour(json: *std.json.Stringify, documents: []const hybrid.Document, index: ?usize) !void {
    const at = index orelse return json.write(null);
    const document = documents[at];
    try json.write(.{ .chunk_id = document.id, .start_line = document.start_line, .end_line = document.end_line });
}

// ------------------------------------------------- CAP-13's operations ---

/// Per-request scratch the RPC and MCP servers keep for the life of an
/// opened generation (sized by its document count).
pub const Workspaces = struct {
    query_vector: []f32,
    results: []hybrid.Result,
    evidence: []engine_module.Evidence,
    sources: []service_module.Source,
};

/// `search_knowledge` and `list_sources` on a legacy service failed inside
/// the engine (a workspace too small); the servers answer "Internal error".
pub const OperationError = error{ OperationFailed, OutOfMemory };

/// `search_knowledge`: `{query, top_k? (1-100, 5), candidate_k? (top_k..10000,
/// 100), path_prefix?, retrieval_mode? (lexical|vector|hybrid, hybrid),
/// query_vector? (required for vector and hybrid when the index has
/// vectors), roots?, principal_labels? (trusted callers only)}`. A request
/// (or caller) that names roots runs through the scope; otherwise the v1
/// path, whose labels already filter it (S3-T4).
pub fn searchKnowledge(allocator: std.mem.Allocator, service: service_module.Service, params: std.json.ObjectMap, caller: Caller, workspaces: Workspaces) OperationError!Result {
    var reader = newReader(allocator, params);
    const parsed = parseSearch(&reader, service, caller, workspaces) catch |err| switch (err) {
        error.Invalid => return reader.failure(),
        error.OutOfMemory => return error.OutOfMemory,
    };
    var search_options = hybrid.SearchOptions{
        .top_k = parsed.top_k,
        .candidate_k = parsed.candidate_k,
        .retrieval_mode = parsed.mode,
        .path_prefix = parsed.path_prefix,
        .principal_labels = parsed.scope.principal_labels,
    };
    if (parsed.field != .content) {
        if (service.folder) |folder| search_options.visible_roots = folder.mask(try folder.allowedRoots(allocator, parsed.scope));
        const hits = service.engine.queryFields(allocator, parsed.query, parsed.field, search_options) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.FilenameIndexUnavailable => return .{ .failed = .{ .code = .capacity, .message = "FilenameIndexUnavailable: rebuild in a separate directory with --filename-index" } },
            else => return error.OperationFailed,
        };
        var output: std.Io.Writer.Allocating = .init(allocator);
        filename_response.writeEvidence(&output.writer, allocator, service.engine, parsed.query, parsed.field, search_options, hits, false) catch return error.OutOfMemory;
        return .{ .ok = output.written() };
    }
    const scoped = parsed.scope.roots != null and service.folder != null;
    const found = if (scoped)
        scopedOf(service).searchKnowledge(allocator, parsed.query, parsed.query_vector, search_options, parsed.scope, workspaces.results, workspaces.evidence, null)
    else
        service.searchKnowledge(allocator, parsed.query, parsed.query_vector, search_options, workspaces.results, workspaces.evidence);
    const evidence_items = found catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.OperationFailed,
    };
    var folder_fields: ?FolderFields = null;
    if (service.folder) |folder| {
        const complete = scopedOf(service).completeness(allocator, parsed.scope) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.OperationFailed,
        };
        folder_fields = .{ .folder = folder, .results = workspaces.results, .pending_files = complete.pending_files, .truncated = complete.truncated };
    }
    var out: std.Io.Writer.Allocating = .init(allocator);
    var json = std.json.Stringify{ .writer = &out.writer };
    writeSearchResult(&json, service, parsed.query, parsed.mode, parsed.scope.principal_labels.len, evidence_items, null, folder_fields) catch return error.OutOfMemory;
    return .{ .ok = out.written() };
}

const ParsedSearch = struct {
    field: filename_field.Field,
    query: []const u8,
    top_k: usize,
    candidate_k: usize,
    path_prefix: ?[]const u8,
    mode: hybrid.RetrievalMode,
    query_vector: []const f32,
    scope: scope.Request,
};

fn parseSearch(reader: *Reader, service: service_module.Service, caller: Caller, workspaces: Workspaces) Error!ParsedSearch {
    try reader.only(&.{ "query", "query_vector", "top_k", "candidate_k", "path_prefix", "retrieval_mode", "principal_labels", "roots", "search_field" });
    const field = std.meta.stringToEnum(filename_field.Field, (try reader.optionalString("search_field")) orelse "content") orelse return reader.fail("search_field must be content, filename or both", .{});
    if (field != .content and !std.mem.eql(u8, (try reader.optionalString("retrieval_mode")) orelse "", "lexical")) return reader.fail("filename search requires explicit lexical retrieval_mode", .{});
    const query = try reader.requiredString("query");
    if (query.len == 0) return reader.fail("query must not be empty", .{});
    // S2-T11: same rejection as `ss_query` and the CLI; never reaches analysis.
    engine_module.Engine.validateQueryText(query) catch return reader.fail("query is not valid UTF-8", .{});
    const top_k = try reader.positiveInteger("top_k", 5);
    if (top_k > 100) return reader.fail("top_k must be 1..100", .{});
    const candidate_k = try reader.positiveInteger("candidate_k", 100);
    if (candidate_k > 10_000 or candidate_k < top_k) return reader.fail("candidate_k must be top_k..10000", .{});
    const path_prefix = try reader.optionalString("path_prefix");
    const mode_text = try reader.optionalString("retrieval_mode");
    const mode = parseRetrievalMode(mode_text orelse "hybrid") orelse return reader.fail("retrieval_mode must be lexical, vector or hybrid", .{});
    const request_scope = try reader.scopeOf(caller);
    const query_vector = queryVector(reader.object.get("query_vector"), service.engine.vector_dimensions, mode, workspaces.query_vector) orelse
        return reader.fail("query_vector must hold {d} finite numbers for {s} retrieval", .{ service.engine.vector_dimensions, @tagName(mode) });
    return .{
        .field = field, .query = query, .top_k = top_k, .candidate_k = candidate_k, .path_prefix = path_prefix, .mode = mode, .query_vector = query_vector, .scope = request_scope };
}

/// The three `retrieval_mode` strings (shared with `ss_query` through `rpc.parseMode`).
pub fn parseRetrievalMode(value: []const u8) ?hybrid.RetrievalMode {
    if (std.mem.eql(u8, value, "lexical")) return .lexical;
    if (std.mem.eql(u8, value, "vector")) return .vector;
    if (std.mem.eql(u8, value, "hybrid")) return .hybrid;
    return null;
}

/// The request's vector: empty for lexical mode or an index without vectors;
/// otherwise exactly `dimensions` finite numbers with a finite L2 norm
/// (S2-T13), else null.
fn queryVector(value: ?std.json.Value, dimensions: usize, mode: hybrid.RetrievalMode, output: []f32) ?[]const f32 {
    if (mode == .lexical or dimensions == 0) return &.{};
    if (output.len < dimensions) return null;
    const array = switch (value orelse return null) {
        .array => |array| array.items,
        else => return null,
    };
    if (array.len != dimensions) return null;
    for (array, output[0..dimensions]) |item, *target| {
        const number: f64 = switch (item) {
            .integer => |integer| @floatFromInt(integer),
            .float => |float| float,
            else => return null,
        };
        target.* = @floatCast(number);
        if (!std.math.isFinite(target.*)) return null;
    }
    if (!scoring.isValidVector(output[0..dimensions])) return null;
    return output[0..dimensions];
}

/// What `search_knowledge` adds per item and at the end on a scoped service.
pub const FolderFields = struct {
    folder: *const scope.Folder,
    /// The ranking behind the evidence, in the same order (document indexes).
    results: []const hybrid.Result,
    pending_files: usize,
    truncated: bool,
};

/// The `search_knowledge` result object (`tool`, `query`, `index`,
/// `retrieval`, `results`, `answer_policy`; then, with `folder_fields`,
/// `truncated` and `pending_files`, and each item's `root_id` and
/// `section_path` after its `ranking`; then, with `extras` (the C ABI's
/// `ss_query`, S2-T4), `warnings`, `request` and `profile`).
pub fn writeSearchResult(
    json: *std.json.Stringify,
    service: service_module.Service,
    query: []const u8,
    mode: hybrid.RetrievalMode,
    principal_label_count: usize,
    evidence_items: []const engine_module.Evidence,
    extras: ?query_report.Extras,
    folder_fields: ?FolderFields,
) !void {
    var tail = extras;
    if (tail) |*e| e.serialize_start = hybrid.Trace.stamp(e.trace);
    try json.beginObject();
    try json.objectField("tool");
    try json.write("search_knowledge");
    try json.objectField("query");
    try json.write(query);
    try json.objectField("index");
    try json.beginObject();
    try json.objectField("version");
    try json.write(@as(u16, 2));
    try json.objectField("generation");
    try json.write(service.engine.generation);
    try json.objectField("analyzer_id");
    try json.write(service.engine.analyzer_id);
    try json.objectField("embedding_model_id");
    try json.write(service.engine.embedding_model_id);
    try json.endObject();
    try json.objectField("retrieval");
    try json.beginObject();
    try json.objectField("mode");
    try json.write(@tagName(mode));
    try json.objectField("vector_dimensions");
    try json.write(service.engine.vector_dimensions);
    try json.objectField("authorization");
    try json.beginObject();
    try json.objectField("semantics");
    try json.write("all-required-labels-v1");
    try json.objectField("principal_label_count");
    try json.write(principal_label_count);
    try json.endObject();
    try json.endObject();
    try json.objectField("results");
    try json.beginArray();
    for (evidence_items, 0..) |item, position| {
        try json.beginObject();
        try json.objectField("chunk_id");
        try json.write(item.chunk_id);
        try json.objectField("citation");
        try json.beginObject();
        try json.objectField("path");
        try json.write(item.path);
        try json.objectField("start_line");
        try json.write(item.start_line);
        try json.objectField("end_line");
        try json.write(item.end_line);
        try json.endObject();
        try json.objectField("content");
        try json.write(item.content);
        try json.objectField("score");
        try json.write(item.fused_score);
        try json.objectField("ranking");
        try json.beginObject();
        try json.objectField("lexical");
        try json.beginObject();
        try json.objectField("rank");
        try json.write(item.lexical_rank);
        try json.objectField("score");
        try json.write(item.lexical_score);
        try json.endObject();
        try json.objectField("vector");
        try json.beginObject();
        try json.objectField("rank");
        try json.write(item.semantic_rank);
        try json.objectField("score");
        try json.write(item.semantic_score);
        try json.endObject();
        try json.endObject();
        if (folder_fields) |fields| {
            const documents = service.engine.documents;
            const index = documentIndex(documents, fields.results, position, item.chunk_id);
            try json.objectField("root_id");
            try json.write(rootIdOf(fields.folder.*, index));
            try json.objectField("section_path");
            try writeSectionPath(json, documents[index].section_path);
        }
        try json.endObject();
    }
    try json.endArray();
    try json.objectField("answer_policy");
    try json.write(.{
        .ground_in_results = true,
        .cite_path_and_lines = true,
        .say_when_evidence_is_insufficient = true,
    });
    if (folder_fields) |fields| {
        try json.objectField("truncated");
        try json.write(fields.truncated);
        try json.objectField("pending_files");
        try json.write(fields.pending_files);
    }
    if (tail) |e| try query_report.write(json, e);
    try json.endObject();
}

/// The document behind evidence item `position`: the ranking's index when it
/// names the same chunk (always, as `Service.searchKnowledge` fills the
/// evidence from the ranking in order), else found by id.
fn documentIndex(documents: []const hybrid.Document, results: []const hybrid.Result, position: usize, chunk_id: []const u8) usize {
    if (position < results.len) {
        const index = results[position].document_index;
        if (index < documents.len and std.mem.eql(u8, documents[index].id, chunk_id)) return index;
    }
    for (documents, 0..) |document, index| if (std.mem.eql(u8, document.id, chunk_id)) return index;
    unreachable;
}

fn rootIdOf(folder: scope.Folder, index: usize) []const u8 {
    const root = folder.document_roots[index];
    return if (root < folder.roots.len) folder.roots[root].root_id else scope.legacy_root_id;
}

fn writeSectionPath(json: *std.json.Stringify, section_path: []const u8) !void {
    try json.beginArray();
    if (section_path.len != 0) {
        var parts = std.mem.splitScalar(u8, section_path, 0x1F);
        while (parts.next()) |part| try json.write(part);
    }
    try json.endArray();
}

/// `read_chunk`: `{chunk_id, path_prefix?, roots?, principal_labels?}` →
/// `{chunk_id, citation {path, start_line, end_line}, content}`; a hidden and
/// an unknown chunk are both `not_found` "Chunk not found".
pub fn readChunk(allocator: std.mem.Allocator, service: service_module.Service, params: std.json.ObjectMap, caller: Caller) !Result {
    var reader = newReader(allocator, params);
    const Parsed = struct { chunk_id: []const u8, path_prefix: ?[]const u8, scope: scope.Request };
    const parsed: Parsed = blk: {
        reader.only(&.{ "chunk_id", "path_prefix", "principal_labels", "roots" }) catch |err| switch (err) {
            error.Invalid => return reader.failure(),
            error.OutOfMemory => return error.OutOfMemory,
        };
        const chunk_id = reader.requiredString("chunk_id") catch |err| switch (err) {
            error.Invalid => return reader.failure(),
            error.OutOfMemory => return error.OutOfMemory,
        };
        const path_prefix = reader.optionalString("path_prefix") catch |err| switch (err) {
            error.Invalid => return reader.failure(),
            error.OutOfMemory => return error.OutOfMemory,
        };
        const request_scope = reader.scopeOf(caller) catch |err| switch (err) {
            error.Invalid => return reader.failure(),
            error.OutOfMemory => return error.OutOfMemory,
        };
        break :blk .{ .chunk_id = chunk_id, .path_prefix = path_prefix, .scope = request_scope };
    };
    // S3-T4 (S3-T3 finding 2): the read by chunk id goes through the scope.
    const read = if (service.folder != null)
        try scopedOf(service).readChunk(allocator, parsed.chunk_id, parsed.path_prefix, parsed.scope)
    else
        service.readChunk(parsed.chunk_id, parsed.path_prefix, parsed.scope.principal_labels);
    const chunk = read orelse return .{ .failed = .{ .code = .not_found, .message = "Chunk not found" } };
    var out: std.Io.Writer.Allocating = .init(allocator);
    var json = std.json.Stringify{ .writer = &out.writer };
    try json.beginObject();
    try writeChunkFields(&json, chunk);
    try json.endObject();
    return .{ .ok = out.written() };
}

/// The fields of one chunk (chunk_id, citation, content), shared with the C
/// ABI's `ss_evidence` through `rpc.writeChunkFields`.
pub fn writeChunkFields(json: *std.json.Stringify, chunk: service_module.Chunk) !void {
    try json.objectField("chunk_id");
    try json.write(chunk.chunk_id);
    try json.objectField("citation");
    try json.beginObject();
    try json.objectField("path");
    try json.write(chunk.path);
    try json.objectField("start_line");
    try json.write(chunk.start_line);
    try json.objectField("end_line");
    try json.write(chunk.end_line);
    try json.endObject();
    try json.objectField("content");
    try json.write(chunk.content);
}

/// `list_sources`: `{path_prefix?, roots?, principal_labels?}` →
/// `{sources: [{path, chunks}], count}`, sorted by path.
pub fn listSources(allocator: std.mem.Allocator, service: service_module.Service, params: std.json.ObjectMap, caller: Caller, workspaces: Workspaces) OperationError!Result {
    var reader = newReader(allocator, params);
    const Parsed = struct { path_prefix: ?[]const u8, scope: scope.Request };
    const parsed: Parsed = blk: {
        reader.only(&.{ "path_prefix", "principal_labels", "roots" }) catch |err| switch (err) {
            error.Invalid => return reader.failure(),
            error.OutOfMemory => return error.OutOfMemory,
        };
        const path_prefix = reader.optionalString("path_prefix") catch |err| switch (err) {
            error.Invalid => return reader.failure(),
            error.OutOfMemory => return error.OutOfMemory,
        };
        const request_scope = reader.scopeOf(caller) catch |err| switch (err) {
            error.Invalid => return reader.failure(),
            error.OutOfMemory => return error.OutOfMemory,
        };
        break :blk .{ .path_prefix = path_prefix, .scope = request_scope };
    };
    const listed = if (service.folder != null)
        scopedOf(service).listSources(allocator, parsed.path_prefix, parsed.scope)
    else
        service.listSources(parsed.path_prefix, parsed.scope.principal_labels, workspaces.sources);
    const sources = listed catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.OperationFailed,
    };
    var out: std.Io.Writer.Allocating = .init(allocator);
    var json = std.json.Stringify{ .writer = &out.writer };
    json.beginObject() catch return error.OutOfMemory;
    json.objectField("sources") catch return error.OutOfMemory;
    json.beginArray() catch return error.OutOfMemory;
    for (sources) |source_entry| json.write(.{ .path = source_entry.path, .chunks = source_entry.chunks }) catch return error.OutOfMemory;
    json.endArray() catch return error.OutOfMemory;
    json.objectField("count") catch return error.OutOfMemory;
    json.write(sources.len) catch return error.OutOfMemory;
    json.endObject() catch return error.OutOfMemory;
    return .{ .ok = out.written() };
}

// ------------------------------------------------------- apply_changes ---

/// `apply_changes` (section 6): the request as the core takes it, the
/// report as `apply.writeReportJson` writes it.
pub fn applyChanges(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, request_json: []const u8, options: apply.Options) !Result {
    const report = switch (try apply.applyChanges(allocator, io, dir, request_json, options)) {
        .ok => |report| report,
        .failed => |failure| return .{ .failed = failure },
    };
    var out: std.Io.Writer.Allocating = .init(allocator);
    var json = std.json.Stringify{ .writer = &out.writer };
    try apply.writeReportJson(&json, report);
    return .{ .ok = out.written() };
}

/// The options a surface accepts for `apply_changes` (`ss_apply_changes`'s
/// `opts_json`): `{allow_file_reads?, max_file_bytes?, max_total_bytes?,
/// analyzer?, max_chars?, overlap_lines?, keep_generations?}`.
pub fn applyOptions(allocator: std.mem.Allocator, params: std.json.ObjectMap) !union(enum) { ok: apply.Options, failed: Failure } {
    var reader = newReader(allocator, params);
    const options = parseApplyOptions(&reader) catch |err| switch (err) {
        error.Invalid => return .{ .failed = reader.failure().failed },
        error.OutOfMemory => return error.OutOfMemory,
    };
    return .{ .ok = options };
}

fn parseApplyOptions(reader: *Reader) Error!apply.Options {
    try reader.only(&.{ "allow_file_reads", "max_file_bytes", "max_total_bytes", "analyzer", "max_chars", "overlap_lines", "keep_generations", "filename_index" });
    var options = apply.Options{};
    if (reader.object.get("filename_index")) |value| options.filename_index = switch (value) {
        .bool => |flag| flag,
        else => return reader.fail("filename_index must be a boolean", .{}),
    };
    if (reader.object.get("allow_file_reads")) |value| options.allow_file_reads = switch (value) {
        .bool => |flag| flag,
        else => return reader.fail("allow_file_reads must be a boolean", .{}),
    };
    if (try reader.optionalInteger("max_file_bytes")) |value| options.max_file_bytes = value;
    if (try reader.optionalInteger("max_total_bytes")) |value| options.max_total_bytes = value;
    if (try reader.optionalString("analyzer")) |name| options.analyzer = @import("indexer.zig").AnalyzerId.parse(name) orelse
        return reader.fail("analyzer must be v1 or v2", .{});
    if (try reader.optionalInteger("max_chars")) |value| {
        if (value == 0) return reader.fail("max_chars must be positive", .{});
        options.max_chars = std.math.cast(usize, value) orelse return reader.fail("max_chars is too large", .{});
    }
    if (try reader.optionalInteger("overlap_lines")) |value| options.overlap_lines = std.math.cast(usize, value) orelse return reader.fail("overlap_lines is too large", .{});
    if (try reader.optionalInteger("keep_generations")) |value| {
        if (value == 0) return reader.fail("keep_generations must be at least 1", .{});
        options.keep_generations = std.math.cast(usize, value) orelse return reader.fail("keep_generations is too large", .{});
    }
    return options;
}

// ------------------------------------------------------------------ tests ---

const snapshot_open = @import("snapshot_open.zig");

/// A host index of two roots (one labelled) in a temporary directory.
const TestIndex = struct {
    arena_state: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    service: service_module.Service = undefined,

    fn init() !*TestIndex {
        const self = try std.testing.allocator.create(TestIndex);
        self.* = .{ .arena_state = std.heap.ArenaAllocator.init(std.testing.allocator), .tmp = std.testing.tmpDir(.{ .iterate = true }) };
        const a = self.arena_state.allocator();
        const io = std.testing.io;
        const week = "# Week 7\n\n## Spelling\nharbour island\n\n## Dates\nBand concert: count me in.\n";
        const long_lines = try a.alloc(u8, 600 * 2);
        for (0..600) |n| {
            long_lines[2 * n] = 'x';
            long_lines[2 * n + 1] = '\n';
        }
        const encoder = std.base64.standard.Encoder;
        const week64 = try a.alloc(u8, encoder.calcSize(week.len));
        _ = encoder.encode(week64, week);
        const long64 = try a.alloc(u8, encoder.calcSize(long_lines.len));
        _ = encoder.encode(long64, long_lines);
        const secret = "# Secret\n\nharbour plans\n";
        const secret64 = try a.alloc(u8, encoder.calcSize(secret.len));
        _ = encoder.encode(secret64, secret);
        const request = try std.fmt.allocPrint(a,
            \\{{"roots":[{{"root_id":"school","kind":"host"}},{{"root_id":"vault","kind":"host","required_labels":["adults"]}}],
            \\"changes":[{{"op":"add","root_id":"school","path":"week.md","content_base64":"{s}"}},
            \\{{"op":"add","root_id":"school","path":"long.txt","content_base64":"{s}"}},
            \\{{"op":"pending","root_id":"school","path":"later.md","size":7}},
            \\{{"op":"add","root_id":"vault","path":"secret.md","content_base64":"{s}"}}]}}
        , .{ week64, long64, secret64 });
        switch (try apply.applyChanges(a, io, self.tmp.dir, request, .{})) {
            .ok => {},
            .failed => |failure| {
                std.debug.print("{s}\n", .{failure.message});
                return error.TestUnexpectedResult;
            },
        }
        const opened = try snapshot_open.openScoped(a, io, self.tmp.dir);
        self.service = .{ .engine = opened.engine, .folder = opened.folder };
        return self;
    }

    fn deinit(self: *TestIndex) void {
        self.tmp.cleanup();
        self.arena_state.deinit();
        std.testing.allocator.destroy(self);
    }

    fn run(self: *TestIndex, operation: anytype, request: []const u8, caller: Caller) !Result {
        const a = self.arena_state.allocator();
        const params = (try parseObject(a, request)).ok;
        return operation(a, self.service, params, caller);
    }
};

fn expectOk(result: Result) ![]const u8 {
    return switch (result) {
        .ok => |text| text,
        .failed => |failure| {
            std.debug.print("unexpected refusal: {s}\n", .{failure.message});
            return error.TestUnexpectedResult;
        },
    };
}

fn expectRefused(result: Result, code: Code, needle: []const u8) !void {
    switch (result) {
        .ok => |text| {
            std.debug.print("unexpected answer: {s}\n", .{text});
            return error.TestUnexpectedResult;
        },
        .failed => |failure| {
            try std.testing.expectEqual(code, failure.code);
            if (std.mem.indexOf(u8, failure.message, needle) == null) {
                std.debug.print("message {s} lacks {s}\n", .{ failure.message, needle });
                return error.TestUnexpectedResult;
            }
        },
    }
}

test "S3-T4: the envelope, root-relative paths and the request echo" {
    const index = try TestIndex.init();
    defer index.deinit();
    const text = try expectOk(try index.run(find, "{\"query\":\"harbour\",\"page_size\":5}", .{}));
    try std.testing.expect(std.mem.startsWith(u8, text, "{\"request\":{\"query\":\"harbour\",\"mode\":\"words\",\"roots\":null,\"path_prefix\":null,\"page_size\":5,\"cursor\":null},\"generation\":1,\"scope\":{\"roots\":[\"school\"],\"labels_applied\":true},\"warnings\":[],\"hits\":[{"));
    try std.testing.expect(std.mem.indexOf(u8, text, "\"root_id\":\"school\",\"path\":\"week.md\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "vault") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"pending_files\":1") != null);
    // A root-relative path prefix.
    const prefixed = try expectOk(try index.run(find, "{\"query\":\"harbour\",\"path_prefix\":\"week\"}", .{}));
    try std.testing.expect(std.mem.indexOf(u8, prefixed, "\"path\":\"week.md\"") != null);
    const none = try expectOk(try index.run(find, "{\"query\":\"harbour\",\"path_prefix\":\"school/\"}", .{}));
    try std.testing.expect(std.mem.indexOf(u8, none, "\"hits\":[]") != null);
}

test "S3-T4: the scope narrows, labels come only from a trusted caller" {
    const index = try TestIndex.init();
    defer index.deinit();
    const trusted = Caller{ .request_labels = true };
    const labelled = try expectOk(try index.run(find, "{\"query\":\"harbour\",\"principal_labels\":[\"adults\"]}", trusted));
    try std.testing.expect(std.mem.indexOf(u8, labelled, "\"root_id\":\"vault\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, labelled, "\"scope\":{\"roots\":[\"school\",\"vault\"]") != null);
    try expectRefused(try index.run(find, "{\"query\":\"harbour\",\"principal_labels\":[\"adults\"]}", .{}), .invalid_argument, "principal_labels comes from the trusted caller");
    try expectRefused(try index.run(find, "{\"query\":\"harbour\",\"principal_labels\":[\"a\",\"a\"]}", trusted), .invalid_argument, "repeats");
    // The server's roots bound the request's.
    const bound = Caller{ .roots = &.{"school"}, .labels = &.{"adults"} };
    const narrowed = try expectOk(try index.run(visibleRoots, "{\"roots\":[\"vault\",\"school\"]}", bound));
    try std.testing.expect(std.mem.indexOf(u8, narrowed, "\"scope\":{\"roots\":[\"school\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, narrowed, "\"request\":{\"roots\":[\"vault\",\"school\"]}") != null);
    const all_bound = try expectOk(try index.run(visibleRoots, "{}", bound));
    try std.testing.expect(std.mem.indexOf(u8, all_bound, "\"roots\":[{\"root_id\":\"school\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, all_bound, "vault") == null);
    // Hidden and absent files answer alike.
    const hidden = try index.run(readSpan, "{\"root_id\":\"vault\",\"path\":\"secret.md\",\"start_line\":1,\"end_line\":1}", .{});
    try expectRefused(hidden, .not_found, "vault/secret.md");
    try expectRefused(try index.run(outline, "{\"root_id\":\"vault\",\"path\":\"secret.md\"}", .{}), .not_found, "not indexed or not retained: vault/secret.md");
}

test "S3-T4: read_span caps, clamping and every refusal; outline" {
    const index = try TestIndex.init();
    defer index.deinit();
    const span = try expectOk(try index.run(readSpan, "{\"root_id\":\"school\",\"path\":\"week.md\",\"start_line\":6,\"end_line\":9,\"context_lines\":1}", .{}));
    try std.testing.expect(std.mem.indexOf(u8, span, "\"warnings\":[{\"code\":\"end_line_clamped\",\"message\":\"end_line 9 is past the last line 7\"}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, span, "\"text\":\"## Dates\\nBand concert: count me in.\\n\",\"context_before\":\"\\n\",\"context_after\":\"\"") != null);
    try expectRefused(try index.run(readSpan, "{\"root_id\":\"school\",\"path\":\"long.txt\",\"start_line\":1,\"end_line\":401}", .{}), .capacity, "401 lines");
    _ = try expectOk(try index.run(readSpan, "{\"root_id\":\"school\",\"path\":\"long.txt\",\"start_line\":21,\"end_line\":380,\"context_lines\":20}", .{}));
    try expectRefused(try index.run(readSpan, "{\"root_id\":\"school\",\"path\":\"week.md\",\"start_line\":1}", .{}), .invalid_argument, "end_line is required");
    try expectRefused(try index.run(readSpan, "{\"root_id\":\"school\",\"path\":\"week.md\",\"start_line\":-1,\"end_line\":1}", .{}), .invalid_argument, "non-negative");
    try expectRefused(try index.run(readSpan, "{\"root_id\":\"school\",\"path\":\"week.md\",\"start_line\":4294967296,\"end_line\":1}", .{}), .invalid_argument, "too large");
    try expectRefused(try index.run(readSpan, "{\"root_id\":\"school\",\"path\":\"week.md\",\"start_line\":1,\"end_line\":1,\"x\":1}", .{}), .invalid_argument, "unknown field \"x\"");
    const tree = try expectOk(try index.run(outline, "{\"root_id\":\"school\",\"path\":\"week.md\"}", .{}));
    try std.testing.expect(std.mem.endsWith(u8, tree, "\"front_matter\":null,\"headings\":[{\"level\":1,\"text\":\"Week 7\",\"line\":1,\"end_line\":7},{\"level\":2,\"text\":\"Spelling\",\"line\":3,\"end_line\":5},{\"level\":2,\"text\":\"Dates\",\"line\":6,\"end_line\":7}],\"lines\":7,\"chunker\":\"md-section-v1\"}"));
}

test "S3-T4: list_files pages, filters and sizes; roots and the scoped status" {
    const index = try TestIndex.init();
    defer index.deinit();
    const page = try expectOk(try index.run(listFiles, "{\"page_size\":2}", .{}));
    try std.testing.expect(std.mem.indexOf(u8, page, "\"files\":[{\"root_id\":\"school\",\"path\":\"later.md\",\"size\":7,\"mtime_ms\":null,\"status\":\"pending\",\"chunks\":0,\"chunker\":null},{\"root_id\":\"school\",\"path\":\"long.txt\",\"size\":1200,") != null);
    try std.testing.expect(std.mem.endsWith(u8, page, "\"total\":3,\"next_cursor\":\"1:2\"}"));
    const rest = try expectOk(try index.run(listFiles, "{\"page_size\":2,\"cursor\":\"1:2\"}", .{}));
    try std.testing.expect(std.mem.indexOf(u8, rest, "\"path\":\"week.md\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, rest, "\"next_cursor\":null}"));
    const pending = try expectOk(try index.run(listFiles, "{\"status\":\"pending\"}", .{}));
    try std.testing.expect(std.mem.indexOf(u8, pending, "\"total\":1") != null);
    try expectRefused(try index.run(listFiles, "{\"cursor\":\"2:0\"}", .{}), .invalid_argument, "stale cursor");
    try expectRefused(try index.run(listFiles, "{\"cursor\":\"1-0\"}", .{}), .invalid_argument, "malformed cursor");
    try expectRefused(try index.run(listFiles, "{\"page_size\":1001}", .{}), .invalid_argument, "page_size");
    try expectRefused(try index.run(listFiles, "{\"status\":\"done\"}", .{}), .invalid_argument, "status");
    const status = try expectOk(try index.run(indexStatus, "{}", .{}));
    try std.testing.expect(std.mem.indexOf(u8, status, "\"files\":2,\"pending\":1,\"truncated\":false,\"roots\":[{\"root_id\":\"school\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "vault") == null);
    const labelled = try expectOk(try index.run(indexStatus, "{\"principal_labels\":[\"adults\"]}", .{ .request_labels = true }));
    try std.testing.expect(std.mem.indexOf(u8, labelled, "\"files\":3,") != null);
}

test "S3-T4: evidence goes through the scope and names section, root and neighbours" {
    const index = try TestIndex.init();
    defer index.deinit();
    const documents = index.service.engine.documents;
    var spelling: ?usize = null;
    var dates: ?usize = null;
    var secret: ?usize = null;
    for (documents, 0..) |document, at| {
        if (std.mem.indexOf(u8, document.text, "harbour island") != null) spelling = at;
        if (std.mem.indexOf(u8, document.text, "count me in") != null) dates = at;
        if (std.mem.indexOf(u8, document.text, "harbour plans") != null) secret = at;
    }
    const a = index.arena_state.allocator();
    const request = try std.fmt.allocPrint(a, "{{\"ids\":[\"{s}\",\"{s}\",\"nope\"]}}", .{ documents[spelling.?].id, documents[secret.?].id });
    const text = try expectOk(try index.run(evidence, request, .{}));
    try std.testing.expect(std.mem.indexOf(u8, text, "\"root_id\":\"school\",\"section_path\":[\"Week 7\",\"Spelling\"],\"neighbours\":{\"prev\":") != null);
    const next = try std.fmt.allocPrint(a, "\"next\":{{\"chunk_id\":\"{s}\",\"start_line\":6,\"end_line\":7}}", .{documents[dates.?].id});
    try std.testing.expect(std.mem.indexOf(u8, text, next) != null);
    const hidden = try std.fmt.allocPrint(a, "{{\"chunk_id\":\"{s}\",\"found\":false}}", .{documents[secret.?].id});
    try std.testing.expect(std.mem.indexOf(u8, text, hidden) != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "{\"chunk_id\":\"nope\",\"found\":false}]"));
    // With the label, the hidden chunk is found; a root outside the scope hides it again.
    const seen = try std.fmt.allocPrint(a, "{{\"ids\":[\"{s}\"],\"principal_labels\":[\"adults\"]}}", .{documents[secret.?].id});
    try std.testing.expect(std.mem.indexOf(u8, try expectOk(try index.run(evidence, seen, .{ .request_labels = true })), "\"root_id\":\"vault\"") != null);
    const narrowed = try std.fmt.allocPrint(a, "{{\"ids\":[\"{s}\"],\"principal_labels\":[\"adults\"],\"roots\":[\"school\"]}}", .{documents[secret.?].id});
    try std.testing.expect(std.mem.indexOf(u8, try expectOk(try index.run(evidence, narrowed, .{ .request_labels = true })), "\"found\":false") != null);
    try expectRefused(try index.run(evidence, "{}", .{}), .invalid_argument, "ids is required");
    // The 5-or-more-ids path (a hash map) answers the same as the scan.
    const many = try std.fmt.allocPrint(a, "{{\"ids\":[\"{s}\",\"{s}\",\"{s}\",\"{s}\",\"{s}\"]}}", .{ documents[spelling.?].id, documents[secret.?].id, "x", "y", documents[dates.?].id });
    const many_text = try expectOk(try index.run(evidence, many, .{}));
    try std.testing.expect(std.mem.startsWith(u8, many_text, text[0 .. std.mem.indexOf(u8, text, "{\"chunk_id\":\"nope\"").?]));
}

test "S3-T4: apply options are strict" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const good = (try applyOptions(a, (try parseObject(a, "{\"allow_file_reads\":true,\"max_file_bytes\":5,\"keep_generations\":2,\"analyzer\":\"v1\"}")).ok)).ok;
    try std.testing.expect(good.allow_file_reads);
    try std.testing.expectEqual(@as(u64, 5), good.max_file_bytes);
    try std.testing.expectEqual(@as(?usize, 2), good.keep_generations);
    for ([_][]const u8{ "{\"bogus\":1}", "{\"allow_file_reads\":1}", "{\"keep_generations\":0}", "{\"analyzer\":\"v9\"}", "{\"max_chars\":0}" }) |bad| {
        try std.testing.expect((try applyOptions(a, (try parseObject(a, bad)).ok)) == .failed);
    }
    try std.testing.expect((try parseObject(a, "[]")) == .failed);
    try std.testing.expect((try parseObject(a, "{")) == .failed);
    try std.testing.expect((try parseObject(a, "")) == .ok);
}
