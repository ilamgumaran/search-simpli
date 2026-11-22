//! S1-T6 criterion 1: the non-`--update` `searchd index` summary line names
//! `budget_exhausted`, between `unreadable=` and `documents=`.
const std = @import("std");
const cli = @import("interfaces").cli;
const indexer = @import("core").indexer;

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
    try std.testing.expectEqual(@as(?@import("core").find.Mode, .phrase), find.mode);
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
    const direct = (try @import("operations").ops.find(a, service, params, cli.cli_caller)).ok;
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

    fn engine(self: *S5T11, index: []const u8) !@import("core").engine.Engine {
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
    for ([_]@import("core").filename_field.Field{ .filename, .both, .content }) |field| {
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
    try std.testing.expectError(error.SimulatedCrash, @import("core").apply.applyChanges(a, io, dir, s5t11_request, .{ .filename_index = true, .fail_after_publish = true }));
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

// ---------------------------------------------------------------------------
// S6-T20: a full rebuild chooses its generation number under `WRITER.LOCK`
// (`docs/tasks/S6-T20.md`, `docs/decisions/0003-full-rebuild-numbers-under-writer-lock.md`).
//
// S6-T17's verifier showed with probes that `searchd index` (and
// `ss_index_folder`) chose the number with `nextFreeGeneration` before the
// lock: a writer publishing in between made the rebuild fail with
// `PathAlreadyExists` (probe B) or publish a used number again and move
// `MANIFEST` back (probe C). These tests run that other writer inside the
// rebuild, at one named file-system call, through a `std.Io` that serves every
// call from `std.testing.io` and runs one step right after the call it waits
// for (`NameSeam`, a sibling of S6-T17's `StatSeam` in
// `core/manifest_read_test.zig`, which waits for a `stat` by inode; the names
// waited for here do not exist yet, so this one waits for a name). No timing
// is involved. The rebuild is `cli.runIndex`, as `searchd index` runs it.

const s6t20 = struct {
    const chunker = @import("core").chunker;
    const generation_alloc = @import("core").generation_alloc;
    const importer = @import("core").importer;
    const lifecycle = @import("core").lifecycle;
    const snapshot_open = @import("core").snapshot_open;

    /// Where the other writer runs.
    const Point = enum {
        /// After the `stat` of `state-10.hybstate`, the last of the six names
        /// `nextFreeGeneration` probes before it returns 10 for a folder at
        /// generation 9: the rebuild has chosen its number and not published.
        after_choice,
        /// When the folder walk opens the subfolder `sub`: on the code before
        /// S6-T20 the rebuild had chosen 10 already; after it, it has not.
        during_walk,
        /// S6-T20 rework 1 (the Verdict's finding 1): after the choice has
        /// returned, not inside it. Armed by the same `stat` of
        /// `state-10.hybstate` as `after_choice`, it fires right after the
        /// rebuild's next call that opens, creates, links, renames, deletes,
        /// unlocks or closes a file: the first step of the publish on the
        /// head, or, if the lease were released after the choice, its unlock.
        after_choice_returned,
    };

    /// The other writer.
    const Other = enum {
        /// `searchd index --update` (`indexFolderIncremental`), once.
        update,
        /// The same twice with `keep_generations = 1`: the second publish
        /// prunes the first one's sections (probe C).
        update_twice_keep_one,
        /// Another `searchd index` full rebuild (`cli.runIndex`).
        rebuild,
        /// `searchd import-json` of a one-document snapshot numbered as a host
        /// would number it from an open: the current generation plus one.
        import_json,
    };

    const Attempt = union(enum) { published: u64, refused: anyerror };

    const NameSeam = struct {
        var base: std.Io = undefined;
        var table: std.Io.VTable = undefined;
        var pending: ?Step = null;
        var wanted: []const u8 = "";
        var on_open_dir = false;
        var ran: usize = 0;
        /// `after_choice_returned`: armed by the `stat`, and the name of the
        /// call it then fired after.
        var after_return = false;
        var armed_next = false;
        var fired_after: []const u8 = "";

        const Step = struct {
            context: *anyopaque,
            run: *const fn (*anyopaque, std.Io) void,
        };

        fn dirStatFile(userdata: ?*anyopaque, dir: std.Io.Dir, sub_path: []const u8, options: std.Io.Dir.StatFileOptions) std.Io.Dir.StatFileError!std.Io.File.Stat {
            const result = base.vtable.dirStatFile(userdata, dir, sub_path, options);
            if (after_return) {
                if (pending != null and std.mem.eql(u8, sub_path, wanted)) armed_next = true;
            } else if (!on_open_dir) fire(sub_path);
            return result;
        }

        /// `after_choice_returned`: the other writer runs after `call`, the
        /// first such call after the arming `stat`.
        fn next(call: []const u8) void {
            if (!armed_next) return;
            armed_next = false;
            const step = pending orelse return;
            pending = null;
            fired_after = call;
            ran += 1;
            step.run(step.context, base);
        }

        fn dirCreateFile(userdata: ?*anyopaque, dir: std.Io.Dir, sub_path: []const u8, options: std.Io.Dir.CreateFileOptions) std.Io.File.OpenError!std.Io.File {
            const result = base.vtable.dirCreateFile(userdata, dir, sub_path, options);
            next("dirCreateFile");
            return result;
        }

        fn dirCreateFileAtomic(userdata: ?*anyopaque, dir: std.Io.Dir, sub_path: []const u8, options: std.Io.Dir.CreateFileAtomicOptions) std.Io.Dir.CreateFileAtomicError!std.Io.File.Atomic {
            const result = base.vtable.dirCreateFileAtomic(userdata, dir, sub_path, options);
            next("dirCreateFileAtomic");
            return result;
        }

        fn dirOpenFile(userdata: ?*anyopaque, dir: std.Io.Dir, sub_path: []const u8, options: std.Io.Dir.OpenFileOptions) std.Io.File.OpenError!std.Io.File {
            const result = base.vtable.dirOpenFile(userdata, dir, sub_path, options);
            next("dirOpenFile");
            return result;
        }

        fn dirDeleteFile(userdata: ?*anyopaque, dir: std.Io.Dir, sub_path: []const u8) std.Io.Dir.DeleteFileError!void {
            const result = base.vtable.dirDeleteFile(userdata, dir, sub_path);
            next("dirDeleteFile");
            return result;
        }

        fn dirRename(userdata: ?*anyopaque, old_dir: std.Io.Dir, old_sub_path: []const u8, new_dir: std.Io.Dir, new_sub_path: []const u8) std.Io.Dir.RenameError!void {
            const result = base.vtable.dirRename(userdata, old_dir, old_sub_path, new_dir, new_sub_path);
            next("dirRename");
            return result;
        }

        fn dirRenamePreserve(userdata: ?*anyopaque, old_dir: std.Io.Dir, old_sub_path: []const u8, new_dir: std.Io.Dir, new_sub_path: []const u8) std.Io.Dir.RenamePreserveError!void {
            const result = base.vtable.dirRenamePreserve(userdata, old_dir, old_sub_path, new_dir, new_sub_path);
            next("dirRenamePreserve");
            return result;
        }

        fn dirHardLink(userdata: ?*anyopaque, old_dir: std.Io.Dir, old_sub_path: []const u8, new_dir: std.Io.Dir, new_sub_path: []const u8, options: std.Io.Dir.HardLinkOptions) std.Io.Dir.HardLinkError!void {
            const result = base.vtable.dirHardLink(userdata, old_dir, old_sub_path, new_dir, new_sub_path, options);
            next("dirHardLink");
            return result;
        }

        fn dirSymLink(userdata: ?*anyopaque, dir: std.Io.Dir, target_path: []const u8, sym_link_path: []const u8, flags: std.Io.Dir.SymLinkFlags) std.Io.Dir.SymLinkError!void {
            const result = base.vtable.dirSymLink(userdata, dir, target_path, sym_link_path, flags);
            next("dirSymLink");
            return result;
        }

        fn fileUnlock(userdata: ?*anyopaque, file: std.Io.File) void {
            base.vtable.fileUnlock(userdata, file);
            next("fileUnlock");
        }

        fn fileClose(userdata: ?*anyopaque, files: []const std.Io.File) void {
            base.vtable.fileClose(userdata, files);
            next("fileClose");
        }

        fn dirOpenDir(userdata: ?*anyopaque, dir: std.Io.Dir, sub_path: []const u8, options: std.Io.Dir.OpenOptions) std.Io.Dir.OpenError!std.Io.Dir {
            const result = base.vtable.dirOpenDir(userdata, dir, sub_path, options);
            if (on_open_dir) fire(sub_path);
            return result;
        }

        fn fire(sub_path: []const u8) void {
            const step = pending orelse return;
            if (!std.mem.eql(u8, sub_path, wanted)) return;
            pending = null;
            ran += 1;
            step.run(step.context, base);
        }

        fn arm(io: std.Io, point: Point, step: Step) std.Io {
            base = io;
            table = io.vtable.*;
            table.dirStatFile = dirStatFile;
            table.dirOpenDir = dirOpenDir;
            table.dirCreateFile = dirCreateFile;
            table.dirCreateFileAtomic = dirCreateFileAtomic;
            table.dirOpenFile = dirOpenFile;
            table.dirDeleteFile = dirDeleteFile;
            table.dirRename = dirRename;
            table.dirRenamePreserve = dirRenamePreserve;
            table.dirHardLink = dirHardLink;
            table.dirSymLink = dirSymLink;
            table.fileUnlock = fileUnlock;
            table.fileClose = fileClose;
            pending = step;
            on_open_dir = point == .during_walk;
            after_return = point == .after_choice_returned;
            armed_next = false;
            fired_after = "";
            wanted = switch (point) {
                .after_choice, .after_choice_returned => "state-10.hybstate",
                .during_walk => "sub",
            };
            ran = 0;
            return .{ .userdata = io.userdata, .vtable = &table };
        }
    };

    /// A folder `notes` (`a.md`, `sub/b.md`) indexed as generation 9 into `out`.
    const Folder = struct {
        tmp: std.testing.TmpDir,
        root: std.Io.Dir,
        out: std.Io.Dir,
        root_path: []const u8,
        out_path: []const u8,

        fn init(a: std.mem.Allocator) !Folder {
            const io = std.testing.io;
            var tmp = std.testing.tmpDir(.{ .iterate = true });
            errdefer tmp.cleanup();
            try tmp.dir.createDirPath(io, "notes/sub");
            try tmp.dir.writeFile(io, .{ .sub_path = "notes/a.md", .data = "alpha evidence about recovery\n" });
            try tmp.dir.writeFile(io, .{ .sub_path = "notes/sub/b.md", .data = "beta evidence about publication\n" });
            try tmp.dir.createDir(io, "out", .default_dir);
            const root = try tmp.dir.openDir(io, "notes", .{ .iterate = true });
            const out = try tmp.dir.openDir(io, "out", .{ .iterate = true });
            const report = try indexer.indexFolder(a, io, root, out, .v2, 9, chunker.default_max_chars, chunker.default_overlap_lines, .{});
            try std.testing.expectEqual(@as(u64, 9), report.generation);
            return .{
                .tmp = tmp,
                .root = root,
                .out = out,
                .root_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/notes", .{tmp.sub_path}),
                .out_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/out", .{tmp.sub_path}),
            };
        }

        fn deinit(self: *Folder) void {
            self.out.close(std.testing.io);
            self.root.close(std.testing.io);
            self.tmp.cleanup();
        }
    };

    /// `searchd index` (`cli.runIndex`) through `io`; the generation its line
    /// names.
    fn runRebuild(a: std.mem.Allocator, io: std.Io, root_path: []const u8, out_path: []const u8, options: cli.IndexOptions) !u64 {
        var output: std.Io.Writer.Allocating = .init(a);
        try cli.runIndex(io, std.testing.allocator, root_path, out_path, options, &output.writer);
        const text = output.written();
        const key = " generation=";
        const at = std.mem.indexOf(u8, text, key) orelse return error.TestUnexpectedResult;
        const rest = text[at + key.len ..];
        return std.fmt.parseInt(u64, rest[0 .. std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len], 10);
    }

    fn manifestGeneration(a: std.mem.Allocator, io: std.Io, out: std.Io.Dir) !u64 {
        return generation_alloc.currentGeneration(a, io, out);
    }

    const OtherWriter = struct {
        a: std.mem.Allocator,
        folder: *const Folder,
        other: Other,
        attempts: [2]Attempt = undefined,
        count: usize = 0,
        manifest_after: u64 = 0,

        fn run(context: *anyopaque, io: std.Io) void {
            const self: *OtherWriter = @ptrCast(@alignCast(context));
            switch (self.other) {
                .update => self.record(self.update(io, null)),
                .update_twice_keep_one => {
                    self.record(self.update(io, 1));
                    self.record(self.update(io, 1));
                },
                .rebuild => self.record(runRebuild(self.a, io, self.folder.root_path, self.folder.out_path, .{})),
                .import_json => self.record(self.importOne(io)),
            }
            self.manifest_after = manifestGeneration(self.a, io, self.folder.out) catch 0;
        }

        fn record(self: *OtherWriter, outcome: anyerror!u64) void {
            self.attempts[self.count] = if (outcome) |generation| .{ .published = generation } else |err| .{ .refused = err };
            self.count += 1;
        }

        fn update(self: *OtherWriter, io: std.Io, keep: ?usize) !u64 {
            const report = try indexer.indexFolderIncremental(self.a, io, self.folder.root, self.folder.out, .v2, chunker.default_max_chars, chunker.default_overlap_lines, .{ .keep_generations = keep });
            return report.generation;
        }

        fn importOne(self: *OtherWriter, io: std.Io) !u64 {
            const next = (try manifestGeneration(self.a, io, self.folder.out)) + 1;
            const json = try std.fmt.allocPrint(self.a,
                \\{{"format_version":1,"generation":{d},"analyzer_id":"ascii-alnum-v1","embedding_model_id":"none","documents":[
                \\{{"id":"other","path":"other.md","start_line":1,"end_line":1,"text":"another writer","vector":[],"required_labels":[]}}]}}
            , .{next});
            const report = try importer.importJson(self.folder.out, io, std.testing.allocator, json);
            return report.generation;
        }

        fn step(self: *OtherWriter) NameSeam.Step {
            return .{ .context = self, .run = run };
        }
    };

    /// One interleaving: a folder at 9, `searchd index` through the seam, the
    /// other writer at `point`. Appends one line to `lines` and returns whether
    /// the rulings hold: the rebuild publishes, no number is published twice,
    /// `MANIFEST` never goes back, and the other writer is refused with
    /// `WriterBusy` when it comes after the rebuild's choice.
    fn race(a: std.mem.Allocator, point: Point, other: Other, lines: *std.Io.Writer) !bool {
        const io = std.testing.io;
        var folder = try Folder.init(a);
        defer folder.deinit();
        var writer = OtherWriter{ .a = a, .folder = &folder, .other = other };
        const before = try manifestGeneration(a, io, folder.out);
        const seam = NameSeam.arm(io, point, writer.step());
        const rebuild = runRebuild(a, seam, folder.root_path, folder.out_path, .{});
        const after = try manifestGeneration(a, io, folder.out);

        try lines.print("  {s} {s}: other [", .{ @tagName(point), @tagName(other) });
        for (writer.attempts[0..writer.count], 0..) |attempt, i| {
            if (i != 0) try lines.writeAll(", ");
            switch (attempt) {
                .published => |g| try lines.print("published {d}", .{g}),
                .refused => |err| try lines.print("{s}", .{@errorName(err)}),
            }
        }
        try lines.print("], MANIFEST {d} -> {d} -> {d}, rebuild ", .{ before, writer.manifest_after, after });
        if (rebuild) |g| try lines.print("published {d}", .{g}) else |err| try lines.print("{s}", .{@errorName(err)});
        if (point == .after_choice_returned) try lines.print(" (other ran after the rebuild's {s})", .{NameSeam.fired_after});

        var ok = NameSeam.ran == 1 and writer.count != 0;
        const published = rebuild catch {
            try lines.writeAll(" FAIL\n");
            return false;
        };
        // No number twice; the rebuild's above every other one.
        var numbers: [3]u64 = undefined;
        var n: usize = 0;
        for (writer.attempts[0..writer.count]) |attempt| switch (attempt) {
            .published => |g| {
                numbers[n] = g;
                n += 1;
            },
            .refused => |err| if (point == .during_walk or err != error.WriterBusy) {
                ok = false;
            },
        };
        if (point != .during_walk and n != 0) ok = false;
        for (numbers[0..n], 0..) |g, i| {
            if (g >= published) ok = false;
            for (numbers[0..i]) |earlier| if (earlier == g) {
                ok = false;
            };
        }
        // MANIFEST never goes back, and it ends on the rebuild's number.
        if (writer.manifest_after < before or after < writer.manifest_after or after != published or published <= before) ok = false;
        const opened = try snapshot_open.openScoped(a, io, folder.out);
        defer snapshot_open.close(opened.engine, opened.folder);
        if (opened.engine.generation != published) ok = false;
        try lines.writeAll(if (ok) " ok\n" else " FAIL\n");
        return ok;
    }
};

test "S6-T20: another writer racing a full rebuild is refused with WriterBusy once the rebuild has chosen its number; no number twice, MANIFEST never back" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var lines: std.Io.Writer.Allocating = .init(a);
    var failed: usize = 0;
    // Every interleaving is tried and printed before the test fails.
    inline for (.{ s6t20.Point.after_choice, s6t20.Point.during_walk }) |point| {
        inline for (.{ s6t20.Other.update, s6t20.Other.update_twice_keep_one, s6t20.Other.rebuild, s6t20.Other.import_json }) |other| {
            if (!try s6t20.race(a, point, other, &lines.writer)) failed += 1;
        }
    }
    std.debug.print("S6-T20 interleavings (point other: other's outcomes, MANIFEST before -> after the other -> after the rebuild, rebuild's outcome):\n{s}", .{lines.written()});
    try std.testing.expectEqual(@as(usize, 0), failed);
}

test "S6-T20: one lease, taken once: another writer that runs after the rebuild's choice has returned, before its publish, is refused with WriterBusy; no number twice, MANIFEST never back" {
    // S6-T20 rework 1 (the Verdict's finding 1). `after_choice` runs the other
    // writer inside `nextFreeGeneration`, so a lease released and taken again
    // after the choice would pass it; this point runs it after the choice has
    // returned, at the rebuild's next file step.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var lines: std.Io.Writer.Allocating = .init(a);
    var failed: usize = 0;
    inline for (.{ s6t20.Other.update, s6t20.Other.update_twice_keep_one, s6t20.Other.rebuild, s6t20.Other.import_json }) |other| {
        if (!try s6t20.race(a, .after_choice_returned, other, &lines.writer)) failed += 1;
    }
    std.debug.print("S6-T20 one lease (point other: other's outcomes, MANIFEST before -> after the other -> after the rebuild, rebuild's outcome):\n{s}", .{lines.written()});
    try std.testing.expectEqual(@as(usize, 0), failed);
}

/// Every entry of `dir`, name and bytes, as one SHA-256 (a directory's bytes
/// as `<dir>`).
fn s6t20DirDigest(a: std.mem.Allocator, dir: std.Io.Dir) ![32]u8 {
    const io = std.testing.io;
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| try names.append(a, try a.dupe(u8, entry.name));
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (names.items) |name| {
        hash.update(name);
        hash.update("\x00");
        hash.update(dir.readFileAlloc(io, name, a, .unlimited) catch |err| switch (err) {
            error.IsDir => "<dir>",
            else => return err,
        });
        hash.update("\x00");
    }
    return hash.finalResult();
}

// S6-T21 (rulings 2 and 4 after Part 1): this was S6-T20's test of a caller's
// number that is not free, which expected `PathAlreadyExists` in all three
// cases. A number at or below the highest generation the directory has any
// trace of is now refused first, with `StaleGeneration`; `PathAlreadyExists`
// stays for a number above that floor whose name is taken by something that is
// not a trace (a `source-N.hybsrc` leftover).
test "S6-T21: searchd index --generation N at or below the highest trace is refused with StaleGeneration, one above it whose name is taken with PathAlreadyExists; nothing on disk changes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    const Taken = enum { published_by_another_writer, lone_lexical_leftover, lone_state_leftover, lone_source_leftover };
    inline for (.{ Taken.published_by_another_writer, Taken.lone_lexical_leftover, Taken.lone_state_leftover, Taken.lone_source_leftover }) |taken| {
        var folder = try s6t20.Folder.init(a);
        defer folder.deinit();
        switch (taken) {
            .published_by_another_writer => {
                const report = try indexer.indexFolderIncremental(a, io, folder.root, folder.out, .v2, s6t20.chunker.default_max_chars, s6t20.chunker.default_overlap_lines, .{});
                try std.testing.expectEqual(@as(u64, 10), report.generation);
            },
            .lone_lexical_leftover => try folder.out.writeFile(io, .{ .sub_path = "lexical-10.hyblex", .data = "a crash leftover" }),
            .lone_state_leftover => try folder.out.writeFile(io, .{ .sub_path = "state-10.hybstate", .data = "a crash leftover" }),
            .lone_source_leftover => try folder.out.writeFile(io, .{ .sub_path = "source-10.hybsrc", .data = "a crash leftover" }),
        }
        const manifest_before = try s6t20.manifestGeneration(a, io, folder.out);
        const before = try s6t20DirDigest(a, folder.out);
        const outcome = s6t20.runRebuild(a, io, folder.root_path, folder.out_path, .{ .generation = 10 });
        if (outcome) |g| {
            std.debug.print("S6-T21 --generation 10 over {s}: published {d}\n", .{ @tagName(taken), g });
        } else |err| std.debug.print("S6-T21 --generation 10 over {s}: {s}\n", .{ @tagName(taken), @errorName(err) });
        try std.testing.expectError(if (taken == .lone_source_leftover) error.PathAlreadyExists else error.StaleGeneration, outcome);
        try std.testing.expectEqual(manifest_before, try s6t20.manifestGeneration(a, io, folder.out));
        try std.testing.expectEqualSlices(u8, &before, &try s6t20DirDigest(a, folder.out));
    }
}

