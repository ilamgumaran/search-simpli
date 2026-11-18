"""S6-T8 verifier (sixth check): my plants on 965cce7, written from the code. Each anchor must occur once.
F6 again; two in the encode's check of a new v4 section (item 3); four of a kind the builder's by-one sweep does not
make (a check dropped for one case, an order swapped, a base changed). plants6.py COPY NAME"""
import sys
from pathlib import Path
copy, name = Path(sys.argv[1]), sys.argv[2]
src = copy / "zig" / "src"
ENDO = "            if (end > std.math.maxInt(u32)) return error.OffsetsEndOverflow;\n"
ENC = ("        validatePositions(index.terms, index.postings, index.document_lengths, sections) catch |err| return switch (err) {\n"
       "            error.UnsortedTerms => error.UnsortedTerms,\n"
       "            else => error.InvalidPositions,\n"
       "        };\n")
def enc_let(e):
    return ("        validatePositions(index.terms, index.postings, index.document_lengths, sections) catch |err| switch (err) {\n"
            "            error.UnsortedTerms => return error.UnsortedTerms,\n"
            f"            error.{e} => {{}},\n"
            "            else => return error.InvalidPositions,\n"
            "        };\n")
R11 = "    for (spans) |span| if (@as(usize, span.start) + span.length > codepoints) return error.OffsetsPastText;\n"
TRE = "        previous_end = start + length;\n    }\n    if (at != end) return error.InvalidPositions;\n    list.items.len += w;\n"
LAZY = "    const sections = index.positions orelse return;\n    return validatePositions(index.terms, index.postings, index.document_lengths, sections);\n"
ESC = "                if (g == offsets_escape) g = readVarint(bytes, &at).?;\n                if (l == offsets_escape) l = readVarint(bytes, &at).?;\n"
P = {
    # F6: v4 rule 10 lets an end of exactly 2^32 through
    "v-vo-end-overflow": [("postings.zig", ENDO, ENDO.replace("if (end > std.math.maxInt(u32))", "if (end > std.math.maxInt(u32) + 1)"))],
    # item 3: the encode's check of the new section lets a v4 length of 0 through (value damage in a carried v4 table)
    "v-enc-zero-ok": [("lexical_segment.zig", ENC, enc_let("OffsetsZeroLength"))],
    # item 3: the encode's check lets a v4 count mismatch through (a stray byte after an inner v4 table)
    "v-enc-count-ok": [("lexical_segment.zig", ENC, enc_let("OffsetsCountMismatch"))],
    # new: rule 11 checks only a chunk's first span
    "v-r11-first-only": [("postings.zig", R11, R11.replace("for (spans) |span|", "for (spans[0..@min(spans.len, 1)]) |span|"))],
    # new: the transcoder's gaps taken from the previous token's start, not its end
    "v-tr-gap-from-start": [("postings.zig", TRE, TRE.replace("previous_end = start + length;", "previous_end = start;"))],
    # new: the deferred (lazy) validation skips a v4 section
    "v-lazy-v4-skip": [("lexical_segment.zig", LAZY, LAZY.replace("orelse return;\n", "orelse return;\n    if (sections.coding == .one_byte) return;\n"))],
    # new: find's v4 decoder reads a token's length escape before its gap escape
    "v-rts-escape-order": [("postings.zig", ESC, "                if (l == offsets_escape) l = readVarint(bytes, &at).?;\n                if (g == offsets_escape) g = readVarint(bytes, &at).?;\n")],
}
for f, old, new in P[name]:
    p = src / f
    s = p.read_text()
    assert s.count(old) == 1, (name, f, s.count(old))
    assert old != new, name
    p.write_text(s.replace(old, new))
print("planted", name)
