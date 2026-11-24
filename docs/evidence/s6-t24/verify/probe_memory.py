#!/usr/bin/env python3
"""S6-T24 verifier probe: peak memory of one `scan` page over a 10 MiB file, by line shape.

`scan` holds one file's bytes and its line starts (`source.lineStarts`, one u64 per line) at a time. A 10 MiB file
of ordinary lines and a 10 MiB file of nothing but line breaks (10,485,759 lines) are each scanned over the
folder and over an index of it; `/usr/bin/time -l` reports the process's maximum resident set. Each call is
bounded to 300 s.

Usage: python3 -I probe_memory.py SEARCHD WORKDIR
"""
import re
import shutil
import subprocess
import sys
from pathlib import Path

searchd, work = sys.argv[1], Path(sys.argv[2])
MiB = 1 << 20
shapes = {
    "text lines (67 B)": (b"tide pool and harbour " * 3 + b"\n") * (10 * MiB // 67),
    "line breaks only": b"\n" * (10 * MiB - 1),
}
for label, data in shapes.items():
    folder = work / ("mem-" + re.sub(r"\W+", "-", label).strip("-"))
    if folder.exists():
        shutil.rmtree(folder)
    folder.mkdir(parents=True)
    (folder / "a.txt").write_bytes(data)
    index = Path(str(folder) + "-idx")
    if index.exists():
        shutil.rmtree(index)
    subprocess.run([searchd, "index", str(folder), "--out", str(index)], capture_output=True, timeout=300, check=True)
    for source, args in (("folder", ["--folder", str(folder)]), ("index", [str(index)])):
        done = subprocess.run(["/usr/bin/time", "-l", searchd, "scan", *args, "zzz", "--json", "--time-ms", "30000"],
                              capture_output=True, timeout=300)
        rss = re.search(rb"(\d+)\s+maximum resident set size", done.stderr)
        peak = re.search(rb"(\d+)\s+peak memory footprint", done.stderr)
        print(f"{label}, {len(data):,} bytes, {source}: exit {done.returncode}, maximum resident set "
              f"{int(rss.group(1)):,} B, peak memory footprint {int(peak.group(1)) if peak else 0:,} B")
