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
const manifest = @import("manifest.zig");
const postings = @import("postings.zig");
const publication = @import("publication.zig");
const scope = @import("scope.zig");
const service_module = @import("service.zig");
const snapshot_open = @import("snapshot_open.zig");
const filename_field = @import("filename_field.zig");

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
    printPeaksUnder("S4-T1 NFR-13", label, cap_bytes, peaks);
}

fn printPeaksUnder(prefix: []const u8, label: []const u8, cap: usize, peaks: Peaks) void {
    std.debug.print("{s} {s} under a {d} B cap, peak live bytes:", .{ prefix, label, cap });
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
    if (scaleEnabled()) try printOpenParts(out.dir, base_file_count, peaks.bytes[@intFromEnum(Operation.open)]);
    for (peaks.bytes) |value| try std.testing.expect(value > 0);
    try std.testing.expect(peaks.overall <= cap_bytes);
}

// --- S4-T8: NFR-13 headroom past 10k files (gated) --------------------------

/// The scale tests run only when this variable is `1`: they take longer than
/// the rest of the suite and measure, they do not gate.
const scale_variable = "SEARCH_SIMPLI_NFR13_SCALE";
/// The scale tests' measurement cap: wide enough that a peak past 64 MiB is
/// recorded instead of refused.
pub const scale_cap_bytes: usize = 256 * 1024 * 1024;
/// S4-T4's Verdict: the open's peak at 10,000 files with filename sections.
const filename_10k_open_peak: usize = 50_128_018;
/// The open's peak of the last scale test that ran in this process.
var last_scale_open: ?struct { file_count: usize, peak: usize } = null;

fn scaleEnabled() bool {
    const value = std.testing.environ.getAlloc(std.testing.allocator, scale_variable) catch return false;
    defer std.testing.allocator.free(value);
    return std.mem.eql(u8, value, "1");
}

fn nowNs() i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

/// The bytes of every file under `dir` (apparent sizes) and their count.
fn dirBytes(a: std.mem.Allocator, dir: std.Io.Dir) !struct { bytes: u64, files: usize } {
    var walker = try dir.walk(a);
    defer walker.deinit();
    var bytes: u64 = 0;
    var files: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        bytes += (try entry.dir.statFile(io, entry.basename, .{})).size;
        files += 1;
    }
    return .{ .bytes = bytes, .files = files };
}

/// One scale point: the generated corpus at `file_count` files, indexed
/// with the filename channel on, every operation measured under
/// `scale_cap_bytes`; the peaks, the sizes and the phase times printed.
fn scaleRun(file_count: usize, cap: usize) !Peaks {
    if (!scaleEnabled()) {
        std.debug.print("S4-T8 NFR-13 scale: skipped ({s}=1 runs it)\n", .{scale_variable});
        return error.SkipZigTest;
    }
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var corpus = std.testing.tmpDir(.{ .iterate = true });
    defer corpus.cleanup();
    var out = std.testing.tmpDir(.{ .iterate = true });
    defer out.cleanup();
    const start = nowNs();
    try generateCorpus(a, corpus.dir, file_count);
    const generated = nowNs();
    _ = try indexer.indexFolderIncremental(a, io, corpus.dir, out.dir, .v2, chunker.default_max_chars, chunker.default_overlap_lines, .{ .filename_index = true });
    const indexed = nowNs();
    const corpus_size = try dirBytes(a, corpus.dir);
    const index_size = try dirBytes(a, out.dir);
    var buffer: [16]u8 = undefined;
    const rare = try std.fmt.allocPrint(a, "{s}", .{word(&buffer, 4321)});
    const peaks = try measure(out.dir, cap, .{ .find_query = "the", .knowledge_query = try std.fmt.allocPrint(a, "the {s}", .{rare}), .filename_query = "doc the", .root_id = "r-legacy", .path = "group-33/doc-03355.md" });
    const measured = nowNs();
    try printOpenParts(out.dir, file_count, peaks.bytes[@intFromEnum(Operation.open)]);
    const label = try std.fmt.allocPrint(a, "scale {d} files, filename channel on,", .{file_count});
    printPeaksUnder("S4-T8 NFR-13", label, cap, peaks);
    std.debug.print("S4-T8 NFR-13 scale {d} files: corpus {d} files {d} B; index {d} files {d} B; generate {d} ms, index {d} ms, measure {d} ms\n", .{
        file_count,                                       corpus_size.files,                                  corpus_size.bytes,                                 index_size.files, index_size.bytes,
        @divTrunc(generated - start, std.time.ns_per_ms), @divTrunc(indexed - generated, std.time.ns_per_ms), @divTrunc(measured - indexed, std.time.ns_per_ms),
    });
    for (peaks.bytes) |value| try std.testing.expect(value > 0);
    const open_peak = peaks.bytes[@intFromEnum(Operation.open)];
    try std.testing.expect(open_peak > filename_10k_open_peak);
    if (last_scale_open) |last| {
        if (last.file_count < file_count) try std.testing.expect(open_peak > last.peak);
    }
    last_scale_open = .{ .file_count = file_count, .peak = open_peak };
    return peaks;
}

