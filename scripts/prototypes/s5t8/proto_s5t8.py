#!/usr/bin/env python3
"""S5-T8 prototype (builder, Phase 1b): J2 through the Python reference with each
candidate of ruling 2 installed (rules.py), judged by the bars of ruling 3, by
scripts/j2_gate.py against fixtures/j2/baseline.json, and by the measure of what
misleads (scripts/j2_negatives.py).

    PYTHONHASHSEED=0 python3 scripts/prototypes/s5t8/proto_s5t8.py [--no-heldout]
        [--candidates W Wb F X W+Wb ...] [--json OUT] [--detail]

`today` (core's own functions) and `rewrite` (`_fold_groups` rewritten in rules.py)
must each equal every cell of both surfaces of the baseline; a mismatch prints
BASELINE MISMATCH. `--no-heldout` leaves out every held-out row: the six *-heldout
slices, the negatives of those slices and `negatives-heldout` (the runs made before
every candidate was declared)."""
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

import rules as R  # noqa: E402

import relevance_smoke as rs  # noqa: E402
import src.search_platform.core as core  # noqa: E402
import src.search_platform.find as findmod  # noqa: E402

ROOT = R.ROOT
PACK = rs.PACKS["j2"]
BASELINE = json.loads((PACK / "baseline.json").read_text(encoding="utf-8"))


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


j2_gate = _load("j2_gate", ROOT / "scripts" / "j2_gate.py")
NEG = _load("j2_negatives", ROOT / "scripts" / "j2_negatives.py")

SLICES = rs.J2_SLICES
VARIANTS = rs.J2_VARIANTS
GUARDED = ("misspelling-heldout", "morphology-heldout", "verbform-heldout")
METRICS = ("success_at_1", "mrr_at_10", "ndcg_at_10", "recall_at_5")


def held_out(q: dict) -> bool:
    return (q["slice"].endswith("-heldout") or str(q.get("negative_of") or "").endswith("-heldout"))


def judgments(no_heldout: bool) -> dict:
    j = json.loads((PACK / "judgments.json").read_text(encoding="utf-8"))
    if no_heldout:
        j["queries"] = [q for q in j["queries"] if not held_out(q)]
    return j


def run(name: str, j: dict) -> dict:
    """One J2 run as relevance_smoke.run_j2_pack, with candidate `name` installed,
    and the measure of what misleads read with the same candidate installed."""
    R.install(name)
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
            result = {"schema": rs.J2_RESULTS_SCHEMA, "judgments_sha256": rs.j2_judgments_sha256(PACK),
                      "runs": runs}
            groups = NEG.capture(index, j)
            measure = NEG.measure(result, j, groups, NEG.hit_words(index, j))
    finally:
        log = json.loads(json.dumps(R.LOG))
        R.restore()
    result["measure"] = measure
    result["log"] = log
    return result


def cells(runs: dict) -> dict:
    out = {}
    for variant, r in runs.items():
        for name, m in list(r["slices"].items()) + [("overall", r["overall"])]:
            if not m["n"]:
                continue
            for k, v in m.items():
                out[(variant, name, k)] = v
        for q, rec in r["queries"].items():
            if "first_grade2_rank" in rec:
                out[(variant, "rank", q)] = rec["first_grade2_rank"]
        for q, n in r["negatives"].items():
            out[(variant, "neg", q)] = json.dumps(n, sort_keys=True)
    return out


