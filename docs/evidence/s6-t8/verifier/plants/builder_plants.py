"""Apply one S6-T8 plant to a copy's zig/src. Usage: plants.py <copy> <name>

Each plant breaks `HYBLEX04`'s section 5 one way; `zig build test` in that
copy (fresh caches) must fail. The symmetric plants change the writer and
every reader alike, so only the fixed bytes (the format document's worked
example, the committed fixtures) can catch them.
"""
import sys
from pathlib import Path

copy, name = Path(sys.argv[1]), sys.argv[2]
src = copy / "zig" / "src"

DECODERS = [
    # validateOneByteOffsets
    ("            var g: u32 = byte & 0x0F;\n            var l: u32 = byte >> 4;\n            if (g == offsets_escape) {",
     "            var g: u32 = byte >> 4;\n            var l: u32 = byte & 0x0F;\n            if (g == offsets_escape) {"),
    # skipOffsetsTable needs no change (it skips both escapes alike).
    # readOffsetsTableChecked
    ("                var g: u32 = byte & 0x0F;\n                length = byte >> 4;",
     "                var g: u32 = byte >> 4;\n                length = byte & 0x0F;"),
    # readOffsetsTable
    ("                var g: u32 = byte & 0x0F;\n                var l: u32 = byte >> 4;\n                if (g == offsets_escape) g = readVarint(bytes, &at).?;",
     "                var g: u32 = byte >> 4;\n                var l: u32 = byte & 0x0F;\n                if (g == offsets_escape) g = readVarint(bytes, &at).?;"),
]

PLANTS = {
    # The gap in the high nibble and the length in the low one, writer and
    # every reader.
    "nibbles-swapped": [("postings.zig",
        "    try list.append(allocator, g | (l << 4));",
        "    try list.append(allocator, l | (g << 4));"),
        # rulings on the Report, item 1b: the first publish's transcoder too.
        ("postings.zig", "        out[w] = g | (l << 4);", "        out[w] = l | (g << 4);")] + [("postings.zig", o, n) for o, n in DECODERS],
    # The escape at 14 (14 and up escape) or 16, writer and readers alike.
    "escape-14": [("postings.zig", "pub const offsets_escape: u8 = 15;", "pub const offsets_escape: u8 = 14;")],
    "escape-16": [("postings.zig", "pub const offsets_escape: u8 = 15;", "pub const offsets_escape: u8 = 16;")],
    # The length's escape before the gap's, writer and every reader.
    "escape-order-swapped": [
        # rulings on the Report, item 1b: the first publish's transcoder too.
        ("postings.zig",
         "        if (g == offsets_escape) putVarint(out, &w, @intCast(z));\n        if (l == offsets_escape) putVarint(out, &w, @intCast(kept));",
         "        if (l == offsets_escape) putVarint(out, &w, @intCast(kept));\n        if (g == offsets_escape) putVarint(out, &w, @intCast(z));"),
        ("postings.zig",
         "    if (g == offsets_escape) try appendVarint(list, allocator, @intCast(z));\n    if (l == offsets_escape) try appendVarint(list, allocator, length);",
         "    if (l == offsets_escape) try appendVarint(list, allocator, length);\n    if (g == offsets_escape) try appendVarint(list, allocator, @intCast(z));"),
        ("postings.zig",
         "            if (g == offsets_escape) {\n                g = try readOffsetsVarint(offsets, &at);\n                if (g < offsets_escape) return error.OffsetsNonCanonicalEscape;\n            }\n            if (l == offsets_escape) {\n                l = try readOffsetsVarint(offsets, &at);\n                if (l < offsets_escape) return error.OffsetsNonCanonicalEscape;\n            }",
         "            if (l == offsets_escape) {\n                l = try readOffsetsVarint(offsets, &at);\n                if (l < offsets_escape) return error.OffsetsNonCanonicalEscape;\n            }\n            if (g == offsets_escape) {\n                g = try readOffsetsVarint(offsets, &at);\n                if (g < offsets_escape) return error.OffsetsNonCanonicalEscape;\n            }"),
        ("postings.zig",
         "                if (g == offsets_escape) g = readVarint(bytes, &at) orelse return null;\n                if (length == offsets_escape) length = readVarint(bytes, &at) orelse return null;",
         "                if (length == offsets_escape) length = readVarint(bytes, &at) orelse return null;\n                if (g == offsets_escape) g = readVarint(bytes, &at) orelse return null;"),
        ("postings.zig",
         "                if (g == offsets_escape) g = readVarint(bytes, &at).?;\n                if (l == offsets_escape) l = readVarint(bytes, &at).?;",
         "                if (l == offsets_escape) l = readVarint(bytes, &at).?;\n                if (g == offsets_escape) g = readVarint(bytes, &at).?;"),
    ],
    # The reader takes the zigzag value as an unsigned gap.
    "zigzag-unsigned": [("postings.zig",
        "    const half: i64 = @intCast(z >> 1);\n    return if (z & 1 == 0) half else -half - 1;",
        "    return @intCast(z);")],
    # The reader's token count one short: a chunk's last token unread.
    "count-off-by-one": [("postings.zig",
        "            const count: usize = readVarint(bytes, &at).?;\n            var end: i64 = 0;",
        "            const count: usize = readVarint(bytes, &at).? -| 1;\n            var end: i64 = 0;")],
    # `HYBLEX03`'s section 5 (pairs) read as v4's.
    "old-reader-removed": [("lexical_segment.zig",
        "if (header.version == version_v4) .one_byte else .pairs",
        ".one_byte")],
    # A byte after the last document's last token accepted.
    "leftover-accepted": [("postings.zig",
        "    if (at != offsets.len) return error.OffsetsTrailingData;\n",
        "")],
}

for file, old, new in PLANTS[name]:
    p = src / file
    s = p.read_text()
    assert s.count(old) == 1, (name, file, old)
    p.write_text(s.replace(old, new))
print("planted", name)
