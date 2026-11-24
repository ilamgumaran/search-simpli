//! `scan`'s matcher (S6-T24, CAP-25 FR-38 and NFR-19, `docs/decisions/0006-pattern-search.md` sections 2 to 5):
//! a literal string, or a pattern in a small regular-expression subset, matched against one line at a time.
//!
//! - **Grammar** (`compile`): the subset of ADR 0006 section 2 plus `\t` (ruling O-8). Everything else is refused
//!   with `pattern not supported at byte <n>: <reason>`; the Python reference (`src/search_platform/scan.py`)
//!   refuses the same patterns with the same messages.
//! - **Compiling** is bounded by a count of work, not of output (rework 1, ruling 1): every node the compiler
//!   expands counts one step, whether or not it emits, and so does every instruction; over 8,192 of either is
//!   refused as too large. A repeat whose body can only match the empty string is simplified to its body at
//!   most once (`X{m,n}` to `X{min(m,1),min(n,1)}`: the same spans), so nested empty repeats cost nothing.
//! - **Matching** (`Matcher`): a Pike VM over code points, at most one thread per instruction per position, so a
//!   pass over a line costs O(instructions x code points) whatever the pattern; leftmost-first (the earlier
//!   alternative and the greedier repeat win), as Python's `re`. A program holds at most 8,192 instructions, a
//!   repeat bound is at most 255, and all of the VM's memory is set up once (`Matcher.init`), none per line.
//! - **Literals** skip the VM: Knuth-Morris-Pratt over bytes (linear whatever the needle), exact or, for an
//!   insensitive ASCII needle with no `s` and no `k`, over ASCII-lowered bytes (exact: the only code points
//!   outside ASCII that fold into ASCII fold to `s` and `k`). A regex with no special character is a literal.
//! - **Case**: `insensitive` applies the analyser's simple fold (`casefold_pairs`, one code point to one) to the
//!   line and to the pattern's code points; a class matches a folded code point `f` when `f` is in the class or is
//!   the fold of a member (`Class.extras`). `smart` is `insensitive` unless a code point the pattern writes
//!   changes under the fold.
//! - **Classes**: `\w` is the analyser's word code points (letters, digits, marks Mn and Mc, ZWNJ, ZWJ; not `_`),
//!   `\d` is Unicode Nd (`digit_ranges`), `\s` the analyser's whitespace (`chunker.isWhitespace`). A class is
//!   normalised when compiled (`Members`, rework 2, ruling 2): its ranges sorted and merged, each of `\w`, `\d`
//!   and `\s` kept once, so testing a code point is at most five binary searches whatever the class says.
//! - **Every match** (`Matcher.matchLine`): Python's `finditer`; empty matches make the line a hit but are left
//!   out of the offsets, and only matches starting within the hit's `text` are listed. Deciding the hit is one
//!   pass; in regex mode at most 16 non-empty matches are listed per line, and a line with a 17th starting
//!   within its text has its text cut where that one starts (`matches_truncated`, and `text_truncated`). Empty
//!   matches neither count nor cut (rework 2, ruling 4), so a line costs at most 17 passes plus one per code
//!   point of its text (at most 512) that an empty match starts at (rework 1, ruling 2). A literal's matches are
//!   found in one pass, all of them.
//! - **Budget**: every loop charges its work to `Budget.charge`, which reads the clock once per 65,536 units and
//!   stops the line with `error.OutOfTime`. A unit is a bounded amount of work (rework 2, ruling 2): a byte
//!   searched, a VM thread followed or stepped, a position (one unit more for the fold, two for a word test), and
//!   a step on a class outside ASCII one unit per search it may do (`Class.cost`). Test builds count the work
//!   behind each unit (`work`), and tests bound it by count.
const std = @import("std");
const chunker = @import("chunker.zig");
const tables = @import("unicode_tables.zig");

pub const max_pattern_bytes: usize = 1024;
/// The compile's cap, on instructions emitted and on nodes expanded alike.
pub const max_program: usize = 8192;
pub const max_repeat: u32 = 255;
/// Regex mode: the non-empty matches listed for one line; the text is cut where the next one starts.
pub const max_matches_per_line: u32 = 16;
/// The budget reads the clock once per this many units of work.
pub const check_units: u64 = 1 << 16;

pub const Mode = enum {
    literal,
    regex,

    pub fn parse(text: []const u8) ?Mode {
        return std.meta.stringToEnum(Mode, text);
    }
};

pub const Case = enum {
    sensitive,
    insensitive,
    smart,

    pub fn parse(text: []const u8) ?Case {
        return std.meta.stringToEnum(Case, text);
    }
};

/// What `smart` resolved to.
pub const Applied = enum { sensitive, insensitive };

// --------------------------------------------------------------- work counts ---

/// Test builds count the elementary steps behind the budget's units (rework 2, rulings 2 and 3): a probe of a
/// table or range search, an item or a thread tested, a byte or a code point passed. A test then bounds the work
/// between two reads of the clock, and the work per unit charged, by counting, never by a clock (NFR-19). Other
/// builds count nothing (`counts_work` is false and the counters are never referenced).
pub const counts_work = @import("builtin").is_test;
pub threadlocal var work_done: u64 = 0;
pub threadlocal var units_charged: u64 = 0;

pub inline fn work(n: u64) void {
    if (counts_work) work_done += n;
}

// ------------------------------------------------------------------ classes ---

fn inRanges(ranges: []const tables.CodepointRange, cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        work(1);
        const mid = lo + (hi - lo) / 2;
        if (cp < ranges[mid].start) hi = mid else if (cp > ranges[mid].end) lo = mid + 1 else return true;
    }
    return false;
}

/// `\w`: the analyser's token code points (`analyzer_v2.zig`): letters, digits (Nd, Nl, No), the marks Mn and
/// Mc, ZWNJ and ZWJ. Not `_`.
pub fn isWord(cp: u21) bool {
    work(1);
    if (cp < 0x80) return (cp >= 'a' and cp <= 'z') or (cp >= 'A' and cp <= 'Z') or (cp >= '0' and cp <= '9');
    return inRanges(&tables.letter_digit_ranges, cp) or inRanges(&tables.mark_ranges, cp) or cp == 0x200C or cp == 0x200D;
}

/// `\d`: Unicode Nd.
pub fn isDigit(cp: u21) bool {
    work(1);
    if (cp < 0x80) return cp >= '0' and cp <= '9';
    return inRanges(&tables.digit_ranges, cp);
}

/// `\s`: Python's `str.isspace`, the analyser's whitespace (`chunker.isWhitespace`, the same set: a test checks
/// every code point up to U+3100, past its last member), in one switch.
pub fn isSpace(cp: u21) bool {
    work(1);
    return switch (cp) {
        0x09...0x0d, 0x1c...0x20, 0x85, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
        else => false,
    };
}

/// The analyser's simple fold of one code point (`analyzer_v2.casefoldCodepoint`).
pub fn fold(cp: u21) u21 {
    if (cp < 0x80) return if (cp >= 'A' and cp <= 'Z') cp + 32 else cp;
    var lo: usize = 0;
    var hi: usize = tables.casefold_pairs.len;
    while (lo < hi) {
        work(1);
        const mid = lo + (hi - lo) / 2;
        const entry = tables.casefold_pairs[mid];
        if (entry.from == cp) return entry.to;
        if (entry.from < cp) lo = mid + 1 else hi = mid;
    }
    return cp;
}

/// A line terminator of `str.splitlines` (a pattern holding one is refused: matching is per line).
pub fn isLineBreak(cp: u21) bool {
    return switch (cp) {
        0x0A...0x0D, 0x1C...0x1E, 0x85, 0x2028, 0x2029 => true,
        else => false,
    };
}

const Item = union(enum) { range: [2]u21, word: bool, digit: bool, space: bool };

/// Whether `cp` is in one of `ranges` (sorted, disjoint), by binary search.
fn inSorted(ranges: []const [2]u21, cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        work(1);
        const mid = lo + (hi - lo) / 2;
        if (cp < ranges[mid][0]) hi = mid else if (cp > ranges[mid][1]) lo = mid + 1 else return true;
    }
    return false;
}

fn lessThanRange(_: void, a: [2]u21, b: [2]u21) bool {
    return a[0] < b[0];
}

/// A class's members, normalised when it is compiled (rework 2, ruling 2), so that testing a code point costs a
/// bounded number of steps whatever the class says: its ranges sorted and merged (one binary search), and each
/// of `\w`, `\d` and `\s` at most once (a table with its negation is every code point). At most five searches:
/// the ranges, the two tables of `\w`, the table of `\d` and (in `Class`) the folds; `\s` is one switch.
const Members = struct {
    all: bool = false,
    ranges: []const [2]u21 = &.{},
    word: ?bool = null,
    digit: ?bool = null,
    space: ?bool = null,

    fn of(allocator: std.mem.Allocator, items: []const Item) !Members {
        var m = Members{};
        var ranges = std.ArrayList([2]u21).empty;
        work(items.len);
        for (items) |item| switch (item) {
            .range => |r| try ranges.append(allocator, r),
            .word => |positive| m.word = once(&m.all, m.word, positive),
            .digit => |positive| m.digit = once(&m.all, m.digit, positive),
            .space => |positive| m.space = once(&m.all, m.space, positive),
        };
        std.mem.sort([2]u21, ranges.items, {}, lessThanRange);
        work(ranges.items.len * (std.math.log2_int_ceil(usize, ranges.items.len + 1) + 1));
        var kept: usize = 0;
        for (ranges.items) |r| {
            if (kept > 0 and r[0] <= ranges.items[kept - 1][1] +| 1) {
                ranges.items[kept - 1][1] = @max(ranges.items[kept - 1][1], r[1]);
                continue;
            }
            ranges.items[kept] = r;
            kept += 1;
        }
        m.ranges = ranges.items[0..kept];
        return m;
    }

    fn once(all: *bool, have: ?bool, positive: bool) bool {
        if (have) |sign| if (sign != positive) {
            all.* = true;
        };
        return positive;
    }

    fn contains(m: *const Members, cp: u21) bool {
        if (m.all) return true;
        if (m.ranges.len > 0 and inSorted(m.ranges, cp)) return true;
        if (m.word) |positive| if (isWord(cp) == positive) return true;
        if (m.digit) |positive| if (isDigit(cp) == positive) return true;
        if (m.space) |positive| if (isSpace(cp) == positive) return true;
        return false;
    }

    /// The table and range searches a test may do (`\w` counts two).
    fn searches(m: *const Members) u32 {
        if (m.all) return 0;
        return @as(u32, @intFromBool(m.ranges.len > 0)) + (if (m.word != null) @as(u32, 2) else 0) + @intFromBool(m.digit != null);
    }
};

const Class = struct {
    negated: bool,
    members: Members,
    /// Insensitive only: the folds of the members that are not members themselves, sorted.
    extras: []const u21 = &.{},
    ascii: [128]bool = undefined,
    /// The units a VM step on this class charges for a code point outside ASCII: one, and one per search the
    /// test may do, so that a unit stays a bounded amount of work (rework 2, ruling 2).
    cost: u32 = 1,

    fn evaluate(class: *const Class, cp: u21) bool {
        var hit = class.members.contains(cp);
        if (!hit and class.extras.len > 0) hit = sortedHas(class.extras, cp);
        return hit != class.negated;
    }

    fn contains(class: *const Class, cp: u21) bool {
        if (cp < 128) return class.ascii[cp];
        return class.evaluate(cp);
    }
};

fn sortedHas(values: []const u21, cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = values.len;
    while (lo < hi) {
        work(1);
        const mid = lo + (hi - lo) / 2;
        if (values[mid] == cp) return true;
        if (values[mid] < cp) lo = mid + 1 else hi = mid;
    }
    return false;
}

// ------------------------------------------------------------ parse, compile ---

pub const Assert = enum { bol, eol, boundary, not_boundary, prev_not_word, next_not_word };

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

pub const Inst = union(enum) {
    char: u21,
    any,
    class: u16,
    assert: Assert,
    split: [2]u32,
    jmp: u32,
    match,
};

const ParseError = error{ Refused, OutOfMemory };

