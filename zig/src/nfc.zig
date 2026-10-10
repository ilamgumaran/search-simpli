//! Unicode Normalization Form C (NFC), implemented against the generated
//! tables in `unicode_tables.zig` (S1-T1, analyzer-v2).
//!
//! This follows the standard three-step NFC algorithm (Unicode Standard
//! Annex #15): full canonical decomposition, canonical ordering of
//! combining marks by combining class, then canonical composition.
//!
//! Complete as of S1-T15: singleton canonical decompositions (e.g. U+212B
//! ANGSTROM SIGN, CJK compatibility ideographs) are in the generated table
//! with `b == 0`, and Hangul syllable decomposition/composition is done
//! algorithmically here (UAX #15 / Unicode 3.12), because the generated
//! tables deliberately exclude the Hangul syllable block. The result equals
//! Python's `unicodedata.normalize("NFC")` on every codepoint
//! (`scripts/nfc_compare.py`).
const std = @import("std");
const tables = @import("unicode_tables.zig");

// Hangul syllable constants (Unicode Standard 3.12).
const s_base: u21 = 0xAC00;
const l_base: u21 = 0x1100;
const v_base: u21 = 0x1161;
const t_base: u21 = 0x11A7;
const l_count: u21 = 19;
const v_count: u21 = 21;
const t_count: u21 = 28;
const n_count: u21 = v_count * t_count;
const s_count: u21 = l_count * n_count;

pub const Error = error{ InvalidUtf8, OutOfMemory };

/// Normalize `text` to NFC, writing the result into memory owned by
/// `allocator`. Returns the input allocator-free (a plain slice) so callers
/// that only need a lightweight check can free it immediately.
pub fn normalize(allocator: std.mem.Allocator, text: []const u8) Error![]u8 {
    // S2-T11: validate before anything walks the bytes. The raw
    // `Utf8Iterator` below `unreachable`s on a byte that cannot start a
    // sequence, which in ReleaseSmall is undefined behaviour (it looped
    // forever). Every later step may therefore assume valid UTF-8.
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    if (!hasAnyCombiningOrDecomposable(text)) {
        // Fast, allocation-preserving path: nothing to change. Still copy so
        // the caller has a uniformly-owned buffer to free.
        return allocator.dupe(u8, text);
    }

    var codepoints = std.ArrayList(u21).empty;
    defer codepoints.deinit(allocator);
    try decomposeAll(allocator, text, &codepoints);
    canonicalOrder(codepoints.items);
    const composed = try compose(allocator, codepoints.items);
    defer allocator.free(composed);

    var out = try std.ArrayList(u8).initCapacity(allocator, composed.len * 2);
    errdefer out.deinit(allocator);
    var buffer: [4]u8 = undefined;
    for (composed) |cp| {
        const len = std.unicode.utf8Encode(cp, &buffer) catch return error.InvalidUtf8;
        try out.appendSlice(allocator, buffer[0..len]);
    }
    return out.toOwnedSlice(allocator);
}

/// Cheap pre-check: true if any codepoint has a canonical decomposition or a
/// non-zero combining class, in which case full normalization is needed.
/// Plain ASCII and already-precomposed text with no combining marks (the
/// common case) short-circuits here without allocating a codepoint buffer.
/// `text` must already be valid UTF-8 (`normalize` checks); an invalid
/// sequence ends the scan instead of reaching the iterator's `unreachable`.
fn hasAnyCombiningOrDecomposable(text: []const u8) bool {
    var view = std.unicode.Utf8View.init(text) catch return false;
    var iter = view.iterator();
    var previous: u21 = 0;
    while (iter.nextCodepoint()) |cp| {
        defer previous = cp;
        if (cp < 0x80) continue;
        if (decompositionOf(cp) != null) return true;
        if (combiningClassOf(cp) != 0) return true;
        // Two adjacent starters can still compose: Hangul L + V, LV + T,
        // and the two-part vowels of Bengali, Oriya, Tamil, ... (U+0BC6 +
        // U+0BBE -> U+0BCA), whose second codepoint has class 0 and so
        // would not be caught by the checks above.
        if (composedOf(previous, cp) != null) return true;
    }
    return false;
}

/// Table lookup. A singleton decomposition has `b == 0`.
fn decompositionOf(cp: u21) ?[2]u21 {
    var lo: usize = 0;
    var hi: usize = tables.decomposition_pairs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const entry = tables.decomposition_pairs[mid];
        if (entry.from == cp) return .{ entry.a, entry.b };
        if (entry.from < cp) lo = mid + 1 else hi = mid;
    }
    return null;
}

