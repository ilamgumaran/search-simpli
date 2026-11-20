"""S6-T9 verifier: compare every same-answer pair (sajobs.PAIRS) on every corpus: abi (abcmp.py), find (line equality;
find_dump already normalises generation and cursors), surf (sfcmp.py). sacmp.py V > sa/compare.txt"""
import os, subprocess, sys
V = sys.argv[1]
sys.path.insert(0, f"{V}/tools")
from sajobs import PAIRS
bad = 0; n = 0; missing = 0
for c in ("j2", "family", "fixtures", "timing-10k", "prose-10k", "tamil-10k"):
    for b1, s1, b2, s2 in PAIRS:
        row = []
        for k in ("abi", "find", "surf"):
            a, b = f"{V}/sa/{k}/{c}/{s1}@{b1}.jsonl", f"{V}/sa/{k}/{c}/{s2}@{b2}.jsonl"
            if not (os.path.exists(a) and os.path.exists(b)):
                row.append(f"{k} MISSING"); missing += 1; continue
            n += 1
            if k == "find":
                la, lb = open(a).read().splitlines(), open(b).read().splitlines()
                d = sum(1 for x, y in zip(la, lb) if x != y) + abs(len(la) - len(lb))
                row.append(f"find {len(la)} calls differ {d}")
            else:
                tool = "abcmp.py" if k == "abi" else "sfcmp.py"
                out = subprocess.run([sys.executable, "-I", f"{V}/tools/sa/{tool}", a, b], capture_output=True, text=True).stdout.strip().splitlines()
                last = out[-1] if out else "no output"
                d = int(last.rsplit("differ", 1)[1].split()[0]) if "differ" in last else -1
                row.append(f"{k} " + last.split(" vs ")[-1].split(" ", 1)[-1])
            if d != 0:
                bad += 1
        print(f"{c:10s} {s1}@{b1} vs {s2}@{b2}: " + "; ".join(row))
print(f"\ncomparisons {n}, with a difference {bad}, missing {missing}")
