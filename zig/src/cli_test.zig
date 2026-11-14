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
    try expectUsage(&.{ "serve", "d", "--http", "8080" }, &.{ "invalid value for --http", "'8080'" });
    try expectUsage(&.{ "serve", "d", "--http", "127.0.0.1:99999" }, &.{ "invalid value for --http", "'127.0.0.1:99999'" });
    try expectUsage(&.{ "serve", "d", "--http", "0.0.0.0:80" }, &.{ "invalid value for --http", "only 127.0.0.1" });
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
    const accepted = cli.parseArgs(&.{ "index", "f", "--out", "o", "--max-file-bytes", "0", "--max-total-bytes", "0", "--overlap-lines", "0" }, &buffer);
    try std.testing.expectEqual(@as(u64, 0), accepted.index.options.caps.max_file_bytes);
    try std.testing.expectEqual(@as(u64, 0), accepted.index.options.caps.max_total_bytes);
    try std.testing.expectEqual(@as(usize, 0), accepted.index.options.overlap_lines);
    try std.testing.expectEqual(@as(?u64, null), accepted.index.options.generation);
    const bench = cli.parseArgs(&.{ "benchmark", "5", "0", "7", "lexical" }, &buffer);
    try std.testing.expectEqual(@as(usize, 0), bench.benchmark.dimensions);
}

test "values only the work used to reject are usage errors, decided before any work (S1-T8 round 2, criterion 1)" {
    // `index --generation 0` used to fail after indexing (GenerationZero, exit 1, a trace).
    try expectUsage(&.{ "index", "f", "--out", "o", "--generation", "0" }, &.{ "--generation", "'0'" });
    try expectUsage(&.{ "index", "f", "--out", "o", "--generation", "00" }, &.{ "--generation", "'00'" });
    var buffer: [512]u8 = undefined;
    const one = cli.parseArgs(&.{ "index", "f", "--out", "o", "--generation", "1" }, &buffer);
    try std.testing.expectEqual(@as(?u64, 1), one.index.options.generation);
    // `benchmark` limits, the same ones `benchmark.run` enforces.
    try expectUsage(&.{ "benchmark", "100001", "1", "1", "lexical" }, &.{"<docs>"});
    try expectUsage(&.{ "benchmark", "1", "4097", "1", "lexical" }, &.{"<dimensions>"});
    try expectUsage(&.{ "benchmark", "1", "0", "1", "vector" }, &.{"<dimensions>"});
    try expectUsage(&.{ "benchmark", "1", "0", "1", "hybrid" }, &.{"<dimensions>"});
    try expectUsage(&.{ "benchmark", "1", "1", "10001", "lexical" }, &.{"<queries>"});
    // The boundaries themselves are accepted.
    const edge = cli.parseArgs(&.{ "benchmark", "100000", "4096", "10000", "hybrid" }, &buffer);
    try std.testing.expectEqual(@as(usize, 100000), edge.benchmark.documents);
    const lexical_zero = cli.parseArgs(&.{ "benchmark", "1", "0", "1", "lexical" }, &buffer);
    try std.testing.expectEqual(@as(usize, 0), lexical_zero.benchmark.dimensions);
}

test "index --generation 0 creates no --out directory (S1-T8 round 2, criterion 1)" {
    // main.zig only runs the work when parseArgs returns .index; a usage error returns first.
    var buffer: [512]u8 = undefined;
    const result = cli.parseArgs(&.{ "index", "f", "--out", ".zig-cache/tmp/never-created-by-generation-zero", "--generation", "0" }, &buffer);
    try std.testing.expect(result == .usage_error);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openDir(std.testing.io, ".zig-cache/tmp/never-created-by-generation-zero", .{}));
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

// S2-T11: invalid UTF-8 in the query text is a usage error (one line, status 2),
// for `query` and `evidence`, before any snapshot is opened.
test "query and evidence reject invalid UTF-8 text with one line and status 2 (S2-T11)" {
    var buffer: [512]u8 = undefined;
    for ([_][]const u8{ "query", "evidence" }) |command| {
        for ([_][]const u8{ "caf\xff", "\x80", "\xfe", "\xc3", "ok \xed\xa0\x80" }) |text| {
            const parsed = cli.parseArgs(&.{ command, "dir", text }, &buffer);
            try std.testing.expect(parsed == .usage_error);
            try std.testing.expectEqual(@as(u8, 2), parsed.usage_error.status);
            try std.testing.expectEqualStrings(
                "searchd: invalid value for query text (not valid UTF-8)\n",
                parsed.usage_error.message,
            );
        }
        const good = cli.parseArgs(&.{ command, "dir", "caf\xc3\xa9" }, &buffer);
        try std.testing.expect(good != .usage_error);
    }
}

