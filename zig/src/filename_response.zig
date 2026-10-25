const engine_module = @import("engine.zig");
const filename_field = @import("filename_field.zig");
const hybrid = @import("hybrid.zig");
const std = @import("std");

/// Serialize the result object shared by the new filename search modes in
/// JSON-RPC, the native CLI and the C ABI. The caller owns the outer transport
/// envelope (JSON-RPC adds `jsonrpc` and `id`).
pub fn writeEvidence(
    output: *std.Io.Writer,
    engine: engine_module.Engine,
    query: []const u8,
    field: filename_field.Field,
    options: hybrid.SearchOptions,
    hits: []const filename_field.Hit,
) !void {
    return writeEvidenceInternal(output, engine, query, field, options, hits, false);
}

/// ABI form of the same result. The ABI contract appends `warnings` and
/// `request` to every query result; filename diagnostics are not computed, so
/// the warning list is always empty and scoped to this mode.
pub fn writeAbiEvidence(
    output: *std.Io.Writer,
    engine: engine_module.Engine,
    query: []const u8,
    field: filename_field.Field,
    options: hybrid.SearchOptions,
    hits: []const filename_field.Hit,
) !void {
    return writeEvidenceInternal(output, engine, query, field, options, hits, true);
}

fn writeEvidenceInternal(
    output: *std.Io.Writer,
    engine: engine_module.Engine,
    query: []const u8,
    field: filename_field.Field,
    options: hybrid.SearchOptions,
    hits: []const filename_field.Hit,
    abi_report: bool,
) !void {
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

fn basename(path: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else path;
}
