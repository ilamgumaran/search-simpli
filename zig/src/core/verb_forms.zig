//! R, the verb-form rule of `fold-groups-v2` (S5-T5, docs/tasks/S5-T5.md
//! ruling 2 as restated in docs/tasks/S5-T5-prototype.md; docs/fold-groups-v2.md).
//!
//! R reads nothing but its word: no dictionary, no file. The word is
//! u = A(F(t)) of a query term t when F leaves one piece of 4 to 49 letters
//! a-z (`fold.Keyer.appendWord`); with p = S(u), its bases are, in order and
//! without repeats:
//!
//!   p;
//!   when p ends in -ing, the remainder r = p less -ing, when r has at least 3
//!     letters and holds one of a, e, i, o, u, y: r, r + e, and r undoubled
//!     (its last letter dropped when the last two are one consonant other than
//!     l, s, z);
//!   the same for -ed;
//!   when p ends in -ied and has at least 5 letters: p less -ied, plus y.
//!
//! The relatives of a base b are b, bs, bes, bed, bing; when b ends in e, bd
//! and b less e plus ing; when b ends consonant, vowel, consonant (y counted a
//! consonant), b doubled plus ed and plus ing; when b ends in a consonant and
//! y, b less y plus ies and plus ied. A vowel is one of a, e, i, o, u. The
//! forms of t are the relatives of every base, t itself left out, first seen
//! first: one exact lookup each.
//!
//! fold-groups-v3 (S5-T8, docs/fold-groups-v3.md) searches only R's eligible
//! forms (`eligibleForms`): R's forms less those of another word. A base b
//! has the doubling shape (`doublingShape`) when it has one vowel group (a, e,
//! i, o, u; y a consonant) and ends consonant, vowel, consonant, the last not
//! w, x or y. Then (i) for a base of the doubling shape, b + ed, b + ing and
//! (unless b ends s, x, z, ch or sh) b + es are left out; (ii) when p is
//! r + ing or r + ed with r of the doubling shape, the base r is left out.
//!
//! Everything here is on the stack: at most `max_bases` bases and `max_forms`
//! forms of at most `max_len` bytes. The Python mirror is
//! `src/search_platform/verb_forms.py`; `verb_forms_test.zig` checks this file
//! against its golden, `fixtures/verb-forms-golden.json`.

const std = @import("std");
const fold = @import("fold.zig");

pub const min_letters = 4;
pub const max_letters = 49;
const min_remainder = 3;
const min_ied = 5;

/// p, three for -ing or for -ed, and one for -ied (a word ends in at most one
/// of -ing and -ed; -ied ends in -ed).
pub const max_bases = 5;
/// Nine relatives a base at most (five, and two of the three pairs: the
/// e-ending and the doubling exclude each other, as do the doubling and the
/// consonant-y pair).
pub const max_forms = max_bases * 9;
/// A base is at most 49 + 1 letters (r + e); a relative adds at most four.
pub const max_len = 56;

/// A short list of distinct words, first seen first.
pub const Words = struct {
    bytes: [max_forms][max_len]u8 = undefined,
    lens: [max_forms]u8 = undefined,
    len: usize = 0,

    pub fn get(words: *const Words, i: usize) []const u8 {
        return words.bytes[i][0..words.lens[i]];
    }

    fn has(words: *const Words, word: []const u8) bool {
        for (0..words.len) |i| if (std.mem.eql(u8, words.get(i), word)) return true;
        return false;
    }

    /// Appends the concatenation of `parts` unless it is already listed or
    /// equals `skip`.
    fn add(words: *Words, parts: []const []const u8, skip: []const u8) void {
        var buf: [max_len]u8 = undefined;
        var n: usize = 0;
        for (parts) |p| {
            @memcpy(buf[n .. n + p.len], p);
            n += p.len;
        }
        const word = buf[0..n];
        if (std.mem.eql(u8, word, skip) or words.has(word)) return;
        std.debug.assert(words.len < max_forms);
        @memcpy(words.bytes[words.len][0..n], word);
        words.lens[words.len] = @intCast(n);
        words.len += 1;
    }
};

fn vowel(c: u8) bool {
    return c == 'a' or c == 'e' or c == 'i' or c == 'o' or c == 'u';
}

