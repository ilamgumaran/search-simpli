//! S6-T7 verifier helper: XXH3-64 (seed 0) of a file's bytes [0, ck_off) ++ [hdr_len, end).
//! Usage: xxh PATH CK_OFF HDR_LEN ; prints the value in decimal on stderr.
const std = @import("std");
pub fn main(init: std.process.Init) !void {
    var it = init.minimal.args.iterate();
    _ = it.next();
    const path = it.next() orelse return error.Usage;
    const ck_off = try std.fmt.parseInt(usize, it.next() orelse return error.Usage, 10);
    const hdr_len = try std.fmt.parseInt(usize, it.next() orelse return error.Usage, 10);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .unlimited);
    var h = std.hash.XxHash3.init(0);
    h.update(bytes[0..ck_off]);
    h.update(bytes[hdr_len..]);
    std.debug.print("{d}\n", .{h.final()});
}
