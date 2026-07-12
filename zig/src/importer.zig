const analysis = @import("analysis.zig");
const engine_module = @import("engine.zig");
const hybrid = @import("hybrid.zig");
const lexical_segment = @import("lexical_segment.zig");
const lifecycle = @import("lifecycle.zig");
const manifest = @import("manifest.zig");
const postings = @import("postings.zig");
const publication = @import("publication.zig");
const segment = @import("segment.zig");
const std = @import("std");

pub const format_version: u16 = 1;
pub const analyzer_id = "ascii-alnum-v1";

const ImportDocument = struct {
    id: []const u8,
    path: []const u8,
    start_line: u32,
    end_line: u32,
    text: []const u8,
    vector: []const f32,
    required_labels: []const []const u8 = &.{},
};

const ImportPayload = struct {
    format_version: u16,
    generation: u64,
    analyzer_id: []const u8,
    embedding_model_id: []const u8,
    documents: []const ImportDocument,
};

pub const Report = struct {
    generation: u64,
    documents: usize,
    terms: usize,
    postings: usize,
    vector_dimensions: usize,
};

pub fn importJson(
    dir: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,
    json_bytes: []const u8,
) !Report {
    var parsed = try std.json.parseFromSlice(ImportPayload, allocator, json_bytes, .{});
    defer parsed.deinit();
    const payload = parsed.value;
    if (payload.format_version != format_version) return error.UnsupportedInterchangeVersion;
    if (!std.mem.eql(u8, payload.analyzer_id, analyzer_id)) return error.UnsupportedAnalyzer;
    if (payload.generation == 0) return error.GenerationZero;
    if (payload.embedding_model_id.len == 0) return error.InvalidEmbeddingModel;

    const documents = try allocator.alloc(hybrid.Document, payload.documents.len);
    defer allocator.free(documents);
    const label_buffers = try allocator.alloc([]u8, payload.documents.len);
    defer allocator.free(label_buffers);
    var allocated_label_buffers: usize = 0;
    defer for (label_buffers[0..allocated_label_buffers]) |buffer| allocator.free(buffer);
    var vector_dimensions: usize = 0;
    var total_tokens: usize = 0;
    for (payload.documents, documents, 0..) |source, *document, document_index| {
        if (source.id.len == 0 or source.path.len == 0) return error.InvalidDocument;
        if (source.vector.len != 0) {
            if (vector_dimensions == 0) vector_dimensions = source.vector.len;
            if (source.vector.len != vector_dimensions) return error.VectorDimensionsInconsistent;
        }
        total_tokens = std.math.add(usize, total_tokens, analysis.tokenCount(source.text)) catch
            return error.IndexTooLarge;
        const required_labels = try packRequiredLabels(allocator, source.required_labels);
        label_buffers[document_index] = required_labels;
        allocated_label_buffers += 1;
        document.* = .{
            .id = source.id,
            .path = source.path,
            .start_line = source.start_line,
            .end_line = source.end_line,
            .text = source.text,
            .vector = source.vector,
            .required_labels = required_labels,
        };
    }
    if ((vector_dimensions == 0) != std.mem.eql(u8, payload.embedding_model_id, "none")) {
        return error.EmbeddingMetadataMismatch;
    }

    const document_encoded_length = try segment.encodedLength(documents);
    const document_encoded_storage = try allocator.alloc(u8, document_encoded_length);
    defer allocator.free(document_encoded_storage);
    const documents_encoded = try segment.encode(documents, document_encoded_storage);

    const terms = try allocator.alloc(postings.TermEntry, total_tokens);
    defer allocator.free(terms);
    const posting_storage = try allocator.alloc(postings.Posting, total_tokens);
    defer allocator.free(posting_storage);
    const document_lengths = try allocator.alloc(u32, documents.len);
    defer allocator.free(document_lengths);
    const posting_fills = try allocator.alloc(usize, total_tokens);
    defer allocator.free(posting_fills);
    const lexical_index = try postings.build(
        documents,
        terms,
        posting_storage,
        document_lengths,
        posting_fills,
    );

    const lexical_encoded_length = try lexical_segment.encodedLength(lexical_index);
    const lexical_encoded_storage = try allocator.alloc(u8, lexical_encoded_length);
    defer allocator.free(lexical_encoded_storage);
    const lexical_encoded = try lexical_segment.encode(lexical_index, lexical_encoded_storage);

    const documents_file = try std.fmt.allocPrint(allocator, "documents-{d}.hybseg", .{payload.generation});
    defer allocator.free(documents_file);
    const lexical_file = try std.fmt.allocPrint(allocator, "lexical-{d}.hyblex", .{payload.generation});
    defer allocator.free(lexical_file);
    const metadata = try manifest.create(
        payload.generation,
        payload.analyzer_id,
        payload.embedding_model_id,
        documents_file,
        lexical_file,
        documents_encoded,
        lexical_encoded,
    );
    const manifest_encoded_length = try manifest.encodedLength(metadata);
    const manifest_encoded_storage = try allocator.alloc(u8, manifest_encoded_length);
    defer allocator.free(manifest_encoded_storage);
    const manifest_encoded = try manifest.encode(metadata, manifest_encoded_storage);
    try lifecycle.publishSerialized(dir, io, manifest_encoded, documents_encoded, lexical_encoded);

    return .{
        .generation = payload.generation,
        .documents = documents.len,
        .terms = lexical_index.terms.len,
        .postings = lexical_index.postings.len,
        .vector_dimensions = vector_dimensions,
    };
}