test "NFR-13 scale: 15,000 files" {
    _ = try scaleRun(15_000, scale_cap_bytes);
}

test "NFR-13 scale: 20,000 files" {
    _ = try scaleRun(20_000, scale_cap_bytes);
}

// --- S4-T8 ruling 3: the open's resident bytes, by table ---------------------

/// A pass-through allocator that keeps the live bytes requested of it, so a
/// table's own size is measured beside what the arena holds for it.
const Counting = struct {
    parent: std.mem.Allocator,
    live: usize = 0,

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const result = self.parent.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.live += len;
        return result;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        if (!self.parent.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.live = self.live - memory.len + new_len;
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const result = self.parent.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.live = self.live - memory.len + new_len;
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(memory, alignment, ret_addr);
        self.live -= memory.len;
    }
};

/// What `snapshot_open.openScoped` allocates, in its order: the manifest's
/// bytes; one slab for the document and lexical sections (read), the source
/// section (reserved, read at the first `read_span`/`outline`/`list_files`)
/// and the filename sections with their decoded tables (reserved, read at
/// the first filename query); the decoded documents, vectors, dictionary
/// terms, postings and document lengths; the decode itself; the parsed
/// meta; the folder (`scope.Loads`, `scope.Folder`, the per-document roots).
pub const OpenPart = enum { manifest, sections, documents, vectors, terms, postings, document_lengths, decode, meta, folder };

pub const OpenParts = struct {
    /// Bytes requested of the open's arena by each part.
    requested: [std.meta.fields(OpenPart).len]usize = @splat(0),
    /// Bytes the capped allocator held after the part minus before it (the
    /// arena's blocks, slack included).
    held: [std.meta.fields(OpenPart).len]usize = @splat(0),
    peak: usize = 0,
    /// The slab's parts (bytes): the document section, the lexical section,
    /// the source section's reservation, the filename reservation.
    documents_section: usize = 0,
    lexical_section: usize = 0,
    source_section: usize = 0,
    filename_reserved: usize = 0,
    document_count: usize = 0,
    term_count: usize = 0,
    posting_count: usize = 0,
    vector_dimensions: usize = 0,
};

