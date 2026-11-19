"""S6-T8 verifier: one line per plant from plants2/out/*.txt (recheck): exit, test counts, the failing tests' names."""
import re, sys
from pathlib import Path
out = Path(__file__).resolve().parent.parent / "plants2" / "out"
for f in sorted(out.glob("*.txt")):
    t = f.read_text(errors="replace")
    summ = [l for l in t.splitlines() if l.startswith("Build Summary")]
    names = sorted(set(m[0] + (" (crashed)" if m[1] == "terminated" else "") for m in re.findall(r"^error: '(.*)' (failed|terminated)", t, re.M)))
    crashes = len(re.findall(r"(panic|Segmentation fault|terminated with signal|crashed)", t))
    d = out.parent / "diff" / (f.stem + ".diff")
    nd = sum(1 for l in d.read_text(errors="replace").splitlines() if l[:1] in "+-" and l[:3] not in ("+++", "---")) if d.exists() else "?"
    comp = re.findall(r"^src/\S+: error: .*$", t, re.M)
    print(f"{f.stem}: changed lines {nd}; {summ[-1] if summ else 'no summary'}; crash markers {crashes}")
    for c in comp[:2]:
        print(f"    compile error: {c}")
    for n in names:
        print(f"    failed: {n}")
