"""S6-T9 ruling 7: each plant's engine test line and the tests it failed, from run_plant.sh's outputs.

    python3 -I plant_results.py SITES_DIR [NAME...]     (no NAME: every plant of plants_sites.py, in its order)

Per plant: its description, the lines its diff changed, the engine step's `run test` line, the number of tests that
failed or crashed, and their names (the part after `.test.`, cut to 110 characters, at most eight). Not part of any
library.
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from plants_sites import P  # noqa: E402

d = Path(sys.argv[1])
names = sys.argv[2:] or list(P)
for n in names:
    out = d / "out" / f"{n}.txt"
    desc = P[n][0] if n in P else "the archive as it is"
    if not out.exists():
        print(f"{n} | {desc} | NOT RUN")
        continue
    t = out.read_text(errors="replace")
    diff = d / "diff" / f"{n}.diff"
    changed = sum(1 for l in diff.read_text().splitlines() if re.match(r"^[-+][^-+]", l)) if diff.exists() else 0
    runs = [l.strip().lstrip("+- ") for l in t.splitlines() if re.search(r"run test \d+ pass", l)]
    engine = max(runs, key=lambda l: int(re.search(r"\((\d+) total\)", l).group(1))) if runs else "NO RUN LINE"
    fails = sorted(set(re.findall(r"error: '(.+?)' failed:", t)))
    crashed = sorted(set(re.findall(r"error: '(.+?)' terminated with signal", t)))
    crash = " crash" if crashed or "panic:" in t else ""
    print(f"{n} | {desc} | diff {changed} lines | {engine} | failed {len(fails) + len(crashed)}{crash}")
    shown = [f for f in fails] + [f"(crash) {f}" for f in crashed]
    for f in shown[:8]:
        print("    -", f.split(".test.", 1)[-1][:110])
    if len(shown) > 8:
        print(f"    ... and {len(shown) - 8} more")
