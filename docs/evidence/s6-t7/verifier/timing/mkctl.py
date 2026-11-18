"""S6-T7 verifier: write a placement control into a copy of main's tree: NBLOCKS distinct never-run
loops behind a branch that is never taken at run time (a length >= 2^50).
  mkctl.py SRC_ZIG_DIR query NBLOCKS   -> postings.lookupExact (the query path)
  mkctl.py SRC_ZIG_DIR open NBLOCKS    -> segment.decodeInspected (the open path)
"""
import sys
from pathlib import Path

src, kind, n = Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])


def block(i, var, nbytes_expr, byte_expr, ret):
    a, step, mul, sh, c, m2 = 1 + i % 5, 1 + i % 3, 2654435761 + 2 * i, i % 7, (i * 37) % 251, 3 + 2 * i
    return f"""        {{
            var acc{i}: u64 = {1000 + i};
            var j{i}: usize = 0;
            while (j{i} + {a} < {nbytes_expr}) : (j{i} += {step}) {{
                acc{i} = (acc{i} *% {mul}) ^ ((@as(u64, {byte_expr(f"j{i}")}) << {sh}) +% {byte_expr(f"j{i} + {a}")});
                if ({byte_expr(f"j{i}")} == {c}) acc{i} +%= @as(u64, j{i}) *% {m2};
            }}
            if (acc{i} == {7000003 + i}) {ret};
        }}
"""


if kind == "query":
    f = src / "src" / "postings.zig"
    anchor = "pub fn lookupExact(index: Index, term: []const u8) ?usize {\n"
    guard = "    // verifier placement control (S6-T7): never true at run time\n    if (term.len >= (@as(usize, 1) << 50)) {\n"
    body = "".join(block(i, "term", "term.len", lambda e: f"term[{e}]", "return @intCast(acc%d %% (index.terms.len + 1))" % i) for i in range(n))
else:
    f = src / "src" / "segment.zig"
    anchor = ") DecodeError![]hybrid.Document {\n    if (document_output.len < header.document_count) return error.DocumentCapacityTooSmall;\n"
    guard = "    // verifier placement control (S6-T7): never true at run time\n    if (encoded.len >= (@as(usize, 1) << 50)) {\n"
    body = "".join(block(i, "encoded", "encoded.len", lambda e: f"encoded[{e}]", "return error.DocumentCapacityTooSmall") for i in range(n))
text = f.read_text()
assert text.count(anchor) == 1, (f, text.count(anchor))
text = text.replace(anchor, anchor + guard + body + "    }\n")
f.write_text(text)
print("wrote", kind, n, "blocks into", f)
