//! S6-T13 verifier's tests (scratch copies only; not part of the branch).
//!
//! A. Every interleaving: the open is given a `std.Io` that counts its file
//!    operations (open, stat by handle or by name, positional read, close,
//!    `operate`) and runs one step through the real `Io` right before the
//!    k-th of them, for every k until the open finishes before the k-th.
//!    Step "publish": generation 2 published (new MANIFEST -1, 0, +1 bytes
//!    against the old). The open must return generation 1 whole or
//!    generation 2 whole at every k. Step "publish+prune": the same, then
//!    generation 1's two section files deleted (what keep_generations=1 does
//!    after a publish): outcomes printed per k, not asserted (the
//!    comparison with `main` is the point).
//! B. MANIFEST cut in place by one byte between the open's stat and its
//!    read: `Truncated`, as on `main`.
//! C. MANIFEST grown in place by one byte between the stat and the read:
//!    generation 1 whole, as on `main` (the stat's length is read).
//! D. MANIFEST empty, one byte, and a directory: the same errors as `main`.
//! E. scan over a damaged MANIFEST and over a section whose checksum does
//!    not match: the same errors as `main`.
const std = @import("std");
const hybrid = @import("hybrid.zig");
const lexical_segment = @import("lexical_segment.zig");
const lifecycle = @import("lifecycle.zig");
const manifest = @import("manifest.zig");
const postings = @import("postings.zig");
const publication = @import("publication.zig");
const segment = @import("segment.zig");
const snapshot_open = @import("snapshot_open.zig");

const Encoded = struct { manifest: []const u8, documents: []const u8, lexical: []const u8 };

fn encode(a: std.mem.Allocator, number: u64, text: []const u8, model_id: []const u8) !Encoded {
    const documents = try a.alloc(hybrid.Document, 1);
    documents[0] = .{ .id = "one", .text = text };
    const documents_encoded = try segment.encode(documents, try a.alloc(u8, 4096));
    const index = try postings.build(documents, try a.alloc(postings.TermEntry, 16), try a.alloc(postings.Posting, 16), try a.alloc(u32, 1), try a.alloc(usize, 16));
    const lexical_encoded = try lexical_segment.encode(index, try a.alloc(u8, 4096));
    const documents_file = try std.fmt.allocPrint(a, "documents-{d}.hybseg", .{number});
    const lexical_file = try std.fmt.allocPrint(a, "lexical-{d}.hyblex", .{number});
    const metadata = try manifest.create(number, "analyzer-v2", model_id, documents_file, lexical_file, documents_encoded, lexical_encoded);
    return .{ .manifest = try manifest.encode(metadata, try a.alloc(u8, 4096)), .documents = documents_encoded, .lexical = lexical_encoded };
}

fn publish(dir: std.Io.Dir, io: std.Io, g: Encoded) !void {
    try lifecycle.publishSerialized(dir, io, g.manifest, g.documents, g.lexical);
}

const text1 = "kestrel lantern harbour";
const text2 = "quillon meadow ferry and more";
const model1 = "vmodel-aaaaaa";

fn model2(a: std.mem.Allocator, delta: isize) ![]const u8 {
    const id = try a.alloc(u8, @intCast(@as(isize, model1.len) + delta));
    @memset(id, 'z');
    @memcpy(id[0..7], "vmodel-");
    return id;
}

const StepKind = enum { publish, publish_prune, cut_in_place, grow_in_place };

