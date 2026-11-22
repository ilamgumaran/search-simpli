"""S6-T20 builder: S6-T13's make_control.py (scripts/prototypes/s6t13/), with one more place, i. A placement control = main's tree plus one never-run function of NBLOCKS inert loops, called
under a branch never true at run time (an input of 2^50 bytes or more). After the S6-T9 verifier's mkctl.py.
  python3 -I make_control.py SRC_ZIG_DIR PLACE NBLOCKS [EXTRA]
EXTRA (default 0): that many one-line steps after the blocks, to bring the control's __text delta near the task's.
PLACE:
  l  snapshot_open.zig, before loadEngine; called in loadEngine right after the MANIFEST is read
     (beside the code this task changed: every open)
  m  manifest.zig, before decodeV2; called from decodeV2 (every open, away from the change)
  i  indexer.zig, before indexFolder; called in walkAndApply (both rebuilds) right after the walk (beside S6-T20's change, the
     full rebuild; never on an open, a query or a find)
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


fn = ("/// S6-T20 placement control (after S6-T13's): never called at run time.\n"
      "pub fn placementControl(bytes: []const u8, at_start: usize) usize {\n    var total: usize = at_start;\n"
      + "".join(block(i) for i in range(n))
      + "".join(f"    if (bytes[at_start % bytes.len] == {11 + e}) total +%= {104729 * (e + 1)};\n" for e in range(extra))
      + "    return total;\n}\n\n")
never = "(@as(usize, 1) << 50)"
spots = {
    "l": ("snapshot_open.zig", "fn loadEngine(allocators: Allocators, io: std.Io, from: From, options: engine.Engine.OpenOptions) !Loaded {\n",
          "    const manifest_first = manifest_read.bytes;\n",  # S6-T13 read through readManifest since then
          f"    if (manifest_first.len >= {never} and placementControl(manifest_first, 0) == 7) return error.IndexTooLarge;\n"),
    "m": ("manifest.zig", "fn decodeV2(encoded: []const u8) ManifestError!Manifest {\n",
          "fn decodeV2(encoded: []const u8) ManifestError!Manifest {\n",
          f"    if (encoded.len >= {never} and placementControl(encoded, 0) == 7) return error.UnsupportedVersion;\n"),
    "i": ("indexer.zig", "pub fn indexFolder(\n",
          "    generation: ?u64,\n) !IncrementalReport {\n    const walked = try walkBatch(allocator, io, root, caps);\n",
          f"    if (caps.max_total_bytes >= {never} and placementControl(std.mem.asBytes(&caps), 0) == 7) return error.OutOfMemory;\n"),
}
name, host, after, call = spots[place]
p = src / "src" / "core" / name  # S6-T14 moved the core files into zig/src/core/
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
