"""S6-T10 verifier: my ruling-2 plants on 1e0a468, written from the code. Each anchor must occur once.
zig_plants.py COPY NAME (COPY is a fresh archive of the head). `v-r11-first-only` is applied by the S6-T8
verifier's own plants6.py, not here."""
import sys
from pathlib import Path

copy, name = Path(sys.argv[1]), sys.argv[2]
src = copy / "zig" / "src"
R11 = "    for (spans) |span| if (@as(usize, span.start) + span.length > codepoints) return error.OffsetsPastText;\n"
CALL = "            if (codepoints) |count| try postings.checkSpansWithinText(read, count);\n"
HIT = "        const token_spans = try context.spans(candidate.document_index, codepoints);\n"
P = {
    # rule 11 skipped only for the middle spans (the first and the last checked)
    "x-r11-skip-middle": [("postings.zig", R11,
        "    for (spans, 0..) |span, i| if ((i == 0 or i + 1 == spans.len) and @as(usize, span.start) + span.length > codepoints) return error.OffsetsPastText;\n")],
    # rule 11 compared with the chunk's byte length, not its codepoints
    "x-r11-bytes": [("find.zig", HIT, HIT.replace("candidate.document_index, codepoints)", "candidate.document_index, document.text.len)"))],
    # rule 11 applied only on a v2-coded (pairs) section 5
    "x-r11-v2-only": [("find.zig", CALL, CALL.replace("if (codepoints) |count| try", "if (codepoints) |count| if (context.index.positions.?.coding == .pairs) try"))],
    # an end exactly at the text's end refused, but only in a chunk of two or more spans
    # (the one-token `omega` control of the new test still answers)
    "x-r11-at-end-multi": [("postings.zig", R11,
        "    for (spans) |span| if (@as(usize, span.start) + span.length > codepoints or (spans.len > 1 and @as(usize, span.start) + span.length == codepoints)) return error.OffsetsPastText;\n")],
}
# Second check: two plants on rule 11 that only non-ASCII text can show. Each passes rule 11 a count other than
# codepoints, from a helper appended to find.zig; the snippet keeps the real count.
TAIL_ANCHOR = "    fn makeHit(context: *const Context, candidate: Candidate) Error!Hit {\n"
UTF16 = ("fn s6t10Utf16Units(text: []const u8) usize {\n"
         "    return std.unicode.calcUtf16LeLen(text) catch @import(\"analysis.zig\").codepointCount(text);\n}\n\n")
NOMARK = ("fn s6t10CodepointsWithoutMarks(text: []const u8) usize {\n"
          "    var count: usize = 0;\n"
          "    var it = (std.unicode.Utf8View.init(text) catch return @import(\"analysis.zig\").codepointCount(text)).iterator();\n"
          "    while (it.nextCodepoint()) |c| {\n"
          "        if ((c >= 0x0300 and c <= 0x036F) or (c >= 0x0BBE and c <= 0x0BCD)) continue;\n"
          "        count += 1;\n"
          "    }\n"
          "    return count;\n}\n\n")
def counted(helper, fn):
    return [("find.zig", HIT, HIT.replace("candidate.document_index, codepoints)", f"candidate.document_index, {fn}(document.text))")),
            ("find.zig", "const std = @import(\"std\");\n", "const std = @import(\"std\");\n" + helper)]
# rule 11 counts UTF-16 code units (a character outside the BMP counts 2)
P["z-r11-utf16"] = counted(UTF16, "s6t10Utf16Units")
# rule 11 skips combining marks (U+0300-U+036F and Tamil's vowel signs and virama, U+0BBE-U+0BCD)
P["z-r11-skip-marks"] = counted(NOMARK, "s6t10CodepointsWithoutMarks")
# A probe, not a plant: the v4 test's five-span file with a character outside the BMP after the last word
# (U+1F33F, one codepoint, two UTF-16 units, four bytes), so a span one codepoint past the text is still inside
# its UTF-16 length.
FIVE = '    .{ .name = "five.txt", .text = "\\u{00E9}lan bravo caf\\u{00E9} delta \\u{0BAA}\\u{0BB3}\\u{0BCD}\\u{0BB3}\\u{0BBF}\\n" },\n'
PROBE = ("offsets_v4_test.zig", FIVE, FIVE.replace("\\u{0BBF}\\n", "\\u{0BBF} \\u{1F33F}\\n"))
P["probe-astral-head"] = [PROBE]
P["probe-astral-utf16"] = [PROBE] + P["z-r11-utf16"]
for f, old, new in P[name]:
    p = src / f
    s = p.read_text()
    assert s.count(old) == 1, (name, f, s.count(old))
    assert old != new, name
    p.write_text(s.replace(old, new))
print("planted", name)
