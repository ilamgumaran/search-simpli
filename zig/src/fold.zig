//! K, the key function of `fold-groups-v1` (S5-T4, docs/tasks/S5-T4.md rulings
//! 2-5 of the plan and ruling 10's query side), and the key map built on it.
//!
//! K maps one analyzer-v2 term (or a raw token: F folds both the same way) to
//! zero or more pieces through four parts, in order:
//!
//!   F  fold: each code point through `unicode_tables.fold_from` (the code
//!      points whose NFKC(casefold(NFKC(c))) fixpoint differs from NFC of
//!      analyzer-v2's simple fold) or else analyzer-v2's simple fold, then NFC;
//!      the result is split again by the v2 rule (letters/digits, the marks and
//!      joiners inside a run, variation selectors dropped), so `½` gives `1`, `2`
//!      and a folded token that is one v2 token gives itself;
//!   A  Latin marks: an ASCII piece is untouched; otherwise the canonical
//!      decomposition, the eight-letter table, every U+0300-U+036F whose nearest
//!      preceding non-mark (Mn/Mc) code point is a-z dropped, then NFC;
//!   S  English plural: a piece matching [a-z]{3,49}, not in the keep list, by
//!      the first of ruling 4's rules that applies;
//!   T  Tamil: a piece of code points U+0B80-U+0BFF only, not in the keep list,
//!      by the first of ruling 5's seven suffix rules whose condition holds and
//!      whose result keeps two Tamil letters (U+0B85-U+0BB9).
//!
//! The group key of a term is its pieces joined by one space, or the term
//! itself when K leaves nothing. The Python mirror is
//! `src/search_platform/analyzer_v3.py`; `fold_test.zig` checks this file
//! against its golden, `fixtures/analyzer-v3-golden.json`, byte for byte.
//!
//! An ASCII term of letters and digits (every term of an English corpus) takes
//! a path with no table lookup and no allocation beyond the output: F is ASCII
//! lowercasing, A leaves it, T cannot apply, and only S looks at it.

const std = @import("std");
const fuzzy = @import("fuzzy.zig");
const nfc = @import("nfc.zig");
const postings = @import("postings.zig");
const tables = @import("unicode_tables.zig");
const title_field = @import("title_field.zig");

pub const policy_id = "fold-groups-v1";

pub const Error = nfc.Error;

// ------------------------------------------------------- character classes --

