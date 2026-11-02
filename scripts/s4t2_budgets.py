#!/usr/bin/env python3
"""S4-T2 R7: the phone-side budgets, before (main, f45c06d) and after (this tree).

Measures, on S4-T1's 10k timing corpus (`scripts/gen_timing_corpus.py <dir>
10000`; the files' SHA-256 in sorted path order is checked against the
recorded one):

- `ss_open` p50 (per sample a fresh handle: `ss_open`, `ss_close`; two
  warm-ups, then `--samples` timed), filename channel off and on;
- the first query after a cold open (per sample `ss_open`, one `ss_query`,
  `ss_close`): content, and filename and both on the enabled index, where
  that first query loads the filename sections;
- one changed file: one `ss_apply_changes` call (one line appended to
  `group-00/doc-00000.md`, `content_base64`) on a fresh copy of the index
  for every run, wall time of the call;
- the MANIFEST of each index (bytes, flags), and what the main library does
  with an index this tree wrote or upgraded.

Every library runs in its own child process (two libraries share symbol
names), and the labels are interleaved round by round. Invented text only;
the numbers printed are the measurements, nothing is estimated.

Usage: python3 scripts/s4t2_budgets.py --corpus DIR --work DIR \\
    --before-dylib LIB --before-searchd BIN --after-dylib LIB --after-searchd BIN
"""
import argparse
import base64
import ctypes
import hashlib
import json
import os
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path

CORPUS_SHA256 = "3a520dd588fa34cb2bec9a15b12f7ad8a0fc3c0d5feebd4baba4ce49fed96e38"
CHANGED_PATH = "group-00/doc-00000.md"
QUERIES = {
    "content": ("hybrid retrieval", {"retrieval_mode": "lexical"}),
    "filename": ("doc 04242", {"retrieval_mode": "lexical", "search_field": "filename"}),
    "both": ("doc 04242 retrieval", {"retrieval_mode": "lexical", "search_field": "both"}),
}


def corpus_digest(root):
    paths = sorted(p for p in root.rglob("*") if p.is_file())
    digest = hashlib.sha256()
    for path in paths:
        digest.update(path.read_bytes())
    return len(paths), digest.hexdigest()


def manifest_facts(index):
    data = (index / "MANIFEST").read_bytes()
    return {"bytes": len(data), "magic": data[:8].decode(), "flags": "0x%04x" % int.from_bytes(data[10:12], "little")}


# ---------------------------------------------------------------- child ---

def load(dylib):
    lib = ctypes.CDLL(str(dylib))
    lib.ss_open.restype = ctypes.c_void_p
    lib.ss_open.argtypes = [ctypes.c_char_p]
    lib.ss_close.argtypes = [ctypes.c_void_p]
    lib.ss_query.restype = ctypes.c_void_p
    lib.ss_query.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t, ctypes.c_char_p]
    lib.ss_apply_changes.restype = ctypes.c_void_p
    lib.ss_apply_changes.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p]
    lib.ss_free.argtypes = [ctypes.c_void_p]
    lib.ss_last_error.restype = ctypes.c_char_p
    lib.ss_version.restype = ctypes.c_char_p
    return lib


