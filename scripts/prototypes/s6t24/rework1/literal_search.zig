//! S6-T24 rework 1, ruling 3: is the standard library's literal search quadratic on the verifier's input, and
//! is the engine's (Knuth-Morris-Pratt, `pattern.Matcher`) linear?
//!
//! Haystack: 10 MiB of lines of 4,095 `a`s (the verifier's file), searched whole, as the old `scan.run` did.
//! Needles: m-1 `a`s then `b`, and `b` then m-1 `a`s, for m = 16, 256, 1024. Each is searched with
//! `std.mem.findPos` (bytes), `std.ascii.findIgnoreCasePos` (ASCII case-insensitive) and the engine's matcher
//! (literal and ASCII-insensitive strategies, no budget), and the fastest of three runs is printed in ms.
//!
//! Run (ReleaseFast) from the repository root:
//!   zig run -OReleaseFast --dep pattern -Mroot=scripts/prototypes/s6t24/rework1/literal_search.zig \
//!       -Mpattern=zig/src/core/pattern.zig
const std = @import("std");
const pattern = @import("pattern");

fn nowNs(io: std.Io) u64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = std.heap.page_allocator;
    const size: usize = 10 << 20;
    const hay = try allocator.alloc(u8, size);
    for (hay, 0..) |*byte, i| byte.* = if (i % 4096 == 4095) '\n' else 'a';
    // The engine searches one line at a time; for the same work, one line of the same length with no breaks.
    const line = try allocator.alloc(u8, size);
    @memset(line, 'a');
    std.debug.print("haystack {d} bytes; fastest of 3, ms\n", .{size});
    for ([_]usize{ 16, 256, 1024 }) |m| {
        for ([_]bool{ true, false }) |b_last| {
            const needle = try allocator.alloc(u8, m);
            @memset(needle, 'a');
            if (b_last) needle[m - 1] = 'b' else needle[0] = 'b';
            var best = [_]u64{std.math.maxInt(u64)} ** 4;
            for (0..3) |_| {
                var t = nowNs(io);
                std.mem.doNotOptimizeAway(std.mem.findPos(u8, hay, 0, needle));
                best[0] = @min(best[0], nowNs(io) - t);
                t = nowNs(io);
                std.mem.doNotOptimizeAway(std.ascii.findIgnoreCasePos(hay, 0, needle));
                best[1] = @min(best[1], nowNs(io) - t);
                inline for (.{ pattern.Case.sensitive, pattern.Case.insensitive }, 2..) |case, slot| {
                    var arena = std.heap.ArenaAllocator.init(allocator);
                    defer arena.deinit();
                    const outcome = try pattern.compile(arena.allocator(), needle, .literal, case, false);
                    const compiled = &outcome.ok;
                    var matcher = try pattern.Matcher.init(arena.allocator(), compiled, null);
                    var offsets = std.ArrayList([2]u32).empty;
                    t = nowNs(io);
                    const got = try matcher.matchLine(arena.allocator(), line, 512, 512, &offsets);
                    best[slot] = @min(best[slot], nowNs(io) - t);
                    std.mem.doNotOptimizeAway(got);
                }
            }
            std.debug.print("m={d:>4} {s}: findPos {d:.1}, findIgnoreCasePos {d:.1}, engine bytes {d:.1}, engine ascii_ci {d:.1}\n", .{
                m,                                          if (b_last) "a's then b" else "b then a's",
                @as(f64, @floatFromInt(best[0])) / 1e6,     @as(f64, @floatFromInt(best[1])) / 1e6,
                @as(f64, @floatFromInt(best[2])) / 1e6,     @as(f64, @floatFromInt(best[3])) / 1e6,
            });
        }
    }
}
