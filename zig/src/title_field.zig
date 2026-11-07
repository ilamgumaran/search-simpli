//! S5-T2: the title field (`title-field-v1`, `docs/tasks/S5-T2.md` rulings 2
//! and 3). A file's root-relative folder names and its stem, tokenized with
//! analyzer-v2, one title document per file, derived in memory from the
//! record paths the documents section already holds: no section, manifest,
//! writer or format change.
//!
//! **The field of a file.** The record path's root-relative part
//! (`scope.rootOfPath` and `scope.relativePath`; a legacy-root path, or one
//! under no root, is taken whole), so the root id is never a folder word.
//! Its folder names (every component but the last), each tokenized, then the
//! stem (Python's `PurePath.stem`: the last component without its final
//! `.ext`; a name whose only dot is its first character, or that ends in its
//! only dot, is kept whole). A term's frequency counts its repeats across the
//! folders and the stem.
//!
//! **The derive** (`derive`): one pass groups the chunks into files when the
//! record paths come in order (every writer's case: files sorted by record
//! path, each file's chunks adjacent); otherwise a fallback sorts a
//! permutation of the chunks by path. File ordinals follow the order of each
//! file's first chunk in the documents. Each distinct folder is tokenized
//! once; each stem once. The postings (per term, the files that hold it, in
//! ordinal order, with the term frequency) and a term table sorted bytewise
//! (for a binary-search lookup) are built through a scratch arena released
//! before `derive` returns, then copied into one exact block from `blocks`
//! (the S4-T9 pattern), which the field points into. `lexical_build.build`
//! is not used: in an arena its per-document maps measured 14.8 MB transient
//! at 10k (the plan's bench).
const std = @import("std");
const analyzer_v2 = @import("analyzer_v2.zig");
const hybrid = @import("hybrid.zig");
const manifest = @import("manifest.zig");
const scope = @import("scope.zig");

pub const policy_id = "title-field-v1";
/// Ruling 2: the measured plateau's middle; one constant per surface
/// (`TITLE_WEIGHT` in `src/search_platform/core.py`).
pub const default_weight: f32 = 2.5;

/// One title document: the file's first chunk (smallest start line, end
/// line, id) and its title length in tokens.
pub const File = extern struct {
    first_chunk: u32,
    length: u32,
};

/// One file holding a term, with the term's frequency in its title.
pub const Posting = extern struct {
    file: u32,
    frequency: u32,
};

/// A term of the sorted term table: its bytes in `Field.term_bytes` and its
/// postings in `Field.postings` (`postings_len` is its document frequency
/// over every file).
pub const Term = extern struct {
    bytes_start: u32,
    bytes_len: u32,
    postings_start: u32,
    postings_len: u32,
};

pub const Field = struct {
    files: []const File,
    /// Each chunk's file ordinal.
    file_of: []const u32,
    postings: []const Posting,
    /// Sorted bytewise by term.
    terms: []const Term,
    term_bytes: []const u8,
    /// Sum of every file's length (the unscoped average's numerator).
    total_length: u64,

    pub fn termBytes(field: Field, term: Term) []const u8 {
        return field.term_bytes[term.bytes_start .. term.bytes_start + term.bytes_len];
    }

    pub fn termPostings(field: Field, term: Term) []const Posting {
        return field.postings[term.postings_start .. term.postings_start + term.postings_len];
    }

    /// The term table's entry for `bytes`, or null.
    pub fn lookup(field: Field, bytes: []const u8) ?Term {
        var low: usize = 0;
        var high: usize = field.terms.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            switch (std.mem.order(u8, field.termBytes(field.terms[middle]), bytes)) {
                .eq => return field.terms[middle],
                .lt => low = middle + 1,
                .gt => high = middle,
            }
        }
        return null;
    }
};

/// What the derive saw and built (the profile of ruling 9).
pub const Profile = struct {
    chunks: usize = 0,
    files: usize = 0,
    /// The one-pass grouping applied (paths in order); false: the fallback.
    in_order: bool = true,
    distinct_folders: usize = 0,
    tokens: usize = 0,
    terms: usize = 0,
    postings: usize = 0,
    /// The exact block's length: what a reader keeps.
    block_bytes: usize = 0,
};

pub const Derived = struct {
    field: Field,
    /// The one exact block the field points into, from `blocks`; release it
    /// with `deinit` through the same allocator.
    block: []align(block_alignment) u8,
    profile: Profile,

    pub fn deinit(derived: Derived, blocks: std.mem.Allocator) void {
        blocks.free(derived.block);
    }
};

