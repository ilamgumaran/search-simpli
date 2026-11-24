#!/usr/bin/env python3
"""S6-T24 verifier probe (Verdict 2): what a first `scan` page over a 10k-file index costs before its budget
can stop it, against `find` on the same index (both open the index; `scan` also loads the source section's line
map once, which the Report states as the index's own). Every CLI call is a first page. Three runs each, the
wall-clock milliseconds (process start included) and, from `/usr/bin/time -l`, the peak memory footprint.

Usage: python3 -I probe_index_first_page.py SEARCHD INDEX...
"""
import re
import subprocess
import sys
import time

searchd = sys.argv[1]
for index in sys.argv[2:]:
    name = index.rstrip("/").split("/")[-1]
    for label, argv in (("scan zzz --time-ms 1", ["scan", index, "zzz", "--json", "--time-ms", "1"]),
                        ("scan tide --time-ms 1", ["scan", index, "tide", "--json", "--time-ms", "1"]),
                        ("find zzz", ["find", index, "zzz", "--json"])):
        rows = []
        for _ in range(3):
            start = time.monotonic()
            done = subprocess.run(["/usr/bin/time", "-l", searchd, *argv], capture_output=True, timeout=300)
            ms = (time.monotonic() - start) * 1000
            peak = re.search(rb"(\d+)\s+peak memory footprint", done.stderr)
            rows.append(f"{ms:.0f} ms / {int(peak.group(1)):,} B" if peak else f"{ms:.0f} ms")
            stopped = re.search(rb'"stopped":"(\w+)"', done.stdout)
        print(f"{name}: {label}: exit {done.returncode}, {'stopped ' + stopped.group(1).decode() if stopped else ''}; " + "; ".join(rows))
