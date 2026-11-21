"""S6-T18 verifier: a placement control for `searchd query` timing = main's tree plus one never-run function,
called under a branch never true at run time (top_k of 2^50 or more). Written by the verifier, after the
builder's make_control.py; not part of any build.
  python3 -I vcontrol.py SRC_ZIG_DIR PLACE NSTEPS
PLACE:
  r  interfaces/cli.zig: the function before runSearch's doc block, called at the top of runSearch
     (where the head's change is removed)
  e  core/engine.zig: the function after the Engine struct, where the head's queryOneShot sits, called at the
     top of Engine.queryTokenized (every one-shot query reaches it)
"""
import sys
from pathlib import Path

src, place, n = Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])
fn = ("/// S6-T18 verifier placement control: never called at run time.\n"
      "fn placementControl(bytes: []const u8, at_start: usize) usize {\n    var total: usize = at_start;\n"
      + "".join(f"    if (bytes[at_start % bytes.len] == {11 + e}) total +%= bytes.len *% {104729 * (e + 1)};\n" for e in range(n))
      + "    return total;\n}\n\n")
never = "(@as(usize, 1) << 50)"
if place == "r":
    p = src / "src/interfaces/cli.zig"
    s = p.read_text()
    host = "fn runSearch(\n"
    first = "    const result_output = try allocator.alloc(hybrid.Result, engine.documents.len);\n"
    assert s.count(host) == 1 and s.count(first) == 1
    s = s.replace(first, f"    if (top_k >= {never} and placementControl(query_text, 0) == 7) return error.IndexTooLarge;\n" + first)
    s = s.replace(host, fn + host)
elif place == "e":
    p = src / "src/core/engine.zig"
    s = p.read_text()
    body = "    ) ![]hybrid.Result {\n        return engine.queryTraced(allocator, query_text, query_vector, result_output, options, null);\n"
    anchor = 'test "published snapshot opens and returns cited hybrid evidence" {\n'
    assert s.count(body) == 1 and s.count(anchor) == 1
    s = s.replace(body, "    ) ![]hybrid.Result {\n"
                  f"        if (options.top_k >= {never} and placementControl(query_text, 0) == 7) return error.IndexTooLarge;\n"
                  "        return engine.queryTraced(allocator, query_text, query_vector, result_output, options, null);\n")
    s = s.replace(anchor, fn + anchor)
else:
    raise SystemExit("place r or e")
p.write_text(s)
print(f"control {place}: {n} steps in {p.relative_to(src)}")
