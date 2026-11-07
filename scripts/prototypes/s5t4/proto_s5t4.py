#!/usr/bin/env python3
"""S5-T4 prototype (planner scratch): candidate analyzer-v3 steps on J2 through
the Python reference, index side (rebuild) and query side only (no rebuild),
judged by scripts/j2_gate.py against the committed baseline.

Run from a checkout holding fixtures/j2 at the S5-T3 baseline (main e0d258b or later):
    PYTHONHASHSEED=0 python3 <this dir>/proto_s5t4.py [--only NAME ...] [--detail] [--json OUT]

`today-py` must equal baseline.json's python-reference cells and `today-eng` (the
body folded simply, as analyzer_v2.zig does) its searchd cells; a mismatch is
printed as BASELINE MISMATCH. Every v3 candidate uses one analyzer on both
surfaces, so it is judged against both baselines; "gate" is against searchd's.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import j2run  # noqa: E402
from analyzer_v3 import Cfg, replace  # noqa: E402

ROOT = Path.cwd()
spec = importlib.util.spec_from_file_location("j2_gate", ROOT / "scripts" / "j2_gate.py")
j2_gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(j2_gate)

SLICES = ("control", "misspelling", "morphology", "accent", "tamil", "title", "phrase", "title-heldout",
          "misspelling-heldout")
SHOW = ("control", "misspelling", "morphology", "accent", "tamil", "title", "phrase", "title-heldout",
        "misspelling-heldout")


def grid() -> dict:
    E = Cfg(name="eng", side="index", base_fold="simple")
    g = {"today-py": None, "today-eng": E}
    F = replace(E, fold=True)
    g["F"] = replace(F, name="F")
    g["A"] = replace(E, name="A", accents=True)
    g["FA"] = replace(F, name="FA", accents=True)
    g["P"] = replace(E, name="P", possessive=True)
    g["S"] = replace(E, name="S", plural=True)
    g["PS"] = replace(E, name="PS", possessive=True, plural=True)
    g["D"] = replace(E, name="D", ed=True)
    g["I"] = replace(E, name="I", ing=True)
    g["PSD"] = replace(E, name="PSD", possessive=True, plural=True, ed=True)
    g["PSI"] = replace(E, name="PSI", possessive=True, plural=True, ing=True)
    g["PSID"] = replace(E, name="PSID", possessive=True, plural=True, ing=True, ed=True)
    g["T"] = replace(E, name="T", tamil=True)
    g["FAPS"] = replace(F, name="FAPS", accents=True, possessive=True, plural=True)
    g["FAPSD"] = replace(F, name="FAPSD", accents=True, possessive=True, plural=True, ed=True)
    g["FAPSID"] = replace(F, name="FAPSID", accents=True, possessive=True, plural=True, ing=True, ed=True)
    g["FPSID"] = replace(F, name="FPSID", possessive=True, plural=True, ing=True, ed=True)
    g["FAPSIDT"] = replace(g["FAPSID"], name="FAPSIDT", tamil=True)
    g["FAPST"] = replace(g["FAPS"], name="FAPST", tamil=True)
    g["FAPSID+Wt"] = replace(g["FAPSID"], name="FAPSID+Wt", stop_title=True)
    g["FAPSID+Wi"] = replace(g["FAPSID"], name="FAPSID+Wi", stop_index=True)
    g["FAPSID+Wq"] = replace(g["FAPSID"], name="FAPSID+Wq", stop_query=True)
    g["FAPSIDT+Wt"] = replace(g["FAPSIDT"], name="FAPSIDT+Wt", stop_title=True)
    g["Wt"] = replace(E, name="Wt", stop_title=True)
    g["Wq"] = replace(E, name="Wq", stop_query=True)
    # query side only (no rebuild): the engine's v2 index, the query analysed by v3
    for base in ("FAPSID", "FAPSIDT", "FA", "PSID", "FAPS"):
        for side, tag in (("query-naive", "qN"), ("query-groups", "qG")):
            g[f"{tag}:{base}"] = replace(g[base], name=f"{tag}:{base}", side=side)
    g["FAPSI"] = replace(g["FAPS"], name="FAPSI", ing=True)
    g["FAPSIDk"] = replace(g["FAPSI"], name="FAPSIDk", ed=True, ed_double="keep")
    g["FAPSDk"] = replace(g["FAPS"], name="FAPSDk", ed=True, ed_double="keep")
    g["FAPSIT"] = replace(g["FAPSI"], name="FAPSIT", tamil=True)
    g["FAPSIDkT"] = replace(g["FAPSIDk"], name="FAPSIDkT", tamil=True)
    g["FST"] = replace(F, name="FST", plural=True, tamil=True)
    g["FPST"] = replace(F, name="FPST", possessive=True, plural=True, tamil=True)
    g["FAST"] = replace(F, name="FAST", accents=True, plural=True, tamil=True)
    g["FAPSIkDkT"] = replace(g["FAPSIDkT"], name="FAPSIkDkT", ing_double="keep")
    g["FAPSIkDk"] = replace(g["FAPSIDk"], name="FAPSIkDk", ing_double="keep")
    g["FAPSDkT"] = replace(g["FAPSDk"], name="FAPSDkT", tamil=True)
    g["Dk"] = replace(E, name="Dk", ed=True, ed_double="keep")
    g["FAPST+Wt"] = replace(g["FAPST"], name="FAPST+Wt", stop_title=True)
    g["FAPST+Wq"] = replace(g["FAPST"], name="FAPST+Wq", stop_query=True)
    g["FAPST+Wi"] = replace(g["FAPST"], name="FAPST+Wi", stop_index=True)
    g["FST-noA"] = replace(F, name="FST-noA", plural=True, tamil=True)
    g["qG:FA"] = replace(g["FA"], name="qG:FA", side="query-groups")
    g["qG:T"] = replace(g["T"], name="qG:T", side="query-groups")
    g["qN:T"] = replace(g["T"], name="qN:T", side="query-naive")
    g["qN:S"] = replace(g["S"], name="qN:S", side="query-naive")
    g["qG:S"] = replace(g["S"], name="qG:S", side="query-groups")
    g["qG:PS"] = replace(g["PS"], name="qG:PS", side="query-groups")
    for base in ("FAPST", "FAPSIT", "FAPSIDkT", "FAPSIkDkT", "FAPSDkT"):
        for side, tag in (("query-naive", "qN"), ("query-groups", "qG")):
            g[f"{tag}:{base}"] = replace(g[base], name=f"{tag}:{base}", side=side)
    g["qG:FAPSIDT+Wt"] = replace(g["FAPSIDT+Wt"], name="qG:FAPSIDT+Wt", side="query-groups")
    # the recommended design (no possessive rule) and its two neighbours
    g["FASIDkT"] = replace(g["FAST"], name="FASIDkT", ing=True, ed=True, ed_double="keep")
    for base in ("FAST", "FASIDkT"):
        for side, tag in (("query-naive", "qN"), ("query-groups", "qG")):
            g[f"{tag}:{base}"] = replace(g[base], name=f"{tag}:{base}", side=side)
    return g


def cells(run_v, s):
    return f"{run_v['slices'][s]['success_at_1']:.3f}/{run_v['slices'][s]['mrr_at_10']:.3f}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", nargs="*")
    ap.add_argument("--detail", action="store_true")
    ap.add_argument("--json")
    args = ap.parse_args()
    baseline = json.loads((j2run.PACK / "baseline.json").read_text(encoding="utf-8"))
    bases = {"py": baseline["surfaces"]["python-reference"]["runs"], "eng": baseline["surfaces"]["searchd"]["runs"]}
    cands = grid()
    names = [n for n in cands if not args.only or n in args.only or n.startswith("today")]
    results = {n: j2run.run(cands[n]) for n in names}
    for tag, surf in (("today-py", "py"), ("today-eng", "eng")):
        for v in ("content", "both"):
            mine = results[tag]["runs"][v]
            for qid, r in bases[surf][v]["first_grade2_rank"].items():
                if mine["queries"][qid].get("first_grade2_rank") != r:
                    print(f"BASELINE MISMATCH {tag} {v} {qid}", file=sys.stderr)
            for sl, m in bases[surf][v]["slices"].items():
                if {k: mine["slices"][sl][k] for k in m} != m:
                    print(f"BASELINE MISMATCH {tag} {v} slice {sl}", file=sys.stderr)
    print("candidate | variant | " + " | ".join(SHOW) + " | overall | gate vs searchd | gate vs python")
    summary = {}
    for name in names:
        summary[name] = {}
        for v in ("content", "both"):
            rv = results[name]["runs"][v]
            fe, _ = j2_gate.judge(rv, bases["eng"][v], {})
            fp, _ = j2_gate.judge(rv, bases["py"][v], {})
            o = rv["overall"]
            print(f"{name} | {v} | " + " | ".join(cells(rv, s) for s in SHOW)
                  + f" | {o['success_at_1']:.3f}/{o['mrr_at_10']:.3f} | "
                  + ("pass" if not fe else "FAIL " + "; ".join(fe)) + " | " + ("pass" if not fp else "FAIL " + "; ".join(fp)))
            moves = {}
            for qid, r in rv["queries"].items():
                if "first_grade2_rank" not in r:
                    continue
                b = bases["eng"][v]["first_grade2_rank"][qid]
                if r["first_grade2_rank"] != b:
                    moves[qid] = [b, r["first_grade2_rank"]]
            negs = {}
            for qid, r in rv["negatives"].items():
                b = bases["eng"][v]["negatives"][qid]
                if (b["top_hit"], b["returned"]) != (r["top_hit"], r["returned"]):
                    negs[qid] = {"before": [b["returned"], b["top_hit"] and b["top_hit"]["path"]],
                                 "after": [r["returned"], r["top_hit"] and r["top_hit"]["path"], r["top_hit_grade"],
                                           r["top_is_named_distractor"]]}
            summary[name][v] = {"slices": {s: [rv["slices"][s]["success_at_1"], rv["slices"][s]["mrr_at_10"]] for s in SLICES},
                                "overall": [o["success_at_1"], o["mrr_at_10"]], "gate_eng": fe, "gate_py": fp,
                                "moves": moves, "negatives": negs}
        summary[name]["log"] = {k: dict(sorted(v.items())) for k, v in results[name]["log"].items()}
    if args.detail:
        for name in names:
            for v in ("content", "both"):
                mv = summary[name][v]["moves"]
                print(f"MOVES {name} {v} " + " ".join(f"{q}:{a}->{b}" for q, (a, b) in sorted(mv.items())))
                for q, n in sorted(summary[name][v]["negatives"].items()):
                    print(f"NEG {name} {v} {q} {n['before']} -> {n['after']}")
            for k, d in summary[name]["log"].items():
                print(f"{k.upper()} {name} " + json.dumps(d, ensure_ascii=False, sort_keys=True))
    if args.json:
        Path(args.json).write_text(json.dumps(summary, ensure_ascii=False, indent=1, sort_keys=True))


if __name__ == "__main__":
    main()