const Parser = struct {
    allocator: std.mem.Allocator,
    text: []const u8,
    at: usize = 0,
    classes: std.ArrayList([]const Item) = .empty,
    negations: std.ArrayList(bool) = .empty,
    /// The code points the pattern writes (chars, class members and range ends), for `smart`.
    written: std.ArrayList(u21) = .empty,
    refusal_at: usize = 0,
    refusal: []const u8 = "",

    fn fail(p: *Parser, at: usize, reason: []const u8) ParseError {
        p.refusal_at = at;
        p.refusal = reason;
        return error.Refused;
    }

    fn peek(p: *const Parser) ?u21 {
        if (p.at >= p.text.len) return null;
        return decodeAt(p.text, p.at).cp;
    }

    fn peekAt(p: *const Parser, at: usize) ?u21 {
        if (at >= p.text.len) return null;
        return decodeAt(p.text, at).cp;
    }

    fn take(p: *Parser) ?u21 {
        work(1);
        if (p.at >= p.text.len) return null;
        const d = decodeAt(p.text, p.at);
        p.at += d.len;
        return d.cp;
    }

    fn alternation(p: *Parser) ParseError!Node {
        var branches = std.ArrayList(Node).empty;
        try branches.append(p.allocator, try p.concat());
        while (p.peek() == '|') {
            _ = p.take();
            try branches.append(p.allocator, try p.concat());
        }
        if (branches.items.len == 1) return branches.items[0];
        return .{ .alt = branches.items };
    }

    fn concat(p: *Parser) ParseError!Node {
        var items = std.ArrayList(Node).empty;
        while (p.peek()) |cp| {
            if (cp == '|' or cp == ')') break;
            try items.append(p.allocator, try p.repeat());
        }
        if (items.items.len == 0) return .empty;
        if (items.items.len == 1) return items.items[0];
        return .{ .cat = items.items };
    }

    fn repeat(p: *Parser) ParseError!Node {
        var node = try p.atom();
        var repeated = false;
        while (p.peek()) |cp| {
            const q_at = p.at;
            if (cp != '*' and cp != '+' and cp != '?' and cp != '{') break;
            if (repeated or node == .assert or node == .empty) return p.fail(q_at, "a repeat follows nothing it can repeat");
            var min: u32 = 0;
            var max: ?u32 = null;
            _ = p.take();
            switch (cp) {
                '*' => {},
                '+' => min = 1,
                '?' => max = 1,
                else => {
                    min = try p.number(q_at);
                    max = min;
                    if (p.peek() == ',') {
                        _ = p.take();
                        max = if (p.peek() == '}') null else try p.number(q_at);
                    }
                    if (p.peek() != '}') return p.fail(q_at, "a repeat {m,n} is not closed");
                    _ = p.take();
                    if (min > max_repeat or (max != null and max.? > max_repeat)) return p.fail(q_at, "a repeat bound is over 255");
                    if (max != null and max.? < min) return p.fail(q_at, "a repeat {m,n} has n below m");
                },
            }
            if (p.peek() == '?' or p.peek() == '+') return p.fail(p.at, "lazy and possessive repeats are not supported");
            if (zeroWidth(node)) {
                // Its body can only match the empty string: once is the same as any number of times.
                min = @min(min, 1);
                max = @min(max orelse 1, 1);
            }
            const sub = try p.allocator.create(Node);
            sub.* = node;
            node = .{ .rep = .{ .sub = sub, .min = min, .max = max } };
            repeated = true;
        }
        return node;
    }

    /// Decimal digits, saturating at a value over 255 (refused by the caller).
    fn number(p: *Parser, q_at: usize) ParseError!u32 {
        const start = p.at;
        var value: u32 = 0;
        while (p.at < p.text.len and std.ascii.isDigit(p.text[p.at])) : (p.at += 1) {
            value = @min(value * 10 + (p.text[p.at] - '0'), 100_000);
        }
        if (p.at == start) return p.fail(q_at, "a repeat {m,n} needs a number");
        return value;
    }

    fn atom(p: *Parser) ParseError!Node {
        const at = p.at;
        const cp = p.take().?;
        switch (cp) {
            '(' => {
                if (p.peek() == '?') {
                    _ = p.take();
                    if (p.take() != ':') return p.fail(at, "look-around and inline flags are not supported");
                }
                const inner = try p.alternation();
                if (p.peek() != ')') return p.fail(at, "a group is not closed");
                _ = p.take();
                return inner;
            },
            '[' => return p.class(at),
            '.' => return .any,
            '^' => return .{ .assert = .bol },
            '$' => return .{ .assert = .eol },
            '\\' => {
                const e = p.take() orelse return p.fail(at, "the pattern ends with a backslash");
                switch (e) {
                    'b' => return .{ .assert = .boundary },
                    'B' => return .{ .assert = .not_boundary },
                    'd', 'D', 'w', 'W', 's', 'S' => return p.single(escapeItem(e)),
                    't' => return p.char(0x09),
                    '1'...'9' => return p.fail(at, "back-references are not supported"),
                    else => return if (isEscapable(e)) p.char(e) else p.fail(at, "an escape outside the subset"),
                }
            },
            '*', '+', '?', '{' => return p.fail(at, "a repeat follows nothing it can repeat"),
            else => return p.char(cp),
        }
    }

    fn char(p: *Parser, cp: u21) ParseError!Node {
        try p.written.append(p.allocator, cp);
        return .{ .char = cp };
    }

    fn single(p: *Parser, item: Item) ParseError!Node {
        const items = try p.allocator.alloc(Item, 1);
        items[0] = item;
        return p.addClass(items, false);
    }

    fn addClass(p: *Parser, items: []const Item, negated: bool) ParseError!Node {
        try p.classes.append(p.allocator, items);
        try p.negations.append(p.allocator, negated);
        return .{ .class = @intCast(p.classes.items.len - 1) };
    }

    /// A class member written as an escape: `\t`, an escaped punctuation or space, or a refusal.
    fn classEscape(p: *Parser, at: usize, e: u21, allow_class: bool) ParseError!union(enum) { cp: u21, item: Item } {
        switch (e) {
            'd', 'D', 'w', 'W', 's', 'S' => return if (allow_class) .{ .item = escapeItem(e) } else p.fail(at, "an escape outside the subset"),
            'b', 'B' => return p.fail(at, "\\b inside a class is not supported"),
            't' => return .{ .cp = 0x09 },
            '1'...'9' => return p.fail(at, "back-references are not supported"),
            else => return if (isEscapable(e)) .{ .cp = e } else p.fail(at, "an escape outside the subset"),
        }
    }

    fn class(p: *Parser, open: usize) ParseError!Node {
        var negated = false;
        if (p.peek() == '^') {
            _ = p.take();
            negated = true;
        }
        var items = std.ArrayList(Item).empty;
        var first = true;
        while (true) {
            const low_at = p.at;
            const cp = p.take() orelse return p.fail(open, "a class [...] is not closed");
            if (cp == ']' and !first) break;
            first = false;
            var low = cp;
            if (cp == '[') return p.fail(low_at, "a [ inside a class must be escaped");
            if (cp == '\\') {
                const e = p.take() orelse return p.fail(low_at, "the pattern ends with a backslash");
                switch (try p.classEscape(low_at, e, true)) {
                    .item => |item| {
                        try items.append(p.allocator, item);
                        continue;
                    },
                    .cp => |value| low = value,
                }
            }
            if (p.peek() == '-' and p.peekAt(p.at + 1) != null and p.peekAt(p.at + 1).? != ']') {
                _ = p.take();
                const high_at = p.at;
                var high = p.take().?;
                if (high == '[') return p.fail(high_at, "a [ inside a class must be escaped");
                if (high == '\\') {
                    const e = p.take() orelse return p.fail(high_at, "the pattern ends with a backslash");
                    high = (try p.classEscape(high_at, e, false)).cp;
                }
                if (high < low) return p.fail(low_at, "a class range is reversed");
                try p.written.append(p.allocator, low);
                try p.written.append(p.allocator, high);
                try items.append(p.allocator, .{ .range = .{ low, high } });
            } else {
                try p.written.append(p.allocator, low);
                try items.append(p.allocator, .{ .range = .{ low, low } });
            }
        }
        return p.addClass(items.items, negated);
    }
};

/// `\` and one of these is the character itself: ASCII punctuation and space.
fn isEscapable(cp: u21) bool {
    return (cp >= 0x20 and cp <= 0x2F) or (cp >= 0x3A and cp <= 0x40) or (cp >= 0x5B and cp <= 0x60) or (cp >= 0x7B and cp <= 0x7E);
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

fn nullable(node: Node) bool {
    work(1);
    return switch (node) {
        .empty, .assert => true,
        .char, .any, .class => false,
        .cat => |items| for (items) |item| {
            if (!nullable(item)) break false;
        } else true,
        .alt => |branches| for (branches) |branch| {
            if (nullable(branch)) break true;
        } else false,
        .rep => |r| r.min == 0 or nullable(r.sub.*),
    };
}

/// Whether `node` can only match the empty string (it consumes no code point on any path).
fn zeroWidth(node: Node) bool {
    work(1);
    return switch (node) {
        .empty, .assert => true,
        .char, .any, .class => false,
        .cat => |items| for (items) |item| {
            if (!zeroWidth(item)) break false;
        } else true,
        .alt => |branches| for (branches) |branch| {
            if (!zeroWidth(branch)) break false;
        } else true,
        .rep => |r| r.max == 0 or zeroWidth(r.sub.*),
    };
}

/// The pattern's text when the tree is only characters (a regex with no special character is a literal).
fn literalOf(allocator: std.mem.Allocator, node: Node) !?[]const u8 {
    var out = std.ArrayList(u8).empty;
    switch (node) {
        .char => |cp| try appendUtf8(allocator, &out, cp),
        .cat => |items| for (items) |item| switch (item) {
            .char => |cp| try appendUtf8(allocator, &out, cp),
            else => return null,
        },
        else => return null,
    }
    return out.items;
}

fn appendUtf8(allocator: std.mem.Allocator, out: *std.ArrayList(u8), cp: u21) !void {
    var buffer: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &buffer) catch unreachable;
    try out.appendSlice(allocator, buffer[0..len]);
}

