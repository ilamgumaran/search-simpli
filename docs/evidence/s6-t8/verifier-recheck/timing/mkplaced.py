"""S6-T8 verifier (recheck): a PLACED control: main's tree plus one never-run function of NBLOCKS inert loops, put
where this task's writer code sits: in postings.zig right after `PositionSections` (the head puts `OffsetsCoding`,
`zigzag`, `appendOneByteToken`, `appendOffsetsTable`, `oneByteTableEnd`, `checkPairsTable` and `transcodePairsTable`
there), called from apply.mergeCarried's section-5 merge (where the head calls `transcodePairsTable`) under a branch
that is never true at run time (a section of 2^50 bytes or more). Written by the verifier; not the builder's script.
  mkplaced.py SRC_ZIG_DIR NBLOCKS
"""
import sys
from pathlib import Path

src, n = Path(sys.argv[1]), int(sys.argv[2])


def block(i):
    a, step, mul, sh, c, m2 = 1 + i % 5, 1 + i % 3, 2654435761 + 2 * i, i % 7, (i * 37) % 251, 3 + 2 * i
    return f"""    {{
        var acc{i}: u64 = {1000 + i};
        var j{i}: usize = at_start;
        while (j{i} + {a} < bytes.len) : (j{i} += {step}) {{
            acc{i} = (acc{i} *% {mul}) ^ ((@as(u64, bytes[j{i}]) << {sh}) +% bytes[j{i} + {a}]);
            if (bytes[j{i}] == {c}) acc{i} +%= @as(u64, j{i}) *% {m2};
        }}
        if (acc{i} == {7000003 + i}) return @intCast(acc{i} % (bytes.len + 1));
        total +%= @intCast(acc{i} & 0xff);
    }}
"""


p = src / "src" / "postings.zig"
s = p.read_text()
anchor = "pub const PositionSections = struct {\n    positions: []const u8,\n    offsets: []const u8,\n};\n"
assert s.count(anchor) == 1, "postings anchor"
fn = ("\n/// verifier placement control (S6-T8 recheck): never called at run time.\n"
      "pub fn verifierPlacedControl(bytes: []const u8, at_start: usize) usize {\n    var total: usize = at_start;\n"
      + "".join(block(i) for i in range(n)) + "    return total;\n}\n")
p.write_text(s.replace(anchor, anchor + fn))

a = src / "src" / "apply.zig"
t = a.read_text()
anchor2 = "    const old_starts = try offsetTableStarts(scratch, sections.offsets, previous.document_lengths);\n    defer scratch.free(old_starts);\n"
assert t.count(anchor2) == 1, "apply anchor"
call = ("    // verifier placement control (S6-T8 recheck): never true at run time\n"
        "    if (sections.offsets.len >= (@as(usize, 1) << 50) and postings.verifierPlacedControl(sections.offsets, old_starts.len) == 7) return error.InvalidLexicalSection;\n")
a.write_text(t.replace(anchor2, anchor2 + call))
print(f"placed {n} blocks after PositionSections in {p}, called from apply.mergeCarried (d)")
