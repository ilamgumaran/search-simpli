#!/usr/bin/env python3
"""S6-T23 Part 1: the judged set before and after, from two `text_search_score.py` JSON files.

    python3 -I compare.py BEFORE.json AFTER.json > compare.md

Prints, per field (`both`, `content`) and form (typed / query): the three totals (all 169, readable now, without
single-source) and every kind, before -> after, for file@1, file@3, file@10, passage@1, passage@10, complete,
complete within 4,096 bytes, answer in its file's first passage, stale copy ranked first, the evidence-bytes median
and the judged-share mean; the no-answer row; then every question that got worse in any configuration, and how.
"Worse" is any of: complete lost, complete within the budget lost, the file rank or the passage rank later (or
lost), a stale copy now ranked first, a no-answer question now returning something, or the judged share lower by
more than 0.005. The direct and index surfaces are compared too; the tables are the direct surface's.
"""
from __future__ import annotations

import json
import sys

FIELDS = ("both", "content")
FORMS = ("typed", "query")
COUNTS = ("file@1", "file@3", "file@10", "passage@1", "passage@10", "complete", "complete_within",
          "first_passage", "stale_first", "not_read")
MEANS = ("evidence_bytes_median", "judged_share_mean")


def val(entry, key):
    v = entry.get(key)
    if isinstance(v, dict):
        return v["hits"]
    return v


def fmt(v):
    if v is None:
        return "–"
    if isinstance(v, float) and v < 1.5:
        return f"{v:.3f}"
    return f"{v:,.0f}" if isinstance(v, (int, float)) else str(v)


def arrow(a, b):
    return fmt(a) if a == b else f"{fmt(a)} → **{fmt(b)}**"


def rank_worse(a, b):
    if a is None:
        return False
    return b is None or b > a


def worse(qb: dict, qa: dict) -> list[str]:
    why = []
    if qb["kind"] == "no-answer":
        if qb["returned"] == 0 and qa["returned"] > 0:
            why.append(f"no-answer now returns {qa['returned']}")
        return why
    if qb["complete"] and not qa["complete"]:
        why.append("complete lost")
    if qb["complete_within"] and not qa["complete_within"]:
        why.append(f"within budget lost ({qb['evidence_bytes']} → {qa['evidence_bytes']} bytes)")
    if rank_worse(qb["file_rank"], qa["file_rank"]):
        why.append(f"file rank {qb['file_rank']} → {qa['file_rank']}")
    if rank_worse(qb["passage_rank"], qa["passage_rank"]):
        why.append(f"passage rank {qb['passage_rank']} → {qa['passage_rank']}")
    if not qb.get("stale_first") and qa.get("stale_first"):
        why.append("stale copy now first")
    jb, ja = qb.get("judged_share"), qa.get("judged_share")
    if jb is not None and ja is not None and ja < jb - 0.005:
        why.append(f"judged share {jb:.3f} → {ja:.3f}")
    return why


def better(qb: dict, qa: dict) -> list[str]:
    if qb["kind"] == "no-answer":
        return []
    why = []
    if not qb["complete"] and qa["complete"]:
        why.append("complete")
    if (qb["file_rank"] is None) and qa["file_rank"] is not None:
        why.append(f"file found at {qa['file_rank']}")
    elif qa["file_rank"] is not None and qb["file_rank"] is not None and qa["file_rank"] < qb["file_rank"]:
        why.append(f"file rank {qb['file_rank']} → {qa['file_rank']}")
    return why