const Compiler = struct {
    allocator: std.mem.Allocator,
    program: std.ArrayList(Inst) = .empty,
    fold_chars: bool,
    /// Nodes expanded so far (every expansion of a repeat's body counts, whether or not it emits).
    work: usize = 0,

    fn emit(c: *Compiler, inst: Inst) error{ TooLarge, OutOfMemory }!u32 {
        work(1);
        if (c.program.items.len >= max_program) return error.TooLarge;
        try c.program.append(c.allocator, inst);
        return @intCast(c.program.items.len - 1);
    }

    /// The whole program: the pattern, wrapped for `whole_word`, then `match`.
    fn whole(c: *Compiler, root: Node, whole_word: bool) error{ TooLarge, OutOfMemory }!void {
        if (whole_word) _ = try c.emit(.{ .assert = .prev_not_word });
        try c.node(root);
        if (whole_word) _ = try c.emit(.{ .assert = .next_not_word });
        _ = try c.emit(.match);
    }

    fn here(c: *Compiler) u32 {
        return @intCast(c.program.items.len);
    }

    fn node(c: *Compiler, n: Node) error{ TooLarge, OutOfMemory }!void {
        work(1);
        c.work += 1;
        if (c.work > max_program) return error.TooLarge;
        switch (n) {
            .empty => {},
            .char => |cp| _ = try c.emit(.{ .char = if (c.fold_chars) fold(cp) else cp }),
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

pub const Strategy = enum {
    /// A byte search for `needle` (Knuth-Morris-Pratt).
    bytes,
    /// The same over ASCII-lowered bytes, for `needle` (ASCII, no s and no k).
    ascii_ci,
    /// The Pike VM over `program`.
    vm,
};

pub const Compiled = struct {
    mode: Mode,
    case_applied: Applied,
    whole_word: bool,
    strategy: Strategy,
    /// `bytes` and `ascii_ci`: the literal's bytes.
    needle: []const u8 = "",
    program: []const Inst = &.{},
    classes: []const Class = &.{},
    /// The pattern can match the empty string (a regex only).
    matches_empty: bool = false,
};

pub const CompileOutcome = union(enum) {
    ok: Compiled,
    /// The message (`invalid_argument`), from the allocator.
    refused: []const u8,
};

fn refuse(allocator: std.mem.Allocator, comptime format: []const u8, args: anytype) !CompileOutcome {
    return .{ .refused = try std.fmt.allocPrint(allocator, format, args) };
}

/// Check and compile a pattern. Everything is allocated from `allocator` (an arena in every caller).
pub fn compile(allocator: std.mem.Allocator, pattern: []const u8, mode: Mode, case: Case, whole_word: bool) error{OutOfMemory}!CompileOutcome {
    if (pattern.len == 0 or pattern.len > max_pattern_bytes) return refuse(allocator, "pattern must be 1..{d} bytes", .{max_pattern_bytes});
    if (!std.unicode.utf8ValidateSlice(pattern)) return refuse(allocator, "pattern is not valid UTF-8", .{});
    {
        var view = std.unicode.Utf8View.initUnchecked(pattern);
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| if (isLineBreak(cp)) return refuse(allocator, "pattern holds a line break; matching is per line", .{});
    }

    var root: Node = undefined;
    var class_items: []const []const Item = &.{};
    var class_negated: []const bool = &.{};
    var written: []const u21 = &.{};
    switch (mode) {
        .literal => {
            var chars = std.ArrayList(Node).empty;
            var cps = std.ArrayList(u21).empty;
            var view = std.unicode.Utf8View.initUnchecked(pattern);
            var it = view.iterator();
            while (it.nextCodepoint()) |cp| {
                try chars.append(allocator, .{ .char = cp });
                try cps.append(allocator, cp);
            }
            root = if (chars.items.len == 1) chars.items[0] else .{ .cat = chars.items };
            written = cps.items;
        },
        .regex => {
            var parser = Parser{ .allocator = allocator, .text = pattern };
            root = parser.alternation() catch |err| switch (err) {
                error.Refused => return refuse(allocator, "pattern not supported at byte {d}: {s}", .{ parser.refusal_at, parser.refusal }),
                error.OutOfMemory => return error.OutOfMemory,
            };
            if (parser.at != pattern.len) return refuse(allocator, "pattern not supported at byte {d}: {s}", .{ parser.at, "a ) has no (" });
            class_items = parser.classes.items;
            class_negated = parser.negations.items;
            written = parser.written.items;
        },
    }

    const applied: Applied = switch (case) {
        .sensitive => .sensitive,
        .insensitive => .insensitive,
        .smart => for (written) |cp| {
            if (fold(cp) != cp) break .sensitive;
        } else .insensitive,
    };
    const insensitive = applied == .insensitive;

    // The program, built for every pattern so its size is checked the same way whatever the strategy.
    var compiler = Compiler{ .allocator = allocator, .fold_chars = insensitive };
    compiler.whole(root, whole_word) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TooLarge => return refuse(allocator, "pattern not supported at byte 0: the pattern is too large (over 8,192 steps)", .{}),
    };

    const classes = try allocator.alloc(Class, class_items.len);
    for (classes, class_items, class_negated) |*class, items, negated| {
        class.* = .{ .negated = negated, .members = try Members.of(allocator, items) };
        if (insensitive) class.extras = try foldExtras(allocator, &class.members);
        class.cost = 1 + class.members.searches() + @intFromBool(class.extras.len > 0);
        for (0..128) |c| class.ascii[c] = class.evaluate(@intCast(c));
    }

    var compiled = Compiled{
        .mode = mode,
        .case_applied = applied,
        .whole_word = whole_word,
        .strategy = .vm,
        .program = compiler.program.items,
        .classes = classes,
        .matches_empty = mode == .regex and nullable(root),
    };
    if (try literalOf(allocator, root)) |needle| {
        compiled.needle = needle;
        if (!insensitive or noAsciiLetters(needle)) {
            compiled.strategy = .bytes;
        } else if (asciiFoldExact(needle)) {
            compiled.strategy = .ascii_ci;
        }
    }
    return .{ .ok = compiled };
}

/// An ASCII needle with no letter folds to itself and nothing else folds to it: a byte search is exact.
fn noAsciiLetters(needle: []const u8) bool {
    for (needle) |byte| if (byte >= 0x80 or std.ascii.isAlphabetic(byte)) return false;
    return true;
}

/// An ASCII needle with no s, S, k or K: `std.ascii` case-insensitive search is the simple fold exactly.
fn asciiFoldExact(needle: []const u8) bool {
    for (needle) |byte| switch (byte) {
        0x80...0xFF, 's', 'S', 'k', 'K' => return false,
        else => {},
    };
    return true;
}

/// The folds of a class's members that are not members themselves, sorted and unique.
fn foldExtras(allocator: std.mem.Allocator, members: *const Members) ![]const u21 {
    // `\w`, `\d`, `\s` and their negations are closed under the fold (a test below checks the whole table), so
    // only a range can add a fold that is not a member: the pairs whose code point lies in one, found by a
    // binary search of the (sorted) table per range.
    if (members.all) return &.{};
    var extras = std.ArrayList(u21).empty;
    const pairs = &tables.casefold_pairs;
    for (members.ranges) |r| {
        var lo: usize = 0;
        var hi: usize = pairs.len;
        while (lo < hi) {
            work(1);
            const mid = lo + (hi - lo) / 2;
            if (pairs[mid].from < r[0]) lo = mid + 1 else hi = mid;
        }
        while (lo < pairs.len and pairs[lo].from <= r[1]) : (lo += 1) {
            work(1);
            if (!members.contains(pairs[lo].to)) try extras.append(allocator, pairs[lo].to);
        }
    }
    std.mem.sort(u21, extras.items, {}, std.sort.asc(u21));
    work(extras.items.len * (std.math.log2_int_ceil(usize, extras.items.len + 1) + 1));
    var kept: usize = 0;
    for (extras.items) |cp| {
        if (kept > 0 and extras.items[kept - 1] == cp) continue;
        extras.items[kept] = cp;
        kept += 1;
    }
    return extras.items[0..kept];
}

// ----------------------------------------------------------------- decoding ---

const Decoded = struct { cp: u21, len: u3 };

/// The code point at byte `at` (U+FFFD and one byte for an invalid sequence; never reads past `bytes`).
fn decodeAt(bytes: []const u8, at: usize) Decoded {
    const len = std.unicode.utf8ByteSequenceLength(bytes[at]) catch return .{ .cp = 0xFFFD, .len = 1 };
    if (at + len > bytes.len) return .{ .cp = 0xFFFD, .len = 1 };
    const cp = std.unicode.utf8Decode(bytes[at .. at + len]) catch return .{ .cp = 0xFFFD, .len = 1 };
    return .{ .cp = cp, .len = len };
}

/// The code point that ends just before byte `at`, or null at 0.
fn decodeBefore(bytes: []const u8, at: usize) ?u21 {
    if (at == 0) return null;
    var start = at - 1;
    var steps: usize = 0;
    while (start > 0 and steps < 3 and bytes[start] & 0xC0 == 0x80) : (steps += 1) start -= 1;
    const d = decodeAt(bytes, start);
    if (start + d.len != at) return 0xFFFD;
    return d.cp;
}

/// The byte `n` code points after byte `at` (as `decodeAt` steps).
fn advance(bytes: []const u8, at: usize, n: u32) usize {
    var i = at;
    for (0..n) |_| i += decodeAt(bytes, i).len;
    return i;
}

/// The first index at or after `from` holding `a` or `b`, or `bytes.len`.
fn indexOfEither(bytes: []const u8, from: usize, a: u8, b: u8) usize {
    const lanes = 16;
    const Block = @Vector(lanes, u8);
    var at = from;
    while (bytes.len - at >= lanes) : (at += lanes) {
        const block: Block = bytes[at..][0..lanes].*;
        const hits_a: u16 = @bitCast(block == @as(Block, @splat(a)));
        const hits_b: u16 = @bitCast(block == @as(Block, @splat(b)));
        if (hits_a | hits_b != 0) return at + @ctz(hits_a | hits_b);
    }
    while (at < bytes.len) : (at += 1) if (bytes[at] == a or bytes[at] == b) return at;
    return at;
}

/// The number of code points in `bytes` (as `decodeAt` steps).
pub fn codepointCount(bytes: []const u8) u32 {
    var at: usize = 0;
    var n: u32 = 0;
    while (at < bytes.len) : (n += 1) at += decodeAt(bytes, at).len;
    return n;
}

// ------------------------------------------------------------------- budget ---

/// A clock in nanoseconds; tests inject their own.
pub const Clock = struct {
    context: ?*anyopaque = null,
    now: *const fn (?*anyopaque) u64,
};

pub const Budget = struct {
    clock: Clock,
    deadline: u64,
    /// While a grace runs (`grace`), the clock it runs to; 0 for none.
    floor: u64 = 0,
    spent: bool = false,
    /// Work charged since the clock was last read.
    units: u64 = 0,

    pub fn start(clock: Clock, budget_ms: u32) Budget {
        return .{ .clock = clock, .deadline = clock.now(clock.context) +| @as(u64, budget_ms) * std.time.ns_per_ms };
    }

    pub fn expired(budget: *Budget) bool {
        if (!budget.spent and budget.clock.now(budget.clock.context) >= @max(budget.deadline, budget.floor)) budget.spent = true;
        return budget.spent;
    }

    /// Charge `units` of work; the clock is read once `check_units` have built up.
    pub fn charge(budget: *Budget, units: u64) error{OutOfTime}!void {
        if (counts_work) units_charged += units;
        budget.units += units;
        if (budget.units < check_units) return;
        budget.units = 0;
        if (budget.expired()) return error.OutOfTime;
    }

    /// Keep going until at least `grace_ms` from now, whatever the deadline (`scan`: a page's first line). True
    /// when the deadline had already passed.
    pub fn grace(budget: *Budget, grace_ms: u64) bool {
        const now = budget.clock.now(budget.clock.context);
        budget.floor = now +| grace_ms * std.time.ns_per_ms;
        budget.spent = false;
        return now >= budget.deadline;
    }

    pub fn endGrace(budget: *Budget) void {
        budget.floor = 0;
    }
};

// -------------------------------------------------------------------- the VM ---

pub const Span = struct { start: u32, end: u32, end_byte: usize };

/// A position between two code points, as the assertions see it.
const Around = struct { first: bool, last: bool, before_word: bool, after_word: bool };

/// The matcher of one compiled pattern: the VM's lists, set up once.
pub const Matcher = struct {
    compiled: *const Compiled,
    budget: ?*Budget = null,
    // The VM: two thread lists of (pc, start), a sparse set for "already on the list at this position", a stack.
    pcs: [2][]u32 = .{ &.{}, &.{} },
    starts: [2][]u32 = .{ &.{}, &.{} },
    lens: [2]usize = .{ 0, 0 },
    dense: []u32 = &.{},
    sparse: []u32 = &.{},
    marks: usize = 0,
    stack: []u32 = &.{},
    stack_starts: []u32 = &.{},
    /// VM work since the last charge.
    units: u64 = 0,
    /// The program tests word boundaries (`\b`, `\B`, whole word): each position tests the code point after it.
    word_asserts: bool = false,
    /// The units a position charges: one, one more for the fold of an insensitive pattern, two more for the word
    /// test (its two table searches).
    position_cost: u64 = 1,
    /// The literal strategies: the needle as compared (ASCII-lowered for `ascii_ci`), its Knuth-Morris-Pratt
    /// prefix table and its length in code points.
    key: []const u8 = "",
    prefix: []const u32 = &.{},
    key_cps: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, compiled: *const Compiled, budget: ?*Budget) !Matcher {
        var m = Matcher{ .compiled = compiled, .budget = budget };
        if (compiled.strategy != .vm) {
            const needle = compiled.needle;
            const key = try allocator.alloc(u8, needle.len);
            for (key, needle) |*k, byte| k.* = if (compiled.strategy == .ascii_ci) std.ascii.toLower(byte) else byte;
            const prefix = try allocator.alloc(u32, needle.len);
            prefix[0] = 0;
            var k: u32 = 0;
            for (1..key.len) |i| {
                while (k > 0 and key[i] != key[k]) k = prefix[k - 1];
                if (key[i] == key[k]) k += 1;
                prefix[i] = k;
            }
            m.key = key;
            m.prefix = prefix;
            m.key_cps = codepointCount(needle);
            return m;
        }
        for (compiled.program) |inst| switch (inst) {
            .assert => |a| if (a != .bol and a != .eol) {
                m.word_asserts = true;
            },
            else => {},
        };
        m.position_cost = 1 + @as(u64, @intFromBool(compiled.case_applied == .insensitive)) + (if (m.word_asserts) @as(u64, 2) else 0);
        const n = compiled.program.len;
        m.pcs = .{ try allocator.alloc(u32, n), try allocator.alloc(u32, n) };
        m.starts = .{ try allocator.alloc(u32, n), try allocator.alloc(u32, n) };
        m.dense = try allocator.alloc(u32, n);
        m.sparse = try allocator.alloc(u32, n);
        @memset(m.sparse, 0);
        m.stack = try allocator.alloc(u32, 2 * n + 2);
        m.stack_starts = try allocator.alloc(u32, 2 * n + 2);
        return m;
    }

    pub const LineMatch = struct {
        hit: bool,
        /// The bytes of the line the hit's `text` keeps: the `text_len` given, or less when regex mode found more
        /// than `max_matches_per_line` non-empty matches starting within it (the text then ends where the next
        /// one starts).
        text_len: usize,
        /// The text was cut at the 17th non-empty match (rework 2, ruling 4).
        matches_truncated: bool,
    };

    /// Whether `line` (no terminator) is a hit, and its matches starting within its text (the first `text_len`
    /// bytes, `text_cps` code points), non-empty ones only, ends clipped to the text, appended to `offsets`
    /// (Python's `finditer` order).
    pub fn matchLine(m: *Matcher, allocator: std.mem.Allocator, line: []const u8, text_len: usize, text_cps: u32, offsets: *std.ArrayList([2]u32)) error{ OutOfMemory, OutOfTime }!LineMatch {
        var hit = false;
        var from: usize = 0;
        var from_cp: u32 = 0;
        var forbid: ?u32 = null;
        while (from <= line.len) {
            const span = (try m.search(line, from, from_cp, forbid)) orelse break;
            hit = true;
            if (span.start >= text_cps) break;
            // An empty match is not listed, so it neither counts towards the 16 nor cuts the text (rework 2,
            // ruling 4). There is at most one per code point of the text, each search charged to the budget.
            if (span.start == span.end) {
                forbid = span.end;
                from = span.end_byte;
                from_cp = span.end;
                continue;
            }
            if (m.compiled.mode == .regex and offsets.items.len == max_matches_per_line) {
                return .{ .hit = true, .text_len = advance(line, from, span.start - from_cp), .matches_truncated = true };
            }
            try offsets.append(allocator, .{ span.start, @min(span.end, text_cps) });
            forbid = null;
            from = span.end_byte;
            from_cp = span.end;
        }
        return .{ .hit = hit, .text_len = text_len, .matches_truncated = false };
    }

    /// The leftmost-first match at or after byte `from` (code point `from_cp`), not an empty one at `forbid`.
    pub fn search(m: *Matcher, line: []const u8, from: usize, from_cp: u32, forbid: ?u32) error{OutOfTime}!?Span {
        return switch (m.compiled.strategy) {
            .vm => m.searchVm(line, from, from_cp, forbid),
            .bytes, .ascii_ci => m.searchLiteral(line, from, from_cp),
        };
    }

    fn charge(m: *Matcher, units: u64) error{OutOfTime}!void {
        if (m.budget) |budget| try budget.charge(units);
    }

    /// Knuth-Morris-Pratt's state over one line: the next byte to read, the needle's bytes matched before it and
    /// the first byte not yet charged to the budget.
    const Kmp = struct { at: usize, matched: u32 = 0, charged: usize };

    /// The next occurrence of the needle in `line` from `state`, as the byte where it starts; `state` then
    /// continues after it, overlapping occurrences included. Each byte is read once (a mismatch falls back
    /// along the prefix table without rereading), so the search is linear in the line whatever the needle; the
    /// budget is charged at least once per `check_units` bytes passed.
    fn nextOccurrence(m: *Matcher, line: []const u8, state: *Kmp) error{OutOfTime}!?usize {
        const key = m.key;
        const lower = m.compiled.strategy == .ascii_ci;
        var at = state.at;
        var matched = state.matched;
        defer {
            state.at = at;
            state.matched = matched;
        }
        while (at < line.len) {
            if (at - state.charged >= check_units) {
                work(at - state.charged);
                try m.charge(at - state.charged);
                state.charged = at;
            }
            if (matched == 0) {
                // Skip to the next byte that can start the needle, a bounded window at a time.
                const window = line[0..@min(line.len, at + check_units)];
                at = if (lower and std.ascii.isAlphabetic(key[0]))
                    indexOfEither(window, at, key[0], std.ascii.toUpper(key[0]))
                else
                    std.mem.indexOfScalarPos(u8, window, at, key[0]) orelse window.len;
                if (at == window.len) continue;
            }
            const byte = if (lower) std.ascii.toLower(line[at]) else line[at];
            while (matched > 0 and key[matched] != byte) {
                work(1);
                matched = m.prefix[matched - 1];
            }
            if (key[matched] == byte) matched += 1;
            at += 1;
            if (matched == key.len) {
                matched = m.prefix[matched - 1];
                work(at - state.charged);
                try m.charge(at - state.charged);
                state.charged = at;
                return at - key.len;
            }
        }
        work(at - state.charged);
        try m.charge(at - state.charged);
        state.charged = at;
        return null;
    }

    fn searchLiteral(m: *Matcher, line: []const u8, from: usize, from_cp: u32) error{OutOfTime}!?Span {
        var state = Kmp{ .at = from, .charged = from };
        var at = from;
        var at_cp = from_cp;
        while (try m.nextOccurrence(line, &state)) |found| {
            const start_cp = at_cp + codepointCount(line[at..found]);
            at = found;
            at_cp = start_cp;
            const end = found + m.key.len;
            if (m.compiled.whole_word) {
                const before = decodeBefore(line, found);
                const after: ?u21 = if (end < line.len) decodeAt(line, end).cp else null;
                // Not a whole word here: the next occurrence, overlapping this one or not.
                if ((before != null and isWord(before.?)) or (after != null and isWord(after.?))) continue;
            }
            return .{ .start = start_cp, .end = start_cp + m.key_cps, .end_byte = end };
        }
        return null;
    }

    fn onList(m: *Matcher, pc: u32) bool {
        const s = m.sparse[pc];
        return s < m.marks and m.dense[s] == pc;
    }

    fn mark(m: *Matcher, pc: u32) void {
        m.sparse[pc] = @intCast(m.marks);
        m.dense[m.marks] = pc;
        m.marks += 1;
    }

    /// Follow jumps, splits and assertions from `pc0` at the position between `prev` and `next`, in priority
    /// order, appending the threads that wait on a code point (or `match`) to list `which`.
    fn add(m: *Matcher, which: usize, pc0: u32, start: u32, at: Around) void {
        const program = m.compiled.program;
        m.stack[0] = pc0;
        m.stack_starts[0] = start;
        var top: usize = 1;
        while (top > 0) {
            top -= 1;
            m.units += 1;
            work(1);
            const pc = m.stack[top];
            const s = m.stack_starts[top];
            if (m.onList(pc)) continue;
            m.mark(pc);
            switch (program[pc]) {
                .jmp => |target| {
                    m.stack[top] = target;
                    m.stack_starts[top] = s;
                    top += 1;
                },
                .split => |targets| {
                    m.stack[top] = targets[1];
                    m.stack_starts[top] = s;
                    m.stack[top + 1] = targets[0];
                    m.stack_starts[top + 1] = s;
                    top += 2;
                },
                .assert => |a| {
                    const ok = switch (a) {
                        .bol => at.first,
                        .eol => at.last,
                        .boundary => at.before_word != at.after_word,
                        .not_boundary => at.before_word == at.after_word,
                        .prev_not_word => !at.before_word,
                        .next_not_word => !at.after_word,
                    };
                    if (ok) {
                        m.stack[top] = pc + 1;
                        m.stack_starts[top] = s;
                        top += 1;
                    }
                },
                else => {
                    m.pcs[which][m.lens[which]] = pc;
                    m.starts[which][m.lens[which]] = s;
                    m.lens[which] += 1;
                },
            }
        }
    }

    /// Charge the VM's work since the last position: each thread followed or stepped (a step on a class outside
    /// ASCII its `Class.cost`), and the position itself, `position_cost` (its decoding, fold and word test).
    fn tick(m: *Matcher) error{OutOfTime}!void {
        const units = m.units + m.position_cost;
        m.units = 0;
        try m.charge(units);
    }

    fn searchVm(m: *Matcher, line: []const u8, from: usize, from_cp: u32, forbid: ?u32) error{OutOfTime}!?Span {
        const program = m.compiled.program;
        const classes = m.compiled.classes;
        const folded = m.compiled.case_applied == .insensitive;
        var at = from;
        var cpi = from_cp;
        var prev: ?u21 = decodeBefore(line, from);
        if (folded) prev = if (prev) |c| fold(c) else null;
        // The word test of the code points either side of a position, done once per code point and only for a
        // program that asks (so an assertion followed is one step, whatever the code point).
        const words = m.word_asserts;
        var prev_word = words and prev != null and isWord(prev.?);
        var current: usize = 0;
        m.lens = .{ 0, 0 };
        var matched: ?Span = null;
        while (true) {
            try m.tick();
            work(1);
            var width: usize = 0;
            const next: ?u21 = if (at < line.len) blk: {
                const d = decodeAt(line, at);
                width = d.len;
                break :blk if (folded) fold(d.cp) else d.cp;
            } else null;
            const next_word = words and next != null and isWord(next.?);
            const around = Around{ .first = prev == null, .last = next == null, .before_word = prev_word, .after_word = next_word };
            // The closure of the carried threads, then (until something matched) a new thread starting here.
            const carried = m.lens[current];
            const other = 1 - current;
            m.lens[other] = 0;
            m.marks = 0;
            for (0..carried) |i| m.add(other, m.pcs[current][i], m.starts[current][i], around);
            if (matched == null) m.add(other, 0, cpi, around);
            current = other;
            if (m.lens[current] == 0) {
                if (matched != null or next == null) break;
                at += width;
                cpi += 1;
                prev = next;
                prev_word = next_word;
                continue;
            }
            // Step: consume `next`, in priority order; a `match` cuts every thread after it.
            const list_len = m.lens[current];
            m.units += list_len;
            const out = 1 - current;
            m.lens[out] = 0;
            for (0..list_len) |i| {
                work(1);
                const pc = m.pcs[current][i];
                const s = m.starts[current][i];
                const take = switch (program[pc]) {
                    .match => {
                        if (forbid != null and s == forbid.? and cpi == forbid.?) continue;
                        matched = .{ .start = s, .end = cpi, .end_byte = at };
                        break;
                    },
                    .char => |c| next != null and next.? == c,
                    .any => next != null,
                    .class => |k| blk: {
                        const cp = next orelse break :blk false;
                        if (cp >= 128) m.units += classes[k].cost - 1;
                        break :blk classes[k].contains(cp);
                    },
                    else => false,
                };
                if (take) {
                    m.pcs[out][m.lens[out]] = pc + 1;
                    m.starts[out][m.lens[out]] = s;
                    m.lens[out] += 1;
                }
            }
            if (next == null) break;
            current = out;
            if (m.lens[current] == 0 and matched != null) break;
            at += width;
            cpi += 1;
            prev = next;
            prev_word = next_word;
        }
        return matched;
    }
};

/// The pattern families of the compile and meter fuzz (rework 2, rulings 2 and 3), shared by the tests below,
/// which count the work, and `scripts/prototypes/s6t24/rework2/meter_bench.zig`, which times the same work with a
/// clock outside the default run. The library never calls them.
pub const fuzz = struct {
    /// Patterns of at most `max_len` bytes drawn from a grammar that favours what costs the compiler work: nested
    /// counted repeats, empty groups, assertions, classes with ranges, alternations.
    pub fn randomPattern(random: std.Random, out: *std.ArrayList(u8), arena: std.mem.Allocator, depth: u32) !void {
        const atoms = [_][]const u8{ "a", "é", ".", "\\w", "\\d", "\\S", "[a-z]", "[^a-cK-Z0-9]", "[ſK\\d]", "(?:)", "^", "$", "\\b", "\\B", "K", "ß" };
        const repeats = [_][]const u8{ "", "", "*", "+", "?", "{255}", "{0,255}", "{2,}", "{1,3}", "{200,255}" };
        const pick = random.uintLessThan(u32, if (depth == 0) 1 else 4);
        switch (pick) {
            0 => try out.appendSlice(arena, atoms[random.uintLessThan(usize, atoms.len)]),
            1 => {
                try out.appendSlice(arena, "(?:");
                try randomPattern(random, out, arena, depth - 1);
                try out.appendSlice(arena, ")");
            },
            2 => {
                try randomPattern(random, out, arena, depth - 1);
                try randomPattern(random, out, arena, depth - 1);
            },
            else => {
                try randomPattern(random, out, arena, depth - 1);
                try out.append(arena, '|');
                try randomPattern(random, out, arena, depth - 1);
            },
        }
        if (out.items.len > 0 and out.items[out.items.len - 1] != '|' and out.items[out.items.len - 1] != '(') {
            try out.appendSlice(arena, repeats[random.uintLessThan(usize, repeats.len)]);
        }
    }

    /// Up to 1,024 bytes of `[...]` classes, each of random items (ranges, escapes, single code points, inside and
    /// outside ASCII) and maybe negated, each followed by a random repeat.
    pub fn randomClasses(random: std.Random, out: *std.ArrayList(u8), arena: std.mem.Allocator) !void {
        const items = [_][]const u8{ "\\w", "\\W", "\\d", "\\D", "\\s", "\\S", "a-z", "A-Z", "0-9", "é", "ß-ſ", "Α-ω", "а-я", "K", "ſ", "\\-", "→", "ā-ž" };
        const repeats = [_][]const u8{ "", "*", "+", "?", "{255}", "{0,255}", "{1,3}" };
        while (true) {
            var class = std.ArrayList(u8).empty;
            try class.append(arena, '[');
            if (random.boolean()) try class.append(arena, '^');
            const count = 1 + random.uintLessThan(usize, 600);
            for (0..count) |_| try class.appendSlice(arena, items[random.uintLessThan(usize, items.len)]);
            try class.append(arena, ']');
            try class.appendSlice(arena, repeats[random.uintLessThan(usize, repeats.len)]);
            if (out.items.len + class.items.len > max_pattern_bytes) return;
            try out.appendSlice(arena, class.items);
        }
    }

    /// The patterns of the compile and meter fuzz (rework 2, rulings 2 and 3): crafted ones at the caps (empty
    /// repeats nested as deep as 1,024 bytes allow, the work cap's edge, 1,024-byte classes of 508 `\w`, `\W`,
    /// `\s` or `\d`, a class of 200 ranges, 204 classes, full-range classes, 510 alternatives), then `random`
    /// patterns of up to 1,024 bytes and `random` class-heavy ones.
    pub fn patterns(arena: std.mem.Allocator, random_count: usize) ![]const []const u8 {
        var prng = std.Random.DefaultPrng.init(20261124);
        const random = prng.random();
        var crafted = std.ArrayList([]const u8).empty;
        {
            var nest = std.ArrayList(u8).empty;
            try nest.appendSlice(arena, "(?:)(?:)");
            while (nest.items.len + 9 <= max_pattern_bytes) {
                const inner = try arena.dupe(u8, nest.items);
                nest.clearRetainingCapacity();
                try nest.appendSlice(arena, "(?:");
                try nest.appendSlice(arena, inner);
                try nest.appendSlice(arena, "){255}");
            }
            try crafted.append(arena, nest.items);
        }
        try crafted.append(arena, "(?:a{255}){31}");
        try crafted.append(arena, "(?:(?:(?:)a){255}){32}");
        try crafted.append(arena, "(?:[a-z]{255}){31}");
        try crafted.append(arena, "(?:a|b|c|d|e|f|g|h|i|j|k|l|m|n|o|p|q|r|s|t|u|v|w|x|y|z){255}");
        for ([_][]const u8{ "\\w", "\\W", "\\s", "\\S", "\\d" }) |escape| {
            try crafted.append(arena, try std.fmt.allocPrint(arena, "[^{s}]{{255}}", .{try repeatText(arena, escape, 508)}));
            try crafted.append(arena, try std.fmt.allocPrint(arena, "[{s}]{{255}}", .{try repeatText(arena, escape, 508)}));
        }
        try crafted.append(arena, try repeatText(arena, "\\w", 512));
        try crafted.append(arena, try repeatText(arena, "\\b", 512));
        try crafted.append(arena, try repeatText(arena, "[A-Z]", 204));
        try crafted.append(arena, try repeatText(arena, "[ -\u{ffff}]", 146));
        try crafted.append(arena, try repeatText(arena, "[a-zA-Z0-9ſK]", 73));
        {
            // One class of 200 ranges outside ASCII (Greek and Cyrillic pairs: folds to add), then a repeat.
            var class = std.ArrayList(u8).empty;
            try class.append(arena, '[');
            var cp: u21 = 0x391;
            while (class.items.len + 16 < max_pattern_bytes) : (cp += 3) {
                try appendUtf8(arena, &class, cp);
                try class.append(arena, '-');
                try appendUtf8(arena, &class, cp + 1);
            }
            try class.appendSlice(arena, "]{255}");
            try crafted.append(arena, class.items);
        }
        {
            var alternatives = std.ArrayList(u8).empty;
            try alternatives.append(arena, 'a');
            while (alternatives.items.len + 2 <= max_pattern_bytes) try alternatives.appendSlice(arena, "|a");
            try crafted.append(arena, alternatives.items);
        }
        var drawn: usize = 0;
        while (drawn < random_count) : (drawn += 1) {
            var out = std.ArrayList(u8).empty;
            if (drawn % 4 == 3) try randomClasses(random, &out, arena) else try randomPattern(random, &out, arena, if (drawn % 2 == 0) 6 else 9);
            if (out.items.len == 0 or out.items.len > max_pattern_bytes) continue;
            try crafted.append(arena, out.items);
        }
        return crafted.items;
    }

    pub fn repeatText(arena: std.mem.Allocator, text: []const u8, times: usize) ![]const u8 {
        var out = std.ArrayList(u8).empty;
        for (0..times) |_| try out.appendSlice(arena, text);
        return out.items;
    }

    pub fn repeatCodepoints(arena: std.mem.Allocator, text: []const u8, total_bytes: usize) ![]u8 {
        const out = try arena.alloc(u8, total_bytes - total_bytes % text.len);
        var at: usize = 0;
        while (at < out.len) : (at += text.len) @memcpy(out[at..][0..text.len], text);
        return out;
    }

    pub const MeterCase = struct { pattern: []const u8, mode: Mode, case: Case, line: []const u8 };

    /// The meter's heaviest units: the verifier's 1,024-byte classes over code points outside ASCII (Verdict 2,
    /// finding 2), a class with every kind of member and folds, word boundaries and a fold at every position, the
    /// heaviest ASCII program, a listing that restarts, and the two literal strategies, each over a long line.
    pub fn meterCases(arena: std.mem.Allocator) ![]const MeterCase {
        const ascii = try repeatCodepoints(arena, "abcdefghij x", 1 << 20);
        const arrows = try repeatCodepoints(arena, "→", 3 << 16);
        const accents = try repeatCodepoints(arena, "é", 2 << 16);
        const mixed = try repeatCodepoints(arena, "Ωж→ 1ſK ", 1 << 18);
        const cases = [_]MeterCase{
            .{ .pattern = try std.fmt.allocPrint(arena, "[^{s}]{{255}}", .{try repeatText(arena, "\\w", 508)}), .mode = .regex, .case = .sensitive, .line = arrows },
            .{ .pattern = try std.fmt.allocPrint(arena, "[^{s}]{{255}}", .{try repeatText(arena, "\\s", 508)}), .mode = .regex, .case = .sensitive, .line = arrows },
            .{ .pattern = try std.fmt.allocPrint(arena, "[^{s}]{{255}}", .{try repeatText(arena, "\\W", 508)}), .mode = .regex, .case = .sensitive, .line = accents },
            .{ .pattern = "(?:[\\d\\sα-ωа-яK]|\\b){1,255}(?:[^\\w\\d]|\\B){1,255}z", .mode = .regex, .case = .insensitive, .line = mixed },
            .{ .pattern = "(?:\\w|\\W){1,255}(?:\\w|\\W){1,255}z", .mode = .regex, .case = .insensitive, .line = mixed },
            .{ .pattern = "(?:[a-j ]{1,255}){15}z", .mode = .regex, .case = .sensitive, .line = ascii },
            .{ .pattern = "(?:\\w|\\W){1,255}(?:\\w|\\W){1,255}z", .mode = .regex, .case = .insensitive, .line = ascii },
            .{ .pattern = "a(.*z)?", .mode = .regex, .case = .sensitive, .line = ascii },
            .{ .pattern = "abcdefghij z", .mode = .literal, .case = .sensitive, .line = ascii },
            .{ .pattern = "ABCDEFGHIJ Z", .mode = .literal, .case = .insensitive, .line = ascii },
            .{ .pattern = "ωж→ 1ſk ωж→ 1ſk z", .mode = .literal, .case = .insensitive, .line = mixed },
        };
        return try arena.dupe(MeterCase, &cases);
    }
};

// -------------------------------------------------------------------- tests ---

const testing = std.testing;

fn compileOk(arena: std.mem.Allocator, pattern: []const u8, mode: Mode, case: Case, whole_word: bool) !Compiled {
    return switch (try compile(arena, pattern, mode, case, whole_word)) {
        .ok => |c| c,
        .refused => |message| {
            std.debug.print("refused {s}: {s}\n", .{ pattern, message });
            return error.TestUnexpectedResult;
        },
    };
}

fn offsetsOf(arena: std.mem.Allocator, pattern: []const u8, mode: Mode, case: Case, whole_word: bool, line: []const u8) !?[]const [2]u32 {
    const compiled = try arena.create(Compiled);
    compiled.* = try compileOk(arena, pattern, mode, case, whole_word);
    var matcher = try Matcher.init(arena, compiled, null);
    var offsets = std.ArrayList([2]u32).empty;
    const result = try matcher.matchLine(arena, line, line.len, codepointCount(line), &offsets);
    if (!result.hit) return null;
    return offsets.items;
}

fn expectOffsets(pattern: []const u8, mode: Mode, case: Case, whole_word: bool, line: []const u8, expected: ?[]const [2]u32) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const got = try offsetsOf(arena_state.allocator(), pattern, mode, case, whole_word, line);
    if (expected == null) {
        if (got != null) {
            std.debug.print("{s} over \"{s}\": expected no hit, got {any}\n", .{ pattern, line, got.? });
            return error.TestUnexpectedResult;
        }
        return;
    }
    if (got == null) {
        std.debug.print("{s} over \"{s}\": expected {any}, got no hit\n", .{ pattern, line, expected.? });
        return error.TestUnexpectedResult;
    }
    testing.expectEqualSlices([2]u32, expected.?, got.?) catch |err| {
        std.debug.print("{s} over \"{s}\"\n", .{ pattern, line });
        return err;
    };
}

