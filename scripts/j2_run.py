#!/usr/bin/env python3
"""Run J2 through the shipped `searchd` binary, compare two runs, or write the baseline (S5-T1).

  j2_run.py --searchd PATH [--optimize NAME] [--output RUN.json]
  j2_run.py --build [--scratch DIR] [--output RUN.json]
  j2_run.py --compare A.json B.json
  j2_run.py (--searchd PATH | --build) --write-baseline fixtures/j2/baseline.json
            [--python-output PY.json] [--output RUN.json]

The index is built the way the app builds one, through the shipped CLI: an
empty folder is indexed with the file-name channel on (`searchd index EMPTY
--filename-index`), then `searchd apply` adds the three roots (school, home,
laptop; kind host) with every file as `content_base64`. `apply` cannot turn the
file-name channel on for a new directory, so this two-step bootstrap leaves an
empty `r-legacy` root beside the three; every request names the three roots.
One `searchd serve` process answers every query on stdio and is closed at the
end. Knowledge rows run `search_knowledge` (lexical, top 10) once with
`search_field: content` and once with `both`; find rows run `find` once, first
page of 10. Metrics come from relevance_smoke.py, the code the Python reference
uses, so both surfaces score with one implementation.

--write-baseline also runs the Python reference in this process and writes
both surfaces into one baseline file; set PYTHONHASHSEED=0 for the record.
"""

from __future__ import annotations

import argparse
import base64
import datetime
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from relevance_smoke import (  # noqa: E402
    J2_RESULTS_SCHEMA,
    J2_TOP_K,
    J2_VARIANTS,
    PACKS,
    j2_git_head,
    j2_judgments_sha256,
    j2_load,
    j2_run_queries,
    run_j2_pack,
)

PACK = PACKS["j2"]
BASELINE_SCHEMA = "j2-baseline-v1"
NATIVE = ROOT / "bindings" / "dart" / "search_simpli" / "native"
CALL_TIMEOUT_S = 60


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def natives_digest() -> dict:
    sys.path.insert(0, str(ROOT / "bindings" / "dart" / "search_simpli" / "tool"))
    from source_digest import source_digest  # noqa: E402
    computed = source_digest(ROOT)
    committed = (NATIVE / "SOURCE-SHA256").read_text(encoding="utf-8").split()[0]
    return {"natives_digest": computed, "natives_digest_matches_committed": computed == committed}


def zig_version() -> str | None:
    if shutil.which("zig") is None:
        return None
    done = subprocess.run(["zig", "version"], capture_output=True, text=True, timeout=60)
    return done.stdout.strip() or None


def top_sample() -> list[str]:
    """The machine's load at the run: the header lines of a `top` sample taken over one
    second (the second of two samples, so CPU figures are a real interval). Process
    names are left out: the baseline is committed to a public repository."""
    if platform.system() == "Darwin":
        cmd, marks = ["top", "-l", "2", "-n", "0", "-s", "1"], ("Processes", "Load Avg", "CPU usage")
    else:
        cmd, marks = ["top", "-b", "-n", "2", "-d", "1"], ("top -", "Tasks", "%Cpu")
    try:
        done = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return []
    lines = [line.strip() for line in done.stdout.splitlines() if line.strip().startswith(marks)]
    return lines[-len(marks):]


def build_searchd(scratch: Path) -> Path:
    """ReleaseSmall, fresh caches inside `scratch`."""
    if shutil.which("zig") is None:
        raise SystemExit("j2_run: --build needs zig on PATH")
    prefix = scratch / "prefix"
    cmd = ["zig", "build", "-Doptimize=ReleaseSmall", "--prefix", str(prefix),
           "--cache-dir", str(scratch / "zig-local-cache"), "--global-cache-dir", str(scratch / "zig-global-cache")]
    done = subprocess.run(cmd, cwd=ROOT / "zig", capture_output=True, text=True, timeout=540)
    if done.returncode != 0:
        raise SystemExit("j2_run: zig build failed:\n" + done.stderr)
    return prefix / "bin" / "searchd"


