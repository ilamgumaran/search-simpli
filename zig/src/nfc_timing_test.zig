//! S1-T16: NFC of one very long line must take time linear in its length.
//!
//! The old recomposition removed every consumed codepoint from the middle of
//! an array, so a Korean line (every syllable is decomposed to jamo and
//! recomposed) with a single combining mark took 17 s at 1 MB against 48 ms
//! before Hangul was composed. The test normalizes a 256 KB and a 1 MB
//! line holding one mark, plus their mark-free twins, interleaved, best of
//! three each, and asserts (1) the growth between sizes stays at most 5x
//! (4x for linear, plus 25 %; quadratic is 16x) and (2) the line with the
//! mark takes at most twice what its mark-free twin takes, plus a small
//! slack for timer granularity. Nothing is a single wall-clock threshold.
//! A second family guards `compose` itself (S1-T17): one line of decomposed
//! jamo with no spaces (L V T triples), so the whole line is a single mark
//! region of 256 KB or 1 MB; the line with one mark never makes a region
//! longer than a few codepoints, so it cannot see a quadratic `compose`. Its
//! twin is the same jamo with a space after each triple (identical codepoints,
//! regions of three). The precomposed-syllable twin is not used: it holds a
//! third of the codepoints and takes half the time on correct code, which
//! leaves no room under "at most twice". Same two assertions.
//!
//! Kept in its own file so restoring the old `nfc.zig` leaves it in place
//! and makes it fail.
const std = @import("std");
const nfc = @import("nfc.zig");

const runs = 3;
const small_bytes: usize = 256 * 1024;
const large_bytes: usize = 1024 * 1024;

fn line(allocator: std.mem.Allocator, size: usize, with_mark: bool) ![]u8 {
    const words = [_][]const u8{ "한글", "학교", "가나다라", "마음의", "구름", "하늘과", "바람", "별빛", "꽃잎", "각막" };
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var marked = !with_mark;
    var i: usize = 0;
    while (out.items.len < size) : (i += 1) {
        if (!marked and out.items.len >= size / 2) {
            try out.appendSlice(allocator, "e\u{0301} "); // the one combining mark
            marked = true;
        }
        try out.appendSlice(allocator, words[i % words.len]);
        try out.append(allocator, ' ');
    }
    return out.toOwnedSlice(allocator);
}

const Form = enum {
    jamo, // L V T jamo, no spaces: the whole line is one mark region
    spaced, // the same jamo with a space after each triple: regions of 3
    syllables, // the same triples as precomposed syllables (already NFC)
};

/// `triples` L V T triples in the given form.
fn jamoLine(allocator: std.mem.Allocator, triples: usize, form: Form) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var buf: [4]u8 = undefined;
    for (0..triples) |n| {
        const i: u32 = @intCast(n);
        const l: u21 = 0x1100 + @as(u21, @intCast((i * 7) % 19));
        const v: u21 = 0x1161 + @as(u21, @intCast((i * 5) % 21));
        const t: u21 = 0x11A8 + @as(u21, @intCast((i * 3) % 27)); // 11A8..11C2
        if (form == .syllables) {
            const syllable: u21 = 0xAC00 + ((l - 0x1100) * 21 + (v - 0x1161)) * 28 + (t - 0x11A7);
            try out.appendSlice(allocator, buf[0..try std.unicode.utf8Encode(syllable, &buf)]);
        } else for ([_]u21{ l, v, t }) |cp| {
            try out.appendSlice(allocator, buf[0..try std.unicode.utf8Encode(cp, &buf)]);
        }
        if (form == .spaced) try out.append(allocator, ' ');
    }
    return out.toOwnedSlice(allocator);
}

fn nanoseconds(io: std.Io, text: []const u8) !i96 {
    const start = std.Io.Clock.awake.now(io).nanoseconds;
    const out = try nfc.normalize(std.testing.allocator, text);
    const finished = std.Io.Clock.awake.now(io).nanoseconds;
    std.testing.allocator.free(out);
    return finished - start;
}

fn ms(ns: i96) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