test "S6-T20: searchd index with WRITER.LOCK held is refused with WriterBusy before it chooses a number" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    var folder = try s6t20.Folder.init(a);
    defer folder.deinit();

    // Probe A of S6-T17's Verdict: another writer holds the lock throughout.
    var lease = (try s6t20.lifecycle.tryAcquireWriter(folder.out, io)).?;
    var released = false;
    defer if (!released) lease.release(io);
    const before = try s6t20DirDigest(a, folder.out);
    try std.testing.expectError(error.WriterBusy, s6t20.runRebuild(a, io, folder.root_path, folder.out_path, .{}));
    try std.testing.expectEqualSlices(u8, &before, &try s6t20DirDigest(a, folder.out));
    try std.testing.expectEqual(@as(u64, 9), try s6t20.manifestGeneration(a, io, folder.out));

    // The order shows where the number is chosen: with no number left
    // (a lone section at `u64` max) and the lock held, a rebuild that chose
    // first answers `NoFreeGeneration`; one that takes the lock first answers
    // `WriterBusy`. Released, it is `NoFreeGeneration` as before.
    try folder.out.writeFile(io, .{ .sub_path = "lexical-18446744073709551615.hyblex", .data = "x" });
    const held = s6t20.runRebuild(a, io, folder.root_path, folder.out_path, .{});
    if (held) |g| {
        std.debug.print("S6-T20 lock held, no number left: published {d}\n", .{g});
    } else |err| std.debug.print("S6-T20 lock held, no number left: {s}\n", .{@errorName(err)});
    try std.testing.expectError(error.WriterBusy, held);
    lease.release(io);
    released = true;
    try std.testing.expectError(error.NoFreeGeneration, s6t20.runRebuild(a, io, folder.root_path, folder.out_path, .{}));
    try std.testing.expectEqual(@as(u64, 9), try s6t20.manifestGeneration(a, io, folder.out));
}

