#!/usr/bin/env python3
"""Score `searchd` on the text-search judged set: the right file and the right passage (S6-T22, plan step H1).

    text_search_score.py --searchd PATH --scratch DIR --out-json RUN.json --out-md RUN.md
                         [--judgments fixtures/text-search/judgments.json] [--top-k 10]
                         [--fields both,content] [--engine-label TEXT]

DIR must not exist or must be empty; the scorer writes the generated folder to
DIR/corpus (`scripts/gen_text_search_corpus.py`, checked against the
judgments' `corpus_sha256`) and an index to DIR/index, and leaves both there.

Every question is asked in two forms, each on two surfaces with each field:
the form `typed` sends the question as a person typed it (`question`), the form
`query` sends the words a caller would pick (`query`); the two columns of every
table are typed / query.

- `direct`: `searchd search DIR/corpus QUERY --evidence --search-field F --top-k K`
  (no index; [direct search](../docs/direct-search.md)).
- `index`: `searchd index DIR/corpus --out DIR/index --filename-index` once, then
  `searchd evidence DIR/index QUERY --search-field F --top-k K`.

The text is sent as one argument. What is scored, per question, from the
evidence envelope's results in order:

- file rank: the rank of the first answer file among the distinct paths of the
  results, in the order they first appear; file@1, @3, @10 count a rank at or
  below 1, 3 and 10;
- passage rank: the rank of the first result whose passage (`citation.path`,
  `start_line`, `end_line`) holds one of the answer's ranges whole (same path,
  passage start at or before the range's start, passage end at or after its
  end); passage@1, @3, @10 likewise;
- complete@K: every part of the answer has one of its ranges held by some
  returned passage;
- for a no-answer question: whether anything was returned, and how many results;
- evidence bytes: the envelope's size on stdout; passage bytes: the UTF-8 size
  of the returned passages' `content`;
- tightness (rework 1, so that handing over more text cannot look like
  progress): `judged_share`, the share of the returned passages' bytes (each
  content line and its newline, line i of a passage taken as its file's line
  start_line + i) that lie inside a judged range of the question; `first_passage`,
  whether every part is held by the first passage returned from one of its
  ranges' files; `complete_within`, complete with at most BUDGET_BYTES evidence
  bytes; for a question with `stale` ranges, `stale_first`, whether a stale
  file ranks before every answer file.

`not read` counts the questions with an answer file the index does not list
(`searchd list-files`): the engine never read it, so nothing can find it.
Aggregates are counts and means over the questions of a kind; `total` is every
question with an answer (no-answer questions are reported on their own row),
and `total_without_single_source` leaves out the questions marked
`single_source` (their rarest query word is in one readable file only).
The output holds no time and no absolute path; the same binary, judgments and
arguments give the same bytes.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import statistics
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))

import gen_text_search_corpus as corpus_mod  # noqa: E402

SCHEMA = "text-search-score-v2"
JUDGMENTS_SCHEMA = "text-search-judgments-v2"
DEFAULT_JUDGMENTS = ROOT / "fixtures" / "text-search" / "judgments.json"
SURFACES = ("direct", "index")
RANKS = (1, 3, 10)
FORMS = ("typed", "query")
# "Complete within N bytes": N is the evidence a caller gets for one question.
# 4,096 (4 KiB), chosen from the baselines (docs/text-search-score.md): just
# above the median evidence size with `content` (v1 mean 2,477; rework-1
# median 3,479 typed, 2,785 query), a quarter to a third of the median with
# `both` (11,814 typed, 9,403 query), so it tells the tight answer from the
# same answer buried in more text.
BUDGET_BYTES = 4096
CALL_TIMEOUT_S = 120


# ---------------------------------------------------------------- judgments

def validate_judgments(data: dict) -> list[str]:
    """Shape problems of a judgments file, as sentences; empty when it is well formed."""
    problems = []
    if data.get("schema") != JUDGMENTS_SCHEMA:
        problems.append(f"schema is {data.get('schema')!r}, not {JUDGMENTS_SCHEMA!r}")
    kinds = data.get("kinds")
    questions = data.get("questions")
    if not isinstance(kinds, dict) or not isinstance(questions, list):
        return problems + ["kinds must be an object and questions a list"]
    seen = set()
    for q in questions:
        qid = q.get("id")
        if not isinstance(qid, str) or qid in seen:
            problems.append(f"bad or repeated id {qid!r}")
        seen.add(qid)
        for key in ("kind", "question", "query", "files", "parts", "single_source"):
            if key not in q:
                problems.append(f"{qid}: no {key}")
        if q.get("kind") not in kinds:
            problems.append(f"{qid}: unknown kind {q.get('kind')!r}")
        if not isinstance(q.get("question"), str) or not q.get("question", "").strip():
            problems.append(f"{qid}: empty question")
        if "query" in q and (not isinstance(q["query"], str) or not q["query"].strip()):
            problems.append(f"{qid}: empty query")
        if "single_source" in q and not isinstance(q["single_source"], bool):
            problems.append(f"{qid}: single_source must be true or false")
        for r in q.get("stale", []):
            if r.get("path") in q.get("files", []):
                problems.append(f"{qid}: stale file {r.get('path')} is also an answer file")
        no_answer = q.get("kind") == "no-answer"
        if no_answer != (q.get("files") == [] and q.get("parts") == []):
            problems.append(f"{qid}: files and parts must be empty exactly for no-answer questions")
        named = []
        for part in q.get("parts", []):
            ranges = part.get("ranges")
            if not isinstance(ranges, list) or not ranges:
                problems.append(f"{qid}: a part with no ranges")
                continue
            for r in ranges:
                s, e = r.get("start_line"), r.get("end_line")
                if not (isinstance(s, int) and isinstance(e, int) and 1 <= s <= e):
                    problems.append(f"{qid}: bad line range {s}-{e}")
                if not r.get("keys"):
                    problems.append(f"{qid}: a range with no keys")
                if r.get("path") not in named:
                    named.append(r.get("path"))
        if q.get("files") != named:
            problems.append(f"{qid}: files {q.get('files')} are not the paths its parts name, in order")
    for kind, info in kinds.items():
        count = sum(1 for q in questions if q.get("kind") == kind)
        if info.get("questions") != count:
            problems.append(f"kind {kind}: says {info.get('questions')} questions, has {count}")
    return problems


def text_of(q: dict, form: str) -> str:
    return q["question"] if form == "typed" else q["query"]


# ---------------------------------------------------------------- scoring

def passages_of(envelope: dict) -> list[dict]:
    """The returned passages, in order, from either envelope `evidence` prints.

    With `--search-field filename` or `both` it is the tool envelope (`results`,
    each with a `citation`); with `content` it is the older one (`evidence`, each
    with `path`, `start_line`, `end_line` at the top)."""
    if "results" in envelope:
        rows = [dict(r["citation"], content=r.get("content", "")) for r in envelope["results"]]
    elif "evidence" in envelope:
        rows = envelope["evidence"]
    else:
        raise ValueError("an evidence envelope with neither results nor evidence")
    return [{"path": r["path"], "start_line": r["start_line"], "end_line": r["end_line"],
             "content": r.get("content", "")} for r in rows]


def holds(passage: dict, rng: dict) -> bool:
    return (passage["path"] == rng["path"] and passage["start_line"] <= rng["start_line"]
            and rng["end_line"] <= passage["end_line"])


def judged_bytes(passages: list[dict], ranges: list[dict]) -> tuple[int, int]:
    """(bytes inside a judged range, all bytes) of the passages' content lines, newline included."""
    inside = total = 0
    for p in passages:
        for i, line in enumerate(p["content"].split("\n")):
            size = len(line.encode("utf-8")) + 1
            total += size
            n = p["start_line"] + i
            if any(r["path"] == p["path"] and r["start_line"] <= n <= r["end_line"] for r in ranges):
                inside += size
    return inside, total


