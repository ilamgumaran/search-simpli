const engine_module = @import("engine.zig");
const hybrid = @import("hybrid.zig");
const std = @import("std");

pub const Chunk = struct {
    chunk_id: []const u8,
    path: []const u8,
    start_line: u32,
    end_line: u32,
    content: []const u8,
};

pub const Source = struct {
    path: []const u8,
    chunks: usize,
};

pub const Status = struct {
    ready: bool,
    generation: u64,
    analyzer_id: []const u8,
    embedding_model_id: []const u8,
    vector_dimensions: usize,
    documents: usize,
    terms: usize,
    postings: usize,
};

pub const ServiceError = error{
    EvidenceCapacityTooSmall,
    SourceCapacityTooSmall,
};

pub const Service = struct {
    engine: engine_module.Engine,

    pub fn searchKnowledge(
        service: Service,
        query_text: []const u8,
        query_vector: []const f32,
        options: hybrid.SearchOptions,
        lexical_score_output: []f32,
        result_output: []hybrid.Result,
        evidence_output: []engine_module.Evidence,
    ) ![]engine_module.Evidence {
        const results = try service.engine.query(
            query_text,
            query_vector,
            lexical_score_output,
            result_output,
            options,
        );
        if (evidence_output.len < results.len) return error.EvidenceCapacityTooSmall;
        for (results, evidence_output[0..results.len]) |result, *evidence| {
            evidence.* = service.engine.evidence(result);
        }
        return evidence_output[0..results.len];
    }

    pub fn readChunk(
        service: Service,
        chunk_id: []const u8,
        path_prefix: ?[]const u8,
        principal_labels: []const []const u8,
    ) ?Chunk {
        for (service.engine.documents) |document| {
            if (!std.mem.eql(u8, document.id, chunk_id)) continue;
            if (path_prefix) |prefix| {
                if (!std.mem.startsWith(u8, document.path, prefix)) return null;
            }
            if (!hybrid.isAuthorized(document.required_labels, principal_labels)) return null;
            return .{
                .chunk_id = document.id,
                .path = document.path,
                .start_line = document.start_line,
                .end_line = document.end_line,
                .content = document.text,
            };
        }
        return null;
    }

    pub fn listSources(
        service: Service,
        path_prefix: ?[]const u8,
        principal_labels: []const []const u8,
        source_output: []Source,
    ) ServiceError![]Source {
        var count: usize = 0;
        for (service.engine.documents) |document| {
            if (document.path.len == 0) continue;
            if (path_prefix) |prefix| {
                if (!std.mem.startsWith(u8, document.path, prefix)) continue;
            }
            if (!hybrid.isAuthorized(document.required_labels, principal_labels)) continue;
            var existing: ?usize = null;
            for (source_output[0..count], 0..) |source, index| {
                if (std.mem.eql(u8, source.path, document.path)) {
                    existing = index;
                    break;
                }
            }
            if (existing) |index| {
                source_output[index].chunks += 1;
            } else {
                if (count >= source_output.len) return error.SourceCapacityTooSmall;
                source_output[count] = .{ .path = document.path, .chunks = 1 };
                count += 1;
            }
        }
        sortSources(source_output[0..count]);
        return source_output[0..count];
    }

    pub fn indexStatus(service: Service) Status {
        return .{
            .ready = true,
            .generation = service.engine.generation,
            .analyzer_id = service.engine.analyzer_id,
            .embedding_model_id = service.engine.embedding_model_id,
            .vector_dimensions = service.engine.vector_dimensions,
            .documents = service.engine.documents.len,
            .terms = service.engine.lexical_index.terms.len,
            .postings = service.engine.lexical_index.postings.len,
        };
    }
};

fn sortSources(sources: []Source) void {
    var index: usize = 1;
    while (index < sources.len) : (index += 1) {
        const value = sources[index];
        var insertion = index;
        while (insertion > 0 and std.mem.order(u8, value.path, sources[insertion - 1].path) == .lt) : (insertion -= 1) {
            sources[insertion] = sources[insertion - 1];
        }
        sources[insertion] = value;
    }
}