const block_alignment = 8;

/// `deriveMarked` without marks.
pub const NoMarks = struct {
    pub fn mark(_: NoMarks, comptime _: []const u8) void {}
};

/// The root-relative part of a record path (ruling 2).
pub fn relativePath(roots: []const manifest.RootEntry, path: []const u8) []const u8 {
    if (scope.rootOfPath(roots, path)) |root| return scope.relativePath(roots[root], path);
    return path;
}

/// Python's `PurePath(name).stem`: `name` without its final suffix, where a
/// suffix is a last dot that is neither the first nor the last character.
pub fn pathStem(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    if (dot > 0 and dot < name.len - 1) return name[0..dot];
    return name;
}

/// The folders part (everything before the last `/`, "" for none) and the
/// stem of a root-relative path.
pub fn split(relative: []const u8) struct { folders: []const u8, stem: []const u8 } {
    const slash = std.mem.lastIndexOfScalar(u8, relative, '/');
    const name = if (slash) |s| relative[s + 1 ..] else relative;
    return .{ .folders = if (slash) |s| relative[0..s] else "", .stem = pathStem(name) };
}

fn isAscii(text: []const u8) bool {
    for (text) |c| if (c >= 0x80) return false;
    return true;
}

/// Calls `sink.add(token)` for each analyzer-v2 token of `text`, in order;
/// a token is valid only during its call.
///
/// ASCII text skips `analyzer_v2.tokenize` (its NFC pass, its codepoint list
/// and one allocation per token): on ASCII, NFC is the identity, no
/// codepoint is a mark, a joiner or a variation selector, the letters and
/// digits are exactly `[A-Za-z0-9]` and their simple casefold is
/// `std.ascii.toLower`, so the tokens are the maximal `[A-Za-z0-9]` runs,
/// lowercased. `title_field_test.zig` checks the two paths agree. Any other
/// text goes through `analyzer_v2.tokenize` in `tmp` (reset first).
fn eachToken(tmp: *std.heap.ArenaAllocator, text: []const u8, sink: anytype) !void {
    if (!isAscii(text)) {
        _ = tmp.reset(.retain_capacity);
        for (try analyzer_v2.tokenize(tmp.allocator(), text)) |token| try sink.add(token);
        return;
    }
    var buffer: [256]u8 = undefined;
    var i: usize = 0;
    while (i < text.len) {
        if (!std.ascii.isAlphanumeric(text[i])) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < text.len and std.ascii.isAlphanumeric(text[i])) i += 1;
        const run = text[start..i];
        const out = if (run.len <= buffer.len) buffer[0..run.len] else long: {
            _ = tmp.reset(.retain_capacity);
            break :long try tmp.allocator().alloc(u8, run.len);
        };
        for (run, out) |c, *o| o.* = std.ascii.toLower(c);
        try sink.add(out);
    }
}

/// `analyzer_v2.tokenize(allocator, text)`'s tokens, through `eachToken`
/// (in `allocator`, which should be an arena).
pub fn tokenizeText(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var tmp = std.heap.ArenaAllocator.init(allocator);
    defer tmp.deinit();
    var out = std.ArrayList([]const u8).empty;
    const Sink = struct {
        allocator: std.mem.Allocator,
        out: *std.ArrayList([]const u8),
        pub fn add(sink: @This(), token: []const u8) !void {
            try sink.out.append(sink.allocator, try sink.allocator.dupe(u8, token));
        }
    };
    try eachToken(&tmp, text, Sink{ .allocator = allocator, .out = &out });
    return out.toOwnedSlice(allocator);
}

/// The title tokens of one record path, folders first, then the stem (in
/// `allocator`, which should be an arena: the token slices are not freed
/// one by one).
pub fn tokens(allocator: std.mem.Allocator, roots: []const manifest.RootEntry, path: []const u8) ![][]const u8 {
    const parts = split(relativePath(roots, path));
    var out = std.ArrayList([]const u8).empty;
    if (parts.folders.len != 0) {
        var it = std.mem.splitScalar(u8, parts.folders, '/');
        while (it.next()) |folder| try out.appendSlice(allocator, try tokenizeText(allocator, folder));
    }
    try out.appendSlice(allocator, try tokenizeText(allocator, parts.stem));
    return out.toOwnedSlice(allocator);
}

