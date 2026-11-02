//! Roots, request scope and visible-scope statistics (S3-T3, CAP-19 FR-19,
//! `docs/folder-knowledge-implementation.md` sections 5 and 7,
//! `docs/authorization.md`).
//!
//! **Roots and record paths.** A generation names its roots in the manifest's
//! `meta.roots`. A document record's `path` is root-qualified,
//! `root_id + "/" + relative`, for every root except the legacy folder root
//! `r-legacy`, whose records keep the bare relative path they had before S3
//! (so every index written by `index_folder`, its chunk ids and every
//! citation a consumer already stores stay byte-for-byte the same). A
//! record's root is the root whose `root_id/` prefixes its path, else the
//! legacy root when the generation has one. `apply.zig` refuses any batch
//! that would make a legacy path's first component equal another root's id,
//! so the rule is never ambiguous.
//!
//! **Scope.** A request's scope is the roots it names (default all) that the
//! caller's trusted `principal_labels` satisfy (a root's `required_labels`),
//! intersected with each document's own required labels (records carry the
//! union of the root's and the file's labels). It is applied before any chunk
//! becomes a candidate (`hybrid.inScope`) and gates every read, list and
//! status operation (`service.zig`).
//!
//! **Statistics.** BM25's document count, average length and document
//! frequencies are computed over the visible scope. `Statistics.build`
//! precomputes, once per opened generation, one group per (root, distinct
//! label set) with its document count, total length and per-term document
//! frequency; a root with more than 64 distinct label sets has no groups and
//! its documents are counted exactly at query time. When every document is
//! visible the index's own values are used, so an unscoped query scores
//! exactly as before.
const std = @import("std");
const hybrid = @import("hybrid.zig");
const manifest = @import("manifest.zig");
const postings = @import("postings.zig");
const scoring = @import("scoring.zig");
const source = @import("source.zig");
const lexical_segment = @import("lexical_segment.zig");

pub const legacy_root_id = "r-legacy";
/// The root ordinal of a document whose path matches no root.
pub const no_root: u16 = std.math.maxInt(u16);
/// Distinct label sets per root that get precomputed statistics (section 7).
pub const max_label_sets_per_root: usize = 64;

/// The roots of a generation without `meta` (a v1 manifest, or an
/// `import-json` generation): one legacy folder root.
pub const legacy_roots = [_]manifest.RootEntry{.{ .root_id = legacy_root_id, .label = "folder", .kind = "local", .retain_source = true, .origin = "folder" }};

pub fn isLegacy(root_id: []const u8) bool {
    return std.mem.eql(u8, root_id, legacy_root_id);
}

/// The record path of `relative` in root `root_id` (owned by `allocator`).
pub fn recordPath(allocator: std.mem.Allocator, root_id: []const u8, relative: []const u8) ![]const u8 {
    if (isLegacy(root_id)) return allocator.dupe(u8, relative);
    return std.mem.concat(allocator, u8, &.{ root_id, "/", relative });
}

/// The ordinal in `roots` of the root a record path belongs to, or null.
pub fn rootOfPath(roots: []const manifest.RootEntry, path: []const u8) ?u16 {
    var legacy: ?u16 = null;
    for (roots, 0..) |root, index| {
        if (isLegacy(root.root_id)) {
            legacy = @intCast(index);
            continue;
        }
        if (path.len > root.root_id.len and std.mem.startsWith(u8, path, root.root_id) and path[root.root_id.len] == '/')
            return @intCast(index);
    }
    return legacy;
}

/// The root-relative part of a record path of `root`.
pub fn relativePath(root: manifest.RootEntry, path: []const u8) []const u8 {
    if (isLegacy(root.root_id)) return path;
    return path[root.root_id.len + 1 ..];
}

/// The canonical newline-separated label field of `a ∪ b` (sorted, no
/// duplicates), owned by `allocator`.
pub fn packLabels(allocator: std.mem.Allocator, a: []const []const u8, b: []const []const u8) ![]const u8 {
    if (a.len + b.len == 0) return "";
    const all = try allocator.alloc([]const u8, a.len + b.len);
    defer allocator.free(all);
    @memcpy(all[0..a.len], a);
    @memcpy(all[a.len..], b);
    std.mem.sort([]const u8, all, {}, lessThanBytes);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (all, 0..) |label, index| {
        if (index > 0 and std.mem.eql(u8, all[index - 1], label)) continue;
        if (out.items.len > 0) try out.append(allocator, '\n');
        try out.appendSlice(allocator, label);
    }
    return out.toOwnedSlice(allocator);
}

