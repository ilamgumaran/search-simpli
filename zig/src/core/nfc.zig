//! Unicode Normalization Form C (NFC), implemented against the generated
//! tables in `unicode_tables.zig` (S1-T1, analyzer-v2).
//!
//! This follows the standard three-step NFC algorithm (Unicode Standard
//! Annex #15): full canonical decomposition, canonical ordering of
//! combining marks by combining class, then canonical composition.
//!
//! Complete as of S1-T15: singleton canonical decompositions (e.g. U+212B
//! ANGSTROM SIGN, CJK compatibility ideographs) are in the generated table
//! with `b == 0`, and Hangul composition (L + V, LV + T) is done
//! algorithmically here (UAX #15 / Unicode 3.12), because the generated
//! tables deliberately exclude the Hangul syllable block. Precomposed
//! syllables are not decomposed: they are kept whole (S1-T16), which gives the
//! same result as decomposing and recomposing them. The result equals
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

    // S1-T16: the full algorithm runs only on the regions that can change.
    // Between two adjacent "inert" codepoints (ASCII, or a precomposed
    // Hangul syllable) nothing can compose, reorder or block: an inert
    // codepoint is a class-0 starter that has no decomposition and is never
    // the second part of a composition pair (checked against the tables by a
    // test below), and no pair joins two inert codepoints. So NFC(text) is
    // the concatenation of NFC of the regions between such boundaries, and
    // an inert run is copied unchanged. A region starts at the inert
    // codepoint just before its first non-inert one (the starter a mark may
    // compose with) and ends before the next inert codepoint. Work and
    // memory stay linear in the text, and Korean or English text holding one
    // mark costs about what a scan of it costs.
    var out = try std.ArrayList(u8).initCapacity(allocator, text.len + 16);
    errdefer out.deinit(allocator);
    var codepoints = std.ArrayList(u21).empty;
    defer codepoints.deinit(allocator);

    var copied_to: usize = 0; // text[0..copied_to] is already in `out`
    var region_start: ?usize = null;
    var previous_inert: ?usize = null; // offset of the previous codepoint if inert
    var at: usize = 0;
    while (at < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[at]) catch return error.InvalidUtf8;
        const cp = std.unicode.utf8Decode(text[at .. at + len]) catch return error.InvalidUtf8;
        if (isInert(cp)) {
            if (region_start) |start| {
                try normalizeRegion(allocator, text[start..at], &codepoints, &out);
                region_start = null;
                copied_to = at;
            }
            previous_inert = at;
        } else {
            if (region_start == null) {
                const start = previous_inert orelse at;
                try out.appendSlice(allocator, text[copied_to..start]);
                copied_to = start;
                region_start = start;
            }
            previous_inert = null;
        }
        at += len;
    }
    if (region_start) |start| {
        try normalizeRegion(allocator, text[start..], &codepoints, &out);
    } else {
        try out.appendSlice(allocator, text[copied_to..]);
    }
    return out.toOwnedSlice(allocator);
}

/// NFC with a map back to the input (S3-T2, `docs/lexical-segment-format-v2.md`):
/// `codepoints[i]` came from input codepoints `starts[i] .. ends[i]`. The
/// regions are `normalize`'s (an inert codepoint before a run of non-inert
/// ones, up to the next inert codepoint), so `codepoints` is exactly
/// `normalize(text)` decoded. A region whose NFC equals its input maps one to
/// one; a region NFC changes maps every output codepoint to the whole region
/// (a composed `e` + U+0301 is one codepoint covering both). Token offsets
/// built from the map therefore always cover the original text of the token.
pub const Mapped = struct {
    codepoints: []u21,
    starts: []u32,
    ends: []u32,

    pub fn deinit(mapped: Mapped, allocator: std.mem.Allocator) void {
        allocator.free(mapped.codepoints);
        allocator.free(mapped.starts);
        allocator.free(mapped.ends);
    }
};

/// One codepoint of NFC output and the input codepoints `start .. end` it came from.
pub const MappedCodepoint = struct { cp: u21, start: u32, end: u32 };

