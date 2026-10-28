const engine_module = @import("engine.zig");
const filename_field = @import("filename_field.zig");
const hybrid = @import("hybrid.zig");
const std = @import("std");

/// Serialize the result object shared by the new filename search modes in
/// JSON-RPC, the native CLI and the C ABI. The caller owns the outer transport
/// envelope (JSON-RPC adds `jsonrpc` and `id`).
pub fn writeEvidence(
    output: *std.Io.Writer,
    allocator: std.mem.Allocator,
    engine: engine_module.Engine,
    query: []const u8,
    field: filename_field.Field,
    options: hybrid.SearchOptions,
    hits: []const filename_field.Hit,
    human_readable: bool,
) !void {
    if (human_readable) return writeHuman(output, allocator, engine, query, hits);
    return writeEvidenceInternal(output, allocator, engine, query, field, options, hits, false);
}

/// ABI form of the same result. The ABI contract appends `warnings` and
/// `request` to every query result; filename diagnostics are not computed, so
/// the warning list is always empty and scoped to this mode.
pub fn writeAbiEvidence(
    output: *std.Io.Writer,
    allocator: std.mem.Allocator,
    engine: engine_module.Engine,
    query: []const u8,
    field: filename_field.Field,
    options: hybrid.SearchOptions,
    hits: []const filename_field.Hit,
) !void {
    return writeEvidenceInternal(output, allocator, engine, query, field, options, hits, true);
}

fn writeEvidenceInternal(
    output: *std.Io.Writer,
    allocator: std.mem.Allocator,
    engine: engine_module.Engine,
    query: []const u8,
    field: filename_field.Field,
    options: hybrid.SearchOptions,
    hits: []const filename_field.Hit,
    abi_report: bool,
) !void {
    const query_terms = try filename_field.tokenize(allocator, engine.analyzer_id, query);
    var json = std.json.Stringify{ .writer = output };
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
    try json.write(engine.generation);
    try json.objectField("analyzer_id");
    try json.write(engine.analyzer_id);
    try json.objectField("embedding_model_id");
    try json.write(engine.embedding_model_id);
    try json.endObject();
    try json.objectField("retrieval");
    try json.beginObject();
    try json.objectField("mode");
    try json.write("lexical");
    try json.objectField("vector_dimensions");
    try json.write(engine.vector_dimensions);
    try json.objectField("authorization");
    try json.beginObject();
    try json.objectField("semantics");
    try json.write("all-required-labels-v1");
    try json.objectField("principal_label_count");
    try json.write(options.principal_labels.len);
    try json.endObject();
    try json.objectField("search_field");
    try json.write(@tagName(field));
    try json.objectField("candidate_k");
    try json.write(options.candidate_k);
    try json.objectField("filename_policy_id");
    try json.write(filename_field.policy_id);
    try json.endObject();
    try json.objectField("results");
    try json.beginArray();
    for (hits) |hit| {
        if (hit.document_index >= engine.documents.len) return error.InvalidFilenameHit;
        const document = engine.documents[hit.document_index];
        const matched_body = hit.body_rank != null;
        const matched_filename = hit.filename_rank != null;
        try json.beginObject();
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
        try json.objectField("score");
        try json.write(hit.fused_score);
        try json.objectField("matched_in");
        try json.beginArray();
        if (matched_body) try json.write("content");
        if (matched_filename) try json.write("filename");
        try json.endArray();
        try json.objectField("basename");
        try json.write(basename(document.path));
        try json.objectField("match_sections");
        try json.beginObject();
        try json.objectField("filename");
        try writeSection(&json, allocator, engine.analyzer_id, query_terms, "File name", basename(document.path), filenameStem(document.path), document.path, null);
        try json.objectField("content");
        try writeSection(&json, allocator, engine.analyzer_id, query_terms, "Content", document.text, document.text, document.path, .{ .start_line = document.start_line, .end_line = document.end_line });
        try json.endObject();
        try json.objectField("ranking");
        try json.beginObject();
        try json.objectField("lexical");
        try json.beginObject();
        try json.objectField("rank");
        try json.write(hit.body_rank);
        try json.objectField("score");
        try json.write(hit.body_score);
        try json.endObject();
        try json.objectField("filename");
        try json.beginObject();
        try json.objectField("rank");
        try json.write(hit.filename_rank);
        try json.objectField("score");
        try json.write(hit.filename_score);
        try json.endObject();
        try json.objectField("vector");
        try json.write(.{ .rank = @as(?usize, null), .score = @as(?f32, null), .mode = "none" });
        try json.endObject();
        try json.endObject();
    }
    try json.endArray();
    try json.objectField("answer_policy");
    try json.write(.{
        .ground_in_results = true,
        .cite_path_and_lines = true,
        .say_when_evidence_is_insufficient = true,
        .filename_matches_are_navigation = true,
    });
    if (abi_report) {
        try json.objectField("warnings");
        try json.beginArray();
        try json.endArray();
        try json.objectField("request");
        try json.write(.{
            .analyzer_id = engine.analyzer_id,
            .retrieval_mode = "lexical",
            .top_k = options.top_k,
            .candidate_k = options.candidate_k,
            .path_prefix = options.path_prefix,
            .search_field = @tagName(field),
        });
    }
    try json.endObject();
}