test "NFC time grows linearly with the length of one line (S1-T16)" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    const small_mark = try line(a, small_bytes, true);
    defer a.free(small_mark);
    const small_plain = try line(a, small_bytes, false);
    defer a.free(small_plain);
    const large_mark = try line(a, large_bytes, true);
    defer a.free(large_mark);
    const large_plain = try line(a, large_bytes, false);
    defer a.free(large_plain);

    // The mark really sends the line down the slow path.
    {
        const out = try nfc.normalize(a, large_mark);
        defer a.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "\u{00E9}") != null);
        try std.testing.expect(std.mem.indexOf(u8, small_plain, "\u{0301}") == null);
    }

    var best_small_mark: i96 = std.math.maxInt(i96);
    var best_large_mark: i96 = std.math.maxInt(i96);
    var best_small_plain: i96 = std.math.maxInt(i96);
    var best_large_plain: i96 = std.math.maxInt(i96);
    for (0..runs) |_| {
        best_small_mark = @min(best_small_mark, try nanoseconds(io, small_mark));
        best_large_mark = @min(best_large_mark, try nanoseconds(io, large_mark));
        best_small_plain = @min(best_small_plain, try nanoseconds(io, small_plain));
        best_large_plain = @min(best_large_plain, try nanoseconds(io, large_plain));
    }
    const growth = @as(f64, @floatFromInt(best_large_mark)) / @as(f64, @floatFromInt(@max(best_small_mark, 1)));
    std.debug.print(
        "\nnfc best-of-{d}: 256 KB mark {d:.2} ms plain {d:.2} ms; 1 MB mark {d:.2} ms plain {d:.2} ms; growth {d:.2}x\n",
        .{ runs, ms(best_small_mark), ms(best_small_plain), ms(best_large_mark), ms(best_large_plain), growth },
    );
    // 4x the length: linear is 4x, quadratic is 16x.
    try std.testing.expect(growth < 5.0);
    // At most twice the mark-free twin, plus 2 ms of slack.
    const slack: i96 = 2 * std.time.ns_per_ms;
    try std.testing.expect(best_small_mark <= 2 * best_small_plain + slack);
    try std.testing.expect(best_large_mark <= 2 * best_large_plain + slack);
}

test "NFC time grows linearly across one long mark region (S1-T17)" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    const small_jamo = try jamoLine(a, small_bytes / 9, .jamo);
    defer a.free(small_jamo);
    const small_twin = try jamoLine(a, small_bytes / 9, .spaced);
    defer a.free(small_twin);
    const large_jamo = try jamoLine(a, large_bytes / 9, .jamo);
    defer a.free(large_jamo);
    const large_twin = try jamoLine(a, large_bytes / 9, .spaced);
    defer a.free(large_twin);

    // The jamo line really is decomposed text that composes to the same text
    // as precomposed syllables.
    {
        const syllables = try jamoLine(a, 1000, .syllables);
        defer a.free(syllables);
        const out = try nfc.normalize(a, small_jamo[0 .. 1000 * 9]);
        defer a.free(out);
        try std.testing.expectEqualStrings(syllables, out);
        try std.testing.expect(std.mem.indexOfScalar(u8, small_twin, ' ') != null);
    }

    var best_small_jamo: i96 = std.math.maxInt(i96);
    var best_large_jamo: i96 = std.math.maxInt(i96);
    var best_small_twin: i96 = std.math.maxInt(i96);
    var best_large_twin: i96 = std.math.maxInt(i96);
    for (0..runs) |_| {
        best_small_jamo = @min(best_small_jamo, try nanoseconds(io, small_jamo));
        best_large_jamo = @min(best_large_jamo, try nanoseconds(io, large_jamo));
        best_small_twin = @min(best_small_twin, try nanoseconds(io, small_twin));
        best_large_twin = @min(best_large_twin, try nanoseconds(io, large_twin));
    }
    const growth = @as(f64, @floatFromInt(best_large_jamo)) / @as(f64, @floatFromInt(@max(best_small_jamo, 1)));
    std.debug.print(
        "\nnfc jamo best-of-{d}: 256 KB jamo {d:.2} ms twin {d:.2} ms; 1 MB jamo {d:.2} ms twin {d:.2} ms; growth {d:.2}x\n",
        .{ runs, ms(best_small_jamo), ms(best_small_twin), ms(best_large_jamo), ms(best_large_twin), growth },
    );
    // 4x the length: linear is 4x, quadratic is 16x.
    try std.testing.expect(growth < 5.0);
    // At most twice the twin, plus 2 ms of slack.
    const slack: i96 = 2 * std.time.ns_per_ms;
    try std.testing.expect(best_small_jamo <= 2 * best_small_twin + slack);
    try std.testing.expect(best_large_jamo <= 2 * best_large_twin + slack);
}