/// `normalizeMapped` as a stream (S3-T2): one output codepoint at a time,
/// holding only the current region, so tokenizing a large text costs no
/// per-codepoint arrays. `allocator` backs the region buffers (`deinit`).
/// `text` must be valid UTF-8 (checked by `init`).
pub const MappedIterator = struct {
    allocator: std.mem.Allocator,
    text: []const u8,
    at: usize = 0,
    index: u32 = 0,
    simple: bool,
    queue: std.ArrayList(MappedCodepoint) = .empty,
    queue_head: usize = 0,
    region: std.ArrayList(u21) = .empty,
    scratch: std.ArrayList(u21) = .empty,

    pub fn init(allocator: std.mem.Allocator, text: []const u8) Error!MappedIterator {
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        return .{ .allocator = allocator, .text = text, .simple = !hasAnyCombiningOrDecomposable(text) };
    }

    pub fn deinit(iterator: *MappedIterator) void {
        iterator.queue.deinit(iterator.allocator);
        iterator.region.deinit(iterator.allocator);
        iterator.scratch.deinit(iterator.allocator);
    }

    const Decoded = struct { cp: u21, len: u3 };

    fn decodeAt(text: []const u8, at: usize) Decoded {
        const len = std.unicode.utf8ByteSequenceLength(text[at]) catch unreachable;
        return .{ .cp = std.unicode.utf8Decode(text[at .. at + len]) catch unreachable, .len = len };
    }

    pub fn next(iterator: *MappedIterator) Error!?MappedCodepoint {
        if (iterator.queue_head < iterator.queue.items.len) {
            defer iterator.queue_head += 1;
            return iterator.queue.items[iterator.queue_head];
        }
        if (iterator.at >= iterator.text.len) return null;
        const current = decodeAt(iterator.text, iterator.at);
        const after = iterator.at + current.len;
        const next_inert = after >= iterator.text.len or isInert(decodeAt(iterator.text, after).cp);
        if (iterator.simple or (isInert(current.cp) and next_inert)) {
            defer {
                iterator.at = after;
                iterator.index += 1;
            }
            return .{ .cp = current.cp, .start = iterator.index, .end = iterator.index + 1 };
        }
        // A region: this codepoint up to the next inert one.
        const start = iterator.index;
        iterator.region.clearRetainingCapacity();
        try iterator.region.append(iterator.allocator, current.cp);
        iterator.at = after;
        iterator.index += 1;
        while (iterator.at < iterator.text.len) {
            const following = decodeAt(iterator.text, iterator.at);
            if (isInert(following.cp)) break;
            try iterator.region.append(iterator.allocator, following.cp);
            iterator.at += following.len;
            iterator.index += 1;
        }
        iterator.scratch.clearRetainingCapacity();
        for (iterator.region.items) |cp| try decomposeOne(iterator.allocator, cp, &iterator.scratch);
        canonicalOrder(iterator.scratch.items);
        const composed = compose(iterator.scratch.items);
        const same = std.mem.eql(u21, composed, iterator.region.items);
        iterator.queue.clearRetainingCapacity();
        iterator.queue_head = 0;
        for (composed, 0..) |cp, k| {
            const offset: u32 = @intCast(k);
            try iterator.queue.append(iterator.allocator, .{
                .cp = cp,
                .start = if (same) start + offset else start,
                .end = if (same) start + offset + 1 else iterator.index,
            });
        }
        return iterator.next();
    }
};

pub fn normalizeMapped(allocator: std.mem.Allocator, text: []const u8) Error!Mapped {
    var iterator = try MappedIterator.init(allocator, text);
    defer iterator.deinit();
    var codepoints = std.ArrayList(u21).empty;
    errdefer codepoints.deinit(allocator);
    var starts = std.ArrayList(u32).empty;
    errdefer starts.deinit(allocator);
    var ends = std.ArrayList(u32).empty;
    errdefer ends.deinit(allocator);
    while (try iterator.next()) |mapped| {
        try codepoints.append(allocator, mapped.cp);
        try starts.append(allocator, mapped.start);
        try ends.append(allocator, mapped.end);
    }
    return .{
        .codepoints = try codepoints.toOwnedSlice(allocator),
        .starts = try starts.toOwnedSlice(allocator),
        .ends = try ends.toOwnedSlice(allocator),
    };
}

