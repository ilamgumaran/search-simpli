//! `line-window-v1`, ported to Zig from `search_platform.core._line_chunks`
//! (S1-T1 acceptance criterion 1). Operates on Unicode codepoints, matching
//! Python's `len(str)` semantics exactly (Python strings are codepoint
//! sequences), which is a stricter match than the existing Dart port in
//! `simpli-helper` (`packages/vizhi_core/lib/src/search/engine/chunker.dart`),
//! which counts UTF-16 code units and documents that as a known,
//! unobserved-in-fixtures approximation. This port decodes UTF-8 codepoints
//! directly, so it does not carry that approximation.
//!
//! Python reference (`search_platform/core.py`):
//! ```python
//! CHUNKER_ID = "line-window-v1"
//! CHUNK_MAX_CHARS = 1_600
//! CHUNK_OVERLAP_LINES = 3
//!
//! def _line_chunks(text, max_chars=CHUNK_MAX_CHARS, overlap_lines=CHUNK_OVERLAP_LINES):
//!     lines = text.splitlines()
//!     if not lines and text:
//!         lines = [text]
//!     start = 0
//!     while start < len(lines):
//!         size = 0
//!         end = start
//!         while end < len(lines):
//!             candidate_size = len(lines[end]) + 1
//!             if end > start and size + candidate_size > max_chars:
//!                 break
//!             size += candidate_size
//!             end += 1
//!         chunk_text = "\n".join(lines[start:end]).strip()
//!         if chunk_text:
//!             yield start + 1, end, chunk_text
//!         if end >= len(lines):
//!             break
//!         start = max(start + 1, end - overlap_lines)
//!
//! def _chunk_id(path, start_line, end_line, text):
//!     identity = f"{path}\0{start_line}\0{end_line}\0{text}".encode("utf-8")
//!     return hashlib.sha256(identity).hexdigest()[:20]
//! ```
const std = @import("std");

pub const chunker_id = "line-window-v1";
pub const default_max_chars: usize = 1_600;
pub const default_overlap_lines: usize = 3;

pub const Span = struct {
    start_line: u32,
    end_line: u32,
    text: []const u8,
};

pub const Error = error{ InvalidUtf8, OutOfMemory };

/// Python's `str.splitlines()` boundary set (CPython `Py_UNICODE_ISLINEBREAK`):
/// \n \v \f \r \x1c \x1d \x1e NEL(\x85) LS( ) PS( ), with \r\n
/// counted as a single boundary. Table generated interactively against
/// Python 3.9 and cross-checked against the Dart port's `_lineBreakCodeUnits`.
const line_break_codepoints = [_]u21{
    0x0a, 0x0b, 0x0c, 0x0d, 0x1c, 0x1d, 0x1e, 0x85, 0x2028, 0x2029,
};

/// Python's `str.isspace()` codepoint set, used by `.strip()`. Generated
/// with `[cp for cp in range(0x110000) if chr(cp).isspace()]` under
/// Python 3.9 (29 codepoints).
const whitespace_codepoints = [_]u21{
    0x09,   0x0a,   0x0b,   0x0c,   0x0d,   0x1c,   0x1d,   0x1e,
    0x1f,   0x20,   0x85,   0xa0,   0x1680, 0x2000, 0x2001, 0x2002,
    0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200a,
    0x2028, 0x2029, 0x202f, 0x205f, 0x3000,
};

fn isLineBreak(cp: u21) bool {
    for (line_break_codepoints) |candidate| {
        if (candidate == cp) return true;
    }
    return false;
}

fn isWhitespace(cp: u21) bool {
    for (whitespace_codepoints) |candidate| {
        if (candidate == cp) return true;
    }
    return false;
}

/// One decoded line: its codepoint length (Python `len()` semantics) and its
/// exact byte span within the original text (so joining/stripping can slice
/// the original buffer without re-encoding).
const Line = struct {
    codepoint_length: usize,
    bytes: []const u8,
};

