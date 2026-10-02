//! S1-T6 criterion 1: the non-`--update` `searchd index` summary line names
//! `budget_exhausted`, between `unreadable=` and `documents=`.
const std = @import("std");
const cli = @import("cli.zig");
const indexer = @import("indexer.zig");

test "index summary line prints budget_exhausted (S1-T6 criterion 1)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;

    // Three 41-byte files and a 50-byte budget: one fits, two are left over.
    const body = "123456789\n123456789\n123456789\n123456789\na";
    try tmp.dir.createDir(io, "in", .default_dir);
    var in_dir = try tmp.dir.openDir(io, "in", .{});
    defer in_dir.close(io);
    try in_dir.writeFile(io, .{ .sub_path = "a.md", .data = body });
    try in_dir.writeFile(io, .{ .sub_path = "b.md", .data = body });
    try in_dir.writeFile(io, .{ .sub_path = "c.md", .data = body });

    const in_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/in", .{tmp.sub_path});
    defer allocator.free(in_path);
    const out_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/out", .{tmp.sub_path});
    defer allocator.free(out_path);

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try cli.runIndex(io, allocator, in_path, out_path, .{ .caps = indexer.Caps{ .max_total_bytes = 50 } }, &output.writer);

    try std.testing.expect(std.mem.indexOf(
        u8,
        output.written(),
        "files_indexed=1 too_large=0 unreadable=0 budget_exhausted=2 documents=",
    ) != null);
}

// S1-T8: every usage error is one line, status 2, decided by `cli.parseArgs`.
fn expectUsageIn(buffer: []u8, args: []const []const u8, needles: []const []const u8) !void {
    switch (cli.parseArgs(args, buffer)) {
        .usage_error => |usage| {
            try std.testing.expectEqual(@as(u8, 2), usage.status);
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, usage.message, "\n"));
            try std.testing.expect(std.mem.endsWith(u8, usage.message, "\n"));
            for (needles) |needle| {
                if (std.mem.indexOf(u8, usage.message, needle) == null) {
                    std.debug.print("message {s} lacks {s}\n", .{ usage.message, needle });
                    return error.TestExpectedEqual;
                }
            }
        },
        else => {
            std.debug.print("not a usage error: {any}\n", .{args});
            return error.TestUnexpectedResult;
        },
    }
}

fn expectUsage(args: []const []const u8, needles: []const []const u8) !void {
    var buffer: [512]u8 = undefined;
    try expectUsageIn(&buffer, args, needles);
}

test "unknown command is one line pointing at --help (S1-T8 criterion 1, 3)" {
    try expectUsage(&.{"frobnicate"}, &.{ "unknown command", "'frobnicate'", "searchd --help" });
}

test "unknown flag for every subcommand (S1-T8 criterion 1)" {
    try expectUsage(&.{ "index", "f", "--out", "o", "--bogus" }, &.{ "unknown flag for index", "'--bogus'" });
    try expectUsage(&.{ "query", "d", "text", "--bogus" }, &.{ "unknown flag for query", "'--bogus'" });
    try expectUsage(&.{ "evidence", "d", "text", "--bogus" }, &.{ "unknown flag for evidence", "'--bogus'" });
    try expectUsage(&.{ "serve", "d", "--bogus" }, &.{ "unknown flag for serve", "'--bogus'" });
    try expectUsage(&.{ "demo", "--bogus" }, &.{ "unexpected argument for demo", "'--bogus'" });
    try expectUsage(&.{ "init-demo", "d", "--bogus" }, &.{ "unexpected argument for init-demo", "'--bogus'" });
    try expectUsage(&.{ "import-json", "d", "f", "--bogus" }, &.{ "unexpected argument for import-json", "'--bogus'" });
    try expectUsage(&.{ "benchmark", "1", "1", "1", "lexical", "--bogus" }, &.{ "unexpected argument for benchmark", "'--bogus'" });
}

