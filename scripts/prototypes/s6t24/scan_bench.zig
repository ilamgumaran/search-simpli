//! S6-T24 Part 1: the cost of `scan` (pattern search), measured outside the engine. It imports the core module only
//! to read an index's source section the way the engine does (`scope.Folder.sourceSection`, `Section.fileBytes`),
//! to number lines the way `read_span` does (`source.lineStarts`) and to use the analyser's Unicode tables; the
//! matcher below is a prototype of the design in `docs/decisions/0006-pattern-search.md`, not engine code.
//!
//!     zig build-exe -OReleaseSmall --dep core -Mroot=scan_bench.zig -Mcore=../../../zig/src/core/core.zig \
//!         -femit-bin=<scratch>/scan_bench
//!     scan_bench bench FOLDER INDEX_DIR ROUNDS
//!     scan_bench linear
//!     scan_bench lines FOLDER PATTERN        (one `path:line` per matching line, regex mode; for the grep check)
//!
//! `bench`, every measure ROUNDS times, interleaved, median and range reported (wall time inside the process):
//!   folder_read     walk FOLDER (dot components skipped, paths sorted), stat and read every file, check its UTF-8:
//!                   the floor of a scan over a folder with nothing prepared;
//!   folder_<p>      the same and pattern p over every line (literal: a byte search of the whole file first);
//!   index_bytes     every file of INDEX_DIR's source section through `Section.fileBytes` (the rebuild from chunks
//!                   and the SHA-256 check at every read), on one opened handle (the first round pays the section's
//!                   load; `index_load` reports that one-time cost separately);
//!   index_<p>       the same and pattern p;
//!   memory_<p>      pattern p over files already in memory (the matcher alone);
//!   memory_sha256   SHA-256 over every file in memory (the share of `fileBytes` that is the check).
//! Patterns: lit = literal `142.50`; ilit = literal `orchard`, case-insensitive (ASCII fast path, below); ilit_vm =
//! the same through the matcher; re1 = `\d+\.\d\d`; re2 = `\w+ing\b`. Each prints its matching lines and files, so
//! the counts can be checked against `grep -c` and agree between the folder and the index.
//!
//! `linear`: `(a+)+b` (which makes a backtracking matcher take exponential time) over one line of n `a`s, n = 2^14
//! .. 2^20 (a 1 MiB line without a newline), best of 3; the ratio of consecutive times shows the growth.
const std = @import("std");
const core = @import("core");
const tables = core.unicode_tables;
const source = core.source;
const scope = core.scope;
const snapshot_open = core.snapshot_open;

// ------------------------------------------------------------------ classes ---

fn inRanges(ranges: []const tables.CodepointRange, cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < ranges[mid].start) hi = mid else if (cp > ranges[mid].end) lo = mid + 1 else return true;
    }
    return false;
}

/// `\w`: the analyser's token code points (letters, digits, the marks attached to them, ZWNJ and ZWJ).
fn isWord(cp: u21) bool {
    if (cp < 0x80) return (cp >= 'a' and cp <= 'z') or (cp >= 'A' and cp <= 'Z') or (cp >= '0' and cp <= '9');
    return inRanges(&tables.letter_digit_ranges, cp) or inRanges(&tables.mark_ranges, cp) or cp == 0x200C or cp == 0x200D;
}

/// `\d` in the prototype: ASCII digits (the design proposes Unicode Nd from a generated table).
fn isDigit(cp: u21) bool {
    return cp >= '0' and cp <= '9';
}

const Item = union(enum) { range: [2]u21, word: bool, digit: bool, space: bool };

const Class = struct {
    negated: bool,
    items: []const Item,
    ascii: [128]bool,

    fn evaluate(items: []const Item, negated: bool, cp: u21) bool {
        var hit = false;
        for (items) |item| {
            const in = switch (item) {
                .range => |r| cp >= r[0] and cp <= r[1],
                .word => |positive| isWord(cp) == positive,
                .digit => |positive| isDigit(cp) == positive,
                .space => |positive| core.chunker.isWhitespace(cp) == positive,
            };
            if (in) {
                hit = true;
                break;
            }
        }
        return hit != negated;
    }

    fn contains(class: *const Class, cp: u21) bool {
        if (cp < 128) return class.ascii[cp];
        return evaluate(class.items, class.negated, cp);
    }
};

// ------------------------------------------------------------ parse, compile ---

const Assert = enum { bol, eol, word, not_word };

const Node = union(enum) {
    empty,
    char: u21,
    any,
    class: u16,
    assert: Assert,
    cat: []const Node,
    alt: []const Node,
    rep: struct { sub: *const Node, min: u32, max: ?u32 },
};