// --- S6-T21: a caller's own generation number at or below the floor ---------
//
// `searchd index --generation N` and an import (`import-json`, `ss_import_json`)
// bring their own number. Before S6-T21 a free number at or below the current
// generation was published as given and moved `MANIFEST` back (S6-T20's
// Verdict, finding 2 and item 3a). Now the number must be above the highest
// generation the directory has any trace of, checked under the writer lease
// (decision 0004), or the call is refused with `StaleGeneration` and changes
// nothing on disk.

const s6t21 = struct {
    const importer = @import("core").importer;

    /// An import of one document numbered `generation`, as a host builds it.
    fn importJson(a: std.mem.Allocator, generation: u64) ![]const u8 {
        return std.fmt.allocPrint(a,
            \\{{"format_version":1,"generation":{d},"analyzer_id":"ascii-alnum-v1","embedding_model_id":"none","documents":[
            \\{{"id":"host","path":"host.md","start_line":1,"end_line":1,"text":"a host import","vector":[],"required_labels":[]}}]}}
        , .{generation});
    }

    fn say(lines: *std.Io.Writer, outcome: anyerror!u64) !void {
        if (outcome) |g| try lines.print("published {d}", .{g}) else |err| try lines.print("{s}", .{@errorName(err)});
    }

    fn importAt(a: std.mem.Allocator, io: std.Io, out: std.Io.Dir, generation: u64) !u64 {
        const report = try importer.importJson(out, io, std.testing.allocator, try importJson(a, generation));
        return report.generation;
    }

    /// The caller-numbered writer under test.
    const Caller = enum {
        /// `searchd import-json` (the importer), numbered 10.
        import_json,
        /// `searchd index --generation 10` (`cli.runIndex`).
        index_generation,
    };

    /// What runs while the caller is held before its lock.
    const Other = enum {
        /// One full rebuild: publishes 10.
        rebuild_once,
        /// Two full rebuilds with `keep_generations = 1`: publish 10 and 11,
        /// and the second prunes 10's sections (the verifier's race).
        rebuild_twice_keep_one,
    };

    /// Serves every call from `std.testing.io` and runs one step right after
    /// the caller's `dirCreateFile` of `WRITER.LOCK`: the file is open and not
    /// yet locked, so the caller holds its number and not the lease. A sibling
    /// of `s6t20.NameSeam`.
    const LockSeam = struct {
        var base: std.Io = undefined;
        var table: std.Io.VTable = undefined;
        var pending: ?s6t20.NameSeam.Step = null;
        var ran: usize = 0;

        fn dirCreateFile(userdata: ?*anyopaque, dir: std.Io.Dir, sub_path: []const u8, options: std.Io.Dir.CreateFileOptions) std.Io.File.OpenError!std.Io.File {
            const result = base.vtable.dirCreateFile(userdata, dir, sub_path, options);
            if (std.mem.eql(u8, sub_path, "WRITER.LOCK")) if (pending) |step| {
                pending = null;
                ran += 1;
                step.run(step.context, base);
            };
            return result;
        }

        fn arm(io: std.Io, step: s6t20.NameSeam.Step) std.Io {
            base = io;
            table = io.vtable.*;
            table.dirCreateFile = dirCreateFile;
            pending = step;
            ran = 0;
            return .{ .userdata = io.userdata, .vtable = &table };
        }
    };

    const OtherWriter = struct {
        a: std.mem.Allocator,
        folder: *const s6t20.Folder,
        other: Other,
        published: [2]u64 = undefined,
        count: usize = 0,
        failed: ?anyerror = null,
        manifest_after: u64 = 0,
        digest_after: [32]u8 = undefined,

        fn run(context: *anyopaque, io: std.Io) void {
            const self: *OtherWriter = @ptrCast(@alignCast(context));
            const rounds: usize = if (self.other == .rebuild_once) 1 else 2;
            const keep: ?usize = if (self.other == .rebuild_once) null else 1;
            for (0..rounds) |_| {
                const g = s6t20.runRebuild(self.a, io, self.folder.root_path, self.folder.out_path, .{ .caps = .{ .keep_generations = keep } }) catch |err| {
                    self.failed = err;
                    return;
                };
                self.published[self.count] = g;
                self.count += 1;
            }
            self.manifest_after = s6t20.manifestGeneration(self.a, io, self.folder.out) catch 0;
            self.digest_after = s6t20DirDigest(self.a, self.folder.out) catch [_]u8{0} ** 32;
        }
    };

    /// One interleaving: a folder at 9; the caller numbers itself 10 (the
    /// current generation plus one, as a host numbers it from an open) and
    /// is held before its lock while `other` publishes. Appends one line and
    /// returns whether the rulings hold: the caller is refused with
    /// `StaleGeneration`, changes nothing, and `MANIFEST` never goes back.
    fn race(a: std.mem.Allocator, caller: Caller, other: Other, lines: *std.Io.Writer) !bool {
        const io = std.testing.io;
        var folder = try s6t20.Folder.init(a);
        defer folder.deinit();
        var writer = OtherWriter{ .a = a, .folder = &folder, .other = other };
        const before = try s6t20.manifestGeneration(a, io, folder.out);
        const number = before + 1;
        const payload = try importJson(a, number);
        const seam = LockSeam.arm(io, .{ .context = &writer, .run = OtherWriter.run });
        const outcome: anyerror!u64 = switch (caller) {
            .import_json => if (importer.importJson(folder.out, seam, std.testing.allocator, payload)) |report| report.generation else |err| err,
            .index_generation => s6t20.runRebuild(a, seam, folder.root_path, folder.out_path, .{ .generation = number }),
        };
        const after = try s6t20.manifestGeneration(a, io, folder.out);
        const digest = try s6t20DirDigest(a, folder.out);

        try lines.print("  {s} {d}, {s}: other [", .{ @tagName(caller), number, @tagName(other) });
        for (writer.published[0..writer.count], 0..) |g, i| {
            if (i != 0) try lines.writeAll(", ");
            try lines.print("published {d}", .{g});
        }
        try lines.print("], MANIFEST {d} -> {d} -> {d}, caller ", .{ before, writer.manifest_after, after });
        if (outcome) |g| try lines.print("published {d}", .{g}) else |err| try lines.print("{s}", .{@errorName(err)});

        var ok = LockSeam.ran == 1 and writer.failed == null and writer.count != 0;
        if (outcome) |_| {
            ok = false;
        } else |err| if (err != error.StaleGeneration) {
            ok = false;
        }
        if (after != writer.manifest_after or after < before) ok = false;
        if (!std.mem.eql(u8, &digest, &writer.digest_after)) ok = false;
        try lines.writeAll(if (ok) " ok\n" else " FAIL\n");
        return ok;
    }
};