test "a flag with no value, for every flag that takes one (S1-T8 criterion 1)" {
    try expectUsage(&.{ "index", "f", "--out" }, &.{"missing value for --out"});
    try expectUsage(&.{ "index", "f", "--out", "o", "--analyzer" }, &.{"missing value for --analyzer"});
    try expectUsage(&.{ "index", "f", "--out", "o", "--max-chars" }, &.{"missing value for --max-chars"});
    try expectUsage(&.{ "index", "f", "--out", "o", "--overlap-lines" }, &.{"missing value for --overlap-lines"});
    try expectUsage(&.{ "index", "f", "--out", "o", "--generation" }, &.{"missing value for --generation"});
    try expectUsage(&.{ "index", "f", "--out", "o", "--max-file-bytes" }, &.{"missing value for --max-file-bytes"});
    try expectUsage(&.{ "index", "f", "--out", "o", "--max-total-bytes" }, &.{"missing value for --max-total-bytes"});
    try expectUsage(&.{ "query", "d", "text", "--top-k" }, &.{"missing value for --top-k"});
    try expectUsage(&.{ "evidence", "d", "text", "--top-k" }, &.{"missing value for --top-k"});
    try expectUsage(&.{ "serve", "d", "--http" }, &.{"missing value for --http"});
}

test "a missing positional argument (S1-T8 criterion 1)" {
    try expectUsage(&.{"index"}, &.{ "missing argument", "<folder>" });
    try expectUsage(&.{ "index", "f" }, &.{ "missing argument", "--out" });
    try expectUsage(&.{"query"}, &.{ "missing argument", "<dir>" });
    try expectUsage(&.{ "query", "d" }, &.{ "missing argument", "<text>" });
    try expectUsage(&.{"evidence"}, &.{ "missing argument", "<dir>" });
    try expectUsage(&.{ "evidence", "d" }, &.{ "missing argument", "<text>" });
    try expectUsage(&.{"serve"}, &.{ "missing argument", "<dir>" });
    try expectUsage(&.{"init-demo"}, &.{ "missing argument", "<dir>" });
    try expectUsage(&.{"import-json"}, &.{ "missing argument", "<dir>" });
    try expectUsage(&.{ "import-json", "d" }, &.{ "missing argument", "<file>" });
    try expectUsage(&.{"benchmark"}, &.{ "missing argument", "<docs>" });
    try expectUsage(&.{ "benchmark", "1", "1", "1" }, &.{ "missing argument", "<mode>" });
}

test "invalid enumerated values (S1-T8 criterion 1)" {
    try expectUsage(&.{ "index", "f", "--out", "o", "--analyzer", "v3" }, &.{ "invalid value for --analyzer", "'v3'" });
    try expectUsage(&.{ "benchmark", "1", "1", "1", "fast" }, &.{ "invalid value for benchmark <mode>", "'fast'" });
}

// The bad spellings of a number that S1-T8 criterion 2 rejects.
const bad_numbers = [_][]const u8{ "+5", "-0", "-1", "1_000", " 5", "5 ", "0x10", "abc", "10k", "", "18446744073709551616", "99999999999999999999999" };

test "every numeric option rejects every bad spelling, quoting the value (S1-T8 criterion 2)" {
    for (bad_numbers) |bad| {
        var quoted_buffer: [64]u8 = undefined;
        const quoted = try std.fmt.bufPrint(&quoted_buffer, "'{s}'", .{bad});
        for ([_][]const u8{ "--max-file-bytes", "--max-total-bytes", "--max-chars", "--overlap-lines", "--generation" }) |option| {
            try expectUsage(&.{ "index", "f", "--out", "o", option, bad }, &.{ option, quoted });
        }
        try expectUsage(&.{ "query", "d", "t", "--top-k", bad }, &.{ "--top-k", quoted });
        try expectUsage(&.{ "evidence", "d", "t", "--top-k", bad }, &.{ "--top-k", quoted });
        try expectUsage(&.{ "benchmark", bad, "1", "1", "lexical" }, &.{ "<docs>", quoted });
        try expectUsage(&.{ "benchmark", "1", bad, "1", "lexical" }, &.{ "<dimensions>", quoted });
        try expectUsage(&.{ "benchmark", "1", "1", bad, "lexical" }, &.{ "<queries>", quoted });
    }
}

test "options positive today still reject 0, the others accept it (S1-T8 criterion 2)" {
    try expectUsage(&.{ "index", "f", "--out", "o", "--max-chars", "0" }, &.{ "--max-chars", "'0'" });
    try expectUsage(&.{ "query", "d", "t", "--top-k", "0" }, &.{ "--top-k", "'0'" });
    try expectUsage(&.{ "benchmark", "0", "1", "1", "lexical" }, &.{ "<docs>", "'0'" });
    try expectUsage(&.{ "benchmark", "1", "1", "0", "lexical" }, &.{ "<queries>", "'0'" });
    var buffer: [512]u8 = undefined;
    const accepted = cli.parseArgs(&.{ "index", "f", "--out", "o", "--max-file-bytes", "0", "--max-total-bytes", "0", "--overlap-lines", "0", "--generation", "0" }, &buffer);
    try std.testing.expectEqual(@as(u64, 0), accepted.index.options.caps.max_file_bytes);
    try std.testing.expectEqual(@as(u64, 0), accepted.index.options.caps.max_total_bytes);
    try std.testing.expectEqual(@as(usize, 0), accepted.index.options.overlap_lines);
    try std.testing.expectEqual(@as(?u64, 0), accepted.index.options.generation);
    const bench = cli.parseArgs(&.{ "benchmark", "5", "0", "7", "hybrid" }, &buffer);
    try std.testing.expectEqual(@as(usize, 0), bench.benchmark.dimensions);
}

