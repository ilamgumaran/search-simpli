//! S2-T11: a query must never hang. Invalid UTF-8 in `query_text` is rejected at
//! the door (`ss_query`, the CLI, `serve`), and the analyzer itself terminates
//! on any byte string. These tests run every call on a worker thread with a
//! watchdog: if no call completes for `stall_seconds`, the test fails with
//! `error.QueryHung` (not the suite timeout). In a Debug build the unchecked
//! walk over a bad byte is a safety panic; in `-Doptimize=ReleaseSmall` (the
//! shipped build) it spins, which is what the watchdog catches.
const std = @import("std");
const abi = @import("abi.zig");
const analyzer_v2 = @import("analyzer_v2.zig");
const engine_module = @import("engine.zig");
const hybrid = @import("hybrid.zig");
const nfc = @import("nfc.zig");
const snapshot_open = @import("snapshot_open.zig");

const stall_seconds = 10;
const fuzz_cases = 100_000;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Shared between the job (worker thread) and the watchdog (the test thread).
const Progress = struct {
    ticks: std.atomic.Value(u64) = .init(0),
    done: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,
};

fn worker(progress: *Progress, comptime job: fn (*Progress) anyerror!void) void {
    job(progress) catch |err| {
        progress.failure = err;
    };
    progress.done.store(true, .release);
}

/// Run `job` on its own thread; fail if its tick counter stops advancing for
/// `stall_seconds`. A hung worker is abandoned (the test process ends anyway).
fn runWithWatchdog(comptime job: fn (*Progress) anyerror!void) !void {
    var progress = Progress{};
    const thread = try std.Thread.spawn(.{}, worker, .{ &progress, job });
    var last_ticks: u64 = 0;
    var last_change = std.Io.Clock.awake.now(io()).nanoseconds;
    while (!progress.done.load(.acquire)) {
        const now = std.Io.Clock.awake.now(io()).nanoseconds;
        const ticks = progress.ticks.load(.monotonic);
        if (ticks != last_ticks) {
            last_ticks = ticks;
            last_change = now;
        } else if (now - last_change > stall_seconds * std.time.ns_per_s) {
            thread.detach();
            std.debug.print("query_utf8_test: no progress for {d}s after {d} calls: HANG\n", .{ stall_seconds, ticks });
            return error.QueryHung;
        }
        std.Thread.yield() catch {};
    }
    thread.join();
    if (progress.failure) |err| return err;
}

// --- generators ---------------------------------------------------------------

const samples = [_][]const u8{
    "hybrid retrieval ranks documents",
    "caf\xc3\xa9 au lait",
    "e\xcc\x81cole \xe2\x80\x94 na\xc3\xafve",
    "\xe0\xae\xa4\xe0\xae\xae\xe0\xae\xbf\xe0\xae\xb4\xe0\xaf\x8d \xe0\xae\xae\xe0\xaf\x8a\xe0\xae\xb4\xe0\xae\xbf",
    "\xf0\x9f\x98\x80 emoji 123",
    "A\xcc\x8a\xe1\xba\xa1\xe1\xba\xa1 x",
    "",
};

/// 0-256 bytes: half are random bytes of any value, half are valid UTF-8
/// samples with one to three byte mutations. No NUL (`ss_query` takes a C
/// string; a NUL ends it).
fn randomQuery(rng: std.Random, storage: *[320]u8) []u8 {
    var len: usize = 0;
    if (rng.boolean()) {
        len = rng.uintAtMost(usize, 256);
        for (storage[0..len]) |*byte| byte.* = rng.int(u8);
    } else {
        const sample = samples[rng.uintLessThan(usize, samples.len)];
        // Repeat the sample up to a random length.
        const target = rng.uintAtMost(usize, 256);
        while (sample.len > 0 and len < target) {
            const take = @min(sample.len, target - len);
            @memcpy(storage[len..][0..take], sample[0..take]);
            len += take;
        }
        for (0..rng.uintAtMost(usize, 3)) |_| {
            if (len == 0) break;
            const at = rng.uintLessThan(usize, len);
            switch (rng.uintLessThan(u8, 3)) {
                0 => storage[at] = rng.int(u8),
                1 => {
                    std.mem.copyForwards(u8, storage[at .. len - 1], storage[at + 1 .. len]);
                    len -= 1;
                },
                else => if (len < 256) {
                    std.mem.copyBackwards(u8, storage[at + 1 .. len + 1], storage[at..len]);
                    storage[at] = rng.int(u8);
                    len += 1;
                },
            }
        }
    }
    for (storage[0..len]) |*byte| {
        if (byte.* == 0) byte.* = 1;
    }
    return storage[0..len];
}

