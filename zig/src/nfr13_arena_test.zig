//! S4-T1 ruling 3: NFR-13 (CAP-19), the 64 MiB workspace cap. Every
//! allocation of the open and of `find`, `read_span`, `outline`,
//! `list_files` and `search_knowledge` goes through `Capped`, an allocator
//! that refuses any request that would take its live bytes past the cap and
//! records the peak. Over `fixtures/family-folder` (three roots through
//! `apply_changes`) all five operations run under 64 MiB; over a generated
//! 10,000-file corpus (`gen_timing_corpus.py`'s shape: 24,000-term syllable
//! vocabulary, one to three paragraphs a file) `find` and `search_knowledge`
//! do too, with the open in the same cap. The peaks print with the tests and
//! are recorded in `docs/tasks/S4-T1.md`.
const std = @import("std");
const apply = @import("apply.zig");
const chunker = @import("chunker.zig");
const engine_module = @import("engine.zig");
const hybrid = @import("hybrid.zig");
const indexer = @import("indexer.zig");
const service_module = @import("service.zig");
const snapshot_open = @import("snapshot_open.zig");

const io = std.testing.io;
pub const cap_bytes: usize = 64 * 1024 * 1024;

/// A capped allocator: fails (returns null) past `cap` live bytes instead
/// of growing, and keeps the peak of live bytes. Single-threaded use.
pub const Capped = struct {
    parent: std.mem.Allocator,
    cap: usize,
    live: usize = 0,
    peak: usize = 0,
    refused: usize = 0,

    pub fn allocator(self: *Capped) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    /// Restart the peak at the current live bytes (before one operation).
    pub fn markPeak(self: *Capped) usize {
        self.peak = self.live;
        return self.live;
    }

    fn admit(self: *Capped, grow: usize) bool {
        if (self.live + grow > self.cap) {
            self.refused += 1;
            return false;
        }
        return true;
    }

    fn account(self: *Capped, old_len: usize, new_len: usize) void {
        self.live = self.live - old_len + new_len;
        self.peak = @max(self.peak, self.live);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Capped = @ptrCast(@alignCast(ctx));
        if (!self.admit(len)) return null;
        const result = self.parent.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.account(0, len);
        return result;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Capped = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and !self.admit(new_len - memory.len)) return false;
        if (!self.parent.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.account(memory.len, new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Capped = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and !self.admit(new_len - memory.len)) return null;
        const result = self.parent.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.account(memory.len, new_len);
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Capped = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(memory, alignment, ret_addr);
        self.account(memory.len, 0);
    }
};

pub const Operation = enum { open, find, read_span, outline, list_files, search_knowledge, filename, both };

pub const Target = struct {
    find_query: []const u8,
    knowledge_query: []const u8,
    filename_query: []const u8 = "doc",
    /// `read_span`, `outline` and `list_files` (null: not run).
    root_id: ?[]const u8 = null,
    path: []const u8 = "",
};

pub const Peaks = struct {
    /// Peak live bytes during each operation (the open's include the engine
    /// it keeps; each later operation's are the engine plus that operation).
    bytes: [std.meta.fields(Operation).len]usize = @splat(0),
    /// The highest of them.
    overall: usize = 0,
};

/// Open the index in `dir` and run each operation of `target`, all under
/// one `cap`-byte `Capped` allocator; each operation gets its own arena over
/// it (released after), as a host's per-call workspace would be.
pub fn measure(dir: std.Io.Dir, cap: usize, target: Target) !Peaks {
    var capped = Capped{ .parent = std.heap.page_allocator, .cap = cap };
    var peaks = Peaks{};
    var engine_arena = std.heap.ArenaAllocator.init(capped.allocator());
    defer engine_arena.deinit();
    _ = capped.markPeak();
    const opened = try snapshot_open.openScoped(engine_arena.allocator(), io, dir);
    defer opened.folder.close();
    peaks.bytes[@intFromEnum(Operation.open)] = capped.peak;
    const scoped = service_module.ScopedService{ .service = .{ .engine = opened.engine, .folder = opened.folder } };

    inline for (comptime std.enums.values(Operation)[1..]) |operation| {
        const runs = if (operation == .filename or operation == .both) opened.engine.filename_index_enabled else target.root_id != null or operation == .find or operation == .search_knowledge;
        if (runs) {
            var op_arena = std.heap.ArenaAllocator.init(capped.allocator());
            defer op_arena.deinit();
            const a = op_arena.allocator();
            _ = capped.markPeak();
            switch (operation) {
                .find => {
                    const answer = (try scoped.find(a, .{ .query = target.find_query }, .{})).ok;
                    try std.testing.expect(answer.hits.len > 0);
                },
                .read_span => {
                    const span = (try scoped.readSpan(a, .{}, target.root_id.?, target.path, 1, 400, 0)).ok;
                    try std.testing.expect(span.text.len > 0);
                },
                .outline => _ = (try scoped.outline(a, .{}, target.root_id.?, target.path)).ok,
                .list_files => try std.testing.expect((try scoped.listFiles(a, .{}, target.root_id.?, null)).len > 0),
                .search_knowledge => {
                    const evidence = try scoped.searchKnowledge(a, target.knowledge_query, &.{}, .{ .retrieval_mode = .lexical }, .{}, try a.alloc(hybrid.Result, 10), try a.alloc(engine_module.Evidence, 10), null);
                    try std.testing.expect(evidence.len > 0);
                },
                .filename, .both => {
                    const hits = try opened.engine.queryFields(a, target.filename_query, if (operation == .filename) .filename else .both, .{ .retrieval_mode = .lexical });
                    try std.testing.expect(hits.len > 0);
                },
                .open => unreachable,
            }
            peaks.bytes[@intFromEnum(operation)] = capped.peak;
        }
    }
    for (peaks.bytes) |value| peaks.overall = @max(peaks.overall, value);
    try std.testing.expectEqual(@as(usize, 0), capped.refused);
    return peaks;
}