const Inst = union(enum) {
    char: u21,
    any,
    class: u16,
    assert: Assert,
    split: [2]u32,
    jmp: u32,
    match,
};

pub const max_program: usize = 8192;
pub const max_repeat: u32 = 255;

const Parser = struct {
    allocator: std.mem.Allocator,
    text: []const u8,
    at: usize = 0,
    classes: *std.ArrayList(Class),
    message: []const u8 = "",

    fn fail(p: *Parser, message: []const u8) error{ Refused, OutOfMemory } {
        p.message = message;
        return error.Refused;
    }

    fn peek(p: *Parser) ?u21 {
        if (p.at >= p.text.len) return null;
        const len = std.unicode.utf8ByteSequenceLength(p.text[p.at]) catch return null;
        return std.unicode.utf8Decode(p.text[p.at .. p.at + len]) catch null;
    }

    fn take(p: *Parser) ?u21 {
        const cp = p.peek() orelse return null;
        p.at += std.unicode.utf8CodepointSequenceLength(cp) catch 1;
        return cp;
    }

    fn alternation(p: *Parser) error{ Refused, OutOfMemory }!Node {
        var branches = std.ArrayList(Node).empty;
        try branches.append(p.allocator, try p.concat());
        while (p.peek() == '|') {
            _ = p.take();
            try branches.append(p.allocator, try p.concat());
        }
        if (branches.items.len == 1) return branches.items[0];
        return .{ .alt = branches.items };
    }

    fn concat(p: *Parser) error{ Refused, OutOfMemory }!Node {
        var items = std.ArrayList(Node).empty;
        while (p.peek()) |cp| {
            if (cp == '|' or cp == ')') break;
            try items.append(p.allocator, try p.repeat());
        }
        if (items.items.len == 0) return .empty;
        if (items.items.len == 1) return items.items[0];
        return .{ .cat = items.items };
    }

    fn repeat(p: *Parser) error{ Refused, OutOfMemory }!Node {
        var node = try p.atom();
        while (p.peek()) |cp| {
            var min: u32 = 0;
            var max: ?u32 = null;
            switch (cp) {
                '*' => _ = p.take(),
                '+' => {
                    _ = p.take();
                    min = 1;
                },
                '?' => {
                    _ = p.take();
                    max = 1;
                },
                '{' => {
                    _ = p.take();
                    min = try p.number();
                    max = min;
                    if (p.peek() == ',') {
                        _ = p.take();
                        max = if (p.peek() == '}') null else try p.number();
                    }
                    if (p.take() != '}') return p.fail("a repeat {m,n} is not closed");
                    if (min > max_repeat or (max != null and max.? > max_repeat)) return p.fail("a repeat bound is over 255");
                    if (max != null and max.? < min) return p.fail("a repeat {m,n} has n below m");
                },
                else => break,
            }
            if (p.peek() == '?' or p.peek() == '+') return p.fail("lazy and possessive repeats are not supported");
            if (node == .assert or node == .empty) return p.fail("a repeat follows nothing it can repeat");
            const sub = try p.allocator.create(Node);
            sub.* = node;
            node = .{ .rep = .{ .sub = sub, .min = min, .max = max } };
        }
        return node;
    }

    fn number(p: *Parser) error{ Refused, OutOfMemory }!u32 {
        const start = p.at;
        while (p.at < p.text.len and std.ascii.isDigit(p.text[p.at])) p.at += 1;
        if (p.at == start) return p.fail("a repeat {m,n} needs a number");
        return std.fmt.parseInt(u32, p.text[start..p.at], 10) catch p.fail("a repeat bound is over 255");
    }

    fn atom(p: *Parser) error{ Refused, OutOfMemory }!Node {
        const cp = p.take().?;
        switch (cp) {
            '(' => {
                if (p.peek() == '?') {
                    _ = p.take();
                    if (p.take() != ':') return p.fail("look-around and inline flags are not supported");
                }
                const inner = try p.alternation();
                if (p.take() != ')') return p.fail("a group is not closed");
                return inner;
            },
            '[' => return p.class(),
            '.' => return .any,
            '^' => return .{ .assert = .bol },
            '$' => return .{ .assert = .eol },
            '\\' => {
                const e = p.take() orelse return p.fail("the pattern ends with a backslash");
                return switch (e) {
                    'b' => .{ .assert = .word },
                    'B' => .{ .assert = .not_word },
                    'd', 'D', 'w', 'W', 's', 'S' => try p.single(escapeItem(e)),
                    '1'...'9' => p.fail("back-references are not supported"),
                    else => if (isMeta(e)) .{ .char = e } else p.fail("an escape outside the subset"),
                };
            },
            '*', '+', '?', '{' => return p.fail("a repeat follows nothing it can repeat"),
            else => return .{ .char = cp },
        }
    }

    fn single(p: *Parser, item: Item) !Node {
        const items = try p.allocator.alloc(Item, 1);
        items[0] = item;
        return p.addClass(items, false);
    }

    fn addClass(p: *Parser, items: []const Item, negated: bool) !Node {
        var made = Class{ .negated = negated, .items = items, .ascii = undefined };
        for (0..128) |c| made.ascii[c] = Class.evaluate(items, negated, @intCast(c));
        try p.classes.append(p.allocator, made);
        return .{ .class = @intCast(p.classes.items.len - 1) };
    }

    fn class(p: *Parser) error{ Refused, OutOfMemory }!Node {
        var negated = false;
        if (p.peek() == '^') {
            _ = p.take();
            negated = true;
        }
        var items = std.ArrayList(Item).empty;
        var first = true;
        while (true) {
            const cp = p.take() orelse return p.fail("a class [...] is not closed");
            if (cp == ']' and !first) break;
            first = false;
            var low = cp;
            if (cp == '\\') {
                const e = p.take() orelse return p.fail("a class [...] is not closed");
                switch (e) {
                    'd', 'D', 'w', 'W', 's', 'S' => {
                        try items.append(p.allocator, escapeItem(e));
                        continue;
                    },
                    else => low = e,
                }
            }
            if (p.peek() == '-' and p.at + 1 < p.text.len and p.text[p.at + 1] != ']') {
                _ = p.take();
                var high = p.take().?;
                if (high == '\\') high = p.take() orelse return p.fail("a class [...] is not closed");
                if (high < low) return p.fail("a class range is reversed");
                try items.append(p.allocator, .{ .range = .{ low, high } });
            } else try items.append(p.allocator, .{ .range = .{ low, low } });
        }
        return p.addClass(items.items, negated);
    }
};

