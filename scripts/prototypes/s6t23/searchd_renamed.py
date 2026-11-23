#!/usr/bin/env -S python3 -I
"""S6-T23 Part 1 prototype: `searchd` as it would behave under `text-sniff-v1`, built from main's unchanged `searchd`.

Given to `scripts/text_search_score.py` as `--searchd`; the scorer itself runs unchanged. Environment:
S6T23_SEARCHD, the real `searchd` (main's, ReleaseSmall).

- `index FOLDER ...` and `search FOLDER ...`: on the first call, `textsniff.py rename` writes FOLDER-text, a copy of
  FOLDER in which every file the sniff calls text and today's 19 extensions skip has a name today's engine reads
  (same stem, same chunker, same bytewise order), and FOLDER-map.json; then the real `searchd` runs on the copy.
- every call: the real `searchd`'s stdout has each new path replaced by the real one (and the copy's folder by the
  real folder), so the scorer sees real paths and the byte counts it measures are the real paths' byte counts.

What this cannot show: the cost of the sniff itself (sniff_bench.zig measures it), a chunk id (a hash over the path)
deciding a tie between two chunks of one renamed file, and anything about files the rule would skip, since the judged
folder holds none (textsniff.py survey shows every file is text).
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import textsniff  # noqa: E402


def main(argv: list[str]) -> int:
    real = os.environ["S6T23_SEARCHD"]
    args = list(argv)
    swaps: list[tuple[bytes, bytes]] = []
    if args and args[0] in ("index", "search") and len(args) > 1:
        folder = Path(args[1])
        copy = folder.with_name(folder.name + "-text")
        map_path = folder.with_name(folder.name + "-map.json")
        if not copy.exists():
            report = textsniff.rename_copy(folder, copy, map_path)
            if not report["order_kept"] or report["refused"] or report["substring_clashes"]:
                print(f"searchd_renamed: rename refused: {report}", file=sys.stderr)
                return 70
        args[1] = str(copy)
        swaps.append((str(copy).encode(), str(folder).encode()))
        os.environ["S6T23_MAP"] = str(map_path)
    map_path = os.environ.get("S6T23_MAP") or _find_map(args)
    if map_path:
        mapping = json.loads(Path(map_path).read_text(encoding="utf-8"))["map"]
        for new, old in sorted(mapping.items(), key=lambda kv: -len(kv[0])):
            swaps.append((json.dumps(new)[1:-1].encode(), json.dumps(old)[1:-1].encode()))
    done = subprocess.run([real, *args], capture_output=True)
    out = done.stdout
    for new, old in swaps:
        out = out.replace(new, old)
    sys.stdout.buffer.write(out)
    sys.stderr.buffer.write(done.stderr)
    return done.returncode


def _find_map(args: list[str]) -> str | None:
    """For `evidence INDEX`, `list-files INDEX`, ...: the map beside the index (the scorer keeps both in one DIR)."""
    if len(args) > 1:
        for candidate in Path(args[1]).resolve().parent.glob("*-map.json"):
            return str(candidate)
    return None


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