fn expectRefused(pattern: []const u8, mode: Mode, expected: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    switch (try compile(arena_state.allocator(), pattern, mode, .smart, false)) {
        .ok => {
            std.debug.print("accepted {s}, expected \"{s}\"\n", .{ pattern, expected });
            return error.TestUnexpectedResult;
        },
        .refused => |message| testing.expectEqualStrings(expected, message) catch |err| {
            std.debug.print("pattern {s}\n", .{pattern});
            return err;
        },
    }
}

test "S6-T24 pattern: every refusal of ADR 0006 section 2, with its byte offset and message" {
    const p = "pattern not supported at byte ";
    const cases = [_][2][]const u8{
        .{ "a(?=b)", p ++ "1: look-around and inline flags are not supported" },
        .{ "(?!b)", p ++ "0: look-around and inline flags are not supported" },
        .{ "(?<=b)", p ++ "0: look-around and inline flags are not supported" },
        .{ "(?i)a", p ++ "0: look-around and inline flags are not supported" },
        .{ "(?", p ++ "0: look-around and inline flags are not supported" },
        .{ "(a)\\1", p ++ "3: back-references are not supported" },
        .{ "\\n", p ++ "0: an escape outside the subset" },
        .{ "x\\x41", p ++ "1: an escape outside the subset" },
        .{ "\\p{L}", p ++ "0: an escape outside the subset" },
        .{ "\\A", p ++ "0: an escape outside the subset" },
        .{ "\\Z", p ++ "0: an escape outside the subset" },
        .{ "\\0", p ++ "0: an escape outside the subset" },
        .{ "\\é", p ++ "0: an escape outside the subset" },
        .{ "[\\b]", p ++ "1: \\b inside a class is not supported" },
        .{ "[a\\B]", p ++ "2: \\b inside a class is not supported" },
        .{ "[[:alpha:]]", p ++ "1: a [ inside a class must be escaped" },
        .{ "[a-[]", p ++ "3: a [ inside a class must be escaped" },
        .{ "a*?", p ++ "2: lazy and possessive repeats are not supported" },
        .{ "a+?", p ++ "2: lazy and possessive repeats are not supported" },
        .{ "a??", p ++ "2: lazy and possessive repeats are not supported" },
        .{ "a{1,2}?", p ++ "6: lazy and possessive repeats are not supported" },
        .{ "a*+", p ++ "2: lazy and possessive repeats are not supported" },
        .{ "a++", p ++ "2: lazy and possessive repeats are not supported" },
        .{ "a?+", p ++ "2: lazy and possessive repeats are not supported" },
        .{ "*a", p ++ "0: a repeat follows nothing it can repeat" },
        .{ "a**", p ++ "2: a repeat follows nothing it can repeat" },
        .{ "a{2}{3}", p ++ "4: a repeat follows nothing it can repeat" },
        .{ "^*", p ++ "1: a repeat follows nothing it can repeat" },
        .{ "$+", p ++ "1: a repeat follows nothing it can repeat" },
        .{ "\\b?", p ++ "2: a repeat follows nothing it can repeat" },
        .{ "a|*", p ++ "2: a repeat follows nothing it can repeat" },
        .{ "(?:)*", p ++ "4: a repeat follows nothing it can repeat" },
        .{ "a{", p ++ "1: a repeat {m,n} needs a number" },
        .{ "a{,3}", p ++ "1: a repeat {m,n} needs a number" },
        .{ "a{2,x}", p ++ "1: a repeat {m,n} needs a number" },
        .{ "a{2", p ++ "1: a repeat {m,n} is not closed" },
        .{ "a{2,3", p ++ "1: a repeat {m,n} is not closed" },
        .{ "a{256}", p ++ "1: a repeat bound is over 255" },
        .{ "a{1,99999999999}", p ++ "1: a repeat bound is over 255" },
        .{ "a{3,2}", p ++ "1: a repeat {m,n} has n below m" },
        .{ "x[abc", p ++ "1: a class [...] is not closed" },
        .{ "[]", p ++ "0: a class [...] is not closed" },
        .{ "[^]", p ++ "0: a class [...] is not closed" },
        .{ "[z-a]", p ++ "1: a class range is reversed" },
        .{ "[a-\\d]", p ++ "3: an escape outside the subset" },
        .{ "(ab", p ++ "0: a group is not closed" },
        .{ "a(b(c)", p ++ "1: a group is not closed" },
        .{ "ab)", p ++ "2: a ) has no (" },
        .{ "a\\", p ++ "1: the pattern ends with a backslash" },
        .{ "[a\\", p ++ "2: the pattern ends with a backslash" },
        .{ "(a{255}){255}", p ++ "0: the pattern is too large (over 8,192 steps)" },
    };
    for (cases) |case| try expectRefused(case[0], .regex, case[1]);
}