fn isMeta(cp: u21) bool {
    return switch (cp) {
        '\\', '.', '+', '*', '?', '(', ')', '|', '[', ']', '{', '}', '^', '$', '-', '/' => true,
        else => false,
    };
}

fn escapeItem(e: u21) Item {
    return switch (e) {
        'd' => .{ .digit = true },
        'D' => .{ .digit = false },
        'w' => .{ .word = true },
        'W' => .{ .word = false },
        's' => .{ .space = true },
        else => .{ .space = false },
    };
}

const Compiler = struct {
    allocator: std.mem.Allocator,
    program: std.ArrayList(Inst) = .empty,

    fn emit(c: *Compiler, inst: Inst) error{ Refused, OutOfMemory }!u32 {
        if (c.program.items.len >= max_program) return error.Refused;
        try c.program.append(c.allocator, inst);
        return @intCast(c.program.items.len - 1);
    }

    fn here(c: *Compiler) u32 {
        return @intCast(c.program.items.len);
    }

    fn node(c: *Compiler, n: Node) error{ Refused, OutOfMemory }!void {
        switch (n) {
            .empty => {},
            .char => |cp| _ = try c.emit(.{ .char = cp }),
            .any => _ = try c.emit(.any),
            .class => |index| _ = try c.emit(.{ .class = index }),
            .assert => |a| _ = try c.emit(.{ .assert = a }),
            .cat => |items| for (items) |item| try c.node(item),
            .alt => |branches| {
                var jumps = std.ArrayList(u32).empty;
                for (branches, 0..) |branch, i| {
                    if (i + 1 < branches.len) {
                        const split = try c.emit(.{ .split = .{ 0, 0 } });
                        c.program.items[split].split[0] = c.here();
                        try c.node(branch);
                        try jumps.append(c.allocator, try c.emit(.{ .jmp = 0 }));
                        c.program.items[split].split[1] = c.here();
                    } else try c.node(branch);
                }
                for (jumps.items) |j| c.program.items[j].jmp = c.here();
            },
            .rep => |r| {
                for (0..r.min) |_| try c.node(r.sub.*);
                if (r.max) |max| {
                    var splits = std.ArrayList(u32).empty;
                    for (r.min..max) |_| {
                        const split = try c.emit(.{ .split = .{ 0, 0 } });
                        c.program.items[split].split[0] = c.here();
                        try splits.append(c.allocator, split);
                        try c.node(r.sub.*);
                    }
                    for (splits.items) |s| c.program.items[s].split[1] = c.here();
                } else {
                    const split = try c.emit(.{ .split = .{ 0, 0 } });
                    c.program.items[split].split[0] = c.here();
                    try c.node(r.sub.*);
                    _ = try c.emit(.{ .jmp = split });
                    c.program.items[split].split[1] = c.here();
                }
            },
        }
    }
};