// --- snapshots ----------------------------------------------------------------

const doc_a = "{\"id\":\"a\",\"path\":\"a.md\",\"start_line\":1,\"end_line\":1,\"text\":\"hybrid retrieval ranks documents\",\"vector\":[],\"required_labels\":[]}";
const doc_b = "{\"id\":\"b\",\"path\":\"b.md\",\"start_line\":1,\"end_line\":1,\"text\":\"caf\\u00e9 au lait \\u0ba4\\u0bae\\u0bbf\\u0bb4\\u0bcd\",\"vector\":[],\"required_labels\":[]}";

fn makeSnapshot(tmp: *std.testing.TmpDir, name: []const u8, analyzer_id: []const u8) ![:0]u8 {
    const path = try std.fmt.allocPrintSentinel(std.testing.allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name }, 0);
    errdefer std.testing.allocator.free(path);
    const payload = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"format_version\":1,\"generation\":1,\"analyzer_id\":\"{s}\",\"embedding_model_id\":\"none\",\"documents\":[{s},{s}]}}",
        .{ analyzer_id, doc_a, doc_b },
    );
    defer std.testing.allocator.free(payload);
    if (abi.ss_import_json(path, payload.ptr, payload.len) < 1) return error.ImportFailed;
    return path;
}

var snapshot_v1: [:0]u8 = undefined;
var snapshot_v2: [:0]u8 = undefined;

// --- the jobs -----------------------------------------------------------------

fn expectDoorRejects(handle: *abi.Handle, text: [:0]const u8, options: ?[*:0]const u8) !void {
    const out = abi.ss_query(handle, text.ptr, null, 0, 3, options);
    if (out) |ptr| {
        abi.ss_free(ptr);
        return error.InvalidQueryAccepted;
    }
    const message = std.mem.span(abi.ss_last_error());
    if (std.mem.indexOf(u8, message, "query_text is not valid UTF-8") == null) return error.WrongMessage;
    if (std.mem.indexOf(u8, message, "SS_ERR_INVALID_ARGUMENT") == null) return error.WrongMessage;
}

fn fuzzJob(progress: *Progress) anyerror!void {
    var prng = std.Random.DefaultPrng.init(0x5232_5431_31);
    const rng = prng.random();
    var storage: [320]u8 = undefined;
    var valid_count: usize = 0;
    var invalid_count: usize = 0;
    const started = std.Io.Clock.awake.now(io()).nanoseconds;
    for ([_][:0]u8{ snapshot_v2, snapshot_v1 }) |path| {
        const handle = abi.ss_open(path) orelse return error.OpenFailed;
        defer abi.ss_close(handle);
        // The same engine, opened for a leak-checked call that skips the C
        // allocator: `Engine.queryTraced` is what `ss_query` ends in.
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        var dir = try std.Io.Dir.cwd().openDir(io(), path, .{});
        defer dir.close(io());
        const engine = try snapshot_open.open(arena_state.allocator(), io(), dir);
        var results: [3]hybrid.Result = undefined;

        for (0..fuzz_cases) |_| {
            const query = randomQuery(rng, &storage);
            storage[query.len] = 0;
            const text: [:0]const u8 = storage[0..query.len :0];
            const valid = std.unicode.utf8ValidateSlice(query);
            const mode: [*:0]const u8 = switch (rng.uintLessThan(u8, 3)) {
                0 => "{\"retrieval_mode\":\"lexical\"}",
                1 => "{\"retrieval_mode\":\"hybrid\",\"profile\":true}",
                else => "{\"retrieval_mode\":\"vector\"}",
            };
            if (valid) {
                valid_count += 1;
                if (abi.ss_query(handle, text.ptr, null, 0, 3, mode)) |ptr| abi.ss_free(ptr);
                var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
                defer scratch.deinit();
                _ = engine.queryTokenized(scratch.allocator(), query, &.{}, &results, .{ .top_k = 3, .candidate_k = 10, .retrieval_mode = .lexical }) catch {};
            } else {
                invalid_count += 1;
                try expectDoorRejects(handle, text, mode);
                // And past the door: the engine refuses it by itself.
                var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
                defer scratch.deinit();
                try std.testing.expectError(error.InvalidQueryText, engine.queryTokenized(scratch.allocator(), query, &.{}, &results, .{ .top_k = 3, .candidate_k = 10, .retrieval_mode = .lexical }));
            }
            _ = progress.ticks.fetchAdd(1, .monotonic);
        }
    }
    const elapsed_ms = @divTrunc(std.Io.Clock.awake.now(io()).nanoseconds - started, std.time.ns_per_ms);
    std.debug.print("S2-T11 fuzz: {d} cases per snapshot x 2 snapshots: {d} valid, {d} invalid (all rejected), {d} ms\n", .{ fuzz_cases, valid_count, invalid_count, elapsed_ms });
}

