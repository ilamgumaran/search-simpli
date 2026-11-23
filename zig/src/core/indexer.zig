//! Native folder indexing (S1-T1 acceptance criterion 3): walks a folder
//! and indexes its UTF-8 text files, lexical-only (no embeddings), no Python
//! involved. Since S3-T3 the walk builds an `apply_changes` batch (one
//! `local` root `r-legacy`, one change per candidate file) and
//! `apply.applyBatch` chunks, tokenizes and publishes it, so one code path
//! writes every generation. Since S6-T23 (CAP-24) a file is read when its
//! bytes are text (`text-sniff-v1`, below), with any extension or none. The
//! rule, its skip list and the ignored-directory set mirror
//! `search_platform.core` exactly, so the same folder produces the same
//! candidate file set as the Python reference.
const std = @import("std");
const analysis = @import("analysis.zig");
const analyzer_v2 = @import("analyzer_v2.zig");
const apply = @import("apply.zig");
const chunker = @import("chunker.zig");
const incremental_state = @import("incremental_state.zig");
const scope = @import("scope.zig");
const snapshot_open = @import("snapshot_open.zig");

pub const AnalyzerId = enum {
    v1,
    v2,

    pub fn label(self: AnalyzerId) []const u8 {
        return switch (self) {
            .v1 => "analyzer-v1",
            .v2 => "analyzer-v2",
        };
    }

    pub fn parse(text: []const u8) ?AnalyzerId {
        if (std.mem.eql(u8, text, "analyzer-v1") or std.mem.eql(u8, text, "v1")) return .v1;
        if (std.mem.eql(u8, text, "analyzer-v2") or std.mem.eql(u8, text, "v2")) return .v2;
        return null;
    }
};

/// `search_platform.core.DEFAULT_EXTENSIONS`. Since S6-T23 (CAP-24) these
/// are the names the walk reads without looking into them first: a file of
/// one of these names is read whole, and the sniff runs on its bytes in
/// memory (`apply.zig`). Every other name that is not on the skip list is
/// sniffed before it is read (`walkFolder`).
pub const default_extensions = [_][]const u8{
    ".c", ".cpp", ".css", ".go", ".h", ".html", ".java", ".js", ".json",
    ".md", ".py", ".rs", ".rst", ".toml", ".ts", ".txt", ".yaml", ".yml", ".zig",
};

// --- text-sniff-v1 (S6-T23, CAP-24 FR-34, ADR 0005 section 2) ----------
//
// A walked file is read when its bytes are text. The rule, in order, for a
// regular file the walk keeps (no component starting with `.`, none of the
// ignored directories): a path that is not a valid record path is
// `bad_name`; a skip-listed extension is not opened (its kind); otherwise
// the first `sniff_head_bytes` bytes decide (`sniff`); a text file is then
// read whole as before (`too_large`, `unreadable`). Mirrored by
// `search_platform.core` (`_sniff`, `_not_read_kind`).

/// The rule's identity, written into every walk-built manifest's meta
/// (`readable`, FR-36).
pub const readable_rule_id = "text-sniff-v1";
/// How many bytes of a file the sniff reads.
pub const sniff_head_bytes: usize = 8192;
/// More than this share of control bytes in the head is binary: the meta's
/// `control_share_max` 0.01, as a percentage.
pub const control_share_percent: usize = 1;

pub const Verdict = enum {
    text,
    /// A UTF-16 or UTF-32 byte order mark: text, but not UTF-8 (read and
    /// counted `unreadable`, as any not-UTF-8 file).
    other_encoding,
    /// A NUL byte, or more than `control_share_percent` % control bytes.
    binary,
    /// Not valid UTF-8 (counted `unreadable` once read whole).
    not_utf8,
};

/// Control bytes that do not occur in text: C0 except TAB, LF, VT, FF, CR and
/// ESC (coloured logs), and DEL.
fn isControlByte(byte: u8) bool {
    return switch (byte) {
        0x01...0x08, 0x0E...0x1A, 0x1C...0x1F, 0x7F => true,
        else => false,
    };
}

/// Valid UTF-8; when `cut` (the file is longer than `head`), a final
/// sequence the head's end cut is allowed, judged by its lead byte alone.
fn headIsUtf8(head: []const u8, cut: bool) bool {
    if (std.unicode.utf8ValidateSlice(head)) return true;
    if (!cut) return false;
    var start = head.len;
    var continuation: usize = 0;
    while (start > 0 and continuation < 3 and (head[start - 1] & 0xC0) == 0x80) : (continuation += 1) start -= 1;
    if (start == 0) return false;
    const lead = head[start - 1];
    const length: usize = switch (lead) {
        0xC2...0xDF => 2,
        0xE0...0xEF => 3,
        0xF0...0xF4 => 4,
        else => return false,
    };
    if (head.len - (start - 1) >= length) return false;
    return std.unicode.utf8ValidateSlice(head[0 .. start - 1]);
}

/// The sniff of `head`, the first bytes of a file of `size` bytes (the
/// whole file when it is at most `sniff_head_bytes`).
pub fn sniff(head: []const u8, size: u64) Verdict {
    if (head.len == 0) return .text;
    if (std.mem.startsWith(u8, head, "\xff\xfe") or std.mem.startsWith(u8, head, "\xfe\xff") or std.mem.startsWith(u8, head, "\x00\x00\xfe\xff")) return .other_encoding;
    if (std.mem.indexOfScalar(u8, head, 0) != null) return .binary;
    var controls: usize = 0;
    for (head) |byte| controls += @intFromBool(isControlByte(byte));
    if (controls * 100 > head.len * control_share_percent) return .binary;
    if (!headIsUtf8(head, size > head.len)) return .not_utf8;
    return .text;
}

/// Why a walked file was not read (FR-35). The fields are in byte order of
/// their names, the order `not_read` lists them in.
pub const NotReadKind = enum { archive, audio, bad_name, binary, database, document, font, image, program, video };