pub const Program = struct {
    insts: []const Inst,
    classes: []const Class,
};

pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) !Program {
    var classes = std.ArrayList(Class).empty;
    var parser = Parser{ .allocator = allocator, .text = pattern, .classes = &classes };
    const root = try parser.alternation();
    if (parser.at != pattern.len) return error.Refused; // an unmatched ')'
    var compiler = Compiler{ .allocator = allocator };
    try compiler.node(root);
    _ = try compiler.emit(.match);
    return .{ .insts = compiler.program.items, .classes = classes.items };
}

// -------------------------------------------------------------------- the VM ---

/// A Pike VM: one pass over the line's code points, at most one thread per instruction per position, so the work
/// is O(instructions x code points) whatever the pattern; leftmost-first (the earlier alternative and the greedier
/// repeat win), as a backtracking matcher's first match. All memory is set up once per program (`init`).
pub const Vm = struct {
    program: Program,
    // Two lists of (pc, start); a sparse set per list for "already on the list at this position".
    pcs: [2][]u32,
    starts: [2][]u32,
    lens: [2]usize = .{ 0, 0 },
    dense: []u32,
    sparse: []u32,
    marks: usize = 0,
    stack: []u32,
    stack_starts: []u32,

    pub fn init(allocator: std.mem.Allocator, program: Program) !Vm {
        const n = program.insts.len;
        return .{
            .program = program,
            .pcs = .{ try allocator.alloc(u32, n), try allocator.alloc(u32, n) },
            .starts = .{ try allocator.alloc(u32, n), try allocator.alloc(u32, n) },
            .dense = try allocator.alloc(u32, n),
            .sparse = try allocator.alloc(u32, n),
            .stack = try allocator.alloc(u32, 2 * n + 2),
            .stack_starts = try allocator.alloc(u32, 2 * n + 2),
        };
    }

    fn onList(vm: *Vm, pc: u32) bool {
        const s = vm.sparse[pc];
        return s < vm.marks and vm.dense[s] == pc;
    }

    fn mark(vm: *Vm, pc: u32) void {
        vm.sparse[pc] = @intCast(vm.marks);
        vm.dense[vm.marks] = pc;
        vm.marks += 1;
    }

    /// Follow jumps, splits and assertions from `pc` at the position between `prev` and `next`, in priority order,
    /// appending the threads that wait on a code point (or `match`) to list `which`.
    fn add(vm: *Vm, which: usize, pc0: u32, start: u32, prev: ?u21, next: ?u21) void {
        var top: usize = 0;
        vm.stack[0] = pc0;
        vm.stack_starts[0] = start;
        top = 1;
        while (top > 0) {
            top -= 1;
            const pc = vm.stack[top];
            const s = vm.stack_starts[top];
            if (vm.onList(pc)) continue;
            vm.mark(pc);
            switch (vm.program.insts[pc]) {
                .jmp => |target| {
                    vm.stack[top] = target;
                    vm.stack_starts[top] = s;
                    top += 1;
                },
                .split => |targets| {
                    vm.stack[top] = targets[1];
                    vm.stack_starts[top] = s;
                    vm.stack[top + 1] = targets[0];
                    vm.stack_starts[top + 1] = s;
                    top += 2;
                },
                .assert => |a| {
                    const ok = switch (a) {
                        .bol => prev == null,
                        .eol => next == null,
                        .word, .not_word => blk: {
                            const before = if (prev) |c| isWord(c) else false;
                            const after = if (next) |c| isWord(c) else false;
                            break :blk (before != after) == (a == .word);
                        },
                    };
                    if (ok) {
                        vm.stack[top] = pc + 1;
                        vm.stack_starts[top] = s;
                        top += 1;
                    }
                },
                else => {
                    vm.pcs[which][vm.lens[which]] = pc;
                    vm.starts[which][vm.lens[which]] = s;
                    vm.lens[which] += 1;
                },
            }
        }
    }

    /// The first (leftmost-first) match in `line` at or after byte `from`, as code-point offsets `[start, end)`
    /// counted from `from`'s code point `from_cp`.
    pub fn search(vm: *Vm, line: []const u8, from: usize, from_cp: u32, before: ?u21) ?[2]u32 {
        var at = from;
        var cpi = from_cp;
        var prev = before;
        var current: usize = 0;
        vm.lens = .{ 0, 0 };
        var matched: ?[2]u32 = null;
        // Raw threads carried to the next position: (pc, start) after a code point was consumed.
        while (true) {
            const next: ?u21 = if (at < line.len) decode(line, at) else null;
            // Closure of the carried threads, then (until something matched) a new thread starting here.
            const raw_len = vm.lens[current];
            const other = 1 - current;
            vm.lens[other] = 0;
            vm.marks = 0;
            for (0..raw_len) |i| vm.add(other, vm.pcs[current][i], vm.starts[current][i], prev, next);
            if (matched == null) vm.add(other, 0, cpi, prev, next);
            current = other;
            if (vm.lens[current] == 0) {
                if (matched != null or next == null) break;
                // Nothing can start here (a failed assertion): move one code point on.
                at += std.unicode.utf8CodepointSequenceLength(next.?) catch 1;
                cpi += 1;
                prev = next;
                continue;
            }
            // Step: consume `next`.
            const list_len = vm.lens[current];
            const out = 1 - current;
            vm.lens[out] = 0;
            for (0..list_len) |i| {
                const pc = vm.pcs[current][i];
                const s = vm.starts[current][i];
                const take = switch (vm.program.insts[pc]) {
                    .match => {
                        matched = .{ s, cpi };
                        break; // threads after this one have lower priority
                    },
                    .char => |c| next != null and next.? == c,
                    .any => next != null,
                    .class => |k| next != null and vm.program.classes[k].contains(next.?),
                    else => false,
                };
                if (take) {
                    vm.pcs[out][vm.lens[out]] = pc + 1;
                    vm.starts[out][vm.lens[out]] = s;
                    vm.lens[out] += 1;
                }
            }
            if (next == null) break;
            current = out;
            if (vm.lens[current] == 0 and matched != null) break;
            at += std.unicode.utf8CodepointSequenceLength(next.?) catch 1;
            cpi += 1;
            prev = next;
        }
        return matched;
    }
};