/// `snapshot_open.openScoped`'s allocations replayed one loader at a time
/// over the same `Capped` and arena as `measure`, recording after each. Its
/// peak equals `measure`'s open peak (checked by the caller), so the parts
/// add up to the open the other tests measure.
fn attributeOpen(dir: std.Io.Dir) !OpenParts {
    var capped = Capped{ .parent = std.heap.page_allocator, .cap = scale_cap_bytes };
    var engine_arena = std.heap.ArenaAllocator.init(capped.allocator());
    defer engine_arena.deinit();
    var counting = Counting{ .parent = engine_arena.allocator() };
    const allocator = counting.allocator();
    var parts = OpenParts{};
    var last_requested: usize = 0;
    var last_held: usize = 0;
    const Mark = struct {
        fn at(p: *OpenParts, c: *const Counting, k: *const Capped, part: OpenPart, requested: *usize, held: *usize) void {
            p.requested[@intFromEnum(part)] = c.live - requested.*;
            p.held[@intFromEnum(part)] = k.live - held.*;
            requested.* = c.live;
            held.* = k.live;
        }
    };

    var manifest_file = try dir.openFile(io, publication.current_manifest_file, .{});
    const manifest_stat = try manifest_file.stat(io);
    manifest_file.close(io);
    const manifest_buffer = try allocator.alloc(u8, @intCast(manifest_stat.size));
    const manifest_encoded = try dir.readFile(io, publication.current_manifest_file, manifest_buffer);
    const metadata = try manifest.decode(manifest_encoded);
    Mark.at(&parts, &counting, &capped, .manifest, &last_requested, &last_held);

    const section_bytes = metadata.documents_bytes + metadata.lexical_bytes;
    const with_source = section_bytes + metadata.source_bytes;
    const reserved_bytes = filename_field.loadReservation(metadata);
    const sections = try allocator.alloc(u8, with_source + reserved_bytes);
    const snapshot = publication.LoadedSnapshot{
        .metadata = metadata,
        .manifest_encoded = manifest_encoded,
        .documents_encoded = try dir.readFile(io, metadata.documents_file, sections[0..metadata.documents_bytes]),
        .lexical_encoded = try dir.readFile(io, metadata.lexical_file, sections[metadata.documents_bytes..section_bytes]),
    };
    Mark.at(&parts, &counting, &capped, .sections, &last_requested, &last_held);
    parts.documents_section = metadata.documents_bytes;
    parts.lexical_section = metadata.lexical_bytes;
    parts.source_section = metadata.source_bytes;
    parts.filename_reserved = reserved_bytes;
    parts.document_count = metadata.document_count;
    parts.term_count = metadata.term_count;
    parts.posting_count = metadata.posting_count;
    parts.vector_dimensions = metadata.vector_dimensions;

    const documents = try allocator.alloc(hybrid.Document, metadata.document_count);
    Mark.at(&parts, &counting, &capped, .documents, &last_requested, &last_held);
    const vectors = try allocator.alloc(f32, metadata.document_count * metadata.vector_dimensions);
    Mark.at(&parts, &counting, &capped, .vectors, &last_requested, &last_held);
    const terms = try allocator.alloc(postings.TermEntry, metadata.term_count);
    Mark.at(&parts, &counting, &capped, .terms, &last_requested, &last_held);
    const posting_storage = try allocator.alloc(postings.Posting, metadata.posting_count);
    Mark.at(&parts, &counting, &capped, .postings, &last_requested, &last_held);
    const document_lengths = try allocator.alloc(u32, metadata.document_count);
    Mark.at(&parts, &counting, &capped, .document_lengths, &last_requested, &last_held);
    const opened = try engine_module.Engine.openWith(snapshot, documents, vectors, terms, posting_storage, document_lengths, .{ .validate_positions = false });
    Mark.at(&parts, &counting, &capped, .decode, &last_requested, &last_held);

    const meta: ?manifest.Meta = if (metadata.meta.len != 0) try manifest.parseMeta(allocator, metadata.meta) else null;
    Mark.at(&parts, &counting, &capped, .meta, &last_requested, &last_held);
    const loads = try allocator.create(scope.Loads);
    loads.* = .{ .io = io, .allocator = allocator, .documents = opened.documents, .index = opened.lexical_index };
    const folder = try allocator.create(scope.Folder);
    folder.* = try scope.Folder.build(allocator, meta, loads);
    Mark.at(&parts, &counting, &capped, .folder, &last_requested, &last_held);
    parts.peak = capped.peak;
    return parts;
}

/// Print the open's parts at `file_count` files and check they add up to
/// `open_peak` (`measure`'s open over the same index).
fn printOpenParts(dir: std.Io.Dir, file_count: usize, open_peak: usize) !void {
    const parts = try attributeOpen(dir);
    std.debug.print("S4-T8 NFR-13 open by table, {d} files (requested/held B):", .{file_count});
    var held_sum: usize = 0;
    for (std.enums.values(OpenPart), parts.requested, parts.held) |part, requested, held| {
        std.debug.print(" {s} {d}/{d}", .{ @tagName(part), requested, held });
        held_sum += held;
    }
    std.debug.print("; slab: documents section {d}, lexical section {d}, source reserved {d}, filename reserved {d}; documents {d}, terms {d}, postings {d}, vector dimensions {d}; sizes Document {d}, TermEntry {d}, Posting {d}; held {d}, peak {d}, measured open {d}\n", .{
        parts.documents_section,  parts.lexical_section,       parts.source_section,      parts.filename_reserved,
        parts.document_count,     parts.term_count,            parts.posting_count,       parts.vector_dimensions,
        @sizeOf(hybrid.Document), @sizeOf(postings.TermEntry), @sizeOf(postings.Posting), held_sum,
        parts.peak,               open_peak,
    });
    try std.testing.expectEqual(open_peak, parts.peak);
    try std.testing.expectEqual(open_peak, held_sum);
}