/// Interns each token it is given as a term id (the key's bytes copied into
/// `allocator`, the key list and the map in `lists`) and appends the id to
/// `ids` (grown in `ids_allocator`).
const Interner = struct {
    allocator: std.mem.Allocator,
    lists: std.mem.Allocator,
    map: *std.StringHashMapUnmanaged(u32),
    keys: *std.ArrayList([]const u8),
    ids: *std.ArrayList(u32),
    ids_allocator: std.mem.Allocator,

    pub fn add(interner: Interner, token: []const u8) !void {
        const gop = try interner.map.getOrPut(interner.lists, token);
        if (!gop.found_existing) {
            errdefer interner.map.removeByPtr(gop.key_ptr);
            const key = try interner.allocator.dupe(u8, token);
            gop.key_ptr.* = key;
            gop.value_ptr.* = @intCast(interner.keys.items.len);
            try interner.keys.append(interner.lists, key);
        }
        try interner.ids.append(interner.ids_allocator, gop.value_ptr.*);
    }
};

fn anchorLess(a: hybrid.Document, b: hybrid.Document) bool {
    if (a.start_line != b.start_line) return a.start_line < b.start_line;
    if (a.end_line != b.end_line) return a.end_line < b.end_line;
    return std.mem.order(u8, a.id, b.id) == .lt;
}

pub fn derive(blocks: std.mem.Allocator, scratch_backing: std.mem.Allocator, documents: []const hybrid.Document, roots: []const manifest.RootEntry) !Derived {
    return deriveMarked(blocks, scratch_backing, documents, roots, NoMarks{});
}

