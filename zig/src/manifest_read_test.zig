//! S6-T13: two readings of the code that S6-T12 filed untested
//! (`docs/tasks/S6-T13.md`).
//!
//! 1. `lifecycle.scan` over a directory whose `MANIFEST` names a documents
//!    or lexical file that is missing.
//! 2. An open that takes `MANIFEST`'s size from one `stat` and reads it
//!    after a publish replaced it. The publish is run deterministically
//!    between the `stat` and the read: the open is given a `std.Io` whose
//!    `fileStat` runs the publish right after the first `stat` it serves
//!    (`StatSeam`), which in every open below is the `stat` of `MANIFEST`.
//!    No timing is involved and the library has no seam of its own.
const std = @import("std");
const chunker = @import("chunker.zig");
const hybrid = @import("hybrid.zig");
const indexer = @import("indexer.zig");
const lexical_segment = @import("lexical_segment.zig");
const lifecycle = @import("lifecycle.zig");
const manifest = @import("manifest.zig");
const postings = @import("postings.zig");
const publication = @import("publication.zig");
const segment = @import("segment.zig");
const snapshot_open = @import("snapshot_open.zig");

/// One v1 generation's three files, encoded in memory.
const Encoded = struct {
    manifest: []const u8,
    documents: []const u8,
    lexical: []const u8,
};

/// A one-document generation `number` whose text is `text` and whose
/// manifest names the embedding model `model_id`: the model id's length is
/// how a test sets the manifest's length to the byte (the open does not read
/// the id).
fn encodeGeneration(a: std.mem.Allocator, number: u64, text: []const u8, model_id: []const u8) !Encoded {
    const documents = try a.alloc(hybrid.Document, 1);
    documents[0] = .{ .id = "one", .text = text };
    const documents_encoded = try segment.encode(documents, try a.alloc(u8, 4096));
    const terms = try a.alloc(postings.TermEntry, 16);
    const posting_storage = try a.alloc(postings.Posting, 16);
    const lengths = try a.alloc(u32, 1);
    const fills = try a.alloc(usize, 16);
    const index = try postings.build(documents, terms, posting_storage, lengths, fills);
    const lexical_encoded = try lexical_segment.encode(index, try a.alloc(u8, 4096));
    const documents_file = try std.fmt.allocPrint(a, "documents-{d}.hybseg", .{number});
    const lexical_file = try std.fmt.allocPrint(a, "lexical-{d}.hyblex", .{number});
    const metadata = try manifest.create(number, "analyzer-v2", model_id, documents_file, lexical_file, documents_encoded, lexical_encoded);
    const manifest_encoded = try manifest.encode(metadata, try a.alloc(u8, 4096));
    return .{ .manifest = manifest_encoded, .documents = documents_encoded, .lexical = lexical_encoded };
}

fn publishGeneration(dir: std.Io.Dir, io: std.Io, generation: Encoded) !void {
    try lifecycle.publishSerialized(dir, io, generation.manifest, generation.documents, generation.lexical);
}

// ---------------------------------------------------------------------------
// Reading 1: the scan.

