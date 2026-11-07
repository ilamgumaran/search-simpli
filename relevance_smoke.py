#!/usr/bin/env python3
"""Build a local index, evaluate graded relevance, and enforce smoke gates."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
import tempfile
import time
from pathlib import Path

from src.search_platform.core import (
    build_index,
    load_index,
    outline,
    read_span,
    save_index,
    search,
)
from src.search_platform.evaluation import (
    RETRIEVAL_MODES,
    discounted_cumulative_gain,
    evaluate_modes,
    load_suite,
)
from src.search_platform.folders import FolderIndex, add_change, folder_changes
from src.search_platform.find import find, find_all
from src.search_platform.providers import (
    DEFAULT_FASTEMBED_MODEL,
    FastEmbedProvider,
    ProviderError,
    provider_from_index,
)


PROFILE_VERSION = 1
METRICS = {
    "ndcg": "mean_ndcg_at_k",
    "mrr": "mean_reciprocal_rank",
    "recall": "macro_recall_at_k",
    "success": "success_at_k",
}


def profile_id(index: dict, suite_path: Path, modes: list[str], top_k: int) -> str:
    identity = {
        "profile_version": PROFILE_VERSION,
        "suite_sha256": hashlib.sha256(suite_path.read_bytes()).hexdigest(),
        "sources": index["source_files"],
        "vector_mode": index.get("vector_mode", "none"),
        "embedding": index.get("embedding"),
        "modes": modes,
        "top_k": top_k,
    }
    encoded = json.dumps(identity, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def gate_failures(
    report: dict,
    minima: dict[str, float],
    *,
    baseline: dict | None = None,
    max_regression: float = 0.0,
) -> list[str]:
    failures = []
    reports = {item["mode"]: item for item in report["evaluation"]["reports"]}
    for mode, current in reports.items():
        for name, minimum in minima.items():
            key = METRICS[name]
            if current[key] < minimum:
                failures.append(
                    f"{mode} {key}={current[key]:.6f} is below minimum {minimum:.6f}"
                )
    if baseline is not None:
        if baseline.get("profile_id") != report.get("profile_id"):
            raise ValueError("baseline profile_id does not match corpus, suite, modes, and top_k")
        baseline_reports = {
            item["mode"]: item for item in baseline["evaluation"]["reports"]
        }
        for mode, current in reports.items():
            if mode not in baseline_reports:
                raise ValueError(f"baseline has no report for mode {mode!r}")
            for key in METRICS.values():
                allowed = baseline_reports[mode][key] - max_regression
                if current[key] < allowed:
                    failures.append(
                        f"{mode} {key}={current[key]:.6f} regressed below "
                        f"baseline {baseline_reports[mode][key]:.6f} minus {max_regression:.6f}"
                    )
    return failures


def run_smoke(
    corpus: Path,
    suite_path: Path,
    *,
    modes: list[str],
    vector_mode: str,
    top_k: int,
    minima: dict[str, float],
    baseline: dict | None = None,
    max_regression: float = 0.0,
    model: str = DEFAULT_FASTEMBED_MODEL,
    model_cache: Path = Path(".search/models"),
    index_path: Path | None = None,
    save_index_path: Path | None = None,
) -> dict:
    if index_path is not None:
        build_started = time.perf_counter()
        index = load_index(index_path)
        build_ms = (time.perf_counter() - build_started) * 1_000.0
        if index.get("root") != str(corpus.expanduser().resolve()):
            raise ValueError("prebuilt index root does not match the smoke corpus")
        vector_mode = index.get("vector_mode", "none")
        provider = (
            provider_from_index(index, cache_dir=model_cache)
            if vector_mode == "neural" and any(mode in {"vector", "hybrid"} for mode in modes)
            else None
        )
        index_source = "prebuilt"
    else:
        provider = (
            FastEmbedProvider(model_name=model, cache_dir=model_cache)
            if vector_mode == "neural"
            else None
        )
        build_started = time.perf_counter()
        index = build_index(corpus, vector_mode=vector_mode, embedding_provider=provider)
        build_ms = (time.perf_counter() - build_started) * 1_000.0
        if save_index_path is not None:
            save_index(index, save_index_path)
        index_source = "built"
    suite = load_suite(suite_path)
    evaluation_started = time.perf_counter()
    evaluation = evaluate_modes(
        index, suite, modes, top_k=top_k, embedding_provider=provider
    )
    evaluation_ms = (time.perf_counter() - evaluation_started) * 1_000.0
    report = {
        "profile_version": PROFILE_VERSION,
        "profile_id": profile_id(index, suite_path, modes, top_k),
        "corpus": str(corpus.resolve()),
        "suite": str(suite_path.resolve()),
        "vector_mode": vector_mode,
        "index_source": index_source,
        "index_path": (
            str((index_path or save_index_path).resolve())
            if (index_path or save_index_path)
            else None
        ),
        "timing_ms": {"build": build_ms, "evaluation": evaluation_ms},
        "evaluation": evaluation,
    }
    failures = gate_failures(
        report,
        minima,
        baseline=baseline,
        max_regression=max_regression,
    )
    report["gate"] = {
        "minima": minima,
        "baseline_profile_id": baseline.get("profile_id") if baseline else None,
        "max_absolute_regression": max_regression if baseline else None,
        "passed": not failures,
        "failures": failures,
    }
    return report


PACKS = {
    "family-folder": Path(__file__).resolve().parent / "fixtures" / "family-folder",
    "j2": Path(__file__).resolve().parent / "fixtures" / "j2",
}
PACK_WORDS_GATE = 0.9
# Case kinds the Python reference answers since S3-T2 (`find`): judged for precision
# and recall across all pages after overlap deduplication; listed engine misses
# must be missed.
FIND_KINDS = ("phrase", "prefix")
# Case kinds the Python reference answers since S3-T1 (outline from md-section-v1,
# read_span from the original bytes); judged for exactness, not recall.
EXACT_KINDS = ("outline", "read_span")


def _overlaps(hit: dict, expected: dict) -> bool:
    return (
        hit["path"] == f"{expected['root_id']}/{expected['path']}"
        and hit["start_line"] <= expected["end_line"]
        and expected["start_line"] <= hit["end_line"]
    )


def _hit_overlaps(hit: dict, expected: dict) -> bool:
    return (hit["root_id"] == expected["root_id"] and hit["path"] == expected["path"]
            and hit["start_line"] <= expected["end_line"] and expected["start_line"] <= hit["end_line"])


def run_lifecycle(pack_dir: Path, roots: list[str], scenario: dict) -> bool:
    """A lifecycle scenario (UC-007 q11-q13) through the Python reference's
    `apply_changes` (S3-T3): the three roots are fed as `add` changes, then
    every step runs and is checked. `find` steps use `words` as conjunctive
    BM25 over the visible scope (S3-T2 owns the real `find` modes)."""
    index = FolderIndex()
    changes = [change for root in roots for change in folder_changes(root, pack_dir / root)]
    index.apply_changes({"roots": [{"root_id": r, "label": r, "kind": "host"} for r in roots], "changes": changes})
    for step in scenario["steps"]:
        if step["op"] == "apply_changes":
            batch = [add_change(c["root_id"], c["path"], c["text"]) if "text" in c else dict(c) for c in step["changes"]]
            report = index.apply_changes({"changes": batch})
            if any(report.get(key) != value for key, value in step["expect_report"].items()):
                return False
        elif step["op"] == "find":
            if step.get("mode", "words") != "words":
                return False
            hits = index.search(step["query"], roots=step.get("roots"), top_k=100, conjunctive=True)
            if "expect_hits" in step:
                expected = step["expect_hits"]
                if not all(any(_hit_overlaps(h, e) for h in hits) for e in expected):
                    return False
                if not all(any(_hit_overlaps(h, e) for e in expected) for h in hits):
                    return False
            for expected in step.get("expect_hits_include", []):
                if not any(_hit_overlaps(h, expected) for h in hits):
                    return False
            paths = {h["path"] for h in hits}
            if not set(step.get("expect_paths_include", [])) <= paths:
                return False
            if paths & set(step.get("expect_paths_exclude", [])):
                return False
            if step.get("expect_empty") and hits:
                return False
        elif step["op"] == "index_status":
            status = index.index_status()
            expect = step["expect"]
            if "pending_paths" in expect and status["pending_paths"] != expect["pending_paths"]:
                return False
            if "roots" in expect and [r["root_id"] for r in status["roots"]] != expect["roots"]:
                return False
            for gone in expect.get("no_trace_of_roots", []):
                if gone in index.roots or any(f["root_id"] == gone for f in index.list_files()):
                    return False
                if any(c["path"].startswith(gone + "/") for c in index.visible_chunks()):
                    return False
        else:
            return False
    return True


def run_pack(name: str, *, top_k: int = 5) -> dict:
    """Run a frozen judgment pack through the Python reference (lexical, one union index).

    Roots are copied side by side so a hit path reads `root/path`, the shape of a
    root_id plus a path. Cases the reference cannot answer yet are counted as skipped.
    """
    pack_dir = PACKS[name]
    judgments = json.loads((pack_dir / "judgments.json").read_text(encoding="utf-8"))
    cases: list[dict] = []
    skipped: dict[str, int] = {}

    def skip(kind: str, count: int = 1) -> None:
        skipped[kind] = skipped.get(kind, 0) + count

    with tempfile.TemporaryDirectory() as scratch:
        union = Path(scratch) / "union"
        for root in judgments["roots"]:
            shutil.copytree(pack_dir / root, union / root)
        index = build_index(union)

        def retrieve(case_id: str, query: str, expected: list[dict]) -> None:
            hits = [
                {"path": r["citation"]["path"], "start_line": r["citation"]["start_line"],
                 "end_line": r["citation"]["end_line"]}
                for r in search(index, query, top_k=top_k, retrieval_mode="lexical",
                                 title_root_ids=judgments["roots"])
            ]
            covered = sum(1 for e in expected if any(_overlaps(h, e) for h in hits))
            cases.append({"id": case_id, "query": query, "expected": len(expected),
                          "covered": covered, "recall": covered / len(expected)})

        def run_outline(case: dict) -> bool:
            got = outline(index, f"{case['root_id']}/{case['path']}")
            want = {key: case[key] for key in ("front_matter", "headings", "lines", "chunker")}
            return got == want

        def run_read_span(case: dict) -> bool:
            got = read_span(index, f"{case['root_id']}/{case['path']}", case["start_line"],
                            case["end_line"], case["context_lines"])
            return (got["sha256"] == case["sha256"]
                    and len(got["text"].encode("utf-8")) == case["byte_length"])

        exact: dict[str, list[dict]] = {kind: [] for kind in (*EXACT_KINDS, "lifecycle")}
        for case in judgments["outline"]:
            exact["outline"].append({"id": case["id"], "exact": run_outline(case)})
        for case in judgments["read_span"]:
            exact["read_span"].append({"id": case["id"], "exact": run_read_span(case)})
        by_case = {f"{kind}:{c['id']}": c for kind in EXACT_KINDS for c in judgments[kind]}

        def run_summary(sc: dict) -> bool:
            full = f"{sc['root_id']}/{sc['path']}"
            if not run_outline(by_case[sc["outline_ref"]]):
                return False
            chunks = [c for c in index["chunks"] if c["path"] == full]
            for want in sc["expected_sections"]:
                mine = sorted((c for c in chunks if c["section_path"] == want["section_path"]
                               and c["heading_line"] == want["heading_line"]),
                              key=lambda c: c["start_line"])
                span = want["first_span"]
                if not mine or not (mine[0]["start_line"] <= span["end_line"]
                                    and span["start_line"] <= mine[0]["end_line"]):
                    return False
            return True

        roots = judgments["roots"]

        def key(entry: dict) -> tuple:
            return entry["root_id"], entry["path"], entry["start_line"]

        def judge_find(case_id: str, kind: str, case: dict) -> None:
            """Every page of `find`; precision and recall over `expected` less the listed misses."""
            hits = find_all(index, case["query"], mode=case["mode"], page_size=2, root_ids=roots)
            misses = {key(e) for e in case.get("expected_engine_miss", [])}
            wanted = [e for e in case["expected"] if key(e) not in misses]

            def hit_overlaps(hit: dict, entry: dict) -> bool:
                return (hit["root_id"] == entry["root_id"] and hit["path"] == entry["path"]
                        and hit["start_line"] <= entry["end_line"] and entry["start_line"] <= hit["end_line"])

            relevant = sum(1 for h in hits if any(hit_overlaps(h, e) for e in case["expected"]))
            covered = sum(1 for e in wanted if any(hit_overlaps(h, e) for h in hits))
            miss_found = [e for e in case.get("expected_engine_miss", []) if any(hit_overlaps(h, e) for h in hits)]
            found_cases[kind].append({
                "id": case_id, "query": case["query"], "hits": len(hits),
                "precision": relevant / len(hits) if hits else 1.0,
                "recall": covered / len(wanted) if wanted else 1.0,
                "expected_misses": len(misses), "expected_misses_found": len(miss_found),
            })

        found_cases: dict[str, list[dict]] = {kind: [] for kind in FIND_KINDS}
        for kind in FIND_KINDS:
            for case in judgments[kind]:
                judge_find(case["id"], kind, case)

        newt = None
        by_ref = {c["id"]: c for kind in ("phrase", "prefix") for c in judgments[kind]}
        for sc in judgments["scenarios"]:
            kind = sc["kind"]
            if kind in ("words", "answer"):
                retrieve(sc["id"], sc["query"], sc["expected"])
            elif kind == "empty":
                newt = (not search(index, sc["query"], top_k=top_k, retrieval_mode="lexical",
                                 title_root_ids=judgments["roots"])
                        and find(index, sc["query"], mode=sc["mode"], root_ids=roots)["empty"])
            elif kind in ("phrase", "prefix"):
                judge_find(sc["id"], kind, {**by_ref[sc["ref"].split(":")[1]], "query": sc["query"], "mode": sc["mode"]})
            elif kind == "phrase_neighbour":
                expected = list(by_ref[sc["ref"].split(":")[1]]["expected"]) + [sc["expected_neighbour"]]
                retrieve(sc["id"], sc["words_query"], expected)
                # The phrase step: the phrase hit, then the next span of the same file.
                phrase_hits = find_all(index, sc["query"], mode=sc["mode"], root_ids=roots)
                want = sc["expected_neighbour"]
                chunks = sorted((c for c in index["chunks"] if c["path"] == f"{want['root_id']}/{want['path']}"),
                                key=lambda c: c["start_line"])
                neighbour_ok = False
                for hit in phrase_hits:
                    at = next(i for i, c in enumerate(chunks) if c["id"] == hit["chunk_id"])
                    for c in chunks[at:at + 2]:
                        if c["start_line"] <= want["end_line"] and want["start_line"] <= c["end_line"]:
                            neighbour_ok = neighbour_ok or c["section_path"] == want["section_path"]
                exact.setdefault("phrase_neighbour", []).append({"id": sc["id"], "exact": bool(phrase_hits) and neighbour_ok})
            elif kind == "outline":
                exact["outline"].append({"id": sc["id"], "exact": run_outline(by_case[sc["ref"]])})
            elif kind == "read_span":
                exact["read_span"].append({"id": sc["id"], "exact": run_read_span(by_case[sc["ref"]])})
            elif kind == "summary":
                exact["outline"].append({"id": sc["id"], "exact": run_summary(sc)})
            elif kind == "lifecycle":
                exact["lifecycle"].append({"id": sc["id"], "exact": run_lifecycle(pack_dir, judgments["roots"], sc)})
            else:
                skip(f"scenario {kind}")
    recalls = [c["recall"] for c in cases]
    words_recall = sum(recalls) / len(recalls) if recalls else 0.0
    exactness = {kind: (sum(1 for c in items if c["exact"]) / len(items) if items else 0.0)
                 for kind, items in exact.items()}
    find_metrics = {
        kind: {
            "precision": min((c["precision"] for c in items), default=1.0),
            "recall": min((c["recall"] for c in items), default=1.0),
            "expected_misses_found": sum(c["expected_misses_found"] for c in items),
        }
        for kind, items in found_cases.items()
    }
    passed = (words_recall >= PACK_WORDS_GATE and newt is True
              and all(value == 1.0 for value in exactness.values())
              and all(m["precision"] == 1.0 and m["recall"] == 1.0 and m["expected_misses_found"] == 0
                      for m in find_metrics.values()))
    return {
        "pack": name,
        "version": judgments["version"],
        "counts": {"scenarios": len(judgments["scenarios"]),
                   **{k: len(judgments[k]) for k in (*FIND_KINDS, *EXACT_KINDS)}},
        "words_recall_at_k": words_recall,
        "top_k": top_k,
        "words_cases": cases,
        "newt_empty": newt,
        "exact_cases": exact,
        "exactness": exactness,
        "find_cases": found_cases,
        "find_metrics": find_metrics,
        "skipped": skipped,
        "gate": {"words_recall_at_k_min": PACK_WORDS_GATE, "exactness_min": 1.0, "passed": passed},
    }


def print_pack_report(report: dict) -> None:
    counts = report["counts"]
    print(f"pack {report['pack']} (judgments version {report['version']}): "
          f"{counts['scenarios']} scenarios, {counts['phrase']} phrase, {counts['prefix']} prefix, "
          f"{counts['outline']} outline, {counts['read_span']} read_span")
    print(f"words recall@{report['top_k']}: {report['words_recall_at_k']:.3f} "
          f"over {len(report['words_cases'])} cases (gate >= {report['gate']['words_recall_at_k_min']})")
    for case in report["words_cases"]:
        print(f"  {case['id']} {case['covered']}/{case['expected']} expected spans in top "
              f"{report['top_k']}: {case['query']!r}")
    print(f"empty result for the newt question: {'pass' if report['newt_empty'] else 'FAIL'}")
    for kind, items in report["exact_cases"].items():
        exact = sum(1 for c in items if c["exact"])
        misses = [c["id"] for c in items if not c["exact"]]
        print(f"{kind} exactness: {exact}/{len(items)} (gate 1.00)" + (f" misses {misses}" if misses else ""))
    for kind, items in report["find_cases"].items():
        metrics = report["find_metrics"][kind]
        print(f"{kind}: precision {metrics['precision']:.2f}, recall {metrics['recall']:.2f} across all pages "
              f"over {len(items)} cases (gate 1.00); expected engine misses found: {metrics['expected_misses_found']}")
        for case in items:
            print(f"  {case['id']} {case['hits']} hits, precision {case['precision']:.2f}, recall {case['recall']:.2f}"
                  f"{', expected misses ' + str(case['expected_misses']) if case['expected_misses'] else ''}: {case['query']!r}")
    total = sum(report["skipped"].values())
    print(f"not yet implemented: {total} skipped")
    for kind, count in sorted(report["skipped"].items()):
        print(f"  {kind}: {count}")
    print(f"gate: {'pass' if report['gate']['passed'] else 'FAIL'}")



# ------------------------------------------------------------------- J2 ---
# S5-T1: the judged fixture that says where keyword search loses. The metric
# code lives here so the Python reference (`--pack j2`) and the shipped engine
# (`scripts/j2_run.py`) score with one implementation. A hit is
# {root_id, path, start_line, end_line, score, chunk_id}; it takes the
# highest-grade unmatched row it overlaps, each row matched at most once (as
# `evaluation._ranked_relevance`), anything else is grade 0.

J2_TOP_K = 10
J2_VARIANTS = ("content", "both")
J2_SLICES = ("control", "misspelling", "morphology", "accent", "tamil", "title", "phrase", "title-heldout",
             "misspelling-heldout", "morphology-heldout", "accent-heldout", "tamil-heldout")
# S5-T2, S5-T3 and S5-T4: the held-out slices are reported beside the overall, not
# inside it, so the overall stays the mean over S5-T1's 95 graded queries and
# comparable with it.
J2_OVERALL_EXCLUDES = ("title-heldout", "misspelling-heldout", "morphology-heldout", "accent-heldout",
                       "tamil-heldout")
J2_RESULTS_SCHEMA = "j2-results-v1"


def j2_grades(hits: list[dict], expected: list[dict]) -> tuple[list[int], list[int | None]]:
    """Grade of each hit, and the row index each hit matched (None when none)."""
    unmatched = set(range(len(expected)))
    grades: list[int] = []
    rows: list[int | None] = []
    for hit in hits:
        candidates = [i for i in unmatched if _hit_overlaps(hit, expected[i])]
        if not candidates:
            grades.append(0)
            rows.append(None)
            continue
        best = max(candidates, key=lambda i: (expected[i]["grade"], -i))
        unmatched.remove(best)
        grades.append(expected[best]["grade"])
        rows.append(best)
    return grades, rows


def j2_tie_groups(scores: list[float]) -> list[list[int]]:
    """1-based [first, last] rank runs whose scores are exactly equal on this surface."""
    groups = []
    start = 0
    for i in range(1, len(scores) + 1):
        if i == len(scores) or scores[i] != scores[start]:
            if i - start > 1:
                groups.append([start + 1, i])
            start = i
    return groups


def j2_query_metrics(grades: list[int], expected: list[dict]) -> dict:
    relevant = [row["grade"] for row in expected if row["grade"] >= 1]
    top = grades[:J2_TOP_K]
    first_relevant = next((rank for rank, g in enumerate(top, start=1) if g >= 1), None)
    first_answer = next((rank for rank, g in enumerate(top, start=1) if g == 2), None)
    ideal = discounted_cumulative_gain(sorted(relevant, reverse=True)[:J2_TOP_K])
    return {
        "success_at_1": 1.0 if top[:1] == [2] else 0.0,
        "mrr_at_10": 1.0 / first_relevant if first_relevant else 0.0,
        "ndcg_at_10": discounted_cumulative_gain(top) / ideal if ideal else 0.0,
        "recall_at_5": sum(1 for g in grades[:5] if g >= 1) / len(relevant) if relevant else 0.0,
        "first_grade2_rank": first_answer,
    }


def j2_record(item: dict, hits: list[dict]) -> dict:
    """One query's record: graded hits, ties, metrics (or the negative's information)."""
    hits = hits[:J2_TOP_K]
    grades, rows = j2_grades(hits, item["expected"])
    listed = []
    for rank, (hit, grade, row) in enumerate(zip(hits, grades, rows), start=1):
        listed.append({"rank": rank, "root_id": hit["root_id"], "path": hit["path"],
                       "start_line": hit["start_line"], "end_line": hit["end_line"], "grade": grade,
                       "row": row, "score": hit["score"], "chunk_id": hit.get("chunk_id")})
    ties = j2_tie_groups([hit["score"] for hit in hits])
    record = {"slice": item["slice"], "mode": item["mode"], "query": item["query"], "hits": listed, "ties": ties}
    if item.get("negative"):
        top = listed[0] if listed else None
        record.update({
            "returned": len(listed),
            "top_hit": None if top is None else {k: top[k] for k in ("root_id", "path", "start_line", "end_line")},
            "top_hit_grade": None if top is None else top["grade"],
            "top_is_named_distractor": None if top is None else top["row"] is not None,
        })
        return record
    record.update(j2_query_metrics(grades, item["expected"]))
    first = record["first_grade2_rank"]
    record["first_grade2_tied"] = bool(first and any(a <= first <= b for a, b in ties))
    return record


def j2_summarise(judgments: dict, records: dict[str, dict]) -> dict:
    """Slice means and the overall mean over every graded query (not a mean of slices)."""
    keys = ("success_at_1", "mrr_at_10", "ndcg_at_10", "recall_at_5")

    def mean(items: list[dict]) -> dict:
        return {"n": len(items), **{k: round(sum(r[k] for r in items) / len(items), 6) if items else 0.0 for k in keys}}

    graded = [q for q in judgments["queries"] if not q.get("negative")]
    slices = {name: mean([records[q["id"]] for q in graded if q["slice"] == name]) for name in J2_SLICES}
    negatives = {q["id"]: {k: records[q["id"]][k] for k in ("returned", "top_hit", "top_hit_grade", "top_is_named_distractor")}
                 for q in judgments["queries"] if q.get("negative")}
    overall = [records[q["id"]] for q in graded if q["slice"] not in J2_OVERALL_EXCLUDES]
    return {"slices": slices, "overall": mean(overall),
            "queries": {q["id"]: records[q["id"]] for q in judgments["queries"]}, "negatives": negatives}


def j2_run_queries(judgments: dict, knowledge, find_page) -> dict:
    """Both variants. `knowledge(query, search_field)` and `find_page(query, mode)` return
    hits; a find row runs once and its record stands in both variants."""
    found = {q["id"]: find_page(q["query"], q["mode"].split(":", 1)[1])
             for q in judgments["queries"] if q["mode"].startswith("find:")}
    runs = {}
    for variant in J2_VARIANTS:
        records = {}
        for q in judgments["queries"]:
            hits = found[q["id"]] if q["id"] in found else knowledge(q["query"], variant)
            records[q["id"]] = j2_record(q, hits)
        runs[variant] = j2_summarise(judgments, records)
    return runs


def j2_judgments_sha256(pack_dir: Path | None = None) -> str:
    return hashlib.sha256(((pack_dir or PACKS["j2"]) / "judgments.json").read_bytes()).hexdigest()


def j2_git_head() -> str | None:
    import subprocess
    try:
        done = subprocess.run(["git", "rev-parse", "HEAD"], cwd=Path(__file__).resolve().parent,
                              capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    return done.stdout.strip() or None if done.returncode == 0 else None


def j2_load() -> list[float] | None:
    import os
    try:
        return [round(x, 2) for x in os.getloadavg()]
    except (AttributeError, OSError):
        return None


def run_j2_pack(fold: str = "") -> dict:
    """J2 through the Python reference: one union index of the three roots with the
    file-name channel on; knowledge rows lexical, top 10, `content` and `both`;
    find rows first page of 10. `fold` names the parts of K that fold-groups-v1
    applies (S5-T4: "FAST" is the rule, "" off; `find` is never grouped)."""
    import os
    import platform
    pack_dir = PACKS["j2"]
    judgments = json.loads((pack_dir / "judgments.json").read_text(encoding="utf-8"))
    with tempfile.TemporaryDirectory() as scratch:
        union = Path(scratch) / "union"
        for root in judgments["roots"]:
            shutil.copytree(pack_dir / root, union / root)
        index = build_index(union, filename_index=True)

        def split(path: str) -> tuple[str, str]:
            root, _, rest = path.partition("/")
            return root, rest

        def knowledge(query: str, field: str) -> list[dict]:
            out = []
            for r in search(index, query, top_k=J2_TOP_K, retrieval_mode="lexical", search_field=field,
                            title_root_ids=judgments["roots"], fold=fold):
                root, rest = split(r["citation"]["path"])
                score = r["ranking"]["lexical"]["score"] if field == "content" else r["score"]
                out.append({"root_id": root, "path": rest, "start_line": r["citation"]["start_line"],
                            "end_line": r["citation"]["end_line"], "score": score, "chunk_id": r.get("chunk_id")})
            return out

        def find_page(query: str, mode: str) -> list[dict]:
            out = []
            for h in find(index, query, mode=mode, page_size=J2_TOP_K)["hits"]:
                root, rest = split(h["path"])
                out.append({"root_id": root, "path": rest, "start_line": h["start_line"], "end_line": h["end_line"],
                            "score": h["score"], "chunk_id": h.get("chunk_id")})
            return out

        runs = j2_run_queries(judgments, knowledge, find_page)
    return {
        "schema": J2_RESULTS_SCHEMA,
        "surface": "python-reference",
        "judgments_sha256": j2_judgments_sha256(pack_dir),
        "engine": {"commit": j2_git_head(), "python_version": platform.python_version(),
                   "hashseed": os.environ.get("PYTHONHASHSEED"), **({"fold": fold} if fold else {})},
        "load": j2_load(),
        "top_k": J2_TOP_K,
        "runs": runs,
    }


def print_j2_report(results: dict) -> None:
    print(f"J2 through the {results['surface']} (top {results['top_k']}, judgments {results['judgments_sha256'][:12]})")
    for variant, run in results["runs"].items():
        print(f"  search_field {variant}:  slice         n  success@1  MRR@10  nDCG@10  recall@5")
        for name, m in list(run["slices"].items()) + [("overall", run["overall"])]:
            print(f"    {name:<12} {m['n']:>3}  {m['success_at_1']:9.3f}  {m['mrr_at_10']:6.3f}  "
                  f"{m['ndcg_at_10']:7.3f}  {m['recall_at_5']:8.3f}")
        lost = [qid for qid, r in run["queries"].items()
                if r["slice"] == "control" and r["first_grade2_rank"] != 1]
        print(f"    control rows not at rank 1: {lost or 'none'}")
        returned = sum(1 for n in run["negatives"].values() if n["returned"])
        print(f"    negatives: {returned}/{len(run['negatives'])} return hits")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        allow_abbrev=False,
        description="Run a dependency-free, graded relevance smoke test over a file corpus."
    )
    parser.add_argument("corpus", type=Path, nargs="?")
    parser.add_argument("suite", type=Path, nargs="?")
    parser.add_argument("--pack", choices=sorted(PACKS), help="run a frozen judgment pack instead of corpus + suite")
    parser.add_argument("--mode", action="append", choices=RETRIEVAL_MODES, dest="modes")
    parser.add_argument(
        "--vector-mode", choices=("none", "hash", "cooccurrence", "neural"), default="none"
    )
    parser.add_argument("--model", default=DEFAULT_FASTEMBED_MODEL)
    parser.add_argument("--model-cache", type=Path, default=Path(".search/models"))
    parser.add_argument("--index", type=Path, help="reuse a prebuilt Search Simpli index")
    parser.add_argument("--save-index", type=Path, help="persist the newly built index for later runs")
    parser.add_argument("--top-k", type=int, help="result count (default: 5 for packs, 10 otherwise)")
    parser.add_argument("--min-ndcg", type=float)
    parser.add_argument("--min-mrr", type=float)
    parser.add_argument("--min-recall", type=float)
    parser.add_argument("--min-success", type=float)
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--max-regression", type=float, default=0.0)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--fold", default="", metavar="PARTS",
                        help="--pack j2 only: fold-groups-v1 with these parts of K (S5-T4; FAST is the rule)")
    arguments = list(sys.argv[1:] if argv is None else argv)
    args = parser.parse_args(arguments)
    if args.top_k is not None and args.top_k < 1:
        parser.error("--top-k must be at least 1")
    if args.pack:
        if args.corpus or args.suite:
            parser.error("--pack takes no corpus or suite")
        unsupported = sorted({value.split("=", 1)[0] for value in arguments
                              if value.startswith("--")
                              and value.split("=", 1)[0] not in {"--pack", "--top-k", "--output", "--fold"}})
        if unsupported:
            parser.error("--pack does not support " + ", ".join(unsupported))
        if args.pack == "j2":
            if args.top_k not in (None, J2_TOP_K):
                parser.error(f"--pack j2 runs at top_k {J2_TOP_K}")
            if args.fold and (set(args.fold) - set("FAST") or len(set(args.fold)) != len(args.fold)):
                parser.error("--fold takes letters of FAST, each once")
            results = run_j2_pack("".join(c for c in "FAST" if c in args.fold))
            print_j2_report(results)
            if args.output:
                args.output.parent.mkdir(parents=True, exist_ok=True)
                args.output.write_text(json.dumps(results, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
            return 0
        if args.fold:
            parser.error("--fold runs with --pack j2 only")
        report = run_pack(args.pack, top_k=5 if args.top_k is None else args.top_k)
        print_pack_report(report)
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        return 0 if report["gate"]["passed"] else 1
    if not args.corpus or not args.suite:
        parser.error("corpus and suite are required unless --pack is given")
    if args.top_k is None:
        args.top_k = 10
    if args.top_k < 1:
        parser.error("--top-k must be at least 1")
    if args.max_regression < 0.0:
        parser.error("--max-regression must be non-negative")
    if args.index and args.save_index:
        parser.error("--index and --save-index are mutually exclusive")
    minima = {
        name: value
        for name, value in {
            "ndcg": args.min_ndcg,
            "mrr": args.min_mrr,
            "recall": args.min_recall,
            "success": args.min_success,
        }.items()
        if value is not None
    }
    if any(not 0.0 <= value <= 1.0 for value in minima.values()):
        parser.error("minimum relevance metrics must be between 0 and 1")
    baseline = json.loads(args.baseline.read_text(encoding="utf-8")) if args.baseline else None
    try:
        report = run_smoke(
            args.corpus,
            args.suite,
            modes=args.modes or ["lexical"],
            vector_mode=args.vector_mode,
            top_k=args.top_k,
            minima=minima,
            baseline=baseline,
            max_regression=args.max_regression,
            model=args.model,
            model_cache=args.model_cache,
            index_path=args.index,
            save_index_path=args.save_index,
        )
    except (OSError, ProviderError, ValueError) as exc:
        print(f"relevance smoke error: {exc}", file=sys.stderr)
        return 2
    rendered = json.dumps(report, indent=2, ensure_ascii=False)
    print(rendered)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered + "\n", encoding="utf-8")
    return 0 if report["gate"]["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
