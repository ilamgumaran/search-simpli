//! `scan` in the core (S6-T24, CAP-25 FR-37 to FR-41, `docs/decisions/0006-pattern-search.md` sections 6 to 8):
//! every line of the files in scope that holds a literal or matches a pattern (`pattern.zig`), in path and line
//! order, paged by a cursor, inside a time budget.
//!
//! - **One loop, two sources** (`Source`): the files in scan order and a function that reads one. An index
//!   (`indexSource`, over the source section; the operations layer decides which files the caller may see) and
//!   a folder with nothing prepared (`scanFolder`: `indexer.walkFolder` and `apply.readWalkedFile`, the same
//!   walk and read rules as `searchd index`, root `r-legacy`). The loop never knows which one it reads.
//! - **A hit is a line**, numbered as `read_span` numbers it (`source.lineStarts`'s rule: a leading BOM is not
//!   part of line 1), without its terminator, cut to 512 bytes at a code-point boundary (or shorter, where regex
//!   mode stopped looking for matches: `pattern.Matcher.matchLine`); `match_offsets` are code-point pairs into
//!   that text, and `before`/`after` the context lines.
//! - **Paging**: `"<generation>:<request>:<file>:<line>:<listed>"` over an index and
//!   `"f<walk>:<request>:<file>:<line>:<listed>"` over a folder, where `<request>` is an XXH3-64 of the request
//!   without its cursor, page size and budget (`requestHash`), `<walk>` one of the walk's sorted paths, `<file>`
//!   the file's ordinal in scan order, `<line>` the next line to search and `<listed>` the hit lines already
//!   returned from that file. Resuming reads no earlier file. A file's counts go on the page where its scan ends.
//! - **Budget** (rework 1, rulings 1, 3 and 5): the clock starts before the pattern is parsed. Every loop charges
//!   its work to `pattern.Budget.charge` (a byte read for line breaks, a byte searched for a literal, a step of
//!   the VM), which reads the clock once per 65,536 units, and the clock is also read between files. A page that
//!   runs out ends with `stopped: "time"` and a cursor strictly after the request's. The page's first line gets
//!   at least `grace_ms` (10 ms) from when it starts, even when the budget went on compiling or reading the file;
//!   a page that still completes no position past the request's cursor is refused with `capacity` instead
//!   (ruling O-7), naming the cause, so a caller can never be handed the cursor it sent.
//!
//! Memory (rework 1, ruling 4): the answer comes from `allocator` (an arena in every caller); one file's bytes
//! are held at a time, with the spans of at most `2 x context_lines + 1` lines around the one being searched and
//! nothing per line of the file, in an arena of their own that is reset before the next file (NFR-13).
const std = @import("std");
const apply = @import("apply.zig");
const find = @import("find.zig");
const indexer = @import("indexer.zig");
const pattern = @import("pattern.zig");
const scope = @import("scope.zig");
const source = @import("source.zig");

pub const default_page_size: u64 = 20;
pub const max_page_size: u64 = 100;
pub const default_max_hits_per_file: u64 = 50;
pub const max_max_hits_per_file: u64 = 1000;
pub const default_time_budget_ms: u64 = 2000;
pub const max_time_budget_ms: u64 = 30_000;
pub const max_context_lines: u64 = 20;
pub const max_glob_bytes: usize = 255;
/// A hit's and a context line's `text`: at most this many bytes of the line.
pub const max_text_bytes: usize = 512;
/// The least time a page's first line gets, from when it starts, whatever is left of the budget.
pub const grace_ms: u64 = 10;

pub const stale_cursor_message = "stale cursor";
pub const foreign_cursor_message = "cursor does not belong to this request";
pub const malformed_cursor_message = "malformed cursor";
pub const empty_match_message = "the pattern can match the empty string, so a line can match without any match_offsets";

pub const Request = struct {
    pattern: []const u8,
    mode: pattern.Mode = .literal,
    case: pattern.Case = .smart,
    whole_word: bool = false,
    path_prefix: ?[]const u8 = null,
    name_glob: ?[]const u8 = null,
    context_lines: u64 = 0,
    max_hits_per_file: u64 = default_max_hits_per_file,
    page_size: u64 = default_page_size,
    cursor: ?[]const u8 = null,
    time_budget_ms: u64 = default_time_budget_ms,
    /// The `roots` the request named, echoed as given (null: none named).
    named_roots: ?[]const []const u8 = null,
    /// The effective scope, which binds the cursor: the roots the caller may see (null: every root) and the labels.
    scope_roots: ?[]const []const u8 = null,
    scope_labels: []const []const u8 = &.{},
};