test "service exposes scoped search read list and status operations" {
    const documents = [_]hybrid.Document{
        .{ .id = "public-lexical", .text = "exact search phrase", .vector = &.{ 0, 1 }, .path = "public/a.md", .start_line = 1, .end_line = 2 },
        .{ .id = "public-vector", .text = "different wording", .vector = &.{ 1, 0 }, .path = "public/b.md", .start_line = 3, .end_line = 4 },
        .{ .id = "private", .text = "exact search phrase private", .vector = &.{ 1, 0 }, .path = "private/secret.md", .start_line = 1, .end_line = 1 },
    };
    var terms: [16]@import("postings.zig").TermEntry = undefined;
    var posting_storage: [24]@import("postings.zig").Posting = undefined;
    var lengths: [documents.len]u32 = undefined;
    var fills: [16]usize = undefined;
    const lexical_index = try @import("postings.zig").build(&documents, &terms, &posting_storage, &lengths, &fills);
    const service = Service{ .engine = .{
        .generation = 3,
        .analyzer_id = "ascii-alnum-v1",
        .embedding_model_id = "manual-v1",
        .vector_dimensions = 2,
        .documents = &documents,
        .lexical_index = lexical_index,
    } };

    var score_storage: [documents.len]f32 = undefined;
    var result_storage: [documents.len]hybrid.Result = undefined;
    var evidence_storage: [documents.len]engine_module.Evidence = undefined;
    const lexical = try service.searchKnowledge("exact search", &.{ 1, 0 }, .{
        .path_prefix = "public/",
        .retrieval_mode = .lexical,
    }, &score_storage, &result_storage, &evidence_storage);
    try std.testing.expectEqualStrings("public-lexical", lexical[0].chunk_id);
    for (lexical) |evidence| try std.testing.expect(std.mem.startsWith(u8, evidence.path, "public/"));

    const vector = try service.searchKnowledge("exact search", &.{ 1, 0 }, .{
        .path_prefix = "public/",
        .retrieval_mode = .vector,
    }, &score_storage, &result_storage, &evidence_storage);
    try std.testing.expectEqualStrings("public-vector", vector[0].chunk_id);

    try std.testing.expect(service.readChunk("private", "public/", &.{}) == null);
    const read = service.readChunk("public-lexical", "public/", &.{}).?;
    try std.testing.expectEqualStrings("public/a.md", read.path);

    var source_storage: [3]Source = undefined;
    const sources = try service.listSources("public/", &.{}, &source_storage);
    try std.testing.expectEqual(@as(usize, 2), sources.len);
    try std.testing.expectEqualStrings("public/a.md", sources[0].path);
    try std.testing.expectEqualStrings("public/b.md", sources[1].path);

    const status = service.indexStatus();
    try std.testing.expect(status.ready);
    try std.testing.expectEqual(@as(u64, 3), status.generation);
    try std.testing.expectEqual(@as(usize, 3), status.documents);
    try std.testing.expectEqual(@as(usize, 2), status.vector_dimensions);
}

test "service reports evidence and source capacity errors" {
    const document = [_]hybrid.Document{.{ .id = "one", .text = "search", .path = "one.md", .start_line = 1, .end_line = 1 }};
    var terms: [2]@import("postings.zig").TermEntry = undefined;
    var posting_storage: [2]@import("postings.zig").Posting = undefined;
    var lengths: [1]u32 = undefined;
    var fills: [2]usize = undefined;
    const index = try @import("postings.zig").build(&document, &terms, &posting_storage, &lengths, &fills);
    const service = Service{ .engine = .{
        .generation = 1,
        .analyzer_id = "ascii-v1",
        .embedding_model_id = "none",
        .vector_dimensions = 0,
        .documents = &document,
        .lexical_index = index,
    } };
    var scores: [1]f32 = undefined;
    var results: [1]hybrid.Result = undefined;
    var no_evidence: [0]engine_module.Evidence = .{};
    try std.testing.expectError(error.EvidenceCapacityTooSmall, service.searchKnowledge("search", &.{}, .{}, &scores, &results, &no_evidence));
    var no_sources: [0]Source = .{};
    try std.testing.expectError(error.SourceCapacityTooSmall, service.listSources(null, &.{}, &no_sources));
}

test "service applies required labels to search read and source listing" {
    const documents = [_]hybrid.Document{
        .{ .id = "public", .text = "launch guide", .path = "public.md", .start_line = 1, .end_line = 1 },
        .{ .id = "private", .text = "confidential launch", .path = "private.md", .start_line = 1, .end_line = 1, .required_labels = "tenant:acme" },
    };
    var terms: [8]@import("postings.zig").TermEntry = undefined;
    var posting_storage: [8]@import("postings.zig").Posting = undefined;
    var lengths: [documents.len]u32 = undefined;
    var fills: [8]usize = undefined;
    const index = try @import("postings.zig").build(&documents, &terms, &posting_storage, &lengths, &fills);
    const service = Service{ .engine = .{
        .generation = 1,
        .analyzer_id = "ascii-v1",
        .embedding_model_id = "none",
        .vector_dimensions = 0,
        .documents = &documents,
        .lexical_index = index,
    } };
    var scores: [documents.len]f32 = undefined;
    var results: [documents.len]hybrid.Result = undefined;
    var evidence: [documents.len]engine_module.Evidence = undefined;
    const anonymous = try service.searchKnowledge("confidential launch", &.{}, .{}, &scores, &results, &evidence);
    try std.testing.expectEqual(@as(usize, 1), anonymous.len);
    try std.testing.expectEqualStrings("public", anonymous[0].chunk_id);
    const tenant = try service.searchKnowledge("confidential launch", &.{}, .{
        .principal_labels = &.{"tenant:acme"},
    }, &scores, &results, &evidence);
    try std.testing.expectEqualStrings("private", tenant[0].chunk_id);
    try std.testing.expect(service.readChunk("private", null, &.{}) == null);
    try std.testing.expect(service.readChunk("private", null, &.{"tenant:acme"}) != null);
    var sources_storage: [documents.len]Source = undefined;
    const anonymous_sources = try service.listSources(null, &.{}, &sources_storage);
    try std.testing.expectEqual(@as(usize, 1), anonymous_sources.len);
    const tenant_sources = try service.listSources(null, &.{"tenant:acme"}, &sources_storage);
    try std.testing.expectEqual(@as(usize, 2), tenant_sources.len);
}