/// `derive`, calling `marks.mark(name)` after each stage: `grouping`,
/// `folders`, `stems`, `postings`, `lookup` (the term table and the block).
/// `scratch` holds the derive's working arrays, each freed when its stage no
/// longer needs it and all of them before this returns (the term bytes and
/// the folders' id lists in an arena over it); `blocks` gives the one exact
/// block the field keeps.
pub fn deriveMarked(blocks: std.mem.Allocator, scratch: std.mem.Allocator, documents: []const hybrid.Document, roots: []const manifest.RootEntry, marks: anytype) !Derived {
    if (documents.len > std.math.maxInt(u32)) return error.IndexTooLarge;
    var profile = Profile{ .chunks = documents.len };
    var strings_state = std.heap.ArenaAllocator.init(scratch);
    defer strings_state.deinit();
    const strings = strings_state.allocator();
    var tmp_state = std.heap.ArenaAllocator.init(scratch);
    defer tmp_state.deinit();

    // -- grouping: file ordinals in first-chunk order, each chunk's file and
    // each file's first chunk.
    const file_of = try scratch.alloc(u32, documents.len);
    defer scratch.free(file_of);
    var first = try std.ArrayList(u32).initCapacity(scratch, documents.len);
    defer first.deinit(scratch);
    for (documents, 0..) |document, i| {
        if (i == 0 or !std.mem.eql(u8, documents[i - 1].path, document.path)) {
            if (i != 0 and std.mem.order(u8, documents[i - 1].path, document.path) == .gt) {
                profile.in_order = false;
                break;
            }
            first.appendAssumeCapacity(@intCast(i));
        } else if (anchorLess(document, documents[first.items[first.items.len - 1]])) {
            first.items[first.items.len - 1] = @intCast(i);
        }
        file_of[i] = @intCast(first.items.len - 1);
    }
    if (!profile.in_order) try groupScattered(scratch, documents, file_of, &first);
    const file_count = first.items.len;
    profile.files = file_count;
    marks.mark("grouping");

    // -- folders: each distinct folders part tokenized once, its tokens
    // interned as term ids.
    var term_keys = std.ArrayList([]const u8).empty;
    defer term_keys.deinit(scratch);
    const file_folders = try scratch.alloc([]const u32, file_count);
    defer scratch.free(file_folders);
    const stem_start = try scratch.alloc(u32, file_count + 1);
    defer scratch.free(stem_start);
    var stem_ids = std.ArrayList(u32).empty;
    defer stem_ids.deinit(scratch);
    {
        var term_ids: std.StringHashMapUnmanaged(u32) = .empty;
        defer term_ids.deinit(scratch);
        try term_ids.ensureTotalCapacity(scratch, @intCast(@min(file_count + 64, std.math.maxInt(u32) / 2)));
        try term_keys.ensureTotalCapacity(scratch, file_count + 64);
        var folder_ids: std.StringHashMapUnmanaged([]const u32) = .empty;
        defer folder_ids.deinit(scratch);
        for (first.items, file_folders) |chunk, *slot| {
            const folders = split(relativePath(roots, documents[chunk].path)).folders;
            if (folders.len == 0) {
                slot.* = &.{};
                continue;
            }
            const gop = try folder_ids.getOrPut(scratch, folders);
            if (!gop.found_existing) {
                var ids = std.ArrayList(u32).empty;
                var it = std.mem.splitScalar(u8, folders, '/');
                while (it.next()) |folder| try eachToken(&tmp_state, folder, Interner{ .allocator = strings, .lists = scratch, .map = &term_ids, .keys = &term_keys, .ids = &ids, .ids_allocator = strings });
                gop.value_ptr.* = ids.items;
            }
            slot.* = gop.value_ptr.*;
        }
        profile.distinct_folders = folder_ids.count();
        marks.mark("folders");

        // -- stems: each file's stem tokenized once.
        try stem_ids.ensureTotalCapacity(scratch, file_count * 2);
        for (first.items, 0..) |chunk, f| {
            stem_start[f] = @intCast(stem_ids.items.len);
            const stem = split(relativePath(roots, documents[chunk].path)).stem;
            try eachToken(&tmp_state, stem, Interner{ .allocator = strings, .lists = scratch, .map = &term_ids, .keys = &term_keys, .ids = &stem_ids, .ids_allocator = scratch });
        }
        stem_start[file_count] = @intCast(stem_ids.items.len);
        marks.mark("stems");
    }

    // -- postings: a counting sort of every (term, file) occurrence by term,
    // files visited in ordinal order, so each term's run is ordered by file
    // and its repeats are its frequency.
    const term_count = term_keys.items.len;
    const files_out = try scratch.alloc(File, file_count);
    defer scratch.free(files_out);
    const term_postings = try scratch.alloc([2]u32, term_count);
    defer scratch.free(term_postings);
    var postings_list = std.ArrayList(Posting).empty;
    defer postings_list.deinit(scratch);
    var total_length: u64 = 0;
    {
        const occurrences = try scratch.alloc(u32, term_count + 1);
        defer scratch.free(occurrences);
        @memset(occurrences, 0);
        for (0..file_count) |f| {
            const stem = stem_ids.items[stem_start[f]..stem_start[f + 1]];
            for (file_folders[f]) |t| occurrences[t + 1] += 1;
            for (stem) |t| occurrences[t + 1] += 1;
            const length = file_folders[f].len + stem.len;
            files_out[f] = .{ .first_chunk = first.items[f], .length = @intCast(length) };
            total_length += length;
        }
        for (1..term_count + 1) |t| occurrences[t] += occurrences[t - 1];
        const token_count: usize = occurrences[term_count];
        profile.tokens = token_count;
        const placed = try scratch.alloc(u32, token_count);
        defer scratch.free(placed);
        const cursor = try scratch.dupe(u32, occurrences[0..term_count]);
        defer scratch.free(cursor);
        for (0..file_count) |f| {
            for (file_folders[f]) |t| {
                placed[cursor[t]] = @intCast(f);
                cursor[t] += 1;
            }
            for (stem_ids.items[stem_start[f]..stem_start[f + 1]]) |t| {
                placed[cursor[t]] = @intCast(f);
                cursor[t] += 1;
            }
        }
        // Distinct (term, file) pairs: the exact postings count.
        var distinct: usize = 0;
        for (0..term_count) |t| {
            for (placed[occurrences[t]..occurrences[t + 1]], occurrences[t]..) |f, k| {
                if (k == occurrences[t] or placed[k - 1] != f) distinct += 1;
            }
        }
        try postings_list.ensureTotalCapacityPrecise(scratch, distinct);
        for (0..term_count) |t| {
            const start: u32 = @intCast(postings_list.items.len);
            for (placed[occurrences[t]..occurrences[t + 1]]) |f| {
                const items = postings_list.items;
                if (items.len > start and items[items.len - 1].file == f) {
                    items[items.len - 1].frequency += 1;
                } else {
                    postings_list.appendAssumeCapacity(.{ .file = f, .frequency = 1 });
                }
            }
            term_postings[t] = .{ start, @as(u32, @intCast(postings_list.items.len)) - start };
        }
    }
    profile.terms = term_count;
    profile.postings = postings_list.items.len;
    marks.mark("postings");

    // -- lookup: the term table sorted bytewise (by each term's first eight
    // bytes, big-endian and zero-padded, then by the whole bytes), then
    // everything copied into one exact block.
    const Keyed = struct { prefix: u64, id: u32 };
    const sorted = try scratch.alloc(Keyed, term_count);
    defer scratch.free(sorted);
    var bytes_total: usize = 0;
    for (sorted, term_keys.items, 0..) |*slot, key, i| {
        var head_bytes: [8]u8 = @splat(0);
        const n = @min(key.len, head_bytes.len);
        @memcpy(head_bytes[0..n], key[0..n]);
        slot.* = .{ .prefix = std.mem.readInt(u64, &head_bytes, .big), .id = @intCast(i) };
        bytes_total += key.len;
    }
    std.sort.pdq(Keyed, sorted, @as([]const []const u8, term_keys.items), struct {
        fn less(keys: []const []const u8, a: Keyed, b: Keyed) bool {
            if (a.prefix != b.prefix) return a.prefix < b.prefix;
            return std.mem.order(u8, keys[a.id], keys[b.id]) == .lt;
        }
    }.less);
    if (bytes_total > std.math.maxInt(u32) or postings_list.items.len > std.math.maxInt(u32)) return error.IndexTooLarge;
    const alignment = block_alignment;
    const block_len = file_count * @sizeOf(File) + documents.len * @sizeOf(u32) + postings_list.items.len * @sizeOf(Posting) +
        term_count * @sizeOf(Term) + bytes_total + 5 * alignment;
    const block = try blocks.alignedAlloc(u8, .fromByteUnits(alignment), block_len);
    errdefer blocks.free(block);
    var fixed = std.heap.FixedBufferAllocator.init(block);
    const fa = fixed.allocator();
    const kept_files = fa.dupe(File, files_out) catch unreachable;
    const kept_file_of = fa.dupe(u32, file_of) catch unreachable;
    const kept_postings = fa.dupe(Posting, postings_list.items) catch unreachable;
    const kept_terms = fa.alloc(Term, term_count) catch unreachable;
    const kept_bytes = fa.alloc(u8, bytes_total) catch unreachable;
    var at: u32 = 0;
    for (sorted, kept_terms) |keyed, *entry| {
        const key = term_keys.items[keyed.id];
        @memcpy(kept_bytes[at .. at + key.len], key);
        entry.* = .{ .bytes_start = at, .bytes_len = @intCast(key.len), .postings_start = term_postings[keyed.id][0], .postings_len = term_postings[keyed.id][1] };
        at += @intCast(key.len);
    }
    profile.block_bytes = block.len;
    marks.mark("lookup");
    return .{
        .field = .{ .files = kept_files, .file_of = kept_file_of, .postings = kept_postings, .terms = kept_terms, .term_bytes = kept_bytes, .total_length = total_length },
        .block = block,
        .profile = profile,
    };
}

