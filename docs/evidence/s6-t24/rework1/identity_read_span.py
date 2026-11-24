#!/usr/bin/env python3
"""S6-T24 rework 1: `read-span` and `outline` answer as on `main` after `source_v2.rebuildChecked` reads a file
kept whole straight into its buffer (ruling 4). On each build's own index (made by identity.py), for every file of
a corpus up to 400 drawn with seed 2411: `read-span` lines 1-400 (`--json`), lines 2-3 with `--context 2`, a range
past the end, and `outline --json`. stdout, stderr and exit code compared.
Usage: python3 -I identity_read_span.py MAIN_SEARCHD HEAD_SEARCHD WORK NAME..."""
import json
import random
import subprocess
import sys
from pathlib import Path

main_bin, head_bin, work = sys.argv[1], sys.argv[2], Path(sys.argv[3])


def run(binary, *args):
    done = subprocess.run([binary, *args], capture_output=True, stdin=subprocess.DEVNULL, timeout=600)
    return done.returncode, done.stdout, done.stderr


for name in sys.argv[4:]:
    a, b = work / f"{name}-main", work / f"{name}-head"
    files, cursor = [], None
    while True:
        page = json.loads(run(main_bin, "list-files", str(a), "--json", "--page-size", "1000", *(["--cursor", cursor] if cursor else []))[1])
        files += [(f["root_id"], f["path"]) for f in page["files"] if f["status"] == "indexed"]
        cursor = page["next_cursor"]
        if not cursor:
            break
    rng = random.Random(2411)
    chosen = sorted(rng.sample(files, min(400, len(files))))
    calls = differ = answered = 0
    for root, path in chosen:
        for rest in (("read-span", "{i}", root, path, "1", "400", "--json"), ("read-span", "{i}", root, path, "2", "3", "--context", "2"),
                     ("read-span", "{i}", root, path, "100000", "100001", "--json"), ("outline", "{i}", root, path, "--json")):
            out_a = run(main_bin, *[str(a) if x == "{i}" else x for x in rest])
            out_b = run(head_bin, *[str(b) if x == "{i}" else x for x in rest])
            calls += 1
            answered += out_a[0] == 0
            if out_a != out_b:
                differ += 1
                print("  DIFF", rest[0], path, out_a[0], out_b[0], out_a[2][:200], out_b[2][:200])
    print(f"{name}: {len(chosen)} files, {calls} calls (read-span x3, outline), {answered} answered with exit 0 by main, "
          f"{differ} differ (stdout, stderr and exit code compared)")
