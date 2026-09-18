//! Picks a generation number that will not collide with an existing
//! `documents-N.hybseg`/`lexical-N.hyblex` pair when publishing into a
//! directory that already holds a snapshot (S1-T3, `docs/tasks/S1-T3.md`
//! criterion 5: `searchd index --out <existing dir>` must re-publish, not
//! fail with `PathAlreadyExists`).
//!
//! Also the recovery half of S1-T3's crash-mid-publication story: a process
//! that crashes between linking an immutable generation file and replacing
//! `MANIFEST` (see `docs/publication-recovery.md`'s crash-visibility matrix)
//! leaves an orphan `documents-K.hybseg`/`lexical-K.hyblex` on disk for the
//! generation it was trying to publish. `lifecycle.scan` already gives an
//! operator visibility into that orphan; `nextFreeGeneration` gives the next
//! automated indexing run a way to route around it instead of failing again
//! with the exact same `PathAlreadyExists`.
const std = @import("std");
const manifest = @import("manifest.zig");
const publication = @import("publication.zig");

/// The current generation recorded by `MANIFEST` in `dir`, or `0` if `dir`
/// has no manifest yet (a fresh output directory).
pub fn currentGeneration(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !u64 {
    var file = dir.openFile(io, publication.current_manifest_file, .{}) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    const stat = try file.stat(io);
    file.close(io);
    const size = std.math.cast(usize, stat.size) orelse return error.IndexTooLarge;
    const buffer = try allocator.alloc(u8, size);
    const encoded = try dir.readFile(io, publication.current_manifest_file, buffer);
    const metadata = try manifest.decode(encoded);
    return metadata.generation;
}

fn pathExists(dir: std.Io.Dir, io: std.Io, name: []const u8) !bool {
    _ = dir.statFile(io, name, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

/// The smallest generation number strictly greater than `dir`'s current
/// generation (0 if none) whose `documents-*.hybseg`/`lexical-*.hyblex`
/// filenames are both free. `allocator` is used only for the transient read
/// of `MANIFEST`; an arena is fine.
pub fn nextFreeGeneration(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !u64 {
    const current = try currentGeneration(allocator, io, dir);
    var candidate = current + 1;
    var attempts: usize = 0;
    while (attempts < 1_000_000) : (attempts += 1) {
        var name_buffer: [64]u8 = undefined;
        const documents_name = try std.fmt.bufPrint(&name_buffer, "documents-{d}.hybseg", .{candidate});
        const documents_taken = try pathExists(dir, io, documents_name);
        var lexical_buffer: [64]u8 = undefined;
        const lexical_name = try std.fmt.bufPrint(&lexical_buffer, "lexical-{d}.hyblex", .{candidate});
        const lexical_taken = try pathExists(dir, io, lexical_name);
        if (!documents_taken and !lexical_taken) return candidate;
        candidate += 1;
    }
    return error.NoFreeGeneration;
}

test "nextFreeGeneration is 1 for a fresh directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const generation = try nextFreeGeneration(std.testing.allocator, std.testing.io, tmp.dir);
    try std.testing.expectEqual(@as(u64, 1), generation);
}

test "nextFreeGeneration skips a crash orphan past the current generation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    // Simulate a manifest at generation 1 by writing raw MANIFEST bytes is
    // more setup than needed here; instead simulate "current=0, but
    // generation 1's files already exist" (a crash before any manifest was
    // ever published, on the very first publish attempt).
    try tmp.dir.writeFile(io, .{ .sub_path = "documents-1.hybseg", .data = "orphan" });
    const generation = try nextFreeGeneration(std.testing.allocator, io, tmp.dir);
    try std.testing.expectEqual(@as(u64, 2), generation);
}
