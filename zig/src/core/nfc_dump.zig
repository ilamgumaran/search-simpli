//! S1-T15 test tool: NFC of many strings, for `scripts/nfc_compare.py`.
//! Reads a file of lines (space-separated hex codepoints), writes one line
//! per input: the NFC of that string as hex codepoints, or `ERR`.
//!
//!     zig run -OReleaseFast zig/src/nfc_dump.zig -- IN OUT
//!
//! It is not part of any library or the build graph.
const std = @import("std");
const nfc = @import("nfc.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args = init.minimal.args.iterate();
    _ = args.next();
    const in_path = args.next() orelse return error.MissingInput;
    const out_path = args.next() orelse return error.MissingOutput;

    const data = try std.Io.Dir.cwd().readFileAlloc(init.io, in_path, gpa, .unlimited);
    defer gpa.free(data);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var utf8: std.ArrayList(u8) = .empty;
        defer utf8.deinit(gpa);
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        while (fields.next()) |field| {
            const cp = try std.fmt.parseInt(u21, field, 16);
            var buffer: [4]u8 = undefined;
            const len = try std.unicode.utf8Encode(cp, &buffer);
            try utf8.appendSlice(gpa, buffer[0..len]);
        }
        const result = nfc.normalize(gpa, utf8.items) catch {
            try out.appendSlice(gpa, "ERR\n");
            continue;
        };
        defer gpa.free(result);
        var view = try std.unicode.Utf8View.init(result);
        var it = view.iterator();
        var first = true;
        while (it.nextCodepoint()) |cp| {
            if (!first) try out.append(gpa, ' ');
            first = false;
            var tmp: [8]u8 = undefined;
            const text = try std.fmt.bufPrint(&tmp, "{X}", .{cp});
            try out.appendSlice(gpa, text);
        }
        try out.append(gpa, '\n');
    }
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = out_path, .data = out.items });
}