/// The fallback grouping, for documents whose record paths are not in
/// order: a permutation sorted by path (ties by chunk order), grouped; each
/// group's ordinal is the rank of its earliest chunk, its first chunk the
/// `anchorLess` least. Fills `file_of` and `first` (cleared first).
fn groupScattered(scratch: std.mem.Allocator, documents: []const hybrid.Document, file_of: []u32, first: *std.ArrayList(u32)) !void {
    first.clearRetainingCapacity();
    const order = try scratch.alloc(u32, documents.len);
    defer scratch.free(order);
    for (order, 0..) |*slot, i| slot.* = @intCast(i);
    std.sort.pdq(u32, order, documents, struct {
        fn less(docs: []const hybrid.Document, a: u32, b: u32) bool {
            return switch (std.mem.order(u8, docs[a].path, docs[b].path)) {
                .lt => true,
                .gt => false,
                .eq => a < b,
            };
        }
    }.less);
    const Group = struct { earliest: u32, start: u32, end: u32 };
    var groups = std.ArrayList(Group).empty;
    defer groups.deinit(scratch);
    var k: usize = 0;
    while (k < order.len) {
        const start = k;
        while (k < order.len and std.mem.eql(u8, documents[order[k]].path, documents[order[start]].path)) k += 1;
        try groups.append(scratch, .{ .earliest = order[start], .start = @intCast(start), .end = @intCast(k) });
    }
    std.sort.pdq(Group, groups.items, {}, struct {
        fn less(_: void, a: Group, b: Group) bool {
            return a.earliest < b.earliest;
        }
    }.less);
    for (groups.items, 0..) |g, ordinal| {
        var anchor = order[g.start];
        for (order[g.start..g.end]) |chunk| {
            file_of[chunk] = @intCast(ordinal);
            if (anchorLess(documents[chunk], documents[anchor])) anchor = chunk;
        }
        first.appendAssumeCapacity(anchor);
    }
}
