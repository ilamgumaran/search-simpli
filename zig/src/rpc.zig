const engine_module = @import("engine.zig");
const hybrid = @import("hybrid.zig");
const postings = @import("postings.zig");
const report = @import("report.zig");
const scoring = @import("scoring.zig");
const service_module = @import("service.zig");
const ops = @import("ops.zig");
const apply = @import("apply.zig");
const scope = @import("scope.zig");
const std = @import("std");

/// S3-T4: what `searchd serve` was started with. The scope comes from the
/// command line (`--roots`, `--labels`): a request may narrow the roots but
/// never widen them. Without `--labels` the raw service keeps accepting a
/// request's `principal_labels` (bounded as before); with it, a request that
/// states them is refused. `apply_changes` exists only with `--allow-write`
/// (`--allow-file-reads` lets its `file` changes be read).
pub const Server = struct {
    caller: ops.Caller = .{ .request_labels = true },
    allow_write: bool = false,
    allow_file_reads: bool = false,
    /// The served index directory (`apply_changes` publishes into it).
    dir_path: ?[]const u8 = null,
    io: ?std.Io = null,
    /// Set by a successful `apply_changes`: the caller reopens the index so
    /// the next request reads the new generation.
    reopen: bool = false,
};

pub const Workspaces = struct {
    query_vector: []f32,
    results: []hybrid.Result,
    evidence: []engine_module.Evidence,
    sources: []service_module.Source,
};

pub fn handleLine(
    service: service_module.Service,
    line: []const u8,
    allocator: std.mem.Allocator,
    workspaces: Workspaces,
    output: *std.Io.Writer,
) !void {
    var server = Server{};
    return handleLineWith(service, &server, line, allocator, workspaces, output);
}

/// `handleLine` for a server started with a scope and write permissions.
pub fn handleLineWith(
    service: service_module.Service,
    server: *Server,
    line: []const u8,
    allocator: std.mem.Allocator,
    workspaces: Workspaces,
    output: *std.Io.Writer,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            try writeError(output, null, -32700, "Parse error");
            return;
        },
    };
    defer parsed.deinit();

    const request = switch (parsed.value) {
        .object => |object| object,
        else => {
            try writeError(output, null, -32600, "Invalid Request");
            return;
        },
    };
    const id = request.get("id");
    if (id == null or !validId(id.?)) {
        try writeError(output, null, -32600, "Invalid Request");
        return;
    }
    const jsonrpc = valueString(request.get("jsonrpc")) orelse {
        try writeError(output, id, -32600, "Invalid Request");
        return;
    };
    const method = valueString(request.get("method")) orelse {
        try writeError(output, id, -32600, "Invalid Request");
        return;
    };
    if (!std.mem.eql(u8, jsonrpc, "2.0")) {
        try writeError(output, id, -32600, "Invalid Request");
        return;
    }
    const params = paramsObject(request.get("params")) orelse {
        try writeError(output, id, -32602, "Invalid params");
        return;
    };

    if (std.mem.eql(u8, method, "search_knowledge")) {
        try handleSearch(service, server.*, allocator, id, params, workspaces, output);
    } else if (std.mem.eql(u8, method, "read_chunk")) {
        try handleRead(service, server.*, allocator, id, params, output);
    } else if (std.mem.eql(u8, method, "list_sources")) {
        try handleList(service, server.*, allocator, id, params, workspaces.sources, output);
    } else if (std.mem.eql(u8, method, "index_status")) {
        if (service.folder == null) {
            if (!onlyFields(params, &.{})) {
                try writeError(output, id, -32602, "Invalid params");
                return;
            }
            try writeStatus(output, id, service.indexStatus());
            return;
        }
        try writeOperation(output, id, try ops.indexStatus(allocator, service, params, server.caller));
    } else if (std.mem.eql(u8, method, "find")) {
        try runOperation(service, server.*, allocator, id, params, output, ops.find);
    } else if (std.mem.eql(u8, method, "outline")) {
        try runOperation(service, server.*, allocator, id, params, output, ops.outline);
    } else if (std.mem.eql(u8, method, "read_span")) {
        try runOperation(service, server.*, allocator, id, params, output, ops.readSpan);
    } else if (std.mem.eql(u8, method, "list_files")) {
        try runOperation(service, server.*, allocator, id, params, output, ops.listFiles);
    } else if (std.mem.eql(u8, method, "roots")) {
        try runOperation(service, server.*, allocator, id, params, output, ops.visibleRoots);
    } else if (std.mem.eql(u8, method, "apply_changes") and server.allow_write) {
        try handleApply(server, allocator, id, parsed.value.object.get("params"), output);
    } else {
        // `apply_changes` without `--allow-write` does not exist.
        try writeError(output, id, -32601, "Method not found");
    }
}

