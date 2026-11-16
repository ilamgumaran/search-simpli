//! S6-T3 codec probe: an in-tree LZ4 block decoder (and, with `encode`, a
//! greedy encoder), the size and speed of a small codec written in the
//! repository. Build `lz4_decode.zig` or `lz4_both.zig`.
const std = @import("std");

pub fn decode(src: []const u8, dst: []u8) error{Corrupt}!usize {
    var s: usize = 0;
    var d: usize = 0;
    while (true) {
        if (s >= src.len) return error.Corrupt;
        const token = src[s];
        s += 1;
        var literals: usize = token >> 4;
        if (literals == 15) while (true) {
            if (s >= src.len) return error.Corrupt;
            const b = src[s];
            s += 1;
            literals += b;
            if (b != 255) break;
        };
        if (literals > src.len - s or literals > dst.len - d) return error.Corrupt;
        @memcpy(dst[d..][0..literals], src[s..][0..literals]);
        d += literals;
        s += literals;
        if (s == src.len) return d;
        if (src.len - s < 2) return error.Corrupt;
        const offset = @as(usize, src[s]) | (@as(usize, src[s + 1]) << 8);
        s += 2;
        var length: usize = (token & 15) + 4;
        if ((token & 15) == 15) while (true) {
            if (s >= src.len) return error.Corrupt;
            const b = src[s];
            s += 1;
            length += b;
            if (b != 255) break;
        };
        if (offset == 0 or offset > d or length > dst.len - d) return error.Corrupt;
        if (offset >= length) {
            @memcpy(dst[d..][0..length], dst[d - offset ..][0..length]);
        } else {
            for (0..length) |k| dst[d + k] = dst[d - offset + k];
        }
        d += length;
    }
}

fn extra(dst: []u8, o: *usize, value: usize) void {
    var v = value - 15;
    while (v >= 255) : (v -= 255) {
        dst[o.*] = 255;
        o.* += 1;
    }
    dst[o.*] = @intCast(v);
    o.* += 1;
}

/// Greedy, a 14-bit hash of four bytes, 64 KiB window; `dst` must hold
/// `src.len + src.len / 255 + 16` bytes.
pub fn encode(src: []const u8, dst: []u8, table: *[1 << 14]u32) usize {
    @memset(table, 0xFFFF_FFFF);
    const n = src.len;
    var o: usize = 0;
    var anchor: usize = 0;
    var i: usize = 0;
    const limit = if (n > 12) n - 12 else 0;
    while (i < limit) {
        const key = std.mem.readInt(u32, src[i..][0..4], .little);
        const h = (key *% 2654435761) >> 18;
        const c = table[h];
        table[h] = @intCast(i);
        if (c != 0xFFFF_FFFF and i - c < 65536 and std.mem.readInt(u32, src[c..][0..4], .little) == key) {
            var length: usize = 4;
            while (i + length < n - 5 and src[c + length] == src[i + length]) length += 1;
            const literals = i - anchor;
            dst[o] = @intCast((@as(usize, @min(literals, 15)) << 4) | @as(usize, @min(length - 4, 15)));
            o += 1;
            if (literals >= 15) extra(dst, &o, literals);
            @memcpy(dst[o..][0..literals], src[anchor..i]);
            o += literals;
            const off: u16 = @intCast(i - c);
            std.mem.writeInt(u16, dst[o..][0..2], off, .little);
            o += 2;
            if (length - 4 >= 15) extra(dst, &o, length - 4);
            i += length;
            anchor = i;
        } else i += 1;
    }
    const literals = n - anchor;
    dst[o] = @intCast(@as(usize, @min(literals, 15)) << 4);
    o += 1;
    if (literals >= 15) extra(dst, &o, literals);
    @memcpy(dst[o..][0..literals], src[anchor..]);
    return o + literals;
}
