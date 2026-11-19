"""S6-T8 verifier: my own plants, aimed at the two late changes (fb74582, e5d1734) and the boundaries.
my_plants.py COPY NAME"""
import sys
from pathlib import Path
copy, name = Path(sys.argv[1]), sys.argv[2]
src = copy / "zig" / "src"
P = {
    # oneByteTableEnd: a whole 16-byte block skipped when fewer than 16 tokens remain (the last block partial)
    "block-overstep": [("postings.zig", "        if (remaining >= lanes and bytes.len - at >= lanes) {", "        if (remaining >= 1 and bytes.len - at >= lanes) {"),
                       ("postings.zig", "                remaining -= lanes;", "                remaining -|= lanes;")],
    # the block test looks at the low (gap) nibble only / the high (length) nibble only
    "block-low-only": [("postings.zig", "            if (!@reduce(.Or, low == escape) and !@reduce(.Or, high == escape)) {", "            if (!@reduce(.Or, low == escape)) {")],
    "block-high-only": [("postings.zig", "            if (!@reduce(.Or, low == escape) and !@reduce(.Or, high == escape)) {", "            if (!@reduce(.Or, high == escape)) {")],
    # (the first versions of the two block plants did not compile: Zig refuses an unused constant; these discard it)
    "block-low-only2": [("postings.zig", "            if (!@reduce(.Or, low == escape) and !@reduce(.Or, high == escape)) {", "            _ = high;\n            if (!@reduce(.Or, low == escape)) {")],
    "block-high-only2": [("postings.zig", "            if (!@reduce(.Or, low == escape) and !@reduce(.Or, high == escape)) {", "            _ = low;\n            if (!@reduce(.Or, high == escape)) {")],
    # check 10: one assertion broken in each new test file (shows zig build test runs it)
    "brk-offsets-test": [("offsets_v4_test.zig", "    try std.testing.expectEqual(@as(usize, 32), (try postings.withOffsetsCoding(a, index, .pairs)).positions.?.offsets.len);", "    try std.testing.expectEqual(@as(usize, 33), (try postings.withOffsetsCoding(a, index, .pairs)).positions.?.offsets.len);")],
    "brk-compat-test": [("compat_s6t8_test.zig", "    try std.testing.expect(refusedBeforeV25(committed_manifest));", "    try std.testing.expect(!refusedBeforeV25(committed_manifest));")],
    # the per-token tail of oneByteTableEnd forgets the length's escape varint
    "tableend-no-length-escape": [("postings.zig", "        if (byte >> 4 == offsets_escape) at = skipOneVarint(bytes, at) orelse return null;\n        remaining -= 1;", "        remaining -= 1;")],
    # transcodePairsTable drops each table's last token (count kept)
    "transcode-drop-last": [("postings.zig", "    for (0..count) |_| {\n        var delta: u32 = undefined;", "    for (0..count) |ti| {\n        var delta: u32 = undefined;"),
                            ("postings.zig", "        out[w] = g | (l << 4);\n        w += 1;", "        if (ti + 1 == count) {\n            previous_end = start + kept;\n            continue;\n        }\n        out[w] = g | (l << 4);\n        w += 1;")],
    # transcodePairsTable: gap measured from the previous start, not the previous end
    "transcode-gap-from-start": [("postings.zig", "        previous_end = start + kept;\n    }\n    if (at != end) return error.InvalidTable;", "        previous_end = start;\n    }\n    if (at != end) return error.InvalidTable;")],
    # transcodePairsTable fast path: delta and length swapped
    "transcode-fastpath-swap": [("postings.zig", "            delta = bytes[at];\n            length = bytes[at + 1];", "            delta = bytes[at + 1];\n            length = bytes[at];")],
    # transcodePairsTable keeps a v2 length of 0 as 0 (no @max): checks whether a test pins the repair
    "transcode-keep-zero": [("postings.zig", "        const kept: u64 = @max(length, 1);", "        const kept: u64 = length;")],
    # fb74582's moved rule removed entirely: makeHit no longer checks rule 11
    "rule11-removed": [("find.zig", "        const token_spans = try context.spans(candidate.document_index, codepoints);", "        const token_spans = try context.spans(candidate.document_index, null);")],
    # rule 11 checked against codepoints - 1 (an end exactly at the text's end refused)
    "rule11-off-by-one": [("postings.zig", "    for (spans) |span| if (@as(usize, span.start) + span.length > codepoints) return error.OffsetsPastText;", "    for (spans) |span| if (@as(usize, span.start) + span.length >= codepoints) return error.OffsetsPastText;")],
    # every reader reads a gap varint when only the length escapes
    "gap-varint-on-length-escape": [
        ("postings.zig", "            if (g == offsets_escape) {\n                g = try readOffsetsVarint(offsets, &at);", "            if (g == offsets_escape or l == offsets_escape) {\n                g = try readOffsetsVarint(offsets, &at);"),
        ("postings.zig", "                if (g == offsets_escape) g = readVarint(bytes, &at) orelse return null;", "                if (g == offsets_escape or length == offsets_escape) g = readVarint(bytes, &at) orelse return null;"),
        ("postings.zig", "                if (g == offsets_escape) g = readVarint(bytes, &at).?;", "                if (g == offsets_escape or l == offsets_escape) g = readVarint(bytes, &at).?;")],
    # the pre-S6-T4 reader (HYBLEX02) wired to the one-byte decoder
    "v2-reader-one-byte": [("postings.zig", "    coding: OffsetsCoding = .pairs,", "    coding: OffsetsCoding = .one_byte,")],
    # validation: rule 9 (start decreases) dropped / rule 8 (start before chunk) dropped / rule 6 dropped
    "rule9-dropped": [("postings.zig", "            if (start < previous_start) return error.OffsetsStartDecreases;\n", "")],
    "rule8-dropped": [("postings.zig", "            if (start < 0) return error.OffsetsStartBeforeChunk;\n", "")],
    "rule6-length-dropped": [("postings.zig", "                if (l < offsets_escape) return error.OffsetsNonCanonicalEscape;\n", "")],
    # the writer's escape test at > 15 for the length only (15 written in the nibble = misread as an escape)
    "writer-length-escape-gt": [("postings.zig", "    const l: u8 = if (length >= offsets_escape) offsets_escape else @intCast(length);", "    const l: u8 = if (length > offsets_escape) offsets_escape else @intCast(length);")],
    # (writer-length-escape-gt turned out equivalent: a length of 15 still gives the nibble 15 and line 79 still
    #  writes its varint, so the bytes do not change.) The non-equivalent boundary: the writer escapes a length of 14
    #  (nibble 15, varint 14), which rule 6 refuses.
    "writer-length-escape-14": [("postings.zig", "    const l: u8 = if (length >= offsets_escape) offsets_escape else @intCast(length);", "    const l: u8 = if (length >= offsets_escape - 1) offsets_escape else @intCast(length);")],
    # the same at the gap: a zigzag gap of 14 escaped
    # (writer-gap-escape-14's line occurs twice; this one names appendOneByteToken's own pair of lines)
    "writer-gap-escape-14b": [("postings.zig", "    const z = zigzag(@as(i64, start) - @as(i64, previous_end));\n    const g: u8 = if (z >= offsets_escape) offsets_escape else @intCast(z);", "    const z = zigzag(@as(i64, start) - @as(i64, previous_end));\n    const g: u8 = if (z >= offsets_escape - 1) offsets_escape else @intCast(z);")],
    "writer-gap-escape-14": [("postings.zig", "    const g: u8 = if (z >= offsets_escape) offsets_escape else @intCast(z);", "    const g: u8 = if (z >= offsets_escape - 1) offsets_escape else @intCast(z);")],
}
for f, old, new in P[name]:
    p = src / f
    s = p.read_text()
    assert s.count(old) == 1, (name, f, s.count(old), old)
    p.write_text(s.replace(old, new))
print("planted", name)