/// Files a walk did not read, counted by kind, without paths (FR-35).
pub const NotRead = struct {
    counts: [@typeInfo(NotReadKind).@"enum".fields.len]usize = @splat(0),

    pub fn add(self: *NotRead, kind: NotReadKind) void {
        self.counts[@intFromEnum(kind)] += 1;
    }

    pub fn count(self: NotRead, kind: NotReadKind) usize {
        return self.counts[@intFromEnum(kind)];
    }

    pub fn total(self: NotRead) usize {
        var sum: usize = 0;
        for (self.counts) |n| sum += n;
        return sum;
    }

    /// `{"binary":1,"image":2}`: the kinds with a non-zero count, `{}`
    /// when none.
    pub fn writeJson(self: NotRead, json: *std.json.Stringify) !void {
        try json.beginObject();
        for (self.counts, 0..) |n, index| {
            if (n == 0) continue;
            try json.objectField(@tagName(@as(NotReadKind, @enumFromInt(index))));
            try json.write(n);
        }
        try json.endObject();
    }
};

/// The skip list: extensions of kinds that are not text, never opened. SVG
/// and RTF are text bytes, but an image and a word-processor document.
const skip_list = [_]struct { []const u8, NotReadKind }{
    .{ ".png", .image },     .{ ".jpg", .image },      .{ ".jpeg", .image },    .{ ".gif", .image },
    .{ ".bmp", .image },     .{ ".tif", .image },      .{ ".tiff", .image },    .{ ".webp", .image },
    .{ ".heic", .image },    .{ ".heif", .image },     .{ ".ico", .image },     .{ ".icns", .image },
    .{ ".psd", .image },     .{ ".svg", .image },      .{ ".avif", .image },    .{ ".raw", .image },
    .{ ".cr2", .image },     .{ ".nef", .image },      .{ ".dng", .image },     .{ ".mp3", .audio },
    .{ ".m4a", .audio },     .{ ".aac", .audio },      .{ ".wav", .audio },     .{ ".flac", .audio },
    .{ ".ogg", .audio },     .{ ".opus", .audio },     .{ ".aif", .audio },     .{ ".aiff", .audio },
    .{ ".mid", .audio },     .{ ".midi", .audio },     .{ ".mp4", .video },     .{ ".m4v", .video },
    .{ ".mov", .video },     .{ ".avi", .video },      .{ ".mkv", .video },     .{ ".webm", .video },
    .{ ".wmv", .video },     .{ ".mpg", .video },      .{ ".mpeg", .video },    .{ ".zip", .archive },
    .{ ".gz", .archive },    .{ ".tgz", .archive },    .{ ".bz2", .archive },   .{ ".xz", .archive },
    .{ ".zst", .archive },   .{ ".7z", .archive },     .{ ".rar", .archive },   .{ ".tar", .archive },
    .{ ".dmg", .archive },   .{ ".iso", .archive },    .{ ".pkg", .archive },   .{ ".jar", .archive },
    .{ ".pdf", .document },  .{ ".doc", .document },   .{ ".docx", .document }, .{ ".xls", .document },
    .{ ".xlsx", .document }, .{ ".ppt", .document },   .{ ".pptx", .document }, .{ ".odt", .document },
    .{ ".ods", .document },  .{ ".odp", .document },   .{ ".pages", .document }, .{ ".numbers", .document },
    .{ ".key", .document },  .{ ".rtf", .document },   .{ ".epub", .document }, .{ ".ttf", .font },
    .{ ".otf", .font },      .{ ".woff", .font },      .{ ".woff2", .font },    .{ ".exe", .program },
    .{ ".dll", .program },   .{ ".so", .program },     .{ ".dylib", .program }, .{ ".o", .program },
    .{ ".a", .program },     .{ ".class", .program },  .{ ".pyc", .program },   .{ ".wasm", .program },
    .{ ".bin", .program },   .{ ".sqlite", .database }, .{ ".sqlite3", .database }, .{ ".db", .database },
};

/// The lowercased last extension of `name` (from its last `.`), or null
/// when it has none or one longer than 16 bytes.
fn lowerExtension(name: []const u8, buffer: *[16]u8) ?[]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
    const suffix = name[dot..];
    if (suffix.len > buffer.len) return null;
    for (suffix, 0..) |byte, i| buffer[i] = std.ascii.toLower(byte);
    return buffer[0..suffix.len];
}

/// The skip list's kind for `name`, or null.
pub fn skipKind(name: []const u8) ?NotReadKind {
    var buffer: [16]u8 = undefined;
    const extension = lowerExtension(name, &buffer) orelse return null;
    for (skip_list) |entry| {
        if (std.mem.eql(u8, entry[0], extension)) return entry[1];
    }
    return null;
}

/// `search_platform.core.IGNORED_DIRECTORIES`.
pub const ignored_directories = [_][]const u8{
    ".git", ".search", ".zig-cache", "__pycache__", "node_modules", "zig-out",
};

pub const IndexReport = struct {
    generation: u64,
    analyzer_id: []const u8,
    files_indexed: usize,
    files_skipped: usize,
    /// Relative paths of every file counted under `files_skipped` (stat
    /// failure, oversized-for-usize, read failure, invalid UTF-8, or a
    /// chunker error) -- S1-T4 criterion 3: a skipped file is never silent,
    /// it is always named.
    unreadable_paths: [][]const u8,
    documents: usize,
    terms: usize,
    postings: usize,
};

fn hasAllowedExtension(name: []const u8) bool {
    var buffer: [16]u8 = undefined;
    const lowered = lowerExtension(name, &buffer) orelse return false;
    for (default_extensions) |candidate| {
        if (std.mem.eql(u8, candidate, lowered)) return true;
    }
    return false;
}

fn isIgnoredComponent(part: []const u8) bool {
    if (part.len > 0 and part[0] == '.') return true;
    for (ignored_directories) |ignored| {
        if (std.mem.eql(u8, ignored, part)) return true;
    }
    return false;
}