fn packRequiredLabels(allocator: std.mem.Allocator, source: []const []const u8) ![]u8 {
    if (source.len > 64) return error.TooManyRequiredLabels;
    const labels = try allocator.dupe([]const u8, source);
    defer allocator.free(labels);
    var index: usize = 1;
    while (index < labels.len) : (index += 1) {
        const value = labels[index];
        var insertion = index;
        while (insertion > 0 and std.mem.order(u8, value, labels[insertion - 1]) == .lt) : (insertion -= 1) {
            labels[insertion] = labels[insertion - 1];
        }
        labels[insertion] = value;
    }
    var total: usize = if (labels.len == 0) 0 else labels.len - 1;
    for (labels, 0..) |label, label_index| {
        if (label.len == 0 or label.len > 256 or std.mem.indexOfAny(u8, label, "\x00\r\n") != null) {
            return error.InvalidRequiredLabel;
        }
        if (label_index > 0 and std.mem.eql(u8, labels[label_index - 1], label)) {
            return error.DuplicateRequiredLabel;
        }
        total = std.math.add(usize, total, label.len) catch return error.IndexTooLarge;
    }
    const output = try allocator.alloc(u8, total);
    var offset: usize = 0;
    for (labels, 0..) |label, label_index| {
        if (label_index > 0) {
            output[offset] = '\n';
            offset += 1;
        }
        @memcpy(output[offset .. offset + label.len], label);
        offset += label.len;
    }
    return output;
}

test "interchange imports into a published queryable snapshot" {
    const json =
        \\{"format_version":1,"generation":4,"analyzer_id":"ascii-alnum-v1","embedding_model_id":"semantic-test-v1","documents":[
        \\{"id":"both","path":"guides/hybrid.md","start_line":1,"end_line":3,"text":"hybrid retrieval combines ranks","vector":[1,0],"required_labels":["tenant:acme","group:search"]},
        \\{"id":"lexical","path":"guides/lexical.md","start_line":5,"end_line":6,"text":"hybrid hybrid exact","vector":[0,1],"required_labels":[]}
        \\]}
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const report = try importJson(tmp.dir, io, std.testing.allocator, json);
    try std.testing.expectEqual(@as(u64, 4), report.generation);
    try std.testing.expectEqual(@as(usize, 2), report.documents);
    try std.testing.expectEqual(@as(usize, 2), report.vector_dimensions);

    var manifest_read: [512]u8 = undefined;
    var document_read: [1024]u8 = undefined;
    var lexical_read: [2048]u8 = undefined;
    const snapshot = try publication.loadCurrent(tmp.dir, io, &manifest_read, &document_read, &lexical_read);
    var documents: [2]hybrid.Document = undefined;
    var vectors: [4]f32 = undefined;
    var terms: [16]postings.TermEntry = undefined;
    var posting_values: [24]postings.Posting = undefined;
    var lengths: [2]u32 = undefined;
    const engine = try engine_module.Engine.open(snapshot, &documents, &vectors, &terms, &posting_values, &lengths);
    var scores: [2]f32 = undefined;
    var results: [2]hybrid.Result = undefined;
    const anonymous = try engine.query("hybrid", &.{ 1, 0 }, &scores, &results, .{ .candidate_k = 2 });
    try std.testing.expectEqualStrings("guides/lexical.md", engine.evidence(anonymous[0]).path);
    const ranked = try engine.query("hybrid", &.{ 1, 0 }, &scores, &results, .{
        .candidate_k = 2,
        .principal_labels = &.{ "group:search", "tenant:acme" },
    });
    const evidence = engine.evidence(ranked[0]);
    try std.testing.expectEqualStrings("guides/hybrid.md", evidence.path);
    try std.testing.expectEqualStrings("group:search\ntenant:acme", engine.documents[0].required_labels);
}

test "interchange rejects analyzer and vector metadata mismatches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try std.testing.expectError(error.UnsupportedAnalyzer, importJson(
        tmp.dir,
        io,
        std.testing.allocator,
        "{\"format_version\":1,\"generation\":1,\"analyzer_id\":\"other\",\"embedding_model_id\":\"none\",\"documents\":[]}",
    ));
    try std.testing.expectError(error.VectorDimensionsInconsistent, importJson(
        tmp.dir,
        io,
        std.testing.allocator,
        "{\"format_version\":1,\"generation\":1,\"analyzer_id\":\"ascii-alnum-v1\",\"embedding_model_id\":\"model\",\"documents\":[{\"id\":\"a\",\"path\":\"a.md\",\"start_line\":1,\"end_line\":1,\"text\":\"a\",\"vector\":[1,0]},{\"id\":\"b\",\"path\":\"b.md\",\"start_line\":1,\"end_line\":1,\"text\":\"b\",\"vector\":[1]}]}",
    ));
    try std.testing.expectError(error.DuplicateRequiredLabel, importJson(
        tmp.dir,
        io,
        std.testing.allocator,
        "{\"format_version\":1,\"generation\":1,\"analyzer_id\":\"ascii-alnum-v1\",\"embedding_model_id\":\"none\",\"documents\":[{\"id\":\"a\",\"path\":\"a.md\",\"start_line\":1,\"end_line\":1,\"text\":\"a\",\"vector\":[],\"required_labels\":[\"tenant:a\",\"tenant:a\"]}]}",
    ));
}
