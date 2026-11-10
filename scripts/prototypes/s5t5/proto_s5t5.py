#!/usr/bin/env python3
"""S5-T5 prototype (builder, Phase 1): J2 through the Python reference with each
candidate of ruling 3 installed over `core._query_groups`, judged by the bars of
ruling 5 and by scripts/j2_gate.py against fixtures/j2/baseline.json.

    PYTHONHASHSEED=0 python3 scripts/prototypes/s5t5/proto_s5t5.py [--no-heldout]
        [--candidates today A B C D] [--json OUT]

`today` (fold-groups-v1 as rewritten in verbforms.py) and `today-orig` (core's own
function) must each equal every cell of both surfaces of the baseline; a
mismatch prints BASELINE MISMATCH. `--no-heldout` leaves out the verbform-heldout
rows and their negatives (vhn1, vhn2): the runs made before the builder's own
candidates were declared."""
from __future__ import annotations

import argparse
import importlib.util
import json
import shutil
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import verbforms as V  # noqa: E402

import relevance_smoke as rs  # noqa: E402
import src.search_platform.core as core  # noqa: E402
import src.search_platform.find as findmod  # noqa: E402

ROOT = V.ROOT
PACK = rs.PACKS["j2"]
BASELINE = json.loads((PACK / "baseline.json").read_text(encoding="utf-8"))
spec = importlib.util.spec_from_file_location("j2_gate", ROOT / "scripts" / "j2_gate.py")
j2_gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(j2_gate)

HELDOUT = "verbform-heldout"
MORPH = ("morphology", "morphology-heldout")
SLICES = rs.J2_SLICES
VARIANTS = rs.J2_VARIANTS


def judgments(no_heldout: bool) -> dict:
    j = json.loads((PACK / "judgments.json").read_text(encoding="utf-8"))
    if no_heldout:
        j["queries"] = [q for q in j["queries"] if q["slice"] != HELDOUT and not q["id"].startswith("vhn")]
    return j


def run(name: str | None, j: dict) -> dict:
    """One J2 run as relevance_smoke.run_j2_pack, with candidate `name` installed."""
    V.install(name)
    try:
        with tempfile.TemporaryDirectory() as scratch:
            union = Path(scratch) / "union"
            for root in j["roots"]:
                shutil.copytree(PACK / root, union / root)
            index = core.build_index(union, filename_index=True)

            def split(path):
                root, _, rest = path.partition("/")
                return root, rest

            def knowledge(query, field):
                out = []
                for r in core.search(index, query, top_k=rs.J2_TOP_K, retrieval_mode="lexical", search_field=field,
                                     title_root_ids=j["roots"], fold="FAST"):
                    root, rest = split(r["citation"]["path"])
                    score = r["ranking"]["lexical"]["score"] if field == "content" else r["score"]
                    out.append({"root_id": root, "path": rest, "start_line": r["citation"]["start_line"],
                                "end_line": r["citation"]["end_line"], "score": score, "chunk_id": r.get("chunk_id")})
                return out

            def find_page(query, mode):
                out = []
                for h in findmod.find(index, query, mode=mode, page_size=rs.J2_TOP_K)["hits"]:
                    root, rest = split(h["path"])
                    out.append({"root_id": root, "path": rest, "start_line": h["start_line"], "end_line": h["end_line"],
                                "score": h["score"], "chunk_id": h.get("chunk_id")})
                return out

            runs = rs.j2_run_queries(j, knowledge, find_page)
    finally:
        log = json.loads(json.dumps(V.LOG))
        V.restore()
    return {"schema": rs.J2_RESULTS_SCHEMA, "judgments_sha256": rs.j2_judgments_sha256(PACK), "runs": runs,
            "log": log}


def cells(runs: dict) -> dict:
    out = {}
    for variant, r in runs.items():
        for name, m in list(r["slices"].items()) + [("overall", r["overall"])]:
            for k, v in m.items():
                out[(variant, name, k)] = v
        for q, rec in r["queries"].items():
            if "first_grade2_rank" in rec:
                out[(variant, "rank", q)] = rec["first_grade2_rank"]
        for q, n in r["negatives"].items():
            out[(variant, "neg", q)] = json.dumps(n, sort_keys=True)
    return out


def baseline_check(name: str, result: dict, skip_heldout: bool = False) -> None:
    got = cells(result["runs"])
    for surface in ("searchd", "python-reference"):
        base_runs = BASELINE["surfaces"][surface]["runs"]
        want = {}
        for variant, b in base_runs.items():
            for slc, m in list(b["slices"].items()) + [("overall", b["overall"])]:
                for k, v in m.items():
                    want[(variant, slc, k)] = v
            for q, r in b["first_grade2_rank"].items():
                want[(variant, "rank", q)] = r
            for q, n in b["negatives"].items():
                want[(variant, "neg", q)] = json.dumps(n, sort_keys=True)
        keys = [k for k in want if k in got and not (skip_heldout and k[1] == HELDOUT)]
        diff = [k for k in keys if want[k] != got[k]]
        print(f"{name} vs baseline {surface}: {len(keys)} cells compared, "
              + (f"BASELINE MISMATCH {len(diff)}: {diff[:8]}" if diff else "all equal"))


def kinds(j: dict) -> dict:
    return {q["id"]: q.get("kind") for q in j["queries"]}


def rank1(rec: dict) -> bool:
    return rec.get("success_at_1") == 1.0


