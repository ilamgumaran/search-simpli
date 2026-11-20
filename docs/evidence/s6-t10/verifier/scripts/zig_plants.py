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
# A probe, not a plant: the new test's five-span file with one non-ASCII letter in a word no query uses
# (`d\u{00E9}lta`: one codepoint, two bytes), so a span one codepoint past the text is still inside its bytes.
FIVE = '    .{ .name = "five.txt", .text = "alpha bravo charlie delta echo\\n" },\n'
PROBE = ("offsets_v4_test.zig", FIVE, FIVE.replace("delta", "d\\u{00E9}lta"))
P["probe-nonascii-head"] = [PROBE]
P["probe-nonascii-bytes"] = [PROBE] + P["x-r11-bytes"]
for f, old, new in P[name]:
    p = src / f
    s = p.read_text()
    assert s.count(old) == 1, (name, f, s.count(old))
    assert old != new, name
    p.write_text(s.replace(old, new))
print("planted", name)