def score_question(q: dict, passages: list[dict], evidence_bytes: int) -> dict:
    row = {"id": q["id"], "kind": q["kind"], "returned": len(passages), "evidence_bytes": evidence_bytes,
           "passage_bytes": sum(len(p["content"].encode("utf-8")) for p in passages),
           "top_paths": [p["path"] for p in passages[:3]]}
    ranges = [r for part in q["parts"] for r in part["ranges"]]
    inside, total = judged_bytes(passages, ranges)
    row["judged_share"] = round(inside / total, 4) if total else None
    if q["kind"] == "no-answer":
        return row
    distinct = []
    for p in passages:
        if p["path"] not in distinct:
            distinct.append(p["path"])
    wanted = set(q["files"])
    row["file_rank"] = next((i for i, path in enumerate(distinct, 1) if path in wanted), None)
    row["passage_rank"] = next((i for i, p in enumerate(passages, 1) if any(holds(p, r) for r in ranges)), None)
    row["parts_found"] = sum(1 for part in q["parts"] if any(holds(p, r) for p in passages for r in part["ranges"]))
    row["parts"] = len(q["parts"])
    row["complete"] = row["parts_found"] == row["parts"]
    first = {}
    for p in passages:
        first.setdefault(p["path"], p)
    row["first_passage"] = all(any(r["path"] in first and holds(first[r["path"]], r) for r in part["ranges"])
                               for part in q["parts"])
    row["complete_within"] = row["complete"] and evidence_bytes <= BUDGET_BYTES
    if q.get("stale"):
        stale = {r["path"] for r in q["stale"]}
        row["stale_rank"] = next((i for i, path in enumerate(distinct, 1) if path in stale), None)
        row["stale_first"] = row["stale_rank"] is not None and (row["file_rank"] is None
                                                                or row["stale_rank"] < row["file_rank"])
    row["single_source"] = q.get("single_source", False)
    return row