fn consonant(c: u8) bool {
    return !vowel(c);
}

/// Whether `u` is a word R applies to: 4 to 49 letters a-z.
pub fn applies(u: []const u8) bool {
    if (u.len < min_letters or u.len > max_letters) return false;
    for (u) |c| if (c < 'a' or c > 'z') return false;
    return true;
}

fn remainderBases(r: []const u8, out: *Words) void {
    if (r.len < min_remainder) return;
    var has_vowel = false;
    for (r) |c| if (vowel(c) or c == 'y') {
        has_vowel = true;
        break;
    };
    if (!has_vowel) return;
    out.add(&.{r}, "");
    out.add(&.{ r, "e" }, "");
    const last = r[r.len - 1];
    if (r.len >= 2 and last == r[r.len - 2] and consonant(last) and last != 'l' and last != 's' and last != 'z') {
        out.add(&.{r[0 .. r.len - 1]}, "");
    }
}

/// p = S(u), written into `buf`.
fn plural(u: []const u8, buf: *[max_len]u8) []const u8 {
    const stem = fold.stemPlural(u);
    @memcpy(buf[0..stem.len], u[0..stem.len]);
    var len = stem.len;
    if (stem.y) {
        buf[len] = 'y';
        len += 1;
    }
    return buf[0..len];
}

/// The bases of the word `u` (`applies(u)` holds), in order, without repeats.
pub fn bases(u: []const u8, out: *Words) void {
    std.debug.assert(applies(u));
    out.len = 0;
    var p_buf: [max_len]u8 = undefined;
    const p = plural(u, &p_buf);
    out.add(&.{p}, "");
    if (std.mem.endsWith(u8, p, "ing")) remainderBases(p[0 .. p.len - 3], out);
    if (std.mem.endsWith(u8, p, "ed")) remainderBases(p[0 .. p.len - 2], out);
    if (std.mem.endsWith(u8, p, "ied") and p.len >= min_ied) out.add(&.{ p[0 .. p.len - 3], "y" }, "");
}

/// Appends the relatives of base `b` to `out`, each unless already listed
/// or equal to `skip`.
pub fn appendRelatives(b: []const u8, skip: []const u8, out: *Words) void {
    out.add(&.{b}, skip);
    out.add(&.{ b, "s" }, skip);
    out.add(&.{ b, "es" }, skip);
    out.add(&.{ b, "ed" }, skip);
    out.add(&.{ b, "ing" }, skip);
    const n = b.len;
    if (b[n - 1] == 'e') {
        out.add(&.{ b, "d" }, skip);
        out.add(&.{ b[0 .. n - 1], "ing" }, skip);
    }
    if (n >= 3 and consonant(b[n - 3]) and vowel(b[n - 2]) and consonant(b[n - 1])) {
        out.add(&.{ b, b[n - 1 ..], "ed" }, skip);
        out.add(&.{ b, b[n - 1 ..], "ing" }, skip);
    }
    if (n >= 2 and b[n - 1] == 'y' and consonant(b[n - 2])) {
        out.add(&.{ b[0 .. n - 1], "ies" }, skip);
        out.add(&.{ b[0 .. n - 1], "ied" }, skip);
    }
}

/// R's forms of a term whose word is `u`: every relative of every base, the
/// term itself (`term`, its bytes as typed) left out, first seen first.
pub fn forms(u: []const u8, term: []const u8, out: *Words) void {
    var b = Words{};
    bases(u, &b);
    out.len = 0;
    for (0..b.len) |i| appendRelatives(b.get(i), term, out);
}

fn vowelGroups(word: []const u8) usize {
    var groups: usize = 0;
    var inside = false;
    for (word) |c| {
        const v = vowel(c);
        if (v and !inside) groups += 1;
        inside = v;
    }
    return groups;
}

/// fold-groups-v3: one vowel group, ending consonant, vowel, consonant, the
/// last not w, x or y.
pub fn doublingShape(b: []const u8) bool {
    const n = b.len;
    if (n < 3) return false;
    const last = b[n - 1];
    return consonant(last) and last != 'w' and last != 'x' and last != 'y' and vowel(b[n - 2]) and
        consonant(b[n - 3]) and vowelGroups(b) == 1;
}

