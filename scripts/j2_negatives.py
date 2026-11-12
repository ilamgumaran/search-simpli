#!/usr/bin/env python3
"""S5-T8: the measure of what misleads, on J2's negatives (fixtures/j2/README.md,
"What counts as misleading").

  j2_negatives.py RUN.json [RUN.json ...] [--json OUT] [--detail]

Each RUN.json is a J2 results file (`scripts/j2_run.py --output` for searchd,
`--python-output` or `relevance_smoke.py` for the Python reference): it holds each
query's first ten hits. For every negative (slices `negatives`, `negatives-tuning`,
`negatives-heldout`) each of its first five hits is labelled real, cross, near or
stop (or other, when nothing of the query matches it), and the measure is printed
per set and variant: the mean top-5 hit count, the share of queries whose first hit
is misleading (stop, near or cross), the mean misleading and the mean real-word hits
in the first five.

The labels read the query's groups as the Python reference makes them: this script
builds the reference index of the fixture and calls `core.search` once per negative
and variant with `core._query_groups` watched, so whatever group function is
installed (today's, or a rule under test) is the one read. A searchd run is labelled
with the reference's groups; the two equal each other on J2 (the fuzzy, analyzer-v3
and verb-form goldens), and a searchd hit is mapped to the reference chunk with the
same lines (or, failing that, to the words of its lines).

`measure()` and `capture()` are the parts a prototype calls in process.
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

import src.search_platform.core as core  # noqa: E402
from relevance_smoke import J2_TOP_K, J2_VARIANTS, PACKS, j2_judgments_sha256  # noqa: E402
from src.search_platform import analyzer_v3, verb_forms  # noqa: E402

PACK = PACKS["j2"]
NEGATIVE_SETS = ("negatives", "negatives-tuning", "negatives-heldout")
TOP = 5
LABELS = ("real", "cross", "near", "stop", "other")
MISLEADING = ("cross", "near", "stop")
FOLD = "FAST"


def load_judgments() -> dict:
    return json.loads((PACK / "judgments.json").read_text(encoding="utf-8"))


def negatives(judgments: dict) -> list[dict]:
    return [q for q in judgments["queries"] if q.get("negative") and q["slice"] in NEGATIVE_SETS]


def build(judgments: dict, scratch: Path) -> dict:
    """The Python reference index of the fixture, as `relevance_smoke.run_j2_pack` builds it."""
    union = scratch / "union"
    for root in judgments["roots"]:
        shutil.copytree(PACK / root, union / root)
    return core.build_index(union, filename_index=True)


def capture(index: dict, judgments: dict, queries: list[dict] | None = None) -> dict:
    """{variant: {query id: {"terms": [...], "groups": {term: [member, ...]}}}}, read
    from the group function installed now, as `core.search` calls it."""
    queries = negatives(judgments) if queries is None else queries
    out: dict = {variant: {} for variant in J2_VARIANTS}
    inner = core._query_groups
    seen: list = []

    def watch(*args, **kwargs):
        groups = inner(*args, **kwargs)
        terms = args[2] if len(args) > 2 else kwargs["terms"]
        seen.append((list(terms), groups))
        return groups

    core._query_groups = watch
    try:
        for q in queries:
            for variant in J2_VARIANTS:
                seen.clear()
                core.search(index, q["query"], top_k=J2_TOP_K, retrieval_mode="lexical", search_field=variant,
                            title_root_ids=judgments["roots"], fold=FOLD)
                terms: list[str] = []
                groups: dict = {}
                for t, g in seen:
                    terms += [x for x in t if x not in terms]
                    for term, members in g.items():
                        have = groups.setdefault(term, [])
                        have += [m for m, _ in members if m not in have]
                out[variant][q["id"]] = {"terms": terms, "groups": groups}
    finally:
        core._query_groups = inner
    return out


def hit_words(index: dict, judgments: dict) -> callable:
    """A function from a hit to its words: the body words of the reference chunk with
    the same lines (else of its lines) and its file's title words."""
    roots = tuple(judgments["roots"])
    chunks = {(c["path"], c["start_line"], c["end_line"]): c for c in index["chunks"]}
    titles = core._title_fields(index["chunks"], roots)

    def words(hit: dict) -> set[str]:
        path = f"{hit['root_id']}/{hit['path']}"
        chunk = chunks.get((path, hit["start_line"], hit["end_line"]))
        if chunk is not None:
            body = set(chunk["terms"])
        else:
            lines = (PACK / path).read_text(encoding="utf-8").splitlines()
            text = "\n".join(lines[hit["start_line"] - 1:hit["end_line"]])
            body = set(core.tokenize(text)) | set(core._filename_tokenize(text))
        return body | set(titles.get(path, ()))

    return words