def share(rows: list[dict], test) -> dict:
    hits = sum(1 for row in rows if test(row))
    return {"hits": hits, "of": len(rows), "share": round(hits / len(rows), 4) if rows else None}


def aggregate(rows: list[dict], unread: set[str]) -> dict:
    out = {"questions": len(rows)}
    if not rows:
        return out
    if all(row["kind"] == "no-answer" for row in rows):
        out["returned_something"] = share(rows, lambda r: r["returned"] > 0)
        out["mean_results"] = round(statistics.mean(r["returned"] for r in rows), 2)
    else:
        for k in RANKS:
            out[f"file@{k}"] = share(rows, lambda r, k=k: r["file_rank"] is not None and r["file_rank"] <= k)
        for k in RANKS:
            out[f"passage@{k}"] = share(rows, lambda r, k=k: r["passage_rank"] is not None and r["passage_rank"] <= k)
        out["complete"] = share(rows, lambda r: r["complete"])
        out["complete_within"] = share(rows, lambda r: r["complete_within"])
        out["first_passage"] = share(rows, lambda r: r["first_passage"])
        out["not_read"] = share(rows, lambda r: r["id"] in unread)
        out["single_source"] = share(rows, lambda r: r["single_source"])
        with_stale = [r for r in rows if "stale_first" in r]
        if with_stale:
            out["stale_first"] = share(with_stale, lambda r: r["stale_first"])
    out["evidence_bytes_mean"] = round(statistics.mean(r["evidence_bytes"] for r in rows), 1)
    out["evidence_bytes_median"] = statistics.median(r["evidence_bytes"] for r in rows)
    out["passage_bytes_mean"] = round(statistics.mean(r["passage_bytes"] for r in rows), 1)
    shares = [r["judged_share"] for r in rows if r["judged_share"] is not None]
    out["judged_share_mean"] = round(statistics.mean(shares), 4) if shares else None
    return out


def summarize(rows: list[dict], kinds: list[str], unread: set[str]) -> dict:
    per_kind = {kind: aggregate([r for r in rows if r["kind"] == kind], unread) for kind in kinds}
    answerable = [r for r in rows if r["kind"] != "no-answer"]
    return {"total": aggregate(answerable, unread),
            "total_without_single_source": aggregate([r for r in answerable if not r["single_source"]], unread),
            "no_answer": aggregate([r for r in rows if r["kind"] == "no-answer"], unread),
            "per_kind": per_kind}


# ---------------------------------------------------------------- running

def run(binary: Path, args: list[str], cwd: Path) -> bytes:
    done = subprocess.run([str(binary), *args], capture_output=True, timeout=CALL_TIMEOUT_S, cwd=cwd)
    if done.returncode != 0:
        raise SystemExit(f"searchd {args[0]} exited {done.returncode}: {done.stderr.decode(errors='replace').strip()}")
    return done.stdout