/// The counting seam.
const Seam = struct {
    var base: std.Io = undefined;
    var table: std.Io.VTable = undefined;
    var count: usize = 0;
    var at: usize = 0;
    var ran: bool = false;
    var step_error: ?anyerror = null;
    var kind: StepKind = .publish;
    var dir: std.Io.Dir = undefined;
    var new: Encoded = undefined;

    fn tick() void {
        if (!ran and count == at) {
            ran = true;
            runStep() catch |err| {
                step_error = err;
            };
        }
        count += 1;
    }

    fn runStep() !void {
        switch (kind) {
            .publish => try publish(dir, base, new),
            .publish_prune => {
                try publish(dir, base, new);
                try dir.deleteFile(base, "documents-1.hybseg");
                try dir.deleteFile(base, "lexical-1.hyblex");
            },
            .cut_in_place, .grow_in_place => {
                var buffer: [4096]u8 = undefined;
                const old = try dir.readFile(base, publication.current_manifest_file, &buffer);
                const f = try dir.openFile(base, publication.current_manifest_file, .{ .mode = .read_write });
                defer f.close(base);
                if (kind == .cut_in_place) {
                    try f.setLength(base, old.len - 1);
                } else {
                    var w = f.writer(base, &.{});
                    try w.seekTo(old.len);
                    try w.interface.writeAll("x");
                    try w.interface.flush();
                }
            },
        }
    }

    fn dirOpenFile(u: ?*anyopaque, d: std.Io.Dir, p: []const u8, o: std.Io.Dir.OpenFileOptions) std.Io.File.OpenError!std.Io.File {
        tick();
        return base.vtable.dirOpenFile(u, d, p, o);
    }
    fn dirStatFile(u: ?*anyopaque, d: std.Io.Dir, p: []const u8, o: std.Io.Dir.StatFileOptions) std.Io.Dir.StatFileError!std.Io.File.Stat {
        tick();
        return base.vtable.dirStatFile(u, d, p, o);
    }
    fn fileStat(u: ?*anyopaque, f: std.Io.File) std.Io.File.StatError!std.Io.File.Stat {
        tick();
        return base.vtable.fileStat(u, f);
    }
    fn fileReadPositional(u: ?*anyopaque, f: std.Io.File, data: []const []u8, offset: u64) std.Io.File.ReadPositionalError!usize {
        tick();
        return base.vtable.fileReadPositional(u, f, data, offset);
    }
    fn fileClose(u: ?*anyopaque, files: []const std.Io.File) void {
        tick();
        base.vtable.fileClose(u, files);
    }
    fn operate(u: ?*anyopaque, op: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
        tick();
        return base.vtable.operate(u, op);
    }

    fn arm(io: std.Io, k: usize, step: StepKind, d: std.Io.Dir, g: Encoded) std.Io {
        base = io;
        table = io.vtable.*;
        table.dirOpenFile = dirOpenFile;
        table.dirStatFile = dirStatFile;
        table.fileStat = fileStat;
        table.fileReadPositional = fileReadPositional;
        table.fileClose = fileClose;
        table.operate = operate;
        count = 0;
        at = k;
        ran = false;
        step_error = null;
        kind = step;
        dir = d;
        new = g;
        return .{ .userdata = io.userdata, .vtable = &table };
    }
};

const Opener = enum { open, open_scoped, open_source };

/// "old", "new" or an error name; a mixed or cut generation fails the test.
fn openOnce(a: std.mem.Allocator, io: std.Io, opener: Opener, dir: std.Io.Dir, delta: isize) ![]const u8 {
    switch (opener) {
        .open => {
            const e = snapshot_open.open(a, io, dir) catch |err| return @errorName(err);
            return judge(e.generation, e.documents[0].text);
        },
        .open_scoped => {
            const s = snapshot_open.openScoped(a, io, dir) catch |err| return @errorName(err);
            defer snapshot_open.close(s.engine, s.folder);
            return judge(s.engine.generation, s.engine.documents[0].text);
        },
        .open_source => {
            const s = snapshot_open.openSource(a, io, dir) catch |err| return @errorName(err);
            if (s.metadata.generation == 1 and std.mem.eql(u8, s.metadata.embedding_model_id, model1)) return "old";
            if (s.metadata.generation == 2 and std.mem.eql(u8, s.metadata.embedding_model_id, try model2(a, delta))) return "new";
            return error.MixedGeneration;
        },
    }
}

fn judge(generation: u64, text: []const u8) ![]const u8 {
    if (generation == 1 and std.mem.eql(u8, text, text1)) return "old";
    if (generation == 2 and std.mem.eql(u8, text, text2)) return "new";
    std.debug.print("mixed: generation {d} text {s}\n", .{ generation, text });
    return error.MixedGeneration;
}

fn sweep(opener: Opener, step: StepKind, delta: isize, assert_whole: bool) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    const g1 = try encode(a, 1, text1, model1);
    const g2 = try encode(a, 2, text2, try model2(a, delta));
    var line: std.ArrayList(u8) = .empty;
    var k: usize = 0;
    var bad: usize = 0;
    while (k < 64) : (k += 1) {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        try publish(tmp.dir, io, g1);
        const seam = Seam.arm(io, k, step, tmp.dir, g2);
        const outcome = try openOnce(a, seam, opener, tmp.dir, delta);
        if (Seam.step_error) |err| {
            std.debug.print("step error at k={d}: {s}\n", .{ k, @errorName(err) });
            return err;
        }
        if (!Seam.ran) break;
        try line.print(a, " {d}:{s}", .{ k, outcome });
        if (!(std.mem.eql(u8, outcome, "old") or std.mem.eql(u8, outcome, "new"))) bad += 1;
    }
    std.debug.print("VSWEEP {s} {s} delta {d}: {d} points, {d} not whole;{s}\n", .{ @tagName(opener), @tagName(step), delta, k, bad, line.items });
    if (assert_whole and bad != 0) return error.NotWholeGeneration;
}

test "S6-T13 verifier A: a publish at every point of every open returns one whole generation" {
    var failed: usize = 0;
    inline for (.{ Opener.open, Opener.open_scoped, Opener.open_source }) |opener| {
        for ([_]isize{ -1, 0, 1 }) |delta| sweep(opener, .publish, delta, true) catch |err| switch (err) {
            error.NotWholeGeneration => failed += 1,
            else => return err,
        };
    }
    try std.testing.expectEqual(@as(usize, 0), failed);
}

