"""S6-T8 (the ruling after the Fifth Verdict): the boundary sweep. One plant per numeric bound or comparison of the
section-5 table code, each moving that bound by one in the accepting direction (`<` to `<=`, `>=` to `>`, a
constant plus or minus one; an equality let through for the value one either side), inside the named function's
body; for a site that serves both section-5 codings, one plant per coding. Each anchor must occur exactly once in
its function's body.

    plants_bounds.py COPY NAME     plant NAME into the source tree at COPY
    plants_bounds.py --list        print the plant names, one per line
"""
import sys
from pathlib import Path

VO = ("postings.zig", "pub fn validateOneByteOffsets(")
RO = ("postings.zig", "fn readOffsetsVarint(")
CK = ("postings.zig", "pub fn checkPairsTable(")
TR = ("postings.zig", "pub fn transcodePairsTable(")
OB = ("postings.zig", "pub fn oneByteTableEnd(")
SV = ("postings.zig", "fn skipOneVarint(")
RV = ("postings.zig", "pub fn readVarint(")
R11 = ("postings.zig", "pub fn checkSpansWithinText(")
FS = ("find.zig", "    fn spans(")
VE = ("source.zig", "pub fn varintsEnd(")
WK = ("apply.zig", "fn offsetTableStarts(")

READ_COUNT = "std.mem.readInt(u32, bytes[at_start..][0..4], .little)"
SHORT_LEN = ("if (bytes.len < at_start or", "if (bytes.len + 1 < at_start or")
SHORT_FOUR = ("bytes.len - at_start < 4)", "bytes.len - at_start < 3)")
COUNT_PLUS = (f"{READ_COUNT} != count)", f"{READ_COUNT} != count and @as(u64, {READ_COUNT}) != @as(u64, count) + 1)")
COUNT_MINUS = (f"{READ_COUNT} != count)", f"{READ_COUNT} != count and @as(u64, {READ_COUNT}) + 1 != count)")
ZERO = ("if (length == 0 or", "if (@as(i64, length) < 0 or")
END = ("start + length > std.math.maxInt(u32)) return", "start + length > std.math.maxInt(u32) + 1) return")
LEFT = ("    if (at != end) return error.InvalidPositions;", "    if (at != end and at + 1 != end) return error.InvalidPositions;")
WK_LAST = "    if (at != offsets.len) return error.InvalidLexicalSection;"