fn lessThanBytes(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// The labels of `packed` (a canonical field) that `root_labels` does not
/// already require: a file's own labels, recovered from its records.
pub fn fileLabels(allocator: std.mem.Allocator, packed_labels: []const u8, root_labels: []const []const u8) ![]const []const u8 {
    if (packed_labels.len == 0) return &.{};
    var out = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, packed_labels, '\n');
    outer: while (it.next()) |label| {
        for (root_labels) |root_label| if (std.mem.eql(u8, root_label, label)) continue :outer;
        try out.append(allocator, label);
    }
    return out.toOwnedSlice(allocator);
}

/// Whether `principal_labels` holds every label in `required`.
pub fn holdsAll(required: []const []const u8, principal_labels: []const []const u8) bool {
    outer: for (required) |label| {
        for (principal_labels) |held| if (std.mem.eql(u8, held, label)) continue :outer;
        return false;
    }
    return true;
}

/// A request's scope as the trusted caller states it (never from a model or
/// a request body: CAP-13, `docs/authorization.md`).
pub const Request = struct {
    /// Root ids to search; null = every root. An unknown id names nothing,
    /// exactly like a root the caller may not see.
    roots: ?[]const []const u8 = null,
    principal_labels: []const []const u8 = &.{},
};

/// Per-generation statistics groups (section 7).
pub const Statistics = struct {
    pub const exact: u32 = std.math.maxInt(u32);

    pub const Group = struct {
        root: u16,
        /// The documents' canonical label field (a slice of a record).
        labels: []const u8,
        documents: u32 = 0,
        total_length: u64 = 0,
    };

    /// Group of each document, or `exact` (its root has more than 64 label
    /// sets, or it belongs to no root).
    document_groups: []const u32,
    groups: []const Group,
    term_count: usize,
    /// `groups.len * term_count` document frequencies, group-major.
    frequencies: []const u32,
    /// Documents counted exactly at query time (group `exact`), ascending.
    exact_documents: []const u32,
    /// Roots that fell back to exact counting.
    exact_roots: []const bool,

    pub fn build(
        allocator: std.mem.Allocator,
        documents: []const hybrid.Document,
        document_roots: []const u16,
        root_count: usize,
        index: postings.Index,
    ) !Statistics {
        std.debug.assert(document_roots.len == documents.len);
        const per_root = try allocator.alloc(std.StringHashMapUnmanaged(u32), root_count);
        defer {
            for (per_root) |*map| map.deinit(allocator);
            allocator.free(per_root);
        }
        for (per_root) |*map| map.* = .empty;
        for (documents, document_roots) |document, root| {
            if (root >= root_count) continue;
            if (per_root[root].count() > max_label_sets_per_root) continue;
            _ = try per_root[root].getOrPut(allocator, document.required_labels);
        }
        const exact_roots = try allocator.alloc(bool, root_count);
        for (per_root, exact_roots) |map, *flag| flag.* = map.count() > max_label_sets_per_root;

        var groups = std.ArrayList(Group).empty;
        for (per_root, 0..) |*map, root| {
            if (exact_roots[root]) continue;
            var it = map.iterator();
            while (it.next()) |entry| entry.value_ptr.* = exact; // assigned in document order below
        }
        const document_groups = try allocator.alloc(u32, documents.len);
        var exact_documents = std.ArrayList(u32).empty;
        for (documents, document_roots, 0..) |document, root, document_index| {
            if (root >= root_count or exact_roots[root]) {
                document_groups[document_index] = exact;
                try exact_documents.append(allocator, @intCast(document_index));
                continue;
            }
            const slot = per_root[root].getPtr(document.required_labels).?;
            if (slot.* == exact) {
                slot.* = @intCast(groups.items.len);
                try groups.append(allocator, .{ .root = root, .labels = document.required_labels });
            }
            const group = &groups.items[slot.*];
            group.documents += 1;
            group.total_length += index.document_lengths[document_index];
            document_groups[document_index] = slot.*;
        }
        const term_count = index.terms.len;
        const frequencies = try allocator.alloc(u32, groups.items.len * term_count);
        @memset(frequencies, 0);
        for (index.terms, 0..) |entry, term_index| {
            for (index.postings[entry.postings_start .. entry.postings_start + entry.postings_length]) |posting| {
                const group = document_groups[posting.document_index];
                if (group != exact) frequencies[@as(usize, group) * term_count + term_index] += 1;
            }
        }
        return .{
            .document_groups = document_groups,
            .groups = try groups.toOwnedSlice(allocator),
            .term_count = term_count,
            .frequencies = frequencies,
            .exact_documents = try exact_documents.toOwnedSlice(allocator),
            .exact_roots = exact_roots,
        };
    }

    fn groupVisible(statistics: Statistics, group: usize, mask: ?hybrid.RootMask, labels: []const []const u8) bool {
        const value = statistics.groups[group];
        if (mask) |m| if (value.root >= m.allowed.len or !m.allowed[value.root]) return false;
        return hybrid.isAuthorized(value.labels, labels);
    }
};