/// One file in scan order. `key` is the source's own (an entry of the index's table, a walk path's ordinal).
pub const File = struct { root_id: []const u8, path: []const u8, key: usize };

pub const Read = union(enum) { ok: []const u8, too_large, unreadable, binary };

pub const Kind = enum { index, folder };

pub const NotScanned = struct {
    too_large: usize = 0,
    unreadable: usize = 0,
    budget_exhausted: usize = 0,
    not_retained: usize = 0,

    pub fn any(n: NotScanned) bool {
        return n.too_large + n.unreadable + n.budget_exhausted + n.not_retained > 0;
    }
};

pub const Source = struct {
    kind: Kind,
    /// Index: the generation. Folder: the XXH3-64 of the walk's sorted paths.
    generation: u64 = 0,
    walk: u64 = 0,
    /// Every file the caller may see, ordered by `root_id` then path (bytes); `run` keeps those in the request's
    /// `path_prefix` and `name_glob`.
    files: []const File,
    context: *anyopaque,
    read: *const fn (context: *anyopaque, allocator: std.mem.Allocator, file: File) error{OutOfMemory}!Read,
    /// Index: scope-wide, the same on every page. Folder: zero (counted as files are read).
    pending_files: usize = 0,
    not_scanned: NotScanned = .{},
    /// Folder: the walk's counts of what it does not read (FR-35).
    not_read: ?indexer.NotRead = null,
};

pub const ContextLine = struct { line: u32, text: []const u8, text_truncated: bool };

pub const Hit = struct {
    root_id: []const u8,
    path: []const u8,
    line: u32,
    text: []const u8,
    text_truncated: bool,
    match_offsets: []const [2]u32,
    before: []const ContextLine,
    after: []const ContextLine,
};

pub const Stopped = enum { none, time };

pub const Answer = struct {
    request: Request,
    kind: Kind,
    generation: ?u64,
    case_applied: pattern.Applied,
    matches_empty: bool,
    hits: []const Hit,
    files_matched: usize = 0,
    files_scanned: usize = 0,
    files_capped: usize = 0,
    bytes_scanned: u64 = 0,
    pending_files: usize,
    not_scanned: NotScanned,
    not_read: ?indexer.NotRead,
    truncated: bool,
    stopped: Stopped,
    next_cursor: ?[]const u8,
};

pub const Outcome = union(enum) {
    ok: Answer,
    failed: source.Failure,
};

fn fail(allocator: std.mem.Allocator, code: source.Code, comptime format: []const u8, args: anytype) error{OutOfMemory}!Outcome {
    return .{ .failed = .{ .code = code, .message = try std.fmt.allocPrint(allocator, format, args) } };
}

// ------------------------------------------------------------------- scope ---

/// `*` any run of code points, `?` one code point, every other code point itself.
pub fn globMatches(glob: []const u8, name: []const u8) bool {
    var g: usize = 0;
    var n: usize = 0;
    var star_g: ?usize = null;
    var star_n: usize = 0;
    while (n < name.len) {
        if (g < glob.len and glob[g] == '*') {
            star_g = g;
            g += 1;
            star_n = n;
            continue;
        }
        if (g < glob.len) {
            const gl = cpLen(glob, g);
            const nl = cpLen(name, n);
            if (glob[g] == '?' or (gl == nl and std.mem.eql(u8, glob[g .. g + gl], name[n .. n + nl]))) {
                g += gl;
                n += nl;
                continue;
            }
        }
        const sg = star_g orelse return false;
        star_n += cpLen(name, star_n);
        n = star_n;
        g = sg + 1;
    }
    while (g < glob.len and glob[g] == '*') g += 1;
    return g == glob.len;
}

fn cpLen(bytes: []const u8, at: usize) usize {
    const len = std.unicode.utf8ByteSequenceLength(bytes[at]) catch return 1;
    return @min(len, bytes.len - at);
}

/// Whether a root-relative `path` is in the request's `path_prefix` and `name_glob`.
pub fn inScope(request: Request, path: []const u8) bool {
    if (request.path_prefix) |prefix| if (!std.mem.startsWith(u8, path, prefix)) return false;
    if (request.name_glob) |glob| {
        const slash = std.mem.lastIndexOfScalar(u8, path, '/');
        const name = if (slash) |s| path[s + 1 ..] else path;
        if (!globMatches(glob, name)) return false;
    }
    return true;
}