class Serve:
    """One `searchd serve` process, one JSON-RPC request per line."""

    def __init__(self, binary: Path, index: Path) -> None:
        self.process = subprocess.Popen([str(binary), "serve", str(index)], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8")
        self.next_id = 0

    def call(self, method: str, params: dict) -> dict:
        self.next_id += 1
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.next_id, "method": method,
                                             "params": params}, ensure_ascii=False) + "\n")
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        if not line:
            raise SystemExit(f"j2_run: searchd closed during {method}: {self.process.stderr.read()[:2000]}")
        reply = json.loads(line)
        if "result" not in reply:
            raise SystemExit(f"j2_run: {method} {params.get('query')!r} failed: {reply.get('error')}")
        return reply["result"]

    def close(self) -> None:
        self.process.stdin.close()
        self.process.wait(timeout=CALL_TIMEOUT_S)
        self.process.stdout.close()
        self.process.stderr.close()


def changes_request(judgments: dict) -> dict:
    request = {"roots": [{"root_id": r, "label": r, "kind": "host"} for r in judgments["roots"]], "changes": []}
    for root in judgments["roots"]:
        base = PACK / root
        for path in sorted(p for p in base.rglob("*") if p.is_file()):
            request["changes"].append({"op": "add", "root_id": root, "path": path.relative_to(base).as_posix(),
                                       "content_base64": base64.b64encode(path.read_bytes()).decode("ascii")})
    return request


def run_searchd(binary: Path, scratch: Path, optimize: str | None) -> dict:
    judgments = json.loads((PACK / "judgments.json").read_text(encoding="utf-8"))
    roots = list(judgments["roots"])
    expected_files = {r: sum(1 for f in judgments["files"] if f["root_id"] == r) for r in roots}
    load_before, sample = j2_load(), top_sample()
    work = Path(tempfile.mkdtemp(prefix="j2-index-", dir=scratch))
    (work / "empty").mkdir()
    (work / "changes.json").write_text(json.dumps(changes_request(judgments)), encoding="utf-8")
    for cmd in ([str(binary), "index", str(work / "empty"), "--out", str(work / "idx"), "--filename-index"],
                [str(binary), "apply", str(work / "idx"), "--changes", str(work / "changes.json")]):
        done = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
        if done.returncode != 0:
            raise SystemExit(f"j2_run: {cmd[1]} failed:\n{done.stdout}\n{done.stderr}")
    serve = Serve(binary, work / "idx")
    try:
        status = serve.call("index_status", {})
        have = {r["root_id"]: r["files"] for r in status["roots"]}
        if {r: have.get(r) for r in roots} != expected_files or have.get("r-legacy", 0) != 0 or set(have) - set(roots) - {"r-legacy"}:
            raise SystemExit(f"j2_run: unexpected roots in the index: {have}")
        probe = serve.call("search_knowledge", {"query": "j2", "top_k": 1, "retrieval_mode": "lexical",
                                                "roots": roots, "search_field": "both"})
        if not probe["retrieval"].get("filename_policy_id"):
            raise SystemExit("j2_run: the index has no file-name channel")

        def strip_root(root_id: str, path: str) -> str:
            return path[len(root_id) + 1:] if path.startswith(root_id + "/") else path

        def knowledge(query: str, field: str) -> list[dict]:
            result = serve.call("search_knowledge", {"query": query, "top_k": J2_TOP_K, "retrieval_mode": "lexical",
                                                     "roots": roots, "search_field": field})
            out = []
            for r in result["results"]:
                score = r["ranking"]["lexical"]["score"] if field == "content" else r["score"]
                out.append({"root_id": r["root_id"], "path": strip_root(r["root_id"], r["citation"]["path"]),
                            "start_line": r["citation"]["start_line"], "end_line": r["citation"]["end_line"],
                            "score": score, "chunk_id": r.get("chunk_id")})
            return out

        def find_page(query: str, mode: str) -> list[dict]:
            result = serve.call("find", {"query": query, "mode": mode, "roots": roots, "page_size": J2_TOP_K})
            return [{"root_id": h["root_id"], "path": h["path"], "start_line": h["start_line"],
                     "end_line": h["end_line"], "score": h["score"], "chunk_id": h.get("chunk_id")}
                    for h in result["hits"]]

        runs = j2_run_queries(judgments, knowledge, find_page)
    finally:
        serve.close()
    shutil.rmtree(work)
    return {
        "schema": J2_RESULTS_SCHEMA,
        "surface": "searchd",
        "judgments_sha256": j2_judgments_sha256(PACK),
        "engine": {"commit": j2_git_head(), **natives_digest(),
                   "binary": {"sha256": sha256_file(binary), "size": binary.stat().st_size,
                              "optimize": optimize or "unknown", "zig": zig_version()},
                   "index": {"roots": status["roots"], "documents": status["documents"],
                             "filename_policy_id": probe["retrieval"]["filename_policy_id"]}},
        "load": {"before": load_before, "after": j2_load(), "top_sample": sample},
        "top_k": J2_TOP_K,
        "runs": runs,
    }


