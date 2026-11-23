//! S6-T23 Part 1: the cost of the proposed sniff (`text-sniff-v1`), measured outside the engine. Standalone: it
//! imports only `std`, nothing under `zig/src/`. The rule is `textsniff.py`'s, steps 3 (the head verdict).
//!
//!     zig build-exe -OReleaseSmall sniff_bench.zig -femit-bin=<scratch>/sniff_bench
//!     sniff_bench FOLDER ROUNDS
//!
//! Over every regular file under FOLDER with no path component starting with `.` (paths sorted), it times, ROUNDS
//! times each, median reported:
//!   memory: the sniff over the first 8,192 bytes of a buffer already holding the file (what the engine would add
//!           for a file it reads whole anyway, a name today's list already reads);
//!   memory_nul_control: the same without the UTF-8 step (for a file read whole, `apply.zig` already checks the
//!           whole file's UTF-8; only the NUL and control-byte steps are new there);
//!   head:   statFile, then readFile of at most 8,192 bytes (open, read, close), then the sniff (what it would add
//!           for a name it must look into first: no extension or one outside today's list);
//!   whole:  statFile and readFile of the whole file, then std.unicode.utf8ValidateSlice, as `apply.zig` reads a
//!           walked file today (the reference the two others are set against).
//! It prints one line per measure (total ns, ns per file) and the verdict counts, so the run shows the sniff
//! agrees with `textsniff.py survey` on the folder.
const std = @import("std");

const head_bytes: usize = 8192;

const Verdict = enum { text, utf16, binary, not_utf8 };

const control_table = blk: {
    var table = [_]bool{false} ** 256;
    for (0x01..0x09) |b| table[b] = true;
    for (0x0E..0x1B) |b| table[b] = true;
    for (0x1C..0x20) |b| table[b] = true;
    table[0x7F] = true;
    break :blk table;
};

fn validPrefix(body: []const u8, cut: bool) bool {
    if (std.unicode.utf8ValidateSlice(body)) return true;
    if (!cut) return false;
    var trim: usize = 1;
    while (trim <= 3 and trim <= body.len) : (trim += 1) {
        if (std.unicode.utf8ValidateSlice(body[0 .. body.len - trim])) return true;
    }
    return false;
}

fn sniff(head: []const u8, size: u64, check_utf8: bool) Verdict {
    if (size == 0) return .text;
    if (head.len >= 4 and std.mem.eql(u8, head[0..4], "\x00\x00\xfe\xff")) return .utf16;
    if (head.len >= 2 and ((head[0] == 0xFF and head[1] == 0xFE) or (head[0] == 0xFE and head[1] == 0xFF))) return .utf16;
    if (std.mem.indexOfScalar(u8, head, 0) != null) return .binary;
    var controls: usize = 0;
    for (head) |b| {
        if (control_table[b]) controls += 1;
    }
    if (controls * 100 > head.len) return .binary;
    const body = if (std.mem.startsWith(u8, head, "\xef\xbb\xbf")) head[3..] else head;
    if (check_utf8 and !validPrefix(body, size > head.len)) return .not_utf8;
    return .text;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn median(values: []u64) u64 {
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    return values[values.len / 2];
}

fn now(io: std.Io) u64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args = init.minimal.args.iterate();
    _ = args.next();
    const folder = args.next() orelse return error.Usage;
    const rounds = try std.fmt.parseInt(usize, args.next() orelse "5", 10);

    var root = try std.Io.Dir.cwd().openDir(io, folder, .{ .iterate = true });
    defer root.close(io);
    var paths = std.ArrayList([]const u8).empty;
    var walker = try root.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        var hidden = false;
        var parts = std.mem.splitScalar(u8, entry.path, '/');
        while (parts.next()) |part| if (part.len > 0 and part[0] == '.') {
            hidden = true;
        };
        if (hidden) continue;
        try paths.append(arena, try arena.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, paths.items, {}, lessThan);

    // Whole files in memory, for the `memory` measure.
    const contents = try arena.alloc([]u8, paths.items.len);
    var total_bytes: u64 = 0;
    for (paths.items, contents) |path, *content| {
        const stat = try root.statFile(io, path, .{});
        const buffer = try arena.alloc(u8, @intCast(stat.size));
        content.* = try root.readFile(io, path, buffer);
        total_bytes += stat.size;
    }
    var counts = [_]usize{0} ** 4;
    for (contents) |content| counts[@intFromEnum(sniff(content[0..@min(content.len, head_bytes)], content.len, true))] += 1;

    const memory = try arena.alloc(u64, rounds);
    const memory_no_utf8 = try arena.alloc(u64, rounds);
    const head = try arena.alloc(u64, rounds);
    const whole = try arena.alloc(u64, rounds);
    var sink: usize = 0;
    const head_buffer = try arena.alloc(u8, head_bytes);
    for (0..rounds) |round| {
        var start = now(io);
        for (contents) |content| sink += @intFromEnum(sniff(content[0..@min(content.len, head_bytes)], content.len, true));
        memory[round] = now(io) - start;

        start = now(io);
        for (contents) |content| sink += @intFromEnum(sniff(content[0..@min(content.len, head_bytes)], content.len, false));
        memory_no_utf8[round] = now(io) - start;

        start = now(io);
        for (paths.items) |path| {
            const stat = try root.statFile(io, path, .{});
            const got = try root.readFile(io, path, head_buffer);
            sink += @intFromEnum(sniff(got, stat.size, true));
        }
        head[round] = now(io) - start;

        start = now(io);
        for (paths.items, contents) |path, content| {
            const stat = try root.statFile(io, path, .{});
            const got = try root.readFile(io, path, content[0..@intCast(stat.size)]);
            if (std.unicode.utf8ValidateSlice(got)) sink += 1;
        }
        whole[round] = now(io) - start;
    }
    const n = paths.items.len;
    const m = median(memory);
    const mn = median(memory_no_utf8);
    const h = median(head);
    const w = median(whole);
    std.debug.print("files {d} bytes {d} rounds {d} sink {d}\n", .{ n, total_bytes, rounds, sink % 7 });
    std.debug.print("verdicts text {d} utf16 {d} binary {d} not_utf8 {d}\n", .{ counts[0], counts[1], counts[2], counts[3] });
    std.debug.print("memory total_ns {d} per_file_ns {d}\n", .{ m, m / @max(n, 1) });
    std.debug.print("memory_nul_control total_ns {d} per_file_ns {d}\n", .{ mn, mn / @max(n, 1) });
    std.debug.print("head   total_ns {d} per_file_ns {d}\n", .{ h, h / @max(n, 1) });
    std.debug.print("whole  total_ns {d} per_file_ns {d}\n", .{ w, w / @max(n, 1) });
}