/// What BM25 divides by for one request, when its scope hides at least one
/// document; `visibleCollection` returns null when nothing is hidden.
pub const View = struct {
    collection: scoring.CollectionStatistics,
    statistics: ?*const Statistics,
    mask: ?hybrid.RootMask,
    labels: []const []const u8,
    /// Group visibility, when `statistics` is set (owned by the allocator
    /// passed to `visibleCollection`; free with `deinit`).
    visible_groups: []bool = &.{},

    pub fn deinit(view: *View, allocator: std.mem.Allocator) void {
        allocator.free(view.visible_groups);
        view.visible_groups = &.{};
    }
};

fn documentVisible(documents: []const hybrid.Document, document_index: usize, mask: ?hybrid.RootMask, labels: []const []const u8) bool {
    if (mask) |m| if (!m.allows(document_index)) return false;
    return hybrid.isAuthorized(documents[document_index].required_labels, labels);
}

/// The visible scope's collection statistics, or null when every document is
/// visible (the caller then uses the index's own values, bit for bit).
/// `labeled_documents == false` (no record carries a label) with no root
/// mask is known to hide nothing without looking at any document.
pub fn visibleCollection(
    allocator: std.mem.Allocator,
    index: postings.Index,
    documents: []const hybrid.Document,
    statistics: ?*const Statistics,
    labeled_documents: ?bool,
    mask: ?hybrid.RootMask,
    labels: []const []const u8,
) !?View {
    if (mask == null and labeled_documents != null and !labeled_documents.?) return null;
    var count: u64 = 0;
    var total: u64 = 0;
    var visible_groups: []bool = &.{};
    errdefer allocator.free(visible_groups);
    if (statistics) |stats| {
        visible_groups = try allocator.alloc(bool, stats.groups.len);
        for (stats.groups, visible_groups, 0..) |group, *flag, group_index| {
            flag.* = stats.groupVisible(group_index, mask, labels);
            if (flag.*) {
                count += group.documents;
                total += group.total_length;
            }
        }
        for (stats.exact_documents) |document_index| {
            if (documentVisible(documents, document_index, mask, labels)) {
                count += 1;
                total += index.document_lengths[document_index];
            }
        }
    } else {
        for (documents, 0..) |_, document_index| {
            if (documentVisible(documents, document_index, mask, labels)) {
                count += 1;
                total += index.document_lengths[document_index];
            }
        }
    }
    if (count == documents.len) {
        allocator.free(visible_groups);
        return null;
    }
    const average: f32 = if (count == 0) 0 else @as(f32, @floatFromInt(total)) / @as(f32, @floatFromInt(count));
    return .{
        .collection = .{ .document_count = @intCast(count), .average_document_length = average },
        .statistics = statistics,
        .mask = mask,
        .labels = labels,
        .visible_groups = visible_groups,
    };
}

/// The position of `entry` in `index.terms` (postings are laid out in term
/// order, so `postings_start` is strictly increasing), or null.
pub fn termIndex(index: postings.Index, entry: postings.TermEntry) ?usize {
    var low: usize = 0;
    var high: usize = index.terms.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const start = index.terms[middle].postings_start;
        if (start == entry.postings_start) {
            return if (index.terms[middle].postings_length == entry.postings_length) middle else null;
        }
        if (start < entry.postings_start) low = middle + 1 else high = middle;
    }
    return null;
}