test "S6-T24 pattern: refused in both modes before parsing" {
    var long: [1025]u8 = undefined;
    @memset(&long, 'a');
    for ([_]Mode{ .literal, .regex }) |mode| {
        try expectRefused("", mode, "pattern must be 1..1024 bytes");
        try expectRefused(&long, mode, "pattern must be 1..1024 bytes");
        try expectRefused("a\xffb", mode, "pattern is not valid UTF-8");
        try expectRefused("\xed\xa0\x80", mode, "pattern is not valid UTF-8"); // a lone surrogate
        try expectRefused("a\nb", mode, "pattern holds a line break; matching is per line");
        try expectRefused("a\u{2028}", mode, "pattern holds a line break; matching is per line");
        try expectRefused("\u{85}", mode, "pattern holds a line break; matching is per line");
        try expectRefused("\x1d", mode, "pattern holds a line break; matching is per line");
    }
    // 1,024 bytes is accepted, and a tab is not a line break.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    _ = try compileOk(arena_state.allocator(), long[0..1024], .literal, .smart, false);
    _ = try compileOk(arena_state.allocator(), "a\tb", .literal, .smart, false);
}

test "S6-T24 pattern: accepted constructs and their matches" {
    const R = Mode.regex;
    const S = Case.sensitive;
    try expectOffsets("a|b", R, S, false, "xbxa", &.{ .{ 1, 2 }, .{ 3, 4 } });
    try expectOffsets("(?:ab)+", R, S, false, "ababxab", &.{ .{ 0, 4 }, .{ 5, 7 } });
    try expectOffsets("(ab)?c", R, S, false, "abcc", &.{ .{ 0, 3 }, .{ 3, 4 } });
    try expectOffsets("a{2}", R, S, false, "aaaaa", &.{ .{ 0, 2 }, .{ 2, 4 } });
    try expectOffsets("a{2,}", R, S, false, "aaaaa", &.{.{ 0, 5 }});
    try expectOffsets("a{1,2}", R, S, false, "aaaaa", &.{ .{ 0, 2 }, .{ 2, 4 }, .{ 4, 5 } });
    try expectOffsets("a{0,2}b", R, S, false, "aaab", &.{.{ 1, 4 }});
    try expectOffsets("[]a]", R, S, false, "x]a", &.{ .{ 1, 2 }, .{ 2, 3 } });
    try expectOffsets("[^]a]+", R, S, false, "]xy]", &.{.{ 1, 3 }});
    try expectOffsets("[a-]", R, S, false, "b-a", &.{ .{ 1, 2 }, .{ 2, 3 } });
    try expectOffsets("[\\]x]", R, S, false, "]", &.{.{ 0, 1 }});
    try expectOffsets("[\\d.]+", R, S, false, "v1.25!", &.{.{ 1, 5 }});
    try expectOffsets(".", R, S, false, "é", &.{.{ 0, 1 }});
    try expectOffsets("^a", R, S, false, "aa", &.{.{ 0, 1 }});
    try expectOffsets("a$", R, S, false, "aa", &.{.{ 1, 2 }});
    try expectOffsets("\\$5", R, S, false, "cost $5", &.{.{ 5, 7 }});
    try expectOffsets("\\ \\-\\{", R, S, false, "a -{", &.{.{ 1, 4 }});
    try expectOffsets("}]", R, S, false, "a}]", &.{.{ 1, 3 }});
    try expectOffsets("\\t\\d", R, S, false, "a\t4", &.{.{ 1, 3 }});
    try expectOffsets("[\\t]", R, S, false, "a\tb", &.{.{ 1, 2 }});
    try expectOffsets("\\s+", R, S, false, "a \u{3000}b", &.{.{ 1, 3 }});
    try expectOffsets("\\S+", R, S, false, " ab ", &.{.{ 1, 3 }});
    try expectOffsets("\\D+", R, S, false, "a1", &.{.{ 0, 1 }});
    try expectOffsets("\\W+", R, S, false, "a_b", &.{.{ 1, 2 }});
    try expectOffsets("\\B", R, S, false, "ab", &.{});
    try expectOffsets("x", R, S, false, "abc", null);
}

