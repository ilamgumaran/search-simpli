//! Verifier scratch only (not tracked): decode every file in the corruption
//! directory with the branch's reader in Debug, print the outcome.
const std = @import("std");
const lexical_segment = @import("lexical_segment.zig");
const postings = @import("postings.zig");
const io = std.testing.io;
const dir_path = "<vscratch>/corrupt";

fn decodeOne(a: std.mem.Allocator, bytes: []const u8) !void {
    const header = try lexical_segment.inspect(bytes);
    // capacities from the header, bounded (the snapshot open sizes them from the manifest)
    if (header.term_count > 1 << 20 or header.posting_count > 1 << 24 or header.document_count > 1 << 20) return error.TooLargeForHarness;
    const terms = try a.alloc(postings.TermEntry, header.term_count);
    const values = try a.alloc(postings.Posting, header.posting_count);
    const lengths = try a.alloc(u32, header.document_count);
    _ = try lexical_segment.decodeWith(bytes, terms, values, lengths, .{ .inspected = header, .term_text_allocator = a, .validate_positions = true });
}

test "verifier corruptions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".hyblex")) continue;
        const bytes = try dir.readFileAlloc(io, entry.name, a, .unlimited);
        if (decodeOne(a, bytes)) |_| {
            std.debug.print("VCORRUPT {s} accepted\n", .{entry.name});
        } else |err| {
            std.debug.print("VCORRUPT {s} refused {s}\n", .{ entry.name, @errorName(err) });
        }
    }
}