// ------------------------------------------------------------------ cursor ---

/// The request's identity for the cursor: XXH3-64 over everything but `cursor`, `page_size` and
/// `time_budget_ms`, with the effective roots and labels.
pub fn requestHash(request: Request) u64 {
    var hasher = std.hash.XxHash3.init(0);
    const Feed = struct {
        fn text(h: *std.hash.XxHash3, value: ?[]const u8) void {
            if (value) |bytes| {
                var length: [9]u8 = undefined;
                length[0] = 1;
                std.mem.writeInt(u64, length[1..9], bytes.len, .little);
                h.update(&length);
                h.update(bytes);
            } else h.update(&[_]u8{0});
        }
        fn number(h: *std.hash.XxHash3, value: u64) void {
            var bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &bytes, value, .little);
            h.update(&bytes);
        }
    };
    Feed.text(&hasher, request.pattern);
    Feed.number(&hasher, @intFromEnum(request.mode));
    Feed.number(&hasher, @intFromEnum(request.case));
    Feed.number(&hasher, @intFromBool(request.whole_word));
    Feed.text(&hasher, request.path_prefix);
    Feed.text(&hasher, request.name_glob);
    Feed.number(&hasher, request.context_lines);
    Feed.number(&hasher, request.max_hits_per_file);
    if (request.scope_roots) |roots| {
        Feed.number(&hasher, roots.len);
        for (roots) |root| Feed.text(&hasher, root);
    } else Feed.number(&hasher, std.math.maxInt(u64));
    Feed.number(&hasher, request.scope_labels.len);
    for (request.scope_labels) |label| Feed.text(&hasher, label);
    return hasher.final();
}

/// XXH3-64 of a walk's sorted paths: an added, removed or renamed file changes it.
pub fn walkHash(paths: []const []const u8) u64 {
    var hasher = std.hash.XxHash3.init(0);
    for (paths) |path| {
        hasher.update(path);
        hasher.update(&[_]u8{0});
    }
    return hasher.final();
}

pub const Position = struct { file: usize = 0, line: u32 = 1, listed: u32 = 0 };

const CursorParse = union(enum) { position: Position, malformed, stale, foreign };

/// Sixteen lowercase hexadecimal digits, as the schema's pattern says (rework 1, ruling 8).
fn parseHex16(text: []const u8) ?u64 {
    if (text.len != 16) return null;
    for (text) |byte| switch (byte) {
        '0'...'9', 'a'...'f' => {},
        else => return null,
    };
    return std.fmt.parseInt(u64, text, 16) catch null;
}

fn parseCursor(cursor: []const u8, src: Source, hash: u64) CursorParse {
    var parts: [5][]const u8 = undefined;
    var it = std.mem.splitScalar(u8, cursor, ':');
    var count: usize = 0;
    while (it.next()) |part| : (count += 1) {
        if (count == 5) return .malformed;
        parts[count] = part;
    }
    if (count != 5) return .malformed;
    const request_hash = parseHex16(parts[1]) orelse return .malformed;
    const file = find.parseDigits(usize, parts[2]) orelse return .malformed;
    const line = find.parseDigits(u32, parts[3]) orelse return .malformed;
    const listed = find.parseDigits(u32, parts[4]) orelse return .malformed;
    if (line == 0) return .malformed;
    const folder_cursor = parts[0].len > 0 and parts[0][0] == 'f';
    if (folder_cursor) {
        const walk = parseHex16(parts[0][1..]) orelse return .malformed;
        if (src.kind != .folder or walk != src.walk) return .stale;
    } else {
        const generation = find.parseDigits(u64, parts[0]) orelse return .malformed;
        if (src.kind != .index or generation != src.generation) return .stale;
    }
    if (request_hash != hash) return .foreign;
    return .{ .position = .{ .file = file, .line = line, .listed = listed } };
}

fn formatCursor(allocator: std.mem.Allocator, src: Source, hash: u64, position: Position) ![]const u8 {
    return switch (src.kind) {
        .index => std.fmt.allocPrint(allocator, "{d}:{x:0>16}:{d}:{d}:{d}", .{ src.generation, hash, position.file, position.line, position.listed }),
        .folder => std.fmt.allocPrint(allocator, "f{x:0>16}:{x:0>16}:{d}:{d}:{d}", .{ src.walk, hash, position.file, position.line, position.listed }),
    };
}

