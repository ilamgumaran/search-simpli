#!/usr/bin/env python3
"""S6-T9 (ruling 5): a placement control placed where this task's new code
on a reader's path sits: `main` plus a new function in filename_field.zig
right before `decodeInspected` (the catalog decode, where record v6's ids
and stems are derived at the first file-name query), holding BLOCKS inert
scans of the body dictionary (S6-T7's make_control.py blocks), called at
the top of `decodeInspected` under a branch that is never true.

    python3 -I make_placed_control.py ZIG_SRC_DIR BLOCKS

Rewrites ZIG_SRC_DIR/filename_field.zig in place; the directory must be a
copy, never the repository's. Not part of any library.
"""
import sys
from pathlib import Path

src, blocks = Path(sys.argv[1]), int(sys.argv[2])
path = src / "filename_field.zig"
text = path.read_text(encoding="utf-8")
anchor = ("fn decodeInspected(allocator: std.mem.Allocator, body_docs: []const hybrid.Document, body_index: postings.Index, "
          "catalog_encoded: []const u8, ch: segment.Header, lexical_encoded: []const u8, lh: lexical_segment.Header) !Decoded {\n")
assert text.count(anchor) == 1, "filename_field anchor not found once"
body = ["/// S6-T9 placement control: called only under a branch that is never true.\n",
        "fn placementControl(index: postings.Index, term: []const u8) ?usize {\n"]
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
body.append("    return null;\n}\n\n")
call = ("    // S6-T9 placement control: never true at run time.\n"
        "    if (body_docs.len >= (@as(usize, 1) << 50)) {\n"
        "        if (placementControl(body_index, body_index.terms[0].term)) |v| if (v == 12345) return error.FilenameCatalogMismatch;\n"
        "    }\n")
path.write_text(text.replace(anchor, "".join(body) + anchor + call), encoding="utf-8")
print(f"{src}: placementControl with {blocks} inert blocks, called from decodeInspected")
