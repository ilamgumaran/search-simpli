"""S6-T8 verifier (fourth check): my own plants on 60d86e4, written from the code (not from the builder's
plants_sites.py). Each anchor must occur once; each plant changes one site. plants4.py COPY NAME"""
import sys
from pathlib import Path
copy, name = Path(sys.argv[1]), sys.argv[2]
src = copy / "zig" / "src"
CK_HEAD = "pub fn checkPairsTable(offsets: []const u8, at_start: usize, end: usize, count: u32) error{InvalidPositions}!void {\n"
TR_HEAD = "pub fn transcodePairsTable(\n"
def reader(fname, shift_bound, cut):
    tail = "    offset.* = at;\n    return @truncate(value);\n}\n\n" if cut else \
           "    if (value > std.math.maxInt(u32)) return null;\n    offset.* = at;\n    return @intCast(value);\n}\n\n"
    return ("/// verifier plant reader\nfn " + fname + "(bytes: []const u8, offset: *usize) ?u32 {\n    var value: u64 = 0;\n"
            "    var shift: u6 = 0;\n    var at = offset.*;\n    while (true) {\n"
            "        if (at >= bytes.len or shift > " + str(shift_bound) + ") return null;\n"
            "        const byte = bytes[at];\n        at += 1;\n        value |= @as(u64, byte & 0x7F) << shift;\n"
            "        if (byte & 0x80 == 0) break;\n        shift += 7;\n    }\n" + tail)
CUT, SIX = reader("vpCut", 28, True), reader("vpSix", 35, False)
CK_START = "        start += readVarint(bytes, &at) orelse return error.InvalidPositions;\n        const length = readVarint(bytes, &at) orelse return error.InvalidPositions;\n"
CK_RULE = "        if (length == 0 or start + length > std.math.maxInt(u32)) return error.InvalidPositions;\n    }\n    if (at != end) return error.InvalidPositions;\n}\n"
TR_SLOW = "            delta = readVarint(bytes, &at) orelse return error.InvalidPositions;\n            length = readVarint(bytes, &at) orelse return error.InvalidPositions;\n"
TR_FAST = "            delta = bytes[at];\n            length = bytes[at + 1];\n"
TR_RULE = "        // v2's rules: every length at least 1, every end within a u32.\n        if (length == 0 or start + length > std.math.maxInt(u32)) return error.InvalidPositions;\n"
TR_GAP = "        if (z > std.math.maxInt(u32)) return error.GapNotRepresentable;\n"
TR_END = "    if (at != end) return error.InvalidPositions;\n    list.items.len += w;\n"
TR_SLICE = ") (std.mem.Allocator.Error || error{ InvalidPositions, GapNotRepresentable })!void {\n    const bytes = offsets[0..end];\n"
OB_GAP = "        if (byte & 0x0F == offsets_escape) at = skipOneVarint(bytes, at) orelse return null;\n"
WK_END = "    if (at != offsets.len) return error.InvalidLexicalSection;\n    return starts;\n"
P = {
    # row 4 (the Third Verdict's F4 plant, as plants3.py made it): ck's start delta read cut to 32 bits
    "ck-fifth-loose-start": [("postings.zig", CK_HEAD, CUT + CK_HEAD), ("postings.zig", CK_START, CK_START.replace("start += readVarint(", "start += vpCut("))],
    # row 3: ck's start delta read lets a sixth byte through
    "v-ck-start-six": [("postings.zig", CK_HEAD, SIX + CK_HEAD), ("postings.zig", CK_START, CK_START.replace("start += readVarint(", "start += vpSix("))],
    # row 9: ck lets an end of exactly 2^32 through
    "v-ck-end-eq": [("postings.zig", CK_RULE, CK_RULE.replace("> std.math.maxInt(u32))", "> std.math.maxInt(u32) + 1)"))],
    # row 14: tr's slow-path start delta cut to 32 bits
    "v-tr-start-cut": [("postings.zig", TR_HEAD, CUT + TR_HEAD), ("postings.zig", TR_SLOW, TR_SLOW.replace("delta = readVarint(", "delta = vpCut("))],
    # row 13: tr's slow-path start delta lets a sixth byte through
    "v-tr-start-six": [("postings.zig", TR_HEAD, SIX + TR_HEAD), ("postings.zig", TR_SLOW, TR_SLOW.replace("delta = readVarint(", "delta = vpSix("))],
    # row 18: the F1 repair restored on tr's fast path only (a one-byte length of 0 read as 1)
    "v-tr-zero-fast-repair": [("postings.zig", TR_FAST, TR_FAST.replace("length = bytes[at + 1];", "length = @max(bytes[at + 1], 1);"))],
    # row 19: tr lets an end of exactly 2^32 through
    "v-tr-end-eq": [("postings.zig", TR_RULE, TR_RULE.replace("> std.math.maxInt(u32))", "> std.math.maxInt(u32) + 1)"))],
    # row 20: tr's gap refusal published as InvalidPositions (InvalidLexicalSection expected)
    "v-tr-gap-error": [("postings.zig", TR_GAP, TR_GAP.replace("error.GapNotRepresentable", "error.InvalidPositions"))],
    # row 21: tr refuses only reading past the end, not stopping short of it
    "v-tr-leftover-gt": [("postings.zig", TR_END, TR_END.replace("if (at != end)", "if (at > end)"))],
    # row 17: tr reads past its table's end (bytes not cut at end)
    "v-tr-unsliced": [("postings.zig", TR_SLICE, TR_SLICE.replace("const bytes = offsets[0..end];", "const bytes = offsets;"))],
    # row 27: ob takes the section's end for the end of a gap escape cut short
    "v-ob-gap-to-end": [("postings.zig", OB_GAP, OB_GAP.replace("orelse return null;", "orelse bytes.len;"))],
    # row 32, v4 side: the walk's end check kept for v2 only
    "v-wk-v4-tail": [("apply.zig", WK_END, WK_END.replace("if (at != offsets.len)", "if (at != offsets.len and sections.coding == .pairs)"))],
}
for f, old, new in P[name]:
    p = src / f
    s = p.read_text()
    assert s.count(old) == 1, (name, f, s.count(old))
    assert old != new, name
    p.write_text(s.replace(old, new))
print("planted", name)