/// `entry`'s document frequency within the view's scope.
pub fn documentFrequency(view: View, index: postings.Index, documents: []const hybrid.Document, entry: postings.TermEntry) u32 {
    const list = index.postings[entry.postings_start .. entry.postings_start + entry.postings_length];
    if (view.statistics) |stats| {
        if (termIndex(index, entry)) |term_index| {
            var frequency: u32 = 0;
            for (view.visible_groups, 0..) |visible, group| {
                if (visible) frequency += stats.frequencies[group * stats.term_count + term_index];
            }
            if (stats.exact_documents.len != 0) {
                for (list) |posting| {
                    if (stats.document_groups[posting.document_index] == Statistics.exact and
                        documentVisible(documents, posting.document_index, view.mask, view.labels)) frequency += 1;
                }
            }
            return frequency;
        }
    }
    var frequency: u32 = 0;
    for (list) |posting| {
        if (documentVisible(documents, posting.document_index, view.mask, view.labels)) frequency += 1;
    }
    return frequency;
}

/// S4-T1: what a scoped open defers to first use, once per opened
/// generation (`docs/tasks/S4-T1.md` ruling 1, `ss_open` in
/// `zig/include/search_simpli.h`): the
/// source section (read, checked against the manifest and indexed at the
/// first operation that reads it), the per-root statistics groups (at the
/// first scored query) and the position tables (with the walk over the
/// lexical section's positions and offsets that validates them, at the
/// first `find`). Each load runs under `mutex`: a second caller during a
/// load waits for it and never loads twice; afterwards a load is one atomic
/// read. Everything a load allocates comes from `allocator` (the opened
/// generation's; touched only under `mutex` after the open).
pub const Loads = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    documents: []const hybrid.Document,
    index: postings.Index,
    document_roots: []const u16 = &.{},
    root_count: usize = 0,

    /// The bound source section's file, opened (not read) at open time so
    /// a later load reads the generation's own bytes even after a writer
    /// pruned the file; null when none is bound or it could not be opened.
    source_file: ?std.Io.File = null,
    /// The manifest's length and checksum of the source section.
    source_bytes: usize = 0,
    source_checksum: u64 = 0,
    /// The manifest's `xxh3_sections` flag (v2.1, S4-T1).
    xxh3_sections: bool = false,
    source_done: std.atomic.Value(bool) = .init(false),
    source: ?source.Section = null,
    /// The bound source section could not be read or did not validate (a
    /// lost file, a wrong size, a bad checksum): the error's name.
    source_error: ?[]const u8 = null,

    statistics_done: std.atomic.Value(bool) = .init(false),
    statistics: Statistics = undefined,

    positions_done: std.atomic.Value(bool) = .init(false),
    position_tables: ?postings.PositionTables = null,
    positions_error: ?anyerror = null,

    /// How many times each load ran (each at most once; tests read them).
    source_loads: u32 = 0,
    statistics_loads: u32 = 0,
    positions_loads: u32 = 0,

    fn lock(loads: *Loads) void {
        loads.mutex.lockUncancelable(loads.io);
    }

    fn unlock(loads: *Loads) void {
        loads.mutex.unlock(loads.io);
    }

    /// Out of memory leaves the section unloaded (a later call retries);
    /// every other outcome is final for this opened generation.
    fn loadSource(loads: *Loads) error{OutOfMemory}!void {
        loads.source_loads += 1;
        loads.source_error = try loads.readSource();
        loads.source_done.store(true, .release);
    }

    fn readSource(loads: *Loads) error{OutOfMemory}!?[]const u8 {
        if (loads.source_error) |name| return name; // the open could not open the file
        const file = loads.source_file orelse return null;
        const buffer = try loads.allocator.alloc(u8, loads.source_bytes);
        const read = file.readPositionalAll(loads.io, buffer, 0) catch |err| return @errorName(err);
        if (read != loads.source_bytes) return "SourceSectionSizeMismatch";
        // The checksum is computed once, by `openIndexed`'s header check,
        // and must equal the manifest's (`manifest.validateSource`'s rule).
        const section = source.openIndexed(loads.allocator, buffer) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return @errorName(err),
        };
        if (section.checksum != loads.source_checksum) return "SourceSectionChecksumMismatch";
        if (!loads.xxh3_sections and section.checksum_kind != .fnv1a64) return "InvalidSourceSection";
        loads.source = section;
        return null;
    }
};

/// What `index_status` says about the source section (contract 2.1.0,
/// field `source`), without loading it.
pub const SourceState = enum {
    /// The generation binds no source section.
    absent,
    /// Bound, not yet read: nothing has checked its bytes.
    unverified,
    /// Read and validated.
    verified,
    /// Bound but lost or damaged: `read_span`/`outline` answer `CAPACITY`.
    unavailable,

    pub fn label(state: SourceState) []const u8 {
        return @tagName(state);
    }
};

