#!/usr/bin/env python3
"""S6-T4 Phase 1: tables from bench.py's rows.

    python3 -I summarize.py RUN1.jsonl [RUN2.jsonl ...]

Prints, per corpus, one Markdown row per variant: open p50; memory after
open and after the query set (footprint growth over the process before
`ss_open`, MB = 10^6 B); the sum over the field's queries of each query's
warm p50 for `content`, `filename`, `both`; the sum of the finds' p50; the
first query and the first find after an open (p50). A cell shows each run's
value separated by " / ". Then, per corpus and run, the largest per-cell
difference from `today` (per query and field, per find) for every variant,
and the loads the rows recorded. All times in ms.
"""

from __future__ import annotations

import json
import sys
from collections import defaultdict
from pathlib import Path

ORDER = ["today", "today-b", "eager-v3", "lazy-nocache", "lazy-1mib", "lazy-keep", "lazy-all", "lazy-checked"]


def corpus_of(row: dict) -> str:
    return Path(row["index"]).name


def field_sum(row: dict, field: str) -> float | None:
    values = [w["p50_ms"] for w in row["warm"] if w["field"] == field]
    return sum(values) if values else None


def cells(row: dict) -> dict:
    out = {(w["field"], w["query"]): w["p50_ms"] for w in row["warm"]}
    out.update({("find:" + f["mode"], f["query"]): f["p50_ms"] for f in row["find"]})
    return out


def fmt(values, digits=2) -> str:
    return " / ".join("–" if v is None else f"{v:.{digits}f}" for v in values)


def main() -> int:
    runs = []
    for path in sys.argv[1:]:
        rows = [json.loads(line) for line in Path(path).read_text(encoding="utf-8").splitlines() if line.strip()]
        runs.append(rows)
    corpora = []
    for rows in runs:
        for row in rows:
            if corpus_of(row) not in corpora:
                corpora.append(corpus_of(row))
    for corpus in corpora:
        by_variant = defaultdict(list)
        for rows in runs:
            found = {r["variant"]: r for r in rows if corpus_of(r) == corpus}
            for variant in ORDER:
                by_variant[variant].append(found.get(variant))
        print(f"\n### {corpus}\n")
        print("| Variant | Open p50 | Memory after open (MB) | after queries (MB) | content Σ | filename Σ | both Σ | find Σ | first query | first find |")
        print("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
        for variant in ORDER:
            rs = by_variant[variant]
            if not any(rs):
                continue
            g = lambda f: [None if r is None else f(r) for r in rs]  # noqa: E731
            print(f"| {variant} | {fmt(g(lambda r: r['open']['p50_ms']))} "
                  f"| {fmt(g(lambda r: r['memory']['open_delta'] / 1e6), 1)} "
                  f"| {fmt(g(lambda r: r['memory']['queries_delta'] / 1e6), 1)} "
                  f"| {fmt(g(lambda r: field_sum(r, 'content')), 3)} "
                  f"| {fmt(g(lambda r: field_sum(r, 'filename')), 3)} "
                  f"| {fmt(g(lambda r: field_sum(r, 'both')), 3)} "
                  f"| {fmt(g(lambda r: sum(f['p50_ms'] for f in r['find'])), 3)} "
                  f"| {fmt(g(lambda r: r['first_query']['p50_ms']), 3)} "
                  f"| {fmt(g(lambda r: r['first_find']['p50_ms']), 3)} |")
        print()
        for index, rows in enumerate(runs, 1):
            found = {r["variant"]: r for r in rows if corpus_of(r) == corpus}
            if "today" not in found:
                continue
            base = cells(found["today"])
            loads = [r["load_before"][1] for r in found.values()] + [r["load_after"][1] for r in found.values()]
            print(f"Run {index}: 5-minute load {min(loads):.2f}–{max(loads):.2f}.")
            for variant in ORDER[1:]:
                if variant not in found:
                    continue
                mine = cells(found[variant])
                diffs = {k: mine[k] - base[k] for k in base if k in mine}
                worst = max(diffs.items(), key=lambda kv: kv[1])
                best = min(diffs.items(), key=lambda kv: kv[1])
                answers_same = all(
                    a["answer_sha256"] == b["answer_sha256"]
                    for a, b in zip(found[variant]["warm"] + found[variant]["find"],
                                    found["today"]["warm"] + found["today"]["find"]))
                print(f"- `{variant}` − `today`: largest +{worst[1]:.4f} ms ({worst[0][0]} `{worst[0][1]}`), "
                      f"smallest {best[1]:+.4f} ms ({best[0][0]} `{best[0][1]}`); answers "
                      f"{'identical' if answers_same else 'DIFFER'}")
            print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
