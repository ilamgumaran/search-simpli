#!/usr/bin/env python3
"""S4-T4: the one-changed-file stage profile and the budgets, before and after.

Two commands, both on S4-T1's 10k timing corpus (`scripts/gen_timing_corpus.py
<dir> 10000`, checked against the recorded SHA-256):

`profile` (ruling 1): one library and its `searchd` (both built with this
tree's stage timers, `SEARCH_SIMPLI_APPLY_STAGES`, `zig/src/apply.zig`
`Stages`). Two indexes are written by `searchd index`, filename channel off
and on; then, `--runs` times for each (interleaved), a fresh copy of the
index gets one `ss_apply_changes` (`group-00/doc-00000.md` plus one line,
`content_base64`) in a child process with `SEARCH_SIMPLI_APPLY_STAGES=1`,
whose stderr line `apply-stages {...}` gives each stage's milliseconds. The
table: p50 and worst per stage, plus the call's wall time.

`budgets` (ruling 5): `scripts/s4t2_budgets.py`'s measurements (`ss_open`,
the first query after a cold open, one changed file, MANIFEST facts) with
the before library (`596032c`) and this tree's, interleaved, plus: the state
bytes each generation writes (`state-N.hybstate`, `INDEX-STATE.json`), the
filename sections of the same input byte-compared before and after, and the
before library on a directory this tree wrote (open, a query, and an
`ss_apply_changes`, whose refusal or success is printed with the state the
next generation names), and this tree's library updating a directory the
before library wrote (`upgrade_off`, `upgrade_on`).

Every library runs in its own child process. Invented text only; every
number printed is a measurement.
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

sys.path.insert(0, str(Path(__file__).resolve().parent))
import s4t2_budgets as s4t2  # noqa: E402

STAGE_VARIABLE = "SEARCH_SIMPLI_APPLY_STAGES"


def request_bytes(corpus):
    content = Path(corpus, s4t2.CHANGED_PATH).read_bytes() + b"One appended line for the budget run.\n"
    return json.dumps({"changes": [{"op": "change", "root_id": "r-legacy", "path": s4t2.CHANGED_PATH,
                                    "content_base64": base64.b64encode(content).decode()}]}).encode()


# ---------------------------------------------------------------- child ---

def child(args):
    if args.mode in ("open", "first", "refuse"):
        return s4t2.child(args)
    lib = s4t2.load(args.dylib)
    out = {"version": lib.ss_version().decode()}
    index = str(args.index).encode()
    if args.mode in ("apply", "update"):
        start = time.perf_counter_ns()
        report = lib.ss_apply_changes(index, request_bytes(args.corpus), None)
        elapsed = time.perf_counter_ns() - start
        if not report:
            out["error"] = lib.ss_last_error().decode()
        else:
            parsed = json.loads(ctypes.string_at(report))
            lib.ss_free(report)
            out.update({"apply_ms": elapsed / 1e6, "changed": parsed["changed"], "generation": parsed["generation"]})
    elif args.mode == "query":
        handle = lib.ss_open(index)
        if not handle:
            out["error"] = lib.ss_last_error().decode()
        else:
            hits = []
            for name in ("content", "filename", "both"):
                text, options = s4t2.QUERIES[name]
                result = lib.ss_query(handle, text.encode(), None, 0, 5, json.dumps(options).encode())
                if not result:
                    hits.append({"query": name, "error": lib.ss_last_error().decode()})
                    continue
                parsed = json.loads(ctypes.string_at(result))["results"]
                lib.ss_free(result)
                hits.append({"query": name, "paths": [hit["citation"]["path"] for hit in parsed]})
            lib.ss_close(handle)
            out["queries"] = hits
    print(json.dumps(out))
    return 0


def run_child(dylib, index, mode, args, query=None, stages=False):
    command = [sys.executable, "-I", str(Path(__file__).resolve()), "--child", "--mode", mode,
               "--dylib", str(dylib), "--index", str(index), "--samples", str(args.samples), "--corpus", str(args.corpus)]
    if query:
        command += ["--query", query]
    env = dict(os.environ)
    env.pop("SEARCH_SIMPLI_LIBRARY_PATH", None)
    env.pop(STAGE_VARIABLE, None)
    if stages:
        env[STAGE_VARIABLE] = "1"
    result = subprocess.run(command, capture_output=True, text=True, timeout=600, env=env)
    if result.returncode != 0:
        raise RuntimeError(f"child {mode} failed: {result.stderr}")
    out = json.loads(result.stdout)
    lines = [line for line in result.stderr.splitlines() if line.startswith("apply-stages ")]
    if stages:
        out["stages"] = json.loads(lines[-1][len("apply-stages "):]) if lines else None
    elif lines:
        out["unexpected_stage_lines"] = len(lines)
    return out


def fresh_copy(index, copy):
    if copy.exists():
        shutil.rmtree(copy)
    shutil.copytree(index, copy)
    (copy / "WRITER.LOCK").unlink(missing_ok=True)


def state_bytes(index):
    """The state bytes the directory's current generation wrote."""
    manifest = s4t2.manifest_facts(index)
    files = {p.name: p.stat().st_size for p in index.iterdir() if p.is_file()}
    generations = sorted(int(name[len("state-"):-len(".hybstate")]) for name in files if name.startswith("state-") and name.endswith(".hybstate"))
    current = f"state-{generations[-1]}.hybstate" if generations else None
    section = files.get(current, 0) if current else 0
    pointer = files.get("INDEX-STATE.json", 0)
    head = (index / current).read_bytes()[:8].decode(errors="replace") if current else None
    state_json = json.loads((index / "INDEX-STATE.json").read_text()) if pointer else None
    return {"section_file": current, "section_magic": head, "section_bytes": section, "index_state_bytes": pointer,
            "index_state_version": state_json.get("state_version") if state_json else None,
            "total_bytes": section + pointer, "manifest": manifest}


