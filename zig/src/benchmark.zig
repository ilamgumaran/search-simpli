const engine_module = @import("engine.zig");
const hybrid = @import("hybrid.zig");
const postings = @import("postings.zig");
const std = @import("std");

pub fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    document_count: usize,
    dimensions: usize,
    query_count: usize,
    mode: hybrid.RetrievalMode,
) !void {
    if (document_count == 0 or document_count > 100_000) return error.InvalidDocumentCount;
    if (dimensions > 4_096) return error.InvalidDimensions;
    if (mode != .lexical and dimensions == 0) return error.InvalidDimensions;
    if (query_count == 0 or query_count > 10_000) return error.InvalidQueryCount;

    const documents = try allocator.alloc(hybrid.Document, document_count);
    defer allocator.free(documents);
    const vector_values = try allocator.alloc(f32, try std.math.mul(usize, document_count, dimensions));
    defer allocator.free(vector_values);
    const component: f32 = if (dimensions == 0) 0 else 1.0 / @sqrt(@as(f32, @floatFromInt(dimensions)));
    @memset(vector_values, component);
    for (documents, 0..) |*document, index| {
        document.* = .{
            .id = "benchmark-document",
            .text = "common search benchmark document lexical semantic evidence",
            .vector = vector_values[index * dimensions .. (index + 1) * dimensions],
            .path = "benchmark/document.md",
            .start_line = 1,
            .end_line = 1,
        };
    }

    const term_capacity: usize = 16;
    const posting_capacity = try std.math.mul(usize, document_count, 8);
    const terms = try allocator.alloc(postings.TermEntry, term_capacity);
    defer allocator.free(terms);
    const posting_values = try allocator.alloc(postings.Posting, posting_capacity);
    defer allocator.free(posting_values);
    const document_lengths = try allocator.alloc(u32, document_count);
    defer allocator.free(document_lengths);
    const posting_fills = try allocator.alloc(usize, term_capacity);
    defer allocator.free(posting_fills);
    const lexical_index = try postings.build(
        documents,
        terms,
        posting_values,
        document_lengths,
        posting_fills,
    );
    const engine = engine_module.Engine{
        .generation = 1,
        .analyzer_id = "ascii-alnum-v1",
        .embedding_model_id = if (dimensions == 0) "none" else "benchmark-v1",
        .vector_dimensions = dimensions,
        .documents = documents,
        .lexical_index = lexical_index,
    };
    const query_vector = try allocator.alloc(f32, dimensions);
    defer allocator.free(query_vector);
    @memset(query_vector, component);
    const lexical_scores = try allocator.alloc(f32, document_count);
    defer allocator.free(lexical_scores);
    const results = try allocator.alloc(hybrid.Result, document_count);
    defer allocator.free(results);
    const durations = try allocator.alloc(u64, query_count);
    defer allocator.free(durations);
    const lexical_durations = try allocator.alloc(u64, query_count);
    defer allocator.free(lexical_durations);
    const ranking_durations = try allocator.alloc(u64, query_count);
    defer allocator.free(ranking_durations);
    const options = hybrid.SearchOptions{
        .top_k = 10,
        .candidate_k = @min(document_count, 100),
        .retrieval_mode = mode,
    };

    _ = try engine.query("common search", query_vector, lexical_scores, results, options);
    for (durations, lexical_durations, ranking_durations) |*duration, *lexical_duration, *ranking_duration| {
        const start = std.Io.Clock.awake.now(io).nanoseconds;
        const scores = try postings.scoreQuery(engine.lexical_index, "common search", lexical_scores, options.bm25);
        const lexical_finish = std.Io.Clock.awake.now(io).nanoseconds;
        const ranked = try hybrid.searchWithLexicalScores(query_vector, engine.documents, scores, results, options);
        const finish = std.Io.Clock.awake.now(io).nanoseconds;
        std.mem.doNotOptimizeAway(ranked.len);
        duration.* = @intCast(finish - start);
        lexical_duration.* = @intCast(lexical_finish - start);
        ranking_duration.* = @intCast(finish - lexical_finish);
    }
    insertionSort(durations);
    insertionSort(lexical_durations);
    insertionSort(ranking_durations);
    const p50 = durations[(durations.len - 1) * 50 / 100];
    const p95 = durations[(durations.len - 1) * 95 / 100];
    const minimum = durations[0];
    const maximum = durations[durations.len - 1];
    std.debug.print(
        "{{\"documents\":{d},\"dimensions\":{d},\"queries\":{d},\"mode\":\"{s}\",\"min_us\":{d:.3},\"p50_us\":{d:.3},\"p95_us\":{d:.3},\"max_us\":{d:.3},\"lexical_p50_us\":{d:.3},\"ranking_p50_us\":{d:.3}}}\n",
        .{
            document_count,
            dimensions,
            query_count,
            @tagName(mode),
            @as(f64, @floatFromInt(minimum)) / 1_000.0,
            @as(f64, @floatFromInt(p50)) / 1_000.0,
            @as(f64, @floatFromInt(p95)) / 1_000.0,
            @as(f64, @floatFromInt(maximum)) / 1_000.0,
            @as(f64, @floatFromInt(lexical_durations[(lexical_durations.len - 1) * 50 / 100])) / 1_000.0,
            @as(f64, @floatFromInt(ranking_durations[(ranking_durations.len - 1) * 50 / 100])) / 1_000.0,
        },
    );
}

fn insertionSort(values: []u64) void {
    var index: usize = 1;
    while (index < values.len) : (index += 1) {
        const value = values[index];
        var insertion = index;
        while (insertion > 0 and value < values[insertion - 1]) : (insertion -= 1) {
            values[insertion] = values[insertion - 1];
        }
        values[insertion] = value;
    }
}
