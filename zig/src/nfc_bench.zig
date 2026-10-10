//! S1-T16 timing tool: `nfc.normalize` on the bytes of a file, in process.
//!
//!     zig run -OReleaseFast zig/src/nfc_bench.zig -- FILE [RUNS]
//!
//! Prints every run's milliseconds and the best. Not part of any library or
//! the build graph.
const std = @import("std");
const nfc = @import("nfc.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args = init.minimal.args.iterate();
    _ = args.next();
    const path = args.next() orelse return error.MissingInput;
    const runs: usize = if (args.next()) |r| try std.fmt.parseInt(usize, r, 10) else 3;
    const data = try std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .unlimited);
    defer gpa.free(data);
    var best: i96 = std.math.maxInt(i96);
    for (0..runs) |_| {
        const start = std.Io.Clock.awake.now(init.io).nanoseconds;
        const out = try nfc.normalize(gpa, data);
        const finish = std.Io.Clock.awake.now(init.io).nanoseconds;
        gpa.free(out);
        best = @min(best, finish - start);
        std.debug.print("run {d:.1} ms\n", .{@as(f64, @floatFromInt(finish - start)) / 1e6});
    }
    std.debug.print("best {d:.1} ms\n", .{@as(f64, @floatFromInt(best)) / 1e6});
}
