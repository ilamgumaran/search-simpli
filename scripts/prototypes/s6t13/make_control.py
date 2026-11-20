"""S6-T13 builder: a placement control = main's tree plus one never-run function of NBLOCKS inert loops, called
under a branch never true at run time (an input of 2^50 bytes or more). After the S6-T9 verifier's mkctl.py.
  python3 -I make_control.py SRC_ZIG_DIR PLACE NBLOCKS [EXTRA]
EXTRA (default 0): that many one-line steps after the blocks, to bring the control's __text delta near the task's.
PLACE:
  l  snapshot_open.zig, before loadEngine; called in loadEngine right after the MANIFEST buffer is allocated
     (beside the code this task changed: every open)
  m  manifest.zig, before decodeV2; called from decodeV2 (every open, away from the change)
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


fn = ("/// S6-T13 placement control: never called at run time.\n"
      "pub fn placementControl(bytes: []const u8, at_start: usize) usize {\n    var total: usize = at_start;\n"
      + "".join(block(i) for i in range(n))
      + "".join(f"    if (bytes[at_start % bytes.len] == {11 + e}) total +%= {104729 * (e + 1)};\n" for e in range(extra))
      + "    return total;\n}\n\n")
never = "(@as(usize, 1) << 50)"
spots = {
    "l": ("snapshot_open.zig", "fn loadEngine(allocators: Allocators, io: std.Io, from: From, options: engine.Engine.OpenOptions) !Loaded {\n",
          "    const manifest_read = try blocks.alloc(u8, manifest_size);\n",
          f"    if (manifest_size >= {never} and placementControl(manifest_read, 0) == 7) return error.IndexTooLarge;\n"),
    "m": ("manifest.zig", "fn decodeV2(encoded: []const u8) ManifestError!Manifest {\n",
          "fn decodeV2(encoded: []const u8) ManifestError!Manifest {\n",
          f"    if (encoded.len >= {never} and placementControl(encoded, 0) == 7) return error.UnsupportedVersion;\n"),
}
name, host, after, call = spots[place]
p = src / "src" / name
s = p.read_text()
assert s.count(host) == 1 and s.count(after) == 1, f"anchors in {name}"
# the function goes before the host's doc comment block
i = s.index(host)
lines_before = s[:i].split("\n")
k = len(lines_before) - 1
while k > 0 and lines_before[k - 1].lstrip().startswith("///"):
    k -= 1
insert_at = len("\n".join(lines_before[:k])) + (1 if k > 0 else 0)
s = s[:insert_at] + fn + s[insert_at:]
s = s.replace(after, after + call)
p.write_text(s)
print(f"control {place}: {n} blocks in {name}")
