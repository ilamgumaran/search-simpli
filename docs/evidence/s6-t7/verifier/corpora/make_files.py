"""S6-T7 verifier: pick the smallest (with a line), median and largest file of each corpus by bytes."""
import json, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "dec"))
import v5dec
V = Path(sys.argv[1])
F = V / "src.noindex/head/fixtures"
sets = {"timing-10k": ("r-legacy", V / "corpora.noindex/timing-10k"), "prose-10k": ("r-legacy", V / "corpora.noindex/prose-10k"),
        "tamil-10k": ("r-legacy", V / "corpora.noindex/tamil-10k"), "fixtures": ("r-legacy", F), "family": ("r-legacy", F / "family-folder")}
for c, (root, base) in list(sets.items()) + [("j2", (None, None))]:
    if c == "j2":
        items = [(r, p.relative_to(F / "j2" / r).as_posix(), p) for r in ("school", "home", "laptop") for p in (F / "j2" / r).rglob("*") if p.is_file()]
    else:
        items = [(root, p.relative_to(base).as_posix(), p) for p in base.rglob("*") if p.is_file()]
    rows = []
    for r, rel, p in items:
        b = p.read_bytes()
        n = len(v5dec.line_starts(b)) - 1
        if n >= 1:
            rows.append((len(b), r, rel, n))
    rows.sort()
    pick = {"small": rows[0], "median": rows[len(rows) // 2], "largest": rows[-1]}
    out = {"corpus": c, "files": {k: [v[1], v[2], v[3]] for k, v in pick.items()}, "bytes": {k: v[0] for k, v in pick.items()}}
    (V / "tim/files" / (c + ".json")).write_text(json.dumps(out))
    print(c, out["bytes"], {k: v[2] for k, v in out["files"].items()})