fn isIgnoredPath(relative_path: []const u8) bool {
    var it = std.mem.splitScalar(u8, relative_path, '/');
    while (it.next()) |part| {
        if (isIgnoredComponent(part)) return true;
    }
    return false;
}

fn lessThanPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// A walk of a folder: the files it reads (sorted bytewise) and the counts
/// of those it does not.
pub const Walk = struct {
    paths: [][]const u8,
    not_read: NotRead = .{},
};

/// Walk `root` under `text-sniff-v1` (S6-T23): every regular file not under
/// an ignored directory or a dot-component is a candidate when its path is
/// a valid record path, its extension is not on the skip list, and either
/// its name is one of `default_extensions` (sniffed once read, in
/// `apply.zig`) or its first bytes sniff as not binary. The paths are
/// sorted. Shared by `indexFolder`, `indexFolderIncremental` and
/// `buildFolderDetached`, so all three see the same file set.
pub fn walkFolder(allocator: std.mem.Allocator, io: std.Io, root: std.Io.Dir) !Walk {
    var paths = std.ArrayList([]const u8).empty;
    var not_read: NotRead = .{};
    var head_buffer: [sniff_head_bytes]u8 = undefined;
    var walker = try root.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (isIgnoredPath(entry.path)) continue;
        // A name no record can hold (a line break, NUL, not UTF-8, too
        // long): counted, never read, never a failure of the whole walk
        // (before S6-T23 the source section refused it: `InvalidPath`).
        if (!apply.validRelativePath(entry.path)) {
            not_read.add(.bad_name);
            continue;
        }
        if (skipKind(entry.basename)) |kind| {
            not_read.add(kind);
            continue;
        }
        if (!hasAllowedExtension(entry.basename) and sniffFile(io, root, entry.path, &head_buffer) == .binary) {
            not_read.add(.binary);
            continue;
        }
        try paths.append(allocator, try allocator.dupe(u8, entry.path));
    }
    const items = try paths.toOwnedSlice(allocator);
    std.mem.sort([]const u8, items, {}, lessThanPath);
    return .{ .paths = items, .not_read = not_read };
}

/// `sniff` of the first `buffer.len` bytes of `root`/`path`. A file that
/// cannot be opened, stated or read is not judged here (`.text`): it stays
/// a candidate, and the whole read reports it `unreadable` with its path.
fn sniffFile(io: std.Io, root: std.Io.Dir, path: []const u8, buffer: []u8) Verdict {
    var file = root.openFile(io, path, .{}) catch return .text;
    defer file.close(io);
    const stat = file.stat(io) catch return .text;
    var reader = file.reader(io, &.{});
    const length = reader.interface.readSliceShort(buffer) catch return .text;
    return sniff(buffer[0..length], stat.size);
}

/// `walkFolder`'s paths only.
pub fn collectCandidatePaths(allocator: std.mem.Allocator, io: std.Io, root: std.Io.Dir) ![][]const u8 {
    return (try walkFolder(allocator, io, root)).paths;
}

fn tokenizeV1(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var tokens = std.ArrayList([]const u8).empty;
    defer tokens.deinit(allocator);
    var iterator = analysis.TokenIterator.init(text);
    while (iterator.next()) |token| {
        const owned = try allocator.alloc(u8, token.bytes.len);
        for (token.bytes, 0..) |byte, i| owned[i] = std.ascii.toLower(byte);
        try tokens.append(allocator, owned);
    }
    return tokens.toOwnedSlice(allocator);
}

pub fn tokenize(allocator: std.mem.Allocator, analyzer: AnalyzerId, text: []const u8) ![][]const u8 {
    return switch (analyzer) {
        .v1 => tokenizeV1(allocator, text),
        .v2 => analyzer_v2.tokenize(allocator, text),
    };
}

/// `tokenize` with each token's codepoint span in `text` (S3-T2): what the
/// positional lexical build (`HYBLEX02`) records as ordinals and offsets.
pub fn tokenizePositioned(allocator: std.mem.Allocator, analyzer: AnalyzerId, text: []const u8) ![]const analysis.PositionedToken {
    return switch (analyzer) {
        .v1 => analysis.tokenizePositioned(allocator, text, true),
        .v2 => analyzer_v2.tokenizePositioned(allocator, text),
    };
}

/// The one root `index_folder` writes (S3-T1): its records keep bare
/// relative paths (`scope.zig`).
pub const legacy_root_id = scope.legacy_root_id;

/// Walk `root`, chunk and tokenize every matching file, and publish a fresh
/// generation into `out_dir` (a full rebuild: the previous generation, if
/// any, is not consulted). `allocator` is expected to be an arena.
///
/// S6-T20: `generation` null publishes the next free number
/// (`generation_alloc.nextFreeGeneration`), chosen by `apply.applyParsed`
/// after it takes `WRITER.LOCK` and published under the same lease, as
/// `indexFolderIncremental` does. A number given is published as given; if
/// a section file it would write is already present, the publish fails
/// with `PathAlreadyExists` and publishes nothing.
///
/// S3-T3 (ruling 2): this is a walk that builds an `apply_changes` batch
/// (one `local` root `r-legacy`, one `walk` change per candidate file) and
/// hands it to `apply.applyBatch`, so one code path writes every generation.
/// The report keeps every S1 field.
///
/// An empty folder (no candidate files, or every candidate file skipped)
/// publishes an empty generation (0 documents/terms/postings) rather than
/// failing -- S1-T4 criterion 3. A file over `caps.max_file_bytes` is not
/// read and is reported as `too_large`; once `caps.max_total_bytes` has been
/// read in this run every remaining candidate is left out and counted as
/// `budget_exhausted` (S1-T5 criterion 1). A full rebuild reports
/// `changed`/`removed`/`unchanged` as 0 and `added` as the files it indexed.
pub fn indexFolder(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    out_dir: std.Io.Dir,
    analyzer: AnalyzerId,
    generation: ?u64,
    max_chars: usize,
    overlap_lines: usize,
    caps: Caps,
) !IncrementalReport {
    return walkAndApply(allocator, io, root, out_dir, analyzer, max_chars, overlap_lines, caps, true, generation);
}

