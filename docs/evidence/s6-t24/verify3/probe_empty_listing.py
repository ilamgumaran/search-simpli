#!/usr/bin/env python3
"""S6-T24 verifier probe (Verdict 3, ruling 4(b)): what listing costs now that empty matches are not counted.

docs/scan.md: "Listing a line's matches is so at most 17 passes plus one per code point of `text` where an empty
match starts (at most 512), all of it metered." A pattern that matches empty at every position but whose
non-empty branch must read to the end of the line before failing, `(?:a.*b)?`, makes each of those 512 passes
cost the whole line. Lines of n `a`s (one file each), n = 2^16, 2^18, 2^20 and 10 MiB - 1; rework 1's binary
(empty matches counted, so 17 passes) against the head, at `--time-ms 30000`, and the head at 1 and 1,000 ms.

Usage: python3 -I probe_empty_listing.py HEAD2_SEARCHD HEAD3_SEARCHD WORKDIR
Every call bounded (120 s). Times are of a machine not kept quiet.
"""
import json
import subprocess
import sys
import time
from pathlib import Path

head2, head3, work = sys.argv[1], sys.argv[2], Path(sys.argv[3])


def run(binary, folder, pattern, tm):
    start = time.monotonic()
    done = subprocess.run([binary, "scan", "--folder", folder, pattern, "--regex", "--json", "--time-ms", tm],
                          capture_output=True, timeout=120)
    ms = (time.monotonic() - start) * 1000
    if done.returncode != 0:
        return f"{ms:.0f} ms, exit {done.returncode}: {done.stderr.decode().strip()[:80]}"
    hit = json.loads(done.stdout)["hits"][0]
    return (f"{ms:.0f} ms, text {len(hit['text'])} code points, offsets {len(hit['match_offsets'])}, "
            f"text_truncated {hit['text_truncated']}, matches_truncated {hit.get('matches_truncated', '(absent)')}")


for n in (1 << 16, 1 << 18, 1 << 20, 10 * (1 << 20) - 1):
    folder = work / f"line-{n}"
    if not folder.exists():
        folder.mkdir(parents=True)
        (folder / "x.txt").write_text("a" * n + "\n")
    for pattern in ("(?:a.*b)?", "a(.*b)?"):
        print(f"{n} a's, {pattern}")
        print(f"  rework 1, --time-ms 30000: {run(head2, folder, pattern, '30000')}")
        for tm in ("30000", "1000", "1"):
            print(f"  head,     --time-ms {tm:>5}: {run(head3, folder, pattern, tm)}")
