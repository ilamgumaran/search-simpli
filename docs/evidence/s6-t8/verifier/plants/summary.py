"""S6-T8 verifier: one line per plant from plants/out/*.txt: exit, test counts, the failing tests' names."""
import re, sys
from pathlib import Path
out = Path(__file__).resolve().parent / "out"
for f in sorted(out.glob("*.txt")):
    t = f.read_text(errors="replace")
    summ = [l for l in t.splitlines() if l.startswith("Build Summary")]
    names = sorted(set(re.findall(r"^error: '([^']*)' failed", t, re.M)))
    comp = re.findall(r"^src/\S+: error: .*$", t, re.M)
    print(f"{f.stem}: {summ[-1] if summ else 'no summary'}")
    for c in comp[:2]:
        print(f"    compile error: {c}")
    for n in names:
        print(f"    failed: {n}")