test "S3-T4: the folder commands parse, and every bad argument is one usage line" {
    var buffer: [512]u8 = undefined;
    const find = cli.parseArgs(&.{ "find", "d", "count me", "--mode", "phrase", "--roots", "a,b", "--page-size", "100", "--cursor", "3:20", "--json" }, &buffer).find;
    try std.testing.expectEqualStrings("count me", find.query);
    try std.testing.expectEqual(@as(?@import("find.zig").Mode, .phrase), find.mode);
    try std.testing.expectEqualStrings("a,b", find.roots.?);
    try std.testing.expectEqual(@as(?usize, 100), find.page_size);
    try std.testing.expect(find.json);
    const span = cli.parseArgs(&.{ "read-span", "d", "school", "notes.md", "3", "7", "--context", "20" }, &buffer).read_span;
    try std.testing.expectEqual(@as(u32, 3), span.start);
    try std.testing.expectEqual(@as(u32, 20), span.context);
    const list = cli.parseArgs(&.{ "list-files", "d", "--root", "home", "--prefix", "recipes/", "--status", "pending", "--page-size", "1000" }, &buffer).list_files;
    try std.testing.expectEqualStrings("pending", list.status.?);
    const apply_args = cli.parseArgs(&.{ "apply", "d", "--changes", "c.json", "--expect-generation", "0", "--allow-file-reads" }, &buffer).apply;
    try std.testing.expectEqual(@as(?u64, 0), apply_args.expect_generation);
    try std.testing.expect(apply_args.allow_file_reads);
    const serve = cli.parseArgs(&.{ "serve", "d", "--roots", "school", "--labels", "adults,kids", "--allow-write", "--allow-file-reads" }, &buffer).serve;
    try std.testing.expectEqualStrings("adults,kids", serve.labels.?);
    try std.testing.expect(serve.allow_write and serve.allow_file_reads);
    try std.testing.expect(cli.parseArgs(&.{ "roots", "d", "--json" }, &buffer).roots.json);
    try std.testing.expect(cli.parseArgs(&.{ "outline", "d", "r", "p" }, &buffer) == .outline);

    try expectUsage(&.{ "find", "d" }, &.{"missing argument"});
    try expectUsage(&.{ "find", "d", "q", "--mode", "fuzzy" }, &.{ "--mode", "'fuzzy'" });
    try expectUsage(&.{ "find", "d", "q", "--page-size", "101" }, &.{ "--page-size", "1-100" });
    try expectUsage(&.{ "find", "d", "q", "--roots", "a,,b" }, &.{"--roots"});
    try expectUsage(&.{ "find", "d", "caf\xff" }, &.{"not valid UTF-8"});
    try expectUsage(&.{ "find", "d", "q", "--bogus" }, &.{ "unknown flag for find", "'--bogus'" });
    try expectUsage(&.{ "outline", "d", "r" }, &.{"<path>"});
    try expectUsage(&.{ "read-span", "d", "r", "p", "0", "1" }, &.{"read-span <start>"});
    try expectUsage(&.{ "read-span", "d", "r", "p", "5", "4" }, &.{"must be at least <start>"});
    try expectUsage(&.{ "read-span", "d", "r", "p", "1", "2", "--context", "21" }, &.{ "--context", "0-20" });
    try expectUsage(&.{ "list-files", "d", "--status", "done" }, &.{"--status"});
    try expectUsage(&.{ "list-files", "d", "--page-size", "0" }, &.{"--page-size"});
    try expectUsage(&.{ "roots", "d", "extra" }, &.{"unknown flag for roots"});
    try expectUsage(&.{ "apply", "d" }, &.{"--changes <file>"});
    try expectUsage(&.{ "apply", "d", "--changes", "c", "--expect-generation", "-1" }, &.{"--expect-generation"});
    try expectUsage(&.{ "serve", "d", "--labels", "" }, &.{"--labels"});
}

