"""S6-T18 builder: a placement control for `searchd query` timing = main's tree plus one never-run function,
called under a branch never true at run time (a top_k or a chunk count of 2^50 or more). After S6-T13's
make_control.py (scripts/prototypes/s6t13/).
  python3 -I make_control.py SRC_ZIG_DIR PLACE NBLOCKS [EXTRA]
NBLOCKS inert loops, then EXTRA one-line steps, to bring the control's __text delta (searchd ReleaseSmall) near the
task's. PLACE:
  r  interfaces/cli.zig, before runSearch; called at the top of runSearch (beside the code this task moves:
     every `query` and `evidence` under content)
  d  core/title_field.zig, before derive; called at the top of derive (every one-shot query, in the core, away
     from the moved lines)
Not part of any build; the copy it edits is a scratch archive of main.
"""
import sys
from pathlib import Path

src, place, n = Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])
extra = int(sys.argv[4]) if len(sys.argv) > 4 else 0


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


fn = ("/// S6-T18 placement control: never called at run time.\n"
      "fn placementControl(bytes: []const u8, at_start: usize) usize {\n    var total: usize = at_start;\n"
      + "".join(block(i) for i in range(n))
      + "".join(f"    if (bytes[at_start % bytes.len] == {11 + e}) total +%= bytes.len *% {104729 * (e + 1)};\n" for e in range(extra))
      + "    return total;\n}\n\n")
never = "(@as(usize, 1) << 50)"
spots = {
    "r": ("interfaces/cli.zig", "fn runSearch(\n",
          "    const result_output = try allocator.alloc(hybrid.Result, engine.documents.len);\n",
          f"    if (top_k >= {never} and placementControl(query_text, 0) == 7) return error.IndexTooLarge;\n",
          True),
    "d": ("core/title_field.zig",
          "pub fn derive(blocks: std.mem.Allocator, scratch_backing: std.mem.Allocator, documents: []const hybrid.Document, roots: []const manifest.RootEntry) !Derived {\n",
          "pub fn derive(blocks: std.mem.Allocator, scratch_backing: std.mem.Allocator, documents: []const hybrid.Document, roots: []const manifest.RootEntry) !Derived {\n",
          f"    if (documents.len >= {never} and placementControl(documents[0].text, 0) == 7) return error.IndexTooLarge;\n",
          False),
}
name, host, after, call, before_call = spots[place]
p = src / "src" / name
s = p.read_text()
assert s.count(host) == 1 and s.count(after) == 1, f"anchors in {name}"
if before_call:
    s = s.replace(after, call + after)
else:
    s = s.replace(after, after + call)
# the function goes before the host's doc comment block
i = s.index(host)
lines_before = s[:i].split("\n")
k = len(lines_before) - 1
while k > 0 and lines_before[k - 1].lstrip().startswith("///"):
    k -= 1
insert_at = len("\n".join(lines_before[:k])) + (1 if k > 0 else 0)
s = s[:insert_at] + fn + s[insert_at:]
p.write_text(s)
print(f"control {place}: {n} blocks, {extra} steps in {name}")