/// S3-T4: the folder-knowledge read methods (`ops.zig`).
fn runOperation(
    service: service_module.Service,
    server: Server,
    allocator: std.mem.Allocator,
    id: ?std.json.Value,
    params: std.json.ObjectMap,
    output: *std.Io.Writer,
    comptime operation: anytype,
) !void {
    if (service.folder == null) {
        try writeError(output, id, -32603, "Internal error");
        return;
    }
    try writeOperation(output, id, try operation(allocator, service, params, server.caller));
}

/// The JSON-RPC error code of a core refusal (`docs/tool-protocol.md`).
pub fn errorCodeOf(code: ops.Code) i32 {
    return switch (code) {
        .invalid_argument => -32602,
        .not_found => -32004,
        .capacity => -32005,
    };
}

fn writeOperation(output: *std.Io.Writer, id: ?std.json.Value, result: ops.Result) !void {
    switch (result) {
        .failed => |failure| {
            var buffer: [1024]u8 = undefined;
            const message = if (failure.code == .invalid_argument)
                std.fmt.bufPrint(&buffer, "Invalid params: {s}", .{failure.message}) catch failure.message
            else
                failure.message;
            try writeError(output, id, errorCodeOf(failure.code), message);
        },
        .ok => |json_text| {
            var json = std.json.Stringify{ .writer = output };
            try responseStart(&json, id);
            try json.objectField("result");
            try json.beginWriteRaw();
            try output.writeAll(json_text);
            json.endWriteRaw();
            try json.endObject();
        },
    }
}

/// `apply_changes` (only with `serve --allow-write`): the params object is
/// the change request itself (implementation section 6).
fn handleApply(server: *Server, allocator: std.mem.Allocator, id: ?std.json.Value, params: ?std.json.Value, output: *std.Io.Writer) !void {
    const value = params orelse {
        try writeError(output, id, -32602, "Invalid params: apply_changes needs the change request as params");
        return;
    };
    const request_json = try std.json.Stringify.valueAlloc(allocator, value, .{});
    const gio = server.io orelse {
        try writeError(output, id, -32603, "Internal error");
        return;
    };
    var dir = std.Io.Dir.cwd().openDir(gio, server.dir_path orelse ".", .{ .iterate = true }) catch {
        try writeError(output, id, -32603, "Internal error");
        return;
    };
    defer dir.close(gio);
    const result = ops.applyChanges(allocator, gio, dir, request_json, .{ .allow_file_reads = server.allow_file_reads }) catch |err| {
        var buffer: [256]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "Internal error: {s}", .{@errorName(err)}) catch "Internal error";
        try writeError(output, id, if (err == error.WriterBusy) -32006 else -32603, if (err == error.WriterBusy) "Writer busy: another writer holds WRITER.LOCK" else message);
        return;
    };
    if (result == .ok) server.reopen = true;
    try writeOperation(output, id, result);
}

/// The request's scope over the server's: `roots` narrows; labels from the
/// request only when the raw service allows it. Null roots = every root.
const RequestScope = struct { request: scope.Request, scoped: bool };

fn requestScope(server: Server, params: std.json.ObjectMap, labels: []const []const u8, allocator: std.mem.Allocator) error{ InvalidRoots, OutOfMemory }!RequestScope {
    var named: ?[]const []const u8 = null;
    if (params.get("roots")) |value| switch (value) {
        .null => {},
        .array => |array| {
            if (array.items.len > ops.max_named_roots) return error.InvalidRoots;
            const list = try allocator.alloc([]const u8, array.items.len);
            for (array.items, list) |item, *slot| slot.* = switch (item) {
                .string => |text| if (text.len == 0) return error.InvalidRoots else text,
                else => return error.InvalidRoots,
            };
            named = list;
        },
        else => return error.InvalidRoots,
    };
    var roots: ?[]const []const u8 = null;
    if (server.caller.roots != null or named != null) {
        const want = named orelse server.caller.roots.?;
        var kept = std.ArrayList([]const u8).empty;
        for (want) |root_id| {
            const allowed = if (server.caller.roots) |bound| for (bound) |b| {
                if (std.mem.eql(u8, b, root_id)) break true;
            } else false else true;
            if (allowed) try kept.append(allocator, root_id);
        }
        roots = kept.items;
    }
    return .{ .request = .{ .roots = roots, .principal_labels = labels }, .scoped = roots != null };
}