def baseline_check(name: str, result: dict) -> None:
    got = cells(result["runs"])
    for surface in ("searchd", "python-reference"):
        want = {}
        for variant, b in BASELINE["surfaces"][surface]["runs"].items():
            for slc, m in list(b["slices"].items()) + [("overall", b["overall"])]:
                for k, v in m.items():
                    want[(variant, slc, k)] = v
            for q, r in b["first_grade2_rank"].items():
                want[(variant, "rank", q)] = r
            for q, n in b["negatives"].items():
                want[(variant, "neg", q)] = json.dumps(n, sort_keys=True)
        keys = [k for k in want if k in got]
        diff = [k for k in keys if want[k] != got[k]]
        print(f"{name} vs baseline {surface}: {len(keys)} cells compared, "
              + (f"BASELINE MISMATCH {len(diff)}: {diff[:8]}" if diff else "all equal"))


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
        print(f"\n### {variant}: negatives, mean top-5 hits / misleading first / mean misleading in top 5 / "
              "mean real in top 5")
        print("| set | n | " + " | ".join(names) + " |")
        print("|---|---|" + "---|" * len(names))
        for set_name in NEG.NEGATIVE_SETS:
            s0 = results[names[0]]["measure"]["sets"][variant].get(set_name)
            if not s0:
                continue
            row = []
            for n in names:
                s = results[n]["measure"]["sets"][variant][set_name]
                row.append(f"{s['mean_top5']:.3f} / {s['misleading_first_share']:.3f} / "
                           f"{s['mean_misleading_top5']:.3f} / {s['mean_real_top5']:.3f}")
            print(f"| {set_name} | {s0['n']} | " + " | ".join(row) + " |")


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
    out: dict = {}
    out["a"] = {v: {s: cand[v]["slices"][s]["success_at_1"] for s in ("control", "precision-control")}
                for v in VARIANTS}
    out["a_pass"] = all(x == 1.0 for v in out["a"].values() for x in v.values())
    if any(held_out(q) for q in j["queries"]):
        failures = []
        for variant in VARIANTS:
            base = BASELINE["surfaces"]["searchd"]["runs"][variant]
            f, _ = j2_gate.judge(cand[variant], base, j2_gate.allowed_ids(None))
            failures += [f"{variant}: {x}" for x in f]
        out["b"] = failures
        out["b_pass"] = not failures
    else:
        out["b"] = "not run (the gate reads every row; --no-heldout leaves the held-out rows out)"
    lost, lower = [], []
    for variant in VARIANTS:
        for q, rec in today[variant]["queries"].items():
            if rec.get("first_grade2_rank") == 1 and cand[variant]["queries"][q]["first_grade2_rank"] != 1:
                lost.append(f"{variant} {q} ({rec['slice']})")
        for slc in GUARDED:
            if not today[variant]["slices"][slc]["n"]:
                continue
            for k in METRICS:
                a, b = today[variant]["slices"][slc][k], cand[variant]["slices"][slc][k]
                if b < a - 1e-9:
                    lower.append(f"{variant} {slc} {k} {a:.3f} -> {b:.3f}")
    out["c"] = {"rank1_lost": lost, "guarded_lower": lower}
    # Phase 1c's decision rule: no rank-1 answer of misspelling-short lost against today.
    out["short_rank1_lost"] = [x for x in lost if "(misspelling-short)" in x]
    out["short_pass"] = not out["short_rank1_lost"]
    out["c_pass"] = not lost and not lower
    d = {}
    for variant in VARIANTS:
        t = results["today"]["measure"]["sets"][variant].get("negatives-heldout")
        c = results[name]["measure"]["sets"][variant].get("negatives-heldout")
        if not t:
            continue
        d[variant] = {"misleading_first": [t["misleading_first_share"], c["misleading_first_share"]],
                      "mean_top5": [t["mean_top5"], c["mean_top5"]],
                      "pass": c["misleading_first_share"] < t["misleading_first_share"] - 1e-9
                      and c["mean_top5"] <= t["mean_top5"] + 1e-9}
    out["d"] = d
    out["d_pass"] = bool(d) and all(x["pass"] for x in d.values())
    out["f_moves"] = moves(results, name)
    return out


def negatives_lines(results: dict, name: str) -> list[str]:
    out = []
    for variant in VARIANTS:
        t = results["today"]["measure"]["queries"][variant]
        c = results[name]["measure"]["queries"][variant]
        for q, rec in c.items():
            a = " ".join(h["label"] for h in t[q]["hits"]) or "-"
            b = " ".join(h["label"] for h in rec["hits"]) or "-"
            if a != b or t[q]["returned"] != rec["returned"]:
                out.append(f"{variant} {q} ({rec['slice']}, {rec['kind'] or '-'}) {rec['query']!r}: "
                           f"{t[q]['returned']} hits [{a}] -> {rec['returned']} hits [{b}]")
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-heldout", action="store_true")
    ap.add_argument("--candidates", nargs="+", default=["W", "Wb", "X"])
    ap.add_argument("--json", type=Path)
    ap.add_argument("--detail", action="store_true")
    a = ap.parse_args(argv)
    j = judgments(a.no_heldout)
    names = ["today"] + [n for n in a.candidates if n != "today"]
    results = {}
    for n in ["rewrite"] + names:
        results[n] = run(n, j)
    baseline_check("today", results["today"])
    baseline_check("rewrite", results["rewrite"])
    print(f"queries run: {len(j['queries'])}" + (" (every held-out row left out)" if a.no_heldout else ""))
    table(results, names)
    for n in names[1:]:
        print(f"\n## {n}")
        b = bars(results, n, j)
        print(f"first grade-2 rank moves ({len(b['f_moves'])}):")
        for m in b["f_moves"]:
            print("  " + m)
        print("bars: " + json.dumps({k: v for k, v in b.items() if k != "f_moves"}, sort_keys=True))
        print("negatives that moved:")
        for line in negatives_lines(results, n):
            print("  " + line)
        if a.detail:
            print("log: " + json.dumps(results[n]["log"], sort_keys=True, ensure_ascii=False)[:4000])
    if a.json:
        a.json.write_text(json.dumps(results, indent=1, sort_keys=True, ensure_ascii=False), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