fn walkAndApply(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    out_dir: std.Io.Dir,
    analyzer: AnalyzerId,
    max_chars: usize,
    overlap_lines: usize,
    caps: Caps,
    fresh: bool,
    generation: ?u64,
) !IncrementalReport {
    const walked = try walkBatch(allocator, io, root, caps);
    const outcome = try apply.applyBatch(allocator, io, out_dir, walked.batch(), walkOptions(analyzer, max_chars, overlap_lines, caps, fresh, generation));
    return reportOf(allocator, outcome, walked.not_read);
}

/// The batch `index` applies for a walk of `root`: one change per candidate
/// file in the one root `r-legacy`, and the walk's not-read counts.
const Walked = struct {
    roots: *const [1]apply.RootDecl,
    changes: []const apply.Change,
    not_read: NotRead,

    fn batch(walked: Walked) apply.Batch {
        return .{ .roots = walked.roots, .changes = walked.changes };
    }
};

fn walkBatch(allocator: std.mem.Allocator, io: std.Io, root: std.Io.Dir, caps: Caps) !Walked {
    const walk = try walkFolder(allocator, io, root);
    const changes = try allocator.alloc(apply.Change, walk.paths.len);
    for (walk.paths, changes) |path, *change| {
        change.* = .{ .op = .change, .root_id = legacy_root_id, .path = path, .content = .{ .walk = .{ .dir = root, .sub_path = path } } };
    }
    const roots = try allocator.create([1]apply.RootDecl);
    roots.* = .{.{ .root_id = legacy_root_id, .label = "folder", .kind = "local", .retain_source = caps.retain_source }};
    return .{ .roots = roots, .changes = changes, .not_read = walk.not_read };
}

fn walkOptions(analyzer: AnalyzerId, max_chars: usize, overlap_lines: usize, caps: Caps, fresh: bool, generation: ?u64) apply.Options {
    return .{
        .analyzer = analyzer,
        .max_chars = max_chars,
        .overlap_lines = overlap_lines,
        .filename_index = caps.filename_index,
        .max_file_bytes = caps.max_file_bytes,
        .max_total_bytes = caps.max_total_bytes,
        .keep_generations = caps.keep_generations,
        .origin = "folder",
        .budget = .exhaust,
        // A rename in a walked folder stays `removed` + `added`: the S1
        // report has no `moved` field (host batches detect renames).
        .detect_renames = false,
        .complete_root = legacy_root_id,
        .fresh = fresh,
        .generation = generation,
        // S6-T23 (FR-36): the generation records the rule that chose its files.
        .readable = true,
    };
}

/// S6-T2 (`searchd search`): the generation `indexFolder` would publish for
/// `root` into an empty directory (generation 1, the same walk, root,
/// options and caps), built in memory and not published: nothing is
/// written anywhere. The sections and the report live in `allocator` (an
/// arena).
pub fn buildFolderDetached(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    analyzer: AnalyzerId,
    max_chars: usize,
    overlap_lines: usize,
    caps: Caps,
) !Detached {
    const walked = try walkBatch(allocator, io, root, caps);
    return switch (try apply.buildDetached(allocator, io, walked.batch(), walkOptions(analyzer, max_chars, overlap_lines, caps, true, 1))) {
        .ok => |detached| .{ .sections = detached.sections, .report = try reportOf(allocator, .{ .ok = detached.report }, walked.not_read) },
        .failed => error.ApplyRefused,
    };
}

pub const Detached = struct {
    sections: apply.Built,
    report: IncrementalReport,
};

fn reportOf(allocator: std.mem.Allocator, outcome: apply.Outcome, walk_not_read: NotRead) !IncrementalReport {
    const report = switch (outcome) {
        .ok => |r| r,
        .failed => return error.ApplyRefused,
    };
    // The walk's counts, and the files of a known name whose bytes the read
    // found binary (`apply.Report.walk_binary`).
    var not_read = walk_not_read;
    not_read.counts[@intFromEnum(NotReadKind.binary)] += report.walk_binary;
    return .{
        .generation = report.generation,
        .analyzer_id = report.analyzer_id,
        .added = report.added,
        .changed = report.changed,
        .removed = report.removed,
        .unchanged = report.unchanged,
        .budget_exhausted = report.budget_exhausted_paths.len,
        .too_large = report.too_large_paths.len,
        .unreadable = report.unreadable_paths.len,
        .too_large_paths = try relativePaths(allocator, report.too_large_paths),
        .unreadable_paths = try relativePaths(allocator, report.unreadable_paths),
        .not_read = not_read,
        .documents = report.documents,
        .terms = report.terms,
        .postings = report.postings,
        .pruned_files = report.pruned_files,
        .prune_failures = report.prune_failures,
        .recovered = report.recovered,
    };
}

fn relativePaths(allocator: std.mem.Allocator, refs: []const apply.PathRef) ![][]const u8 {
    const out = try allocator.alloc([]const u8, refs.len);
    for (refs, out) |ref, *path| path.* = ref.path;
    return out;
}