// ------------------------------------------------------------------- lines ---

/// A line's bytes without its terminator (CRLF, or one of `str.splitlines`' single terminators).
pub fn stripBreak(line: []const u8) []const u8 {
    const end = line.len;
    if (end >= 2 and line[end - 2] == '\r' and line[end - 1] == '\n') return line[0 .. end - 2];
    if (end >= 3 and line[end - 3] == 0xe2 and line[end - 2] == 0x80 and (line[end - 1] == 0xa8 or line[end - 1] == 0xa9)) return line[0 .. end - 3];
    if (end >= 2 and line[end - 2] == 0xc2 and line[end - 1] == 0x85) return line[0 .. end - 2];
    if (end >= 1) switch (line[end - 1]) {
        0x0a, 0x0b, 0x0c, 0x0d, 0x1c, 0x1d, 0x1e => return line[0 .. end - 1],
        else => {},
    };
    return line;
}

/// The length of a line's `text`: all of it up to 512 bytes, else the longest prefix ending on a code-point boundary.
pub fn textCut(line: []const u8) usize {
    if (line.len <= max_text_bytes) return line.len;
    var cut = max_text_bytes;
    while (cut > 0 and line[cut] & 0xC0 == 0x80) cut -= 1;
    return cut;
}

/// One line of a file: its first byte, the end of its content (before its terminator) and where the next starts.
pub const LineSpan = struct { start: usize, end: usize, next: usize };

/// A file's lines one at a time, as `source.lineStarts` finds them (a leading BOM is not part of line 1; a line
/// exists when a byte starts it), keeping nothing per line.
pub const Lines = struct {
    bytes: []const u8,
    /// Where the next line starts.
    at: usize,
    /// The lines returned so far: the last one returned is line `number`.
    number: u32 = 0,

    pub fn init(bytes: []const u8) Lines {
        return .{ .bytes = bytes, .at = if (std.mem.startsWith(u8, bytes, "\xef\xbb\xbf")) 3 else 0 };
    }

    /// The next line, or null after the last. With a budget, every byte passed is charged, at least once per
    /// `pattern.check_units` bytes; out of time, the reader is left where it was.
    pub fn next(self: *Lines, budget: ?*pattern.Budget) error{OutOfTime}!?LineSpan {
        const bytes = self.bytes;
        if (self.at >= bytes.len) return null;
        const start = self.at;
        var at = start;
        var charged = start;
        const span: LineSpan = while (true) {
            if (at - charged >= pattern.check_units) {
                if (budget) |b| try b.charge(at - charged);
                charged = at;
            }
            const window = @min(bytes.len, at + pattern.check_units);
            const candidate = source.nextBreakCandidatePub(bytes[0..window], at);
            if (candidate == bytes.len) break .{ .start = start, .end = candidate, .next = candidate };
            if (candidate == window) {
                at = window;
                continue;
            }
            const width = source.breakWidthAt(bytes, candidate);
            if (width == 0) {
                at = candidate + 1;
                continue;
            }
            break .{ .start = start, .end = candidate, .next = candidate + width };
        };
        if (budget) |b| try b.charge(span.next - charged + 1);
        self.at = span.next;
        self.number += 1;
        return span;
    }
};

// --------------------------------------------------------------------- run ---

fn validate(allocator: std.mem.Allocator, request: Request) !?Outcome {
    if (request.page_size < 1 or request.page_size > max_page_size) return try fail(allocator, .invalid_argument, "page_size must be 1..{d}", .{max_page_size});
    if (request.context_lines > max_context_lines) return try fail(allocator, .invalid_argument, "context_lines must be 0..{d}", .{max_context_lines});
    if (request.max_hits_per_file < 1 or request.max_hits_per_file > max_max_hits_per_file)
        return try fail(allocator, .invalid_argument, "max_hits_per_file must be 1..{d}", .{max_max_hits_per_file});
    if (request.time_budget_ms < 1 or request.time_budget_ms > max_time_budget_ms)
        return try fail(allocator, .invalid_argument, "time_budget_ms must be 1..{d}", .{max_time_budget_ms});
    if (request.name_glob) |glob| if (glob.len == 0 or glob.len > max_glob_bytes or std.mem.indexOfScalar(u8, glob, '/') != null or !std.unicode.utf8ValidateSlice(glob))
        return try fail(allocator, .invalid_argument, "name_glob must be 1..{d} bytes with no /", .{max_glob_bytes});
    return null;
}