# ---------------------------------------------------------------- compare ---

def _simple_fold_differs(text: str) -> bool:
    for ch in unicodedata.normalize("NFC", text):
        folded = ch.casefold()
        if len(folded) > 1 and ch.lower() != folded:
            return True
    return False


def _file_text(root_id: str, path: str) -> str:
    target = PACK / root_id / path
    return target.read_text(encoding="utf-8", errors="replace") if target.is_file() else ""


def explain(query: str, a: dict, b: dict) -> str:
    """Why two surfaces' top-10 lists for one query differ: analyzer, tie order, near-tie or unexplained.

    Tie order: the two score sequences agree (within f32 rounding) and every rank
    where the hits differ sits in a run of equal scores, or at rank 10 where such
    a run can continue past the cut. Near-tie: the same, with scores that differ
    by less than 1e-5 relative inside a surface."""
    key = lambda h: (h["root_id"], h["path"], h["start_line"], h["end_line"])  # noqa: E731
    ka, kb = [key(h) for h in a["hits"]], [key(h) for h in b["hits"]]
    differing = set(ka) ^ set(kb) | {k for i, k in enumerate(ka) if i >= len(kb) or kb[i] != k}
    if _simple_fold_differs(query) or any(_simple_fold_differs(_file_text(k[0], k[1])) for k in differing):
        return "analyzer (full case fold in the Python reference, simple fold in searchd)"
    sa, sb = [h["score"] for h in a["hits"]], [h["score"] for h in b["hits"]]
    close = lambda x, y, tol: abs(x - y) <= tol * max(abs(x), abs(y), 1e-12)  # noqa: E731
    if len(sa) != len(sb) or not all(close(x, y, 1e-6) for x, y in zip(sa, sb)):
        return "unexplained"
    ranks = [i for i in range(len(ka)) if ka[i] != kb[i]]

    def tied(scores: list[float], i: int, tol: float) -> bool:
        return (i == len(scores) - 1 and len(scores) == J2_TOP_K) or any(
            close(scores[i], scores[j], tol) for j in (i - 1, i + 1) if 0 <= j < len(scores))

    if all(tied(sa, i, 0.0) or tied(sb, i, 0.0) for i in ranks):
        return "tie order (document index in searchd, chunk id in the Python reference)"
    if all(tied(sa, i, 1e-5) or tied(sb, i, 1e-5) for i in ranks):
        return "near-tie (f32 in searchd, f64 in the Python reference)"
    return "unexplained"


def compare(path_a: Path, path_b: Path) -> int:
    a = json.loads(path_a.read_text(encoding="utf-8"))
    b = json.loads(path_b.read_text(encoding="utf-8"))
    if a["judgments_sha256"] != b["judgments_sha256"]:
        print("j2_run: the two runs judge different judgments.json files", file=sys.stderr)
        return 2
    print(f"compare {a['surface']} ({path_a.name}) with {b['surface']} ({path_b.name})")
    key = lambda h: (h["root_id"], h["path"], h["start_line"], h["end_line"])  # noqa: E731
    unexplained = 0
    for variant in J2_VARIANTS:
        qa, qb = a["runs"][variant]["queries"], b["runs"][variant]["queries"]
        rows = []
        for qid in qa:
            ra, rb = qa[qid], qb[qid]
            same_list = [key(h) for h in ra["hits"]] == [key(h) for h in rb["hits"]]
            same_rank = ra.get("first_grade2_rank") == rb.get("first_grade2_rank")
            if same_list and same_rank:
                continue
            why = explain(ra["query"], ra, rb)
            unexplained += why == "unexplained"
            rows.append(f"  {qid:5} {ra['slice']:<11} first grade-2 rank {ra.get('first_grade2_rank')} / "
                        f"{rb.get('first_grade2_rank')}; top 10 {'same' if same_list else 'differs'}: {why}")
        print(f"search_field {variant}: {len(rows)} queries differ")
        print("\n".join(rows) if rows else "  none")
    return 1 if unexplained else 0


# --------------------------------------------------------------- baseline ---