/// The labels a request runs with: its own `principal_labels` (bounded as
/// before) when the server allows it, else the server's `--labels`.
fn requestLabels(server: Server, params: std.json.ObjectMap, storage: [][]const u8) error{InvalidLabels}![]const []const u8 {
    if (params.get("principal_labels")) |value| {
        if (!server.caller.request_labels) return error.InvalidLabels;
        return parsePrincipalLabels(value, storage);
    }
    return server.caller.labels;
}

fn handleSearch(
    service: service_module.Service,
    server: Server,
    allocator: std.mem.Allocator,
    id: ?std.json.Value,
    params: std.json.ObjectMap,
    workspaces: Workspaces,
    output: *std.Io.Writer,
) !void {
    if (!onlyFields(params, &.{ "query", "query_vector", "top_k", "candidate_k", "path_prefix", "retrieval_mode", "principal_labels", "roots" })) {
        try writeError(output, id, -32602, "Invalid params");
        return;
    }
    const query = valueString(params.get("query")) orelse {
        try writeError(output, id, -32602, "Invalid params");
        return;
    };
    if (query.len == 0) {
        try writeError(output, id, -32602, "Invalid params");
        return;
    }
    // S2-T11: same rejection as `ss_query` and the CLI; never reaches analysis.
    engine_module.Engine.validateQueryText(query) catch {
        try writeError(output, id, -32602, "Invalid params: query is not valid UTF-8");
        return;
    };
    const top_k = optionalPositiveInteger(params.get("top_k"), 5) orelse {
        try writeError(output, id, -32602, "Invalid params");
        return;
    };
    if (top_k > 100) {
        try writeError(output, id, -32602, "Invalid params");
        return;
    }
    const candidate_k = optionalPositiveInteger(params.get("candidate_k"), 100) orelse {
        try writeError(output, id, -32602, "Invalid params");
        return;
    };
    if (candidate_k > 10_000 or candidate_k < top_k) {
        try writeError(output, id, -32602, "Invalid params");
        return;
    }
    const path_prefix = optionalString(params.get("path_prefix")) catch {
        try writeError(output, id, -32602, "Invalid params");
        return;
    };
    const mode_text = optionalString(params.get("retrieval_mode")) catch {
        try writeError(output, id, -32602, "Invalid params");
        return;
    };
    const mode = parseMode(mode_text orelse "hybrid") orelse {
        try writeError(output, id, -32602, "Invalid params");
        return;
    };
    var principal_label_storage: [64][]const u8 = undefined;
    const principal_labels = requestLabels(server, params, &principal_label_storage) catch {
        try writeError(output, id, -32602, "Invalid params");
        return;
    };
    const request_scope = requestScope(server, params, principal_labels, allocator) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            try writeError(output, id, -32602, "Invalid params");
            return;
        },
    };
    const query_vector = parseQueryVector(
        params.get("query_vector"),
        service.engine.vector_dimensions,
        mode,
        workspaces.query_vector,
    ) catch {
        try writeError(output, id, -32602, "Invalid params");
        return;
    };
    const search_options = hybrid.SearchOptions{
        .top_k = top_k,
        .candidate_k = candidate_k,
        .retrieval_mode = mode,
        .path_prefix = path_prefix,
        .principal_labels = principal_labels,
    };
    // S3-T4: a request (or server) that names roots goes through the scope;
    // otherwise the v1 path, unchanged (labels already filter it there).
    const found = if (request_scope.scoped and service.folder != null)
        (service_module.ScopedService{ .service = service }).searchKnowledge(allocator, query, query_vector, search_options, request_scope.request, workspaces.results, workspaces.evidence, null)
    else
        service.searchKnowledge(allocator, query, query_vector, search_options, workspaces.results, workspaces.evidence);
    const evidence = found catch {
        try writeError(output, id, -32603, "Internal error");
        return;
    };
    try writeSearchResult(output, id, service, query, mode, principal_labels.len, evidence);
}