fn decode(bytes: []const u8, at: usize) u21 {
    const len = std.unicode.utf8ByteSequenceLength(bytes[at]) catch return 0xFFFD;
    if (at + len > bytes.len) return 0xFFFD;
    return std.unicode.utf8Decode(bytes[at .. at + len]) catch 0xFFFD;
}

// ------------------------------------------------------------------ scanning ---

/// A line's bytes without its terminator (CRLF, or one of `str.splitlines`' single terminators).
fn stripBreak(line: []const u8) []const u8 {
    var end = line.len;
    if (end >= 2 and line[end - 2] == '\r' and line[end - 1] == '\n') return line[0 .. end - 2];
    if (end >= 3 and line[end - 3] == 0xe2 and line[end - 2] == 0x80 and (line[end - 1] == 0xa8 or line[end - 1] == 0xa9)) return line[0 .. end - 3];
    if (end >= 2 and line[end - 2] == 0xc2 and line[end - 1] == 0x85) return line[0 .. end - 2];
    if (end >= 1) switch (line[end - 1]) {
        0x0a, 0x0b, 0x0c, 0x0d, 0x1c, 0x1d, 0x1e => end -= 1,
        else => {},
    };
    return line[0..end];
}

const Kind = enum { literal, ilit_ascii, vm };

const Pattern = struct {
    kind: Kind,
    needle: []const u8 = "",
    vm: ?*Vm = null,
};

const Counts = struct { lines: usize = 0, files: usize = 0 };

const Scanner = struct {
    allocator: std.mem.Allocator,
    starts: std.ArrayList(u64) = .empty,
    /// Matching lines as (file index, line), when asked for (the `lines` command).
    out: ?*std.ArrayList([2]usize) = null,

    fn lineMatches(p: Pattern, line: []const u8) bool {
        return switch (p.kind) {
            .literal => std.mem.indexOf(u8, line, p.needle) != null,
            .ilit_ascii => std.ascii.indexOfIgnoreCase(line, p.needle) != null,
            .vm => p.vm.?.search(line, 0, 0, null) != null,
        };
    }

    /// Scan one file's bytes. Literal kinds search the whole buffer first and number lines only in a file with a
    /// hit; the VM runs on every line.
    fn file(s: *Scanner, p: Pattern, bytes: []const u8, index: usize, counts: *Counts) !void {
        switch (p.kind) {
            .literal, .ilit_ascii => {
                const first = switch (p.kind) {
                    .literal => std.mem.indexOf(u8, bytes, p.needle),
                    else => std.ascii.indexOfIgnoreCase(bytes, p.needle),
                };
                if (first == null) return;
            },
            .vm => {},
        }
        s.starts.clearRetainingCapacity();
        try source.lineStarts(s.allocator, bytes, &s.starts);
        const starts = s.starts.items;
        var matched = false;
        for (0..starts.len - 1) |i| {
            const line = stripBreak(bytes[starts[i]..starts[i + 1]]);
            if (lineMatches(p, line)) {
                counts.lines += 1;
                matched = true;
                if (s.out) |list| try list.append(s.allocator, .{ index, i + 1 });
            }
        }
        if (matched) counts.files += 1;
    }
};

