//! S6-T24 rework 2, rulings 2 and 3: the wall-clock side of the stated constant, outside the default test run.
//!
//! The default `zig build test` bounds the meter by counting work (`pattern.zig`, "one interval of the meter is
//! bounded work, counted" and "every pattern of the fuzz does bounded work per unit charged"; `scan_test.zig`,
//! the glob tests). This program times the same cases with a real clock, in the build it is run in:
//!
//! 1. Compile: every pattern of `pattern.fuzz.patterns` (crafted ones at the caps and 4,000 random ones, up to
//!    1,024 bytes, class-heavy among them), sensitive and insensitive, whole word; the slowest, fastest of 3.
//! 2. The meter: each of `pattern.fuzz.meterCases` matched with a clock that keeps the widest gap between two of
//!    its reads (one meter interval), and the time per unit charged.
//! 3. The fuzz patterns matched over a mixed line: the most time per unit charged.
//! 4. The glob: the verifier's 255-byte glob against 20,000 names of 255 bytes (Verdict 2, finding 1).
//!
//! Run from the repository root (ReleaseSmall, the shipped build's mode):
//!   zig run -OReleaseSmall --dep core -Mroot=scripts/prototypes/s6t24/rework2/meter_bench.zig \
//!       -Mcore=zig/src/core/core.zig
const std = @import("std");
const core = @import("core");
const pattern = core.pattern;
const scan = core.scan;

var io_global: std.Io = undefined;

fn nowNs() u64 {
    return @intCast(std.Io.Clock.awake.now(io_global).nanoseconds);
}

const GapClock = struct {
    last: u64 = 0,
    widest: u64 = 0,
    reads: u64 = 0,

    fn now(context: ?*anyopaque) u64 {
        const self: *GapClock = @ptrCast(@alignCast(context.?));
        const t = nowNs();
        if (self.reads > 0) self.widest = @max(self.widest, t - self.last);
        self.last = t;
        self.reads += 1;
        return t;
    }
};

/// Units charged, counted by a budget whose clock never runs out (the clock is only read, every 65,536 units).
const UnitClock = struct {
    reads: u64 = 0,
    fn now(context: ?*anyopaque) u64 {
        const self: *UnitClock = @ptrCast(@alignCast(context.?));
        self.reads += 1;
        return self.reads;
    }
};