def label(held: set[str], terms: list[str], groups: dict, stop: set[str], verdicts: dict) -> tuple[str, list]:
    """The hit's label, and every (query word, matched word, label) behind it."""
    found = []
    for term in terms:
        members = [term] + [m for m in groups.get(term, ()) if m != term]
        for member in members:
            if member not in held:
                continue
            if term in stop:
                kind = "stop"
            elif member == term or analyzer_v3.key(member, FOLD) == analyzer_v3.key(term, FOLD):
                kind = "real"
            elif member in verb_forms.forms(term):
                verdict = verdicts.get(term, {}).get(member)
                if verdict not in ("same", "cross"):
                    raise SystemExit(f"j2_negatives: {term} -> {member} is a verb form with no verdict in "
                                     "judgments.json verb_form_judgments")
                kind = "real" if verdict == "same" else "cross"
            else:
                kind = "near"
            found.append((term, member, kind))
    kinds = {k for _, _, k in found}
    return next((k for k in LABELS if k in kinds), "other"), found


def measure(results: dict, judgments: dict, groups: dict, words) -> dict:
    """Per variant and set: the measure; per variant and query: the labels."""
    stop = set(judgments["stop_words"])
    verdicts = judgments["verb_form_judgments"]
    out: dict = {"sets": {}, "queries": {}}
    for variant in J2_VARIANTS:
        records = results["runs"][variant]["queries"]
        per_query = {}
        for q in negatives(judgments):
            g = groups[variant][q["id"]]
            labelled = []
            for hit in records[q["id"]]["hits"][:TOP]:
                kind, found = label(words(hit), g["terms"], g["groups"], stop, verdicts)
                labelled.append({"hit": f"{hit['root_id']}/{hit['path']}:{hit['start_line']}-{hit['end_line']}",
                                 "label": kind, "matches": [list(f) for f in found]})
            per_query[q["id"]] = {"slice": q["slice"], "kind": q.get("kind"), "query": q["query"],
                                  "returned": records[q["id"]]["returned"], "hits": labelled}
        out["queries"][variant] = per_query
        sets = {}
        for name in NEGATIVE_SETS:
            items = [r for r in per_query.values() if r["slice"] == name]
            if not items:
                continue
            n = len(items)
            first = [r["hits"][0]["label"] if r["hits"] else None for r in items]
            sets[name] = {
                "n": n,
                "mean_top5": round(sum(min(r["returned"], TOP) for r in items) / n, 6),
                "misleading_first_share": round(sum(1 for f in first if f in MISLEADING) / n, 6),
                "mean_misleading_top5": round(sum(sum(1 for h in r["hits"] if h["label"] in MISLEADING)
                                                  for r in items) / n, 6),
                "mean_real_top5": round(sum(sum(1 for h in r["hits"] if h["label"] == "real") for r in items) / n, 6),
                "first_hit_labels": {k: c for k in LABELS + ("none",)
                                     if (c := sum(1 for f in first if (f or "none") == k))},
                "top5_labels": {k: c for k in LABELS
                                if (c := sum(1 for r in items for h in r["hits"] if h["label"] == k))},
            }
        out["sets"][variant] = sets
    return out


def print_measure(name: str, m: dict, detail: bool) -> None:
    for variant in J2_VARIANTS:
        print(f"\n{name} [{variant}]")
        print("| set | n | mean top-5 hits | misleading first | mean misleading in top 5 | mean real in top 5 "
              "| first-hit labels |")
        print("|---|---|---|---|---|---|---|")
        for set_name, s in m["sets"][variant].items():
            labels = ", ".join(f"{k} {v}" for k, v in s["first_hit_labels"].items())
            print(f"| {set_name} | {s['n']} | {s['mean_top5']:.3f} | {s['misleading_first_share']:.3f} | "
                  f"{s['mean_misleading_top5']:.3f} | {s['mean_real_top5']:.3f} | {labels} |")
        if detail:
            for qid, r in m["queries"][variant].items():
                labels = " ".join(h["label"] for h in r["hits"]) or "-"
                print(f"  {qid:5} {r['kind'] or '-':<10} {r['query']!r}: {r['returned']} hits; top 5: {labels}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("runs", nargs="+", type=Path)
    parser.add_argument("--json", type=Path)
    parser.add_argument("--detail", action="store_true")
    args = parser.parse_args(argv)
    judgments = load_judgments()
    with tempfile.TemporaryDirectory() as scratch:
        index = build(judgments, Path(scratch))
        groups = capture(index, judgments)
        words = hit_words(index, judgments)
        out = {}
        for path in args.runs:
            results = json.loads(path.read_text(encoding="utf-8"))
            if results["judgments_sha256"] != j2_judgments_sha256(PACK):
                raise SystemExit(f"j2_negatives: {path.name} judged another judgments.json")
            name = results.get("surface", path.name)
            out[name] = measure(results, judgments, groups, words)
            print_measure(name, out[name], args.detail)
    if args.json:
        args.json.write_text(json.dumps(out, indent=1, sort_keys=True, ensure_ascii=False) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