fn inRanges(ranges: []const tables.CodepointRange, cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const range = ranges[mid];
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

fn isLetterOrDigit(cp: u21) bool {
    if (cp < 0x80) return (cp >= 'a' and cp <= 'z') or (cp >= 'A' and cp <= 'Z') or (cp >= '0' and cp <= '9');
    return inRanges(&tables.letter_digit_ranges, cp);
}

fn isMark(cp: u21) bool {
    if (cp < 0x300) return false;
    return inRanges(&tables.mark_ranges, cp);
}

fn isJoiner(cp: u21) bool {
    return cp == 0x200C or cp == 0x200D;
}

fn isVariationSelector(cp: u21) bool {
    return (cp >= 0xFE00 and cp <= 0xFE0F) or (cp >= 0xE0100 and cp <= 0xE01EF);
}

/// analyzer-v2's simple fold of one code point (`analyzer_v2.casefoldCodepoint`).
fn simpleFold(cp: u21) u21 {
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

/// The fold table's output for `cp`, or null where the simple fold gives it.
pub fn foldOutput(cp: u21) ?[]const u8 {
    if (cp < tables.fold_from[0]) return null;
    var lo: usize = 0;
    var hi: usize = tables.fold_from.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const from = tables.fold_from[mid];
        if (from == cp) {
            const k = tables.fold_to[mid];
            return tables.fold_pool[tables.fold_offsets[k]..tables.fold_offsets[k + 1]];
        }
        if (from < cp) lo = mid + 1 else hi = mid;
    }
    return null;
}

/// A canonical decomposition (`unicode_tables.decomposition_pairs`; a
/// singleton has `b == 0`). Hangul syllables are left whole, as `nfc.zig` does:
/// their jamo are neither marks nor a-z, so A treats them the same either way.
fn decompositionOf(cp: u21) ?[2]u21 {
    if (cp < 0xC0) return null;
    if (cp >= 0xAC00 and cp <= 0xD7A3) return null;
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

fn appendUtf8(allocator: std.mem.Allocator, out: *std.ArrayList(u8), cp: u21) Error!void {
    var buffer: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &buffer) catch return error.InvalidUtf8;
    try out.appendSlice(allocator, buffer[0..len]);
}

fn decode(allocator: std.mem.Allocator, bytes: []const u8, out: *std.ArrayList(u21)) Error!void {
    out.clearRetainingCapacity();
    var view = std.unicode.Utf8View.init(bytes) catch return error.InvalidUtf8;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |cp| try out.append(allocator, cp);
}

// --------------------------------------------------------- A: Latin marks --

fn latinTable(cp: u21) ?[]const u8 {
    return switch (cp) {
        0xF8 => "o", // ø
        0x111 => "d", // đ
        0x142 => "l", // ł
        0x127 => "h", // ħ
        0x167 => "t", // ŧ
        0x131 => "i", // ı
        0xE6 => "ae", // æ
        0x153 => "oe", // œ
        else => null,
    };
}

fn decomposeInto(allocator: std.mem.Allocator, cp: u21, out: *std.ArrayList(u21)) Error!void {
    if (decompositionOf(cp)) |parts| {
        try decomposeInto(allocator, parts[0], out);
        if (parts[1] != 0) try decomposeInto(allocator, parts[1], out);
        return;
    }
    try out.append(allocator, cp);
}

// ---------------------------------------------------- S: English plural --

const plural_keep = [_][]const u8{
    "news",     "species",      "series",  "always",    "perhaps",    "christmas", "lens",       "atlas",
    "canvas",   "bias",         "alias",   "chaos",     "cosmos",     "pants",     "trousers",   "scissors",
    "glasses",  "maths",        "physics", "athletics", "gymnastics", "politics",  "measles",    "mumps",
    "means",    "lots",         "thanks",  "towards",   "afterwards", "upstairs",  "downstairs", "indoors",
    "outdoors", "headquarters", "whereas", "yes",       "does",       "goes",      "was",        "has",
    "his",      "its",          "this",    "thus",      "plus",       "bus",       "gas",        "us",
    "is",       "as",
};

fn inList(list: []const []const u8, piece: []const u8) bool {
    for (list) |word| if (std.mem.eql(u8, word, piece)) return true;
    return false;
}

/// S's output length (a prefix of `piece`) and whether a final `y` follows it.
const Stem = struct { len: usize, y: bool = false };

fn stemPlural(piece: []const u8) Stem {
    const whole = Stem{ .len = piece.len };
    if (piece.len < 3 or piece.len > 49) return whole;
    for (piece) |b| if (b < 'a' or b > 'z') return whole;
    const ends = std.mem.endsWith;
    if (ends(u8, piece, "ss") or ends(u8, piece, "us") or ends(u8, piece, "is") or !ends(u8, piece, "s")) return whole;
    if (inList(&plural_keep, piece)) return whole;
    if (ends(u8, piece, "ies")) {
        return if (piece.len >= 5) .{ .len = piece.len - 3, .y = true } else .{ .len = piece.len - 1 };
    }
    if (ends(u8, piece, "sses") or ends(u8, piece, "xes") or ends(u8, piece, "ches") or
        ends(u8, piece, "shes") or ends(u8, piece, "zzes")) return .{ .len = piece.len - 2 };
    if (ends(u8, piece, "oes") and piece.len >= 6) return .{ .len = piece.len - 2 };
    if (piece.len >= 4) return .{ .len = piece.len - 1 };
    return whole;
}

// ------------------------------------------------------------- T: Tamil --

const tamil_keep = [_][]const u8{ "நாங்கள்", "நீங்கள்", "உங்கள்", "எங்கள்", "தங்கள்", "அவர்கள்", "இவர்கள்", "மக்கள்" };
const tamil_vowel_signs = [_][]const u8{ "ா", "ி", "ீ", "ு", "ூ", "ெ", "ே", "ை", "ொ", "ோ", "ௌ" };
const tamil_i_ai = [_][]const u8{ "ி", "ீ", "ை" };

const TamilRule = struct { suffix: []const u8, replacement: []const u8, stem_ends: ?[]const []const u8 };
const tamil_rules = [_]TamilRule{
    .{ .suffix = "ங்கள்", .replacement = "ம்", .stem_ends = null },
    .{ .suffix = "கள்", .replacement = "", .stem_ends = null },
    .{ .suffix = "த்தில்", .replacement = "ம்", .stem_ends = null },
    .{ .suffix = "த்தின்", .replacement = "ம்", .stem_ends = null },
    .{ .suffix = "க்கு", .replacement = "", .stem_ends = &tamil_vowel_signs },
    .{ .suffix = "யில்", .replacement = "", .stem_ends = &tamil_i_ai },
    .{ .suffix = "யின்", .replacement = "", .stem_ends = &tamil_i_ai },
};

/// Tamil letters (U+0B85-U+0BB9) in valid UTF-8 `text`.
fn tamilLetters(text: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch unreachable;
        const cp = std.unicode.utf8Decode(text[i .. i + len]) catch unreachable;
        if (cp >= 0x0B85 and cp <= 0x0BB9) n += 1;
        i += len;
    }
    return n;
}