/// Caps applied to a single `indexFolder` or `indexFolderIncremental` run
/// alike (S1-T5, round-E rework: `indexFolder` did not enforce
/// `max_total_bytes` at all before this). Both come from the caller's
/// `opts` (CLI flags or `ss_index_folder`'s `opts` JSON object) -- see
/// `docs/tasks/S1-T3.md` criterion 2.
pub const Caps = struct {
    /// CAP-16's filename channel (S4-T2 R6): `true` asks for it (a new or
    /// empty directory only), `false` asks for none, `null` (the default,
    /// `searchd index` without `--filename-index`) keeps the directory's
    /// current setting (none for a new directory).
    filename_index: ?bool = null,
    /// S2-T5, opt-in (`null`, the default, deletes nothing): after a
    /// successful publish, delete the section files of generations older
    /// than the newest `keep_generations` (>= 1). Carried here because
    /// `Caps` already travels from every caller (CLI, `ss_index_folder`)
    /// through `indexFolder`/`indexFolderIncremental` to the publish call.
    keep_generations: ?usize = null,
    /// A file larger than this (bytes) is never read; it is excluded from
    /// the index and counted under the report's `too_large`.
    max_file_bytes: u64 = 10 * 1024 * 1024,
    /// Once this many bytes have been read from disk in this run, remaining
    /// unprocessed candidate files are left untouched for this generation
    /// and counted under the report's `budget_exhausted`. On
    /// `indexFolderIncremental`, a left-over file's previous chunks (if any)
    /// are carried forward unchanged; `indexFolder` (a full rebuild) has no
    /// previous generation to carry anything forward from, so a left-over
    /// file there is simply absent from the new generation, the same as a
    /// file over `max_file_bytes`. Guards worst-case run time on an enormous
    /// folder; a later `--update` run picks up where this one left off.
    max_total_bytes: u64 = 512 * 1024 * 1024,
    /// S3-T1 (CAP-19 FR-22, implementation section 4): keep every indexed
    /// file's original bytes in the generation's source section so
    /// `read_span` is byte-exact. Default true for `index_folder` in this
    /// task (ruling 4); false writes no source section and `read_span`
    /// answers `CAPACITY` "re-index required: source absent".
    retain_source: bool = true,
};

pub const IncrementalReport = struct {
    generation: u64,
    analyzer_id: []const u8,
    added: usize,
    changed: usize,
    removed: usize,
    /// Unchanged since the previous generation (content hash matched
    /// `INDEX-STATE.json`) -- nothing to do. S1-T4 criterion 3 splits this
    /// out of the old, ambiguous `skipped` (round-B non-blocking finding 5):
    /// a caller can no longer confuse "finished, nothing changed" with
    /// "ran out of budget, try again".
    unchanged: usize,
    /// Left untouched for this generation because `caps.max_total_bytes`
    /// was exhausted first; the file's previous chunks (if any) are carried
    /// forward unchanged and it is eligible again on the next run.
    budget_exhausted: usize,
    too_large: usize,
    unreadable: usize,
    /// Relative paths of every file counted under `too_large` -- S1-T4
    /// criterion 3. A file that grows past `caps.max_file_bytes` is
    /// tombstoned (its previous chunks are not carried forward: see the
    /// call site in `indexFolderIncremental`), never silently kept, and
    /// this path list is what keeps that tombstoning from being silent
    /// about *which* file it happened to.
    too_large_paths: [][]const u8,
    /// Relative paths of every file counted under `unreadable` -- S1-T4
    /// criterion 3 (round-B non-blocking finding 6). Unlike `too_large`,
    /// an unreadable file's previous chunks (if any) are carried forward.
    unreadable_paths: [][]const u8,
    /// S6-T23 (FR-35): files the walk did not read, by kind, without paths:
    /// a bad name, a skip-listed kind, or bytes the sniff calls binary. Not
    /// in the manifest's `skipped`; a file of the previous generation that is
    /// now not read is `removed`.
    not_read: NotRead = .{},
    documents: usize,
    terms: usize,
    postings: usize,
    /// S2-T5: superseded section files deleted by `caps.keep_generations`
    /// after this publish, and deletions that failed (the publish itself
    /// still succeeded). Both 0 when the option is off.
    pruned_files: usize = 0,
    prune_failures: usize = 0,
    /// Non-null when `INDEX-STATE.json` was discarded and every file
    /// re-indexed into a full generation: `"missing_section"` (S2-T5:
    /// `MANIFEST` named a section that could not be read) or
    /// `"missing_manifest"` (S2-T12: no `MANIFEST`, but a state file exists).
    recovered: ?[]const u8 = null,
};

/// Incremental folder indexing (S1-T3, `docs/incremental-indexing.md`):
/// re-walks `root` and applies the walk as one batch over the current
/// generation in `out_dir`. Every candidate file is read and hashed; a file
/// whose hash and chunker match its `INDEX-STATE.json` entry keeps its
/// chunks (re-tokenized from the previous postings, not re-chunked); a file
/// no longer in the walk is removed; an unreadable file, or one left over by
/// `caps.max_total_bytes`, keeps its previous chunks; a file over
/// `caps.max_file_bytes` loses them (`too_large`). A `MANIFEST` naming a lost
/// section, or a lost `MANIFEST` beside a state file, re-indexes every file
/// and says so in `recovered`. Fails closed (`error.AnalyzerMismatch`) on a
/// generation published with another analyzer. Publishes the next free
/// generation, then writes `INDEX-STATE.json`.
///
/// S3-T3: the walk builds an `apply_changes` batch (`apply.applyBatch`).
pub fn indexFolderIncremental(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    out_dir: std.Io.Dir,
    analyzer: AnalyzerId,
    max_chars: usize,
    overlap_lines: usize,
    caps: Caps,
) !IncrementalReport {
    return walkAndApply(allocator, io, root, out_dir, analyzer, max_chars, overlap_lines, caps, false, null);
}

test "indexFolder publishes a queryable generation from a real folder" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;

    try tmp.dir.writeFile(io, .{ .sub_path = "note.md", .data = "search evidence combines lexical and semantic ranks\n" });
    try tmp.dir.createDir(io, "out", .default_dir);
    var out_dir = try tmp.dir.openDir(io, "out", .{});
    defer out_dir.close(io);

    const report = try indexFolder(arena, io, tmp.dir, out_dir, .v2, 1, chunker.default_max_chars, chunker.default_overlap_lines, .{});
    try std.testing.expectEqual(@as(usize, 1), report.added);
    try std.testing.expect(report.documents >= 1);
    try std.testing.expectEqualStrings("analyzer-v2", report.analyzer_id);
}