fn handleRead(
    service: service_module.Service,
    server: Server,
    allocator: std.mem.Allocator,
    id: ?std.json.Value,
    params: std.json.ObjectMap,
    output: *std.Io.Writer,
) !void {
    if (!onlyFields(params, &.{ "chunk_id", "path_prefix", "principal_labels", "roots" })) {
        try writeError(output, id, -32602, "Invalid params");
        return;
    }
    const chunk_id = valueString(params.get("chunk_id")) orelse {
        try writeError(output, id, -32602, "Invalid params");
        return;
    };
    const path_prefix = optionalString(params.get("path_prefix")) catch {
        try writeError(output, id, -32602, "Invalid params");
        return;
    };
    var principal_label_storage: [64][]const u8 = undefined;
    const principal_labels = requestLabels(server, params, &principal_label_storage) catch {
        try writeError(output, id, -32602, "Invalid params");
        return;
    };
    const request_scope = requestScope(server, params, principal_labels, allocator) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            try writeError(output, id, -32602, "Invalid params");
            return;
        },
    };
    // S3-T4 (S3-T3 finding 2): the read by chunk id goes through the scope.
    const read = if (service.folder != null)
        try (service_module.ScopedService{ .service = service }).readChunk(allocator, chunk_id, path_prefix, request_scope.request)
    else
        service.readChunk(chunk_id, path_prefix, principal_labels);
    const chunk = read orelse {
        try writeError(output, id, -32004, "Chunk not found");
        return;
    };
    var json = std.json.Stringify{ .writer = output };
    try responseStart(&json, id);
    try json.objectField("result");
    try json.beginObject();
    try writeChunkFields(&json, chunk);
    try json.endObject();
    try json.endObject();
}

fn handleList(
    service: service_module.Service,
    server: Server,
    allocator: std.mem.Allocator,
    id: ?std.json.Value,
    params: std.json.ObjectMap,
    source_output: []service_module.Source,
    output: *std.Io.Writer,
) !void {
    if (!onlyFields(params, &.{ "path_prefix", "principal_labels", "roots" })) {
        try writeError(output, id, -32602, "Invalid params");
        return;
    }
    const path_prefix = optionalString(params.get("path_prefix")) catch {
        try writeError(output, id, -32602, "Invalid params");
        return;
    };
    var principal_label_storage: [64][]const u8 = undefined;
    const principal_labels = requestLabels(server, params, &principal_label_storage) catch {
        try writeError(output, id, -32602, "Invalid params");
        return;
    };
    const request_scope = requestScope(server, params, principal_labels, allocator) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            try writeError(output, id, -32602, "Invalid params");
            return;
        },
    };
    const listed = if (service.folder != null)
        (service_module.ScopedService{ .service = service }).listSources(allocator, path_prefix, request_scope.request)
    else
        service.listSources(path_prefix, principal_labels, source_output);
    const sources = listed catch {
        try writeError(output, id, -32603, "Internal error");
        return;
    };
    var json = std.json.Stringify{ .writer = output };
    try responseStart(&json, id);
    try json.objectField("result");
    try json.beginObject();
    try json.objectField("sources");
    try json.beginArray();
    for (sources) |source| {
        try json.beginObject();
        try json.objectField("path");
        try json.write(source.path);
        try json.objectField("chunks");
        try json.write(source.chunks);
        try json.endObject();
    }
    try json.endArray();
    try json.objectField("count");
    try json.write(sources.len);
    try json.endObject();
    try json.endObject();
}

fn writeSearchResult(
    output: *std.Io.Writer,
    id: ?std.json.Value,
    service: service_module.Service,
    query: []const u8,
    mode: hybrid.RetrievalMode,
    principal_label_count: usize,
    evidence: []const engine_module.Evidence,
) !void {
    var json = std.json.Stringify{ .writer = output };
    try responseStart(&json, id);
    try json.objectField("result");
    try writeSearchResultValue(&json, service, query, mode, principal_label_count, evidence);
    try json.endObject();
}

/// The `result` value of a `search_knowledge` JSON-RPC response, factored out
/// so the C ABI (`abi.zig`'s `ss_query`) emits byte-identical JSON for the
/// same query without duplicating the field layout.
pub fn writeSearchResultValue(
    json: *std.json.Stringify,
    service: service_module.Service,
    query: []const u8,
    mode: hybrid.RetrievalMode,
    principal_label_count: usize,
    evidence: []const engine_module.Evidence,
) !void {
    return writeSearchResultValueWith(json, service, query, mode, principal_label_count, evidence, null);
}