def indexed_paths(binary: Path, index: Path, cwd: Path) -> set[str]:
    paths, cursor = set(), None
    while True:
        args = ["list-files", str(index), "--json", "--page-size", "100"]
        if cursor:
            args += ["--cursor", cursor]
        page = json.loads(run(binary, args, cwd))
        paths.update(f["path"] for f in page["files"] if f.get("status") == "indexed")
        cursor = page.get("next_cursor")
        if not cursor:
            return paths


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def score(binary: Path, judgments_path: Path, scratch: Path, top_k: int, fields: list[str],
          engine_label: str | None, questions_filter=None) -> dict:
    data = json.loads(judgments_path.read_text(encoding="utf-8"))
    problems = validate_judgments(data)
    if problems:
        raise SystemExit("judgments are malformed:\n  " + "\n  ".join(problems))
    questions = data["questions"]
    if questions_filter is not None:
        questions = [q for q in questions if questions_filter(q)]
    kinds = list(data["kinds"])
    scratch.mkdir(parents=True, exist_ok=True)
    if any(scratch.iterdir()):
        raise SystemExit(f"--scratch must be empty or absent: {scratch}")
    folder, index = scratch / "corpus", scratch / "index"
    corpus = corpus_mod.write_corpus(folder)
    digest = corpus_mod.corpus_digest(corpus)
    if digest != data["corpus"]["corpus_sha256"]:
        raise SystemExit(f"generated corpus {digest} is not the judged one {data['corpus']['corpus_sha256']}")
    run(binary, ["index", str(folder), "--out", str(index), "--filename-index"], scratch)
    read = indexed_paths(binary, index, scratch)
    unread = {q["id"] for q in questions if any(path not in read for path in q["files"])}

    configs, raw = {}, {}
    for field in fields:
        for form in FORMS:
            for surface in SURFACES:
                rows = []
                for q in questions:
                    text = text_of(q, form)
                    rest = ["--search-field", field, "--top-k", str(top_k)]
                    if surface == "direct":
                        out = run(binary, ["search", str(folder), text, "--evidence", *rest], scratch)
                    else:
                        out = run(binary, ["evidence", str(index), text, *rest], scratch)
                    raw[(field, form, surface, q["id"])] = out
                    rows.append(score_question(q, passages_of(json.loads(out)), len(out)))
                configs[f"{surface}/{field}/{form}"] = {"surface": surface, "search_field": field, "form": form,
                                                        "summary": summarize(rows, kinds, unread),
                                                        "questions": rows}
    agreement = {f"{field}/{form}": sum(1 for q in questions
                                        if raw[(field, form, "direct", q["id"])] == raw[(field, form, "index", q["id"])])
                 for field in fields for form in FORMS}
    return {
        "schema": SCHEMA,
        "engine": {"searchd_sha256": sha256_file(binary), "label": engine_label},
        "judgments": {"path": str(judgments_path.resolve().relative_to(ROOT)) if judgments_path.resolve().is_relative_to(ROOT) else judgments_path.name,
                      "sha256": sha256_file(judgments_path), "questions": len(questions)},
        "corpus": {"files": len(corpus), "bytes": sum(len(v) for v in corpus.values()), "corpus_sha256": digest,
                   "files_read_by_engine": len(read), "files_not_read": sorted(set(corpus) - read)},
        "top_k": top_k,
        "budget_bytes": BUDGET_BYTES,
        "fields": fields,
        "forms": list(FORMS),
        "direct_equals_index": {key: {"identical": n, "of": len(questions)} for key, n in agreement.items()},
        "not_read_questions": sorted(unread),
        "configs": configs,
    }


# ---------------------------------------------------------------- Markdown

def cell(entry: dict | None) -> str:
    if not entry or entry.get("share") is None:
        return "–"
    return f"{entry['share']:.2f} ({entry['hits']}/{entry['of']})"


def hits(entry: dict | None) -> str:
    return "–" if not entry or entry.get("share") is None else str(entry["hits"])


def pair(typed: dict, query: dict, key: str, fmt) -> str:
    return f"{fmt(typed.get(key))} / {fmt(query.get(key))}"


def number(value) -> str:
    return "–" if value is None else f"{value:,.0f}"


def ratio(value) -> str:
    return "–" if value is None else f"{value:.2f}"


ROWS_TOTAL = (("**total** (with an answer)", "total"),
              ("**total without single-source**", "total_without_single_source"))


