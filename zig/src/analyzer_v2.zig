//! `analyzer-v2`: Unicode-aware tokenization (S1-T1 acceptance criterion 2).
//!
//! Pipeline per the task's wording ("NFC, case folding, letters/digits by
//! Unicode category, no ASCII-only paths"):
//!   1. NFC-normalize the input (`nfc.normalize`).
//!   2. Split into maximal runs of codepoints in Unicode General_Category
//!      Lu/Ll/Lt/Lm/Lo (letter) or Nd/Nl/No (number) -- `unicode_tables.letter_digit_ranges`.
//!   3. Simple-casefold each codepoint in a run (`unicode_tables.casefold_pairs`).
//!
//! This intentionally lines up with `search_platform.core.tokenize`'s
//! existing behavior (`[^\W_]+` then `.casefold()`): CPython's `\w` (with
//! `re.UNICODE`, the Python 3 default) is defined as "alphanumeric or
//! underscore", and "alphanumeric" is alpha-or-decimal-or-digit-or-numeric,
//! i.e. exactly categories L* and N* -- not marks (Mn/Mc). Verified
//! interactively: `'்'.isalnum()` (Tamil virama, category Mn) is
//! `False`, so Python's own tokenizer already splits Tamil text at
//! combining marks, and analyzer-v2 does the same by using the same
//! category set. This is *not* full grapheme-cluster-aware Indic
//! tokenization; it is documented parity with the existing Python
//! reference, which BM25 conformance is measured against.
//!
//! Documented limitations (ROLES.md: report what is not done, don't hide
//! it):
//! - Case folding here is *simple* (one codepoint to one codepoint), not
//!   Unicode's *full* case folding (which Python's `str.casefold()` uses,
//!   e.g. German sharp s U+00DF -> "ss", some ligatures). This is invisible
//!   for the fixtures this task ships (English and Tamil; Tamil has no
//!   letter case, and the vendored app-text/README fixtures are plain
//!   English prose without sharp-s-style multi-codepoint folds).
//! - NFC (see `nfc.zig`) excludes Hangul syllable algorithmic
//!   decomposition/composition; irrelevant to this task's fixtures.
const std = @import("std");
const nfc = @import("nfc.zig");
const tables = @import("unicode_tables.zig");

pub const analyzer_id = "analyzer-v2";

pub const Error = nfc.Error;

fn isLetterOrDigit(cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = tables.letter_digit_ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const range = tables.letter_digit_ranges[mid];
        if (cp < range.start) {
            hi = mid;
        } else if (cp > range.end) {
            lo = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

fn casefoldCodepoint(cp: u21) u21 {
    var lo: usize = 0;
    var hi: usize = tables.casefold_pairs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const entry = tables.casefold_pairs[mid];
        if (entry.from == cp) return entry.to;
        if (entry.from < cp) lo = mid + 1 else hi = mid;
    }
    return cp;
}

/// Tokenize `text`: NFC-normalize, then split into maximal Unicode
/// letter/digit runs, casefolding each codepoint. Returns an
/// allocator-owned slice of allocator-owned token strings (both freed by
/// freeing the returned slice's elements, then the slice itself, or by
/// using an arena and discarding it wholesale -- the intended use in this
/// codebase, since indexing/query are one-shot CLI operations).
pub fn tokenize(allocator: std.mem.Allocator, text: []const u8) Error![][]const u8 {
    const normalized = try nfc.normalize(allocator, text);
    defer allocator.free(normalized);

    var tokens = std.ArrayList([]const u8).empty;
    defer tokens.deinit(allocator);

    var view = std.unicode.Utf8View.init(normalized) catch return error.InvalidUtf8;
    var iterator = view.iterator();
    var current = std.ArrayList(u8).empty;
    defer current.deinit(allocator);

    while (iterator.nextCodepointSlice()) |slice| {
        const cp = std.unicode.utf8Decode(slice) catch return error.InvalidUtf8;
        if (isLetterOrDigit(cp)) {
            const folded = casefoldCodepoint(cp);
            var buffer: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(folded, &buffer) catch return error.InvalidUtf8;
            try current.appendSlice(allocator, buffer[0..len]);
        } else if (current.items.len > 0) {
            try tokens.append(allocator, try current.toOwnedSlice(allocator));
            current = std.ArrayList(u8).empty;
        }
    }
    if (current.items.len > 0) {
        try tokens.append(allocator, try current.toOwnedSlice(allocator));
    }
    return tokens.toOwnedSlice(allocator);
}

pub fn freeTokens(allocator: std.mem.Allocator, tokens: [][]const u8) void {
    for (tokens) |token| allocator.free(token);
    allocator.free(tokens);
}

test "tokenize splits, casefolds, and NFC-normalizes English text" {
    const allocator = std.testing.allocator;
    const tokens = try tokenize(allocator, "Zig, search-v2! Cafe\u{0301} rocks.");
    defer freeTokens(allocator, tokens);
    const expected = [_][]const u8{ "zig", "search", "v2", "caf\u{00e9}", "rocks" };
    try std.testing.expectEqual(expected.len, tokens.len);
    for (expected, tokens) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "tokenize splits Tamil text at combining marks, matching Python isalnum" {
    const allocator = std.testing.allocator;
    // "தமிழ் மொழி": Python's `[^\W_]+` finds ['தம', 'ழ', 'ம', 'ழ'] on this
    // input (verified interactively against CPython 3.9) because the
    // dependent vowel signs and virama are category Mn/Mc, not alnum.
    const tokens = try tokenize(allocator, "தமிழ் மொழி");
    defer freeTokens(allocator, tokens);
    try std.testing.expectEqual(@as(usize, 4), tokens.len);
    try std.testing.expectEqualStrings("தம", tokens[0]);
    try std.testing.expectEqualStrings("ழ", tokens[1]);
    try std.testing.expectEqualStrings("ம", tokens[2]);
    try std.testing.expectEqualStrings("ழ", tokens[3]);
}

test "tokenize treats letters and digits uniformly across scripts" {
    const allocator = std.testing.allocator;
    const tokens = try tokenize(allocator, "v2 2026 ௨௦௨௬");
    defer freeTokens(allocator, tokens);
    try std.testing.expectEqual(@as(usize, 3), tokens.len);
}
