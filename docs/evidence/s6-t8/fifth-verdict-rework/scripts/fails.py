"""Print each plant's suite line and its failed tests (short names). fails.py DIR NAME..."""
import re, sys
from pathlib import Path
d = Path(sys.argv[1])
for n in sys.argv[2:]:
    t = (d / "out" / f"{n}.txt").read_text(errors="replace")
    run = [l.strip() for l in t.splitlines() if re.search(r"run test \d+ pass", l)]
    fails = sorted(set(re.findall(r"error: '(.+?)' failed:", t)))
    crashed = sorted(set(re.findall(r"error: '(.+?)' terminated with signal", t)))
    crash = "panic" in t or "terminated with signal" in t or "crashed" in t
    print(f"{n} | {run[0] if run else 'NO RUN LINE'} | failed {len(fails)}{' crash' if crash else ''}")
    names = [("", f) for f in fails] + [("(crash) ", f) for f in crashed]
    for tag, f in names[:6]: print("   -", tag + f.split(".test.", 1)[-1][:110])
    if len(names) > 6: print(f"   ... and {len(names) - 6} more")