fn allTamil(text: []const u8) bool {
    if (text.len == 0) return false;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch return false;
        if (i + len > text.len) return false;
        const cp = std.unicode.utf8Decode(text[i .. i + len]) catch return false;
        if (cp < 0x0B80 or cp > 0x0BFF) return false;
        i += len;
    }
    return true;
}

/// T: appends the stemmed `piece` to `out`.
fn appendTamil(allocator: std.mem.Allocator, piece: []const u8, out: *std.ArrayList(u8)) Error!void {
    if (allTamil(piece) and !inList(&tamil_keep, piece)) {
        for (tamil_rules) |rule| {
            if (!std.mem.endsWith(u8, piece, rule.suffix)) continue;
            const stem = piece[0 .. piece.len - rule.suffix.len];
            if (rule.stem_ends) |ends| {
                var ok = false;
                for (ends) |e| if (std.mem.endsWith(u8, stem, e)) {
                    ok = true;
                    break;
                };
                if (!ok) continue;
            }
            if (tamilLetters(stem) + tamilLetters(rule.replacement) >= 2) {
                try out.appendSlice(allocator, stem);
                try out.appendSlice(allocator, rule.replacement);
                return;
            }
        }
    }
    try out.appendSlice(allocator, piece);
}

// ------------------------------------------------------------------- K --