def child(args):
    lib = load(args.dylib)
    index = str(args.index).encode()
    out = {"version": lib.ss_version().decode()}
    clock = time.perf_counter_ns
    if args.mode == "open":
        samples = []
        for number in range(2 + args.samples):
            start = clock()
            handle = lib.ss_open(index)
            elapsed = clock() - start
            if not handle:
                out["error"] = lib.ss_last_error().decode()
                break
            lib.ss_close(handle)
            if number >= 2:
                samples.append(elapsed / 1e6)
        out["open_ms"] = samples
    elif args.mode == "first":
        text, options = QUERIES[args.query]
        opens, firsts = [], []
        for number in range(2 + args.samples):
            start = clock()
            handle = lib.ss_open(index)
            opened = clock()
            if not handle:
                out["error"] = lib.ss_last_error().decode()
                break
            result = lib.ss_query(handle, text.encode(), None, 0, 5, json.dumps(options).encode())
            done = clock()
            if not result:
                out["error"] = lib.ss_last_error().decode()
                lib.ss_close(handle)
                break
            hits = json.loads(ctypes.string_at(result))["results"]
            lib.ss_free(result)
            lib.ss_close(handle)
            if not hits:
                out["error"] = "no results"
                break
            # The file the name names: first for a filename query, among the
            # fused results for both (RRF ties it with the best content hit).
            named = [hit["citation"]["path"].endswith("doc-04242.md") for hit in hits]
            if (args.query == "filename" and not named[0]) or (args.query == "both" and not any(named)):
                out["error"] = "the named file is missing from the results"
                break
            if number >= 2:
                opens.append((opened - start) / 1e6)
                firsts.append((done - opened) / 1e6)
        out["open_ms"], out["first_ms"] = opens, firsts
    elif args.mode == "apply":
        content = Path(args.corpus, CHANGED_PATH).read_bytes() + b"One appended line for the budget run.\n"
        request = {"changes": [{"op": "change", "root_id": "r-legacy", "path": CHANGED_PATH,
                                "content_base64": base64.b64encode(content).decode()}]}
        start = clock()
        report = lib.ss_apply_changes(index, json.dumps(request).encode(), None)
        elapsed = clock() - start
        if not report:
            out["error"] = lib.ss_last_error().decode()
        else:
            parsed = json.loads(ctypes.string_at(report))
            lib.ss_free(report)
            out["apply_ms"] = elapsed / 1e6
            out["changed"] = parsed["changed"]
            out["generation"] = parsed["generation"]
    elif args.mode == "refuse":
        handle = lib.ss_open(index)
        if handle:
            lib.ss_close(handle)
            out["opened"] = True
        else:
            out["opened"] = False
            out["error"] = lib.ss_last_error().decode()
    print(json.dumps(out))
    return 0


# --------------------------------------------------------------- parent ---

def run_child(dylib, index, mode, args, query=None):
    command = [sys.executable, "-I", str(Path(__file__).resolve()), "--child", "--mode", mode,
               "--dylib", str(dylib), "--index", str(index), "--samples", str(args.samples), "--corpus", str(args.corpus)]
    if query:
        command += ["--query", query]
    env = dict(os.environ)
    env.pop("SEARCH_SIMPLI_LIBRARY_PATH", None)
    result = subprocess.run(command, capture_output=True, text=True, timeout=600, env=env)
    if result.returncode != 0:
        raise RuntimeError(f"child {mode} failed: {result.stderr}")
    return json.loads(result.stdout)


def p50(values):
    return statistics.median(values) if values else None