/// `writeSearchResultValue` plus, when `extras` is set (the C ABI, S2-T4), the
/// `warnings`, `request` and optional `profile` fields appended last. JSON-RPC
/// passes `null`, so its output is unchanged.
pub fn writeSearchResultValueWith(
    json: *std.json.Stringify,
    service: service_module.Service,
    query: []const u8,
    mode: hybrid.RetrievalMode,
    principal_label_count: usize,
    evidence: []const engine_module.Evidence,
    extras: ?report.Extras,
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
    for (evidence) |item| {
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
        try json.endObject();
    }
    try json.endArray();
    try json.objectField("answer_policy");
    try json.write(.{
        .ground_in_results = true,
        .cite_path_and_lines = true,
        .say_when_evidence_is_insufficient = true,
    });
    if (tail) |e| try report.write(json, e);
    try json.endObject();
}

fn writeStatus(output: *std.Io.Writer, id: ?std.json.Value, status: service_module.Status) !void {
    var json = std.json.Stringify{ .writer = output };
    try responseStart(&json, id);
    try json.objectField("result");
    try json.write(status);
    try json.endObject();
}

/// The fields of one chunk (chunk_id, citation, content), factored out so the
/// C ABI's `ss_evidence` shares this exact field layout with `read_chunk`.
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

fn responseStart(json: *std.json.Stringify, id: ?std.json.Value) !void {
    try json.beginObject();
    try json.objectField("jsonrpc");
    try json.write("2.0");
    try json.objectField("id");
    if (id) |value| try json.write(value) else try json.write(null);
}

fn writeError(output: *std.Io.Writer, id: ?std.json.Value, code: i32, message: []const u8) !void {
    var json = std.json.Stringify{ .writer = output };
    try responseStart(&json, id);
    try json.objectField("error");
    try json.write(.{ .code = code, .message = message });
    try json.endObject();
}

fn paramsObject(value: ?std.json.Value) ?std.json.ObjectMap {
    if (value == null) return .empty;
    return switch (value.?) {
        .object => |object| object,
        else => null,
    };
}

fn valueString(value: ?std.json.Value) ?[]const u8 {
    if (value == null) return null;
    return switch (value.?) {
        .string => |string| string,
        else => null,
    };
}

fn optionalString(value: ?std.json.Value) error{InvalidType}!?[]const u8 {
    if (value == null or value.? == .null) return null;
    return valueString(value) orelse error.InvalidType;
}

fn optionalPositiveInteger(value: ?std.json.Value, default: usize) ?usize {
    if (value == null) return default;
    return switch (value.?) {
        .integer => |integer| if (integer > 0) @intCast(integer) else null,
        else => null,
    };
}

fn parsePrincipalLabels(
    value: ?std.json.Value,
    output: [][]const u8,
) error{InvalidLabels}![]const []const u8 {
    if (value == null or value.? == .null) return &.{};
    const items = switch (value.?) {
        .array => |array| array.items,
        else => return error.InvalidLabels,
    };
    if (items.len > output.len) return error.InvalidLabels;
    const labels = output[0..items.len];
    for (items, labels, 0..) |item, *target, index| {
        const label = switch (item) {
            .string => |string| string,
            else => return error.InvalidLabels,
        };
        if (label.len == 0 or label.len > 256 or std.mem.indexOfAny(u8, label, "\x00\r\n") != null) {
            return error.InvalidLabels;
        }
        for (labels[0..index]) |existing| {
            if (std.mem.eql(u8, existing, label)) return error.InvalidLabels;
        }
        target.* = label;
    }
    return labels;
}

/// Shared with the C ABI (`abi.zig`) so `ss_query`'s `retrieval_mode` option
/// accepts exactly the same three strings as `search_knowledge`.
pub fn parseMode(value: []const u8) ?hybrid.RetrievalMode {
    if (std.mem.eql(u8, value, "lexical")) return .lexical;
    if (std.mem.eql(u8, value, "vector")) return .vector;
    if (std.mem.eql(u8, value, "hybrid")) return .hybrid;
    return null;
}

fn parseQueryVector(
    value: ?std.json.Value,
    dimensions: usize,
    mode: hybrid.RetrievalMode,
    output: []f32,
) error{InvalidVector}![]const f32 {
    if (mode == .lexical) return &.{};
    if (dimensions == 0) return &.{};
    if (output.len < dimensions) return error.InvalidVector;
    const array = if (value) |present| switch (present) {
        .array => |array| array.items,
        else => return error.InvalidVector,
    } else return error.InvalidVector;
    if (array.len != dimensions) return error.InvalidVector;
    for (array, output[0..dimensions]) |item, *target| {
        const number: f64 = switch (item) {
            .integer => |integer| @floatFromInt(integer),
            .float => |float| float,
            else => return error.InvalidVector,
        };
        target.* = @floatCast(number);
        if (!std.math.isFinite(target.*)) return error.InvalidVector;
    }
    // S2-T13: same rule as `ss_query`: the L2 norm must be a finite f32.
    if (!scoring.isValidVector(output[0..dimensions])) return error.InvalidVector;
    return output[0..dimensions];
}