/// The spans of the lines around the one being searched, by line number modulo its length (`2 x context + 1`).
const Ring = struct {
    spans: []LineSpan,

    fn at(ring: Ring, line: u32) LineSpan {
        return ring.spans[line % ring.spans.len];
    }

    fn put(ring: Ring, line: u32, span: LineSpan) void {
        ring.spans[line % ring.spans.len] = span;
    }
};

fn contextLines(allocator: std.mem.Allocator, bytes: []const u8, ring: Ring, first: u32, last: u32) ![]const ContextLine {
    if (first > last) return &.{};
    const lines = try allocator.alloc(ContextLine, last - first + 1);
    for (lines, first..) |*slot, number| {
        const span = ring.at(@intCast(number));
        const content = bytes[span.start..span.end];
        const cut = textCut(content);
        slot.* = .{ .line = @intCast(number), .text = try allocator.dupe(u8, content[0..cut]), .text_truncated = cut < content.len };
    }
    return lines;
}

/// The refusal of a page that ran out of time before completing a position (ruling O-7), naming the cause.
fn outOfTime(allocator: std.mem.Allocator, request: Request, file: File, line: u32, went_on_reading: bool) error{OutOfMemory}!Outcome {
    if (went_on_reading) return fail(allocator, .capacity, "time_budget_ms ({d}) ran out reading {s}/{s}, and line {d} did not finish in the {d} ms after: raise it (at most {d}) or narrow the scope", .{ request.time_budget_ms, file.root_id, file.path, line, grace_ms, max_time_budget_ms });
    return fail(allocator, .capacity, "line {d} of {s}/{s} outlasts time_budget_ms ({d}): raise it (at most {d}) or narrow the scope", .{ line, file.root_id, file.path, request.time_budget_ms, max_time_budget_ms });
}