def p50(values):
    return statistics.median(values) if values else None


def build_indexes(work, corpus, builds):
    facts = {}
    for label, searchd, extra in builds:
        index = work / label
        start = time.perf_counter()
        subprocess.run([str(searchd), "index", str(corpus), "--out", str(index), *extra], check=True, capture_output=True, timeout=600)
        facts[label] = {"index_wall_ms": (time.perf_counter() - start) * 1000, "manifest": s4t2.manifest_facts(index),
                        "files": sorted(p.name for p in index.iterdir())}
    return facts


def check_corpus(corpus):
    count, digest = s4t2.corpus_digest(corpus)
    return {"corpus_files": count, "corpus_sha256": digest, "corpus_matches_recorded": digest == s4t2.CORPUS_SHA256}


# -------------------------------------------------------------- profile ---

def profile(args):
    corpus, work = args.corpus.resolve(), args.work.resolve()
    report = {"kind": "s4-t4-profile-v1", **check_corpus(corpus), "library": {}, "runs": []}
    for label, path in (("dylib", args.dylib), ("searchd", args.searchd)):
        report["library"][label] = {"bytes": path.stat().st_size, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)
    report["indexes"] = build_indexes(work, corpus, (("off", args.searchd, []), ("on", args.searchd, ["--filename-index"])))
    for run_number in range(args.runs):
        for label in ("off", "on"):
            copy = work / f"apply-{label}"
            fresh_copy(work / label, copy)
            result = run_child(args.dylib, copy, "apply", args, stages=True)
            entry = {"run": run_number + 1, "label": label, "wall_ms": result.get("apply_ms"), "error": result.get("error"),
                     "stages": result.get("stages")}
            if run_number == 0:
                entry["state_after"] = state_bytes(copy)
            report["runs"].append(entry)
    table = {}
    for label in ("off", "on"):
        runs = [r for r in report["runs"] if r["label"] == label and r["stages"]]
        # S4-T11 ruling 1: every stage and dotted sub-stage any run printed,
        # in first-seen order (a sub-stage only some runs reach still shows).
        names = []
        for r in runs:
            names += [name for name in r["stages"] if name not in names]
        table[label] = {name: {"p50_ms": p50([r["stages"][name] for r in runs if name in r["stages"]]),
                               "worst_ms": max(r["stages"][name] for r in runs if name in r["stages"]),
                               "runs_ms": [r["stages"].get(name) for r in runs]} for name in names}
        walls = [r["wall_ms"] for r in runs]
        table[label]["call_wall"] = {"p50_ms": p50(walls), "worst_ms": max(walls) if walls else None, "runs_ms": walls}
    report["table"] = table
    print(json.dumps(report, indent=2))
    return 0


# -------------------------------------------------------------- budgets ---

