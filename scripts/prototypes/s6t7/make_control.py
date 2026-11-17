#!/usr/bin/env python3
"""S6-T7 Phase 2: a placement control, `main` plus code that never runs
(S6-T4's and S6-T5's controls, re-made for `main` at ad71cfb, whose
`postings.lookupExact` moved).

    python3 -I make_control.py POSTINGS_ZIG BLOCKS

Inserts after `pub fn lookupExact(...) ?usize {` a branch on
`term.len >= 2^50` (never true) holding BLOCKS inert scans of the
dictionary, each a different constant so none is merged with another. The
file is rewritten in place; it must be a copy, never the repository's. Not
part of any library.
"""
import sys

path, blocks = sys.argv[1], int(sys.argv[2])
text = open(path, encoding="utf-8").read()
anchor = "pub fn lookupExact(index: Index, term: []const u8) ?usize {\n"
assert text.count(anchor) == 1, "anchor not found once"
body = ["    // S6-T7 placement control: never true at run time\n",
        "    if (term.len >= (@as(usize, 1) << 50)) {\n"]
for i in range(blocks):
    a, b, c = i % 3, (i + 1) % 3, 2 + i % 7
    body.append(f"""        {{
            var acc{i}: usize = {7 + i};
            for (index.terms, 0..) |entry, i| {{
                if (entry.term.len > {1 + i % 5} and entry.term[{a % 2}] == term[{b}] +% {1 + i % 250}) acc{i} +%= i *% {3 + 2 * i};
                if (std.mem.eql(u8, entry.term[0..@min(entry.term.len, {c})], term[0..@min(term.len, {c})])) acc{i} ^= i;
            }}
            if (acc{i} == {1000003 + i}) return acc{i} % (index.terms.len + 1);
        }}
""")
body.append("        return null;\n    }\n")
open(path, "w", encoding="utf-8").write(text.replace(anchor, anchor + "".join(body)))
print(f"{path}: {blocks} inert blocks")
