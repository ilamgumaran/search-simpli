"""The sweep table from the plant outputs: sites4.noindex (at c88e11f) and sites5.noindex (the reruns at 7ff9212).
sweep_table.py PLANTS_PY OUT_TXT OUT_MD"""
import importlib.util, re, sys
from pathlib import Path

S = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("pb", sys.argv[1])
pb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pb)


def result(d, n):
    p = S / d / "out" / f"{n}.txt"
    if not p.exists():
        return None
    t = p.read_text(errors="replace")
    run = [l.strip() for l in t.splitlines() if re.search(r"run test \d+ pass", l)]
    fails = sorted(set(re.findall(r"error: '(.+?)' failed:", t)))
    crashed = sorted(set(re.findall(r"error: '(.+?)' terminated with signal", t)))
    nd = sum(1 for l in (S / d / "diff" / f"{n}.diff").read_text().splitlines() if re.match(r"^[-+][^-+]", l))
    names = [f.split(".test.", 1)[-1] for f in fails] + [f.split(".test.", 1)[-1] + " (crash)" for f in crashed]
    return run[0].lstrip("+- ") if run else "NO RUN LINE", names, nd


txt, md = [], []
for name, (site, coding, _) in pb.P.items():
    before = result("sites4.noindex", name)
    after = result("sites5.noindex", name)
    txt.append(f"{name} | {site} | {coding}")
    for label, r in (("c88e11f", before), ("7ff9212", after)):
        if r is None:
            continue
        run, names, nd = r
        txt.append(f"  at {label}: diff {nd} lines | {run} | {len(names)} failed")
        for x in names:
            txt.append(f"    - {x}")
    def cell(r):
        if r is None:
            return "not rerun"
        return str(len(r[1])) + (" (crash)" if any(x.endswith("(crash)") for x in r[1]) and all(x.endswith("(crash)") for x in r[1]) else "")
    md.append(f"| `{name}` | {site} | {coding} | {cell(before)} | {cell(after)} |")
Path(sys.argv[2]).write_text("\n".join(txt) + "\n")
Path(sys.argv[3]).write_text("\n".join(md) + "\n")
print(len(md), "rows")
