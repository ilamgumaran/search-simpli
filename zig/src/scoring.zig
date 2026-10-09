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

/// A valid vector, for a query or a stored document (S2-T13): every component
/// is finite and the L2 norm is a finite `f32`, that is, the sum of squares
/// accumulated in `f32` (the way `cosineSimilarity` accumulates it) does not
/// overflow. Roughly: the norm stays below 1.8e19. An all-zero vector is valid
/// (its cosine is defined as 0).
pub fn isValidVector(values: []const f32) bool {
    var squared: f32 = 0;
    for (values) |value| {
        if (!std.math.isFinite(value)) return false;
        squared += value * value;
    }
    return std.math.isFinite(squared);
}

/// Cosine similarity. For every pair whose `f32` sums of squares, dot product
/// and denominator are finite (all vectors that pass `isValidVector`, and every
/// ordinary embedding) the arithmetic is the original `f32` loop, bit for bit.
/// If any of them overflows (components of about 1.8e19 and more, which only
/// snapshots written before S2-T13 can hold), the score is recomputed with
/// `f64` accumulation, which cannot overflow for finite `f32` inputs, so the
/// result is always a finite number in [-1, 1] and never NaN.
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
    const denominator = @sqrt(left_squared) * @sqrt(right_squared);
    if (std.math.isFinite(dot_product) and std.math.isFinite(left_squared) and
        std.math.isFinite(right_squared) and std.math.isFinite(denominator))
    {
        return dot_product / denominator;
    }
    return cosineWide(left, right);
}

fn cosineWide(left: []const f32, right: []const f32) f32 {
    var dot_product: f64 = 0;
    var left_squared: f64 = 0;
    var right_squared: f64 = 0;
    for (left, right) |left_value, right_value| {
        const l: f64 = left_value;
        const r: f64 = right_value;
        dot_product += l * r;
        left_squared += l * l;
        right_squared += r * r;
    }
    if (left_squared == 0 or right_squared == 0) return 0;
    const score = dot_product / (@sqrt(left_squared) * @sqrt(right_squared));
    if (std.math.isNan(score)) return 0;
    return @floatCast(@max(-1.0, @min(1.0, score)));
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

test "cosine at f32 extremes is finite, not NaN (S2-T13)" {
    const big = std.math.floatMax(f32);
    // Squares overflow f32: the original loop gave inf / inf = NaN.
    const same = try cosineSimilarity(&.{ big, big }, &.{ big, big });
    try std.testing.expect(std.math.isFinite(same));
    try std.testing.expectApproxEqAbs(@as(f32, 1), same, 1e-6);
    const opposite = try cosineSimilarity(&.{ big, 0 }, &.{ -big, 0 });
    try std.testing.expectApproxEqAbs(@as(f32, -1), opposite, 1e-6);
    const orthogonal = try cosineSimilarity(&.{ big, 0 }, &.{ 0, big });
    try std.testing.expectEqual(@as(f32, 0), orthogonal);
    const mixed = try cosineSimilarity(&.{ 1e30, 1 }, &.{ 1e20, 0 });
    try std.testing.expect(std.math.isFinite(mixed));
    try std.testing.expectApproxEqAbs(@as(f32, 1), mixed, 1e-6);
    // Ordinary vectors keep the original f32 arithmetic exactly.
    const a = [_]f32{ 0.1, -0.7, 0.33 };
    const b = [_]f32{ 0.9, 0.2, -0.4 };
    var dot: f32 = 0;
    var ls: f32 = 0;
    var rs: f32 = 0;
    for (a, b) |x, y| {
        dot += x * y;
        ls += x * x;
        rs += y * y;
    }
    try std.testing.expectEqual(dot / (@sqrt(ls) * @sqrt(rs)), try cosineSimilarity(&a, &b));
}

test "isValidVector rejects non-finite components and an overflowing norm (S2-T13)" {
    try std.testing.expect(isValidVector(&.{}));
    try std.testing.expect(isValidVector(&.{ 0, 0 }));
    try std.testing.expect(isValidVector(&.{ 1.8e19, 0 }));
    try std.testing.expect(!isValidVector(&.{ 2e19, 0 }));
    try std.testing.expect(!isValidVector(&.{ std.math.floatMax(f32), 1 }));
    try std.testing.expect(!isValidVector(&.{ 1, std.math.nan(f32) }));
    try std.testing.expect(!isValidVector(&.{ std.math.inf(f32), 1 }));
    try std.testing.expect(!isValidVector(&.{-std.math.inf(f32)}));
}

test "reciprocal rank prefers earlier results and ignores absence" {
    const first = reciprocalRankContribution(1, 60);
    const tenth = reciprocalRankContribution(10, 60);
    try std.testing.expect(first > tenth);
    try std.testing.expectEqual(@as(f32, 0), reciprocalRankContribution(null, 60));
}