test "S6-T13: scan returns FileNotFound when MANIFEST names a missing documents or lexical file; no MANIFEST stays no error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;

    const first = try encodeGeneration(a, 1, "alpha evidence about recovery", "none");
    const second = try encodeGeneration(a, 2, "beta evidence about recovery", "none");

    inline for (.{ "documents-2.hybseg", "lexical-2.hyblex" }) |missing| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        try publishGeneration(tmp.dir, io, first);
        try publishGeneration(tmp.dir, io, second);

        var manifest_read: [4096]u8 = undefined;
        var documents_read: [4096]u8 = undefined;
        var lexical_read: [4096]u8 = undefined;
        // Whole: generation 2 is current, generation 1 superseded.
        const whole = try lifecycle.scan(tmp.dir, io, &manifest_read, &documents_read, &lexical_read);
        try std.testing.expectEqual(@as(?u64, 2), whole.current_generation);
        try std.testing.expectEqual(@as(usize, 2), whole.current_files);
        try std.testing.expectEqual(@as(usize, 1), whole.superseded_document_files);
        try std.testing.expectEqual(@as(usize, 1), whole.superseded_lexical_files);
        try std.testing.expectEqual(@as(usize, 0), whole.orphan_document_files + whole.orphan_lexical_files);

        // The current MANIFEST's documents or lexical file is gone: the scan
        // returns the error instead of reporting a directory with no
        // MANIFEST (generation null, every section file an orphan).
        try tmp.dir.deleteFile(io, missing);
        try std.testing.expectError(error.FileNotFound, lifecycle.scan(tmp.dir, io, &manifest_read, &documents_read, &lexical_read));

        // No MANIFEST at all is still no error: no current generation, and
        // every remaining section file is an orphan.
        try tmp.dir.deleteFile(io, publication.current_manifest_file);
        const none = try lifecycle.scan(tmp.dir, io, &manifest_read, &documents_read, &lexical_read);
        try std.testing.expectEqual(@as(?u64, null), none.current_generation);
        try std.testing.expectEqual(@as(usize, 0), none.current_files);
        try std.testing.expectEqual(@as(usize, 0), none.superseded_document_files + none.superseded_lexical_files);
        try std.testing.expectEqual(@as(usize, 3), none.orphan_document_files + none.orphan_lexical_files);
    }
}

// ---------------------------------------------------------------------------
// Reading 2: the MANIFEST read during a publish.