const LineCitation = struct { start_line: u32, end_line: u32 };

fn termPresent(tokens: []const []const u8, term: []const u8) bool {
    for (tokens) |token| if (std.mem.eql(u8, token, term)) return true;
    return false;
}

fn writeSection(
    json: *std.json.Stringify,
    allocator: std.mem.Allocator,
    analyzer_id: []const u8,
    query_terms: []const []const u8,
    label: []const u8,
    source: []const u8,
    analyzer_source: []const u8,
    path: []const u8,
    lines: ?LineCitation,
) !void {
    const source_terms = try filename_field.tokenize(allocator, analyzer_id, analyzer_source);
    try json.beginObject();
    try json.objectField("label");
    try json.write(label);
    try json.objectField("matched");
    var matched = false;
    for (query_terms) |term| if (termPresent(source_terms, term)) {
        matched = true;
        break;
    };
    try json.write(matched);
    try json.objectField("matched_terms");
    try json.beginArray();
    for (query_terms, 0..) |term, i| {
        var duplicate = false;
        for (query_terms[0..i]) |prior| if (std.mem.eql(u8, prior, term)) {
            duplicate = true;
            break;
        };
        if (!duplicate and termPresent(source_terms, term)) try json.write(term);
    }
    try json.endArray();
    try json.objectField("text");
    try json.write(source);
    try json.objectField("citation");
    try json.beginObject();
    try json.objectField("path");
    try json.write(path);
    if (lines) |citation| {
        try json.objectField("field");
        try json.write("content");
        try json.objectField("start_line");
        try json.write(citation.start_line);
        try json.objectField("end_line");
        try json.write(citation.end_line);
    } else {
        try json.objectField("field");
        try json.write("filename");
    }
    try json.endObject();
    try json.endObject();
}

fn writeHuman(
    output: *std.Io.Writer,
    allocator: std.mem.Allocator,
    engine: engine_module.Engine,
    query: []const u8,
    hits: []const filename_field.Hit,
) !void {
    const query_terms = try filename_field.tokenize(allocator, engine.analyzer_id, query);
    try output.print("query: {s} (analyzer={s})\n", .{ query, engine.analyzer_id });
    for (hits, 0..) |hit, i| {
        if (hit.document_index >= engine.documents.len) return error.InvalidFilenameHit;
        const document = engine.documents[hit.document_index];
        try output.print("{d}. {s}\n", .{ i + 1, document.path });
        try writeHumanSection(output, allocator, engine.analyzer_id, query_terms, "File name", basename(document.path), filenameStem(document.path), document.path, null);
        try writeHumanSection(output, allocator, engine.analyzer_id, query_terms, "Content", document.text, document.text, document.path, .{ .start_line = document.start_line, .end_line = document.end_line });
    }
}