test "S6-T24 pattern: finditer offsets, empty matches dropped (Python 3.9 spans in the comments)" {
    const R = Mode.regex;
    const S = Case.sensitive;
    // a* over baaac: (0,0) (1,4) (4,4) (5,5); the engine keeps the non-empty one.
    try expectOffsets("a*", R, S, false, "baaac", &.{.{ 1, 4 }});
    // a*|b over b: (0,0) (0,1) (1,1).
    try expectOffsets("a*|b", R, S, false, "b", &.{.{ 0, 1 }});
    // x* over an empty line: a hit with no offsets.
    try expectOffsets("x*", R, S, false, "", &.{});
    try expectOffsets("^", R, S, false, "abc", &.{});
    try expectOffsets("\\b", R, S, false, "ab cd", &.{});
    try expectOffsets("\\b", R, S, false, "  ", null);
    // Leftmost-first: the earlier alternative wins even when shorter.
    try expectOffsets("a|ab", R, S, false, "ab", &.{.{ 0, 1 }});
    try expectOffsets("ab|a", R, S, false, "ab", &.{.{ 0, 2 }});
    // Greedy repeats.
    try expectOffsets("a.*b", R, S, false, "aXbYb", &.{.{ 0, 5 }});
    try expectOffsets("(a|b)*c", R, S, false, "abac", &.{.{ 0, 4 }});
}

test "S6-T24 pattern: \\w, \\b and whole_word use the analyser's word code points (no _)" {
    const R = Mode.regex;
    const L = Mode.literal;
    const S = Case.sensitive;
    try expectOffsets("\\w+", R, S, false, "snake_case", &.{ .{ 0, 5 }, .{ 6, 10 } });
    try expectOffsets("\\bcase\\b", R, S, false, "snake_case", &.{.{ 6, 10 }});
    try expectOffsets("send", L, S, true, "send_email(x)", &.{.{ 0, 4 }});
    try expectOffsets("50", L, S, true, "142.50 and 150", &.{.{ 4, 6 }});
    try expectOffsets("50", L, S, true, "150", null);
    try expectOffsets("\\$5", R, S, true, "cost $5 each", &.{.{ 5, 7 }});
    try expectOffsets("$5", L, S, true, "cost $5 each", &.{.{ 5, 7 }});
    // Tamil: the vowel signs and the virama are marks, inside the word.
    try expectOffsets("\\w+", R, S, false, "மழை பெய்தால்", &.{ .{ 0, 3 }, .{ 4, 12 } });
    try expectOffsets("மழை", L, S, true, "மழைக்காலம் மழை", &.{.{ 11, 14 }});
    try expectOffsets("\\bமழை\\b", R, S, false, "மழைக்காலம்", null);
    // \d is Unicode Nd: Tamil digits.
    try expectOffsets("\\d+", R, S, false, "௧௨ and 34", &.{ .{ 0, 2 }, .{ 7, 9 } });
    // A whole-word candidate that fails is retried one code point further on.
    try expectOffsets("aa", L, S, true, "aaa aa", &.{.{ 4, 6 }});
    try expectOffsets("a+", R, S, true, "ab a", &.{.{ 3, 4 }});
}

test "S6-T24 pattern: case: insensitive folds, smart resolves by the fold table, classes fold" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const R = Mode.regex;
    const L = Mode.literal;
    const I = Case.insensitive;
    try expectOffsets("orchard", L, I, false, "ORCHARD Orchard", &.{ .{ 0, 7 }, .{ 8, 15 } });
    try expectOffsets("Orchard", L, .smart, false, "ORCHARD Orchard", &.{.{ 8, 15 }});
    try expectOffsets("orchard", L, .smart, false, "ORCHARD", &.{.{ 0, 7 }});
    // ſ (U+017F) folds to s and K (U+212A, KELVIN SIGN) to k.
    try expectOffsets("sk", L, I, false, "\u{17F}\u{212A} SK", &.{ .{ 0, 2 }, .{ 3, 5 } });
    try expectOffsets("[a-z]+", R, I, false, "\u{17F}\u{212A}X", &.{.{ 0, 3 }});
    try expectOffsets("[^a-z]", R, I, false, "\u{212A}1", &.{.{ 1, 2 }});
    try expectOffsets("[S]", R, I, false, "\u{17F}", &.{.{ 0, 1 }});
    try expectOffsets("Ω", L, I, false, "ω \u{2126}", &.{ .{ 0, 1 }, .{ 2, 3 } });
    // No full folding, no accents, no NFC.
    try expectOffsets("ss", L, I, false, "ß", null);
    try expectOffsets("cafe", L, I, false, "café", null);
    try expectOffsets("é", L, I, false, "e\u{301}", null);
    // smart: a code point the pattern writes that changes under the fold.
    const cases = [_]struct { []const u8, Mode, Applied }{
        .{ "pickle", L, .insensitive },  .{ "Pickle", L, .sensitive },    .{ "\u{212A}", L, .sensitive },
        .{ "\u{17F}", L, .sensitive },   .{ "ǅ", L, .sensitive },          .{ "மழை", L, .insensitive },
        .{ "\\W\\S\\D\\B", R, .insensitive }, .{ "[A-z]", R, .sensitive }, .{ "a{2}\\.", R, .insensitive },
        .{ "\\.\\d", R, .insensitive },
    };
    for (cases) |case| {
        const compiled = try compileOk(arena, case[0], case[1], .smart, false);
        try testing.expectEqual(case[2], compiled.case_applied);
    }
}

test "S6-T24 pattern: strategies: a literal skips the VM, ASCII-insensitive only without s and k" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_]struct { []const u8, Mode, Case, Strategy }{
        .{ "142.50", .literal, .smart, .bytes },
        .{ "142", .regex, .smart, .bytes },
        .{ "\\$5", .regex, .smart, .bytes },
        .{ "orchard", .literal, .insensitive, .ascii_ci },
        .{ "desk", .literal, .insensitive, .vm },
        .{ "Kelvin", .literal, .insensitive, .vm },
        .{ "மழை", .literal, .insensitive, .vm },
        .{ "மழை", .literal, .sensitive, .bytes },
        .{ "a.c", .regex, .sensitive, .vm },
    };
    for (cases) |case| {
        const compiled = try compileOk(arena, case[0], case[1], case[2], false);
        testing.expectEqual(case[3], compiled.strategy) catch |err| {
            std.debug.print("{s}\n", .{case[0]});
            return err;
        };
    }
    const empty = try compileOk(arena, "x*", .regex, .smart, false);
    try testing.expect(empty.matches_empty);
    const not_empty = try compileOk(arena, "x+|y", .regex, .smart, false);
    try testing.expect(!not_empty.matches_empty);
}

test "S6-T24 pattern: offsets only for matches starting within text, clipped at its end" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const compiled = try compileOk(arena, "ab+", .regex, .sensitive, false);
    var matcher = try Matcher.init(arena, &compiled, null);
    var offsets = std.ArrayList([2]u32).empty;
    try testing.expect((try matcher.matchLine(arena, "ab abbbb ab", 6, 6, &offsets)).hit);
    try testing.expectEqualSlices([2]u32, &.{ .{ 0, 2 }, .{ 3, 6 } }, offsets.items);
    // A match wholly past the text still makes the line a hit.
    offsets.clearRetainingCapacity();
    try testing.expect((try matcher.matchLine(arena, "xxxxxx ab", 3, 3, &offsets)).hit);
    try testing.expectEqual(@as(usize, 0), offsets.items.len);
}