/// `orchard` case-insensitive: every code point's fold orbit is ASCII except `s` (U+017F) and `k` (U+212A), so a
/// needle without `s` or `k` can be searched ASCII-case-insensitively over bytes, exactly.
fn asciiFoldSafe(needle: []const u8) bool {
    for (needle) |b| {
        if (b >= 0x80) return false;
        const l = std.ascii.toLower(b);
        if (l == 's' or l == 'k') return false;
    }
    return true;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn now(io: std.Io) u64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn hidden(path: []const u8) bool {
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (part.len > 0 and part[0] == '.') return true;
    return false;
}

fn walkPaths(arena: std.mem.Allocator, io: std.Io, root: std.Io.Dir) ![][]const u8 {
    var paths = std.ArrayList([]const u8).empty;
    var walker = try root.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or hidden(entry.path)) continue;
        try paths.append(arena, try arena.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, paths.items, {}, lessThan);
    return paths.items;
}

/// Walk, stat, read and UTF-8-check every file, scanning each with `p` when given. A fresh arena per call.
fn folderPass(gpa: std.mem.Allocator, io: std.Io, folder: []const u8, p: ?Pattern) !Counts {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root = try std.Io.Dir.cwd().openDir(io, folder, .{ .iterate = true });
    defer root.close(io);
    const paths = try walkPaths(arena, io, root);
    var scanner = Scanner{ .allocator = arena };
    var counts = Counts{};
    var buffer = std.ArrayList(u8).empty;
    for (paths, 0..) |path, index| {
        const stat = try root.statFile(io, path, .{});
        try buffer.resize(arena, @intCast(stat.size));
        const got = try root.readFile(io, path, buffer.items);
        if (!std.unicode.utf8ValidateSlice(got)) continue;
        if (p) |pattern| try scanner.file(pattern, got, index, &counts) else counts.files += 1;
    }
    return counts;
}

/// Every file of the section through `fileBytes`, scanning each with `p` when given.
fn indexPass(gpa: std.mem.Allocator, section: source.Section, p: ?Pattern) !Counts {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scanner = Scanner{ .allocator = arena };
    var counts = Counts{};
    for (0..section.file_count) |index| {
        var per_file = std.heap.ArenaAllocator.init(gpa);
        defer per_file.deinit();
        const entry = section.file(index);
        const bytes = switch (try section.fileBytes(per_file.allocator(), entry)) {
            .ok => |b| b,
            .failed => return error.SourceUnavailable,
        };
        if (p) |pattern| try scanner.file(pattern, bytes, index, &counts) else counts.files += 1;
    }
    return counts;
}

fn memoryPass(gpa: std.mem.Allocator, contents: []const []const u8, p: Pattern) !Counts {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var scanner = Scanner{ .allocator = arena_state.allocator() };
    var counts = Counts{};
    for (contents, 0..) |bytes, index| try scanner.file(p, bytes, index, &counts);
    return counts;
}

const Measure = struct {
    name: []const u8,
    times: std.ArrayList(u64) = .empty,
    counts: Counts = .{},
};

fn report(m: *Measure) void {
    std.mem.sort(u64, m.times.items, {}, std.sort.asc(u64));
    const t = m.times.items;
    std.debug.print("{s:<16} median_ms {d:>9.2} min_ms {d:>9.2} max_ms {d:>9.2} lines {d} files {d}\n", .{
        m.name,
        @as(f64, @floatFromInt(t[t.len / 2])) / 1e6,
        @as(f64, @floatFromInt(t[0])) / 1e6,
        @as(f64, @floatFromInt(t[t.len - 1])) / 1e6,
        m.counts.lines,
        m.counts.files,
    });
}

fn vmPattern(arena: std.mem.Allocator, pattern: []const u8) !Pattern {
    const program = try compile(arena, pattern);
    const vm = try arena.create(Vm);
    vm.* = try Vm.init(arena, program);
    return .{ .kind = .vm, .vm = vm };
}

/// `orchard` case-insensitive through the VM: each letter a class of its fold orbit (all ASCII here).
const ilit_vm_pattern = "[oO][rR][cC][hH][aA][rR][dD]";