test "S3-T4: --json prints exactly the operation's JSON; text output and refusals" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const request = "{\"roots\":[{\"root_id\":\"school\",\"kind\":\"host\"}],\"changes\":[{\"op\":\"add\",\"root_id\":\"school\",\"path\":\"week.md\",\"content_base64\":\"IyBXZWVrCgp0aWRlIHRhYmxlCg==\"}]}";
    try tmp.dir.writeFile(io, .{ .sub_path = "changes.json", .data = request });
    const index = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/index", .{tmp.sub_path});
    const changes = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/changes.json", .{tmp.sub_path});
    var out: std.Io.Writer.Allocating = .init(a);
    var err: std.Io.Writer.Allocating = .init(a);
    try std.testing.expectEqual(@as(u8, 0), try cli.runApply(io, a, .{ .path = index, .changes = changes }, &out.writer, &err.writer));
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "applied: generation=1 added=1 "));

    out.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 0), try cli.runFind(io, a, .{ .path = index, .query = "tide", .json = true }, &out.writer, &err.writer));
    const service = try cli.openService(a, io, index);
    var params = std.json.ObjectMap.empty;
    try params.put(a, "query", .{ .string = "tide" });
    const direct = (try @import("ops.zig").find(a, service, params, cli.cli_caller)).ok;
    try std.testing.expectEqualStrings(direct, out.written()[0 .. out.written().len - 1]);

    out.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 0), try cli.runReadSpan(io, a, .{ .path = index, .root_id = "school", .file = "week.md", .start = 3, .end = 3, .context = 1 }, &out.writer, &err.writer));
    try std.testing.expectEqualStrings("\ntide table\n", out.written());

    out.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 1), try cli.runOutline(io, a, .{ .path = index, .root_id = "school", .file = "nope.md" }, &out.writer, &err.writer));
    try std.testing.expectEqualStrings("", out.written());
    try std.testing.expectEqualStrings("searchd: SS_ERR_NOT_FOUND: not indexed or not retained: school/nope.md\n", err.written());

    out.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 0), try cli.runRoots(io, a, .{ .path = index }, &out.writer, &err.writer));
    try std.testing.expectEqualStrings("school  school  host  files=1 documents=1 pending=0\n", out.written());

    // --expect-generation: stale, and a request that states another one.
    err.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 1), try cli.runApply(io, a, .{ .path = index, .changes = changes, .expect_generation = 5 }, &out.writer, &err.writer));
    try std.testing.expectEqualStrings("searchd: SS_ERR_INVALID_ARGUMENT: stale: generation is 1\n", err.written());
    try tmp.dir.writeFile(io, .{ .sub_path = "changes.json", .data = "{\"expect_generation\":1,\"changes\":[]}" });
    err.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 1), try cli.runApply(io, a, .{ .path = index, .changes = changes, .expect_generation = 2 }, &out.writer, &err.writer));
    try std.testing.expect(std.mem.indexOf(u8, err.written(), "differs from the request's expect_generation") != null);
}

// === S5-T11 (review R08): apply --filename-index =============================

test "S5-T11: --filename-index parses on apply only; twice is once; index's is unchanged" {
    var buffer: [512]u8 = undefined;
    try std.testing.expect(!cli.parseArgs(&.{ "apply", "d", "--changes", "c" }, &buffer).apply.filename_index);
    try std.testing.expect(cli.parseArgs(&.{ "apply", "d", "--filename-index", "--changes", "c" }, &buffer).apply.filename_index);
    const twice = cli.parseArgs(&.{ "apply", "d", "--changes", "c", "--filename-index", "--json", "--filename-index" }, &buffer).apply;
    try std.testing.expect(twice.filename_index and twice.json);
    try std.testing.expectEqualStrings("c", twice.changes);
    try std.testing.expectEqual(@as(?bool, true), cli.parseArgs(&.{ "index", "f", "--out", "o", "--filename-index" }, &buffer).index.options.caps.filename_index);
    try std.testing.expectEqual(@as(?bool, null), cli.parseArgs(&.{ "index", "f", "--out", "o" }, &buffer).index.options.caps.filename_index);
    try expectUsage(&.{ "apply", "d", "--filename-index" }, &.{"--changes <file>"});
    try expectUsage(&.{ "find", "d", "q", "--filename-index" }, &.{ "unknown flag for find", "'--filename-index'" });
    try expectUsage(&.{ "query", "d", "q", "--filename-index" }, &.{ "unknown flag for query", "'--filename-index'" });
    try expectUsage(&.{ "evidence", "d", "q", "--filename-index" }, &.{ "unknown flag for evidence", "'--filename-index'" });
    try expectUsage(&.{ "roots", "d", "--filename-index" }, &.{"unknown flag for roots"});
    try expectUsage(&.{ "list-files", "d", "--filename-index" }, &.{"unknown flag for list-files"});
    try expectUsage(&.{ "outline", "d", "r", "p", "--filename-index" }, &.{"unknown flag for outline"});
    try expectUsage(&.{ "read-span", "d", "r", "p", "1", "1", "--filename-index" }, &.{"unknown flag for read-span"});
    try expectUsage(&.{ "serve", "d", "--filename-index" }, &.{"unknown flag for serve"});
    try expectUsage(&.{ "mcp", "d", "--filename-index" }, &.{"unknown flag for mcp"});
    try expectUsage(&.{ "import-json", "d", "f", "--filename-index" }, &.{"unexpected argument for import-json"});
    try std.testing.expect(std.mem.indexOf(u8, cli.usage_text, "[--allow-file-reads] [--filename-index] [--json]") != null);
}