test "normalizeMapped equals normalize and maps back to the input" {
    const allocator = std.testing.allocator;
    const inputs = [_][]const u8{
        "plain ascii", "Cafe\u{0301} au lait", "a\u{0323}\u{0301}b", "\u{0BA4}\u{0BAE}\u{0BBF}\u{0BB4}\u{0BCD}",
        "\u{1112}\u{1161}\u{11AB}x", "\u{212B}ngstrom \u{F900}", "1\u{FE0F}\u{20E3}", "",
        "\u{0BC6}\u{0BBE} e\u{0301}e\u{0301}",
    };
    for (inputs) |text| {
        const expected = try normalize(allocator, text);
        defer allocator.free(expected);
        const mapped = try normalizeMapped(allocator, text);
        defer mapped.deinit(allocator);
        var encoded = std.ArrayList(u8).empty;
        defer encoded.deinit(allocator);
        for (mapped.codepoints, mapped.starts, mapped.ends) |cp, start, end| {
            var buffer: [4]u8 = undefined;
            const n = try std.unicode.utf8Encode(cp, &buffer);
            try encoded.appendSlice(allocator, buffer[0..n]);
            try std.testing.expect(start < end);
        }
        try std.testing.expectEqualStrings(expected, encoded.items);
    }
    // e + U+0301 composes: the one output codepoint covers both inputs.
    const mapped = try normalizeMapped(allocator, "xe\u{0301}y");
    defer mapped.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), mapped.codepoints.len);
    try std.testing.expectEqual(@as(u32, 1), mapped.starts[1]);
    try std.testing.expectEqual(@as(u32, 3), mapped.ends[1]);
    try std.testing.expectEqual(@as(u32, 3), mapped.starts[2]);
}

/// ASCII, or a precomposed Hangul syllable: see `normalize`.
fn isInert(cp: u21) bool {
    return cp < 0x80 or (cp >= s_base and cp < s_base + s_count);
}