fn validId(value: std.json.Value) bool {
    return switch (value) {
        .null, .integer, .string => true,
        else => false,
    };
}

fn onlyFields(object: std.json.ObjectMap, allowed: []const []const u8) bool {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        var found = false;
        for (allowed) |name| {
            if (std.mem.eql(u8, entry.key_ptr.*, name)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

test "JSON RPC search returns scoped cited evidence" {
    const documents = [_]hybrid.Document{
        .{ .id = "public-lexical", .text = "exact search phrase", .vector = &.{ 0, 1 }, .path = "public/a.md", .start_line = 1, .end_line = 2 },
        .{ .id = "public-vector", .text = "different wording", .vector = &.{ 1, 0 }, .path = "public/b.md", .start_line = 3, .end_line = 4 },
        .{ .id = "private", .text = "exact search phrase private", .vector = &.{ 1, 0 }, .path = "private/secret.md", .start_line = 1, .end_line = 1 },
    };
    var terms: [16]postings.TermEntry = undefined;
    var posting_storage: [24]postings.Posting = undefined;
    var lengths: [documents.len]u32 = undefined;
    var fills: [16]usize = undefined;
    const index = try postings.build(&documents, &terms, &posting_storage, &lengths, &fills);
    const service = service_module.Service{ .engine = .{
        .generation = 9,
        .analyzer_id = "ascii-v1",
        .embedding_model_id = "manual-v1",
        .vector_dimensions = 2,
        .documents = &documents,
        .lexical_index = index,
    } };
    var query_vector: [2]f32 = undefined;
    var results: [documents.len]hybrid.Result = undefined;
    var evidence: [documents.len]engine_module.Evidence = undefined;
    var sources: [documents.len]service_module.Source = undefined;
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try handleLine(
        service,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"search_knowledge\",\"params\":{\"query\":\"exact search\",\"retrieval_mode\":\"vector\",\"path_prefix\":\"public/\",\"query_vector\":[1,0],\"top_k\":1}}",
        std.testing.allocator,
        .{ .query_vector = &query_vector, .results = &results, .evidence = &evidence, .sources = &sources },
        &output.writer,
    );
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output.written(), .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    const first = result.get("results").?.array.items[0].object;
    try std.testing.expectEqualStrings("public-vector", first.get("chunk_id").?.string);
    try std.testing.expectEqualStrings("public/b.md", first.get("citation").?.object.get("path").?.string);
}

test "JSON RPC validates vectors methods scoped reads and principal labels" {
    const documents = [_]hybrid.Document{.{ .id = "private", .text = "secret", .vector = &.{ 1, 0 }, .path = "private/secret.md", .start_line = 1, .end_line = 1, .required_labels = "tenant:acme" }};
    var terms: [4]postings.TermEntry = undefined;
    var posting_storage: [4]postings.Posting = undefined;
    var lengths: [1]u32 = undefined;
    var fills: [4]usize = undefined;
    const index = try postings.build(&documents, &terms, &posting_storage, &lengths, &fills);
    const service = service_module.Service{ .engine = .{
        .generation = 1,
        .analyzer_id = "ascii-v1",
        .embedding_model_id = "manual-v1",
        .vector_dimensions = 2,
        .documents = &documents,
        .lexical_index = index,
    } };
    var vector: [2]f32 = undefined;
    var results: [1]hybrid.Result = undefined;
    var evidence: [1]engine_module.Evidence = undefined;
    var sources: [1]service_module.Source = undefined;
    const workspaces = Workspaces{ .query_vector = &vector, .results = &results, .evidence = &evidence, .sources = &sources };

    var missing_vector_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer missing_vector_output.deinit();
    try handleLine(service, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"search_knowledge\",\"params\":{\"query\":\"secret\"}}", std.testing.allocator, workspaces, &missing_vector_output.writer);
    try std.testing.expect(std.mem.indexOf(u8, missing_vector_output.written(), "-32602") != null);

    var invalid_candidate_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer invalid_candidate_output.deinit();
    try handleLine(service, "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"search_knowledge\",\"params\":{\"query\":\"secret\",\"retrieval_mode\":\"lexical\",\"top_k\":2,\"candidate_k\":1}}", std.testing.allocator, workspaces, &invalid_candidate_output.writer);
    try std.testing.expect(std.mem.indexOf(u8, invalid_candidate_output.written(), "-32602") != null);

    var scoped_read_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer scoped_read_output.deinit();
    try handleLine(service, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"read_chunk\",\"params\":{\"chunk_id\":\"private\",\"path_prefix\":\"public/\"}}", std.testing.allocator, workspaces, &scoped_read_output.writer);
    try std.testing.expect(std.mem.indexOf(u8, scoped_read_output.written(), "-32004") != null);

    var denied_read_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer denied_read_output.deinit();
    try handleLine(service, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"read_chunk\",\"params\":{\"chunk_id\":\"private\"}}", std.testing.allocator, workspaces, &denied_read_output.writer);
    try std.testing.expect(std.mem.indexOf(u8, denied_read_output.written(), "-32004") != null);

    var allowed_read_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer allowed_read_output.deinit();
    try handleLine(service, "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"read_chunk\",\"params\":{\"chunk_id\":\"private\",\"principal_labels\":[\"tenant:acme\"]}}", std.testing.allocator, workspaces, &allowed_read_output.writer);
    try std.testing.expect(std.mem.indexOf(u8, allowed_read_output.written(), "\"content\":\"secret\"") != null);

    var denied_search_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer denied_search_output.deinit();
    try handleLine(service, "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"search_knowledge\",\"params\":{\"query\":\"secret\",\"retrieval_mode\":\"lexical\"}}", std.testing.allocator, workspaces, &denied_search_output.writer);
    try std.testing.expect(std.mem.indexOf(u8, denied_search_output.written(), "\"results\":[]") != null);

    var allowed_search_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer allowed_search_output.deinit();
    try handleLine(service, "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"search_knowledge\",\"params\":{\"query\":\"secret\",\"retrieval_mode\":\"lexical\",\"principal_labels\":[\"tenant:acme\"]}}", std.testing.allocator, workspaces, &allowed_search_output.writer);
    try std.testing.expect(std.mem.indexOf(u8, allowed_search_output.written(), "\"chunk_id\":\"private\"") != null);

    var invalid_labels_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer invalid_labels_output.deinit();
    try handleLine(service, "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"list_sources\",\"params\":{\"principal_labels\":[\"tenant:acme\",\"tenant:acme\"]}}", std.testing.allocator, workspaces, &invalid_labels_output.writer);
    try std.testing.expect(std.mem.indexOf(u8, invalid_labels_output.written(), "-32602") != null);

    var unknown_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer unknown_output.deinit();
    try handleLine(service, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"read_file\",\"params\":{}}", std.testing.allocator, workspaces, &unknown_output.writer);
    try std.testing.expect(std.mem.indexOf(u8, unknown_output.written(), "-32601") != null);
}

test "JSON RPC returns parse errors and status" {
    const service = service_module.Service{ .engine = .{
        .generation = 4,
        .analyzer_id = "ascii-v1",
        .embedding_model_id = "none",
        .vector_dimensions = 0,
        .documents = &.{},
        .lexical_index = .{ .terms = &.{}, .postings = &.{}, .document_lengths = &.{}, .average_document_length = 0 },
    } };
    var no_vectors: [0]f32 = .{};
    var no_results: [0]hybrid.Result = .{};
    var no_evidence: [0]engine_module.Evidence = .{};
    var no_sources: [0]service_module.Source = .{};
    const workspaces = Workspaces{ .query_vector = &no_vectors, .results = &no_results, .evidence = &no_evidence, .sources = &no_sources };
    var parse_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer parse_output.deinit();
    try handleLine(service, "not-json", std.testing.allocator, workspaces, &parse_output.writer);
    try std.testing.expect(std.mem.indexOf(u8, parse_output.written(), "-32700") != null);

    var status_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer status_output.deinit();
    try handleLine(service, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"index_status\",\"params\":{}}", std.testing.allocator, workspaces, &status_output.writer);
    try std.testing.expect(std.mem.indexOf(u8, status_output.written(), "\"generation\":4") != null);
}

test "S3-T4: the RPC folder methods, the command-line scope and apply_changes gating" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const request =
        \\{"roots":[{"root_id":"school","kind":"host"},{"root_id":"vault","kind":"host","required_labels":["adults"]}],
        \\"changes":[{"op":"add","root_id":"school","path":"week.md","content_base64":"IyBXZWVrCgp0aWRlIHRhYmxlCg=="},
        \\{"op":"add","root_id":"vault","path":"plan.md","content_base64":"IyBQbGFuCgp0aWRlIHNlY3JldAo="}]}
    ;
    _ = (try apply.applyChanges(a, io, tmp.dir, request, .{})).ok;
    const opened = try @import("snapshot_open.zig").openScoped(a, io, tmp.dir);
    const service = service_module.Service{ .engine = opened.engine, .folder = opened.folder };
    const count = service.engine.documents.len;
    const workspaces = Workspaces{
        .query_vector = &.{},
        .results = try a.alloc(hybrid.Result, count),
        .evidence = try a.alloc(engine_module.Evidence, count),
        .sources = try a.alloc(service_module.Source, count),
    };
    const Call = struct {
        fn run(svc: service_module.Service, server: *Server, ws: Workspaces, allocator: std.mem.Allocator, line: []const u8) ![]const u8 {
            var out: std.Io.Writer.Allocating = .init(allocator);
            try handleLineWith(svc, server, line, allocator, ws, &out.writer);
            return out.written();
        }
    };
    var raw = Server{};
    // Each new method answers with the canonical result.
    for ([_][]const u8{ "find", "roots", "list_files" }) |method| {
        const line = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{s}\",\"params\":{s}}}", .{ method, if (std.mem.eql(u8, method, "find")) "{\"query\":\"tide\"}" else "{}" });
        const answer = try Call.run(service, &raw, workspaces, a, line);
        try std.testing.expect(std.mem.startsWith(u8, answer, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"request\":"));
        try std.testing.expect(std.mem.indexOf(u8, answer, "vault") == null);
    }
    const span = try Call.run(service, &raw, workspaces, a, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"read_span\",\"params\":{\"root_id\":\"school\",\"path\":\"week.md\",\"start_line\":3,\"end_line\":3}}");
    try std.testing.expect(std.mem.indexOf(u8, span, "\"text\":\"tide table\\n\"") != null);
    const missing = try Call.run(service, &raw, workspaces, a, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"outline\",\"params\":{\"root_id\":\"vault\",\"path\":\"plan.md\"}}");
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":3,\"error\":{\"code\":-32004,\"message\":\"not indexed or not retained: vault/plan.md\"}}", missing);
    // The raw service keeps request labels; the scoped status counts them.
    const labelled = try Call.run(service, &raw, workspaces, a, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"index_status\",\"params\":{\"principal_labels\":[\"adults\"]}}");
    try std.testing.expect(std.mem.indexOf(u8, labelled, "\"files\":2,") != null);
    const plain = try Call.run(service, &raw, workspaces, a, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"index_status\",\"params\":{}}");
    try std.testing.expect(std.mem.indexOf(u8, plain, "\"documents\":1,") != null);
    // apply_changes does not exist without --allow-write.
    const refused = try Call.run(service, &raw, workspaces, a, "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"apply_changes\",\"params\":{\"changes\":[]}}");
    try std.testing.expect(std.mem.indexOf(u8, refused, "-32601") != null);
    try std.testing.expect(!raw.reopen);
    // --labels: the server's; a request stating labels is refused.
    var scoped = Server{ .caller = .{ .labels = &.{"adults"}, .roots = &.{"vault"} } };
    const vault = try Call.run(service, &scoped, workspaces, a, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"find\",\"params\":{\"query\":\"tide\",\"roots\":[\"school\",\"vault\"]}}");
    try std.testing.expect(std.mem.indexOf(u8, vault, "\"scope\":{\"roots\":[\"vault\"]") != null);
    const forged = try Call.run(service, &scoped, workspaces, a, "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"read_chunk\",\"params\":{\"chunk_id\":\"x\",\"principal_labels\":[]}}");
    try std.testing.expect(std.mem.indexOf(u8, forged, "-32602") != null);
    const hidden_search = try Call.run(service, &scoped, workspaces, a, "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"search_knowledge\",\"params\":{\"query\":\"tide\",\"retrieval_mode\":\"lexical\"}}");
    try std.testing.expect(std.mem.indexOf(u8, hidden_search, "vault/plan.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, hidden_search, "school/week.md") == null);
    // With --allow-write: published, and the caller is told to reopen.
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var writer = Server{ .allow_write = true, .dir_path = path, .io = io };
    const applied = try Call.run(service, &writer, workspaces, a, "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"apply_changes\",\"params\":{\"expect_generation\":1,\"changes\":[{\"op\":\"remove\",\"root_id\":\"school\",\"path\":\"week.md\"}]}}");
    try std.testing.expect(std.mem.indexOf(u8, applied, "\"result\":{\"generation\":2,") != null);
    try std.testing.expect(writer.reopen);
}