test "S6-T24 pattern: invalid UTF-8 in a line reads as U+FFFD, never past the line" {
    try expectOffsets("b", .regex, .sensitive, false, "a\xffb\xe2\x82", &.{.{ 2, 3 }});
    try expectOffsets(".+", .regex, .sensitive, false, "\xe2\x82", &.{.{ 0, 2 }});
    try expectOffsets("\u{FFFD}", .literal, .sensitive, false, "a\xffb", null);
    try expectOffsets("[^a]", .regex, .insensitive, false, "\xc3", &.{.{ 0, 1 }});
}

test "S6-T24 pattern: a 1 MiB line without a newline" {
    const line = try testing.allocator.alloc(u8, 1 << 20);
    defer testing.allocator.free(line);
    @memset(line, 'a');
    line[line.len - 1] = 'b';
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const compiled = try compileOk(arena, "a+b$", .regex, .sensitive, false);
    var matcher = try Matcher.init(arena, &compiled, null);
    var offsets = std.ArrayList([2]u32).empty;
    try testing.expect((try matcher.matchLine(arena, line, 512, 512, &offsets)).hit);
    try testing.expectEqualSlices([2]u32, &.{.{ 0, 512 }}, offsets.items);
}

const CountingClock = struct {
    now_ns: u64 = 0,
    step: u64,

    fn now(context: ?*anyopaque) u64 {
        const self: *CountingClock = @ptrCast(@alignCast(context.?));
        self.now_ns += self.step;
        return self.now_ns;
    }
};

test "S6-T24 pattern: the VM charges its work and reads the clock once per 65,536 units, then stops the line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const compiled = try compileOk(arena, "(a+)+b", .regex, .sensitive, false);
    var clock = CountingClock{ .step = std.time.ns_per_ms };
    var budget = Budget.start(.{ .context = &clock, .now = CountingClock.now }, 3);
    var matcher = try Matcher.init(arena, &compiled, &budget);
    const line = try arena.alloc(u8, 256 * 1024);
    @memset(line, 'a');
    var offsets = std.ArrayList([2]u32).empty;
    try testing.expectError(error.OutOfTime, matcher.matchLine(arena, line, 512, 512, &offsets));
    try testing.expect(budget.spent);
    // Each read advanced the clock 1 ms: the start, then one read per 65,536 units until 3 ms had passed.
    try testing.expectEqual(@as(u64, 4 * std.time.ns_per_ms), clock.now_ns);
}

fn timeLine(arena: std.mem.Allocator, matcher: *Matcher, line: []const u8) !u64 {
    var best: u64 = std.math.maxInt(u64);
    for (0..3) |_| {
        var offsets = std.ArrayList([2]u32).empty;
        const start = std.Io.Clock.awake.now(testing.io).nanoseconds;
        _ = try matcher.matchLine(arena, line, 512, 512, &offsets);
        best = @min(best, @as(u64, @intCast(std.Io.Clock.awake.now(testing.io).nanoseconds - start)));
    }
    return best;
}

test "S6-T24 pattern: linear time: (a+)+b over 2^16 and 2^20 a's, a ratio at most 32 for 16 times the length" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const compiled = try compileOk(arena, "(a+)+b", .regex, .sensitive, false);
    var matcher = try Matcher.init(arena, &compiled, null);
    const long = try arena.alloc(u8, 1 << 20);
    @memset(long, 'a');
    const short_ns = try timeLine(arena, &matcher, long[0 .. 1 << 16]);
    const long_ns = try timeLine(arena, &matcher, long);
    const ratio = @as(f64, @floatFromInt(long_ns)) / @as(f64, @floatFromInt(@max(short_ns, 1)));
    std.debug.print("S6-T24 linear: (a+)+b over 2^16 a's {d} ns, 2^20 a's {d} ns, ratio {d:.2} (bar 32)\n", .{ short_ns, long_ns, ratio });
    try testing.expect(ratio <= 32.0);
}

test "S6-T24 pattern: the fold keeps \\w, \\d and \\s and is idempotent over the whole table" {
    for (tables.casefold_pairs) |pair| {
        try testing.expectEqual(isWord(pair.from), isWord(pair.to));
        try testing.expectEqual(isDigit(pair.from), isDigit(pair.to));
        try testing.expectEqual(isSpace(pair.from), isSpace(pair.to));
        try testing.expectEqual(pair.to, fold(pair.to));
        try testing.expectEqual(pair.to, fold(pair.from));
    }
}

// ------------------------------------------------------------- rework 1 tests ---

fn programOf(arena: std.mem.Allocator, pattern: []const u8) !Compiled {
    return compileOk(arena, pattern, .regex, .sensitive, false);
}

test "S6-T24 rework 1, ruling 1: a repeat of a body that only matches the empty string is kept once" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The verifier's 44-byte pattern, one level deeper (53 bytes), and two that were refused as too large.
    const nested = [_][]const u8{
        "(?:(?:(?:(?:(?:)(?:)){255}){255}){255}){255}",
        "(?:(?:(?:(?:(?:(?:)(?:)){255}){255}){255}){255}){255}",
        "(?:(?:(?:^$){255}){255}){255}",
        "(?:(?:(?:\\b\\B){255}){255}){255}",
    };
    for (nested) |pattern| {
        const compiled = try programOf(arena, pattern);
        try testing.expect(compiled.program.len <= 8);
        try testing.expect(compiled.matches_empty);
    }
    // The same spans as the unsimplified repeats.
    const R = Mode.regex;
    const S = Case.sensitive;
    try expectOffsets("(?:^$){3}", R, S, false, "", &.{});
    try expectOffsets("(?:^$){3}", R, S, false, "a", null);
    try expectOffsets("(?:\\b\\b)*x", R, S, false, "a x", &.{.{ 2, 3 }});
    try expectOffsets("(?:\\b\\b){2,5}x", R, S, false, "ax x", &.{.{ 3, 4 }});
    try expectOffsets("(?:\\B\\B){0}x", R, S, false, "ax", &.{.{ 1, 2 }});
    try expectOffsets("(?:(?:)|^)+a", R, S, false, "aa", &.{ .{ 0, 1 }, .{ 1, 2 } });
}

test "S6-T24 rework 1, ruling 1: the compile counts every expansion, emitting or not" {
    const too_large = "pattern not supported at byte 0: the pattern is too large (over 8,192 steps)";
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // 1 + 31 x 256 = 7,937 expansions and 7,906 instructions: accepted.
    _ = try programOf(arena, "(?:a{255}){31}");
    // 1 + 32 x 256 = 8,193 expansions (8,161 instructions would fit): refused.
    try expectRefused("(?:a{255}){32}", .regex, too_large);
    // An empty group in a body that also consumes is expanded each time: 24,513 expansions, 8,161 instructions.
    try expectRefused("(?:(?:(?:)a){255}){32}", .regex, too_large);
    // A literal of 1,024 code points: 1,025 expansions.
    var long: [1024]u8 = undefined;
    @memset(&long, 'x');
    _ = try compileOk(arena, &long, .literal, .insensitive, true);
}

/// The most work (counted, `work`) a compile of a pattern of up to 1,024 bytes may take: the bound the fuzz
/// below holds every pattern to (rework 2, ruling 3: a count, not a clock).
const max_compile_work: u64 = 500_000;

test "S6-T24 rework 2, rulings 2 and 3: compiling any pattern of up to 1,024 bytes is bounded work (counted, fuzz)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const patterns = try fuzz.patterns(arena_state.allocator(), 4000);
    var worst: u64 = 0;
    var worst_pattern: []const u8 = "";
    var compiled_count: usize = 0;
    var refused_count: usize = 0;
    var longest: usize = 0;
    for (patterns) |pattern| {
        longest = @max(longest, pattern.len);
        for ([_]Case{ .sensitive, .insensitive }) |case| {
            var one = std.heap.ArenaAllocator.init(testing.allocator);
            defer one.deinit();
            const before = work_done;
            const outcome = try compile(one.allocator(), pattern, .regex, case, true);
            const took = work_done - before;
            switch (outcome) {
                .ok => compiled_count += 1,
                .refused => refused_count += 1,
            }
            if (took > worst) {
                worst = took;
                worst_pattern = pattern;
            }
        }
    }
    std.debug.print("S6-T24 compile fuzz: {d} patterns (longest {d} bytes), {d} compiled, {d} refused; most work {d} ({d} bytes: {s})\n", .{ patterns.len, longest, compiled_count, refused_count, worst, worst_pattern.len, worst_pattern[0..@min(worst_pattern.len, 80)] });
    try testing.expect(compiled_count > 2000);
    try testing.expectEqual(max_pattern_bytes, longest);
    try testing.expect(worst <= max_compile_work);
}

fn lineMatch(arena: std.mem.Allocator, pattern: []const u8, mode: Mode, line: []const u8, offsets: *std.ArrayList([2]u32)) !Matcher.LineMatch {
    const compiled = try arena.create(Compiled);
    compiled.* = try compileOk(arena, pattern, mode, .sensitive, false);
    var matcher = try Matcher.init(arena, compiled, null);
    offsets.clearRetainingCapacity();
    const cut = textCutForTest(line);
    return matcher.matchLine(arena, line, cut, codepointCount(line[0..cut]), offsets);
}

fn textCutForTest(line: []const u8) usize {
    return @min(line.len, 512);
}

test "S6-T24 rework 1, ruling 2 and rework 2, ruling 4: regex mode lists at most 16 non-empty matches per line and cuts the text at the 17th" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var offsets = std.ArrayList([2]u32).empty;
    const as = "a" ** 100;
    // The verifier's pattern: every match is one `a`, but each search runs `.*b` to the line's end.
    var got = try lineMatch(arena, "a(.*b)?", .regex, as, &offsets);
    try testing.expect(got.hit);
    try testing.expectEqual(@as(usize, 16), got.text_len);
    try testing.expectEqual(@as(usize, 16), offsets.items.len);
    try testing.expectEqualSlices(u32, &.{ 15, 16 }, &offsets.items[15]);
    try testing.expect(got.matches_truncated);
    // Twenty words: sixteen listed, the text ends where the seventeenth starts.
    const words = "w0 w1 w2 w3 w4 w5 w6 w7 w8 w9 wa wb wc wd we wf wg wh wi wj";
    got = try lineMatch(arena, "\\w+", .regex, words, &offsets);
    try testing.expectEqual(@as(usize, 48), got.text_len);
    try testing.expectEqual(@as(usize, 16), offsets.items.len);
    try testing.expect(got.matches_truncated);
    // Exactly sixteen: nothing is cut.
    got = try lineMatch(arena, "\\w+", .regex, words[0..47], &offsets);
    try testing.expectEqual(@as(usize, 47), got.text_len);
    try testing.expectEqual(@as(usize, 16), offsets.items.len);
    try testing.expect(!got.matches_truncated);
    // Empty matches are not listed and do not count (rework 2, ruling 4): x* over 25 b's is a hit with no
    // offsets and its whole text; \b over twenty words lists nothing and cuts nothing.
    got = try lineMatch(arena, "x*", .regex, "b" ** 25, &offsets);
    try testing.expect(got.hit);
    try testing.expectEqual(@as(usize, 25), got.text_len);
    try testing.expectEqual(@as(usize, 0), offsets.items.len);
    try testing.expect(!got.matches_truncated);
    got = try lineMatch(arena, "\\b", .regex, words, &offsets);
    try testing.expectEqual(words.len, got.text_len);
    try testing.expectEqual(@as(usize, 0), offsets.items.len);
    // Empty matches between non-empty ones: x*a? over 20 a's lists 16 one-code-point matches, cut at the 17th.
    got = try lineMatch(arena, "x*a?", .regex, "a" ** 20, &offsets);
    try testing.expectEqual(@as(usize, 16), got.text_len);
    try testing.expectEqual(@as(usize, 16), offsets.items.len);
    try testing.expect(got.matches_truncated);
    // Sixteen non-empty matches and empty ones after them: nothing cut.
    got = try lineMatch(arena, "a*", .regex, "ab" ** 16, &offsets);
    try testing.expectEqual(@as(usize, 32), got.text_len);
    try testing.expectEqual(@as(usize, 16), offsets.items.len);
    try testing.expect(!got.matches_truncated);
    // A code point boundary: the cut is a byte offset after whole code points.
    got = try lineMatch(arena, ".", .regex, "é" ** 20, &offsets);
    try testing.expectEqual(@as(usize, 32), got.text_len);
    // Literal mode lists every match (its search is one pass whatever the count); regex mode caps a literal too.
    got = try lineMatch(arena, "a", .literal, as, &offsets);
    try testing.expectEqual(@as(usize, 100), got.text_len);
    try testing.expectEqual(@as(usize, 100), offsets.items.len);
    try testing.expect(!got.matches_truncated);
    got = try lineMatch(arena, "a", .regex, as, &offsets);
    try testing.expectEqual(@as(usize, 16), got.text_len);
    try testing.expect(got.matches_truncated);
}