fn bench(gpa: std.mem.Allocator, io: std.Io, folder: []const u8, index_dir: []const u8, rounds: usize) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const lit = Pattern{ .kind = .literal, .needle = "142.50" };
    std.debug.assert(asciiFoldSafe("orchard"));
    const ilit = Pattern{ .kind = .ilit_ascii, .needle = "orchard" };
    const ilit_vm = try vmPattern(arena, ilit_vm_pattern);
    const re1 = try vmPattern(arena, "\\d+\\.\\d\\d");
    const re2 = try vmPattern(arena, "\\w+ing\\b");
    const patterns = [_]struct { []const u8, Pattern }{
        .{ "lit", lit }, .{ "ilit", ilit }, .{ "ilit_vm", ilit_vm }, .{ "re1", re1 }, .{ "re2", re2 },
    };

    // Files in memory for the matcher-alone measures.
    var root = try std.Io.Dir.cwd().openDir(io, folder, .{ .iterate = true });
    defer root.close(io);
    const paths = try walkPaths(arena, io, root);
    const contents = try arena.alloc([]const u8, paths.len);
    var total: u64 = 0;
    for (paths, contents) |path, *content| {
        const stat = try root.statFile(io, path, .{});
        const buffer = try arena.alloc(u8, @intCast(stat.size));
        content.* = try root.readFile(io, path, buffer);
        total += stat.size;
    }

    // The index: one handle, the source section loaded once (timed).
    var index_root = try std.Io.Dir.cwd().openDir(io, index_dir, .{});
    defer index_root.close(io);
    const opened = try snapshot_open.openScoped(arena, io, index_root);
    const load_start = now(io);
    const section = (try opened.folder.sourceSection()) orelse return error.NoSource;
    const load_ns = now(io) - load_start;

    var measures = std.ArrayList(Measure).empty;
    try measures.append(arena, .{ .name = "folder_read" });
    try measures.append(arena, .{ .name = "index_bytes" });
    try measures.append(arena, .{ .name = "memory_sha256" });
    for (patterns) |entry| {
        try measures.append(arena, .{ .name = try std.fmt.allocPrint(arena, "folder_{s}", .{entry[0]}) });
        try measures.append(arena, .{ .name = try std.fmt.allocPrint(arena, "index_{s}", .{entry[0]}) });
        try measures.append(arena, .{ .name = try std.fmt.allocPrint(arena, "memory_{s}", .{entry[0]}) });
    }

    var sink: u8 = 0;
    for (0..rounds) |_| {
        var k: usize = 0;
        var start = now(io);
        measures.items[k].counts = try folderPass(gpa, io, folder, null);
        try measures.items[k].times.append(arena, now(io) - start);
        k += 1;
        start = now(io);
        measures.items[k].counts = try indexPass(gpa, section, null);
        try measures.items[k].times.append(arena, now(io) - start);
        k += 1;
        start = now(io);
        for (contents) |bytes| {
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
            sink +%= digest[0];
        }
        try measures.items[k].times.append(arena, now(io) - start);
        measures.items[k].counts = .{ .files = contents.len };
        k += 1;
        for (patterns) |entry| {
            start = now(io);
            measures.items[k].counts = try folderPass(gpa, io, folder, entry[1]);
            try measures.items[k].times.append(arena, now(io) - start);
            k += 1;
            start = now(io);
            measures.items[k].counts = try indexPass(gpa, section, entry[1]);
            try measures.items[k].times.append(arena, now(io) - start);
            k += 1;
            start = now(io);
            measures.items[k].counts = try memoryPass(gpa, contents, entry[1]);
            try measures.items[k].times.append(arena, now(io) - start);
            k += 1;
        }
    }
    std.debug.print("folder {s} files {d} bytes {d} index_files {d} rounds {d} sink {d}\n", .{ std.fs.path.basename(folder), paths.len, total, section.file_count, rounds, sink % 2 });
    std.debug.print("index_load       once_ms {d:.2} (the source section's first use on the handle)\n", .{@as(f64, @floatFromInt(load_ns)) / 1e6});
    for (measures.items) |*m| report(m);
}

