"""S6-T8 verifier (recheck): plants on the final source (fa61957). Written by the verifier from the code; the first
three are the three F1 plants the builder ran, re-made here from their descriptions. Each anchor must occur once.
plants2.py COPY NAME"""
import sys
from pathlib import Path
copy, name = Path(sys.argv[1]), sys.argv[2]
src = copy / "zig" / "src"
TR_CHECK = ("        start += delta;\n        // v2's rules: every length at least 1, every end within a u32.\n"
            "        if (length == 0 or start + length > std.math.maxInt(u32)) return error.InvalidPositions;\n")
CK_CHECK = ("        const length = readVarint(bytes, &at) orelse return error.InvalidPositions;\n"
            "        if (length == 0 or start + length > std.math.maxInt(u32)) return error.InvalidPositions;\n    }\n    if (at != end) return error.InvalidPositions;\n}\n")
CK_COUNT = ("pub fn checkPairsTable(offsets: []const u8, at_start: usize, end: usize, count: u32) error{InvalidPositions}!void {\n"
            "    const bytes = offsets[0..end];\n    if (bytes.len < at_start or bytes.len - at_start < 4) return error.InvalidPositions;\n"
            "    if (std.mem.readInt(u32, bytes[at_start..][0..4], .little) != count) return error.InvalidPositions;\n")
TR_COUNT = (") (std.mem.Allocator.Error || error{ InvalidPositions, GapNotRepresentable })!void {\n    const bytes = offsets[0..end];\n"
            "    if (bytes.len < at_start or bytes.len - at_start < 4) return error.InvalidPositions;\n"
            "    if (std.mem.readInt(u32, bytes[at_start..][0..4], .little) != count) return error.InvalidPositions;\n")
TR_END = "        previous_end = start + length;\n    }\n    if (at != end) return error.InvalidPositions;\n    list.items.len += w;\n"
DROP = "            if (!carried.isSet(old)) try postings.checkPairsTable(sections.offsets, old_starts[old], old_starts[old + 1], length);\n"
CATCH = ("                error.InvalidPositions => return error.InvalidPositions,\n                error.GapNotRepresentable => return error.InvalidLexicalSection,\n")
P = {
    # --- the three F1 plants ---
    "f1-refusal-removed": [("postings.zig", TR_CHECK, TR_CHECK.replace("length == 0 or ", ""))],
    "f1-repair-restored": [("postings.zig", TR_CHECK, TR_CHECK.replace("        if (length == 0 or start + length",
                            "        length = @max(length, 1);\n        if (length == 0 or start + length"))],
    "f1-dropped-unchecked": [("apply.zig", DROP, DROP.replace("if (!carried.isSet(old))", "if (!carried.isSet(old) and old == std.math.maxInt(usize))"))],
    # --- mine: one validity check removed at a time ---
    "ck-zero-removed": [("postings.zig", CK_CHECK, CK_CHECK.replace("length == 0 or ", ""))],
    "ck-count-removed": [("postings.zig", CK_COUNT, CK_COUNT.replace(") != count) return error.InvalidPositions;\n", ") != count + 0 and false) return error.InvalidPositions;\n"))],
    "ck-u32-end-removed": [("postings.zig", CK_CHECK, CK_CHECK.replace("length == 0 or start + length > std.math.maxInt(u32)", "length == 0"))],
    "ck-end-removed": [("postings.zig", CK_CHECK, CK_CHECK.replace("    if (at != end) return error.InvalidPositions;\n}\n", "    if (at != end and false) return error.InvalidPositions;\n}\n"))],
    "tr-count-removed": [("postings.zig", TR_COUNT, TR_COUNT.replace(") != count) return error.InvalidPositions;\n", ") != count and false) return error.InvalidPositions;\n"))],
    "tr-end-removed": [("postings.zig", TR_END, TR_END.replace("if (at != end)", "if (at != end and false)"))],
    "tr-u32-end-removed": [("postings.zig", TR_CHECK, TR_CHECK.replace("length == 0 or start + length > std.math.maxInt(u32)", "length == 0"))],
    "tr-gap-check-removed": [("postings.zig", "        if (z > std.math.maxInt(u32)) return error.GapNotRepresentable;\n", "        if (z > std.math.maxInt(u32) and false) return error.GapNotRepresentable;\n")],
    # --- the removed-table check skipped for the last table ---
    "drop-skip-last": [("apply.zig", DROP, DROP.replace("if (!carried.isSet(old))", "if (!carried.isSet(old) and old + 1 < previous.document_lengths.len)"))],
    # --- the error mapped to success ---
    "drop-error-swallowed": [("apply.zig", DROP, DROP.replace("try postings.checkPairsTable(sections.offsets, old_starts[old], old_starts[old + 1], length);",
                              "postings.checkPairsTable(sections.offsets, old_starts[old], old_starts[old + 1], length) catch {};"))],
    "carry-error-swallowed": [("apply.zig", CATCH, CATCH.replace("error.InvalidPositions => return error.InvalidPositions,", "error.InvalidPositions => {},"))],
    "carry-error-to-gap": [("apply.zig", CATCH, CATCH.replace("error.InvalidPositions => return error.InvalidPositions,", "error.InvalidPositions => return error.InvalidLexicalSection,"))],
}
for f, old, new in P[name]:
    p = src / f
    s = p.read_text()
    assert s.count(old) == 1, (name, f, s.count(old))
    assert old != new, name
    p.write_text(s.replace(old, new))
print("planted", name)
