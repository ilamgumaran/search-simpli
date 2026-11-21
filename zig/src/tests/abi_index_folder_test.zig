//! S6-T19: a test of `interfaces/abi.zig`, moved here from beside it with its name and
//! body unchanged apart from imports. It names `manifest.decode`, which no operation or
//! interface uses; a test beside the code in interfaces/ reaches the core only through
//! the public core API, a test in tests/ may use internals (docs/core-api.md), so the
//! move lets that name leave `api`.
const std = @import("std");
const generation_alloc = @import("core").generation_alloc;
const manifest = @import("core").manifest;
const ss_close = @import("interfaces").abi.ss_close;
const ss_free = @import("interfaces").abi.ss_free;
const ss_index_folder = @import("interfaces").abi.ss_index_folder;
const ss_last_error = @import("interfaces").abi.ss_last_error;
const ss_open = @import("interfaces").abi.ss_open;

test "ss_index_folder lists every max trace and resets the list between calls" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const test_io = std.testing.io;
    const max = "18446744073709551615";
    const documents_max = "documents-" ++ max ++ ".hybseg";
    const lexical_max = "lexical-" ++ max ++ ".hyblex";
    const names = [_][]const u8{ "MANIFEST", "INDEX-STATE.json", documents_max, lexical_max };

    try tmp.dir.createDir(test_io, "notes", .default_dir);
    try tmp.dir.writeFile(test_io, .{ .sub_path = "notes/a.md", .data = "alpha\n" });
    const notes_z = try std.fmt.allocPrintSentinel(std.testing.allocator, ".zig-cache/tmp/{s}/notes", .{tmp.sub_path}, 0);
    defer std.testing.allocator.free(notes_z);
    const out_z = try std.fmt.allocPrintSentinel(std.testing.allocator, ".zig-cache/tmp/{s}/out", .{tmp.sub_path}, 0);
    defer std.testing.allocator.free(out_z);
    const one_z = try std.fmt.allocPrintSentinel(std.testing.allocator, ".zig-cache/tmp/{s}/one", .{tmp.sub_path}, 0);
    defer std.testing.allocator.free(one_z);
    const fresh_z = try std.fmt.allocPrintSentinel(std.testing.allocator, ".zig-cache/tmp/{s}/fresh", .{tmp.sub_path}, 0);
    defer std.testing.allocator.free(fresh_z);

    ss_free(ss_index_folder(out_z, notes_z, null) orelse return error.IndexFailed);
    var original_manifest_buffer: [4096]u8 = undefined;
    const original_manifest = try tmp.dir.readFile(test_io, "out/MANIFEST", &original_manifest_buffer);
    var metadata = try manifest.decode(original_manifest);
    // Re-encode a real indexed snapshot's manifest at u64 max and retain its
    // actual section bytes under the canonical max names.
    var section_buffer: [65536]u8 = undefined;
    const original_documents_path = try std.fmt.allocPrint(std.testing.allocator, "out/{s}", .{metadata.documents_file});
    defer std.testing.allocator.free(original_documents_path);
    const original_documents = try tmp.dir.readFile(test_io, original_documents_path, &section_buffer);
    try tmp.dir.writeFile(test_io, .{ .sub_path = "out/" ++ documents_max, .data = original_documents });
    const original_lexical_path = try std.fmt.allocPrint(std.testing.allocator, "out/{s}", .{metadata.lexical_file});
    defer std.testing.allocator.free(original_lexical_path);
    const original_lexical = try tmp.dir.readFile(test_io, original_lexical_path, &section_buffer);
    try tmp.dir.writeFile(test_io, .{ .sub_path = "out/" ++ lexical_max, .data = original_lexical });
    metadata.generation = std.math.maxInt(u64);
    metadata.documents_file = documents_max;
    metadata.lexical_file = lexical_max;
    var encoded_manifest_buffer: [4096]u8 = undefined;
    const encoded_manifest = try manifest.encode(metadata, &encoded_manifest_buffer);
    try tmp.dir.writeFile(test_io, .{ .sub_path = "out/MANIFEST", .data = encoded_manifest });
    try tmp.dir.writeFile(test_io, .{ .sub_path = "out/INDEX-STATE.json", .data = "{\"generation\":18446744073709551615,\"analyzer_id\":\"analyzer-v2\",\"files\":[]}" });
    try tmp.dir.writeFile(test_io, .{ .sub_path = "out/documents-018446744073709551615.hybseg", .data = "alias" });
    try tmp.dir.writeFile(test_io, .{ .sub_path = "out/lexical-7.hyblex", .data = "lower" });
    try tmp.dir.createDir(test_io, "out/lexical-018446744073709551615.hyblex", .default_dir);

    const max_handle = ss_open(out_z) orelse return error.OpenFailed;
    ss_close(max_handle);

    const snapshot_paths = [_][]const u8{
        "out/MANIFEST",           "out/INDEX-STATE.json", "out/" ++ documents_max,                      "out/" ++ lexical_max,
        "out/documents-1.hybseg", "out/lexical-1.hyblex", "out/documents-018446744073709551615.hybseg", "out/lexical-7.hyblex",
    };
    var saved: [snapshot_paths.len][]u8 = undefined;
    for (snapshot_paths, 0..) |path, i| {
        var buffer: [65536]u8 = undefined;
        saved[i] = try std.testing.allocator.dupe(u8, try tmp.dir.readFile(test_io, path, &buffer));
    }
    defer for (saved) |bytes| std.testing.allocator.free(bytes);

    try std.testing.expect(ss_index_folder(out_z, notes_z, null) == null);
    const first_message = try std.testing.allocator.dupe(u8, std.mem.span(ss_last_error()));
    defer std.testing.allocator.free(first_message);
    try std.testing.expect(std.mem.startsWith(u8, first_message, "ss_index_folder: NoFreeGeneration"));
    try std.testing.expect(std.mem.indexOf(u8, first_message, max) != null);
    var previous: usize = 0;
    for (names) |name| {
        const position = std.mem.indexOf(u8, first_message, name) orelse return error.MissingTrace;
        try std.testing.expect(position >= previous);
        try std.testing.expect(std.mem.indexOf(u8, first_message[position + name.len ..], name) == null);
        previous = position + name.len;
    }
    try std.testing.expect(std.mem.indexOf(u8, first_message, "fresh") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_message, "inspect") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_message, "delete or rename that file") == null);
    try std.testing.expect(std.mem.indexOf(u8, first_message, "zig-cache") == null);
    try std.testing.expect(std.mem.indexOf(u8, first_message, "documents-018446744073709551615.hybseg") == null);
    try std.testing.expect(std.mem.indexOf(u8, first_message, "lexical-7.hyblex") == null);
    for (snapshot_paths, saved) |path, bytes| {
        var buffer: [65536]u8 = undefined;
        try std.testing.expectEqualSlices(u8, bytes, try tmp.dir.readFile(test_io, path, &buffer));
    }

    try tmp.dir.createDir(test_io, "one", .default_dir);
    try tmp.dir.writeFile(test_io, .{ .sub_path = "one/lexical-" ++ max ++ ".hyblex", .data = "orphan" });
    const Worker = struct {
        fn run(dir: [*:0]const u8, notes: [*:0]const u8, output: *[512]u8, length: *usize) void {
            if (ss_index_folder(dir, notes, null)) |json| {
                ss_free(json);
                length.* = 0;
                return;
            }
            const message = std.mem.span(ss_last_error());
            length.* = message.len;
            @memcpy(output[0..message.len], message);
        }
    };
    var worker_buffer: [512]u8 = undefined;
    var worker_length: usize = 0;
    const worker = try std.Thread.spawn(.{}, Worker.run, .{ one_z.ptr, notes_z.ptr, &worker_buffer, &worker_length });
    worker.join();
    const worker_message = worker_buffer[0..worker_length];
    try std.testing.expect(std.mem.indexOf(u8, worker_message, lexical_max) != null);
    for (names[0..3]) |name| try std.testing.expect(std.mem.indexOf(u8, worker_message, name) == null);
    try std.testing.expectEqualStrings(first_message, std.mem.span(ss_last_error()));
    var cause_buffer: [512]u8 = undefined;
    const main_cause = generation_alloc.describeNoFreeGeneration(&cause_buffer);
    for (names) |name| try std.testing.expect(std.mem.indexOf(u8, main_cause, name) != null);

    try std.testing.expect(ss_index_folder(one_z, notes_z, null) == null);
    const one_message = std.mem.span(ss_last_error());
    try std.testing.expect(std.mem.indexOf(u8, one_message, lexical_max) != null);
    for (names[0..3]) |name| try std.testing.expect(std.mem.indexOf(u8, one_message, name) == null);
    try std.testing.expect(ss_index_folder(out_z, notes_z, null) == null);
    try std.testing.expectEqualStrings(first_message, std.mem.span(ss_last_error()));

    ss_free(ss_index_folder(fresh_z, notes_z, null) orelse return error.IndexFailed);
    try std.testing.expectEqualStrings("", std.mem.span(ss_last_error()));
    for (snapshot_paths, saved) |path, bytes| {
        var buffer: [65536]u8 = undefined;
        try std.testing.expectEqualSlices(u8, bytes, try tmp.dir.readFile(test_io, path, &buffer));
    }
}