pub fn main(init: std.process.Init) !void {
    io_global = init.io;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 1. Compile.
    const patterns = try pattern.fuzz.patterns(arena, 4000);
    var slowest: u64 = 0;
    var slowest_pattern: []const u8 = "";
    var compiled_count: usize = 0;
    var longest: usize = 0;
    for (patterns) |text| {
        longest = @max(longest, text.len);
        for ([_]pattern.Case{ .sensitive, .insensitive }) |case| {
            var best: u64 = std.math.maxInt(u64);
            for (0..3) |_| {
                var one = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer one.deinit();
                const start = nowNs();
                _ = try pattern.compile(one.allocator(), text, .regex, case, true);
                best = @min(best, nowNs() - start);
            }
            compiled_count += 1;
            if (best > slowest) {
                slowest = best;
                slowest_pattern = text;
            }
        }
    }
    std.debug.print("compile: {d} patterns (longest {d} bytes) x 2 cases; slowest {d} us ({d} bytes: {s})\n", .{ patterns.len, longest, slowest / 1000, slowest_pattern.len, slowest_pattern[0..@min(slowest_pattern.len, 60)] });

    // 2. The meter on its heaviest units.
    const cases = try pattern.fuzz.meterCases(arena);
    var widest_all: u64 = 0;
    var ns_per_unit_worst: f64 = 0;
    for (cases) |case| {
        const compiled = try arena.create(pattern.Compiled);
        compiled.* = (try pattern.compile(arena, case.pattern, case.mode, case.case, false)).ok;
        var widest: u64 = std.math.maxInt(u64);
        var per_unit: f64 = std.math.inf(f64);
        for (0..3) |_| {
            var gap = GapClock{};
            var budget = pattern.Budget.start(.{ .context = &gap, .now = GapClock.now }, 30_000);
            var matcher = try pattern.Matcher.init(arena, compiled, &budget);
            var offsets = std.ArrayList([2]u32).empty;
            _ = try matcher.matchLine(arena, case.line, 512, 512, &offsets);
            widest = @min(widest, gap.widest);
            // The time per unit: the same line with a clock that only counts its reads (one per 65,536 units).
            var units = UnitClock{};
            var counted = pattern.Budget.start(.{ .context = &units, .now = UnitClock.now }, 30_000);
            counted.deadline = std.math.maxInt(u64);
            var matcher2 = try pattern.Matcher.init(arena, compiled, &counted);
            var offsets2 = std.ArrayList([2]u32).empty;
            const start = nowNs();
            _ = try matcher2.matchLine(arena, case.line, 512, 512, &offsets2);
            const took = nowNs() - start;
            const charged = (units.reads - 1) * pattern.check_units + counted.units;
            per_unit = @min(per_unit, @as(f64, @floatFromInt(took)) / @as(f64, @floatFromInt(@max(charged, 1))));
        }
        widest_all = @max(widest_all, widest);
        ns_per_unit_worst = @max(ns_per_unit_worst, per_unit);
        std.debug.print("meter: {s} ({d} bytes) over {d} bytes: widest gap {d} us, {d:.2} ns a unit\n", .{ case.pattern[0..@min(case.pattern.len, 40)], case.pattern.len, case.line.len, widest / 1000, per_unit });
    }
    std.debug.print("meter: widest gap over all cases {d} us; most time a unit {d:.2} ns\n", .{ widest_all / 1000, ns_per_unit_worst });

    // 3. The fuzz patterns over a mixed line.
    const line = try pattern.fuzz.repeatCodepoints(arena, "Ωж→ 1ſKaé-x\tß", 1 << 16);
    var fuzz_worst: f64 = 0;
    var fuzz_worst_pattern: []const u8 = "";
    var fuzz_count: usize = 0;
    for (patterns[0..@min(patterns.len, 1200)]) |text| {
        for ([_]pattern.Case{ .sensitive, .insensitive }) |case| {
            var one = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer one.deinit();
            const compiled = try one.allocator().create(pattern.Compiled);
            compiled.* = switch (try pattern.compile(one.allocator(), text, .regex, case, false)) {
                .ok => |c| c,
                .refused => continue,
            };
            var units = UnitClock{};
            var counted = pattern.Budget.start(.{ .context = &units, .now = UnitClock.now }, 30_000);
            counted.deadline = std.math.maxInt(u64);
            var matcher = try pattern.Matcher.init(one.allocator(), compiled, &counted);
            var offsets = std.ArrayList([2]u32).empty;
            const start = nowNs();
            _ = try matcher.matchLine(one.allocator(), line, 512, 340, &offsets);
            const took = nowNs() - start;
            const charged = (units.reads - 1) * pattern.check_units + counted.units;
            fuzz_count += 1;
            // Only searches long enough to time (at least 1 ms of work).
            if (took < std.time.ns_per_ms) continue;
            const per_unit = @as(f64, @floatFromInt(took)) / @as(f64, @floatFromInt(@max(charged, 1)));
            if (per_unit > fuzz_worst) {
                fuzz_worst = per_unit;
                fuzz_worst_pattern = text;
            }
        }
    }
    std.debug.print("meter fuzz: {d} patterns matched over {d} bytes; most time a unit {d:.2} ns ({d} bytes: {s})\n", .{ fuzz_count, line.len, fuzz_worst, fuzz_worst_pattern.len, fuzz_worst_pattern[0..@min(fuzz_worst_pattern.len, 60)] });

    // 4. The glob.
    const glob = scan.Glob.init("*" ++ "a" ** 253 ++ "b");
    const names = try arena.alloc([]const u8, 20_000);
    for (names, 0..) |*name, i| name.* = try std.fmt.allocPrint(arena, "{s}{d:0>5}.txt", .{ "a" ** 245, i });
    var best: u64 = std.math.maxInt(u64);
    var kept: usize = 0;
    for (0..3) |_| {
        kept = 0;
        const start = nowNs();
        for (names) |name| kept += @intFromBool(glob.matches(name));
        best = @min(best, nowNs() - start);
    }
    std.debug.print("glob: 20,000 names of 255 bytes against * + 253 a + b: {d} us in all, {d:.1} ns a byte, {d} kept\n", .{ best / 1000, @as(f64, @floatFromInt(best)) / (20_000.0 * 255.0), kept });
}