def table(results: dict, names: list[str]) -> None:
    for variant in VARIANTS:
        print(f"\n### {variant}: success@1 / MRR@10")
        print("| slice | n | " + " | ".join(names) + " |")
        print("|---|---|" + "---|" * len(names))
        for slc in list(SLICES) + ["overall"]:
            r0 = results[names[0]]["runs"][variant]
            m0 = r0["overall"] if slc == "overall" else r0["slices"][slc]
            if not m0["n"]:
                continue
            row = []
            for n in names:
                r = results[n]["runs"][variant]
                m = r["overall"] if slc == "overall" else r["slices"][slc]
                row.append(f"{m['success_at_1']:.3f} / {m['mrr_at_10']:.3f}")
            print(f"| {slc} | {m0['n']} | " + " | ".join(row) + " |")


def moves(results: dict, name: str) -> list[str]:
    out = []
    for variant in VARIANTS:
        t = results["today"]["runs"][variant]["queries"]
        c = results[name]["runs"][variant]["queries"]
        for q in t:
            if "first_grade2_rank" not in t[q]:
                continue
            a, b = t[q]["first_grade2_rank"], c[q]["first_grade2_rank"]
            if a != b:
                out.append(f"{variant} {q} ({t[q]['slice']}) {a if a else '-'} -> {b if b else '-'}")
    return out


def bars(results: dict, name: str, j: dict) -> dict:
    today, cand = results["today"]["runs"], results[name]["runs"]
    kind = kinds(j)
    out = {}
    out["a"] = {v: cand[v]["slices"]["control"]["success_at_1"] for v in VARIANTS}
    out["a_pass"] = all(x == 1.0 for x in out["a"].values())
    if cand["content"]["slices"][HELDOUT]["n"]:
        failures = []
        for variant in VARIANTS:
            base = BASELINE["surfaces"]["searchd"]["runs"][variant]
            f, _ = j2_gate.judge(cand[variant], base, j2_gate.allowed_ids(None))
            failures += [f"{variant}: {x}" for x in f]
        out["b"] = failures
        out["b_pass"] = not failures
        c = {}
        for variant in VARIANTS:
            s = cand[variant]["slices"][HELDOUT]["success_at_1"]
            guards = {q: cand[variant]["queries"][q]["first_grade2_rank"] for q, k in kind.items() if k == "guard"}
            c[variant] = {"success_at_1": s, "guards": guards,
                          "pass": s >= 0.60 - 1e-9 and all(r == 1 for r in guards.values())}
        out["c"] = c
        out["c_pass"] = c["content"]["pass"]
    lower = []
    for slc in MORPH:
        for variant in VARIANTS:
            for k in ("success_at_1", "mrr_at_10", "ndcg_at_10", "recall_at_5"):
                a, b = today[variant]["slices"][slc][k], cand[variant]["slices"][slc][k]
                if b < a - 1e-9:
                    lower.append(f"{variant} {slc} {k} {a:.3f} -> {b:.3f}")
    gained = 0
    for q, rec in today["content"]["queries"].items():
        if rec["slice"] in MORPH and "success_at_1" in rec:
            gained += int(rank1(cand["content"]["queries"][q])) - int(rank1(rec))
    out["d"] = {"lower": lower, "rank1_gain_content": gained}
    out["d_pass"] = not lower and gained >= 3
    lost = []
    for variant in VARIANTS:
        for q, rec in today[variant]["queries"].items():
            if rec["slice"] in MORPH + (HELDOUT,) or "success_at_1" not in rec:
                continue
            if rank1(rec) and not rank1(cand[variant]["queries"][q]):
                lost.append(f"{variant} {q} ({rec['slice']})")
    out["e"] = lost
    out["e_pass"] = not lost
    return out


def negatives(results: dict, name: str) -> list[str]:
    out = []
    for variant in VARIANTS:
        t = results["today"]["runs"][variant]["negatives"]
        c = results[name]["runs"][variant]["negatives"]
        for q in t:
            a, b = t[q], c[q]
            mark = "" if a == b else "  (moved)"
            top = b["top_hit"]
            where = f"{top['root_id']}/{top['path']}:{top['start_line']}-{top['end_line']}" if top else "none"
            out.append(f"{variant} {q}: {b['returned']} hits, top {where}, named distractor {b['top_is_named_distractor']}{mark}")
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-heldout", action="store_true")
    ap.add_argument("--candidates", nargs="+", default=["today", "A", "B", "C", "D"])
    ap.add_argument("--json", type=Path)
    ap.add_argument("--detail", action="store_true")
    a = ap.parse_args(argv)
    j = judgments(a.no_heldout)
    names = a.candidates if a.candidates[0] == "today" else ["today"] + a.candidates
    results = {}
    results["today-orig"] = run("today-orig", j)
    baseline_check("today-orig", results["today-orig"], a.no_heldout)
    for n in names:
        results[n] = run(n, j)
    baseline_check("today", results["today"], a.no_heldout)
    print(f"queries run: {len(j['queries'])}{' (verbform-heldout and vhn1, vhn2 left out)' if a.no_heldout else ''}")
    table(results, names)
    for n in names[1:]:
        print(f"\n## {n}")
        mv = moves(results, n)
        print(f"first grade-2 rank moves ({len(mv)}):")
        for m in mv:
            print("  " + m)
        b = bars(results, n, j)
        print("bars: " + json.dumps(b, sort_keys=True))
        if a.detail:
            print("verb groups: " + json.dumps(results[n]["log"].get("verb", {}), sort_keys=True))
            print("fuzzy: " + json.dumps(results[n]["log"].get("fuzzy", {}), sort_keys=True))
        print("negatives:")
        for line in negatives(results, n):
            print("  " + line)
    if a.json:
        a.json.write_text(json.dumps(results, indent=1, sort_keys=True), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