fn analyzerJob(progress: *Progress) anyerror!void {
    // Every single byte, as a string of one byte and as the byte after "a".
    for (0..256) |value| {
        const byte: u8 = @intCast(value);
        try exerciseAnalyzer(&.{byte});
        try exerciseAnalyzer(&.{ 'a', byte });
        try exerciseAnalyzer(&.{ byte, 'a' });
        _ = progress.ticks.fetchAdd(1, .monotonic);
    }
    // 2,000 random byte strings of length 1-64 (and 2,000 mutated-valid ones).
    var prng = std.Random.DefaultPrng.init(0x5232_5431_32);
    const rng = prng.random();
    var buffer: [64]u8 = undefined;
    for (0..2000) |_| {
        const len = 1 + rng.uintLessThan(usize, 64);
        rng.bytes(buffer[0..len]);
        try exerciseAnalyzer(buffer[0..len]);
        const sample = samples[rng.uintLessThan(usize, samples.len - 1)];
        var mutated: [64]u8 = undefined;
        const n = @min(sample.len, 64);
        @memcpy(mutated[0..n], sample[0..n]);
        mutated[rng.uintLessThan(usize, n)] = rng.int(u8);
        try exerciseAnalyzer(mutated[0..n]);
        _ = progress.ticks.fetchAdd(1, .monotonic);
    }
}

/// `nfc.normalize` and `analyzer_v2.tokenize` return (a result or
/// `InvalidUtf8`); invalid input is an error, valid input succeeds.
fn exerciseAnalyzer(bytes: []const u8) !void {
    const valid = std.unicode.utf8ValidateSlice(bytes);
    if (nfc.normalize(std.testing.allocator, bytes)) |normalized| {
        std.testing.allocator.free(normalized);
        try std.testing.expect(valid);
    } else |err| {
        try std.testing.expectEqual(error.InvalidUtf8, err);
        try std.testing.expect(!valid);
    }
    if (analyzer_v2.tokenize(std.testing.allocator, bytes)) |tokens| {
        for (tokens) |token| std.testing.allocator.free(token);
        std.testing.allocator.free(tokens);
        try std.testing.expect(valid);
    } else |err| {
        try std.testing.expectEqual(error.InvalidUtf8, err);
        try std.testing.expect(!valid);
    }
}

fn echoJob(progress: *Progress) anyerror!void {
    // The v1 byte-array echo (S2-T4 finding N3): an invalid query is an error
    // on a v1 snapshot, never a report whose `query` is a JSON array.
    const handle = abi.ss_open(snapshot_v1) orelse return error.OpenFailed;
    defer abi.ss_close(handle);
    for ([_][:0]const u8{ "caf\xff", "\x80", "hybrid \xfe\xff", "\xc3", "\xed\xa0\x80", "\xf8\x88\x80\x80\x80" }) |text| {
        try expectDoorRejects(handle, text, "{\"retrieval_mode\":\"lexical\"}");
        _ = progress.ticks.fetchAdd(1, .monotonic);
    }
    // A valid query still answers, with `query` a string.
    const ok = abi.ss_query(handle, "caf\xc3\xa9", null, 0, 3, "{\"retrieval_mode\":\"lexical\"}") orelse return error.QueryFailed;
    defer abi.ss_free(ok);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(ok), "\"query\":\"caf\xc3\xa9\"") != null);
}

fn withSnapshots(comptime job: fn (*Progress) anyerror!void) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    snapshot_v1 = try makeSnapshot(&tmp, "v1", "ascii-alnum-v1");
    defer std.testing.allocator.free(snapshot_v1);
    snapshot_v2 = try makeSnapshot(&tmp, "v2", "analyzer-v2");
    defer std.testing.allocator.free(snapshot_v2);
    try runWithWatchdog(job);
}

test "every byte 0x00-0xFF and 2,000 random byte strings terminate in nfc and the v2 tokenizer" {
    try runWithWatchdog(analyzerJob);
}

test "ss_query rejects invalid UTF-8 on analyzer-v2 and ascii-alnum-v1 without hanging (hang test)" {
    try withSnapshots(echoJob);
}

test "fuzz: 100,000 random byte strings through ss_query on a v2 and a v1 snapshot" {
    try withSnapshots(fuzzJob);
}