const s5t11_request = "{\"roots\":[{\"root_id\":\"school\",\"kind\":\"host\"},{\"root_id\":\"attic\",\"kind\":\"host\"}],\"changes\":[{\"op\":\"add\",\"root_id\":\"school\",\"path\":\"tide-table.md\",\"content_base64\":\"IyBXZWVrCgp0aWRlIHRhYmxlCg==\"}]}";

const S5T11 = struct {
    arena_state: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    changes: []const u8 = "",

    fn init() !*S5T11 {
        const self = try std.testing.allocator.create(S5T11);
        self.* = .{ .arena_state = std.heap.ArenaAllocator.init(std.testing.allocator), .tmp = std.testing.tmpDir(.{ .iterate = true }) };
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "changes.json", .data = s5t11_request });
        self.changes = try self.path("changes.json");
        return self;
    }

    fn deinit(self: *S5T11) void {
        self.tmp.cleanup();
        self.arena_state.deinit();
        std.testing.allocator.destroy(self);
    }

    fn path(self: *S5T11, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.arena_state.allocator(), ".zig-cache/tmp/{s}/{s}", .{ self.tmp.sub_path, name });
    }

    /// `runApply`'s status, stdout and stderr.
    fn apply(self: *S5T11, index: []const u8, filename_index: bool) !struct { status: u8, out: []const u8, err: []const u8 } {
        const a = self.arena_state.allocator();
        var out: std.Io.Writer.Allocating = .init(a);
        var err: std.Io.Writer.Allocating = .init(a);
        const status = try cli.runApply(std.testing.io, a, .{ .path = index, .changes = self.changes, .filename_index = filename_index }, &out.writer, &err.writer);
        return .{ .status = status, .out = out.written(), .err = err.written() };
    }

    fn roots(self: *S5T11, index: []const u8) ![]const u8 {
        const a = self.arena_state.allocator();
        var out: std.Io.Writer.Allocating = .init(a);
        var err: std.Io.Writer.Allocating = .init(a);
        try std.testing.expectEqual(@as(u8, 0), try cli.runRoots(std.testing.io, a, .{ .path = index }, &out.writer, &err.writer));
        return out.written();
    }

    fn engine(self: *S5T11, index: []const u8) !@import("engine.zig").Engine {
        return (try cli.openService(self.arena_state.allocator(), std.testing.io, index)).engine;
    }

    /// Every file of the index directory, name and bytes, in name order.
    fn files(self: *S5T11, index_name: []const u8) ![]const u8 {
        const a = self.arena_state.allocator();
        const io = std.testing.io;
        var dir = try self.tmp.dir.openDir(io, index_name, .{ .iterate = true });
        defer dir.close(io);
        var names: std.ArrayList([]const u8) = .empty;
        var it = dir.iterate();
        while (try it.next(io)) |entry| if (entry.kind == .file) try names.append(a, try a.dupe(u8, entry.name));
        std.mem.sort([]const u8, names.items, {}, struct {
            fn less(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.less);
        var all: std.Io.Writer.Allocating = .init(a);
        for (names.items) |name| {
            try all.writer.print("{s}\n", .{name});
            try all.writer.writeAll(try dir.readFileAlloc(io, name, a, .unlimited));
        }
        return all.written();
    }
};

test "S5-T11: a fresh apply with --filename-index publishes only the requested roots with the channel" {
    const f = try S5T11.init();
    defer f.deinit();
    const index = try f.path("fresh");
    const applied = try f.apply(index, true);
    try std.testing.expectEqual(@as(u8, 0), applied.status);
    try std.testing.expect(std.mem.startsWith(u8, applied.out, "applied: generation=1 added=1 "));
    const engine = try f.engine(index);
    try std.testing.expectEqual(@as(u64, 1), engine.generation);
    try std.testing.expect(engine.filename_index_enabled);
    try std.testing.expectEqualStrings("school  school  host  files=1 documents=1 pending=0\nattic  attic  host  files=0 documents=0 pending=0\n", try f.roots(index));
    // filename, both and content answer at once.
    const a = f.arena_state.allocator();
    for ([_]@import("filename_field.zig").Field{ .filename, .both, .content }) |field| {
        var out: std.Io.Writer.Allocating = .init(a);
        try cli.runQuery(std.testing.io, a, index, "tide", .{ .search_field = field, .json = true }, &out.writer);
        try std.testing.expect(std.mem.indexOf(u8, out.written(), "tide-table.md") != null);
    }
}

test "S5-T11: without the flag a fresh apply stays plain, as before" {
    const f = try S5T11.init();
    defer f.deinit();
    const index = try f.path("plain");
    try std.testing.expectEqual(@as(u8, 0), (try f.apply(index, false)).status);
    const engine = try f.engine(index);
    try std.testing.expectEqual(@as(u64, 1), engine.generation);
    try std.testing.expect(!engine.filename_index_enabled);
}

test "S5-T11: an index with the channel takes the flag as a no-op; a repeat is safe" {
    const f = try S5T11.init();
    defer f.deinit();
    const index = try f.path("repeat");
    try std.testing.expectEqual(@as(u8, 0), (try f.apply(index, true)).status);
    const again = try f.apply(index, true);
    try std.testing.expectEqual(@as(u8, 0), again.status);
    try std.testing.expect(std.mem.startsWith(u8, again.out, "applied: generation=2 added=0 changed=0 removed=0 moved=0 pending=0 unchanged=1 "));
    const without = try f.apply(index, false);
    try std.testing.expect(std.mem.startsWith(u8, without.out, "applied: generation=3 added=0 changed=0 removed=0 moved=0 pending=0 unchanged=1 "));
    try std.testing.expect((try f.engine(index)).filename_index_enabled);
}

test "S5-T11: an index without the channel refuses the flag: exit 2, one line, nothing written" {
    const f = try S5T11.init();
    defer f.deinit();
    const index = try f.path("plain");
    try std.testing.expectEqual(@as(u8, 0), (try f.apply(index, false)).status);
    const before = try f.files("plain");
    const refused = try f.apply(index, true);
    try std.testing.expectEqual(cli.usage_exit_status, refused.status);
    try std.testing.expectEqualStrings("", refused.out);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, refused.err, "\n"));
    try std.testing.expect(std.mem.startsWith(u8, refused.err, "searchd: invalid value for apply --filename-index: "));
    try std.testing.expect(std.mem.indexOf(u8, refused.err, "has no file-name channel") != null);
    try std.testing.expectEqualStrings(before, try f.files("plain"));
    const engine = try f.engine(index);
    try std.testing.expectEqual(@as(u64, 1), engine.generation);
    try std.testing.expect(!engine.filename_index_enabled);
}