test "S6-T21: a caller's number at or below the highest generation is refused with StaleGeneration and changes nothing; one above it publishes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    var folder = try s6t20.Folder.init(a);
    defer folder.deinit();
    var lines: std.Io.Writer.Allocating = .init(a);
    var failed: usize = 0;

    // The verifier's static case (S6-T20 Verdict 3a): 5 over 9, and 9 itself.
    const Try = struct { caller: s6t21.Caller, number: u64 };
    inline for (.{
        Try{ .caller = .index_generation, .number = 5 },
        Try{ .caller = .index_generation, .number = 9 },
        Try{ .caller = .import_json, .number = 5 },
        Try{ .caller = .import_json, .number = 9 },
    }) |attempt| {
        const before = try s6t20DirDigest(a, folder.out);
        const outcome: anyerror!u64 = switch (attempt.caller) {
            .index_generation => s6t20.runRebuild(a, io, folder.root_path, folder.out_path, .{ .generation = attempt.number }),
            .import_json => s6t21.importAt(a, io, folder.out, attempt.number),
        };
        const manifest_after = try s6t20.manifestGeneration(a, io, folder.out);
        const unchanged = std.mem.eql(u8, &before, &try s6t20DirDigest(a, folder.out));
        try lines.writer.print("  {s} {d} over 9: ", .{ @tagName(attempt.caller), attempt.number });
        if (outcome) |g| try lines.writer.print("published {d}", .{g}) else |err| try lines.writer.print("{s}", .{@errorName(err)});
        try lines.writer.print(", MANIFEST {d}, directory {s}\n", .{ manifest_after, if (unchanged) "unchanged" else "changed" });
        const refused = if (outcome) |_| false else |err| err == error.StaleGeneration;
        if (!refused or manifest_after != 9 or !unchanged) failed += 1;
    }

    // Above the floor: published as given, and the floor moves with it.
    const twelve = s6t20.runRebuild(a, io, folder.root_path, folder.out_path, .{ .generation = 12 });
    const thirteen = s6t21.importAt(a, io, folder.out, 13);
    const twelve_again = s6t21.importAt(a, io, folder.out, 12);
    try lines.writer.writeAll("  index_generation 12 over 9: ");
    try s6t21.say(&lines.writer, twelve);
    try lines.writer.writeAll("; import_json 13: ");
    try s6t21.say(&lines.writer, thirteen);
    try lines.writer.writeAll("; import_json 12 over 13: ");
    try s6t21.say(&lines.writer, twelve_again);
    try lines.writer.print("; MANIFEST {d}\n", .{try s6t20.manifestGeneration(a, io, folder.out)});
    if ((twelve catch 0) != 12 or (thirteen catch 0) != 13) failed += 1;
    if (twelve_again) |_| {
        failed += 1;
    } else |err| if (err != error.StaleGeneration) {
        failed += 1;
    }
    if (try s6t20.manifestGeneration(a, io, folder.out) != 13) failed += 1;

    std.debug.print("S6-T21 a caller's number over a folder at generation 9:\n{s}", .{lines.written()});
    try std.testing.expectEqual(@as(usize, 0), failed);
}