fn printPeaks(label: []const u8, peaks: Peaks) void {
    std.debug.print("S4-T1 NFR-13 {s} under a {d} B cap, peak live bytes:", .{ label, cap_bytes });
    for (std.enums.values(Operation), peaks.bytes) |operation, value| {
        if (value != 0) std.debug.print(" {s} {d}", .{ @tagName(operation), value });
    }
    std.debug.print("\n", .{});
}

const pack = "../fixtures/family-folder";

/// `fixtures/family-folder`'s three roots through one `apply_changes`.
fn indexFamilyFolder(a: std.mem.Allocator, out: std.Io.Dir) !void {
    var request: std.Io.Writer.Allocating = .init(a);
    const w = &request.writer;
    try w.writeAll("{\"roots\":[{\"root_id\":\"home\",\"kind\":\"host\"},{\"root_id\":\"laptop\",\"kind\":\"host\"},{\"root_id\":\"school\",\"kind\":\"host\"}],\"changes\":[");
    var first = true;
    for ([_][]const u8{ "home", "laptop", "school" }) |root_id| {
        var from = try std.Io.Dir.cwd().openDir(io, try std.fmt.allocPrint(a, "{s}/{s}", .{ pack, root_id }), .{ .iterate = true });
        defer from.close(io);
        var walker = try from.walk(a);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const bytes = try from.readFileAlloc(io, entry.path, a, .unlimited);
            const encoded = try a.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
            _ = std.base64.standard.Encoder.encode(encoded, bytes);
            if (!first) try w.writeAll(",");
            first = false;
            try w.print("{{\"op\":\"add\",\"root_id\":\"{s}\",\"path\":\"{s}\",\"content_base64\":\"{s}\"}}", .{ root_id, entry.path, encoded });
        }
    }
    try w.writeAll("]}");
    switch (try apply.applyChanges(a, io, out, request.written(), .{})) {
        .ok => {},
        .failed => return error.TestUnexpectedResult,
    }
}

test "S4-T1 NFR-13: find, read_span, outline, list_files and search_knowledge over the family folder inside 64 MiB" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try indexFamilyFolder(arena_state.allocator(), tmp.dir);
    const peaks = try measure(tmp.dir, cap_bytes, .{ .find_query = "pond", .knowledge_query = "hedgehogs in the pond", .root_id = "home", .path = "garden.md" });
    printPeaks("family-folder", peaks);
    try std.testing.expect(peaks.overall <= cap_bytes);
    // This body-only fixture does not enable the optional filename channel.
    for (peaks.bytes[0..@intFromEnum(Operation.filename)]) |value| try std.testing.expect(value > 0);
}

test "S4-T1 NFR-13: the cap bites (a 256 KiB cap refuses the same open)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try indexFamilyFolder(arena_state.allocator(), tmp.dir);
    try std.testing.expectError(error.OutOfMemory, measure(tmp.dir, 256 * 1024, .{ .find_query = "pond", .knowledge_query = "pond" }));
}

// --- the generated 10,000-file corpus ---------------------------------------

const consonants = [_][]const u8{ "b", "c", "d", "f", "g", "h", "j", "k", "l", "m", "n", "p", "r", "s", "t", "v", "w", "z", "sh", "ch", "th", "wh" };
const vowels = [_][]const u8{ "a", "e", "i", "o", "u" };
const common_words = [_][]const u8{ "the", "a", "an", "of", "and", "to", "in", "for", "with", "by", "is", "are", "that", "this", "it", "as", "from", "on", "be", "was", "were", "has", "have", "will", "can", "not" };
const topics = [_][]const u8{ "Hybrid Retrieval", "Hash Tables", "Garbage Collection", "Type Systems", "Distributed Consensus", "Operating System Schedulers", "Compilers", "Database Indexing" };
/// The corpus of the S4-T1 and S4-T2 tests (their peaks are recorded at it).
const base_file_count: usize = 10_000;
const vocabulary_size: usize = 24_000;