/// A `std.Io` that serves every call from `base` and, right after the first
/// `fileStat` it serves, runs one step (a publish) through `base`.
const StatSeam = struct {
    var base: std.Io = undefined;
    var table: std.Io.VTable = undefined;
    var pending: ?Step = null;
    /// How many steps ran, the size the triggering `stat` returned, and the
    /// step's error, if any.
    var ran: usize = 0;
    var stat_size: u64 = 0;
    var step_error: ?anyerror = null;

    const Step = struct {
        context: *const anyopaque,
        run: *const fn (*const anyopaque, std.Io) anyerror!void,
    };

    fn fileStat(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.StatError!std.Io.File.Stat {
        const stat = try base.vtable.fileStat(userdata, file);
        if (pending) |step| {
            pending = null;
            ran += 1;
            stat_size = stat.size;
            step.run(step.context, base) catch |err| {
                step_error = err;
            };
        }
        return stat;
    }

    fn arm(io: std.Io, step: Step) std.Io {
        base = io;
        table = io.vtable.*;
        table.fileStat = fileStat;
        pending = step;
        ran = 0;
        stat_size = 0;
        step_error = null;
        return .{ .userdata = io.userdata, .vtable = &table };
    }

    fn expectRanAfterManifestStat(old_manifest_len: usize) !void {
        try std.testing.expectEqual(@as(usize, 1), ran);
        try std.testing.expectEqual(@as(?anyerror, null), step_error);
        try std.testing.expectEqual(@as(u64, old_manifest_len), stat_size);
    }
};

/// The step: publish `generation` into `dir`.
const PublishStep = struct {
    dir: std.Io.Dir,
    generation: Encoded,

    fn run(context: *const anyopaque, io: std.Io) anyerror!void {
        const self: *const PublishStep = @ptrCast(@alignCast(context));
        try publishGeneration(self.dir, io, self.generation);
    }

    fn step(self: *const PublishStep) StatSeam.Step {
        return .{ .context = self, .run = run };
    }
};

const Which = enum { old, new };

/// The open reads the old generation whole or the new one whole: its
/// generation number and its one document's text are one generation's.
fn whichGeneration(generation: u64, text: []const u8) !Which {
    if (generation == 1 and std.mem.eql(u8, text, old_text)) return .old;
    if (generation == 2 and std.mem.eql(u8, text, new_text)) return .new;
    std.debug.print("open gave generation {d} with text \"{s}\"\n", .{ generation, text });
    return error.TestUnexpectedResult;
}

const old_text = "alpha evidence about recovery";
const new_text = "beta evidence about recovery and more";
const old_model = "model-aaaa";

/// The bound: a new MANIFEST one byte shorter than the size the open read
/// from `stat`, the same size, and one byte longer (and a much longer one).
const deltas = [_]isize{ -1, 0, 1, 2048 };

fn newModel(a: std.mem.Allocator, delta: isize) ![]const u8 {
    const length: usize = @intCast(@as(isize, old_model.len) + delta);
    const id = try a.alloc(u8, length);
    @memset(id, 'b');
    @memcpy(id[0..6], "model-");
    return id;
}

const Opener = enum { open, open_scoped, open_source };

fn openThroughSeam(a: std.mem.Allocator, opener: Opener, delta: isize) !Which {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const old = try encodeGeneration(a, 1, old_text, old_model);
    const new = try encodeGeneration(a, 2, new_text, try newModel(a, delta));
    try std.testing.expectEqual(@as(isize, @intCast(old.manifest.len)) + delta, @as(isize, @intCast(new.manifest.len)));
    try publishGeneration(tmp.dir, io, old);

    const publish = PublishStep{ .dir = tmp.dir, .generation = new };
    const seam = StatSeam.arm(io, publish.step());
    const which: Which = switch (opener) {
        .open => blk: {
            const opened = snapshot_open.open(a, seam, tmp.dir) catch |err| {
                std.debug.print("open (new MANIFEST {d} bytes, stat said {d}): {s}\n", .{ new.manifest.len, old.manifest.len, @errorName(err) });
                return err;
            };
            break :blk try whichGeneration(opened.generation, opened.documents[0].text);
        },
        .open_scoped => blk: {
            const opened = snapshot_open.openScoped(a, seam, tmp.dir) catch |err| {
                std.debug.print("openScoped (new MANIFEST {d} bytes, stat said {d}): {s}\n", .{ new.manifest.len, old.manifest.len, @errorName(err) });
                return err;
            };
            defer snapshot_open.close(opened.engine, opened.folder);
            break :blk try whichGeneration(opened.engine.generation, opened.engine.documents[0].text);
        },
        .open_source => blk: {
            const opened = snapshot_open.openSource(a, seam, tmp.dir) catch |err| {
                std.debug.print("openSource (new MANIFEST {d} bytes, stat said {d}): {s}\n", .{ new.manifest.len, old.manifest.len, @errorName(err) });
                return err;
            };
            // A v1 generation binds no source section: the manifest is all
            // this open reads, and it must be one whole MANIFEST.
            try std.testing.expect(opened.source == null);
            const model = if (opened.metadata.generation == 1) old_model else try newModel(a, delta);
            try std.testing.expectEqualStrings(model, opened.metadata.embedding_model_id);
            break :blk if (opened.metadata.generation == 1) .old else .new;
        },
    };
    try StatSeam.expectRanAfterManifestStat(old.manifest.len);

    // The publish in the step is whole: a plain open now reads generation 2.
    const after = try snapshot_open.open(a, io, tmp.dir);
    try std.testing.expectEqual(@as(u64, 2), after.generation);
    try std.testing.expectEqualStrings(new_text, after.documents[0].text);
    return which;
}

test "S6-T13: an open whose MANIFEST is replaced between its stat and its read returns one whole generation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var line: [512]u8 = undefined;
    var used: usize = 0;
    inline for (.{ Opener.open, Opener.open_scoped, Opener.open_source }) |opener| {
        for (deltas) |delta| {
            // Either generation, whole, is right; an error is not.
            const which = openThroughSeam(a, opener, delta) catch |err| {
                std.debug.print("{s}, new MANIFEST {d} byte(s) against the stat: {s}\n", .{ @tagName(opener), delta, @errorName(err) });
                return err;
            };
            used += (try std.fmt.bufPrint(line[used..], " {s} {d}:{s}", .{ @tagName(opener), delta, @tagName(which) })).len;
        }
    }
    std.debug.print("S6-T13 MANIFEST replaced between stat and read (opener, new length - stat length: generation read):{s}\n", .{line[0..used]});
}