test "indexFolder publishes an empty generation for an empty folder instead of NoDocuments" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;

    try tmp.dir.createDir(io, "root", .default_dir);
    var root = try tmp.dir.openDir(io, "root", .{ .iterate = true });
    defer root.close(io);
    try tmp.dir.createDir(io, "out", .default_dir);
    var out_dir = try tmp.dir.openDir(io, "out", .{});
    defer out_dir.close(io);

    const report = try indexFolder(arena, io, root, out_dir, .v2, 1, chunker.default_max_chars, chunker.default_overlap_lines, .{});
    try std.testing.expectEqual(@as(usize, 0), report.added);
    try std.testing.expectEqual(@as(usize, 0), report.documents);
    try std.testing.expectEqual(@as(usize, 0), report.terms);
    try std.testing.expectEqual(@as(usize, 0), report.postings);
    try std.testing.expectEqual(@as(usize, 0), report.unreadable_paths.len);

    // The empty generation is durably published and queryable (0 results,
    // never an open failure).
    const opened = try snapshot_open.open(arena, io, out_dir);
    try std.testing.expectEqual(@as(u64, 1), opened.generation);
    try std.testing.expectEqual(@as(usize, 0), opened.documents.len);
}

test "indexFolder lists the paths of files it could not read" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;

    try tmp.dir.writeFile(io, .{ .sub_path = "good.md", .data = "search evidence combines lexical and semantic ranks\n" });
    // Invalid UTF-8 -- rejected the same way a genuinely unreadable file is.
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.md", .data = &[_]u8{ 0xff, 0xfe, 0x00 } });
    try tmp.dir.createDir(io, "out", .default_dir);
    var out_dir = try tmp.dir.openDir(io, "out", .{});
    defer out_dir.close(io);

    const report = try indexFolder(arena, io, tmp.dir, out_dir, .v2, 1, chunker.default_max_chars, chunker.default_overlap_lines, .{});
    try std.testing.expectEqual(@as(usize, 1), report.added);
    try std.testing.expectEqual(@as(usize, 1), report.unreadable);
    try std.testing.expectEqual(@as(usize, 1), report.unreadable_paths.len);
    try std.testing.expectEqualStrings("bad.md", report.unreadable_paths[0]);
}

test "hasAllowedExtension matches DEFAULT_EXTENSIONS case-insensitively" {
    try std.testing.expect(hasAllowedExtension("README.MD"));
    try std.testing.expect(hasAllowedExtension("main.zig"));
    try std.testing.expect(!hasAllowedExtension("image.png"));
    try std.testing.expect(!hasAllowedExtension("noext"));
}

test "S6-T23: sniff's verdicts (the same bytes as tests/test_text_sniff.py)" {
    const cases = [_]struct { []const u8, u64, Verdict }{
        .{ "", 0, .text },
        .{ "plain words\n", 12, .text },
        .{ "\xef\xbb\xbfa UTF-8 mark\n", 16, .text },
        .{ "2026-11-01 \x1b[32mINFO\x1b[0m done\n", 31, .text },
        .{ "\xff\xfeh\x00i\x00", 6, .other_encoding },
        .{ "\xfe\xff\x00h\x00i", 6, .other_encoding },
        .{ "\x00\x00\xfe\xff\x00\x00\x00h", 8, .other_encoding },
        .{ "ab\x00cd", 5, .binary },
        .{ "a" ** 99 ++ "\x01", 100, .text },
        .{ "a" ** 98 ++ "\x01\x02", 100, .binary },
        .{ "caf\xe9\n", 5, .not_utf8 },
        .{ "abc\xe2\x82", 9000, .text },
        .{ "abc\xe2\x82", 5, .not_utf8 },
        .{ "abc\xf0\x9f\x98", 9000, .text },
        .{ "abc\xff", 9000, .not_utf8 },
        .{ "abc\xe2\x82\xac", 9000, .text },
        .{ "\x80\x80\x80\x80", 9000, .not_utf8 },
    };
    for (cases, 0..) |case, index| {
        errdefer std.debug.print("case {d}\n", .{index});
        try std.testing.expectEqual(case[2], sniff(case[0], case[1]));
    }
    // The rule's id and parameters, as the manifest writes them.
    try std.testing.expect(std.mem.indexOf(u8, @import("manifest.zig").readable_meta, "\"id\":\"" ++ readable_rule_id ++ "\",\"head_bytes\":8192,\"control_share_max\":0.01") != null);
    try std.testing.expectEqual(@as(usize, 8192), sniff_head_bytes);
    try std.testing.expectEqual(NotReadKind.image, skipKind("Logo.SVG").?);
    try std.testing.expectEqual(NotReadKind.archive, skipKind("backup.tar.gz").?);
    try std.testing.expectEqual(@as(?NotReadKind, null), skipKind("README"));
    try std.testing.expectEqual(@as(?NotReadKind, null), skipKind("loans.csv"));
}

/// A folder of every kind the walk tells apart (S6-T23).
fn writeKindsFolder(dir: std.Io.Dir) !void {
    const io = std.testing.io;
    const files = [_]struct { []const u8, []const u8 }{
        .{ "notes/a.md", "# A\n\nThe kestrel nests by the mill.\n" },
        .{ "README", "The russet folder holds the orchard plans.\n" },
        .{ "data.csv", "item,shelf\ntilecutter,S20\n" },
        .{ "logo.svg", "<svg><title>orchard</title></svg>\n" },
        .{ "scan.pdf", "%PDF-1.7 orchard\n" },
        .{ "blob", "orchard\x00\x01\x02" },
        .{ "known.txt", "orchard with a NUL\x00 inside\n" },
        .{ "a\rb.md", "orchard behind a carriage return\n" },
        .{ "Icon\r", "" },
        .{ ".env", "TOKEN=orchard\n" },
        .{ ".config/settings.ini", "orchard = hidden\n" },
        .{ "node_modules/pkg/readme", "orchard in node_modules\n" },
    };
    for (files) |file| {
        if (std.fs.path.dirname(file[0])) |parent| try dir.createDirPath(io, parent);
        try dir.writeFile(io, .{ .sub_path = file[0], .data = file[1] });
    }
}