test "S6-T13 verifier A2: a publish then a prune of generation 1 at every point (printed, not asserted)" {
    inline for (.{ Opener.open, Opener.open_scoped, Opener.open_source }) |opener| {
        for ([_]isize{ -1, 0, 1 }) |delta| try sweep(opener, .publish_prune, delta, false);
    }
}

/// B and C: the in-place change right after the first stat of a handle.
fn inPlace(step: StepKind, opener: Opener) ![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    const g1 = try encode(a, 1, text1, model1);
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try publish(tmp.dir, io, g1);
    // Find the point right after the open's stat of MANIFEST: on `main` and
    // on the head, operation 0 is the open of MANIFEST and 1 its stat.
    const seam = Seam.arm(io, 2, step, tmp.dir, g1);
    const outcome = try openOnce(a, seam, opener, tmp.dir, 0);
    if (Seam.step_error) |err| return err;
    try std.testing.expect(Seam.ran);
    return try std.heap.page_allocator.dupe(u8, outcome);
}

test "S6-T13 verifier B: MANIFEST cut in place between the stat and the read is Truncated" {
    inline for (.{ Opener.open, Opener.open_scoped, Opener.open_source }) |opener| {
        const outcome = try inPlace(.cut_in_place, opener);
        std.debug.print("VB {s}: {s}\n", .{ @tagName(opener), outcome });
        try std.testing.expectEqualStrings("Truncated", outcome);
    }
}

test "S6-T13 verifier C: MANIFEST grown in place between the stat and the read reads the stat's length" {
    inline for (.{ Opener.open, Opener.open_scoped, Opener.open_source }) |opener| {
        const outcome = try inPlace(.grow_in_place, opener);
        std.debug.print("VC {s}: {s}\n", .{ @tagName(opener), outcome });
        try std.testing.expectEqualStrings("old", outcome);
    }
}

test "S6-T13 verifier D: an empty, a one-byte and a directory MANIFEST" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    const g1 = try encode(a, 1, text1, model1);
    inline for (.{ "empty", "one", "dir" }) |shape| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        try publish(tmp.dir, io, g1);
        if (comptime std.mem.eql(u8, shape, "dir")) {
            try tmp.dir.deleteFile(io, publication.current_manifest_file);
            try tmp.dir.createDir(io, publication.current_manifest_file, .default_dir);
        } else {
            try tmp.dir.writeFile(io, .{ .sub_path = publication.current_manifest_file, .data = if (comptime std.mem.eql(u8, shape, "one")) g1.manifest[0..1] else "" });
        }
        inline for (.{ Opener.open, Opener.open_scoped, Opener.open_source }) |opener| {
            const outcome = try openOnce(a, io, opener, tmp.dir, 0);
            std.debug.print("VD {s} {s}: {s}\n", .{ shape, @tagName(opener), outcome });
            const want = if (comptime std.mem.eql(u8, shape, "dir")) "IsDir" else "Truncated";
            try std.testing.expectEqualStrings(want, outcome);
        }
    }
}

test "S6-T13 verifier E: scan over a damaged MANIFEST or a section whose checksum does not match" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    const g1 = try encode(a, 1, text1, model1);
    const g2 = try encode(a, 2, text2, model1);
    inline for (.{ "cut", "flipped", "documents", "lexical" }) |damage| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        try publish(tmp.dir, io, g1);
        try publish(tmp.dir, io, g2);
        if (comptime std.mem.eql(u8, damage, "cut")) {
            try tmp.dir.writeFile(io, .{ .sub_path = publication.current_manifest_file, .data = g2.manifest[0 .. g2.manifest.len - 1] });
        } else if (comptime std.mem.eql(u8, damage, "flipped")) {
            const copy = try a.dupe(u8, g2.manifest);
            copy[copy.len - 1] ^= 1;
            try tmp.dir.writeFile(io, .{ .sub_path = publication.current_manifest_file, .data = copy });
        } else {
            const name = if (comptime std.mem.eql(u8, damage, "documents")) "documents-2.hybseg" else "lexical-2.hyblex";
            const bytes = if (comptime std.mem.eql(u8, damage, "documents")) g2.documents else g2.lexical;
            const copy = try a.dupe(u8, bytes);
            copy[copy.len - 1] ^= 1;
            try tmp.dir.writeFile(io, .{ .sub_path = name, .data = copy });
        }
        var mb: [4096]u8 = undefined;
        var db: [4096]u8 = undefined;
        var lb: [4096]u8 = undefined;
        const outcome: []const u8 = if (lifecycle.scan(tmp.dir, io, &mb, &db, &lb)) |r|
            try std.fmt.allocPrint(a, "report current {?d} orphans {d}/{d}", .{ r.current_generation, r.orphan_document_files, r.orphan_lexical_files })
        else |err|
            @errorName(err);
        std.debug.print("VE {s}: {s}\n", .{ damage, outcome });
        try std.testing.expect(std.mem.indexOf(u8, outcome, "report") == null);
    }
}
