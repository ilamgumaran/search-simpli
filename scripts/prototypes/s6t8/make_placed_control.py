#!/usr/bin/env python3
"""S6-T8 (rulings on the Report, item 2): a placement control placed where
this task's new code sits: `main` plus a new function in postings.zig right
after `PositionSections` (where the branch's section-5 coding functions
are), holding BLOCKS inert scans of the dictionary (S6-T7's
make_control.py blocks), called from `apply.mergeCarried` (where the
branch's writer calls them) under a branch that is never true.

    python3 -I make_placed_control.py ZIG_SRC_DIR BLOCKS

Rewrites ZIG_SRC_DIR/postings.zig and ZIG_SRC_DIR/apply.zig in place; the
directory must be a copy, never the repository's. Not part of any library.
"""
import sys
from pathlib import Path

src, blocks = Path(sys.argv[1]), int(sys.argv[2])
postings = src / "postings.zig"
text = postings.read_text(encoding="utf-8")
anchor = "pub const PositionSections = struct {\n    positions: []const u8,\n    offsets: []const u8,\n};\n"
assert text.count(anchor) == 1, "postings anchor not found once"
body = ["\n/// S6-T8 placement control: called only under a branch that is never true.\n",
        "pub fn placementControl(index: Index, term: []const u8) ?usize {\n"]
for i in range(blocks):
    a, b, c = i % 3, (i + 1) % 3, 2 + i % 7
    body.append(f"""    {{
        var acc{i}: usize = {7 + i};
        for (index.terms, 0..) |entry, i| {{
            if (entry.term.len > {1 + i % 5} and entry.term[{a % 2}] == term[{b}] +% {1 + i % 250}) acc{i} +%= i *% {3 + 2 * i};
            if (std.mem.eql(u8, entry.term[0..@min(entry.term.len, {c})], term[0..@min(term.len, {c})])) acc{i} ^= i;
        }}
        if (acc{i} == {1000003 + i}) return acc{i} % (index.terms.len + 1);
    }}
""")
body.append("    return null;\n}\n")
postings.write_text(text.replace(anchor, anchor + "".join(body)), encoding="utf-8")

apply = src / "apply.zig"
text = apply.read_text(encoding="utf-8")
anchor = "    // (d) Section 5: each document's table, previous or fresh.\n"
assert text.count(anchor) == 1, "apply anchor not found once"
call = ("    // S6-T8 placement control: never true at run time.\n"
        "    if (previous.document_lengths.len >= (@as(usize, 1) << 50)) {\n"
        "        if (postings.placementControl(previous, previous.terms[0].term)) |v| if (v == 12345) return error.InvalidLexicalSection;\n"
        "    }\n")
apply.write_text(text.replace(anchor, call + anchor), encoding="utf-8")
print(f"{src}: placementControl with {blocks} inert blocks, called from mergeCarried")