test "S6-T21: a caller's number held before its lock while other writers publish is refused with StaleGeneration; MANIFEST never back, nothing changed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var lines: std.Io.Writer.Allocating = .init(a);
    var failed: usize = 0;
    // The verifier's race (S6-T20 Verdict, finding 2): numbered 10 from an open
    // at 9; two rebuilds with `keep_generations = 1` publish 10 and 11 before
    // the caller takes the lock. Before S6-T21 the caller published 10 again
    // and `MANIFEST` went 11 -> 10.
    inline for (.{ s6t21.Caller.import_json, s6t21.Caller.index_generation }) |caller| {
        inline for (.{ s6t21.Other.rebuild_once, s6t21.Other.rebuild_twice_keep_one }) |other| {
            if (!try s6t21.race(a, caller, other, &lines.writer)) failed += 1;
        }
    }
    std.debug.print("S6-T21 races (caller number, other: other's outcomes, MANIFEST before -> after the other -> after the caller, caller's outcome):\n{s}", .{lines.written()});
    try std.testing.expectEqual(@as(usize, 0), failed);
}

test "S6-T21: a MANIFEST that is missing or cannot be decoded counts as absent; the section files still set the floor" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    var lines: std.Io.Writer.Allocating = .init(a);
    var failed: usize = 0;
    const Damage = enum { undecodable, missing };
    inline for (.{ Damage.undecodable, Damage.missing }) |damage| {
        var folder = try s6t20.Folder.init(a);
        defer folder.deinit();
        switch (damage) {
            .undecodable => try folder.out.writeFile(io, .{ .sub_path = "MANIFEST", .data = "not a manifest" }),
            .missing => try folder.out.deleteFile(io, "MANIFEST"),
        }
        // At or below generation 9's section files: refused, nothing changed.
        inline for (.{ 5, 9 }) |number| {
            const before = try s6t20DirDigest(a, folder.out);
            const outcome = s6t21.importAt(a, io, folder.out, number);
            const unchanged = std.mem.eql(u8, &before, &try s6t20DirDigest(a, folder.out));
            try lines.writer.print("  {s} MANIFEST, import_json {d}: ", .{ @tagName(damage), number });
            if (outcome) |g| try lines.writer.print("published {d}", .{g}) else |err| try lines.writer.print("{s}", .{@errorName(err)});
            try lines.writer.print(", directory {s}\n", .{if (unchanged) "unchanged" else "changed"});
            const refused = if (outcome) |_| false else |err| err == error.StaleGeneration;
            if (!refused or !unchanged) failed += 1;
        }
        // `--generation 10` over a damaged MANIFEST: the folder writer reads
        // MANIFEST itself (`apply.zig`, before the check) and fails as before
        // S6-T21; a missing one is a fresh start, above the floor.
        const before = try s6t20DirDigest(a, folder.out);
        const rebuilt = s6t20.runRebuild(a, io, folder.root_path, folder.out_path, .{ .generation = 10 });
        try lines.writer.print("  {s} MANIFEST, index_generation 10: ", .{@tagName(damage)});
        if (rebuilt) |g| try lines.writer.print("published {d}\n", .{g}) else |err| try lines.writer.print("{s}\n", .{@errorName(err)});
        switch (damage) {
            .undecodable => {
                if (rebuilt) |_| {
                    failed += 1;
                } else |err| if (err == error.StaleGeneration) {
                    failed += 1;
                }
                if (!std.mem.eql(u8, &before, &try s6t20DirDigest(a, folder.out))) failed += 1;
                // Above the floor, the import publishes and replaces it, as before.
                const ten = s6t21.importAt(a, io, folder.out, 10);
                try lines.writer.print("  {s} MANIFEST, import_json 10: ", .{@tagName(damage)});
                try s6t21.say(&lines.writer, ten);
                try lines.writer.writeAll(", MANIFEST now ");
                try s6t21.say(&lines.writer, s6t20.manifestGeneration(a, io, folder.out));
                try lines.writer.writeAll("\n");
                if ((ten catch 0) != 10 or (s6t20.manifestGeneration(a, io, folder.out) catch 0) != 10) failed += 1;
            },
            .missing => if ((rebuilt catch 0) != 10) {
                failed += 1;
            },
        }
    }
    std.debug.print("S6-T21 a damaged or missing MANIFEST over generation 9's sections:\n{s}", .{lines.written()});
    try std.testing.expectEqual(@as(usize, 0), failed);
}