/// K's working buffers, reused across calls (nothing in them outlives a call).
pub const Keyer = struct {
    allocator: std.mem.Allocator,
    folded: std.ArrayList(u8) = .empty,
    cps: std.ArrayList(u21) = .empty,
    run: std.ArrayList(u8) = .empty,
    marks: std.ArrayList(u21) = .empty,
    marked: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Keyer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Keyer) void {
        self.folded.deinit(self.allocator);
        self.cps.deinit(self.allocator);
        self.run.deinit(self.allocator);
        self.marks.deinit(self.allocator);
        self.marked.deinit(self.allocator);
    }

    /// Appends K's pieces of `token` to `out`, each followed by one 0x00 byte
    /// (a v2 token never holds U+0000), and returns the piece count.
    pub fn appendPieces(self: *Keyer, token: []const u8, out: *std.ArrayList(u8)) Error!usize {
        const a = self.allocator;
        if (asciiWord(token)) {
            // F is ASCII lowercasing; A leaves ASCII; T cannot apply.
            const start = out.items.len;
            try out.ensureUnusedCapacity(a, token.len + 2);
            for (token) |b| out.appendAssumeCapacity(std.ascii.toLower(b));
            const stem = stemPlural(out.items[start..]);
            out.items.len = start + stem.len;
            if (stem.y) out.appendAssumeCapacity('y');
            out.appendAssumeCapacity(0);
            return 1;
        }
        // F: the table or the simple fold per code point, then NFC.
        self.folded.clearRetainingCapacity();
        var view = std.unicode.Utf8View.init(token) catch return error.InvalidUtf8;
        var iterator = view.iterator();
        while (iterator.nextCodepoint()) |cp| {
            if (foldOutput(cp)) |bytes| {
                try self.folded.appendSlice(a, bytes);
            } else {
                try appendUtf8(a, &self.folded, simpleFold(cp));
            }
        }
        const normalized = try nfc.normalize(a, self.folded.items);
        defer a.free(normalized);
        // The v2 split of the folded text.
        try decode(a, normalized, &self.cps);
        var kept: usize = 0;
        for (self.cps.items) |cp| {
            if (isVariationSelector(cp)) continue;
            self.cps.items[kept] = cp;
            kept += 1;
        }
        const cps = self.cps.items[0..kept];
        var pieces: usize = 0;
        var in_token = false;
        self.run.clearRetainingCapacity();
        for (cps, 0..) |cp, i| {
            const continues = isLetterOrDigit(cp) or (in_token and (isMark(cp) or (isJoiner(cp) and
                i + 1 < cps.len and (isLetterOrDigit(cps[i + 1]) or isMark(cps[i + 1])))));
            if (continues) {
                in_token = true;
                try appendUtf8(a, &self.run, cp);
            } else if (in_token) {
                try self.finishPiece(out);
                pieces += 1;
                in_token = false;
            }
        }
        if (in_token) {
            try self.finishPiece(out);
            pieces += 1;
        }
        return pieces;
    }

    /// A, S and T on the piece in `self.run`, appended to `out` with its 0x00.
    fn finishPiece(self: *Keyer, out: *std.ArrayList(u8)) Error!void {
        const a = self.allocator;
        defer self.run.clearRetainingCapacity();
        var piece: []const u8 = self.run.items;
        var owned: ?[]u8 = null;
        defer if (owned) |o| a.free(o);
        if (!isAscii(piece)) {
            // A: decompose, map the eight letters, drop U+0300-U+036F after a-z, NFC.
            self.marks.clearRetainingCapacity();
            var view = std.unicode.Utf8View.init(piece) catch return error.InvalidUtf8;
            var iterator = view.iterator();
            while (iterator.nextCodepoint()) |cp| try decomposeInto(a, cp, &self.marks);
            self.marked.clearRetainingCapacity();
            var latin_base = false;
            for (self.marks.items) |cp| {
                if (isMark(cp)) {
                    if (latin_base and cp >= 0x300 and cp <= 0x36F) continue;
                    try appendUtf8(a, &self.marked, cp);
                    continue;
                }
                if (latinTable(cp)) |mapped| {
                    try self.marked.appendSlice(a, mapped);
                    latin_base = true;
                } else {
                    try appendUtf8(a, &self.marked, cp);
                    latin_base = cp >= 'a' and cp <= 'z';
                }
            }
            owned = try nfc.normalize(a, self.marked.items);
            piece = owned.?;
        }
        // S, then T (each applies to a piece the other never does).
        const stem = stemPlural(piece);
        if (stem.len != piece.len or stem.y) {
            try out.appendSlice(a, piece[0..stem.len]);
            if (stem.y) try out.append(a, 'y');
        } else {
            try appendTamil(a, piece, out);
        }
        try out.append(a, 0);
    }

    /// The group key of `term` (ruling 10): K's pieces joined by one space, or
    /// `term` itself when K leaves nothing. Appended to `out`.
    pub fn appendKey(self: *Keyer, term: []const u8, out: *std.ArrayList(u8)) Error!void {
        const start = out.items.len;
        const pieces = try self.appendPieces(term, out);
        if (pieces == 0) {
            try out.appendSlice(self.allocator, term);
            return;
        }
        // Each piece ends in 0x00: the last is dropped, the others become spaces.
        out.items.len -= 1;
        for (out.items[start..]) |*b| {
            if (b.* == 0) b.* = ' ';
        }
    }
};