fn timeMatch(arena: std.mem.Allocator, matcher: *Matcher, line: []const u8) !u64 {
    var best: u64 = std.math.maxInt(u64);
    for (0..3) |_| {
        var offsets = std.ArrayList([2]u32).empty;
        const start = std.Io.Clock.awake.now(testing.io).nanoseconds;
        _ = try matcher.matchLine(arena, line, 512, 512, &offsets);
        best = @min(best, @as(u64, @intCast(std.Io.Clock.awake.now(testing.io).nanoseconds - start)));
    }
    return best;
}

test "S6-T24 rework 1, ruling 2: listing a(.*b)?'s matches is linear: 2^16 and 2^18 a's, a ratio at most 8 for 4 times the length" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const compiled = try compileOk(arena, "a(.*b)?", .regex, .sensitive, false);
    var matcher = try Matcher.init(arena, &compiled, null);
    const long = try arena.alloc(u8, 1 << 18);
    @memset(long, 'a');
    const short_ns = try timeMatch(arena, &matcher, long[0 .. 1 << 16]);
    const long_ns = try timeMatch(arena, &matcher, long);
    const ratio = @as(f64, @floatFromInt(long_ns)) / @as(f64, @floatFromInt(@max(short_ns, 1)));
    std.debug.print("S6-T24 listing: a(.*b)? over 2^16 a's {d} ns, 2^18 a's {d} ns, ratio {d:.2} (bar 8)\n", .{ short_ns, long_ns, ratio });
    try testing.expect(ratio <= 8.0);
}

test "S6-T24 rework 1, ruling 3: the literal search is linear (1,023 a's and b over a's), both strategies" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const needle = "a" ** 1023 ++ "b";
    const long = try arena.alloc(u8, 1 << 20);
    @memset(long, 'a');
    for ([_]Case{ .sensitive, .insensitive }) |case| {
        const compiled = try arena.create(Compiled);
        compiled.* = try compileOk(arena, needle, .literal, case, false);
        try testing.expectEqual(if (case == .sensitive) Strategy.bytes else Strategy.ascii_ci, compiled.strategy);
        var matcher = try Matcher.init(arena, compiled, null);
        const short_ns = try timeMatch(arena, &matcher, long[0 .. 1 << 18]);
        const long_ns = try timeMatch(arena, &matcher, long);
        const ratio = @as(f64, @floatFromInt(long_ns)) / @as(f64, @floatFromInt(@max(short_ns, 1)));
        std.debug.print("S6-T24 literal {s}: 1,023 a's and b over 2^18 a's {d} ns, 2^20 a's {d} ns, ratio {d:.2} (bar 8)\n", .{ @tagName(compiled.strategy), short_ns, long_ns, ratio });
        try testing.expect(ratio <= 8.0);
    }
    // Overlapping candidates for a whole word, and a needle with a repeated prefix: the same answers as before.
    try expectOffsets("aa", .literal, .sensitive, true, "aaa aa", &.{.{ 4, 6 }});
    try expectOffsets("abab", .literal, .sensitive, false, "abababab ab", &.{ .{ 0, 4 }, .{ 4, 8 } });
    try expectOffsets("aab", .literal, .insensitive, false, "AAAAB aab", &.{ .{ 2, 5 }, .{ 6, 9 } });
    try expectOffsets("Ab", .literal, .insensitive, false, "xaB", &.{.{ 1, 3 }});
}

test "S6-T24 rework 1, ruling 3: the literal search charges the budget inside a line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const compiled = try compileOk(arena, "a" ** 1023 ++ "b", .literal, .insensitive, false);
    var clock = CountingClock{ .step = std.time.ns_per_ms };
    var budget = Budget.start(.{ .context = &clock, .now = CountingClock.now }, 3);
    var matcher = try Matcher.init(arena, &compiled, &budget);
    const line = try arena.alloc(u8, 1 << 20);
    @memset(line, 'a');
    var offsets = std.ArrayList([2]u32).empty;
    try testing.expectError(error.OutOfTime, matcher.matchLine(arena, line, 512, 512, &offsets));
    // The start, then one read per 65,536 bytes until 3 ms had passed.
    try testing.expectEqual(@as(u64, 4 * std.time.ns_per_ms), clock.now_ns);
}

/// A clock that, at each read, takes the work counted (`work`) and the units charged since the read before: one
/// interval of the meter, counted (rework 2, ruling 3). It advances 1 ns a read, so a budget never runs out.
const WorkClock = struct {
    t: u64 = 0,
    reads: u64 = 0,
    last_work: u64 = 0,
    last_units: u64 = 0,
    widest_work: u64 = 0,
    widest_units: u64 = 0,
    /// The most work per unit charged in one interval (intervals of at least `check_units` units).
    worst_per_unit: f64 = 0,

    fn now(context: ?*anyopaque) u64 {
        const self: *WorkClock = @ptrCast(@alignCast(context.?));
        const w = work_done - self.last_work;
        const u = units_charged - self.last_units;
        if (self.reads > 0) {
            self.widest_work = @max(self.widest_work, w);
            self.widest_units = @max(self.widest_units, u);
            if (u >= check_units) self.worst_per_unit = @max(self.worst_per_unit, @as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(u)));
        }
        self.last_work = work_done;
        self.last_units = units_charged;
        self.reads += 1;
        self.t += 1;
        return self.t;
    }
};

/// The stated bounds of the meter (rework 2, ruling 2): at most this much work (`work`) per unit charged, and at
/// most `check_units` plus one position's units (a program of 8,192 instructions: each followed at most three
/// times and stepped once at a class's cost of at most 6, and the position's 4) between two reads of the clock.
const max_work_per_unit: f64 = 12;
const max_units_between_reads: u64 = check_units + 9 * max_program + 4;


test "S6-T24 rework 2, rulings 2 and 3: one interval of the meter is bounded work, counted, on the heaviest units" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = try fuzz.meterCases(arena);
    var worst_per_unit: f64 = 0;
    var widest_units: u64 = 0;
    for (cases) |case| {
        const compiled = try compileOk(arena, case.pattern, case.mode, case.case, false);
        var clock = WorkClock{};
        var budget = Budget.start(.{ .context = &clock, .now = WorkClock.now }, 30_000);
        var matcher = try Matcher.init(arena, &compiled, &budget);
        var offsets = std.ArrayList([2]u32).empty;
        _ = try matcher.matchLine(arena, case.line, 512, 512, &offsets);
        std.debug.print("S6-T24 meter: {s} ({d} bytes) over {d} bytes: {d} reads, widest {d} units and {d} work, at most {d:.2} work a unit\n", .{ case.pattern[0..@min(case.pattern.len, 40)], case.pattern.len, case.line.len, clock.reads, clock.widest_units, clock.widest_work, clock.worst_per_unit });
        try testing.expect(clock.reads >= 3);
        worst_per_unit = @max(worst_per_unit, clock.worst_per_unit);
        widest_units = @max(widest_units, clock.widest_units);
        try testing.expect(clock.widest_work <= @as(u64, @intFromFloat(max_work_per_unit * @as(f64, @floatFromInt(max_units_between_reads)))));
    }
    try testing.expect(worst_per_unit <= max_work_per_unit);
    try testing.expect(widest_units <= max_units_between_reads);
}

test "S6-T24 rework 2, rulings 2 and 3: every pattern of the fuzz does bounded work per unit charged (counted)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const patterns = try fuzz.patterns(arena, 1200);
    const line = try fuzz.repeatCodepoints(arena, "Ωж→ 1ſKaé-x\tß", 600);
    var worst: f64 = 0;
    var worst_pattern: []const u8 = "";
    var matched: usize = 0;
    for (patterns) |pattern| {
        for ([_]Case{ .sensitive, .insensitive }) |case| {
            var one = std.heap.ArenaAllocator.init(testing.allocator);
            defer one.deinit();
            const compiled = try one.allocator().create(Compiled);
            compiled.* = switch (try compile(one.allocator(), pattern, .regex, case, false)) {
                .ok => |c| c,
                .refused => continue,
            };
            var clock = WorkClock{};
            var budget = Budget.start(.{ .context = &clock, .now = WorkClock.now }, 30_000);
            var matcher = try Matcher.init(one.allocator(), compiled, &budget);
            var offsets = std.ArrayList([2]u32).empty;
            const work_before = work_done;
            const units_before = units_charged;
            _ = try matcher.matchLine(one.allocator(), line, @min(line.len, 512), codepointCount(line[0..@min(line.len, 512)]), &offsets);
            try matcher.tick();
            const w = work_done - work_before;
            const u = units_charged - units_before;
            matched += 1;
            const per_unit = @as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(@max(u, 1)));
            if (per_unit > worst) {
                worst = per_unit;
                worst_pattern = pattern;
            }
            try testing.expect(clock.widest_units <= max_units_between_reads);
        }
    }
    std.debug.print("S6-T24 meter fuzz: {d} patterns matched, at most {d:.2} work a unit ({d} bytes: {s})\n", .{ matched, worst, worst_pattern.len, worst_pattern[0..@min(worst_pattern.len, 80)] });
    try testing.expect(matched > 800);
    try testing.expect(worst <= max_work_per_unit);
}

/// A class's items tested one by one, as before rework 2: the reference `Members` is checked against.
fn memberReference(items: []const Item, cp: u21) bool {
    for (items) |item| {
        const in = switch (item) {
            .range => |r| cp >= r[0] and cp <= r[1],
            .word => |positive| isWord(cp) == positive,
            .digit => |positive| isDigit(cp) == positive,
            .space => |positive| chunker.isWhitespace(cp) == positive,
        };
        if (in) return true;
    }
    return false;
}

test "S6-T24 rework 2, ruling 2: a normalised class has exactly the members and folds its items give" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // `\s` in one switch is the analyser's whitespace, at every code point up to past its last member.
    for (0..0x3100) |c| try testing.expectEqual(chunker.isWhitespace(@intCast(c)), isSpace(@intCast(c)));
    var prng = std.Random.DefaultPrng.init(20261124);
    const random = prng.random();
    const probes = [_]u21{ 0, '\t', ' ', '0', '9', 'A', 'K', 'Z', '_', 'a', 'k', 's', 'z', 0x7f, 0x85, 0xa0, 0xb5, 0xdf, 0xe9, 0x17f, 0x391, 0x3a9, 0x3c9, 0x410, 0x44f, 0x660, 0xb95, 0xbcd, 0x1680, 0x200c, 0x2028, 0x2126, 0x212a, 0x2192, 0x3000, 0xfffd, 0x10ffff };
    for (0..500) |_| {
        var items = std.ArrayList(Item).empty;
        for (0..random.uintLessThan(usize, 8) + 1) |_| {
            const item: Item = switch (random.uintLessThan(u8, 5)) {
                0 => .{ .word = random.boolean() },
                1 => .{ .digit = random.boolean() },
                2 => .{ .space = random.boolean() },
                else => blk: {
                    const low = probes[random.uintLessThan(usize, probes.len)] +| random.uintLessThan(u21, 3);
                    break :blk .{ .range = .{ @min(low, 0x10ffff), @min(low +| random.uintLessThan(u21, 40), 0x10ffff) } };
                },
            };
            try items.append(arena, item);
        }
        const members = try Members.of(arena, items.items);
        for (probes) |base| for ([_]u21{ base, base +| 1, base -| 1 }) |cp| {
            try testing.expectEqual(memberReference(items.items, cp), members.contains(cp));
        };
        for (members.ranges) |r| for ([_]u21{ r[0], r[1], r[0] -| 1, r[1] +| 1 }) |cp| {
            try testing.expectEqual(memberReference(items.items, cp), members.contains(cp));
        };
        // The folds the class adds: those of the whole table, as before rework 2.
        var expected = std.ArrayList(u21).empty;
        for (tables.casefold_pairs) |pair| {
            if (memberReference(items.items, pair.from) and !memberReference(items.items, pair.to)) try expected.append(arena, pair.to);
        }
        std.mem.sort(u21, expected.items, {}, std.sort.asc(u21));
        var unique = std.ArrayList(u21).empty;
        for (expected.items) |cp| if (unique.items.len == 0 or unique.items[unique.items.len - 1] != cp) try unique.append(arena, cp);
        try testing.expectEqualSlices(u21, unique.items, try foldExtras(arena, &members));
    }
}
