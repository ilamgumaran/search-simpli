"""Prepare the build cases: each a fresh copy of the pristine archive with one case's edits."""
import shutil, sys
from pathlib import Path
sys.argv = [sys.argv[0], sys.argv[1], sys.argv[2], "extra"]
import importlib.util
here = Path(__file__).resolve().parent
src = (here / "static_cases.py").read_text()
# reuse the case tables and apply() without running the loop
head = src.split("rows = []")[0]
ns = {"__file__": str(here / "static_cases.py")}
exec(head.replace("] if len(sys.argv) > 3 else CASES", "]"), ns)  # extra list
extra = {c[0]: c for c in ns["CASES"]}
exec(head.replace("] if len(sys.argv) > 3 else CASES", "] if False else CASES"), ns)  # base list
base = {c[0]: c for c in ns["CASES"]}
allc = {**base, **extra}
PRISTINE, WORK = Path(sys.argv[1]), Path(sys.argv[2])
want = {"B1": ["S13"], "B2": ["S14"], "B3": ["S15"], "B4": ["S16"], "B5": ["S17"], "B6": ["S20"],
        "B7": ["A04", "S13"], "B8": ["P01"]}
for bid, ids in want.items():
    dst = WORK / bid
    assert not dst.exists()
    shutil.copytree(PRISTINE, dst, symlinks=True)
    for cid in ids:
        ns["apply"](dst, allc[cid][3])
    print(bid, ids, "prepared")
