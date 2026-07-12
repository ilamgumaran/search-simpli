const engine_module = @import("engine.zig");
const hybrid = @import("hybrid.zig");
const postings = @import("postings.zig");
const service_module = @import("service.zig");
const std = @import("std");

pub const Workspaces = struct {
    query_vector: []f32,
    lexical_scores: []f32,
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
        try handleSearch(service, id, params, workspaces, output);
    } else if (std.mem.eql(u8, method, "read_chunk")) {
        try handleRead(service, id, params, output);
    } else if (std.mem.eql(u8, method, "list_sources")) {
        try handleList(service, id, params, workspaces.sources, output);
    } else if (std.mem.eql(u8, method, "index_status")) {
        if (!onlyFields(params, &.{})) {
            try writeError(output, id, -32602, "Invalid params");
            return;
        }
        try writeStatus(output, id, service.indexStatus());
    } else {
        try writeError(output, id, -32601, "Method not found");
    }
}

fn handleSearch(
    service: service_module.Service,
    id: ?std.json.Value,
    params: std.json.ObjectMap,
    workspaces: Workspaces,
    output: *std.Io.Writer,
) !void {
    if (!onlyFields(params, &.{ "query", "query_vector", "top_k", "candidate_k", "path_prefix", "retrieval_mode", "principal_labels" })) {
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
    const principal_labels = parsePrincipalLabels(params.get("principal_labels"), &principal_label_storage) catch {
        try writeError(output, id, -32602, "Invalid params");
        return;
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
    const evidence = service.searchKnowledge(
        query,
        query_vector,
        .{
            .top_k = top_k,
            .candidate_k = candidate_k,
            .retrieval_mode = mode,
            .path_prefix = path_prefix,
            .principal_labels = principal_labels,
        },
        workspaces.lexical_scores,
        workspaces.results,
        workspaces.evidence,
    ) catch {
        try writeError(output, id, -32603, "Internal error");
        return;
    };
    try writeSearchResult(output, id, service, query, mode, principal_labels.len, evidence);
}

fn handleRead(
    service: service_module.Service,
    id: ?std.json.Value,
    params: std.json.ObjectMap,
    output: *std.Io.Writer,
) !void {
    if (!onlyFields(params, &.{ "chunk_id", "path_prefix", "principal_labels" })) {
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
    const principal_labels = parsePrincipalLabels(params.get("principal_labels"), &principal_label_storage) catch {
        try writeError(output, id, -32602, "Invalid params");
        return;
    };
    const chunk = service.readChunk(chunk_id, path_prefix, principal_labels) orelse {
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
    id: ?std.json.Value,
    params: std.json.ObjectMap,
    source_output: []service_module.Source,
    output: *std.Io.Writer,
) !void {
    if (!onlyFields(params, &.{ "path_prefix", "principal_labels" })) {
        try writeError(output, id, -32602, "Invalid params");
        return;
    }
    const path_prefix = optionalString(params.get("path_prefix")) catch {
        try writeError(output, id, -32602, "Invalid params");
        return;
    };
    var principal_label_storage: [64][]const u8 = undefined;
    const principal_labels = parsePrincipalLabels(params.get("principal_labels"), &principal_label_storage) catch {
        try writeError(output, id, -32602, "Invalid params");
        return;
    };
    const sources = service.listSources(path_prefix, principal_labels, source_output) catch {
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
    try json.endObject();
    try json.endObject();
}

fn writeStatus(output: *std.Io.Writer, id: ?std.json.Value, status: service_module.Status) !void {
    var json = std.json.Stringify{ .writer = output };
    try responseStart(&json, id);
    try json.objectField("result");
    try json.write(status);
    try json.endObject();
}

fn writeChunkFields(json: *std.json.Stringify, chunk: service_module.Chunk) !void {
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

fn parseMode(value: []const u8) ?hybrid.RetrievalMode {
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
    var scores: [documents.len]f32 = undefined;
    var results: [documents.len]hybrid.Result = undefined;
    var evidence: [documents.len]engine_module.Evidence = undefined;
    var sources: [documents.len]service_module.Source = undefined;
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try handleLine(
        service,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"search_knowledge\",\"params\":{\"query\":\"exact search\",\"retrieval_mode\":\"vector\",\"path_prefix\":\"public/\",\"query_vector\":[1,0],\"top_k\":1}}",
        std.testing.allocator,
        .{ .query_vector = &query_vector, .lexical_scores = &scores, .results = &results, .evidence = &evidence, .sources = &sources },
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
    var scores: [1]f32 = undefined;
    var results: [1]hybrid.Result = undefined;
    var evidence: [1]engine_module.Evidence = undefined;
    var sources: [1]service_module.Source = undefined;
    const workspaces = Workspaces{ .query_vector = &vector, .lexical_scores = &scores, .results = &results, .evidence = &evidence, .sources = &sources };

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
    var no_scores: [0]f32 = .{};
    var no_results: [0]hybrid.Result = .{};
    var no_evidence: [0]engine_module.Evidence = .{};
    var no_sources: [0]service_module.Source = .{};
    const workspaces = Workspaces{ .query_vector = &no_vectors, .lexical_scores = &no_scores, .results = &no_results, .evidence = &no_evidence, .sources = &no_sources };
    var parse_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer parse_output.deinit();
    try handleLine(service, "not-json", std.testing.allocator, workspaces, &parse_output.writer);
    try std.testing.expect(std.mem.indexOf(u8, parse_output.written(), "-32700") != null);

    var status_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer status_output.deinit();
    try handleLine(service, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"index_status\",\"params\":{}}", std.testing.allocator, workspaces, &status_output.writer);
    try std.testing.expect(std.mem.indexOf(u8, status_output.written(), "\"generation\":4") != null);
}