/// A generation's roots, pending and unchunked files, chunkers, source
/// section and statistics: everything a scoped operation needs beside the
/// engine. Built once per opened generation (`snapshot_open.openScoped`);
/// the source section, the statistics and the position tables load at
/// first use (`Loads`, S4-T1).
pub const Folder = struct {
    roots: []const manifest.RootEntry,
    pending: []const manifest.PendingEntry = &.{},
    unchunked: []const manifest.PendingEntry = &.{},
    skipped: []const manifest.PendingEntry = &.{},
    chunkers: []const manifest.ChunkerEntry = &.{},
    document_roots: []const u16,
    has_positions: bool = false,
    /// The manifest binds a source section.
    source_bound: bool = false,
    loads: *Loads,

    /// `meta == null`: a generation without meta (one legacy root).
    /// `loads` holds the engine's documents and index and, when the
    /// manifest binds one, the source section's file, length and checksum.
    pub fn build(
        allocator: std.mem.Allocator,
        meta: ?manifest.Meta,
        loads: *Loads,
    ) !Folder {
        const roots: []const manifest.RootEntry = if (meta) |m| m.roots else &legacy_roots;
        const documents = loads.documents;
        const document_roots = try allocator.alloc(u16, documents.len);
        for (documents, document_roots) |document, *root| root.* = rootOfPath(roots, document.path) orelse no_root;
        loads.document_roots = document_roots;
        loads.root_count = roots.len;
        return .{
            .roots = roots,
            .pending = if (meta) |m| m.pending else &.{},
            .unchunked = if (meta) |m| m.unchunked else &.{},
            .skipped = if (meta) |m| m.skipped else &.{},
            .chunkers = if (meta) |m| m.chunkers else &.{},
            .document_roots = document_roots,
            .loads = loads,
        };
    }

    /// Release what the open kept (the source section's file handle).
    pub fn close(folder: Folder) void {
        const loads = folder.loads;
        loads.lock();
        defer loads.unlock();
        if (loads.source_file) |file| file.close(loads.io);
        loads.source_file = null;
    }

    /// The source section's state, without loading it.
    pub fn sourceState(folder: Folder) SourceState {
        if (!folder.source_bound) return .absent;
        const loads = folder.loads;
        if (!loads.source_done.load(.acquire)) return .unverified;
        return if (loads.source != null) .verified else .unavailable;
    }

    /// The source section, loaded and validated at the first call; null
    /// when none is bound or it is lost or damaged (`sourceError` names why).
    pub fn sourceSection(folder: Folder) error{OutOfMemory}!?source.Section {
        const loads = folder.loads;
        if (!loads.source_done.load(.acquire)) {
            loads.lock();
            defer loads.unlock();
            if (!loads.source_done.load(.monotonic)) try loads.loadSource();
        }
        return loads.source;
    }

    /// Why a bound source section is unavailable, once a load has tried.
    pub fn sourceError(folder: Folder) ?[]const u8 {
        const loads = folder.loads;
        if (!loads.source_done.load(.acquire)) return null;
        return loads.source_error;
    }

    /// The statistics groups when a scored query has built them, else null
    /// (a caller that does not score counts exactly, with equal results).
    pub fn loadedStatistics(folder: Folder) ?*const Statistics {
        const loads = folder.loads;
        return if (loads.statistics_done.load(.acquire)) &loads.statistics else null;
    }

    /// The statistics groups, built at the first call.
    pub fn statistics(folder: Folder) error{OutOfMemory}!*const Statistics {
        const loads = folder.loads;
        if (!loads.statistics_done.load(.acquire)) {
            loads.lock();
            defer loads.unlock();
            if (!loads.statistics_done.load(.monotonic)) {
                loads.statistics_loads += 1;
                loads.statistics = try Statistics.build(loads.allocator, loads.documents, loads.document_roots, loads.root_count, loads.index);
                loads.statistics_done.store(true, .release);
            }
        }
        return &loads.statistics;
    }

    /// The position tables of a `HYBLEX02` generation (null without
    /// positions), built at the first call after validating the lexical
    /// section's positions and offsets; a damaged section fails this and
    /// every later call with the same error.
    pub fn positionTables(folder: Folder) !?postings.PositionTables {
        const loads = folder.loads;
        if (loads.index.positions == null) return null;
        if (!loads.positions_done.load(.acquire)) {
            loads.lock();
            defer loads.unlock();
            if (!loads.positions_done.load(.monotonic)) {
                loads.positions_loads += 1;
                if (lexical_segment.validatePositionSections(loads.index)) {
                    loads.position_tables = try postings.buildPositionTables(loads.allocator, loads.index);
                } else |err| {
                    loads.positions_error = err;
                }
                loads.positions_done.store(true, .release);
            }
        }
        if (loads.positions_error) |err| return err;
        return loads.position_tables;
    }

    pub fn rootIndex(folder: Folder, root_id: []const u8) ?u16 {
        for (folder.roots, 0..) |root, index| if (std.mem.eql(u8, root.root_id, root_id)) return @intCast(index);
        return null;
    }

    /// Which roots `request` may see: named (or all) and their
    /// `required_labels` held. Owned by `allocator`.
    pub fn allowedRoots(folder: Folder, allocator: std.mem.Allocator, request: Request) ![]bool {
        const allowed = try allocator.alloc(bool, folder.roots.len);
        for (folder.roots, allowed) |root, *flag| {
            var named = request.roots == null;
            if (request.roots) |ids| {
                for (ids) |id| if (std.mem.eql(u8, id, root.root_id)) {
                    named = true;
                };
            }
            flag.* = named and holdsAll(root.required_labels, request.principal_labels);
        }
        return allowed;
    }

    /// The root mask for `request` (`allowed` from `allowedRoots`).
    pub fn mask(folder: Folder, allowed: []const bool) hybrid.RootMask {
        return .{ .document_roots = folder.document_roots, .allowed = allowed };
    }

    /// The ordinal of the root `root_id` when `request` may see it.
    pub fn visibleRoot(folder: Folder, allowed: []const bool, root_id: []const u8) ?u16 {
        const index = folder.rootIndex(root_id) orelse return null;
        return if (allowed[index]) index else null;
    }
};

