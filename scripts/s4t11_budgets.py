#!/usr/bin/env python3
"""S4-T11: the one-changed-file update against a fresh index, byte for byte.

`compare` (rulings 2 and 3), on S4-T1's 10k timing corpus
(`scripts/gen_timing_corpus.py <dir> 10000`, checked against the recorded
SHA-256): for the filename channel off and on, `searchd index` writes an
index of the corpus; a fresh copy of it gets one `ss_apply_changes` from the
library (`group-00/doc-00000.md` plus one line, as `scripts/s4t4_budgets.py`
sends it); a copy of the corpus with the same line appended to that file is
indexed fresh by the same `searchd`. The sections the update wrote
(`documents-N.hybseg`, `lexical-N.hyblex`, `source-N.hybsrc`, and with the
channel on `filenames-N.hybseg`, `filename-lexical-N.hyblex`) are compared
byte for byte with the fresh index's (generation 2 against generation 1:
no section holds its generation number). Sizes and SHA-256 are printed.

`index-time` (ruling 4(e)): the full build, `searchd index` of the corpus
(no update) by the before and the after `searchd`, filename channel off and
on, in `--rounds` interleaved rounds; wall time per run, p50 and worst, the
load average at the start and the end.

The other timing commands stay in `scripts/s4t4_budgets.py` (`profile`,
`budgets`). Every library runs in its own child process. Invented text
only; every number printed is a measurement.
"""
import argparse
import hashlib
import json
import re
import os
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import s4t2_budgets as s4t2  # noqa: E402
import s4t4_budgets as s4t4  # noqa: E402

STEMS = (("documents", "hybseg"), ("lexical", "hyblex"), ("source", "hybsrc"),
         ("filenames", "hybseg"), ("filename-lexical", "hyblex"))


def current_sections(index):
    """The newest generation's section files, by stem."""
    found = {}
    for stem, suffix in STEMS:
        pattern = re.compile(rf"^{re.escape(stem)}-(\d+)\.{suffix}$")
        generations = sorted(int(m.group(1)) for p in index.iterdir() if (m := pattern.match(p.name)))
        if generations:
            found[stem] = index / f"{stem}-{generations[-1]}.{suffix}"
    return found


def describe(path):
    data = path.read_bytes()
    return {"file": path.name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def compare(args):
    corpus, work = args.corpus.resolve(), args.work.resolve()
    report = {"kind": "s4-t11-compare-v1", **s4t4.check_corpus(corpus), "binaries": {}, "cells": {}}
    for label, path in (("dylib", args.dylib), ("searchd", args.searchd)):
        report["binaries"][label] = {"bytes": path.stat().st_size, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)
    mutated = work / "corpus-mutated"
    shutil.copytree(corpus, mutated)
    changed = mutated / s4t2.CHANGED_PATH
    changed.write_bytes(changed.read_bytes() + b"One appended line for the budget run.\n")
    all_identical = True
    for label, extra in (("off", []), ("on", ["--filename-index"])):
        base, fresh = work / f"index-{label}", work / f"fresh-{label}"
        for source_dir, out in ((corpus, base), (mutated, fresh)):
            subprocess.run([str(args.searchd), "index", str(source_dir), "--out", str(out), *extra], check=True, capture_output=True, timeout=600)
        updated = work / f"update-{label}"
        s4t4.fresh_copy(base, updated)
        result = s4t4.run_child(args.dylib, updated, "apply", argparse.Namespace(samples=1, corpus=corpus))
        cell = {"apply": {key: result.get(key) for key in ("apply_ms", "changed", "generation", "error")}, "sections": {}}
        got, want = current_sections(updated), current_sections(fresh)
        for stem in sorted(set(got) | set(want)):
            a, b = got.get(stem), want.get(stem)
            identical = a is not None and b is not None and a.read_bytes() == b.read_bytes()
            all_identical = all_identical and identical
            cell["sections"][stem] = {"update": describe(a) if a else None, "fresh": describe(b) if b else None, "identical": identical}
        report["cells"][label] = cell
    report["all_identical"] = all_identical
    print(json.dumps(report, indent=2))
    return 0 if all_identical else 1


def index_time(args):
    corpus, work = args.corpus.resolve(), args.work.resolve()
    report = {"kind": "s4-t11-index-time-v1", **s4t4.check_corpus(corpus), "load_average": list(os.getloadavg()),
              "binaries": {}, "runs": []}
    for label, path in (("before_searchd", args.before_searchd), ("after_searchd", args.after_searchd)):
        report["binaries"][label] = {"bytes": path.stat().st_size, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)
    cells = (("before_off", args.before_searchd, []), ("after_off", args.after_searchd, []),
             ("before_on", args.before_searchd, ["--filename-index"]), ("after_on", args.after_searchd, ["--filename-index"]))
    for round_number in range(args.rounds):
        for label, searchd, extra in cells:
            out = work / label
            if out.exists():
                shutil.rmtree(out)
            start = time.perf_counter()
            subprocess.run([str(searchd), "index", str(corpus), "--out", str(out), *extra], check=True, capture_output=True, timeout=600)
            report["runs"].append({"round": round_number + 1, "label": label, "wall_ms": (time.perf_counter() - start) * 1000})
    summary = {}
    for label, _, _ in cells:
        walls = [r["wall_ms"] for r in report["runs"] if r["label"] == label]
        summary[label] = {"p50_ms": statistics.median(walls), "worst_ms": max(walls), "runs_ms": walls}
    for channel in ("off", "on"):
        before, after = summary[f"before_{channel}"]["p50_ms"], summary[f"after_{channel}"]["p50_ms"]
        summary[f"after_over_before_{channel}"] = after / before
    report["summary"] = summary
    report["load_average_end"] = list(os.getloadavg())
    print(json.dumps(report, indent=2))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=("compare", "index-time"))
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--dylib", type=Path, help="compare: the library that updates")
    parser.add_argument("--searchd", type=Path, help="compare: its searchd")
    parser.add_argument("--before-searchd", type=Path, help="index-time")
    parser.add_argument("--after-searchd", type=Path, help="index-time")
    parser.add_argument("--rounds", type=int, default=5)
    args = parser.parse_args()
    needed = ("dylib", "searchd") if args.command == "compare" else ("before_searchd", "after_searchd")
    missing = [n for n in needed if getattr(args, n) is None]
    if missing:
        parser.error("missing " + ", ".join("--" + n.replace("_", "-") for n in missing))
    return compare(args) if args.command == "compare" else index_time(args)


if __name__ == "__main__":
    raise SystemExit(main())