test "S6-T23: the walk reads text of any name, skips listed kinds and binary heads, counts bad names, leaves dot-files out" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    try writeKindsFolder(tmp.dir);

    const walk = try walkFolder(arena, io, tmp.dir);
    // `known.txt` is a known name: a candidate, sniffed once read.
    try std.testing.expectEqual(@as(usize, 4), walk.paths.len);
    for ([_][]const u8{ "README", "data.csv", "known.txt", "notes/a.md" }, walk.paths) |want, got| try std.testing.expectEqualStrings(want, got);
    try std.testing.expectEqual(@as(usize, 2), walk.not_read.count(.bad_name));
    try std.testing.expectEqual(@as(usize, 1), walk.not_read.count(.binary));
    try std.testing.expectEqual(@as(usize, 1), walk.not_read.count(.document));
    try std.testing.expectEqual(@as(usize, 1), walk.not_read.count(.image));
    try std.testing.expectEqual(@as(usize, 5), walk.not_read.total());
}

test "S6-T23: a folder holding names with a carriage return indexes and searches; not-read files are reported by kind" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "root", .default_dir);
    var root = try tmp.dir.openDir(io, "root", .{ .iterate = true });
    defer root.close(io);
    try writeKindsFolder(root);
    try tmp.dir.createDir(io, "out", .default_dir);
    var out_dir = try tmp.dir.openDir(io, "out", .{ .iterate = true });
    defer out_dir.close(io);

    const report = try indexFolder(arena, io, root, out_dir, .v2, null, chunker.default_max_chars, chunker.default_overlap_lines, .{});
    try std.testing.expectEqual(@as(usize, 3), report.added);
    try std.testing.expectEqual(@as(usize, 0), report.unreadable);
    // `blob` by its head, `known.txt` by its bytes once read.
    try std.testing.expectEqual(@as(usize, 2), report.not_read.count(.binary));
    try std.testing.expectEqual(@as(usize, 2), report.not_read.count(.bad_name));
    try std.testing.expectEqual(@as(usize, 6), report.not_read.total());
    var json_out: std.Io.Writer.Allocating = .init(arena);
    var json = std.json.Stringify{ .writer = &json_out.writer };
    try report.not_read.writeJson(&json);
    try std.testing.expectEqualStrings("{\"bad_name\":2,\"binary\":2,\"document\":1,\"image\":1}", json_out.written());
    const opened = try snapshot_open.open(arena, io, out_dir);
    try std.testing.expectEqual(@as(usize, 3), opened.documents.len);
    // The generation names the rule; not-read files are not `skipped`.
    const manifest_bytes = try out_dir.readFileAlloc(io, "MANIFEST", arena, .unlimited);
    try std.testing.expect(std.mem.indexOf(u8, manifest_bytes, "\"readable\":{\"id\":\"text-sniff-v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest_bytes, "\"skipped\"") == null);

    // Direct search builds the same generation and the same report.
    const detached = try buildFolderDetached(arena, io, root, .v2, chunker.default_max_chars, chunker.default_overlap_lines, .{ .filename_index = true });
    try std.testing.expectEqual(@as(usize, 3), detached.report.added);
    try std.testing.expectEqual(report.not_read.counts, detached.report.not_read.counts);
}

test "S6-T23: an index built before the rule takes the newly readable files at its next update, without a rebuild" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "root", .default_dir);
    var root = try tmp.dir.openDir(io, "root", .{ .iterate = true });
    defer root.close(io);
    try writeKindsFolder(root);
    try tmp.dir.createDir(io, "out", .default_dir);
    var out_dir = try tmp.dir.openDir(io, "out", .{ .iterate = true });
    defer out_dir.close(io);

    // The generation an engine before 2.9.0 published for this folder: the
    // files of the 19 extensions (`known.txt`'s NUL is valid UTF-8, so it was
    // read; `a\rb.md` would have failed the walk and is left out here), no
    // `readable` key.
    const old_paths = [_][]const u8{ "known.txt", "notes/a.md" };
    var changes: [old_paths.len]apply.Change = undefined;
    for (old_paths, &changes) |path, *change| change.* = .{ .op = .change, .root_id = legacy_root_id, .path = path, .content = .{ .walk = .{ .dir = root, .sub_path = path } } };
    const roots = [1]apply.RootDecl{.{ .root_id = legacy_root_id, .label = "folder", .kind = "local", .retain_source = true }};
    var old_options = walkOptions(.v2, chunker.default_max_chars, chunker.default_overlap_lines, .{}, true, null);
    old_options.readable = false;
    _ = try reportOf(arena, try apply.applyBatch(arena, io, out_dir, .{ .roots = &roots, .changes = &changes }, old_options), .{});
    const old_manifest = try out_dir.readFileAlloc(io, "MANIFEST", arena, .unlimited);
    try std.testing.expect(std.mem.indexOf(u8, old_manifest, "\"readable\"") == null);
    try std.testing.expectEqual(@as(usize, 2), (try snapshot_open.open(arena, io, out_dir)).documents.len);

    const report = try indexFolderIncremental(arena, io, root, out_dir, .v2, chunker.default_max_chars, chunker.default_overlap_lines, .{});
    try std.testing.expectEqual(@as(u64, 2), report.generation);
    try std.testing.expectEqual(@as(usize, 2), report.added); // README, data.csv
    try std.testing.expectEqual(@as(usize, 1), report.unchanged); // notes/a.md
    try std.testing.expectEqual(@as(usize, 1), report.removed); // known.txt: binary now
    try std.testing.expectEqual(@as(usize, 2), report.not_read.count(.binary));
    try std.testing.expectEqual(@as(usize, 3), (try snapshot_open.open(arena, io, out_dir)).documents.len);
    const new_manifest = try out_dir.readFileAlloc(io, "MANIFEST", arena, .unlimited);
    try std.testing.expect(std.mem.indexOf(u8, new_manifest, "\"readable\":{\"id\":\"text-sniff-v1\"") != null);
}

