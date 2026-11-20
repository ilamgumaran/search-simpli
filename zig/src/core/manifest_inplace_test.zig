//! S6-T13, after the Verdict: the verifier's tests B, C and E
//! (`docs/evidence/s6-t13/verifier/tools/verifier_s6t13_test.zig`), adopted
//! so that its plants `v1`, `v6b`, `v7` and `v8` fail `zig build test`.
//!
//! B. `MANIFEST` cut in place by one byte between the open's `stat` and its
//!    read: `Truncated`, as on `main` (the short read is honoured).
//! C. `MANIFEST` grown in place by one byte between the `stat` and the read:
//!    the old generation whole, as on `main` (the `stat`'s length is read).
//! E. `scan` over a damaged `MANIFEST` or a section whose checksum does not
//!    match: the error, as on `main`, never a report.
//!
//! No writer in the library changes `MANIFEST` in place (every publish
//! renames a new file in), so B and C stand for a process outside the
//! writer protocol. The seam counts the open's file operations and runs the
//! in-place change right before the third (operation 0 opens `MANIFEST`,
//! 1 is its `stat`).
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

const StepKind = enum { cut_in_place, grow_in_place };

/// The counting seam: runs the step once, through the real `Io`, right
/// before the open's `at`-th file operation.
const Seam = struct {
    var base: std.Io = undefined;
    var table: std.Io.VTable = undefined;
    var count: usize = 0;
    var at: usize = 0;
    var ran: bool = false;
    var step_error: ?anyerror = null;
    var kind: StepKind = .cut_in_place;
    var dir: std.Io.Dir = undefined;

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
        var buffer: [4096]u8 = undefined;
        const old = try dir.readFile(base, publication.current_manifest_file, &buffer);
        const f = try dir.openFile(base, publication.current_manifest_file, .{ .mode = .read_write });
        defer f.close(base);
        switch (kind) {
            .cut_in_place => try f.setLength(base, old.len - 1),
            .grow_in_place => {
                var w = f.writer(base, &.{});
                try w.seekTo(old.len);
                try w.interface.writeAll("x");
                try w.interface.flush();
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

    fn arm(io: std.Io, k: usize, step: StepKind, d: std.Io.Dir) std.Io {
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
        return .{ .userdata = io.userdata, .vtable = &table };
    }
};

const Opener = enum { open, open_scoped, open_source };

/// "old" or an error name; anything else fails the test.
fn openOnce(a: std.mem.Allocator, io: std.Io, opener: Opener, dir: std.Io.Dir) ![]const u8 {
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
            return error.MixedGeneration;
        },
    }
}

fn judge(generation: u64, text: []const u8) ![]const u8 {
    if (generation == 1 and std.mem.eql(u8, text, text1)) return "old";
    std.debug.print("not generation 1 whole: generation {d} text {s}\n", .{ generation, text });
    return error.MixedGeneration;
}

/// B and C: the in-place change right after the open's `stat` of `MANIFEST`.
fn inPlace(a: std.mem.Allocator, step: StepKind, opener: Opener) ![]const u8 {
    const io = std.testing.io;
    const g1 = try encode(a, 1, text1, model1);
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try publish(tmp.dir, io, g1);
    const seam = Seam.arm(io, 2, step, tmp.dir);
    const outcome = try openOnce(a, seam, opener, tmp.dir);
    if (Seam.step_error) |err| return err;
    try std.testing.expect(Seam.ran);
    return outcome;
}

test "S6-T13 verifier B: MANIFEST cut in place between the stat and the read is Truncated" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    inline for (.{ Opener.open, Opener.open_scoped, Opener.open_source }) |opener| {
        const outcome = try inPlace(arena_state.allocator(), .cut_in_place, opener);
        try std.testing.expectEqualStrings("Truncated", outcome);
    }
}

test "S6-T13 verifier C: MANIFEST grown in place between the stat and the read reads the stat's length" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    inline for (.{ Opener.open, Opener.open_scoped, Opener.open_source }) |opener| {
        const outcome = try inPlace(arena_state.allocator(), .grow_in_place, opener);
        try std.testing.expectEqualStrings("old", outcome);
    }
}

test "S6-T13 verifier E: scan over a damaged MANIFEST or a section whose checksum does not match returns the error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    const g1 = try encode(a, 1, text1, model1);
    const g2 = try encode(a, 2, text2, model1);
    const Case = struct { damage: []const u8, want: anyerror };
    const cases = [_]Case{
        .{ .damage = "cut", .want = error.Truncated },
        .{ .damage = "flipped", .want = error.ChecksumMismatch },
        .{ .damage = "documents", .want = error.InvalidDocumentSection },
        .{ .damage = "lexical", .want = error.InvalidLexicalSection },
    };
    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        try publish(tmp.dir, io, g1);
        try publish(tmp.dir, io, g2);
        if (std.mem.eql(u8, case.damage, "cut")) {
            try tmp.dir.writeFile(io, .{ .sub_path = publication.current_manifest_file, .data = g2.manifest[0 .. g2.manifest.len - 1] });
        } else if (std.mem.eql(u8, case.damage, "flipped")) {
            const copy = try a.dupe(u8, g2.manifest);
            copy[copy.len - 1] ^= 1;
            try tmp.dir.writeFile(io, .{ .sub_path = publication.current_manifest_file, .data = copy });
        } else {
            const documents = std.mem.eql(u8, case.damage, "documents");
            const copy = try a.dupe(u8, if (documents) g2.documents else g2.lexical);
            copy[copy.len - 1] ^= 1;
            try tmp.dir.writeFile(io, .{ .sub_path = if (documents) "documents-2.hybseg" else "lexical-2.hyblex", .data = copy });
        }
        var mb: [4096]u8 = undefined;
        var db: [4096]u8 = undefined;
        var lb: [4096]u8 = undefined;
        if (lifecycle.scan(tmp.dir, io, &mb, &db, &lb)) |report| {
            std.debug.print("scan with {s} damaged gave a report: current {?d}\n", .{ case.damage, report.current_generation });
            return error.TestExpectedError;
        } else |err| {
            if (err != case.want) std.debug.print("scan with {s} damaged: {s}\n", .{ case.damage, @errorName(err) });
            try std.testing.expectEqual(case.want, err);
        }
    }
}
