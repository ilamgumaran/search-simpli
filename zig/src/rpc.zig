const engine_module = @import("engine.zig");
const hybrid = @import("hybrid.zig");
const postings = @import("postings.zig");
const report = @import("report.zig");
const scoring = @import("scoring.zig");
const service_module = @import("service.zig");
const ops = @import("ops.zig");
const apply = @import("apply.zig");
const scope = @import("scope.zig");
const snapshot_open = @import("snapshot_open.zig");
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

/// S3-T6: the scratch now lives with the operations (`ops.Workspaces`).
pub const Workspaces = ops.Workspaces;

/// S4-T6: one opened generation and the arena that holds everything its
/// open decoded. The arena is on the heap and never moves:
/// `snapshot_open.openScoped` keeps `arena.allocator()`, a pointer to this
/// arena, in the generation's `scope.Loads`, and the lazy loads (the source
/// section, the statistics groups, the position tables, the filename
/// sections) allocate through it for as long as the generation is served.
/// Before S4-T6 the server moved the arena by value into its own field and
/// freed the place it had been opened in, so every lazy load after an
/// `apply_changes` called through a freed `ArenaAllocator` (a crash in a
/// release build, `docs/tasks/S4-T6.md`). `close` releases the generation's
/// files and its memory; nothing of it may be used afterwards.
pub const Generation = struct {
    arena: *std.heap.ArenaAllocator,
    service: service_module.Service,
    workspaces: Workspaces,

    /// Open the current generation in `path`; everything from a new arena
    /// over `gpa`.
    pub fn open(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Generation {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(gpa);
        errdefer {
            arena.deinit();
            gpa.destroy(arena);
        }
        const a = arena.allocator();
        var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
        defer dir.close(io);
        const opened = try snapshot_open.openScoped(a, io, dir);
        errdefer opened.folder.close();
        const count = opened.engine.documents.len;
        return .{
            .arena = arena,
            .service = .{ .engine = opened.engine, .folder = opened.folder },
            .workspaces = .{
                .query_vector = try a.alloc(f32, opened.engine.vector_dimensions),
                .results = try a.alloc(hybrid.Result, count),
                .evidence = try a.alloc(engine_module.Evidence, count),
                .sources = try a.alloc(service_module.Source, count),
            },
        };
    }

    /// Release the files the open kept (the source and filename sections)
    /// and the arena.
    pub fn close(generation: Generation, gpa: std.mem.Allocator) void {
        if (generation.service.folder) |folder| folder.close();
        generation.arena.deinit();
        gpa.destroy(generation.arena);
    }
};

/// S4-T6: `searchd serve`'s state (stdio and `--http`): the server's scope
/// and permissions and the served generation. A request that publishes
/// (`apply_changes`) is answered from the old generation; then `reload`
/// opens the new one and closes the old one, so no `scope.Loads` of a closed
/// generation stays reachable.
pub const Served = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    server: Server,
    generation: Generation,

    pub fn open(gpa: std.mem.Allocator, io: std.Io, path: []const u8, server: Server) !Served {
        return .{ .gpa = gpa, .io = io, .path = path, .server = server, .generation = try Generation.open(gpa, io, path) };
    }

    /// Answer one request line; reload after a successful `apply_changes`.
    pub fn handle(served: *Served, line: []const u8, output: *std.Io.Writer) !void {
        var request_arena = std.heap.ArenaAllocator.init(served.gpa);
        defer request_arena.deinit();
        served.server.reopen = false;
        try handleLineWith(served.generation.service, &served.server, line, request_arena.allocator(), served.generation.workspaces, output);
        if (served.server.reopen) try served.reload();
    }

    /// The old generation stays served until the new one is open; a failed
    /// open leaves it served and returns the error.
    pub fn reload(served: *Served) !void {
        const next = try Generation.open(served.gpa, served.io, served.path);
        served.generation.close(served.gpa);
        served.generation = next;
    }

    pub fn close(served: *Served) void {
        served.generation.close(served.gpa);
    }
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
    caller_allocator: std.mem.Allocator,
    workspaces: Workspaces,
    output: *std.Io.Writer,
) !void {
    // The operations (`ops.zig`) allocate from an arena released here.
    var arena_state = std.heap.ArenaAllocator.init(caller_allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
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

    // S3-T6: CAP-13's operations answer through `ops.zig`, as the folder
    // methods do, so the MCP server shares every byte of their results.
    if (std.mem.eql(u8, method, "search_knowledge")) {
        try writeFallible(output, id, ops.searchKnowledge(allocator, service, params, server.caller, workspaces));
    } else if (std.mem.eql(u8, method, "read_chunk")) {
        try writeOperation(output, id, try ops.readChunk(allocator, service, params, server.caller));
    } else if (std.mem.eql(u8, method, "list_sources")) {
        try writeFallible(output, id, ops.listSources(allocator, service, params, server.caller, workspaces));
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

/// An operation that can fail inside the engine: "Internal error" (-32603).
fn writeFallible(output: *std.Io.Writer, id: ?std.json.Value, outcome: ops.OperationError!ops.Result) !void {
    const result = outcome catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.OperationFailed => return writeError(output, id, -32603, "Internal error"),
    };
    try writeOperation(output, id, result);
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
    const result = ops.applyChanges(allocator, gio, dir, request_json, .{ .allow_file_reads = server.allow_file_reads, .write_roots = server.caller.roots, .write_labels = if (server.caller.roots != null or server.caller.labels.len != 0) server.caller.labels else null }) catch |err| {
        var buffer: [256]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "Internal error: {s}", .{@errorName(err)}) catch "Internal error";
        try writeError(output, id, if (err == error.WriterBusy) -32006 else -32603, if (err == error.WriterBusy) "Writer busy: another writer holds WRITER.LOCK" else message);
        return;
    };
    if (result == .ok) server.reopen = true;
    try writeOperation(output, id, result);
}

/// The `result` value of a `search_knowledge` JSON-RPC response on a service
/// without scope data, shared with the C ABI (`abi.zig`'s `ss_query`) so it
/// emits byte-identical JSON for the same query (`ops.writeSearchResult`).
pub fn writeSearchResultValue(
    json: *std.json.Stringify,
    service: service_module.Service,
    query: []const u8,
    mode: hybrid.RetrievalMode,
    principal_label_count: usize,
    evidence: []const engine_module.Evidence,
) !void {
    return ops.writeSearchResult(json, service, query, mode, principal_label_count, evidence, null, null);
}

/// `writeSearchResultValue` plus, when `extras` is set (the C ABI, S2-T4), the
/// `warnings`, `request` and optional `profile` fields appended last. The C
/// ABI does not add S3-T6's folder fields (`ops.FolderFields`): its
/// contract-2.0.0 output is unchanged.
pub fn writeSearchResultValueWith(
    json: *std.json.Stringify,
    service: service_module.Service,
    query: []const u8,
    mode: hybrid.RetrievalMode,
    principal_label_count: usize,
    evidence: []const engine_module.Evidence,
    extras: ?report.Extras,
) !void {
    return ops.writeSearchResult(json, service, query, mode, principal_label_count, evidence, extras, null);
}

fn writeStatus(output: *std.Io.Writer, id: ?std.json.Value, status: service_module.Status) !void {
    var json = std.json.Stringify{ .writer = output };
    try responseStart(&json, id);
    try json.objectField("result");
    try json.write(status);
    try json.endObject();
}

/// The fields of one chunk (chunk_id, citation, content), shared by
/// `read_chunk` and the C ABI's `ss_evidence` (`ops.writeChunkFields`).
pub fn writeChunkFields(json: *std.json.Stringify, chunk: service_module.Chunk) !void {
    return ops.writeChunkFields(json, chunk);
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

/// Shared with the C ABI (`abi.zig`) so `ss_query`'s `retrieval_mode` option
/// accepts exactly the same three strings as `search_knowledge`.
pub fn parseMode(value: []const u8) ?hybrid.RetrievalMode {
    return ops.parseRetrievalMode(value);
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
