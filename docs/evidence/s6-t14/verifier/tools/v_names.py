#!/usr/bin/env python3
"""Run test binaries directly (cwd = an archive's zig/) and list each test's name.
Usage: v_names.py OUT ZIGDIR BIN [BIN ...]
Writes OUT: one line per test, "name<TAB>status" (status from the same line,
or the next status word seen before the next test), sorted; and the runner's tail."""
import re
import subprocess
import sys

out, zigdir, *bins = sys.argv[1:]
START = re.compile(r"^(\d+)/(\d+) (.+?)\.\.\.(.*)$")
rows, tails = [], []
for b in bins:
    p = subprocess.run([b], cwd=zigdir, capture_output=True, text=True, errors="replace")
    text = p.stdout + p.stderr
    pending = None
    total = None
    for line in text.split("\n"):
        m = START.match(line)
        if m:
            if pending:
                rows.append(pending)
            total = int(m.group(2))
            rest = m.group(4).strip()
            status = rest if rest in ("OK", "SKIP") or rest.startswith("FAIL") else "?"
            pending = [m.group(3), status]
            if status != "?":
                rows.append(pending)
                pending = None
        elif pending and line.strip() in ("OK", "SKIP"):
            pending[1] = line.strip()
            rows.append(pending)
            pending = None
        elif pending and line.strip().endswith("OK") and line.strip() != "":
            # test output ending the line, then OK on it
            pending[1] = "OK"
            rows.append(pending)
            pending = None
    if pending:
        rows.append(pending)
    summary = [l for l in text.split("\n") if re.search(r"tests? passed|skipped|failed", l) and not START.match(l)]
    tails.append(f"{b}: exit {p.returncode}; runner total {total}; {summary[-1:] }")
rows.sort()
with open(out, "w") as f:
    for name, status in rows:
        f.write(f"{name}\t{status}\n")
print(f"{out}: {len(rows)} tests; " + "; ".join(f"{s}={sum(1 for r in rows if r[1]==s)}" for s in sorted({r[1] for r in rows})))
for t in tails:
    print("  ", t)
