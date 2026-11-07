//! S4-T18: the library's own `memcpy`, `memmove` and `memset`, copying
//! 16 bytes at a time.
//!
//! Why: every library, `searchd` and test binary bundles Zig's
//! `compiler_rt`, and in `ReleaseSmall` Zig 0.16's `compiler_rt` exports
//! `memcpySmall`, `memmoveSmall` and a `memset` that move one byte at a time
//! (about a cycle per byte: the 9.27 MB documents section took 2.42 ms to
//! copy, S4-T16). The platform's `memcpy` cannot be bound instead: the
//! library needs `compiler_rt`'s f128 helpers (`std.json` parses integers
//! through `f128`), `bundle_compiler_rt` is all or nothing, and neither
//! `libSystem` nor Xcode's `compiler-rt` provides those helpers (S4-T18
//! ruling 2).
//!
//! How it wins: `zig/build.zig` compiles this file as its own object (with
//! `-fno-builtin`, so LLVM never turns these loops back into calls to
//! `memcpy`) and links it into every artifact. Its symbols are strong and
//! hidden: each binary binds them inside itself, over `compiler_rt`'s weak
//! ones, and exports nothing new. For the iOS framework, which Apple's
//! linker links from the static archive's objects, `tool/build_native.sh`
//! makes `compiler_rt.o`'s three symbols local first (they are not weak in
//! that object, and `ld64` refuses a duplicate).
//!
//! Every length is moved in windows of 16, 8, 4, 2 or 1 bytes. A window
//! loads all its bytes before it stores any, and two windows may overlap
//! (the last one ends at the end of the range), so there is no byte tail.
//! The forward walk is exact when `dest <= src` or the ranges do not
//! overlap, the backward walk when `dest > src`; `memmove` picks one.

const V = @Vector(16, u8);

inline fn load(comptime T: type, p: [*]const u8) T {
    return @as(*align(1) const T, @ptrCast(p)).*;
}

inline fn store(comptime T: type, p: [*]u8, value: T) void {
    @as(*align(1) T, @ptrCast(p)).* = value;
}

/// `n` in 0..32: every load happens before any store, so this is exact for
/// overlapping ranges in either direction.
inline fn moveSmall(d: [*]u8, s: [*]const u8, n: usize) void {
    if (n >= 16) {
        const a = load(V, s);
        const b = load(V, s + n - 16);
        store(V, d, a);
        store(V, d + n - 16, b);
    } else if (n >= 8) {
        const a = load(u64, s);
        const b = load(u64, s + n - 8);
        store(u64, d, a);
        store(u64, d + n - 8, b);
    } else if (n >= 4) {
        const a = load(u32, s);
        const b = load(u32, s + n - 4);
        store(u32, d, a);
        store(u32, d + n - 4, b);
    } else if (n >= 2) {
        const a = load(u16, s);
        const b = load(u16, s + n - 2);
        store(u16, d, a);
        store(u16, d + n - 2, b);
    } else if (n == 1) {
        d[0] = s[0];
    }
}

/// `n` > 32, `dest <= src` or no overlap. Each 32-byte step loads before it
/// stores and only writes below the next step's source; the last 32 bytes
/// are loaded first and stored last, overlapping the final step.
fn forward(d: [*]u8, s: [*]const u8, n: usize) void {
    @setRuntimeSafety(false);
    const last_a = load(V, s + n - 32);
    const last_b = load(V, s + n - 16);
    var i: usize = 0;
    while (n - i > 32) : (i += 32) {
        const a = load(V, s + i);
        const b = load(V, s + i + 16);
        store(V, d + i, a);
        store(V, d + i + 16, b);
    }
    store(V, d + n - 32, last_a);
    store(V, d + n - 16, last_b);
}

/// `n` > 32, `dest > src`: the mirror of `forward`, from the end down; the
/// first 32 bytes are loaded first and stored last.
fn backward(d: [*]u8, s: [*]const u8, n: usize) void {
    @setRuntimeSafety(false);
    const first_a = load(V, s);
    const first_b = load(V, s + 16);
    var j: usize = n;
    while (j > 32) : (j -= 32) {
        const a = load(V, s + j - 32);
        const b = load(V, s + j - 16);
        store(V, d + j - 32, a);
        store(V, d + j - 16, b);
    }
    store(V, d, first_a);
    store(V, d + 16, first_b);
}

fn memcpyWide(noalias dest: ?[*]u8, noalias src: ?[*]const u8, len: usize) callconv(.c) ?[*]u8 {
    @setRuntimeSafety(false);
    if (len == 0) return dest;
    if (len <= 32) moveSmall(dest.?, src.?, len) else forward(dest.?, src.?, len);
    return dest;
}

