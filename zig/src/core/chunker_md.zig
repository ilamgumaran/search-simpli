//! `md-section-v1` (S3-T1 ruling 2, CAP-19 FR-18): the Markdown chunker,
//! ported from `search_platform.core._md_section_chunks` and pinned against
//! it by `fixtures/chunk-golden-md.json` (`chunker_md_test.zig`).
//!
//! Rules, on the file's lines (`str.splitlines` boundaries, the same lines
//! `line-window-v1` numbers; a leading UTF-8 BOM is not part of line 1):
//! - Front matter: line 1 is exactly `---` and a later line within the first
//!   100 is exactly `---`. Inner lines are `key: value` string pairs (blank
//!   lines skipped); any other inner line makes the block plain metadata text
//!   (no fields). Front matter is never part of a chunk.
//! - ATX heading: one to six `#` then a space or tab; the text is the rest with
//!   surrounding spaces/tabs and a closing `#` run removed.
//! - Setext heading: a non-blank line not starting with `-`, `*`, `+`, `#` or
//!   a backtick, directly above a line of only `=` (level 1) or only `-`
//!   (level 2), optionally followed by spaces/tabs. The heading line is the text line.
//! - A fence opens on a line starting with three or more backticks or tildes
//!   and closes on a line starting with at least as many of the same character
//!   followed only by whitespace; an unclosed fence runs to the end of the
//!   file. Nothing inside a fence is a heading.
//! - Each heading opens a section that runs to the line before the next
//!   heading of any level; the lines before the first heading (after front
//!   matter) form a section with an empty path. A chunk never crosses a
//!   section. Inside a section the windows are `line-window-v1`'s with the
//!   same parameters, except that a fenced block that fits `max_chars` is one
//!   unit: a window never ends or restarts inside it. A longer fence is
//!   windowed line by line.
const std = @import("std");
const chunker = @import("chunker.zig");

pub const chunker_id = "md-section-v1";
pub const front_matter_id = "yaml-v1";
pub const front_matter_max_lines: usize = 100;
pub const section_separator: u8 = 0x1f;

const Error = chunker.Error;
const Line = chunker.Line;

pub const Field = struct { key: []const u8, value: []const u8 };

pub const FrontMatter = struct {
    /// 0-based index of the opening and the closing `---` line.
    start: usize,
    end: usize,
    valid: bool,
    /// Empty when `valid` is false.
    fields: []Field,
    /// The inner lines joined by LF (kept when the block is not key: value).
    raw: []const u8,
};

pub const Heading = struct {
    level: u8,
    text: []const u8,
    /// 0-based line index.
    line: usize,
};

pub const Fence = struct { start: usize, end: usize };

pub const Structure = struct {
    lines: []Line,
    front_matter: ?FrontMatter,
    body_start: usize,
    headings: []Heading,
    fences: []Fence,
};

/// Strip a leading UTF-8 byte order mark.
pub fn withoutBom(text: []const u8) []const u8 {
    if (std.mem.startsWith(u8, text, "\xef\xbb\xbf")) return text[3..];
    return text;
}

fn isBlank(bytes: []const u8) Error!bool {
    return (try chunker.stripWhitespace(bytes)).len == 0;
}

fn atxHeading(line: []const u8) ?struct { level: u8, text: []const u8 } {
    var level: usize = 0;
    while (level < line.len and line[level] == '#') level += 1;
    if (level < 1 or level > 6 or level >= line.len) return null;
    if (line[level] != ' ' and line[level] != '\t') return null;
    var rest = std.mem.trimStart(u8, line[level..], " \t");
    rest = std.mem.trimEnd(u8, rest, " \t");
    rest = std.mem.trimEnd(u8, rest, "#");
    rest = std.mem.trimEnd(u8, rest, " \t");
    return .{ .level = @intCast(level), .text = rest };
}

fn fenceMarker(line: []const u8) ?struct { char: u8, run: usize } {
    if (line.len == 0 or (line[0] != '`' and line[0] != '~')) return null;
    const char = line[0];
    var run: usize = 0;
    while (run < line.len and line[run] == char) run += 1;
    if (run < 3) return null;
    return .{ .char = char, .run = run };
}

fn isSetextUnderline(line: []const u8) bool {
    if (line.len == 0 or (line[0] != '=' and line[0] != '-')) return false;
    const char = line[0];
    var index: usize = 0;
    while (index < line.len and line[index] == char) index += 1;
    while (index < line.len and (line[index] == ' ' or line[index] == '\t')) index += 1;
    return index == line.len;
}

fn setextTextAllowed(line: []const u8) bool {
    if (line.len == 0) return true;
    return switch (line[0]) {
        '-', '*', '+', '#', '`' => false,
        else => true,
    };
}