// S6-T21 rework 1 (the Verdict's finding 1): every `format_version: 2` import
// (`filename-field-v1`) publishes through
// `lifecycle.publishSerializedWithFilenameKeeping`, a path no other S6-T21
// test takes (they import format 1). The check must hold there too.
test "S6-T21: a format_version 2 import at or below the highest generation is refused with StaleGeneration and changes nothing; above it publishes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    var folder = try s6t20.Folder.init(a);
    defer folder.deinit();
    var lines: std.Io.Writer.Allocating = .init(a);
    var failed: usize = 0;
    const payload = struct {
        fn at(arena: std.mem.Allocator, generation: u64) ![]const u8 {
            return std.fmt.allocPrint(arena,
                \\{{"format_version":2,"filename_policy_id":"filename-field-v1","generation":{d},"analyzer_id":"ascii-alnum-v1","embedding_model_id":"none","documents":[
                \\{{"id":"host","path":"notes/host.md","start_line":1,"end_line":1,"text":"a host import","vector":[],"required_labels":[]}}]}}
            , .{generation});
        }
    };
    inline for (.{ 5, 9 }) |number| {
        const before = try s6t20DirDigest(a, folder.out);
        const outcome: anyerror!u64 = if (s6t21.importer.importJson(folder.out, io, std.testing.allocator, try payload.at(a, number))) |report| report.generation else |err| err;
        const unchanged = std.mem.eql(u8, &before, &try s6t20DirDigest(a, folder.out));
        const manifest_after = try s6t20.manifestGeneration(a, io, folder.out);
        try lines.writer.print("  format 2 import {d} over 9: ", .{number});
        try s6t21.say(&lines.writer, outcome);
        try lines.writer.print(", MANIFEST {d}, directory {s}\n", .{ manifest_after, if (unchanged) "unchanged" else "changed" });
        const refused = if (outcome) |_| false else |err| err == error.StaleGeneration;
        if (!refused or manifest_after != 9 or !unchanged) failed += 1;
    }
    const ten: anyerror!u64 = if (s6t21.importer.importJson(folder.out, io, std.testing.allocator, try payload.at(a, 10))) |report| report.generation else |err| err;
    const manifest_after = try s6t20.manifestGeneration(a, io, folder.out);
    try lines.writer.writeAll("  format 2 import 10 over 9: ");
    try s6t21.say(&lines.writer, ten);
    try lines.writer.print(", MANIFEST {d}\n", .{manifest_after});
    if ((ten catch 0) != 10 or manifest_after != 10) failed += 1;
    // The file-name sections were published with it (the format-2 path).
    if (folder.out.statFile(io, "filenames-10.hybseg", .{})) |_| {} else |_| failed += 1;
    std.debug.print("S6-T21 format_version 2 imports over a folder at generation 9:\n{s}", .{lines.written()});
    try std.testing.expectEqual(@as(usize, 0), failed);
}