# name: (site, coding, [(function, old, new)])
P = {
    # validateOneByteOffsets (v4: the open, the first find, the encode) and its varint reader
    "b-vo-count-plus": ("vo: count != length (rule 2), one more let through", "v4",
                        [(VO, "if (count != length)", "if (count != length and count != @as(u64, length) + 1)")]),
    "b-vo-count-minus": ("vo: count != length (rule 2), one less let through", "v4",
                         [(VO, "if (count != length)", "if (count != length and @as(u64, count) + 1 != length)")]),
    "b-vo-token-at": ("vo: at >= len before a token byte (rule 3)", "v4",
                      [(VO, "if (at >= offsets.len) return error.OffsetsTruncated;", "if (at > offsets.len) return error.OffsetsTruncated;")]),
    "b-vo-gap-canon": ("vo: gap escape < 15 (rule 6)", "v4",
                       [(VO, "if (g < offsets_escape)", "if (g < offsets_escape - 1)")]),
    "b-vo-length-canon": ("vo: length escape < 15 (rule 6)", "v4",
                          [(VO, "if (l < offsets_escape)", "if (l < offsets_escape - 1)")]),
    "b-vo-zero": ("vo: length == 0, as < 1 (rule 7)", "v4",
                  [(VO, "if (l == 0)", "if (@as(i64, l) < 0)")]),
    "b-vo-before-chunk": ("vo: start < 0 (rule 8)", "v4",
                          [(VO, "if (start < 0)", "if (start < -1)")]),
    "b-vo-decreases": ("vo: start < previous start (rule 9)", "v4",
                       [(VO, "if (start < previous_start)", "if (start < previous_start - 1)")]),
    "b-vo-end": ("vo: end > 2^32 - 1 (rule 10)", "v4",
                 [(VO, "if (end > std.math.maxInt(u32))", "if (end > std.math.maxInt(u32) + 1)")]),
    "b-vo-trailing": ("vo: at != len after the last table (rule 12)", "v4",
                      [(VO, "if (at != offsets.len) return error.OffsetsTrailingData;",
                        "if (at != offsets.len and at + 1 != offsets.len) return error.OffsetsTrailingData;")]),
    "b-ro-at": ("readOffsetsVarint: i >= len (rules 1, 4)", "v4",
                [(RO, "if (i >= bytes.len)", "if (i > bytes.len)")]),
    "b-ro-shift": ("readOffsetsVarint: shift > 28 (rules 1, 5)", "v4",
                   [(RO, "if (shift > 28)", "if (shift > 29)")]),
    "b-ro-max": ("readOffsetsVarint: value > 2^32 - 1 (rules 1, 5)", "v4",
                 [(RO, "if (value > std.math.maxInt(u32))", "if (value > std.math.maxInt(u32) + 1)")]),
    # checkPairsTable (v2: the tables the first publish drops)
    "b-ck-len": ("ck: len < at_start", "v2", [(CK, *SHORT_LEN)]),
    "b-ck-four": ("ck: len - at_start < 4", "v2", [(CK, *SHORT_FOUR)]),
    "b-ck-count-plus": ("ck: count != length, one more let through", "v2", [(CK, *COUNT_PLUS)]),
    "b-ck-count-minus": ("ck: count != length, one less let through", "v2", [(CK, *COUNT_MINUS)]),
    "b-ck-zero": ("ck: length == 0, as < 1", "v2", [(CK, *ZERO)]),
    "b-ck-end": ("ck: start + length > 2^32 - 1", "v2", [(CK, *END)]),
    "b-ck-leftover": ("ck: at != end", "v2", [(CK, *LEFT)]),
    # transcodePairsTable (v2: the tables the first publish carries)
    "b-tr-len": ("tr: len < at_start", "v2", [(TR, *SHORT_LEN)]),
    "b-tr-four": ("tr: len - at_start < 4", "v2", [(TR, *SHORT_FOUR)]),
    "b-tr-count-plus": ("tr: count != length, one more let through", "v2", [(TR, *COUNT_PLUS)]),
    "b-tr-count-minus": ("tr: count != length, one less let through", "v2", [(TR, *COUNT_MINUS)]),
    "b-tr-fast-room": ("tr: fast path, len - at >= 2", "v2",
                       [(TR, "if (bytes.len - at >= 2 and", "if (bytes.len - at >= 1 and")]),
    "b-tr-fast-delta": ("tr: fast path, delta byte < 0x80", "v2",
                        [(TR, "bytes[at] < 0x80 and", "bytes[at] < 0x81 and")]),
    "b-tr-fast-length": ("tr: fast path, length byte < 0x80", "v2",
                         [(TR, "bytes[at + 1] < 0x80)", "bytes[at + 1] < 0x81)")]),
    "b-tr-zero": ("tr: length == 0, as < 1", "v2", [(TR, *ZERO)]),
    "b-tr-end": ("tr: start + length > 2^32 - 1", "v2", [(TR, *END)]),
    "b-tr-gap": ("tr: zigzag gap > 2^32 - 1 (GapNotRepresentable)", "v2",
                 [(TR, "if (z > std.math.maxInt(u32))", "if (z > std.math.maxInt(u32) + 1)")]),
    "b-tr-gap-escape": ("tr: zigzag gap >= 15 escapes", "v2",
                        [(TR, "if (z >= offsets_escape)", "if (z > offsets_escape)")]),
    "b-tr-length-escape": ("tr: length >= 15 escapes", "v2",
                           [(TR, "if (length >= offsets_escape)", "if (length > offsets_escape)")]),
    "b-tr-leftover": ("tr: at != end", "v2", [(TR, *LEFT)]),
    # oneByteTableEnd and skipOneVarint (v4: the walk of a later update)
    "b-ob-remaining": ("ob: fast path, remaining >= 16", "v4",
                       [(OB, "if (remaining >= lanes and", "if (remaining >= lanes - 1 and")]),
    "b-ob-room": ("ob: fast path, len - at >= 16", "v4",
                  [(OB, "bytes.len - at >= lanes)", "bytes.len - at >= lanes - 1)")]),
    "b-ob-at": ("ob: at >= len before a token byte", "v4",
                [(OB, "if (at >= bytes.len) return null;", "if (at > bytes.len) return null;")]),
    "b-sv-at": ("skipOneVarint: at < len", "v4",
                [(SV, "while (at < bytes.len)", "while (at <= bytes.len)")]),
    "b-sv-end-byte": ("skipOneVarint: byte < 0x80 ends the varint", "v4",
                      [(SV, "if (byte < 0x80)", "if (byte < 0x81)")]),
    # readVarint (v2's tables, at the first publish and at v2's open)
    "b-rv-at": ("readVarint: at >= len", "v2",
                [(RV, "if (at >= bytes.len or shift > 28)", "if (at > bytes.len or shift > 28)")]),
    "b-rv-shift": ("readVarint: shift > 28", "v2",
                   [(RV, "if (at >= bytes.len or shift > 28)", "if (at >= bytes.len or shift > 29)")]),
    "b-rv-max": ("readVarint: value > 2^32 - 1", "v2",
                 [(RV, "if (value > std.math.maxInt(u32))", "if (value > std.math.maxInt(u32) + 1)")]),
    # source.varintsEnd (v2: the walk's tables)
    "b-ve-offset": ("varintsEnd: offset > len", "v2",
                    [(VE, "if (offset > bytes.len) return null;", "if (offset > bytes.len + 1) return null;")]),
    "b-ve-remaining": ("varintsEnd: fast path, remaining >= 16", "v2",
                       [(VE, "while (remaining >= lanes and", "while (remaining >= lanes - 1 and")]),
    "b-ve-room": ("varintsEnd: fast path, len - offset >= 16", "v2",
                  [(VE, "bytes.len - offset >= lanes)", "bytes.len - offset >= lanes - 1)")]),
    "b-ve-block-end": ("varintsEnd: fast path, byte < 0x80 is an end", "v2",
                       [(VE, "block < @as(Block, @splat(0x80))", "block < @as(Block, @splat(0x81))")]),
    "b-ve-at": ("varintsEnd: offset >= len", "v2",
                [(VE, "if (offset >= bytes.len) return null;", "if (offset > bytes.len) return null;")]),
    # apply.offsetTableStarts (the walk)
    "b-wk-four": ("walk: len - at < 4 (v2 count)", "v2",
                  [(WK, "if (offsets.len - at < 4)", "if (offsets.len - at < 3)")]),
    "b-wk-last-v2": ("walk: at != len after the last table, one byte let through", "v2",
                     [(WK, WK_LAST, "    if (at != offsets.len and !(at + 1 == offsets.len and sections.coding == .pairs)) return error.InvalidLexicalSection;")]),
    "b-wk-last-v4": ("walk: at != len after the last table, one byte let through", "v4",
                     [(WK, WK_LAST, "    if (at != offsets.len and !(at + 1 == offsets.len and sections.coding == .one_byte)) return error.InvalidLexicalSection;")]),
    # rule 11 at find: the span's end against the chunk's text, per coding at its caller
    "b-r11-v4": ("rule 11: end > codepoints, at find", "v4",
                 [(FS, "try postings.checkSpansWithinText(read, count);",
                   "try postings.checkSpansWithinText(read, if (context.index.positions.?.coding == .one_byte) count + 1 else count);")]),
    "b-r11-v2": ("rule 11: end > codepoints, at find", "v2",
                 [(FS, "try postings.checkSpansWithinText(read, count);",
                   "try postings.checkSpansWithinText(read, if (context.index.positions.?.coding == .pairs) count + 1 else count);")]),
    "b-r11": ("rule 11: end > codepoints, in checkSpansWithinText", "both",
              [(R11, "> codepoints)", "> codepoints + 1)")]),
}


def body_span(text, header):
    start = text.index(header)
    assert text.count(header) == 1, header
    end = text.index("\n}\n", start) + 3 if not header.startswith("    ") else text.index("\n    }\n", start) + 7
    return start, end


def plant(copy, name):
    src = copy / "zig" / "src"
    _, _, edits = P[name]
    for (file, header), old, new in edits:
        path = src / file
        text = path.read_text()
        start, end = body_span(text, header)
        body = text[start:end]
        assert body.count(old) == 1, (name, header, old, body.count(old))
        new_body = body.replace(old, new)
        assert new_body != body, name
        path.write_text(text[:start] + new_body + text[end:])
    print("planted", name)


if __name__ == "__main__":
    if sys.argv[1:] == ["--list"]:
        print("\n".join(P))
    else:
        plant(Path(sys.argv[1]), sys.argv[2])