test "isIgnoredPath skips dotfiles and ignored directories" {
    try std.testing.expect(isIgnoredPath(".git/config"));
    try std.testing.expect(isIgnoredPath("node_modules/pkg/index.js"));
    try std.testing.expect(isIgnoredPath("src/.hidden.md"));
    try std.testing.expect(!isIgnoredPath("src/main.md"));
}

test "indexFolder applies max_file_bytes cap on a full rebuild (S1-T5 criterion 1)" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;

    // A 41-byte file with a 10-byte cap should be reported too_large and
    // not indexed -- S1-T5 criterion 1 example.
    try tmp.dir.writeFile(io, .{ .sub_path = "oversized.md", .data = "123456789\n123456789\n123456789\n123456789\na" });
    try tmp.dir.createDir(io, "out", .default_dir);
    var out_dir = try tmp.dir.openDir(io, "out", .{});
    defer out_dir.close(io);

    const caps = Caps{ .max_file_bytes = 10 };
    const report = try indexFolder(arena, io, tmp.dir, out_dir, .v2, 1, chunker.default_max_chars, chunker.default_overlap_lines, caps);
    try std.testing.expectEqual(@as(usize, 0), report.added);
    try std.testing.expectEqual(@as(usize, 1), report.too_large);
    try std.testing.expectEqual(@as(usize, 1), report.too_large_paths.len);
    try std.testing.expectEqualStrings("oversized.md", report.too_large_paths[0]);
    try std.testing.expectEqual(@as(usize, 0), report.documents);

    // The generation is published but empty (0 documents), and queryable.
    const opened = try snapshot_open.open(arena, io, out_dir);
    try std.testing.expectEqual(@as(u64, 1), opened.generation);
    try std.testing.expectEqual(@as(usize, 0), opened.documents.len);
}

test "indexFolder applies max_total_bytes cap on a full rebuild (S1-T5 criterion 1 rework)" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;

    // Three ~41-byte files and a 50-byte budget: only the first (sorted by
    // path) fits, the other two are left out and counted budget_exhausted --
    // same fixture shape the round-D tester's own rejection probe used.
    try tmp.dir.writeFile(io, .{ .sub_path = "a.md", .data = "123456789\n123456789\n123456789\n123456789\na" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.md", .data = "123456789\n123456789\n123456789\n123456789\na" });
    try tmp.dir.writeFile(io, .{ .sub_path = "c.md", .data = "123456789\n123456789\n123456789\n123456789\na" });
    try tmp.dir.createDir(io, "out", .default_dir);
    var out_dir = try tmp.dir.openDir(io, "out", .{});
    defer out_dir.close(io);

    const caps = Caps{ .max_total_bytes = 50 };
    const report = try indexFolder(arena, io, tmp.dir, out_dir, .v2, 1, chunker.default_max_chars, chunker.default_overlap_lines, caps);
    try std.testing.expectEqual(@as(usize, 1), report.added);
    try std.testing.expectEqual(@as(usize, 2), report.budget_exhausted);
    try std.testing.expectEqual(@as(usize, 0), report.too_large);
    try std.testing.expectEqual(@as(usize, 1), report.documents);

    // Only the processed file's state entry is persisted -- the two left
    // over by the budget are eligible again on the next run, exactly like
    // `indexFolderIncremental`'s budget_exhausted files.
    const state = try incremental_state.load(arena, io, out_dir);
    try std.testing.expect(state != null);
    if (state) |s| try std.testing.expectEqual(@as(usize, 1), s.files.len);
}

test "full rebuild writes INDEX-STATE.json, first --update reports unchanged (S1-T5 criterion 2)" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;

    // `root` and `out_dir` are siblings, not nested (an --out directory
    // living inside the folder it indexes would see its own INDEX-STATE.json
    // as a candidate .json file to index -- a hazard for a real caller who
    // nests them, not something this test should also fall into).
    try tmp.dir.createDir(io, "notes", .default_dir);
    var root = try tmp.dir.openDir(io, "notes", .{ .iterate = true });
    defer root.close(io);
    try root.writeFile(io, .{ .sub_path = "note.md", .data = "hybrid ranking combines lexical and semantic evidence\n" });
    try tmp.dir.createDir(io, "out", .default_dir);
    var out_dir = try tmp.dir.openDir(io, "out", .{});
    defer out_dir.close(io);

    // Full rebuild (generation 1).
    const report1 = try indexFolder(arena, io, root, out_dir, .v2, 1, chunker.default_max_chars, chunker.default_overlap_lines, .{});
    try std.testing.expectEqual(@as(usize, 1), report1.added);
    try std.testing.expectEqual(@as(usize, 1), report1.documents);

    // Verify that INDEX-STATE.json was written with the correct state.
    const state = try incremental_state.load(arena, io, out_dir);
    try std.testing.expect(state != null);
    if (state) |s| {
        try std.testing.expectEqual(@as(usize, 1), s.files.len);
        try std.testing.expectEqualStrings("note.md", s.files[0].path);
    }

    // The criterion's own wording ("first --update reports unchanged"): run
    // an actual --update (indexFolderIncremental) against the same
    // directory and check it reports the file unchanged, not added --
    // round-D's test never ran this part despite its name claiming to
    // (round-D tester's Verdict, criterion 2).
    const report2 = try indexFolderIncremental(arena, io, root, out_dir, .v2, chunker.default_max_chars, chunker.default_overlap_lines, .{});
    try std.testing.expectEqual(@as(usize, 0), report2.added);
    try std.testing.expectEqual(@as(usize, 1), report2.unchanged);
    try std.testing.expectEqual(@as(u64, 2), report2.generation);
}
