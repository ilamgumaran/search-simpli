"""S6-T8 verifier (fifth check): my plants on 284a0e7, written from the code. v-wk-v4-tail again (F5), varintsEnd on
its own, and the read-time v4 decoder find uses (validateOneByteOffsets, checkSpansWithinText). Each anchor must occur
once. plants5.py COPY NAME"""
import sys
from pathlib import Path
copy, name = Path(sys.argv[1]), sys.argv[2]
src = copy / "zig" / "src"
WK_END = "    if (at != offsets.len) return error.InvalidLexicalSection;\n    return starts;\n"
VE = "        if (offset >= bytes.len) return null;\n        if (bytes[offset] & 0x80 == 0) remaining -= 1;\n"
BEFORE = "            if (start < 0) return error.OffsetsStartBeforeChunk;\n"
DECR = "            if (start < previous_start) return error.OffsetsStartDecreases;\n"
LNC = "                l = try readOffsetsVarint(offsets, &at);\n                if (l < offsets_escape) return error.OffsetsNonCanonicalEscape;\n"
ENDO = "            if (end > std.math.maxInt(u32)) return error.OffsetsEndOverflow;\n"
R11 = "    for (spans) |span| if (@as(usize, span.start) + span.length > codepoints) return error.OffsetsPastText;\n"
P = {
    "v-wk-v4-tail": [("apply.zig", WK_END, WK_END.replace("if (at != offsets.len)", "if (at != offsets.len and sections.coding == .pairs)"))],
    # varintsEnd on its own: the bytes running out read as the end of the varints
    "v-ve-end-break": [("source.zig", VE, VE.replace("return null;", "break;"))],
    # v4 rule 8: a start before the chunk let through
    "v-vo-before-chunk": [("postings.zig", BEFORE, BEFORE.replace("if (start < 0)", "if (start < 0 and false)"))],
    # v4 rule 9: a start before the previous start let through
    "v-vo-decreases": [("postings.zig", DECR, DECR.replace("if (start < previous_start)", "if (start < previous_start and false)"))],
    # v4 rule 6, the length escape only: a non-canonical length escape let through
    "v-vo-len-noncanon": [("postings.zig", LNC, LNC.replace("if (l < offsets_escape)", "if (l < offsets_escape and false)"))],
    # v4 rule 10: an end past a u32 let through
    "v-vo-end-overflow": [("postings.zig", ENDO, ENDO.replace("if (end > std.math.maxInt(u32))", "if (end > std.math.maxInt(u32) + 1)"))],
    # v4 rule 11 at find: an end one past the text let through
    "v-r11-by-one": [("postings.zig", R11, R11.replace("> codepoints)", "> codepoints + 1)"))],
}
for f, old, new in P[name]:
    p = src / f
    s = p.read_text()
    assert s.count(old) == 1, (name, f, s.count(old))
    assert old != new, name
    p.write_text(s.replace(old, new))
print("planted", name)