/// Run one page of `request` over `src`. A refused request is `.failed`, not an error.
pub fn run(allocator: std.mem.Allocator, request: Request, src: Source, clock: pattern.Clock) error{OutOfMemory}!Outcome {
    if (try validate(allocator, request)) |refused| return refused;
    // The clock starts before the pattern is parsed (rework 1, ruling 1): compiling is part of the page.
    var budget = pattern.Budget.start(clock, @intCast(request.time_budget_ms));
    const compiled = try allocator.create(pattern.Compiled);
    compiled.* = switch (try pattern.compile(allocator, request.pattern, request.mode, request.case, request.whole_word)) {
        .ok => |value| value,
        .refused => |message| return .{ .failed = .{ .code = .invalid_argument, .message = message } },
    };
    const hash = requestHash(request);
    const start: Position = if (request.cursor) |cursor| switch (parseCursor(cursor, src, hash)) {
        .position => |position| position,
        .malformed => return fail(allocator, .invalid_argument, malformed_cursor_message, .{}),
        .stale => return fail(allocator, .invalid_argument, stale_cursor_message, .{}),
        .foreign => return fail(allocator, .invalid_argument, foreign_cursor_message, .{}),
    } else .{};

    var kept = std.ArrayList(usize).empty;
    for (src.files, 0..) |file, index| if (inScope(request, file.path)) try kept.append(allocator, index);
    if (start.file > kept.items.len or start.listed > request.max_hits_per_file) return fail(allocator, .invalid_argument, malformed_cursor_message, .{});

    var matcher = try pattern.Matcher.init(allocator, compiled, &budget);
    var file_arena = std.heap.ArenaAllocator.init(allocator);
    defer file_arena.deinit();
    var hits = std.ArrayList(Hit).empty;
    var answer = Answer{
        .request = request,
        .kind = src.kind,
        .generation = if (src.kind == .index) src.generation else null,
        .case_applied = compiled.case_applied,
        .matches_empty = compiled.matches_empty,
        .hits = &.{},
        .pending_files = src.pending_files,
        .not_scanned = src.not_scanned,
        .not_read = src.not_read,
        .truncated = false,
        .stopped = .none,
        .next_cursor = null,
    };
    const max_hits: u32 = @intCast(request.max_hits_per_file);
    const context: u32 = @intCast(request.context_lines);
    var position = start;
    var progress = false;
    var resume_at: ?Position = null;

    files: while (position.file < kept.items.len) {
        if (progress and budget.expired()) {
            answer.stopped = .time;
            resume_at = position;
            break;
        }
        const file = src.files[kept.items[position.file]];
        _ = file_arena.reset(.retain_capacity);
        const fa = file_arena.allocator();
        const bytes = switch (try src.read(src.context, fa, file)) {
            .ok => |bytes| bytes,
            .too_large => blk: {
                answer.not_scanned.too_large += 1;
                break :blk null;
            },
            .unreadable => blk: {
                answer.not_scanned.unreadable += 1;
                break :blk null;
            },
            .binary => blk: {
                if (answer.not_read) |*counts| counts.add(.binary);
                break :blk null;
            },
        } orelse {
            position = .{ .file = position.file + 1 };
            progress = true;
            budget.endGrace();
            continue;
        };
        var lines = Lines.init(bytes);
        const ring = Ring{ .spans = try fa.alloc(LineSpan, 2 * context + 1) };
        // The lines before the cursor's are read as part of reading the file, without the budget.
        while (lines.number + 1 < position.line) {
            const span = (lines.next(null) catch unreachable) orelse break;
            ring.put(lines.number, span);
        }
        // The page's first line gets its grace, from now.
        const went_on_reading = if (!progress) budget.grace(grace_ms) else false;
        var offsets = std.ArrayList([2]u32).empty;
        var line = position.line;
        var listed = position.listed;
        var capped = false;
        while (true) {
            // The spans up to `line + context` (or the last line) are in the ring.
            while (lines.number < line +| context) {
                const span = (lines.next(&budget) catch {
                    if (!progress) return outOfTime(allocator, request, file, line, went_on_reading);
                    answer.stopped = .time;
                    resume_at = .{ .file = position.file, .line = line, .listed = listed };
                    break :files;
                }) orelse break;
                ring.put(lines.number, span);
            }
            if (line > lines.number) break;
            const span = ring.at(line);
            const content = bytes[span.start..span.end];
            const cut = textCut(content);
            offsets.clearRetainingCapacity();
            const result = matcher.matchLine(fa, content, cut, pattern.codepointCount(content[0..cut]), &offsets) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.OutOfTime => {
                    if (!progress) return outOfTime(allocator, request, file, line, went_on_reading);
                    answer.stopped = .time;
                    resume_at = .{ .file = position.file, .line = line, .listed = listed };
                    break :files;
                },
            };
            progress = true;
            budget.endGrace();
            if (result.hit) {
                if (listed == max_hits) {
                    capped = true;
                    break;
                }
                try hits.append(allocator, .{
                    .root_id = file.root_id,
                    .path = file.path,
                    .line = line,
                    .text = try allocator.dupe(u8, content[0..result.text_len]),
                    .text_truncated = result.text_len < content.len,
                    .match_offsets = try allocator.dupe([2]u32, offsets.items),
                    .before = if (context == 0) &.{} else try contextLines(allocator, bytes, ring, @max(1, line -| context), line - 1),
                    .after = try contextLines(allocator, bytes, ring, line + 1, @min(line +| context, lines.number)),
                });
                listed += 1;
                if (hits.items.len == request.page_size) {
                    resume_at = .{ .file = position.file, .line = line + 1, .listed = listed };
                    break :files;
                }
            }
            line += 1;
        }
        answer.files_scanned += 1;
        answer.bytes_scanned += bytes.len;
        if (listed > 0) answer.files_matched += 1;
        if (capped) answer.files_capped += 1;
        position = .{ .file = position.file + 1 };
        progress = true;
        budget.endGrace();
    }

    answer.hits = hits.items;
    answer.truncated = answer.pending_files > 0 or answer.not_scanned.any();
    if (resume_at) |at| answer.next_cursor = try formatCursor(allocator, src, hash, at);
    return .{ .ok = answer };
}

// ------------------------------------------------------------ index source ---

/// A file the caller may see in an index: its root, root-relative path, record path and whether its root keeps
/// source bytes.
pub const Candidate = struct { root_id: []const u8, path: []const u8, record: []const u8, retained: bool };