// S6-T21 rework 1 (the Verdict's finding 2): `init-demo` publishes generation 1
// through `lifecycle.publishSerialized`, whose check no other Zig test reaches.
// The sections are a real format-1 import's (generation 1, published into a
// fresh directory first), handed to `publishSerialized` as `init-demo` hands
// its own. `main.zig`'s `catch`es end the process and are not in any test
// build; `tests/test_cli_process.py` guards them.
test "S6-T21: publishSerialized (init-demo's publish) refuses generation 1 over a folder at 9 with StaleGeneration and changes nothing; into a fresh directory it publishes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    const lifecycle = @import("core").lifecycle;
    var folder = try s6t20.Folder.init(a);
    defer folder.deinit();

    try folder.tmp.dir.createDir(io, "source-gen", .default_dir);
    var source = try folder.tmp.dir.openDir(io, "source-gen", .{ .iterate = true });
    defer source.close(io);
    try std.testing.expectEqual(@as(u64, 1), try s6t21.importAt(a, io, source, 1));
    const manifest_encoded = try source.readFileAlloc(io, "MANIFEST", a, .unlimited);
    const documents = try source.readFileAlloc(io, "documents-1.hybseg", a, .unlimited);
    const lexical = try source.readFileAlloc(io, "lexical-1.hyblex", a, .unlimited);

    const before = try s6t20DirDigest(a, folder.out);
    const outcome = lifecycle.publishSerialized(folder.out, io, manifest_encoded, documents, lexical);
    if (outcome) |_| {
        std.debug.print("S6-T21 publishSerialized of generation 1 over 9: published\n", .{});
    } else |err| std.debug.print("S6-T21 publishSerialized of generation 1 over 9: {s}\n", .{@errorName(err)});
    try std.testing.expectError(error.StaleGeneration, outcome);
    try std.testing.expectEqual(@as(u64, 9), try s6t20.manifestGeneration(a, io, folder.out));
    try std.testing.expectEqualSlices(u8, &before, &try s6t20DirDigest(a, folder.out));

    try folder.tmp.dir.createDir(io, "fresh", .default_dir);
    var fresh = try folder.tmp.dir.openDir(io, "fresh", .{ .iterate = true });
    defer fresh.close(io);
    try lifecycle.publishSerialized(fresh, io, manifest_encoded, documents, lexical);
    try std.testing.expectEqual(@as(u64, 1), try s6t20.manifestGeneration(a, io, fresh));
}