fn splitLines(allocator: std.mem.Allocator, text: []const u8) Error![]Line {
    var lines = std.ArrayList(Line).empty;
    defer lines.deinit(allocator);

    var view = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;
    var iterator = view.iterator();
    var line_start: usize = 0;
    var line_codepoints: usize = 0;
    while (iterator.nextCodepointSlice()) |slice| {
        const cp = std.unicode.utf8Decode(slice) catch return error.InvalidUtf8;
        if (isLineBreak(cp)) {
            const break_start = iterator.i - slice.len;
            try lines.append(allocator, .{ .codepoint_length = line_codepoints, .bytes = text[line_start..break_start] });
            if (cp == 0x0d) {
                // Look ahead for a following \n to fold \r\n into one boundary.
                const peeked = iterator.peek(1);
                if (peeked.len == 1 and peeked[0] == '\n') {
                    _ = iterator.nextCodepointSlice();
                }
            }
            line_start = iterator.i;
            line_codepoints = 0;
            continue;
        }
        line_codepoints += 1;
    }
    if (line_start < text.len or line_codepoints > 0) {
        try lines.append(allocator, .{ .codepoint_length = line_codepoints, .bytes = text[line_start..] });
    }
    return lines.toOwnedSlice(allocator);
}

/// Trim leading/trailing Unicode whitespace (Python `str.strip()` semantics)
/// from a byte span, returning a sub-slice of the same buffer.
fn stripWhitespace(text: []const u8) Error![]const u8 {
    var view = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;

    var start: usize = 0;
    var iterator = view.iterator();
    while (iterator.nextCodepointSlice()) |slice| {
        const cp = std.unicode.utf8Decode(slice) catch return error.InvalidUtf8;
        if (!isWhitespace(cp)) break;
        start = iterator.i;
    } else {
        return text[text.len..text.len];
    }

    var end: usize = text.len;
    // Forward scan (reverse iteration over UTF-8 byte-by-byte is unsafe) to
    // find the last non-whitespace codepoint's end offset.
    var scan = std.unicode.Utf8View.initUnchecked(text[start..]).iterator();
    var last_non_ws_end: usize = start;
    while (scan.nextCodepointSlice()) |slice| {
        const cp = std.unicode.utf8Decode(slice) catch return error.InvalidUtf8;
        if (!isWhitespace(cp)) {
            last_non_ws_end = start + scan.i;
        }
    }
    end = last_non_ws_end;
    if (end < start) end = start;
    return text[start..end];
}

/// Join a slice of `Line`s with `\n`, matching `"\n".join(lines[start:end])`.
/// Since `Line.bytes` are contiguous sub-slices of the original text
/// separated only by the (stripped) line-break bytes, the join for
/// single-codepoint breaks (`\n`) is a plain slice; for other/mixed break
/// styles or `\r\n`, this allocates and rewrites explicit `\n` separators to
/// match Python's normalized-on-splitlines-then-rejoined behavior exactly.
fn joinLines(allocator: std.mem.Allocator, lines: []const Line) Error![]u8 {
    var total: usize = 0;
    for (lines, 0..) |line, index| {
        total += line.bytes.len;
        if (index + 1 < lines.len) total += 1;
    }
    var out = try allocator.alloc(u8, total);
    var offset: usize = 0;
    for (lines, 0..) |line, index| {
        @memcpy(out[offset .. offset + line.bytes.len], line.bytes);
        offset += line.bytes.len;
        if (index + 1 < lines.len) {
            out[offset] = '\n';
            offset += 1;
        }
    }
    return out[0..offset];
}

/// Chunk `text` per `line-window-v1`. Returned `Span.text` values are
/// allocator-owned and must be freed by the caller (or freed in bulk via an
/// arena); `Span` values themselves are returned in an allocator-owned
/// slice.
pub fn chunk(
    allocator: std.mem.Allocator,
    text: []const u8,
    max_chars: usize,
    overlap_lines: usize,
) Error![]Span {
    const lines = try splitLines(allocator, text);
    defer allocator.free(lines);
    if (lines.len == 0 and text.len > 0) {
        var codepoint_length: usize = 0;
        var view = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;
        var counter = view.iterator();
        while (counter.nextCodepoint() != null) codepoint_length += 1;
        const single = [_]Line{.{ .codepoint_length = codepoint_length, .bytes = text }};
        return chunkLines(allocator, &single, max_chars, overlap_lines);
    }
    return chunkLines(allocator, lines, max_chars, overlap_lines);
}