def tables(typed: dict, query: dict, kinds: list[str]) -> list[str]:
    """Two tables, finding and tightness; every cell is typed / query, counts of questions."""
    names = [(kind, typed["per_kind"][kind], query["per_kind"][kind]) for kind in kinds]
    names += [(label, typed[key], query[key]) for label, key in ROWS_TOTAL]
    find = ["| Kind | n | single-source | not read | file@1 | file@3 | file@10 | passage@1 | passage@3 "
            "| passage@10 | complete | returned anything |",
            "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    tight = [f"| Kind | n | complete | complete within {BUDGET_BYTES:,} bytes | evidence bytes, median "
             "| judged share of passage bytes, mean | answer in its file's first passage | stale copy ranked first |",
             "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for name, t, q in names:
        n = t["questions"]
        cells = [pair(t, q, f"file@{k}", hits) for k in RANKS] + [pair(t, q, f"passage@{k}", hits) for k in RANKS]
        find.append(f"| {name} | {n} | {hits(t.get('single_source'))} | {hits(t.get('not_read'))} | "
                    + " | ".join(cells) + f" | {pair(t, q, 'complete', hits)} | {pair(t, q, 'returned_something', hits)} |")
        tight.append(f"| {name} | {n} | {pair(t, q, 'complete', hits)} | {pair(t, q, 'complete_within', hits)} | "
                     f"{pair(t, q, 'evidence_bytes_median', number)} | {pair(t, q, 'judged_share_mean', ratio)} | "
                     f"{pair(t, q, 'first_passage', hits)} | {pair(t, q, 'stale_first', hits)} |")
    return ["Finding: how many questions (typed / query).", "", *find, "",
            "Tightness (typed / query).", "", *tight]


def markdown(result: dict, kinds: list[str]) -> str:
    lines = ["# Text-search score", "",
             f"`searchd` sha256 `{result['engine']['searchd_sha256']}`"
             + (f" ({result['engine']['label']})" if result["engine"]["label"] else "") + ".",
             f"Judgments `{result['judgments']['path']}` sha256 `{result['judgments']['sha256']}`, "
             f"{result['judgments']['questions']} questions.",
             f"Corpus {result['corpus']['files']} files, {result['corpus']['bytes']:,} bytes, sha256 "
             f"`{result['corpus']['corpus_sha256']}`; the engine read {result['corpus']['files_read_by_engine']} "
             f"and left {len(result['corpus']['files_not_read'])} unread.",
             f"Top {result['top_k']} results per question. Every cell is typed / query: the question sent as typed, "
             "then the query words.", ""]
    for field in result["fields"]:
        lines += [f"## `--search-field {field}`, direct search", ""]
        lines += tables(result["configs"][f"direct/{field}/typed"]["summary"],
                        result["configs"][f"direct/{field}/query"]["summary"], kinds)
        lines.append("")
        same = all(result["direct_equals_index"][f"{field}/{form}"]["identical"]
                   == result["direct_equals_index"][f"{field}/{form}"]["of"] for form in result["forms"])
        if same:
            lines += [f"The index surface (`index` then `evidence`) gave byte-identical evidence for every question "
                      "in both forms, so its tables are the same.", ""]
        else:
            lines += ["The index surface did not give byte-identical evidence for every question; its tables:", ""]
            lines += tables(result["configs"][f"index/{field}/typed"]["summary"],
                            result["configs"][f"index/{field}/query"]["summary"], kinds)
            lines.append("")
    return "\n".join(lines)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Score searchd on the text-search judged set.")
    parser.add_argument("--searchd", type=Path, required=True)
    parser.add_argument("--scratch", type=Path, required=True)
    parser.add_argument("--out-json", type=Path, required=True)
    parser.add_argument("--out-md", type=Path, required=True)
    parser.add_argument("--judgments", type=Path, default=DEFAULT_JUDGMENTS)
    parser.add_argument("--top-k", type=int, default=10)
    parser.add_argument("--fields", default="both,content")
    parser.add_argument("--engine-label", default=None)
    args = parser.parse_args(argv)
    fields = [f for f in args.fields.split(",") if f]
    if not fields or any(f not in ("content", "filename", "both") for f in fields):
        parser.error("--fields takes content, filename and both, comma-separated")
    kinds = list(json.loads(args.judgments.read_text(encoding="utf-8"))["kinds"])
    result = score(args.searchd, args.judgments, args.scratch, args.top_k, fields, args.engine_label)
    args.out_json.write_text(json.dumps(result, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    args.out_md.write_text(markdown(result, kinds) + "\n", encoding="utf-8")
    for form in FORMS:
        total = result["configs"][f"direct/{fields[0]}/{form}"]["summary"]["total"]
        print(f"{fields[0]}/{form}: file@10 {cell(total['file@10'])}, passage@10 {cell(total['passage@10'])}, "
              f"complete {cell(total['complete'])}, within {BUDGET_BYTES} bytes {cell(total['complete_within'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