fn memmoveWide(dest: ?[*]u8, src: ?[*]const u8, len: usize) callconv(.c) ?[*]u8 {
    @setRuntimeSafety(false);
    if (len == 0) return dest;
    const d = dest.?;
    const s = src.?;
    if (len <= 32) {
        moveSmall(d, s, len);
    } else if (@intFromPtr(d) -% @intFromPtr(s) >= len) {
        // `dest` below `src`, or at or past its end: forward is exact.
        forward(d, s, len);
    } else {
        backward(d, s, len);
    }
    return dest;
}

fn memsetWide(dest: ?[*]u8, c: c_int, len: usize) callconv(.c) ?[*]u8 {
    @setRuntimeSafety(false);
    if (len == 0) return dest;
    const d = dest.?;
    const byte: u8 = @truncate(@as(c_uint, @bitCast(c)));
    const v: V = @splat(byte);
    if (len >= 16) {
        var i: usize = 0;
        while (len - i > 16) : (i += 16) store(V, d + i, v);
        store(V, d + len - 16, v);
    } else if (len >= 8) {
        const w = @as(u64, byte) * 0x0101_0101_0101_0101;
        store(u64, d, w);
        store(u64, d + len - 8, w);
    } else if (len >= 4) {
        const w = @as(u32, byte) * 0x0101_0101;
        store(u32, d, w);
        store(u32, d + len - 4, w);
    } else {
        for (0..len) |k| d[k] = byte;
    }
    return dest;
}

comptime {
    @export(&memcpyWide, .{ .name = "memcpy", .linkage = .strong, .visibility = .hidden });
    @export(&memmoveWide, .{ .name = "memmove", .linkage = .strong, .visibility = .hidden });
    @export(&memsetWide, .{ .name = "memset", .linkage = .strong, .visibility = .hidden });
}

// ---------------------------------------------------------------- tests ---
// The expected bytes are built with plain loops (this file is compiled with
// -fno-builtin, so they stay loops), never with `@memcpy`/`@memset`, which in
// this test binary would call the functions under test.

const std = @import("std");
const testing = std.testing;

const guard = 64;

fn pattern(buffer: []u8, seed: u8) void {
    for (buffer, 0..) |*b, k| b.* = @truncate(k *% 151 +% seed);
}

fn expectEqualBytes(expected: []const u8, actual: []const u8, what: []const u8, len: usize, a: usize, b: usize) !void {
    for (expected, actual, 0..) |e, x, at| {
        if (e != x) {
            std.debug.print("S4-T18 fastmem: {s} len {d} at {d}/{d}: first difference at byte {d}\n", .{ what, len, a, b, at });
            return error.TestExpectedEqual;
        }
    }
}