fn isAscii(bytes: []const u8) bool {
    for (bytes) |b| if (b >= 0x80) return false;
    return true;
}

/// An ASCII run of letters and digits: one v2 token whose F is lowercasing.
fn asciiWord(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    for (bytes) |b| if (!std.ascii.isAlphanumeric(b)) return false;
    return true;
}

/// K's pieces of `token`, each owned by `allocator` (one allocation per piece
/// and one for the slice; free with `freePieces`).
pub fn keyTerms(allocator: std.mem.Allocator, token: []const u8) Error![][]u8 {
    var keyer = Keyer.init(allocator);
    defer keyer.deinit();
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(allocator);
    const n = try keyer.appendPieces(token, &bytes);
    const out = try allocator.alloc([]u8, n);
    var made: usize = 0;
    errdefer {
        for (out[0..made]) |p| allocator.free(p);
        allocator.free(out);
    }
    var it = std.mem.splitScalar(u8, bytes.items, 0);
    while (made < n) : (made += 1) out[made] = try allocator.dupe(u8, it.next().?);
    return out;
}

pub fn freePieces(allocator: std.mem.Allocator, pieces: [][]u8) void {
    for (pieces) |p| allocator.free(p);
    allocator.free(pieces);
}

/// The group key of `term`, owned by `allocator`.
pub fn key(allocator: std.mem.Allocator, term: []const u8) Error![]u8 {
    var keyer = Keyer.init(allocator);
    defer keyer.deinit();
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try keyer.appendKey(term, &out);
    return out.toOwnedSlice(allocator);
}

// ------------------------------------------------------------- key map --