test "S6-T13: a folder index whose MANIFEST grows across the publish opens whole between stat and read" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "notes", .default_dir);
    var root = try tmp.dir.openDir(io, "notes", .{ .iterate = true });
    defer root.close(io);
    try tmp.dir.createDir(io, "out", .default_dir);
    var out = try tmp.dir.openDir(io, "out", .{ .iterate = true });
    defer out.close(io);

    // Generation 9, then 10 in the step: every section name in the
    // manifest gains a digit, so the new MANIFEST is longer.
    try root.writeFile(io, .{ .sub_path = "a.md", .data = "alpha evidence about recovery\n" });
    _ = try indexer.indexFolder(a, io, root, out, .v2, 9, chunker.default_max_chars, chunker.default_overlap_lines, .{});
    const old_len = (try out.statFile(io, publication.current_manifest_file, .{})).size;

    // The step: a real folder publish (`--update`) of the folder with three
    // more files.
    const FolderStep = struct {
        a: std.mem.Allocator,
        root: std.Io.Dir,
        out: std.Io.Dir,

        fn run(context: *const anyopaque, step_io: std.Io) anyerror!void {
            const self: *const @This() = @ptrCast(@alignCast(context));
            inline for (.{ "b.md", "c.md", "d.md" }) |name| {
                try self.root.writeFile(step_io, .{ .sub_path = name, .data = "beta evidence about publication and more notes\n" });
            }
            const report = try indexer.indexFolderIncremental(self.a, step_io, self.root, self.out, .v2, chunker.default_max_chars, chunker.default_overlap_lines, .{});
            if (report.generation != 10) return error.TestUnexpectedResult;
        }
    };
    const folder_step = FolderStep{ .a = a, .root = root, .out = out };
    const seam = StatSeam.arm(io, .{ .context = &folder_step, .run = FolderStep.run });
    const opened = snapshot_open.openScoped(a, seam, out) catch |err| {
        std.debug.print("openScoped (MANIFEST {d} bytes at the stat, {d} after the publish): {s}\n", .{ old_len, (try out.statFile(io, publication.current_manifest_file, .{})).size, @errorName(err) });
        return err;
    };
    defer snapshot_open.close(opened.engine, opened.folder);
    try StatSeam.expectRanAfterManifestStat(@intCast(old_len));
    const new_len = (try out.statFile(io, publication.current_manifest_file, .{})).size;
    try std.testing.expect(new_len > old_len);
    // Generation 9 (one file) or generation 10 (four files), whole.
    const whole_old = opened.engine.generation == 9 and opened.engine.documents.len == 1;
    const whole_new = opened.engine.generation == 10 and opened.engine.documents.len == 4;
    try std.testing.expect(whole_old or whole_new);
    std.debug.print("S6-T13 folder MANIFEST {d} -> {d} bytes between stat and read: generation {d} read\n", .{ old_len, new_len, opened.engine.generation });
}

test "S6-T13: a damaged MANIFEST is refused with the same error as before, by every open" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    const whole = try encodeGeneration(a, 1, old_text, old_model);

    const Damage = enum { cut, extra, flipped };
    const expected = [_]anyerror{ error.Truncated, error.TrailingData, error.ChecksumMismatch };
    inline for (.{ Damage.cut, Damage.extra, Damage.flipped }, 0..) |damage, i| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        try publishGeneration(tmp.dir, io, whole);
        const bytes: []const u8 = switch (damage) {
            .cut => whole.manifest[0 .. whole.manifest.len - 1],
            .extra => try std.mem.concat(a, u8, &.{ whole.manifest, "x" }),
            .flipped => blk: {
                const copy = try a.dupe(u8, whole.manifest);
                copy[copy.len - 1] ^= 0x01;
                break :blk copy;
            },
        };
        try tmp.dir.writeFile(io, .{ .sub_path = publication.current_manifest_file, .data = bytes });
        try std.testing.expectError(expected[i], snapshot_open.open(a, io, tmp.dir));
        try std.testing.expectError(expected[i], snapshot_open.openScoped(a, io, tmp.dir));
        try std.testing.expectError(expected[i], snapshot_open.openSource(a, io, tmp.dir));
    }
}