test "S4-T18 memcpy: every length 0..256 at every source and destination alignment 0..15, guards untouched" {
    var src: [guard + 16 + 256 + guard]u8 = undefined;
    var dst: [src.len]u8 = undefined;
    var expected: [src.len]u8 = undefined;
    pattern(&src, 3);
    var cases: usize = 0;
    for (0..16) |sa| {
        for (0..16) |da| {
            for (0..257) |len| {
                pattern(&dst, 0xEE);
                pattern(&expected, 0xEE);
                for (0..len) |k| expected[guard + da + k] = src[guard + sa + k];
                const result = memcpyWide(dst[guard + da ..].ptr, src[guard + sa ..].ptr, len);
                try testing.expectEqual(@as(?[*]u8, dst[guard + da ..].ptr), result);
                try expectEqualBytes(&expected, &dst, "memcpy", len, sa, da);
                cases += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 16 * 16 * 257), cases);
}

test "S4-T18 memmove: every length 0..256 at every alignment 0..15 without overlap" {
    var src: [guard + 16 + 256 + guard]u8 = undefined;
    var dst: [src.len]u8 = undefined;
    var expected: [src.len]u8 = undefined;
    pattern(&src, 5);
    for (0..16) |sa| {
        for (0..16) |da| {
            for (0..257) |len| {
                pattern(&dst, 0x11);
                pattern(&expected, 0x11);
                for (0..len) |k| expected[guard + da + k] = src[guard + sa + k];
                const result = memmoveWide(dst[guard + da ..].ptr, src[guard + sa ..].ptr, len);
                try testing.expectEqual(@as(?[*]u8, dst[guard + da ..].ptr), result);
                try expectEqualBytes(&expected, &dst, "memmove", len, sa, da);
            }
        }
    }
}

test "S4-T18 memmove: overlapping ranges forward and backward, every length 0..256, shifts -64..64" {
    var buffer: [guard + 64 + 16 + 256 + 64 + guard]u8 = undefined;
    var expected: [buffer.len]u8 = undefined;
    var forward_cases: usize = 0;
    var backward_cases: usize = 0;
    for ([_]usize{ 0, 1, 7, 8, 15 }) |base_alignment| {
        const base = guard + 64 + base_alignment;
        for (0..257) |len| {
            var shift: isize = -64;
            while (shift <= 64) : (shift += 1) {
                const to: usize = @intCast(@as(isize, @intCast(base)) + shift);
                const seed: u8 = @truncate(len);
                pattern(&buffer, seed);
                pattern(&expected, seed);
                // The source bytes as they were before the move.
                for (0..len) |k| expected[to + k] = @truncate((base + k) *% 151 +% seed);
                const result = memmoveWide(buffer[to..].ptr, buffer[base..].ptr, len);
                try testing.expectEqual(@as(?[*]u8, buffer[to..].ptr), result);
                try expectEqualBytes(&expected, &buffer, "memmove overlap", len, base_alignment, @abs(shift));
                if (shift < 0) forward_cases += 1;
                if (shift > 0) backward_cases += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 5 * 257 * 64), forward_cases);
    try testing.expectEqual(@as(usize, 5 * 257 * 64), backward_cases);
}

test "S4-T18 memset: every length 0..256 at every alignment 0..15, zero and non-zero" {
    var dst: [guard + 16 + 256 + guard]u8 = undefined;
    var expected: [dst.len]u8 = undefined;
    for ([_]c_int{ 0x00, 0xA5, 0x1A5 }) |value| {
        // The C contract: the value is converted to unsigned char.
        const byte: u8 = @truncate(@as(c_uint, @bitCast(value)));
        for (0..16) |da| {
            for (0..257) |len| {
                pattern(&dst, 0x77);
                pattern(&expected, 0x77);
                for (0..len) |k| expected[guard + da + k] = byte;
                const result = memsetWide(dst[guard + da ..].ptr, value, len);
                try testing.expectEqual(@as(?[*]u8, dst[guard + da ..].ptr), result);
                try expectEqualBytes(&expected, &dst, "memset", len, byte, da);
            }
        }
    }
}

test "S4-T18 zero lengths take null pointers and return dest" {
    try testing.expectEqual(@as(?[*]u8, null), memcpyWide(null, null, 0));
    try testing.expectEqual(@as(?[*]u8, null), memmoveWide(null, null, 0));
    try testing.expectEqual(@as(?[*]u8, null), memsetWide(null, 0x5A, 0));
}

test "S4-T18 large sizes: 4 KiB + 1 and 1 MiB + 7, copied, moved both ways and set" {
    const allocator = testing.allocator;
    for ([_]usize{ 4096 + 1, 1024 * 1024 + 7 }) |len| {
        const src = try allocator.alloc(u8, len + 256);
        defer allocator.free(src);
        const dst = try allocator.alloc(u8, len + 256);
        defer allocator.free(dst);
        const expected = try allocator.alloc(u8, len + 256);
        defer allocator.free(expected);
        pattern(src, 9);
        for ([_]usize{ 0, 3, 13 }) |sa| {
            pattern(dst, 0x42);
            pattern(expected, 0x42);
            for (0..len) |k| expected[5 + k] = src[sa + k];
            _ = memcpyWide(dst[5..].ptr, src[sa..].ptr, len);
            try expectEqualBytes(expected, dst, "memcpy large", len, sa, 5);
        }
        // Overlap in one buffer: dest below src (forward) and above (backward).
        for ([_]isize{ -100, -3, 3, 100 }) |shift| {
            const from: usize = 120;
            const to: usize = @intCast(@as(isize, from) + shift);
            pattern(dst, 0x24);
            pattern(expected, 0x24);
            for (0..len) |k| expected[to + k] = @truncate((from + k) *% 151 +% 0x24);
            _ = memmoveWide(dst[to..].ptr, dst[from..].ptr, len);
            try expectEqualBytes(expected, dst, "memmove large", len, from, to);
        }
        pattern(dst, 0x61);
        pattern(expected, 0x61);
        for (0..len) |k| expected[7 + k] = 0xC3;
        _ = memsetWide(dst[7..].ptr, 0xC3, len);
        try expectEqualBytes(expected, dst, "memset large", len, 7, 7);
    }
}