test "record paths, root lookup and the legacy root" {
    const roots = [_]manifest.RootEntry{
        .{ .root_id = "school", .label = "School", .kind = "icloud", .retain_source = true },
        .{ .root_id = legacy_root_id, .label = "folder", .kind = "local", .retain_source = true },
        .{ .root_id = "home", .label = "Home", .kind = "host", .retain_source = true },
    };
    try std.testing.expectEqual(@as(?u16, 0), rootOfPath(&roots, "school/week.md"));
    try std.testing.expectEqual(@as(?u16, 2), rootOfPath(&roots, "home/a/b.md"));
    try std.testing.expectEqual(@as(?u16, 1), rootOfPath(&roots, "schoolwork/x.md"));
    try std.testing.expectEqual(@as(?u16, 1), rootOfPath(&roots, "notes.md"));
    try std.testing.expectEqual(@as(?u16, null), rootOfPath(roots[0..1], "notes.md"));
    try std.testing.expectEqualStrings("week.md", relativePath(roots[0], "school/week.md"));
    try std.testing.expectEqualStrings("notes.md", relativePath(roots[1], "notes.md"));
    const arena_state = std.testing.allocator;
    const qualified = try recordPath(arena_state, "home", "a.md");
    defer arena_state.free(qualified);
    try std.testing.expectEqualStrings("home/a.md", qualified);
    const bare = try recordPath(arena_state, legacy_root_id, "a.md");
    defer arena_state.free(bare);
    try std.testing.expectEqualStrings("a.md", bare);
}

test "labels pack as a sorted union and split back against the root" {
    const allocator = std.testing.allocator;
    const packed_labels = try packLabels(allocator, &.{ "family", "cloud-ok" }, &.{ "cloud-ok", "adults" });
    defer allocator.free(packed_labels);
    try std.testing.expectEqualStrings("adults\ncloud-ok\nfamily", packed_labels);
    const own = try fileLabels(allocator, packed_labels, &.{"cloud-ok"});
    defer allocator.free(own);
    try std.testing.expectEqual(@as(usize, 2), own.len);
    try std.testing.expectEqualStrings("adults", own[0]);
    try std.testing.expect(holdsAll(&.{ "a", "b" }, &.{ "b", "c", "a" }));
    try std.testing.expect(!holdsAll(&.{ "a", "d" }, &.{ "b", "c", "a" }));
}