const IndexContext = struct {
    section: source.Section,
    entries: []const source.FileEntry,

    fn read(context: *anyopaque, allocator: std.mem.Allocator, file: File) error{OutOfMemory}!Read {
        const self: *const IndexContext = @ptrCast(@alignCast(context));
        return switch (try self.section.fileBytes(allocator, self.entries[file.key])) {
            .ok => |bytes| .{ .ok = bytes },
            // A file whose bytes fail the section's check is counted, not fatal.
            .failed => .unreadable,
        };
    }
};

fn lessThanCandidate(_: void, a: Candidate, b: Candidate) bool {
    const order = std.mem.order(u8, a.root_id, b.root_id);
    if (order != .eq) return order == .lt;
    return std.mem.order(u8, a.path, b.path) == .lt;
}

/// The index source over `section`: the candidates in `root_id` then path order, each looked up in the section;
/// one in the request's scope whose root keeps no bytes, or that the section does not hold, is counted
/// `not_retained`. `not_scanned` and `pending_files` come from the caller (the generation's skipped and pending
/// files the caller may see, in scope).
pub fn indexSource(allocator: std.mem.Allocator, request: Request, section: source.Section, generation: u64, candidates: []Candidate, pending_files: usize, not_scanned: NotScanned) !Source {
    std.mem.sort(Candidate, candidates, {}, lessThanCandidate);
    const context = try allocator.create(IndexContext);
    var entries = std.ArrayList(source.FileEntry).empty;
    var files = std.ArrayList(File).empty;
    var counts = not_scanned;
    for (candidates) |candidate| {
        const entry = if (candidate.retained) section.find(candidate.record) else null;
        if (entry) |found| {
            try files.append(allocator, .{ .root_id = candidate.root_id, .path = candidate.path, .key = entries.items.len });
            try entries.append(allocator, found);
        } else if (inScope(request, candidate.path)) counts.not_retained += 1;
    }
    context.* = .{ .section = section, .entries = entries.items };
    return .{
        .kind = .index,
        .generation = generation,
        .files = files.items,
        .context = context,
        .read = IndexContext.read,
        .pending_files = pending_files,
        .not_scanned = counts,
    };
}

// ----------------------------------------------------------- folder source ---

const FolderContext = struct {
    io: std.Io,
    dir: std.Io.Dir,
    max_file_bytes: u64,

    fn read(context: *anyopaque, allocator: std.mem.Allocator, file: File) error{OutOfMemory}!Read {
        const self: *const FolderContext = @ptrCast(@alignCast(context));
        const caps = apply.ReadCaps{ .max_file_bytes = self.max_file_bytes, .sniff = !indexer.hasAllowedExtension(std.fs.path.basename(file.path)) };
        return switch (try apply.readWalkedFile(allocator, self.io, self.dir, file.path, caps)) {
            .ok => |bytes| .{ .ok = bytes },
            .too_large => .too_large,
            .unreadable, .over_budget => .unreadable,
            .binary => .binary,
        };
    }
};

/// The folder source: `dir` walked as `searchd index` walks it, every file read with the same caps (`apply`'s
/// read-and-caps, `max_file_bytes` per file), root `r-legacy`. `include` false (a request whose `roots` leave
/// `r-legacy` out) gives no files. Nothing is written.
pub fn folderSource(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, max_file_bytes: u64, include: bool) !Source {
    const walk = try indexer.walkFolder(allocator, io, dir);
    const files = try allocator.alloc(File, if (include) walk.paths.len else 0);
    for (files, 0..) |*file, index| file.* = .{ .root_id = scope.legacy_root_id, .path = walk.paths[index], .key = index };
    const context = try allocator.create(FolderContext);
    context.* = .{ .io = io, .dir = dir, .max_file_bytes = max_file_bytes };
    return .{
        .kind = .folder,
        .walk = walkHash(walk.paths),
        .files = files,
        .context = context,
        .read = FolderContext.read,
        .not_read = walk.not_read,
    };
}

/// `std.Io.Clock.awake` as a `pattern.Clock`; `io` must outlive the scan.
pub const IoClock = struct {
    io: std.Io,

    pub fn clock(self: *IoClock) pattern.Clock {
        return .{ .context = self, .now = now };
    }

    fn now(context: ?*anyopaque) u64 {
        const self: *IoClock = @ptrCast(@alignCast(context.?));
        return @intCast(std.Io.Clock.awake.now(self.io).nanoseconds);
    }
};

// -------------------------------------------------------------------- JSON ---