test "valid arguments parse (S1-T8 criterion 2)" {
    var buffer: [512]u8 = undefined;
    const index = cli.parseArgs(&.{ "index", "in", "--out", "out", "--analyzer", "v1", "--max-chars", "0100", "--update", "--max-file-bytes", "1048576", "--generation", "18446744073709551615" }, &buffer);
    try std.testing.expectEqualStrings("in", index.index.folder);
    try std.testing.expectEqualStrings("out", index.index.out);
    try std.testing.expectEqual(@as(usize, 100), index.index.options.max_chars);
    try std.testing.expectEqual(@as(u64, 1048576), index.index.options.caps.max_file_bytes);
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), index.index.options.generation);
    try std.testing.expect(index.index.options.update);
    const query = cli.parseArgs(&.{ "query", "d", "hello world", "--json", "--top-k", "3" }, &buffer);
    try std.testing.expectEqual(@as(usize, 3), query.query.options.top_k);
    try std.testing.expect(query.query.options.json);
    const serve = cli.parseArgs(&.{ "serve", "d", "--http", "127.0.0.1:9" }, &buffer);
    try std.testing.expectEqualStrings("127.0.0.1:9", serve.serve.http.?);
}

test "a value longer than the message buffer is marked truncated, still one line (S1-T8 criterion 2)" {
    const long = "1" ** 600 ++ "x";
    var big: [512]u8 = undefined;
    try expectUsageIn(&big, &.{ "index", "f", "--out", "o", "--max-file-bytes", long }, &.{ "--max-file-bytes", "(value truncated)" });
    var tiny: [70]u8 = undefined;
    try expectUsageIn(&tiny, &.{ "index", "f", "--out", "o", "--max-chars", long }, &.{ "--max-chars", "(value truncated)" });
    var small: [96]u8 = undefined;
    try expectUsageIn(&small, &.{ "index", "f", "--out", "o", "--max-chars", long }, &.{ "--max-chars", "(value truncated)" });
    // A control byte in a value cannot add a second line.
    try expectUsage(&.{ "frob\nnicate" }, &.{"'frob?nicate'"});
}

test "help is a command, a bare invocation is a usage error carrying the usage text (S1-T8 criterion 3)" {
    var buffer: [512]u8 = undefined;
    try std.testing.expect(cli.parseArgs(&.{"--help"}, &buffer) == .help);
    try std.testing.expect(cli.parseArgs(&.{"-h"}, &buffer) == .help);
    try std.testing.expect(cli.parseArgs(&.{"help"}, &buffer) == .help);
    const bare = cli.parseArgs(&.{}, &buffer);
    try std.testing.expectEqual(@as(u8, 2), bare.usage_error.status);
    try std.testing.expectEqualStrings(cli.usage_text, bare.usage_error.message);
}

test "usage text states the exit statuses (S1-T8 criterion 3)" {
    try std.testing.expect(std.mem.indexOf(u8, cli.usage_text, "Exit status: 0 success; 1 the work failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, cli.usage_text, "2 usage error") != null);
}

test "a failure of the work is not a usage error and keeps exit 1 (S1-T8 criterion 3)" {
    // `main` exits 1 for any error these return; usage errors exit 2.
    try std.testing.expect(cli.usage_exit_status != 1);
    const io = std.testing.io;
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectError(error.FileNotFound, cli.runIndex(io, std.testing.allocator, "no-such-folder-s1-t8", "no-such-out", .{}, &output.writer));
    try std.testing.expectError(error.FileNotFound, cli.runQuery(io, std.testing.allocator, "no-such-snapshot-s1-t8", "q", .{}, &output.writer));
    try std.testing.expectError(error.FileNotFound, cli.runEvidence(io, std.testing.allocator, "no-such-snapshot-s1-t8", "q", .{}, &output.writer));
}
