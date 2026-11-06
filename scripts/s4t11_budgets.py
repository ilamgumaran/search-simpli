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

The timing commands stay in `scripts/s4t4_budgets.py` (`profile`,
`budgets`). Every library runs in its own child process. Invented text
only; every number printed is a measurement.
"""
import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
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


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=("compare",))
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--dylib", type=Path, required=True)
    parser.add_argument("--searchd", type=Path, required=True)
    args = parser.parse_args()
    return compare(args)


if __name__ == "__main__":
    raise SystemExit(main())