fn writeContext(json: *std.json.Stringify, lines: []const ContextLine) !void {
    try json.beginArray();
    for (lines) |line| {
        try json.beginObject();
        try json.objectField("line");
        try json.write(line.line);
        try json.objectField("text");
        try json.write(line.text);
        try json.objectField("text_truncated");
        try json.write(line.text_truncated);
        try json.endObject();
    }
    try json.endArray();
}

/// The whole result object (ADR 0006 section 15.2): the request echo, `source`, `generation`, `scope` (with
/// `scope_roots`, the roots the request could see) and `warnings` as `find`'s envelope, then the answer.
pub fn writeJson(json: *std.json.Stringify, answer: Answer, scope_roots: []const []const u8) !void {
    const request = answer.request;
    try json.beginObject();
    try json.objectField("request");
    try json.beginObject();
    try json.objectField("pattern");
    try json.write(request.pattern);
    try json.objectField("mode");
    try json.write(@tagName(request.mode));
    try json.objectField("case");
    try json.write(@tagName(request.case));
    try json.objectField("whole_word");
    try json.write(request.whole_word);
    try json.objectField("roots");
    try json.write(request.named_roots);
    try json.objectField("path_prefix");
    try json.write(request.path_prefix);
    try json.objectField("name_glob");
    try json.write(request.name_glob);
    try json.objectField("context_lines");
    try json.write(request.context_lines);
    try json.objectField("max_hits_per_file");
    try json.write(request.max_hits_per_file);
    try json.objectField("page_size");
    try json.write(request.page_size);
    try json.objectField("cursor");
    try json.write(request.cursor);
    try json.objectField("time_budget_ms");
    try json.write(request.time_budget_ms);
    try json.endObject();
    try json.objectField("source");
    try json.write(@tagName(answer.kind));
    try json.objectField("generation");
    try json.write(answer.generation);
    try json.objectField("scope");
    try json.beginObject();
    try json.objectField("roots");
    try json.write(scope_roots);
    try json.objectField("labels_applied");
    try json.write(true);
    try json.endObject();
    try json.objectField("warnings");
    try json.beginArray();
    if (answer.matches_empty) {
        try json.beginObject();
        try json.objectField("code");
        try json.write("pattern_matches_empty");
        try json.objectField("message");
        try json.write(empty_match_message);
        try json.endObject();
    }
    try json.endArray();
    try json.objectField("case_applied");
    try json.write(@tagName(answer.case_applied));
    try json.objectField("hits");
    try json.beginArray();
    for (answer.hits) |hit| {
        try json.beginObject();
        try json.objectField("root_id");
        try json.write(hit.root_id);
        try json.objectField("path");
        try json.write(hit.path);
        try json.objectField("line");
        try json.write(hit.line);
        try json.objectField("text");
        try json.write(hit.text);
        try json.objectField("text_truncated");
        try json.write(hit.text_truncated);
        try json.objectField("match_offsets");
        try json.beginArray();
        for (hit.match_offsets) |range| {
            try json.beginArray();
            try json.write(range[0]);
            try json.write(range[1]);
            try json.endArray();
        }
        try json.endArray();
        try json.objectField("before");
        try writeContext(json, hit.before);
        try json.objectField("after");
        try writeContext(json, hit.after);
        try json.endObject();
    }
    try json.endArray();
    try json.objectField("files_matched");
    try json.write(answer.files_matched);
    try json.objectField("files_scanned");
    try json.write(answer.files_scanned);
    try json.objectField("files_capped");
    try json.write(answer.files_capped);
    try json.objectField("bytes_scanned");
    try json.write(answer.bytes_scanned);
    try json.objectField("pending_files");
    try json.write(answer.pending_files);
    try json.objectField("not_scanned");
    try json.beginObject();
    try json.objectField("too_large");
    try json.write(answer.not_scanned.too_large);
    try json.objectField("unreadable");
    try json.write(answer.not_scanned.unreadable);
    try json.objectField("budget_exhausted");
    try json.write(answer.not_scanned.budget_exhausted);
    try json.objectField("not_retained");
    try json.write(answer.not_scanned.not_retained);
    try json.endObject();
    try json.objectField("not_read");
    if (answer.not_read) |counts| try counts.writeJson(json) else try json.write(null);
    try json.objectField("truncated");
    try json.write(answer.truncated);
    try json.objectField("stopped");
    try json.write(@tagName(answer.stopped));
    try json.objectField("next_cursor");
    try json.write(answer.next_cursor);
    try json.endObject();
}