/// Lines, front matter, headings and fences of one Markdown file. `text` may
/// carry a BOM. Allocations from `allocator` (an arena is expected).
pub fn structure(allocator: std.mem.Allocator, text: []const u8) Error!Structure {
    const lines = try chunker.splitLines(allocator, withoutBom(text));

    var front_matter: ?FrontMatter = null;
    var first: usize = 0;
    if (lines.len > 0 and std.mem.eql(u8, lines[0].bytes, "---")) {
        const limit = @min(lines.len, front_matter_max_lines);
        var index: usize = 1;
        while (index < limit) : (index += 1) {
            if (!std.mem.eql(u8, lines[index].bytes, "---")) continue;
            var fields = std.ArrayList(Field).empty;
            var valid = true;
            for (lines[1..index]) |item| {
                if (try isBlank(item.bytes)) continue;
                const colon = std.mem.indexOfScalar(u8, item.bytes, ':') orelse {
                    valid = false;
                    break;
                };
                const key = try chunker.stripWhitespace(item.bytes[0..colon]);
                if (key.len == 0) {
                    valid = false;
                    break;
                }
                const value = try chunker.stripWhitespace(item.bytes[colon + 1 ..]);
                var replaced = false;
                for (fields.items) |*existing| {
                    if (std.mem.eql(u8, existing.key, key)) {
                        existing.value = value;
                        replaced = true;
                    }
                }
                if (!replaced) try fields.append(allocator, .{ .key = key, .value = value });
            }
            if (!valid) fields.clearRetainingCapacity();
            front_matter = .{
                .start = 0,
                .end = index,
                .valid = valid,
                .fields = try fields.toOwnedSlice(allocator),
                .raw = try chunker.joinLines(allocator, lines[1..index]),
            };
            first = index + 1;
            break;
        }
    }

    var headings = std.ArrayList(Heading).empty;
    var fences = std.ArrayList(Fence).empty;
    var open_fence: ?struct { char: u8, run: usize, start: usize } = null;
    var index = first;
    while (index < lines.len) {
        const line = lines[index].bytes;
        if (open_fence) |fence| {
            if (fenceMarker(line)) |marker| {
                if (marker.char == fence.char and marker.run >= fence.run and try isBlank(line[marker.run..])) {
                    try fences.append(allocator, .{ .start = fence.start, .end = index + 1 });
                    open_fence = null;
                }
            }
            index += 1;
            continue;
        }
        if (fenceMarker(line)) |marker| {
            open_fence = .{ .char = marker.char, .run = marker.run, .start = index };
            index += 1;
            continue;
        }
        if (atxHeading(line)) |heading| {
            try headings.append(allocator, .{ .level = heading.level, .text = heading.text, .line = index });
        } else if (!(try isBlank(line)) and index + 1 < lines.len and
            isSetextUnderline(lines[index + 1].bytes) and setextTextAllowed(line))
        {
            const level: u8 = if (lines[index + 1].bytes[0] == '=') 1 else 2;
            try headings.append(allocator, .{ .level = level, .text = try chunker.stripWhitespace(line), .line = index });
            index += 1;
        }
        index += 1;
    }
    if (open_fence) |fence| try fences.append(allocator, .{ .start = fence.start, .end = lines.len });

    return .{
        .lines = lines,
        .front_matter = front_matter,
        .body_start = first,
        .headings = try headings.toOwnedSlice(allocator),
        .fences = try fences.toOwnedSlice(allocator),
    };
}

fn unitSize(lines: []const Line, start: usize, end: usize) usize {
    var size: usize = 0;
    for (lines[start..end]) |line| size += line.codepoint_length + 1;
    return size;
}

fn fittingEnd(fitting: []const Fence, line: usize) ?usize {
    for (fitting) |fence| {
        if (fence.start == line) return fence.end;
    }
    return null;
}