fn esKept(b: []const u8) bool {
    const last = b[b.len - 1];
    return last == 's' or last == 'x' or last == 'z' or std.mem.endsWith(u8, b, "ch") or std.mem.endsWith(u8, b, "sh");
}

/// Whether r = p less `suffix` is a left-out base (rule (ii)).
fn leftOut(p: []const u8, suffix: []const u8, base: []const u8) bool {
    return std.mem.endsWith(u8, p, suffix) and base.len == p.len - suffix.len and
        std.mem.eql(u8, base, p[0 .. p.len - suffix.len]) and doublingShape(base);
}

/// fold-groups-v3's forms of a term whose word is `u`: R's forms less those
/// of another word (rules (i) and (ii)), the term itself left out, first
/// seen first.
pub fn eligibleForms(u: []const u8, term: []const u8, out: *Words) void {
    var b = Words{};
    bases(u, &b);
    var p_buf: [max_len]u8 = undefined;
    const p = plural(u, &p_buf);
    out.len = 0;
    for (0..b.len) |i| {
        const base = b.get(i);
        if (leftOut(p, "ing", base) or leftOut(p, "ed", base)) continue;
        var rel = Words{};
        appendRelatives(base, term, &rel);
        const doubling = doublingShape(base);
        for (0..rel.len) |j| {
            const form = rel.get(j);
            if (doubling and form.len > base.len and std.mem.startsWith(u8, form, base)) {
                const tail = form[base.len..];
                if (std.mem.eql(u8, tail, "ed") or std.mem.eql(u8, tail, "ing")) continue;
                if (std.mem.eql(u8, tail, "es") and !esKept(base)) continue;
            }
            out.add(&.{form}, term);
        }
    }
}

test "bases and forms of a few words" {
    var out = Words{};
    bases("hopping", &out);
    try std.testing.expectEqual(@as(usize, 4), out.len);
    try std.testing.expectEqualStrings("hop", out.get(3));
    out.len = 0;
    appendRelatives("hop", "hop", &out);
    const want = [_][]const u8{ "hops", "hopes", "hoped", "hoping", "hopped", "hopping" };
    try std.testing.expectEqual(want.len, out.len);
    for (want, 0..) |w, i| try std.testing.expectEqualStrings(w, out.get(i));
    bases("tidied", &out);
    try std.testing.expectEqualStrings("tidy", out.get(out.len - 1));
    try std.testing.expect(!applies("aaa"));
    try std.testing.expect(applies("a" ** 49));
    try std.testing.expect(!applies("a" ** 50));
    try std.testing.expect(!applies("ab1d"));
}

test "the largest word fits the buffers" {
    var out = Words{};
    // 46 letters + "ied": the -ed remainder (47 letters) and its e, the
    // -ied base, each with every relative.
    forms("bab" ** 15 ++ "bied", "x", &out);
    try std.testing.expect(out.len <= max_forms);
}

test "eligible forms: the doubling shape and its left-out forms" {
    try std.testing.expect(doublingShape("hop"));
    try std.testing.expect(doublingShape("car"));
    try std.testing.expect(!doublingShape("box"));
    try std.testing.expect(!doublingShape("row"));
    try std.testing.expect(!doublingShape("visit"));
    try std.testing.expect(!doublingShape("oil"));
    var out = Words{};
    // hopping: the base hop keeps hops but not hoped, hoping, hopes (hope's).
    eligibleForms("hopping", "hopping", &out);
    const hopping = [_][]const u8{ "hoppings", "hoppinges", "hoppinged", "hoppinging", "hopp", "hopps", "hoppes", "hopped", "hoppe", "hoppees", "hoppeed", "hoppeing", "hop", "hops" };
    try std.testing.expectEqual(hopping.len, out.len);
    for (hopping, 0..) |w, i| try std.testing.expectEqualStrings(w, out.get(i));
    // hoping: rule (ii) leaves the base hop out; hope stays.
    eligibleForms("hoping", "hoping", &out);
    const hoping = [_][]const u8{ "hopings", "hopinges", "hopinged", "hopinging", "hope", "hopes", "hopees", "hopeed", "hopeing", "hoped" };
    try std.testing.expectEqual(hoping.len, out.len);
    for (hoping, 0..) |w, i| try std.testing.expectEqualStrings(w, out.get(i));
}
