const hybrid = @import("hybrid.zig");
const lexical_segment = @import("lexical_segment.zig");
const manifest = @import("manifest.zig");
const postings = @import("postings.zig");
const publication = @import("publication.zig");
const segment = @import("segment.zig");
const std = @import("std");

pub const Evidence = struct {
    chunk_id: []const u8,
    path: []const u8,
    start_line: u32,
    end_line: u32,
    content: []const u8,
    fused_score: f32,
    lexical_score: f32,
    semantic_score: f32,
    lexical_rank: ?usize,
    semantic_rank: ?usize,
};

pub const Engine = struct {
    generation: u64,
    analyzer_id: []const u8,
    embedding_model_id: []const u8,
    vector_dimensions: usize,
    documents: []const hybrid.Document,
    lexical_index: postings.Index,

    pub fn open(
        snapshot: publication.LoadedSnapshot,
        document_output: []hybrid.Document,
        vector_output: []f32,
        term_output: []postings.TermEntry,
        posting_output: []postings.Posting,
        document_length_output: []u32,
    ) !Engine {
        try manifest.validateSnapshot(snapshot.metadata, snapshot.documents_encoded, snapshot.lexical_encoded);
        const documents = try segment.decode(snapshot.documents_encoded, document_output, vector_output);
        const lexical_index = try lexical_segment.decode(
            snapshot.lexical_encoded,
            term_output,
            posting_output,
            document_length_output,
        );
        if (documents.len != lexical_index.document_lengths.len) return error.DocumentCountMismatch;
        return .{
            .generation = snapshot.metadata.generation,
            .analyzer_id = snapshot.metadata.analyzer_id,
            .embedding_model_id = snapshot.metadata.embedding_model_id,
            .vector_dimensions = snapshot.metadata.vector_dimensions,
            .documents = documents,
            .lexical_index = lexical_index,
        };
    }

    pub fn query(
        engine: Engine,
        query_text: []const u8,
        query_vector: []const f32,
        lexical_score_output: []f32,
        result_output: []hybrid.Result,
        options: hybrid.SearchOptions,
    ) ![]hybrid.Result {
        const lexical_scores = try postings.scoreQuery(engine.lexical_index, query_text, lexical_score_output, options.bm25);
        return hybrid.searchWithLexicalScores(query_vector, engine.documents, lexical_scores, result_output, options);
    }

    pub fn evidence(engine: Engine, result: hybrid.Result) Evidence {
        std.debug.assert(result.document_index < engine.documents.len);
        const document = engine.documents[result.document_index];
        std.debug.assert(std.mem.eql(u8, document.id, result.document_id));
        return .{
            .chunk_id = document.id,
            .path = document.path,
            .start_line = document.start_line,
            .end_line = document.end_line,
            .content = document.text,
            .fused_score = result.fused_score,
            .lexical_score = result.lexical_score,
            .semantic_score = result.semantic_score,
            .lexical_rank = result.lexical_rank,
            .semantic_rank = result.semantic_rank,
        };
    }
};

test "published snapshot opens and returns cited hybrid evidence" {
    const documents = [_]hybrid.Document{
        .{ .id = "both", .text = "hybrid retrieval combines ranks", .vector = &.{ 0.8, 0.2 }, .path = "guides/hybrid.md", .start_line = 1, .end_line = 6 },
        .{ .id = "lexical", .text = "hybrid hybrid exact", .vector = &.{ 0, 1 }, .path = "guides/lexical.md", .start_line = 10, .end_line = 12 },
        .{ .id = "semantic", .text = "meaning based result", .vector = &.{ 1, 0 }, .path = "guides/semantic.md", .start_line = 20, .end_line = 22 },
    };
    var document_encoded_storage: [1024]u8 = undefined;
    const documents_encoded = try segment.encode(&documents, &document_encoded_storage);
    var source_terms: [24]postings.TermEntry = undefined;
    var source_postings: [32]postings.Posting = undefined;
    var source_lengths: [documents.len]u32 = undefined;
    var fills: [24]usize = undefined;
    const source_index = try postings.build(&documents, &source_terms, &source_postings, &source_lengths, &fills);
    var lexical_encoded_storage: [2048]u8 = undefined;
    const lexical_encoded = try lexical_segment.encode(source_index, &lexical_encoded_storage);
    const metadata = try manifest.create(
        1,
        "ascii-alnum-v1",
        "manual-test-vectors-v1",
        "documents-1.hybseg",
        "lexical-1.hyblex",
        documents_encoded,
        lexical_encoded,
    );
    var manifest_encoded_storage: [512]u8 = undefined;
    const manifest_encoded = try manifest.encode(metadata, &manifest_encoded_storage);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try publication.publish(tmp.dir, io, manifest_encoded, documents_encoded, lexical_encoded);
    var manifest_read: [512]u8 = undefined;
    var documents_read: [1024]u8 = undefined;
    var lexical_read: [2048]u8 = undefined;
    const snapshot = try publication.loadCurrent(tmp.dir, io, &manifest_read, &documents_read, &lexical_read);

    var decoded_documents: [documents.len]hybrid.Document = undefined;
    var vectors: [documents.len * 2]f32 = undefined;
    var terms: [24]postings.TermEntry = undefined;
    var posting_storage: [32]postings.Posting = undefined;
    var lengths: [documents.len]u32 = undefined;
    const opened = try Engine.open(snapshot, &decoded_documents, &vectors, &terms, &posting_storage, &lengths);
    var score_storage: [documents.len]f32 = undefined;
    var result_storage: [documents.len]hybrid.Result = undefined;
    const results = try opened.query("hybrid", &.{ 1, 0 }, &score_storage, &result_storage, .{});
    const evidence = opened.evidence(results[0]);

    try std.testing.expectEqual(@as(u64, 1), opened.generation);
    try std.testing.expectEqualStrings("both", evidence.chunk_id);
    try std.testing.expectEqualStrings("guides/hybrid.md", evidence.path);
    try std.testing.expectEqual(@as(u32, 1), evidence.start_line);
    try std.testing.expectEqual(@as(u32, 6), evidence.end_line);
    try std.testing.expectEqualStrings("hybrid retrieval combines ranks", evidence.content);
    try std.testing.expect(evidence.lexical_rank != null);
    try std.testing.expect(evidence.semantic_rank != null);
}

test "engine query exposes caller capacity errors" {
    const empty = Engine{
        .generation = 1,
        .analyzer_id = "ascii-v1",
        .embedding_model_id = "none",
        .vector_dimensions = 0,
        .documents = &.{},
        .lexical_index = .{
            .terms = &.{},
            .postings = &.{},
            .document_lengths = &.{},
            .average_document_length = 0,
        },
    };
    var no_scores: [0]f32 = .{};
    var no_results: [0]hybrid.Result = .{};
    const results = try empty.query("anything", &.{}, &no_scores, &no_results, .{});
    try std.testing.expectEqual(@as(usize, 0), results.len);
}