def main(before_path: str, after_path: str) -> int:
    before = json.load(open(before_path, encoding="utf-8"))
    after = json.load(open(after_path, encoding="utf-8"))
    out = ["# Judged set before and after (S6-T23 Part 1 prototype)", "",
           f"Before: `{before['engine']['label']}`, read {before['corpus']['files_read_by_engine']} of "
           f"{before['corpus']['files']} files. After: `{after['engine']['label']}`, read "
           f"{after['corpus']['files_read_by_engine']} of {after['corpus']['files']}.",
           f"Direct = index, before: {before['direct_equals_index']}.",
           f"Direct = index, after: {after['direct_equals_index']}.", "",
           "Cells are typed / query, before → after (bold when they differ). Counts are questions.", ""]
    kinds = list(before["configs"]["direct/both/typed"]["summary"]["per_kind"])
    totals = [("total (169)", lambda s: s["total"]), ("readable now (146)", lambda s: s["total_readable_now"]),
              ("without single-source (116)", lambda s: s["total_without_single_source"])]
    for field in FIELDS:
        sb = {f: before["configs"][f"direct/{field}/{f}"]["summary"] for f in FORMS}
        sa = {f: after["configs"][f"direct/{field}/{f}"]["summary"] for f in FORMS}

        def cells(get, keys):
            return " | ".join(" / ".join(arrow(val(get(sb[f]), k), val(get(sa[f]), k)) for f in FORMS) for k in keys)

        find = ("file@1", "file@3", "file@10", "passage@1", "passage@10", "complete", "not_read")
        tight = ("complete_within", "evidence_bytes_median", "judged_share_mean", "first_passage", "stale_first")
        out += [f"## `--search-field {field}`", "", "Finding:", "",
                "| Total | " + " | ".join(find) + " |", "| --- |" + " ---: |" * len(find)]
        out += [f"| {name} | {cells(get, find)} |" for name, get in totals]
        out += ["", "Tightness and ranking:", "",
                "| Total | " + " | ".join(tight) + " |", "| --- |" + " ---: |" * len(tight)]
        out += [f"| {name} | {cells(get, tight)} |" for name, get in totals]
        per = ("file@1", "file@10", "complete", "complete_within", "not_read")
        out += ["", "Per kind:", "", "| Kind | n | " + " | ".join(per) + " |", "| --- | ---: |" + " ---: |" * len(per)]
        out += [f"| {k} | {sb['typed']['per_kind'][k]['questions']} | {cells(lambda s, k=k: s['per_kind'][k], per)} |"
                for k in kinds if k != "no-answer"]
        out += ["", "No-answer (12), returned anything: " + " / ".join(
            arrow(val(sb[f]["no_answer"], "returned_something"), val(sa[f]["no_answer"], "returned_something"))
            for f in FORMS), ""]
    out += ["## Questions that got worse", "",
            "Per question, every configuration (surface/field/form) in which it got worse and how. Judged-share drops "
            "alone are counted at the end, not listed.", ""]
    grouped, share_only = {}, {}
    for surface in ("direct", "index"):
        for field in FIELDS:
            for form in FORMS:
                key = f"{surface}/{field}/{form}"
                qa = {q["id"]: q for q in after["configs"][key]["questions"]}
                for qb in before["configs"][key]["questions"]:
                    why = worse(qb, qa[qb["id"]])
                    serious = [w for w in why if not w.startswith("judged share")]
                    if serious:
                        grouped.setdefault((qb["id"], qb["kind"]), []).append(
                            f"`{key}`: " + "; ".join(serious) + f"; first paths after {qa[qb['id']]['top_paths'][:2]}")
                    elif why:
                        share_only[key] = share_only.get(key, 0) + 1
    for (qid, kind), lines in grouped.items():
        out.append(f"- **{qid}** ({kind}):")
        out += [f"  - {line}" for line in lines]
    if not grouped:
        out.append("None, in any of the eight configurations.")
    out += ["", "Judged share lower by more than 0.005 and nothing else worse: "
            + ", ".join(f"`{k}` {n}" for k, n in share_only.items()) + "."]
    out += ["", "## Questions that got better (direct surface)", ""]
    for field in FIELDS:
        for form in FORMS:
            key = f"direct/{field}/{form}"
            qa = {q["id"]: q for q in after["configs"][key]["questions"]}
            ids = [f"{qb['id']} ({', '.join(better(qb, qa[qb['id']]))})" for qb in before["configs"][key]["questions"]
                   if better(qb, qa[qb["id"]])]
            out.append(f"- `{key}`, {len(ids)}: " + "; ".join(ids))
    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