fn linear(gpa: std.mem.Allocator, io: std.Io) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = try vmPattern(arena, "(a+)+b");
    std.debug.print("program {d} instructions\n", .{p.vm.?.program.insts.len});
    var previous: ?u64 = null;
    var n: usize = 1 << 14;
    while (n <= 1 << 20) : (n *= 2) {
        const line = try arena.alloc(u8, n);
        @memset(line, 'a');
        var best: u64 = std.math.maxInt(u64);
        var found = false;
        for (0..3) |_| {
            const start = now(io);
            found = p.vm.?.search(line, 0, 0, null) != null;
            best = @min(best, now(io) - start);
        }
        const ratio: f64 = if (previous) |prev| @as(f64, @floatFromInt(best)) / @as(f64, @floatFromInt(prev)) else 0;
        std.debug.print("n {d:>8} best_ms {d:>9.3} ratio_to_half {d:.2} matched {}\n", .{ n, @as(f64, @floatFromInt(best)) / 1e6, ratio, found });
        previous = best;
    }
    // Every match of a line, not the first: `a*b|a` over n `a`s matches n times, and each search runs to the line's
    // end before the higher-priority `a*b` thread dies, so listing every match is quadratic (an ASCII line, so a
    // code-point offset is a byte offset).
    const q = try vmPattern(arena, "a*b|a");
    std.debug.print("every match of a*b|a\n", .{});
    previous = null;
    n = 1 << 10;
    while (n <= 1 << 14) : (n *= 2) {
        const line = try arena.alloc(u8, n);
        @memset(line, 'a');
        var best: u64 = std.math.maxInt(u64);
        var count: usize = 0;
        for (0..3) |_| {
            const start = now(io);
            count = 0;
            var at: u32 = 0;
            while (at <= n) {
                const m = q.vm.?.search(line, at, at, if (at == 0) null else 'a') orelse break;
                count += 1;
                at = if (m[1] > m[0]) m[1] else m[1] + 1;
            }
            best = @min(best, now(io) - start);
        }
        const ratio: f64 = if (previous) |prev| @as(f64, @floatFromInt(best)) / @as(f64, @floatFromInt(prev)) else 0;
        std.debug.print("n {d:>8} best_ms {d:>9.3} ratio_to_half {d:.2} matches {d}\n", .{ n, @as(f64, @floatFromInt(best)) / 1e6, ratio, count });
        previous = best;
    }
}

fn lines(gpa: std.mem.Allocator, io: std.Io, folder: []const u8, pattern: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = try vmPattern(arena, pattern);
    var root = try std.Io.Dir.cwd().openDir(io, folder, .{ .iterate = true });
    defer root.close(io);
    const paths = try walkPaths(arena, io, root);
    var found = std.ArrayList([2]usize).empty;
    var scanner = Scanner{ .allocator = arena, .out = &found };
    var counts = Counts{};
    for (paths, 0..) |path, index| {
        const stat = try root.statFile(io, path, .{});
        const buffer = try arena.alloc(u8, @intCast(stat.size));
        const got = try root.readFile(io, path, buffer);
        if (!std.unicode.utf8ValidateSlice(got)) continue;
        try scanner.file(p, got, index, &counts);
    }
    var out_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buffer);
    for (found.items) |hit| try stdout.interface.print("{s}:{d}\n", .{ paths[hit[0]], hit[1] });
    try stdout.interface.flush();
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const command = args.next() orelse return error.Usage;
    if (std.mem.eql(u8, command, "bench")) {
        const folder = args.next() orelse return error.Usage;
        const index_dir = args.next() orelse return error.Usage;
        const rounds = try std.fmt.parseInt(usize, args.next() orelse "5", 10);
        return bench(init.gpa, init.io, folder, index_dir, rounds);
    }
    if (std.mem.eql(u8, command, "linear")) return linear(init.gpa, init.io);
    if (std.mem.eql(u8, command, "lines")) {
        const folder = args.next() orelse return error.Usage;
        const pattern = args.next() orelse return error.Usage;
        return lines(init.gpa, init.io, folder, pattern);
    }
    return error.Usage;
}

test "the subset: matches and refusals" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_]struct { []const u8, []const u8, ?[2]u32 }{
        .{ "142\\.50", "total 142.50 paid", .{ 6, 12 } },
        .{ "\\d+\\.\\d\\d", "was 7.5 now 18.00", .{ 12, 17 } },
        .{ "^ab", "xab", null },
        .{ "b$", "ab", .{ 1, 2 } },
        .{ "\\bcat\\b", "concat cat", .{ 7, 10 } },
        .{ "a|ab", "ab", .{ 0, 1 } },
        .{ "(a+)+b", "aaab", .{ 0, 4 } },
        .{ "x{2,3}", "xxxx", .{ 0, 3 } },
        .{ "[^a-c]+", "abcdef", .{ 3, 6 } },
        .{ "\\w+", "கணினி இல்", .{ 0, 5 } },
        .{ "a*", "bbb", .{ 0, 0 } },
    };
    for (cases) |case| {
        const p = try vmPattern(arena, case[0]);
        const got = p.vm.?.search(case[1], 0, 0, null);
        if (case[2]) |want| {
            try std.testing.expect(got != null);
            try std.testing.expectEqual(want, got.?);
        } else try std.testing.expect(got == null);
    }
    for ([_][]const u8{ "(?=a)", "\\1", "a{1,300}", "a*?", "*a", "[abc", "(a" }) |bad| {
        try std.testing.expectError(error.Refused, compile(arena, bad));
    }
}
