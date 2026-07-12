const std = @import("std");

pub const Bm25Parameters = struct {
    k1: f32 = 1.2,
    b: f32 = 0.75,
};

pub const VectorError = error{DimensionMismatch};

pub fn bm25Contribution(
    term_frequency: f32,
    document_length: f32,
    average_document_length: f32,
    document_frequency: u32,
    document_count: u32,
    parameters: Bm25Parameters,
) f32 {
    if (term_frequency <= 0 or average_document_length <= 0 or document_count == 0) return 0;
    const df: f32 = @floatFromInt(document_frequency);
    const count: f32 = @floatFromInt(document_count);
    const idf = @log(1.0 + (count - df + 0.5) / (df + 0.5));
    const length_normalization = 1.0 - parameters.b + parameters.b * document_length / average_document_length;
    return idf * (term_frequency * (parameters.k1 + 1.0)) /
        (term_frequency + parameters.k1 * length_normalization);
}

pub fn cosineSimilarity(left: []const f32, right: []const f32) VectorError!f32 {
    if (left.len != right.len) return error.DimensionMismatch;
    if (left.len == 0) return 0;

    var dot_product: f32 = 0;
    var left_squared: f32 = 0;
    var right_squared: f32 = 0;
    for (left, right) |left_value, right_value| {
        dot_product += left_value * right_value;
        left_squared += left_value * left_value;
        right_squared += right_value * right_value;
    }
    if (left_squared == 0 or right_squared == 0) return 0;
    return dot_product / (@sqrt(left_squared) * @sqrt(right_squared));
}

pub fn reciprocalRankContribution(rank: ?usize, k: f32) f32 {
    const present_rank = rank orelse return 0;
    if (present_rank == 0) return 0;
    return 1.0 / (k + @as(f32, @floatFromInt(present_rank)));
}

test "BM25 rewards a present term" {
    const missing = bm25Contribution(0, 100, 100, 3, 100, .{});
    const present = bm25Contribution(2, 100, 100, 3, 100, .{});
    try std.testing.expectEqual(@as(f32, 0), missing);
    try std.testing.expect(present > missing);
}

test "rarer terms receive a larger BM25 contribution" {
    const rare = bm25Contribution(1, 100, 100, 1, 100, .{});
    const common = bm25Contribution(1, 100, 100, 80, 100, .{});
    try std.testing.expect(rare > common);
}

test "cosine similarity validates dimensions and direction" {
    try std.testing.expectApproxEqAbs(@as(f32, 1), try cosineSimilarity(&.{ 1, 0 }, &.{ 3, 0 }), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), try cosineSimilarity(&.{ 1, 0 }, &.{ 0, 2 }), 0.0001);
    try std.testing.expectError(error.DimensionMismatch, cosineSimilarity(&.{1}, &.{ 1, 2 }));
}

test "reciprocal rank prefers earlier results and ignores absence" {
    const first = reciprocalRankContribution(1, 60);
    const tenth = reciprocalRankContribution(10, 60);
    try std.testing.expect(first > tenth);
    try std.testing.expectEqual(@as(f32, 0), reciprocalRankContribution(null, 60));
}