fn word(buffer: []u8, index: usize) []const u8 {
    const base = consonants.len * vowels.len;
    var length: usize = 0;
    for ([_]usize{ (index / (base * base)) % base, (index / base) % base, index % base }) |syllable| {
        for ([_][]const u8{ consonants[syllable / vowels.len], vowels[syllable % vowels.len] }) |part| {
            @memcpy(buffer[length..][0..part.len], part);
            length += part.len;
        }
    }
    return buffer[0..length];
}

/// The shape of `scripts/gen_timing_corpus.py` (not its bytes): folders of
/// 100 Markdown files (`group-NN/doc-NNNNN.md`; 10,000 files are 100
/// folders), a heading and one to three paragraphs of three to six
/// sentences, 35 % common words, and a closing line that uses each
/// vocabulary word at least once across the corpus. S4-T8: `file_count` is
/// a parameter; at 10,000 the bytes are those of S4-T1's generator.
fn generateCorpus(a: std.mem.Allocator, dir: std.Io.Dir, file_count: usize) !void {
    var prng = std.Random.DefaultPrng.init(20260917);
    const random = prng.random();
    var text: std.Io.Writer.Allocating = .init(a);
    var buffer: [16]u8 = undefined;
    for (0..file_count) |index| {
        text.clearRetainingCapacity();
        const w = &text.writer;
        const paragraphs = random.intRangeAtMost(usize, 1, 3);
        for (0..paragraphs) |_| {
            try w.print("# {s}\n\n", .{topics[index % topics.len]});
            for (0..random.intRangeAtMost(usize, 3, 6)) |_| {
                for (0..random.intRangeAtMost(usize, 8, 16)) |k| {
                    if (k != 0) try w.writeAll(" ");
                    if (random.float(f32) < 0.35) try w.writeAll(common_words[random.uintLessThan(usize, common_words.len)]) else try w.writeAll(word(&buffer, random.uintLessThan(usize, vocabulary_size)));
                }
                try w.writeAll(". ");
            }
            try w.writeAll("\n\n");
        }
        var quota = index;
        while (quota < vocabulary_size) : (quota += file_count) try w.print("{s} ", .{word(&buffer, quota)});
        try w.writeAll(".\n");
        const path = try std.fmt.allocPrint(a, "group-{d:0>2}/doc-{d:0>5}.md", .{ index / 100, index });
        if (index % 100 == 0) try dir.createDirPath(io, path[0..std.mem.indexOfScalar(u8, path, '/').?]);
        try dir.writeFile(io, .{ .sub_path = path, .data = text.written() });
    }
}

test "S4-T1 NFR-13: find and search_knowledge over a 10,000-file index inside 64 MiB, the open included" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var corpus = std.testing.tmpDir(.{ .iterate = true });
    defer corpus.cleanup();
    var out = std.testing.tmpDir(.{ .iterate = true });
    defer out.cleanup();
    try generateCorpus(a, corpus.dir, base_file_count);
    _ = try indexer.indexFolderIncremental(a, io, corpus.dir, out.dir, .v2, chunker.default_max_chars, chunker.default_overlap_lines, .{});
    var buffer: [16]u8 = undefined;
    const rare = try std.fmt.allocPrint(a, "{s}", .{word(&buffer, 4321)});
    // "the" is in most chunks: the widest postings list and the most hits.
    const peaks = try measure(out.dir, cap_bytes, .{ .find_query = "the", .knowledge_query = try std.fmt.allocPrint(a, "the {s}", .{rare}), .root_id = "r-legacy", .path = "group-33/doc-03355.md" });
    printPeaks("10k generated", peaks);
    try std.testing.expect(peaks.overall <= cap_bytes);
}

test "filename and S4 lazy tables share the unchanged 64 MiB cap at 10k files" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var corpus = std.testing.tmpDir(.{ .iterate = true });
    defer corpus.cleanup();
    var out = std.testing.tmpDir(.{ .iterate = true });
    defer out.cleanup();
    try generateCorpus(a, corpus.dir, base_file_count);
    _ = try indexer.indexFolderIncremental(a, io, corpus.dir, out.dir, .v2, chunker.default_max_chars, chunker.default_overlap_lines, .{ .filename_index = true });
    const peaks = try measure(out.dir, cap_bytes, .{ .find_query = "the", .knowledge_query = "the", .filename_query = "doc the", .root_id = "r-legacy", .path = "group-33/doc-03355.md" });
    printPeaks("10k filename and lazy tables", peaks);
    for (peaks.bytes) |value| try std.testing.expect(value > 0);
    try std.testing.expect(peaks.overall <= cap_bytes);
}