/// The terms whose key is not themselves, sorted by (key, term index): with a
/// dictionary that holds every term whose key is itself, it answers "which
/// terms share this key" (ruling 10's members) without a second copy of the
/// dictionary. `terms` is the caller's list, kept by index only.
pub const KeyMap = struct {
    /// Into `keys`: entry i's key is keys[key_offsets[i]..key_offsets[i + 1]].
    key_offsets: []u32,
    keys: []u8,
    /// The term index of entry i (`deriveIndexed`: below `body_terms` a
    /// body dictionary index, else `body_terms` + a title field term index).
    term_of: []u32,
    body_terms: u32 = 0,
    /// `deriveIndexed`'s title field: the one its title numbers index (a
    /// query's own field may be another; members are looked up by bytes).
    field: ?*const title_field.Field = null,

    pub fn deinit(self: *KeyMap, allocator: std.mem.Allocator) void {
        allocator.free(self.key_offsets);
        allocator.free(self.keys);
        allocator.free(self.term_of);
        self.* = undefined;
    }

    pub fn len(self: KeyMap) usize {
        return self.term_of.len;
    }

    pub fn keyOf(self: KeyMap, i: usize) []const u8 {
        return self.keys[self.key_offsets[i]..self.key_offsets[i + 1]];
    }

    /// The bytes this map keeps.
    pub fn keptBytes(self: KeyMap) usize {
        return self.key_offsets.len * @sizeOf(u32) + self.keys.len + self.term_of.len * @sizeOf(u32);
    }

    /// The entries whose key is `k`, as a range of entry indexes.
    pub fn range(self: KeyMap, k: []const u8) struct { start: usize, end: usize } {
        var lo: usize = 0;
        var hi: usize = self.len();
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (std.mem.order(u8, self.keyOf(mid), k) == .lt) lo = mid + 1 else hi = mid;
        }
        var end = lo;
        while (end < self.len() and std.mem.eql(u8, self.keyOf(end), k)) end += 1;
        return .{ .start = lo, .end = end };
    }

    /// Builds the map over `terms` (any order). `scratch` holds the transient
    /// buffers and is freed before return; the map is owned by `allocator`.
    pub fn derive(allocator: std.mem.Allocator, scratch: std.mem.Allocator, terms: []const []const u8) Error!KeyMap {
        const Terms = struct {
            terms: []const []const u8,
            fn at(s: @This(), i: usize) ?[]const u8 {
                return s.terms[i];
            }
        };
        return deriveWith(allocator, scratch, terms.len, Terms{ .terms = terms }, Terms.at);
    }

    /// The query side's map (ruling 10): over the whole body dictionary and
    /// the title field's terms the body does not hold, numbered body first.
    /// No term list is built: each term is read where it lies.
    pub fn deriveIndexed(allocator: std.mem.Allocator, scratch: std.mem.Allocator, index: postings.Index, field: ?*const title_field.Field) Error!KeyMap {
        const Terms = struct {
            index: postings.Index,
            field: ?*const title_field.Field,
            fn at(s: @This(), i: usize) ?[]const u8 {
                if (i < s.index.terms.len) return s.index.terms[i].term;
                const f = s.field.?;
                const bytes = f.termBytes(f.terms[i - s.index.terms.len]);
                if (postings.lookupExact(s.index, bytes) != null) return null;
                return bytes;
            }
        };
        const titles = if (field) |f| f.terms.len else 0;
        var map = try deriveWith(allocator, scratch, index.terms.len + titles, Terms{ .index = index, .field = field }, Terms.at);
        map.body_terms = @intCast(index.terms.len);
        map.field = field;
        return map;
    }

    /// `derive` over `n` terms read by `termAt` (null: skip that number).
    pub fn deriveWith(allocator: std.mem.Allocator, scratch: std.mem.Allocator, n_terms: usize, source: anytype, comptime termAt: fn (@TypeOf(source), usize) ?[]const u8) Error!KeyMap {
        var keyer = Keyer.init(scratch);
        defer keyer.deinit();
        var buffer = std.ArrayList(u8).empty;
        defer buffer.deinit(scratch);
        const Entry = struct { start: u32, end: u32, term: u32 };
        var entries = std.ArrayList(Entry).empty;
        defer entries.deinit(scratch);
        var pool = std.ArrayList(u8).empty;
        defer pool.deinit(scratch);
        for (0..n_terms) |i| {
            const term = termAt(source, i) orelse continue;
            buffer.clearRetainingCapacity();
            try keyer.appendKey(term, &buffer);
            if (std.mem.eql(u8, buffer.items, term)) continue;
            const start: u32 = @intCast(pool.items.len);
            try pool.appendSlice(scratch, buffer.items);
            try entries.append(scratch, .{ .start = start, .end = @intCast(pool.items.len), .term = @intCast(i) });
        }
        const Ctx = struct {
            pool: []const u8,
            fn less(ctx: @This(), x: Entry, y: Entry) bool {
                return switch (std.mem.order(u8, ctx.pool[x.start..x.end], ctx.pool[y.start..y.end])) {
                    .lt => true,
                    .gt => false,
                    .eq => x.term < y.term,
                };
            }
        };
        std.mem.sort(Entry, entries.items, Ctx{ .pool = pool.items }, Ctx.less);
        const n = entries.items.len;
        const key_offsets = try allocator.alloc(u32, n + 1);
        errdefer allocator.free(key_offsets);
        const term_of = try allocator.alloc(u32, n);
        errdefer allocator.free(term_of);
        var total: usize = 0;
        for (entries.items) |e| total += e.end - e.start;
        const keys = try allocator.alloc(u8, total);
        var at: u32 = 0;
        for (entries.items, 0..) |e, i| {
            key_offsets[i] = at;
            @memcpy(keys[at..][0 .. e.end - e.start], pool.items[e.start..e.end]);
            at += e.end - e.start;
            term_of[i] = e.term;
        }
        key_offsets[n] = at;
        return .{ .key_offsets = key_offsets, .keys = keys, .term_of = term_of };
    }
};

// ------------------------------------------------------- the query side --