pub fn combiningClassOf(cp: u21) u8 {
    var lo: usize = 0;
    var hi: usize = tables.combining_class_pairs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const entry = tables.combining_class_pairs[mid];
        if (entry.codepoint == cp) return entry.ccc;
        if (entry.codepoint < cp) lo = mid + 1 else hi = mid;
    }
    return 0;
}

fn composedOf(a: u21, b: u21) ?u21 {
    // Hangul: L + V -> LV; LV + T -> LVT (algorithmic, not in the tables).
    if (a >= l_base and a < l_base + l_count and b >= v_base and b < v_base + v_count) {
        return s_base + ((a - l_base) * v_count + (b - v_base)) * t_count;
    }
    if (a >= s_base and a < s_base + s_count and (a - s_base) % t_count == 0 and
        b > t_base and b < t_base + t_count)
    {
        return a + (b - t_base);
    }
    // Composition pairs are sorted by (a, b); binary search on `a`, then
    // linear-scan the (small) run sharing that first codepoint.
    var lo: usize = 0;
    var hi: usize = tables.composition_pairs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (tables.composition_pairs[mid].a < a) lo = mid + 1 else hi = mid;
    }
    var i = lo;
    while (i < tables.composition_pairs.len and tables.composition_pairs[i].a == a) : (i += 1) {
        if (tables.composition_pairs[i].b == b) return tables.composition_pairs[i].composed;
    }
    return null;
}

fn decomposeAll(allocator: std.mem.Allocator, text: []const u8, out: *std.ArrayList(u21)) Error!void {
    var view = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;
    var iter = view.iterator();
    while (iter.nextCodepoint()) |cp| {
        try decomposeOne(allocator, cp, out);
    }
}

fn decomposeOne(allocator: std.mem.Allocator, cp: u21, out: *std.ArrayList(u21)) Error!void {
    if (cp >= s_base and cp < s_base + s_count) {
        const index = cp - s_base;
        try out.append(allocator, l_base + index / n_count);
        try out.append(allocator, v_base + (index % n_count) / t_count);
        if (index % t_count != 0) try out.append(allocator, t_base + index % t_count);
        return;
    }
    if (decompositionOf(cp)) |parts| {
        try decomposeOne(allocator, parts[0], out);
        if (parts[1] != 0) try decomposeOne(allocator, parts[1], out);
        return;
    }
    try out.append(allocator, cp);
}

/// Stable-sort maximal runs of non-zero-combining-class codepoints by
/// combining class (Unicode canonical ordering algorithm).
fn canonicalOrder(codepoints: []u21) void {
    var i: usize = 0;
    while (i < codepoints.len) {
        if (combiningClassOf(codepoints[i]) == 0) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < codepoints.len and combiningClassOf(codepoints[j]) != 0) : (j += 1) {}
        insertionSortByCombiningClass(codepoints[i..j]);
        i = j;
    }
}

fn insertionSortByCombiningClass(run: []u21) void {
    var i: usize = 1;
    while (i < run.len) : (i += 1) {
        const value = run[i];
        const value_ccc = combiningClassOf(value);
        var j = i;
        while (j > 0 and combiningClassOf(run[j - 1]) > value_ccc) : (j -= 1) {
            run[j] = run[j - 1];
        }
        run[j] = value;
    }
}

/// Canonical composition (UAX #15): scan left to right; a "starter" (ccc==0)
/// may compose with a later combining mark if nothing of equal-or-lower
/// combining class stands between them (the standard "blocked" check).
fn compose(allocator: std.mem.Allocator, codepoints: []const u21) Error![]u21 {
    var out = try std.ArrayList(u21).initCapacity(allocator, codepoints.len);
    errdefer out.deinit(allocator);
    for (codepoints) |cp| {
        try out.append(allocator, cp);
    }

    var starter_index: ?usize = null;
    var last_ccc: u8 = 0;
    var i: usize = 0;
    while (i < out.items.len) : (i += 1) {
        const cp = out.items[i];
        const ccc = combiningClassOf(cp);
        if (starter_index != null and ccc != 0 and ccc <= last_ccc) {
            // Blocked: cannot compose across an equal-or-lower-class mark.
            last_ccc = ccc;
            continue;
        }
        // A starter (ccc == 0) is blocked from composing with anything
        // other than the codepoint right after it: any codepoint between
        // blocks it (UAX #15). `last_ccc != 0` means a mark sits between.
        const blocked_starter = ccc == 0 and last_ccc != 0;
        if (starter_index) |s_index| {
            if (!blocked_starter) if (composedOf(out.items[s_index], cp)) |composed| {
                out.items[s_index] = composed;
                _ = out.orderedRemove(i);
                i -= 1;
                // `last_ccc` is unchanged: it is the class of the last
                // codepoint still standing between the starter and `i`.
                continue;
            };
        }
        if (ccc == 0) {
            starter_index = i;
            last_ccc = 0;
        } else {
            last_ccc = ccc;
        }
    }
    return out.toOwnedSlice(allocator);
}