def budgets(args):
    corpus, work = args.corpus.resolve(), args.work.resolve()
    report = {"kind": "s4-t4-budgets-v1", **check_corpus(corpus), "binaries": {}, "load_average": list(os.getloadavg()),
              "open": [], "first": [], "apply": [], "before_library_on_after": {}}
    for label, path in (("before_dylib", args.before_dylib), ("after_dylib", args.after_dylib),
                        ("before_searchd", args.before_searchd), ("after_searchd", args.after_searchd)):
        report["binaries"][label] = {"bytes": path.stat().st_size, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)
    report["indexes"] = build_indexes(work, corpus, (
        ("before_off", args.before_searchd, []), ("before_on", args.before_searchd, ["--filename-index"]),
        ("after_off", args.after_searchd, []), ("after_on", args.after_searchd, ["--filename-index"])))
    cells = (("before_off", args.before_dylib, work / "before_off"), ("before_on", args.before_dylib, work / "before_on"),
             ("after_off", args.after_dylib, work / "after_off"), ("after_on", args.after_dylib, work / "after_on"))
    for round_number in range(args.rounds):
        for label, dylib, index in cells:
            result = run_child(dylib, index, "open", args)
            opens = result.get("open_ms") or []
            report["open"].append({"round": round_number + 1, "label": label, "p50_ms": p50(opens),
                                   "min_ms": min(opens) if opens else None, "max_ms": max(opens) if opens else None,
                                   "samples": len(opens), "error": result.get("error"), "version": result["version"]})
        for label, dylib, index in cells:
            for query in ("content", "filename", "both"):
                if query != "content" and not label.endswith("_on"):
                    continue
                result = run_child(dylib, index, "first", args, query)
                report["first"].append({"round": round_number + 1, "label": label, "query": query,
                                        "open_p50_ms": p50(result.get("open_ms")), "first_p50_ms": p50(result.get("first_ms")),
                                        "error": result.get("error")})
    # The after library's first update of a directory the before library
    # wrote (HYBSTA01 and a version 2 INDEX-STATE.json): the upgrade.
    apply_cells = cells + (("upgrade_off", args.after_dylib, work / "before_off"), ("upgrade_on", args.after_dylib, work / "before_on"))
    kept = {}
    for run_number in range(args.apply_runs):
        for label, dylib, index in apply_cells:
            copy = work / f"apply-{label}-{run_number}"
            fresh_copy(index, copy)
            result = run_child(dylib, copy, "apply", args)
            entry = {"run": run_number + 1, "label": label, "ms": result.get("apply_ms"), "changed": result.get("changed"),
                     "generation": result.get("generation"), "error": result.get("error")}
            if run_number == 0:
                entry["state_after"] = state_bytes(copy)
                entry["files_after"] = sorted(p.name for p in copy.iterdir())
                kept[label] = copy
            else:
                shutil.rmtree(copy)
            report["apply"].append(entry)

    # The filename sections of the same input, before and after: the
    # generation `searchd index` wrote and the one the update wrote.
    identical = {}
    for name_pattern, generation, before_dir, after_dir in (
            ("{}-1", 1, work / "before_on", work / "after_on"),
            ("{}-2", 2, kept.get("before_on"), kept.get("after_on"))):
        for stem, suffix in (("filenames", "hybseg"), ("filename-lexical", "hyblex")):
            name = f"{stem}-{generation}.{suffix}"
            a, b = before_dir / name, after_dir / name
            identical[name] = {"before_bytes": a.stat().st_size if a.exists() else None,
                               "after_bytes": b.stat().st_size if b.exists() else None,
                               "identical": a.exists() and b.exists() and a.read_bytes() == b.read_bytes()}
    report["filename_sections"] = identical

    # The before library on directories this tree wrote (ruling 3): open,
    # the three queries, then one update on a fresh copy.
    for label in ("after_off", "after_on"):
        facts = {"open": run_child(args.before_dylib, work / label, "refuse", args),
                 "queries": run_child(args.before_dylib, work / label, "query", args).get("queries")}
        copy = work / f"before-updates-{label}"
        fresh_copy(work / label, copy)
        updated = run_child(args.before_dylib, copy, "update", args)
        facts["update"] = {key: updated.get(key) for key in ("apply_ms", "changed", "generation", "error")}
        facts["after_update"] = state_bytes(copy)
        report["before_library_on_after"][label] = facts
    summary = {}
    for label, _, _ in apply_cells:
        opens = [e["p50_ms"] for e in report["open"] if e["label"] == label and e["p50_ms"] is not None]
        applies = [e["ms"] for e in report["apply"] if e["label"] == label and e["ms"] is not None]
        summary[label] = {"open_p50_ms_by_round": opens, "apply_ms_runs": applies, "apply_p50_ms": p50(applies),
                          "apply_worst_ms": max(applies) if applies else None}
    report["summary"] = summary
    report["load_average_end"] = list(os.getloadavg())
    print(json.dumps(report, indent=2))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", nargs="?", choices=("profile", "budgets"))
    parser.add_argument("--child", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--mode", choices=("open", "first", "refuse", "apply", "update", "query"), help=argparse.SUPPRESS)
    parser.add_argument("--index", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--query", choices=tuple(s4t2.QUERIES), help=argparse.SUPPRESS)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--work", type=Path)
    parser.add_argument("--dylib", type=Path, help="profile: the instrumented library")
    parser.add_argument("--searchd", type=Path, help="profile: its searchd")
    parser.add_argument("--before-dylib", type=Path)
    parser.add_argument("--before-searchd", type=Path)
    parser.add_argument("--after-dylib", type=Path)
    parser.add_argument("--after-searchd", type=Path)
    parser.add_argument("--samples", type=int, default=30)
    parser.add_argument("--rounds", type=int, default=2)
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--apply-runs", type=int, default=5)
    args = parser.parse_args()
    if args.child:
        return child(args)
    if args.command == "profile":
        missing = [n for n in ("work", "dylib", "searchd") if getattr(args, n) is None]
        if missing:
            parser.error("missing " + ", ".join("--" + n for n in missing))
        return profile(args)
    if args.command == "budgets":
        missing = [n for n in ("work", "before_dylib", "before_searchd", "after_dylib", "after_searchd") if getattr(args, n) is None]
        if missing:
            parser.error("missing " + ", ".join("--" + n.replace("_", "-") for n in missing))
        return budgets(args)
    parser.error("a command is required: profile or budgets")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
