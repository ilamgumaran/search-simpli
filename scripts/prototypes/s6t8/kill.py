#!/usr/bin/env python3
"""S6-T8: SIGKILL during the first publish from `main`'s format (62324f9).

    python3 -I kill.py SEARCHD OLD_INDEX FOLDER WORK FIRST_MS LAST_MS STEP_MS

For each delay from FIRST_MS to LAST_MS: copy OLD_INDEX (written by `main`
at 62324f9: manifest v2.4, content lexical section `HYBLEX03`) to WORK/trial-<ms>, start
`SEARCHD index FOLDER --out <copy> --update --filename-index`, wait the
delay once, and SIGKILL it if it is still running. Then classify the copy:

- its `MANIFEST` names generation 1 with flag bit 7 clear and a `HYBLEX03`
  content section, or generation 2 with bit 7 set and `HYBLEX04`; anything
  else is a failure;
- `SEARCHD` answers the reference requests (a query, `find` in its three
  modes, `list-files`, and `read-span` of five files) exactly as on an
  untouched copy (both formats answer alike);
- a later `index --update` over the leftovers publishes a whole v2.5
  generation that answers the same.

WORK must not exist. Prints one line per trial and a summary; exit 1 on any
failure. Not part of any library.
"""

from __future__ import annotations

import json
import re
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path


def manifest_state(index: Path) -> tuple[int, bool, int, bytes]:
    raw = (index / "MANIFEST").read_bytes()
    flags = int.from_bytes(raw[10:12], "little")
    generation = int.from_bytes(raw[12:20], "little")
    lexical = index / f"lexical-{generation}.hyblex"
    magic = lexical.read_bytes()[:8] if lexical.exists() else b""
    return generation, bool(flags & 0x80), int(magic[6:8]) if magic[6:8].isdigit() else -1, magic


def answers(searchd: str, index: Path) -> str:
    out = []
    for argv in (["query", str(index), "search ranking", "--json", "--top-k", "10"],
                 ["find", str(index), "search ranking", "--json", "--page-size", "50"],
                 ["find", str(index), "search ranking", "--mode", "phrase", "--json", "--page-size", "50"],
                 ["find", str(index), "bethi", "--mode", "prefix", "--json", "--page-size", "50"],
                 ["list-files", str(index), "--json", "--page-size", "1000"]):
        done = subprocess.run([searchd, *argv], capture_output=True, text=True)
        out.append(done.stdout.replace(str(index), "IDX") + done.stderr + str(done.returncode))
    files = json.loads(out[-1].rsplit("0", 1)[0])["files"] if out[-1].endswith("0") else []
    for f in files[:: max(1, len(files) // 5)][:5]:
        done = subprocess.run([searchd, "read-span", str(index), f["root_id"], f["path"], "1", "60", "--json"],
                              capture_output=True, text=True)
        out.append(done.stdout + done.stderr + str(done.returncode))
    # The generation number is the one thing a whole generation 1 and a whole
    # generation 2 (or 3) answer differently (it is in every answer, and in
    # `list-files`' cursor).
    return re.sub(r'"generation":\d+', '"generation":G', re.sub(r'"(\d+):(\d+)"', r'"G:\2"', "\n".join(out)))


def main(argv: list[str]) -> int:
    if len(argv) != 8:
        print(__doc__, file=sys.stderr)
        return 2
    searchd, old, folder, work = argv[1], Path(argv[2]), argv[3], Path(argv[4])
    first, last, step = (int(x) for x in argv[5:8])
    work.mkdir()
    reference = work / "reference"
    shutil.copytree(old, reference)
    want = answers(searchd, reference)
    counts = {"gen1": 0, "gen2": 0, "killed": 0, "finished": 0, "failures": 0, "later": 0}
    for ms in range(first, last + 1, step):
        copy = work / f"trial-{ms}"
        shutil.copytree(old, copy)
        process = subprocess.Popen([searchd, "index", folder, "--out", str(copy), "--update", "--filename-index"],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(ms / 1000)
        killed = process.poll() is None
        if killed:
            process.send_signal(signal.SIGKILL)
        process.wait()
        counts["killed" if killed else "finished"] += 1
        generation, flag, version, magic = manifest_state(copy)
        consistent = (generation == 1 and not flag and magic == b"HYBLEX03") or \
                     (generation == 2 and flag and magic == b"HYBLEX04")
        same = answers(searchd, copy) == want
        later = subprocess.run([searchd, "index", folder, "--out", str(copy), "--update", "--filename-index"],
                               capture_output=True, text=True)
        g2, f2, v2, m2 = manifest_state(copy)
        later_ok = later.returncode == 0 and f2 and m2 == b"HYBLEX04" and answers(searchd, copy) == want
        ok = consistent and same and later_ok
        counts[f"gen{generation}"] = counts.get(f"gen{generation}", 0) + 1
        counts["later"] += later_ok
        counts["failures"] += not ok
        print(f"{ms:4d} ms: {'killed' if killed else 'finished'}; generation {generation}, bit 7 {int(flag)}, "
              f"{magic.decode('latin-1')}; answers {'same' if same else 'DIFFER'}; "
              f"later update -> generation {g2} {'whole, same answers' if later_ok else 'FAILED'}")
        shutil.rmtree(copy)
    print(f"summary: {counts}")
    return 1 if counts["failures"] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