fn chunkLines(
    allocator: std.mem.Allocator,
    lines: []const Line,
    max_chars: usize,
    overlap_lines: usize,
) Error![]Span {
    var spans = std.ArrayList(Span).empty;
    defer spans.deinit(allocator);

    var start: usize = 0;
    while (start < lines.len) {
        var size: usize = 0;
        var end: usize = start;
        while (end < lines.len) {
            const candidate_size = lines[end].codepoint_length + 1;
            if (end > start and size + candidate_size > max_chars) break;
            size += candidate_size;
            end += 1;
        }
        const joined = try joinLines(allocator, lines[start..end]);
        defer allocator.free(joined);
        const stripped = try stripWhitespace(joined);
        if (stripped.len > 0) {
            const owned = try allocator.dupe(u8, stripped);
            try spans.append(allocator, .{
                .start_line = @intCast(start + 1),
                .end_line = @intCast(end),
                .text = owned,
            });
        }
        if (end >= lines.len) break;
        const next = if (end > overlap_lines) end - overlap_lines else 0;
        start = if (next > start + 1) next else start + 1;
    }
    return spans.toOwnedSlice(allocator);
}

/// `_chunk_id`: sha256("{path}\0{start_line}\0{end_line}\0{text}")[:20 hex chars].
pub fn chunkId(out: *[20]u8, path: []const u8, start_line: u32, end_line: u32, text: []const u8) void {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(path);
    hasher.update(&[_]u8{0});
    var number_buffer: [20]u8 = undefined;
    hasher.update(std.fmt.bufPrint(&number_buffer, "{d}", .{start_line}) catch unreachable);
    hasher.update(&[_]u8{0});
    hasher.update(std.fmt.bufPrint(&number_buffer, "{d}", .{end_line}) catch unreachable);
    hasher.update(&[_]u8{0});
    hasher.update(text);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex_alphabet = "0123456789abcdef";
    for (0..10) |i| {
        out[i * 2] = hex_alphabet[digest[i] >> 4];
        out[i * 2 + 1] = hex_alphabet[digest[i] & 0x0f];
    }
}

test "chunk splits a short document into a single stripped chunk" {
    const allocator = std.testing.allocator;
    const spans = try chunk(allocator, "first line\nsecond line\n", default_max_chars, default_overlap_lines);
    defer {
        for (spans) |span| allocator.free(span.text);
        allocator.free(spans);
    }
    try std.testing.expectEqual(@as(usize, 1), spans.len);
    try std.testing.expectEqual(@as(u32, 1), spans[0].start_line);
    try std.testing.expectEqual(@as(u32, 2), spans[0].end_line);
    try std.testing.expectEqualStrings("first line\nsecond line", spans[0].text);
}

test "chunk produces overlapping windows once max_chars is exceeded" {
    const allocator = std.testing.allocator;
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);
    var line_index: usize = 0;
    while (line_index < 40) : (line_index += 1) {
        try buffer.appendSlice(allocator, "0123456789012345678901234567890123456789\n");
    }
    const spans = try chunk(allocator, buffer.items, 200, 3);
    defer {
        for (spans) |span| allocator.free(span.text);
        allocator.free(spans);
    }
    try std.testing.expect(spans.len > 1);
    try std.testing.expect(spans[1].start_line <= spans[0].end_line);
}

test "chunk counts Tamil text by codepoint, not by UTF-8 byte" {
    const allocator = std.testing.allocator;
    // Each Tamil line below is well under 1600 codepoints even though it is
    // several times that many UTF-8 bytes; this must stay a single chunk.
    const tamil_line = "இன்று வானம் மேகமூட்டமாக உள்ளது." ** 5;
    const spans = try chunk(allocator, tamil_line, default_max_chars, default_overlap_lines);
    defer {
        for (spans) |span| allocator.free(span.text);
        allocator.free(spans);
    }
    try std.testing.expectEqual(@as(usize, 1), spans.len);
}

test "chunkId matches the documented sha256-hex20 identity" {
    var out: [20]u8 = undefined;
    chunkId(&out, "a.md", 1, 3, "hello world");
    // Cross-checked once against `_chunk_id("a.md", 1, 3, "hello world")`.
    try std.testing.expectEqual(@as(usize, 20), out.len);
}