/// Chunk one Markdown file per `md-section-v1`. Every returned slice is
/// allocator-owned; use an arena.
pub fn chunk(
    allocator: std.mem.Allocator,
    text: []const u8,
    max_chars: usize,
    overlap_lines: usize,
) Error![]chunker.FileSpan {
    const parsed = try structure(allocator, text);
    const lines = parsed.lines;

    var fitting = std.ArrayList(Fence).empty;
    defer fitting.deinit(allocator);
    for (parsed.fences) |fence| {
        if (unitSize(lines, fence.start, fence.end) <= max_chars) try fitting.append(allocator, fence);
    }

    const Boundary = struct { start: usize, path: []const u8, depth: u16, heading_line: u32 };
    var boundaries = std.ArrayList(Boundary).empty;
    defer boundaries.deinit(allocator);
    if (parsed.headings.len == 0 or parsed.headings[0].line > parsed.body_start) {
        try boundaries.append(allocator, .{ .start = parsed.body_start, .path = "", .depth = 0, .heading_line = 0 });
    }
    var stack = std.ArrayList(Heading).empty;
    defer stack.deinit(allocator);
    for (parsed.headings) |heading| {
        while (stack.items.len > 0 and stack.items[stack.items.len - 1].level >= heading.level) _ = stack.pop();
        try stack.append(allocator, heading);
        var path = std.ArrayList(u8).empty;
        for (stack.items, 0..) |entry, position| {
            if (position > 0) try path.append(allocator, section_separator);
            try path.appendSlice(allocator, entry.text);
        }
        try boundaries.append(allocator, .{
            .start = heading.line,
            .path = try path.toOwnedSlice(allocator),
            .depth = @intCast(stack.items.len),
            .heading_line = @intCast(heading.line + 1),
        });
    }

    var spans = std.ArrayList(chunker.FileSpan).empty;
    for (boundaries.items, 0..) |boundary, number| {
        const stop = if (number + 1 < boundaries.items.len) boundaries.items[number + 1].start else lines.len;
        var start = boundary.start;
        while (start < stop) {
            var size: usize = 0;
            var end = start;
            while (end < stop) {
                if (fittingEnd(fitting.items, end)) |fence_end| {
                    const unit = unitSize(lines, end, fence_end);
                    if (end > start and size + unit > max_chars) break;
                    size += unit;
                    end = fence_end;
                    continue;
                }
                const candidate = lines[end].codepoint_length + 1;
                if (end > start and size + candidate > max_chars) break;
                size += candidate;
                end += 1;
            }
            const joined = try chunker.joinLines(allocator, lines[start..end]);
            const stripped = try chunker.stripWhitespace(joined);
            if (stripped.len > 0) {
                try spans.append(allocator, .{
                    .start_line = @intCast(start + 1),
                    .end_line = @intCast(end),
                    .text = stripped,
                    .section_path = boundary.path,
                    .section_depth = boundary.depth,
                    .heading_line = boundary.heading_line,
                });
            }
            if (end >= stop) break;
            const rewound = if (end > overlap_lines) end - overlap_lines else 0;
            var following = if (rewound > start + 1) rewound else start + 1;
            for (fitting.items) |fence| {
                if (fence.start < following and following < fence.end) {
                    following = if (fence.start > start) fence.start else fence.end;
                    break;
                }
            }
            start = following;
        }
    }
    return spans.toOwnedSlice(allocator);
}

pub const OutlineHeading = struct {
    level: u8,
    text: []const u8,
    line: u32,
    end_line: u32,
};

pub const Outline = struct {
    front_matter: ?FrontMatter,
    headings: []OutlineHeading,
    lines: u32,
};

/// `outline` of one Markdown file (S3-T1 ruling 5): 1-based heading lines;
/// a heading's `end_line` is the line before the next heading of the same or
/// a higher level, else the last line.
pub fn outline(allocator: std.mem.Allocator, text: []const u8) Error!Outline {
    const parsed = try structure(allocator, text);
    const total: u32 = @intCast(parsed.lines.len);
    const headings = try allocator.alloc(OutlineHeading, parsed.headings.len);
    for (parsed.headings, 0..) |heading, number| {
        var end = total;
        for (parsed.headings[number + 1 ..]) |later| {
            if (later.level <= heading.level) {
                end = @intCast(later.line);
                break;
            }
        }
        headings[number] = .{ .level = heading.level, .text = heading.text, .line = @intCast(heading.line + 1), .end_line = end };
    }
    return .{ .front_matter = parsed.front_matter, .headings = headings, .lines = total };
}

test "md-section-v1 keeps a chunk inside its section and records the path" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = "---\ntitle: T\n---\nintro\n# One\nalpha\n## Two\nbeta\n```\n# not\n```\n";
    const spans = try chunk(arena, text, chunker.default_max_chars, chunker.default_overlap_lines);
    try std.testing.expectEqual(@as(usize, 3), spans.len);
    try std.testing.expectEqual(@as(u32, 4), spans[0].start_line);
    try std.testing.expectEqualStrings("intro", spans[0].text);
    try std.testing.expectEqual(@as(u16, 0), spans[0].section_depth);
    try std.testing.expectEqualStrings("One", spans[1].section_path);
    try std.testing.expectEqual(@as(u32, 5), spans[1].heading_line);
    try std.testing.expectEqualStrings("One\x1fTwo", spans[2].section_path);
    try std.testing.expectEqual(@as(u16, 2), spans[2].section_depth);
    try std.testing.expectEqual(@as(u32, 11), spans[2].end_line);

    const parsed = try outline(arena, text);
    try std.testing.expectEqual(@as(usize, 2), parsed.headings.len);
    try std.testing.expectEqual(@as(u32, 11), parsed.headings[0].end_line);
    try std.testing.expectEqualStrings("T", parsed.front_matter.?.fields[0].value);
}

test "md-section-v1 on an empty file yields nothing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const spans = try chunk(arena_state.allocator(), "", chunker.default_max_chars, chunker.default_overlap_lines);
    try std.testing.expectEqual(@as(usize, 0), spans.len);
}