/// The term of map numbering `i` (`KeyMap.deriveIndexed`): a body entry, or
/// a title-only term.
const Numbered = struct { body: ?postings.TermEntry, bytes: []const u8 };

fn numbered(context: fuzzy.Context, map: *const KeyMap, i: u32) Numbered {
    if (i < map.body_terms) {
        const entry = context.index.terms[i];
        return .{ .body = entry, .bytes = entry.term };
    }
    const field = map.field.?;
    return .{ .body = null, .bytes = field.termBytes(field.terms[i - map.body_terms]) };
}

/// One candidate of a group (ruling 10), or null when the request cannot use
/// it: a body term held by a chunk in scope (path prefix included) is a body
/// member; otherwise a term a visible title under the prefix holds is a
/// title member (no body postings). The order's key df is the term's body df
/// over the roots and labels (a prefix does not narrow it), 0 for a term the
/// body does not hold.
fn member(context: fuzzy.Context, candidate: Numbered) ?fuzzy.Member {
    const key_df: u32 = if (candidate.body) |entry| context.keyFrequency(entry) else 0;
    if (candidate.body) |entry| if (context.heldInScope(entry)) {
        return .{ .term = entry.term, .distance = 0, .weight = 1, .key_df = key_df, .body = entry };
    };
    const field = context.title orelse return null;
    const term = field.lookup(candidate.bytes) orelse return null;
    if (!context.titleHeld(field, term, true)) return null;
    return .{ .term = field.termBytes(term), .distance = 0, .weight = 1, .key_df = key_df, .body = null };
}

/// The group order: the typed term first, then key df descending, then bytes.
fn memberBefore(typed: []const u8, a: fuzzy.Member, b: fuzzy.Member) bool {
    const a_typed = std.mem.eql(u8, a.term, typed);
    const b_typed = std.mem.eql(u8, b.term, typed);
    if (a_typed != b_typed) return a_typed;
    if (a.key_df != b.key_df) return a.key_df > b.key_df;
    return std.mem.order(u8, a.term, b.term) == .lt;
}

/// fold-groups-v1 (ruling 10): for each distinct token, the in-scope body
/// terms and visible title terms whose key equals the token's, each at weight
/// 1.0; a group is kept when it is not empty and not the token alone. Null
/// when no token has one. The groups score through fuzzy-v1's machinery (one
/// shared df, the best member per chunk); `map` is over the whole index and
/// the scope is applied here, at use.
pub fn compute(allocator: std.mem.Allocator, context: fuzzy.Context, map: *const KeyMap, tokens: []const []const u8) !?fuzzy.Groups {
    var keyer = Keyer.init(allocator);
    defer keyer.deinit();
    var k = std.ArrayList(u8).empty;
    defer k.deinit(allocator);
    var kk = std.ArrayList(u8).empty;
    defer kk.deinit(allocator);
    var members = std.ArrayList(fuzzy.Member).empty;
    defer members.deinit(allocator);
    var items = std.ArrayList(fuzzy.Group).empty;
    errdefer {
        for (items.items) |g| {
            allocator.free(g.typed);
            allocator.free(g.members);
        }
        items.deinit(allocator);
    }
    for (tokens, 0..) |token, position| {
        var repeated = false;
        for (tokens[0..position]) |earlier| if (std.mem.eql(u8, earlier, token)) {
            repeated = true;
            break;
        };
        if (repeated) continue;
        k.clearRetainingCapacity();
        try keyer.appendKey(token, &k);
        members.clearRetainingCapacity();
        // The term equal to the key, when its own key is itself.
        const self: ?Numbered = if (postings.lookupExact(context.index, k.items)) |i|
            .{ .body = context.index.terms[i], .bytes = context.index.terms[i].term }
        else if (context.title) |field| (if (field.lookup(k.items)) |term| Numbered{ .body = null, .bytes = field.termBytes(term) } else null) else null;
        if (self) |candidate| {
            kk.clearRetainingCapacity();
            try keyer.appendKey(candidate.bytes, &kk);
            if (std.mem.eql(u8, kk.items, k.items)) if (member(context, candidate)) |m| try members.append(allocator, m);
        }
        const r = map.range(k.items);
        for (map.term_of[r.start..r.end]) |i| if (member(context, numbered(context, map, i))) |m| try members.append(allocator, m);
        if (members.items.len == 0) continue;
        if (members.items.len == 1 and std.mem.eql(u8, members.items[0].term, token)) continue;
        std.mem.sort(fuzzy.Member, members.items, token, memberBefore);
        const owned = try allocator.dupe(fuzzy.Member, members.items);
        errdefer allocator.free(owned);
        const typed = try allocator.dupe(u8, token);
        errdefer allocator.free(typed);
        try items.append(allocator, .{ .typed = typed, .members = owned });
    }
    if (items.items.len == 0) {
        items.deinit(allocator);
        return null;
    }
    return .{ .items = try items.toOwnedSlice(allocator) };
}