test "NFC composes a trailing combining acute accent" {
    const allocator = std.testing.allocator;
    const decomposed = "e\u{0301}galite"; // e + COMBINING ACUTE ACCENT
    const normalized = try normalize(allocator, decomposed);
    defer allocator.free(normalized);
    try std.testing.expectEqualStrings("\u{00E9}galite", normalized);
}

test "NFC is a no-op on already-composed text" {
    const allocator = std.testing.allocator;
    const text = "cafe\u{0301} au lait";
    const normalized = try normalize(allocator, text);
    defer allocator.free(normalized);
    try std.testing.expectEqualStrings("caf\u{00E9} au lait", normalized);
}

test "NFC leaves plain ASCII and Tamil text untouched" {
    const allocator = std.testing.allocator;
    const tamil = "\u{0BAE}\u{0BB4}\u{0BC8}"; // already-precomposed Tamil syllable
    const normalized = try normalize(allocator, tamil);
    defer allocator.free(normalized);
    try std.testing.expectEqualStrings(tamil, normalized);

    const ascii = "hello, world!";
    const ascii_normalized = try normalize(allocator, ascii);
    defer allocator.free(ascii_normalized);
    try std.testing.expectEqualStrings(ascii, ascii_normalized);
}

test "NFC orders multiple combining marks by combining class before composing" {
    const allocator = std.testing.allocator;
    // COMBINING DOT BELOW (ccc=220) followed by COMBINING ACUTE ACCENT (ccc=230)
    // typed in the "wrong" storage order still normalizes deterministically.
    const text = "a\u{0323}\u{0301}";
    const normalized = try normalize(allocator, text);
    defer allocator.free(normalized);
    // a + dot-below composes to U+1EA1 (LATIN SMALL LETTER A WITH DOT BELOW),
    // the acute then stacks as a combining mark (no further precomposed form).
    try std.testing.expectEqualStrings("\u{1EA1}\u{0301}", normalized);
}

fn expectNfc(input: []const u8, expected: []const u8) !void {
    const allocator = std.testing.allocator;
    const normalized = try normalize(allocator, input);
    defer allocator.free(normalized);
    try std.testing.expectEqualStrings(expected, normalized);
}

test "NFC replaces singleton decompositions (S1-T15)" {
    try expectNfc("\u{212B}", "\u{00C5}"); // ANGSTROM SIGN -> A WITH RING ABOVE
    try expectNfc("\u{F900}", "\u{8C48}"); // CJK COMPATIBILITY IDEOGRAPH-F900
    try expectNfc("\u{037E}", ";"); // GREEK QUESTION MARK -> SEMICOLON
    try expectNfc("\u{1F71}", "\u{03AC}"); // singleton onto a precomposed letter
}

test "NFC composes decomposed Hangul and leaves composed Hangul alone (S1-T15)" {
    try expectNfc("\u{1112}\u{1161}\u{11AB}", "\u{D55C}"); // han
    try expectNfc("\u{1100}\u{1161}", "\u{AC00}"); // L + V
    try expectNfc("\u{AC00}\u{11A8}", "\u{AC01}"); // LV + T
    try expectNfc("\u{D55C}\u{AE00}", "\u{D55C}\u{AE00}");
    try expectNfc("\u{1100}\u{0301}\u{1161}", "\u{1100}\u{0301}\u{1161}"); // a mark blocks
    try expectNfc("\u{1161}\u{1100}", "\u{1161}\u{1100}"); // wrong order
}

test "NFC composes two-part vowels whose second part is a starter (S1-T15)" {
    try expectNfc("\u{0BC6}\u{0BBE}", "\u{0BCA}"); // Tamil O
    try expectNfc("\u{09C7}\u{09BE}", "\u{09CB}"); // Bengali O
}