def baseline_runs(results: dict) -> dict:
    out = {}
    for variant, run in results["runs"].items():
        out[variant] = {
            "slices": run["slices"],
            "overall": run["overall"],
            "first_grade2_rank": {qid: r["first_grade2_rank"] for qid, r in run["queries"].items()
                                  if "first_grade2_rank" in r},
            "slice_of": {qid: r["slice"] for qid, r in run["queries"].items()},
            "negatives": run["negatives"],
        }
    return out


def engine_commit(named: str | None) -> str | None:
    """The commit whose engine this is: HEAD, or a named commit whose Zig sources and
    contracts HEAD carries unchanged (checked)."""
    head = j2_git_head()
    if not named:
        return head
    done = subprocess.run(["git", "diff", "--quiet", named, "HEAD", "--", "zig", "contracts"], cwd=ROOT,
                          capture_output=True, text=True, timeout=60)
    if done.returncode != 0:
        raise SystemExit(f"j2_run: zig/ or contracts/ differ between {named} and HEAD")
    full = subprocess.run(["git", "rev-parse", named], cwd=ROOT, capture_output=True, text=True, timeout=60)
    return full.stdout.strip()


def write_baseline(target: Path, searchd: dict, python: dict, engine: str | None) -> None:
    if searchd["judgments_sha256"] != python["judgments_sha256"]:
        raise SystemExit("j2_run: the two surfaces judged different judgments.json files")
    baseline = {
        "schema": BASELINE_SCHEMA,
        "judgments_sha256": searchd["judgments_sha256"],
        "engine_commit": engine,
        "run_commit": searchd["engine"]["commit"],
        "natives_digest": searchd["engine"]["natives_digest"],
        "recorded": datetime.date.today().isoformat(),
        "load": searchd["load"],
        "top_k": J2_TOP_K,
        "surfaces": {
            "searchd": {"binary": searchd["engine"]["binary"], "runs": baseline_runs(searchd)},
            "python-reference": {"python_version": python["engine"]["python_version"],
                                 "hashseed": python["engine"]["hashseed"], "runs": baseline_runs(python)},
        },
    }
    target.write_text(json.dumps(baseline, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--searchd", type=Path, help="the searchd binary (default: $SEARCHD_BINARY)")
    source.add_argument("--build", action="store_true", help="build searchd ReleaseSmall with fresh caches")
    source.add_argument("--compare", nargs=2, type=Path, metavar=("A", "B"))
    parser.add_argument("--optimize", help="the binary's optimize mode, for the record (set by --build)")
    parser.add_argument("--scratch", type=Path, help="where the build and the index go (default: a temporary folder)")
    parser.add_argument("--output", type=Path, help="write the searchd results here")
    parser.add_argument("--write-baseline", type=Path, metavar="BASELINE")
    parser.add_argument("--python-output", type=Path, help="with --write-baseline: write the Python results here")
    parser.add_argument("--engine-commit", help="with --write-baseline: the branch point whose engine HEAD carries unchanged")
    args = parser.parse_args(argv)
    if args.compare:
        return compare(*args.compare)
    scratch_root = args.scratch.resolve() if args.scratch else None
    if scratch_root:
        scratch_root.mkdir(parents=True, exist_ok=True)
    scratch = Path(tempfile.mkdtemp(prefix="j2-run-", dir=scratch_root))
    try:
        optimize = args.optimize
        if args.build:
            binary, optimize = build_searchd(scratch), "ReleaseSmall"
        else:
            env = os.environ.get("SEARCHD_BINARY")
            binary = args.searchd or (Path(env) if env else None)
            if binary is None:
                parser.error("give --searchd PATH, --build or $SEARCHD_BINARY")
        if not binary.is_file():
            parser.error(f"no searchd at {binary}")
        results = run_searchd(binary.resolve(), scratch, optimize)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    for variant, run in results["runs"].items():
        lost = [q for q, r in run["queries"].items() if r["slice"] == "control" and r["first_grade2_rank"] != 1]
        print(f"searchd {variant}: " + ", ".join(f"{n} MRR@10 {m['mrr_at_10']:.3f}" for n, m in run["slices"].items())
              + f"; control rows not at rank 1: {lost or 'none'}")
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(results, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    if args.write_baseline:
        python = run_j2_pack()
        if args.python_output:
            args.python_output.write_text(json.dumps(python, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        write_baseline(args.write_baseline, results, python, engine_commit(args.engine_commit))
        print(f"baseline written: {args.write_baseline}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
