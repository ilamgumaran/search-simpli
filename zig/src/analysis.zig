const std = @import("std");

pub const Token = struct {
    bytes: []const u8,
    start: usize,
};

/// Allocation-free ASCII tokenizer for the first engine milestone.
/// The Unicode strategy is intentionally a separate, versioned concern.
pub const TokenIterator = struct {
    text: []const u8,
    cursor: usize = 0,

    pub fn init(text: []const u8) TokenIterator {
        return .{ .text = text };
    }

    pub fn next(iterator: *TokenIterator) ?Token {
        while (iterator.cursor < iterator.text.len and !isTokenByte(iterator.text[iterator.cursor])) {
            iterator.cursor += 1;
        }
        if (iterator.cursor >= iterator.text.len) return null;

        const start = iterator.cursor;
        while (iterator.cursor < iterator.text.len and isTokenByte(iterator.text[iterator.cursor])) {
            iterator.cursor += 1;
        }
        return .{ .bytes = iterator.text[start..iterator.cursor], .start = start };
    }
};

pub fn tokenCount(text: []const u8) usize {
    var count: usize = 0;
    var iterator = TokenIterator.init(text);
    while (iterator.next() != null) count += 1;
    return count;
}

pub fn termFrequency(text: []const u8, term: []const u8) usize {
    var count: usize = 0;
    var iterator = TokenIterator.init(text);
    while (iterator.next()) |token| {
        if (eqlCaseFoldAscii(token.bytes, term)) count += 1;
    }
    return count;
}

pub fn isFirstOccurrence(text: []const u8, token: Token) bool {
    var iterator = TokenIterator.init(text);
    while (iterator.next()) |candidate| {
        if (candidate.start == token.start) return true;
        if (eqlCaseFoldAscii(candidate.bytes, token.bytes)) return false;
    }
    return true;
}

pub fn eqlCaseFoldAscii(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_byte, right_byte| {
        if (std.ascii.toLower(left_byte) != std.ascii.toLower(right_byte)) return false;
    }
    return true;
}

fn isTokenByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte);
}

test "token iterator finds words and numbers" {
    var iterator = TokenIterator.init("Zig, search-v2!");
    try std.testing.expectEqualStrings("Zig", iterator.next().?.bytes);
    try std.testing.expectEqualStrings("search", iterator.next().?.bytes);
    try std.testing.expectEqualStrings("v2", iterator.next().?.bytes);
    try std.testing.expect(iterator.next() == null);
}

test "term frequency uses ASCII case folding" {
    try std.testing.expectEqual(@as(usize, 2), termFrequency("Search finds SEARCH evidence", "search"));
    try std.testing.expectEqual(@as(usize, 4), tokenCount("Search finds cited evidence"));
}

test "first occurrence suppresses duplicate query terms" {
    var iterator = TokenIterator.init("zig ZIG engine");
    const first = iterator.next().?;
    const duplicate = iterator.next().?;
    try std.testing.expect(isFirstOccurrence(iterator.text, first));
    try std.testing.expect(!isFirstOccurrence(iterator.text, duplicate));
}