fn writeHumanSection(
    output: *std.Io.Writer,
    allocator: std.mem.Allocator,
    analyzer_id: []const u8,
    query_terms: []const []const u8,
    label: []const u8,
    source: []const u8,
    analyzer_source: []const u8,
    path: []const u8,
    lines: ?LineCitation,
) !void {
    const source_terms = try filename_field.tokenize(allocator, analyzer_id, analyzer_source);
    var matched = false;
    try output.print("   {s}: ", .{label});
    for (query_terms) |term| if (termPresent(source_terms, term)) {
        matched = true;
        break;
    };
    try output.writeAll(if (matched) "MATCH\n" else "no match\n");
    try output.writeAll("     matched terms: ");
    var first = true;
    for (query_terms, 0..) |term, i| {
        var duplicate = false;
        for (query_terms[0..i]) |prior| if (std.mem.eql(u8, prior, term)) {
            duplicate = true;
            break;
        };
        if (!duplicate and termPresent(source_terms, term)) {
            if (!first) try output.writeAll(", ");
            try output.writeAll(term);
            first = false;
        }
    }
    if (first) try output.writeAll("(none)");
    try output.writeByte('\n');
    if (lines) |citation| {
        try output.print("     citation: {s}:{d}-{d}\n", .{ path, citation.start_line, citation.end_line });
        try output.print("     text: {s}\n", .{source});
    } else {
        try output.print("     citation: {s} (filename)\n", .{path});
        try output.print("     text: {s}\n", .{source});
    }
}

fn basename(path: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else path;
}

fn filenameStem(path: []const u8) []const u8 {
    const name = basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    return name[0..dot];
}

test "filename results expose source-based match sections and readable citations" {
    const allocator = std.testing.allocator;
    const docs = [_]hybrid.Document{.{
        .id = "chunk-1",
        .path = "docs/Annual_Report.md",
        .text = "The budget grew.",
        .start_line = 8,
        .end_line = 10,
    }};
    const engine = engine_module.Engine{
        .generation = 3,
        .analyzer_id = @import("analyzer_v2.zig").analyzer_id,
        .embedding_model_id = "none",
        .vector_dimensions = 0,
        .documents = &docs,
        .lexical_index = .{ .terms = &.{}, .postings = &.{}, .document_lengths = &.{}, .average_document_length = 0 },
    };
    const hits = [_]filename_field.Hit{.{
        .document_index = 0,
        .body_rank = 1,
        .filename_rank = 1,
        .fused_score = 0.5,
    }};
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeEvidence(&out.writer, arena_state.allocator(), engine, "annual budget missing md", .both, .{ .top_k = 1, .candidate_k = 1, .retrieval_mode = .lexical }, &hits, false);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out.written(), .{});
    defer parsed.deinit();
    const sections = parsed.value.object.get("results").?.array.items[0].object.get("match_sections").?.object;
    const filename = sections.get("filename").?.object;
    try std.testing.expect(filename.get("matched").?.bool);
    try std.testing.expectEqualStrings("Annual_Report.md", filename.get("text").?.string);
    const filename_terms = filename.get("matched_terms").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), filename_terms.len);
    try std.testing.expectEqualStrings("annual", filename_terms[0].string);
    const filename_citation = filename.get("citation").?.object;
    try std.testing.expectEqualStrings("filename", filename_citation.get("field").?.string);
    try std.testing.expect(filename_citation.get("start_line") == null);
    const content = sections.get("content").?.object;
    try std.testing.expect(content.get("matched").?.bool);
    try std.testing.expectEqualStrings("The budget grew.", content.get("text").?.string);
    try std.testing.expectEqualStrings("budget", content.get("matched_terms").?.array.items[0].string);
    const content_citation = content.get("citation").?.object;
    try std.testing.expectEqualStrings("content", content_citation.get("field").?.string);
    try std.testing.expectEqual(@as(i64, 8), content_citation.get("start_line").?.integer);
    try std.testing.expectEqual(@as(i64, 10), content_citation.get("end_line").?.integer);

    var human: std.Io.Writer.Allocating = .init(allocator);
    defer human.deinit();
    try writeEvidence(&human.writer, arena_state.allocator(), engine, "annual budget missing md", .both, .{ .top_k = 1, .candidate_k = 1, .retrieval_mode = .lexical }, &hits, true);
    try std.testing.expect(std.mem.indexOf(u8, human.written(), "File name: MATCH") != null);
    try std.testing.expect(std.mem.indexOf(u8, human.written(), "Content: MATCH") != null);
    try std.testing.expect(std.mem.indexOf(u8, human.written(), "docs/Annual_Report.md:8-10") != null);
    try std.testing.expect(std.mem.indexOf(u8, human.written(), "text: The budget grew.") != null);
}