def parent(args):
    corpus, work = args.corpus.resolve(), args.work.resolve()
    count, digest = corpus_digest(corpus)
    report = {"kind": "s4-t2-budgets-v1", "corpus_files": count, "corpus_sha256": digest,
              "corpus_matches_recorded": digest == CORPUS_SHA256, "binaries": {}, "indexes": {},
              "open": [], "first": [], "apply": [], "refusals": {}}
    for label, path in (("before_dylib", args.before_dylib), ("after_dylib", args.after_dylib),
                        ("before_searchd", args.before_searchd), ("after_searchd", args.after_searchd)):
        report["binaries"][label] = {"bytes": path.stat().st_size, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)
    builds = (("before", args.before_searchd, []), ("after_off", args.after_searchd, []),
              ("after_on", args.after_searchd, ["--filename-index"]))
    for label, searchd, extra in builds:
        index = work / label
        start = time.perf_counter()
        subprocess.run([str(searchd), "index", str(corpus), "--out", str(index), *extra], check=True, capture_output=True, timeout=600)
        report["indexes"][label] = {"index_wall_ms": (time.perf_counter() - start) * 1000, "manifest": manifest_facts(index),
                                    "files": sorted(p.name for p in index.iterdir())}

    # (label, dylib, index): main's library on main's index; this tree's on
    # its own, filename off and on; this tree's on main's index (upgrade).
    cells = (("before", args.before_dylib, work / "before"), ("after_off", args.after_dylib, work / "after_off"),
             ("after_on", args.after_dylib, work / "after_on"), ("upgrade", args.after_dylib, work / "before"))
    for round_number in range(args.rounds):
        for label, dylib, index in cells:
            result = run_child(dylib, index, "open", args)
            report["open"].append({"round": round_number + 1, "label": label, "p50_ms": p50(result.get("open_ms")),
                                   "min_ms": min(result["open_ms"]) if result.get("open_ms") else None,
                                   "max_ms": max(result["open_ms"]) if result.get("open_ms") else None,
                                   "samples": len(result.get("open_ms", [])), "error": result.get("error"), "version": result["version"]})
        for label, dylib, index in cells:
            for query in ("content", "filename", "both"):
                if query != "content" and label != "after_on":
                    continue
                result = run_child(dylib, index, "first", args, query)
                report["first"].append({"round": round_number + 1, "label": label, "query": query,
                                        "open_p50_ms": p50(result.get("open_ms")), "first_p50_ms": p50(result.get("first_ms")),
                                        "total_p50_ms": p50([a + b for a, b in zip(result.get("open_ms", []), result.get("first_ms", []))]),
                                        "error": result.get("error")})
    for run_number in range(args.apply_runs):
        for label, dylib, index in cells:
            copy = work / f"apply-{label}-{run_number}"
            shutil.copytree(index, copy)
            (copy / "WRITER.LOCK").unlink(missing_ok=True)
            result = run_child(dylib, copy, "apply", args)
            entry = {"run": run_number + 1, "label": label, "ms": result.get("apply_ms"), "changed": result.get("changed"),
                     "generation": result.get("generation"), "error": result.get("error")}
            if run_number == 0:
                entry["manifest_after"] = manifest_facts(copy)
                entry["files_after"] = sorted(p.name for p in copy.iterdir())
                if label in ("upgrade", "after_off", "after_on"):
                    report["refusals"][f"before_dylib_on_{label}_written"] = run_child(args.before_dylib, copy, "refuse", args)
            report["apply"].append(entry)
            if run_number != 0:
                shutil.rmtree(copy)
    summary = {}
    for label, _, _ in cells:
        opens = [e["p50_ms"] for e in report["open"] if e["label"] == label and e["p50_ms"] is not None]
        applies = [e["ms"] for e in report["apply"] if e["label"] == label and e["ms"] is not None]
        summary[label] = {"open_p50_ms_by_round": opens, "apply_ms_runs": applies, "apply_p50_ms": p50(applies)}
    report["summary"] = summary
    print(json.dumps(report, indent=2))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--child", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--mode", choices=("open", "first", "apply", "refuse"), help=argparse.SUPPRESS)
    parser.add_argument("--dylib", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--index", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--query", choices=tuple(QUERIES), help=argparse.SUPPRESS)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--work", type=Path)
    parser.add_argument("--before-dylib", type=Path)
    parser.add_argument("--before-searchd", type=Path)
    parser.add_argument("--after-dylib", type=Path)
    parser.add_argument("--after-searchd", type=Path)
    parser.add_argument("--samples", type=int, default=30)
    parser.add_argument("--rounds", type=int, default=2)
    parser.add_argument("--apply-runs", type=int, default=5)
    args = parser.parse_args()
    if args.child:
        return child(args)
    missing = [name for name in ("work", "before_dylib", "before_searchd", "after_dylib", "after_searchd") if getattr(args, name) is None]
    if missing:
        parser.error("missing " + ", ".join("--" + name.replace("_", "-") for name in missing))
    return parent(args)


if __name__ == "__main__":
    raise SystemExit(main())