test "S5-T11: a crash after the fresh one-step publish leaves the complete first generation with the channel" {
    // The S3-T3 recovery method (`fail_after_publish`: the MANIFEST is
    // published, INDEX-STATE.json is not written) on the options `runApply`
    // passes for the flag.
    const f = try S5T11.init();
    defer f.deinit();
    const a = f.arena_state.allocator();
    const io = std.testing.io;
    var dir = try f.tmp.dir.createDirPathOpen(io, "crash", .{ .open_options = .{ .iterate = true } });
    defer dir.close(io);
    try std.testing.expectError(error.SimulatedCrash, @import("apply.zig").applyChanges(a, io, dir, s5t11_request, .{ .filename_index = true, .fail_after_publish = true }));
    const index = try f.path("crash");
    const crashed = try f.engine(index);
    try std.testing.expectEqual(@as(u64, 1), crashed.generation);
    try std.testing.expect(crashed.filename_index_enabled);
    try std.testing.expectEqualStrings("school  school  host  files=1 documents=1 pending=0\nattic  attic  host  files=0 documents=0 pending=0\n", try f.roots(index));
    // The retry, with or without the flag, sees generation 1 and keeps the channel.
    const retry = try f.apply(index, true);
    try std.testing.expect(std.mem.startsWith(u8, retry.out, "applied: generation=2 added=0 changed=0 removed=0 moved=0 pending=0 unchanged=1 "));
    const plain = try f.apply(index, false);
    try std.testing.expect(std.mem.startsWith(u8, plain.out, "applied: generation=3 "));
    try std.testing.expect((try f.engine(index)).filename_index_enabled);
}