// S6-T20: `ss_index_folder` without `update` chooses its generation number
// under `WRITER.LOCK` (`docs/tasks/S6-T20.md`). The order of two refusals shows
// where: with no number left and the lock held by another writer, a call that
// chose its number first answers `NoFreeGeneration`; one that takes the lock
// first answers `WriterBusy`.
test "S6-T20: ss_index_folder with WRITER.LOCK held answers WriterBusy before it chooses a number" {
    const lifecycle = @import("core").lifecycle;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const test_io = std.testing.io;
    const lexical_max = "lexical-18446744073709551615.hyblex";
    try tmp.dir.createDir(test_io, "notes", .default_dir);
    try tmp.dir.writeFile(test_io, .{ .sub_path = "notes/a.md", .data = "alpha\n" });
    const notes_z = try std.fmt.allocPrintSentinel(std.testing.allocator, ".zig-cache/tmp/{s}/notes", .{tmp.sub_path}, 0);
    defer std.testing.allocator.free(notes_z);
    const out_z = try std.fmt.allocPrintSentinel(std.testing.allocator, ".zig-cache/tmp/{s}/out", .{tmp.sub_path}, 0);
    defer std.testing.allocator.free(out_z);

    ss_free(ss_index_folder(out_z, notes_z, null) orelse return error.IndexFailed);
    var out = try tmp.dir.openDir(test_io, "out", .{ .iterate = true });
    defer out.close(test_io);
    try out.writeFile(test_io, .{ .sub_path = lexical_max, .data = "x" });

    var lease = (try lifecycle.tryAcquireWriter(out, test_io)).?;
    var released = false;
    defer if (!released) lease.release(test_io);
    try std.testing.expect(ss_index_folder(out_z, notes_z, null) == null);
    const held = try std.testing.allocator.dupe(u8, std.mem.span(ss_last_error()));
    defer std.testing.allocator.free(held);
    std.debug.print("S6-T20 ss_index_folder, lock held, no number left: {s}\n", .{held});
    try std.testing.expectEqualStrings("ss_index_folder: WriterBusy", held);

    lease.release(test_io);
    released = true;
    try std.testing.expect(ss_index_folder(out_z, notes_z, null) == null);
    const free = std.mem.span(ss_last_error());
    try std.testing.expect(std.mem.startsWith(u8, free, "ss_index_folder: NoFreeGeneration"));
    try std.testing.expect(std.mem.indexOf(u8, free, lexical_max) != null);
    var manifest_buffer: [4096]u8 = undefined;
    try std.testing.expectEqual(@as(u64, 1), (try manifest.decode(try out.readFile(test_io, "MANIFEST", &manifest_buffer))).generation);
}