/// The three-step algorithm on one region, appending UTF-8 to `out`.
fn normalizeRegion(
    allocator: std.mem.Allocator,
    region: []const u8,
    codepoints: *std.ArrayList(u21),
    out: *std.ArrayList(u8),
) Error!void {
    codepoints.clearRetainingCapacity();
    try decomposeAll(allocator, region, codepoints);
    canonicalOrder(codepoints.items);
    const composed = compose(codepoints.items);
    for (composed) |cp| {
        try out.ensureUnusedCapacity(allocator, 4);
        const n = std.unicode.utf8Encode(cp, out.unusedCapacitySlice()) catch return error.InvalidUtf8;
        out.items.len += n;
    }
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

/// True for the Hangul jamo block (U+1100..U+11FF) and the precomposed
/// syllables, which no table row mentions.
/// The generated tables deliberately exclude both blocks (Hangul is
/// algorithmic); a test below checks that against every table row, so the
/// early outs it feeds cannot change a result. (S1-T16: the Korean slow path
/// otherwise binary-searches three tables for every jamo.)
fn isHangul(cp: u21) bool {
    return (cp >= l_base and cp <= 0x11FF) or (cp >= s_base and cp < s_base + s_count);
}

/// Table lookup. A singleton decomposition has `b == 0`.
fn decompositionOf(cp: u21) ?[2]u21 {
    if (isHangul(cp)) return null;
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
    if (isHangul(cp)) return 0;
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
    if (isHangul(a)) return null; // no table row starts with Hangul
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
    // A precomposed Hangul syllable is kept whole (S1-T16). UAX #15 would
    // decompose it to L V [T] and recompose it, but the three jamo are
    // adjacent, all of class 0, and always recompose to the same syllable
    // (nothing can sit between them), so the round trip is the identity. A
    // following T jamo still composes with an LV syllable in `composedOf`.
    // This keeps Korean text on the slow path at about the cost of text
    // without marks.
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

/// Canonical composition (UAX #15), one pass, in place (S1-T16).
///
/// `read` walks the decomposed, canonically ordered codepoints; `write`
/// is the end of the already-composed prefix, which is rewritten in the same
/// buffer (`write <= read` always). The only look-back is the index of the
/// last starter and the combining class of the last codepoint kept after it
/// (marks are ordered, so that is also the highest since the starter). A
/// codepoint composes with the last starter only if nothing blocks it; when it
/// does, it is appended, and when it does not compose it is appended too. The
/// composed prefix is never rescanned or shifted, so the work is linear.
/// Returns the composed prefix of `codepoints`.
fn compose(codepoints: []u21) []u21 {
    var starter_index: ?usize = null;
    var last_ccc: u8 = 0;
    var write: usize = 0;
    for (codepoints) |cp| {
        const ccc = combiningClassOf(cp);
        if (starter_index != null and ccc != 0 and ccc <= last_ccc) {
            // Blocked: cannot compose across an equal-or-lower-class mark.
            last_ccc = ccc;
            codepoints[write] = cp;
            write += 1;
            continue;
        }
        // A starter (ccc == 0) is blocked from composing with anything
        // other than the codepoint right after it: any codepoint between
        // blocks it (UAX #15). `last_ccc != 0` means a mark sits between.
        const blocked_starter = ccc == 0 and last_ccc != 0;
        if (starter_index) |s_index| {
            if (!blocked_starter) if (composedOf(codepoints[s_index], cp)) |composed| {
                codepoints[s_index] = composed;
                // `last_ccc` is unchanged: it is the class of the last
                // codepoint still standing between the starter and here.
                continue;
            };
        }
        if (ccc == 0) {
            starter_index = write;
            last_ccc = 0;
        } else {
            last_ccc = ccc;
        }
        codepoints[write] = cp;
        write += 1;
    }
    return codepoints[0..write];
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

test "the generated tables have no row in the Hangul blocks (S1-T16 early outs)" {
    for (tables.combining_class_pairs) |row| try std.testing.expect(!isHangul(row.codepoint));
    for (tables.decomposition_pairs) |row| {
        try std.testing.expect(!isHangul(row.from));
        try std.testing.expect(!isHangul(row.a));
        try std.testing.expect(!isHangul(row.b));
    }
    for (tables.composition_pairs) |row| {
        try std.testing.expect(!isHangul(row.a));
        try std.testing.expect(!isHangul(row.b));
        try std.testing.expect(!isHangul(row.composed));
    }
}

test "inert codepoints are never part of a table row except as the first of a pair (S1-T16)" {
    // The region split in `normalize` rests on this.
    for (tables.composition_pairs) |row| {
        try std.testing.expect(!isInert(row.b));
        try std.testing.expect(!isInert(row.composed));
    }
    for (tables.decomposition_pairs) |row| try std.testing.expect(!isInert(row.from));
    for (tables.combining_class_pairs) |row| try std.testing.expect(!isInert(row.codepoint));
    // No pair joins two inert codepoints (b is never inert: above), and the
    // Hangul rule needs a jamo.
}

test "a mark blocks a starter from its class-0 second part, in Tamil too (S1-T16)" {
    // starter, mark (pulli, ccc 9), class-0 second: must NOT compose.
    try expectNfc("\u{0BC6}\u{0BCD}\u{0BBE}", "\u{0BC6}\u{0BCD}\u{0BBE}");
    try expectNfc("\u{0BC6}\u{0BCD}\u{0BD7}", "\u{0BC6}\u{0BCD}\u{0BD7}");
    try expectNfc("\u{0B95}\u{0BC6}\u{0BCD}\u{0BBE}", "\u{0B95}\u{0BC6}\u{0BCD}\u{0BBE}");
    try expectNfc("\u{09C7}\u{0301}\u{09BE}", "\u{09C7}\u{0301}\u{09BE}");
    // without the mark the pair composes, with ASCII around it
    try expectNfc("a\u{0BC6}\u{0BBE}b", "a\u{0BCA}b");
}

test "regions around marks in mixed ASCII, Hangul and Latin text (S1-T16)" {
    try expectNfc("abc e\u{0301} def", "abc \u{00E9} def");
    try expectNfc("\u{D55C}\u{AE00} e\u{0301}\u{D55C}", "\u{D55C}\u{AE00} \u{00E9}\u{D55C}");
    try expectNfc("\u{AC00}\u{11A8}\u{AC00}", "\u{AC01}\u{AC00}"); // LV + T, then a syllable
    try expectNfc("\u{1100}\u{D55C}\u{1161}", "\u{1100}\u{D55C}\u{1161}"); // jamo around a syllable do not join it
    try expectNfc("\u{D55C}\u{0301}\u{11A8}", "\u{D55C}\u{0301}\u{11A8}"); // a mark between an LVT syllable and a T jamo
    try expectNfc("\u{0301}a", "\u{0301}a"); // leading mark
    try expectNfc("a\u{0301}", "\u{00E1}"); // trailing region
}