/// The tokens without a group in `groups` (fuzzy-v1 runs on these only),
/// borrowed from `tokens`.
pub fn ungrouped(allocator: std.mem.Allocator, tokens: []const []const u8, groups: ?fuzzy.Groups) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    errdefer out.deinit(allocator);
    for (tokens) |token| {
        if (groups) |g| if (g.of(token) != null) continue;
        try out.append(allocator, token);
    }
    return out.toOwnedSlice(allocator);
}

/// Both sets of groups as one (fold groups first), taking ownership of
/// their contents; null when both are null.
pub fn merge(allocator: std.mem.Allocator, folded: ?fuzzy.Groups, expanded: ?fuzzy.Groups) !?fuzzy.Groups {
    const a = folded orelse return expanded;
    const b = expanded orelse return folded;
    const items = try allocator.alloc(fuzzy.Group, a.items.len + b.items.len);
    @memcpy(items[0..a.items.len], a.items);
    @memcpy(items[a.items.len..], b.items);
    allocator.free(a.items);
    allocator.free(b.items);
    return .{ .items = items };
}

test "K on the traps of rulings 2-5" {
    const a = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "ｇｏｇｇｌｅｓ", "goggle" },
        .{ "ﬂute", "flute" },
        .{ "１２", "12" },
        .{ "straße", "strasse" },
        .{ "Ⅻ", "xii" },
        .{ "x²", "x2" },
        .{ "½", "1 2" },
        .{ "résumé", "resume" },
        .{ "łódź", "lodz" },
        .{ "æsop", "aesop" },
        .{ "boxes", "box" },
        .{ "ponies", "pony" },
        .{ "ties", "tie" },
        .{ "buses", "buse" },
        .{ "glasses", "glasses" },
        .{ "shoes", "shoe" },
        .{ "potatoes", "potato" },
        .{ "நாட்கள்", "நாட்" },
        .{ "மரங்கள்", "மரம்" },
        .{ "நாங்கள்", "நாங்கள்" },
        .{ "Boxes", "box" },
    };
    for (cases) |case| {
        const k = try key(a, case[0]);
        defer a.free(k);
        std.testing.expectEqualStrings(case[1], k) catch |err| {
            std.debug.print("K({s})\n", .{case[0]});
            return err;
        };
    }
}

test "the key map groups terms by key" {
    const a = std.testing.allocator;
    const terms = [_][]const u8{ "box", "boxes", "café", "cafe", "cafés", "zebra" };
    var map = try KeyMap.derive(a, a, &terms);
    defer map.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), map.len());
    const r = map.range("cafe");
    try std.testing.expectEqual(@as(usize, 2), r.end - r.start);
    try std.testing.expectEqual(@as(u32, 2), map.term_of[r.start]);
    try std.testing.expectEqual(@as(u32, 4), map.term_of[r.start + 1]);
    const b = map.range("box");
    try std.testing.expectEqual(@as(u32, 1), map.term_of[b.start]);
    try std.testing.expectEqual(@as(usize, 0), map.range("zebra").end - map.range("zebra").start);
}
